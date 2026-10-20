# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# 3 x Ubuntu 26.04 "CI" nodes, SSH forwarded on host ports 12231-12233.
#
# Each node also gets a second NIC on a static private network
# (192.168.78.11-13) so the nodes can reach each other at deterministic
# addresses, and /etc/hosts entries for all three nodes are written by the
# provision script (node1 .. node3).  There is no CI on these nodes, just
# Docker: they exist so ddcache can be exercised the way it would run,
# i.e. several builders that each hold their own cache and have to
# exchange cache data over the network.
#
# The subnet and the SSH port range deliberately differ from the
# `deployed` project's cluster (192.168.56.x / 1222x) so both can be
# up at the same time.
#
# Every node is provisioned with docker (Ubuntu's own docker.io +
# docker-buildx), rsync, zstd and skopeo, plus a shared cluster SSH key
# so any node can ssh/scp to any other node as `vagrant` over the private
# network without a password.  `ubuntu:26.04` and `registry:2` are pulled
# during provisioning so a cold test run isn't dominated by image pulls.
#
# Host-architecture aware: the box `bento/ubuntu-26.04` publishes separate
# arm64 and amd64 builds for every common provider (virtualbox, libvirt,
# parallels, qemu, utm, vmware_desktop), and Vagrant downloads the build
# matching the host CPU.

require "rbconfig"

HOST_ARCH = case RbConfig::CONFIG["host_cpu"]
            when /arm64|aarch64/ then "arm64"
            when /x86_64|amd64/  then "amd64"
            else
              `uname -m`.strip
            end

MACOS = !!(RbConfig::CONFIG["host_os"] =~ /darwin/)

BOX        = "bento/ubuntu-26.04"
BOX_ARCH   = HOST_ARCH
SUBNET     = "192.168.78"
NODES = {
  "node1" => { ssh_port: 12231, private_ip: "#{SUBNET}.11" },
  "node2" => { ssh_port: 12232, private_ip: "#{SUBNET}.12" },
  "node3" => { ssh_port: 12233, private_ip: "#{SUBNET}.13" },
}

MEMORY = 3072
CPUS   = 2

# The bento/ubuntu-26.04 box is UEFI-only: GPT disk with an EFI System
# Partition and no BIOS boot partition.  libvirt must boot it with OVMF
# (or AAVMF on arm64) instead of the default SeaBIOS, otherwise the
# firmware can't find a bootloader and the vCPU spins at 100% forever.
UEFI_CODE_CANDIDATES = {
  "amd64" => %w[
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
  ],
  "arm64" => %w[
    /usr/share/AAVMF/AAVMF_CODE.fd
    /usr/share/AAVMF/AAVMF_CODE_4M.fd
    /usr/share/edk2/aarch64/QEMU_EFI.fd
    /usr/share/edk2/aarch64/QEMU_EFI_4M.fd
  ],
}
UEFI_CODE = (UEFI_CODE_CANDIDATES[HOST_ARCH] || []).find { |p| File.exist?(p) }

# Shared cluster keypair: every node trusts the public half and holds the
# private half, so node->node ssh/scp works both ways with no passwords.
# It lives under .vagrant/ (gitignored) and is created on first `up`.
KEY_DIR  = ".vagrant"
KEY_PATH = "#{KEY_DIR}/cluster_key"
Dir.mkdir(KEY_DIR) unless Dir.exist?(KEY_DIR)
system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ddcache-cluster", "-f", KEY_PATH) unless File.exist?(KEY_PATH)
CLUSTER_PUB   = File.read("#{KEY_PATH}.pub").strip
CLUSTER_PRIV  = `base64 -w0 #{KEY_PATH}`.strip

PROVISION_SCRIPT = <<~SHELL
  set -eux
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y openssh-server sudo curl rsync zstd skopeo docker.io docker-buildx
  systemctl enable --now docker
  usermod -aG docker vagrant

  # --- inter-node SSH ------------------------------------------------------
  install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
  grep -qF "#{CLUSTER_PUB}" /home/vagrant/.ssh/authorized_keys 2>/dev/null ||
    echo '#{CLUSTER_PUB}' >>/home/vagrant/.ssh/authorized_keys
  echo '#{CLUSTER_PRIV}' | base64 -d >/home/vagrant/.ssh/id_cluster
  printf 'Host *\\n  StrictHostKeyChecking no\\n  UserKnownHostsFile /dev/null\\n  IdentityFile ~/.ssh/id_cluster\\n' >/home/vagrant/.ssh/config
  chmod 600 /home/vagrant/.ssh/id_cluster /home/vagrant/.ssh/config
  chmod 644 /home/vagrant/.ssh/authorized_keys
  chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys /home/vagrant/.ssh/config \
    /home/vagrant/.ssh/id_cluster

  # --- static private-network address --------------------------------------
  # Every provider except qemu configures the private_network NIC itself.  The
  # qemu provider does it with a cloud-init seed, and this box ships cloud-init
  # disabled, so the NIC would otherwise sit on vmnet's DHCP pool instead of
  # its static IP.  Pin it ourselves when it isn't already set; the management
  # NIC is the qemu user-mode NAT (10.0.2.x), so the private NIC is whatever
  # else is there.
  idx="$(hostname | sed 's/^node//')"
  want="#{SUBNET}.1${idx}"
  if ! ip -4 -o addr show | grep -q "inet ${want}/"; then
    nat="$(ip -4 -o addr show | awk '$4 ~ /^10\\.0\\.2\\./ { print $2; exit }')"
    dev="$(ls /sys/class/net | grep -vE "^(lo|${nat})$" | head -1)"
    printf 'network:\\n  version: 2\\n  ethernets:\\n    %s:\\n      dhcp4: false\\n      addresses: [%s/24]\\n' \\
      "${dev}" "${want}" >/etc/netplan/60-private-network.yaml
    chmod 600 /etc/netplan/60-private-network.yaml
    netplan apply
  fi

  # --- deterministic inter-node name resolution ----------------------------
  # Point our own hostname at our private-network IP (bento maps it to
  # 127.0.1.1, which breaks anything that advertises its own hostname),
  # then add /etc/hosts entries for every other node.
  sed -i "s/^127\\.0\\.1\\.1 .*/#{SUBNET}.1${idx} $(hostname)/" /etc/hosts
  for i in 1 2 3; do
    if [ "$i" != "$idx" ]; then
      grep -qE "[[:space:]]node${i}$" /etc/hosts ||
        echo "#{SUBNET}.1${i} node${i}" >>/etc/hosts
    fi
  done

  # --- the NAT gateway, as a stable name -----------------------------------
  # The host runs an apt-caching HTTP proxy (see nginx/) that is reachable
  # from every node at its NAT gateway address.  Every node resolves it to the
  # same name so a proxy build-arg can't fragment the Docker cache between
  # nodes the way a per-node bridge IP would.
  gw="$(ip route show default | awk '{print $3; exit}')"
  grep -qE "[[:space:]]apt-cache$" /etc/hosts || echo "${gw} apt-cache" >>/etc/hosts

  # --- don't make the first test run wait for pulls ------------------------
  docker pull -q ubuntu:26.04
  docker pull -q registry:2
SHELL

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_check_update = false

  # No project dir in the guest: tests rsync what they need, which keeps the
  # node's cache state out of any host-synced mount.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |name, cfg|
    config.vm.define name do |node|
      node.vm.hostname = name

      # Override the default "ssh" forwarded port so `vagrant ssh` and the
      # test harness both use 1223x on the host side.
      node.vm.network "forwarded_port",
                      guest: 22,
                      host:  cfg[:ssh_port],
                      id:    "ssh",
                      auto_correct: false

      # Static private network so the nodes reach each other at deterministic
      # addresses (libvirt, virtualbox and parallels wire this up natively; the
      # qemu provider needs the advanced_network opt-in below).
      node.vm.network "private_network", ip: cfg[:private_ip]

      node.vm.provider "virtualbox" do |vb|
        vb.name   = "ddcache-#{name}"
        vb.memory = MEMORY
        vb.cpus   = CPUS
      end

      node.vm.provider "libvirt" do |lv|
        # Force KVM when the host has it; the bento box ships `driver = "qemu"`
        # in its own Vagrantfile so it runs in CI/containers without /dev/kvm.
        # On a real Linux host that drops us into TCG (pure software
        # emulation), pinning every QEMU process at 100% and never finishing
        # the boot.  Override it here so KVM is used where available.
        if File.exist?("/dev/kvm")
          lv.driver = "kvm"
        end
        if UEFI_CODE
          lv.loader = UEFI_CODE
          lv.nvram  = "/var/lib/libvirt/qemu/nvram/#{name}_ddcache_VARS.fd"
        end
        # vagrant-libvirt reaches the guest via its 192.168.121.x IP for
        # `vagrant ssh`, so it skips forwarding the `id: "ssh"` port by
        # default.  Opt back in so the documented localhost:1223x ports are
        # real on every provider, even though `vagrant ssh-config` still
        # prefers the direct address.
        lv.forward_ssh_port = true
        lv.memory = MEMORY
        lv.cpus   = CPUS
      end

      node.vm.provider "parallels" do |pr|
        pr.name   = "ddcache-#{name}"
        pr.memory = MEMORY
        pr.cpus   = CPUS
      end

      node.vm.provider "qemu" do |q|
        # The vagrant-qemu plugin drives its own SSH hostfwd and ignores the
        # Vagrantfile's forwarded_port host for id: "ssh".
        q.ssh_port = cfg[:ssh_port]
        q.memory   = MEMORY
        q.cpus     = CPUS

        # Without this the plugin silently drops the private_network above and
        # the nodes only get the user-mode NAT NIC, so nothing can reach them
        # at #{SUBNET}.x.  On macOS the NIC is backed by the socket_vmnet
        # daemon, which holds the root vmnet.framework membership so QEMU
        # itself stays unprivileged.
        q.advanced_network = true
        q.net_mode = :socket_vmnet if MACOS
      end

      node.vm.provision "shell", inline: PROVISION_SCRIPT
    end
  end

  puts "-> Vagrantfile: host arch=#{HOST_ARCH}, box=#{BOX} (#{BOX_ARCH}), subnet=#{SUBNET}.0/24"
end
