#!/bin/bash

set -euo pipefail

#
#  Virtual "CI cluster" for ddcache.  VMs only, no containers here: the
#  nodes themselves run Docker.
#
#  usage:
#    ./env.sh up             bring up every node and snapshot the clean cluster
#    ./env.sh down           destroy the cluster
#    ./env.sh snapshot       take the restore point (done by `up`)
#    ./env.sh restore        roll every node back to that restore point
#    ./env.sh status         provider, node state, node addresses
#    ./env.sh vagrant ...    anything else, straight through to vagrant
#
#  `restore` is the important one for cache work: a test run dirties the
#  nodes (builder caches, cache dirs, registry storage) and iterating on a
#  cache experiment means starting from an empty cache every time.
#

#
# platform handling
#

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
Darwin) platform="macos" ;;
Linux) platform="linux" ;;
MINGW* | MSYS* | CYGWIN*) platform="windows" ;;
*) platform="${os,,}" ;;
esac
case "$arch" in
arm64 | aarch64) arch="arm64" ;;
x86_64 | amd64) arch="amd64" ;;
esac

BUILTIN_PROVIDERS="virtualbox hyperv"

plugin_for() {
	case "$1" in
	libvirt) echo "vagrant-libvirt" ;;
	qemu) echo "vagrant-qemu" ;;
	parallels) echo "vagrant-parallels" ;;
	vmware_desktop) echo "vagrant-vmware-desktop" ;;
	*) echo "" ;;
	esac
}

provider_ready() {
	local p="$1"

	case "$p" in

	libvirt)
		virsh -c qemu:///system uri >/dev/null 2>&1 && return 0
		[[ -S /var/run/libvirt/libvirt-sock ]] ||
			[[ -S /opt/local/var/run/libvirt/libvirt-sock ]] ||
			[[ -S "$HOME/.libvirt/libvirt-sock" ]] && return 0
		return 1
		;;

	parallels)
		command -v prlctl >/dev/null 2>&1 && prlctl list -a >/dev/null 2>&1
		;;

	qemu)
		local qarch="amd64"
		[[ "$arch" == "arm64" ]] && qarch="aarch64"
		command -v "qemu-system-${qarch}" >/dev/null 2>&1
		;;

	*)
		return 0
		;;

	esac
}

detect_provider() {
	if [[ -n "${ENV_PROVIDER:-}" ]]; then
		echo "${ENV_PROVIDER}"
		return
	fi

	local candidates

	case "$platform/$arch" in
	macos/arm64) candidates="libvirt qemu virtualbox parallels" ;;
	macos/amd64) candidates="libvirt virtualbox qemu" ;;
	linux/*) candidates="libvirt virtualbox" ;;
	windows/*) candidates="virtualbox" ;;
	*) candidates="virtualbox libvirt parallels qemu" ;;
	esac

	local plugins
	plugins="$(vagrant plugin list 2>/dev/null || true)"

	local p plugin
	for p in $candidates; do
		if [[ " $BUILTIN_PROVIDERS " == *" $p "* ]]; then
			case "$p" in

			virtualbox) [[ -x "$(command -v VBoxManage 2>/dev/null)" ]] && provider_ready "$p" && {
				echo "$p"
				return
			} ;;

			hyperv) [[ "$platform" == "windows" ]] && {
				echo "$p"
				return
			} ;;

			esac

			continue
		fi

		plugin="$(plugin_for "$p")"
		[[ -z "$plugin" ]] && continue
		if printf '%s\n' "$plugins" | grep -q "^${plugin} " && provider_ready "$p"; then
			echo "$p"
			return
		fi
	done

	echo ""
}

provider="$(detect_provider)"

#
# helpers
#

require_vagrant() {
	command -v vagrant >/dev/null 2>&1 || {
		echo "env.sh: 'vagrant' not found on PATH.  Install Vagrant first:" >&2
		echo "  brew install vagrant   # or: https://developer.hashicorp.com/vagrant/install" >&2
		exit 1
	}
}

require_provider() {
	[[ -n "$provider" ]] || {
		echo "env.sh: no usable Vagrant provider found.  Candidates for $platform/$arch:" >&2
		echo "  libvirt  -> vagrant plugin install vagrant-libvirt, and a running" >&2
		echo "              libvirtd (systemctl start libvirtd.socket)" >&2
		echo "  virtualbox -> install VBoxManage" >&2
		echo "Or set ENV_PROVIDER=<provider> to force one." >&2
		exit 1
	}
}

vagrant_up() {
	if [[ -n "$provider" ]]; then
		vagrant up --provider="$provider" "$@"
	else
		vagrant up "$@"
	fi
}

vagrant_vm_names() {
	vagrant status --machine-readable 2>/dev/null |
		awk -F, '$3 == "provider-name" { print $2 }' |
		sort -u
}

vagrant_halt_parallel() {
	local vm pid failed=0 started=0
	local pids=()

	while IFS= read -r vm; do
		[[ -n "$vm" ]] || continue
		echo "env.sh: vagrant halt $vm"
		vagrant halt "$vm" &
		pids+=("$!")
		started=1
	done < <(vagrant_vm_names)

	if ((started == 0)); then
		echo "env.sh: no Vagrant machines to halt" >&2
		return 1
	fi

	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			failed=1
		fi
	done

	return "$failed"
}

#
# snapshot / restore
#

VAGRANT_SNAPSHOT_NAME="env-sh"
LIBVIRT_URI="qemu:///system"
VAGRANT_SNAPSHOT_DIR=".vagrant/snapshots"

libvirt_domain_for() {
	local vm="$1"
	virsh -c "$LIBVIRT_URI" list --all --name 2>/dev/null |
		grep -E "_${vm}$" | head -1
}

# virsh save/restore covers RAM, but a build run also writes the disk, and
# `virsh restore` comes back to the state the *save* was taken from only for
# memory.  Take an internal qemu-img disk snapshot alongside it so a restore
# really is "empty caches again".
libvirt_snapshot() {
	local snapdir="$VAGRANT_SNAPSHOT_DIR" vm domain state disk saved

	mkdir -p "$snapdir"

	saved=0

	while IFS= read -r vm; do
		[[ -n "$vm" ]] || continue
		domain="$(libvirt_domain_for "$vm")"
		if [[ -z "$domain" ]]; then
			echo "env.sh: skip $vm (no libvirt domain)"
			continue
		fi
		state="$(virsh -c "$LIBVIRT_URI" domstate "$domain" 2>/dev/null)"
		if [[ "$state" != "running" ]]; then
			echo "env.sh: skip $vm ($state)"
			continue
		fi
		echo "env.sh: virsh save $domain -> $snapdir/${vm}.save"
		virsh -c "$LIBVIRT_URI" save "$domain" "$snapdir/${vm}.save"
		while IFS= read -r disk; do
			[[ -n "$disk" ]] || continue
			echo "env.sh: qemu-img snapshot -c $VAGRANT_SNAPSHOT_NAME $disk"
			while sudo qemu-img snapshot -d "$VAGRANT_SNAPSHOT_NAME" "$disk" >/dev/null 2>&1; do
				:
			done
			sudo qemu-img snapshot -c "$VAGRANT_SNAPSHOT_NAME" "$disk"
		done < <(virsh -c "$LIBVIRT_URI" domblklist "$domain" --details 2>/dev/null |
			awk '$2 == "disk" { print $NF }')
		echo "env.sh: virsh restore $snapdir/${vm}.save"
		virsh -c "$LIBVIRT_URI" restore "$snapdir/${vm}.save"
		saved=$((saved + 1))
	done < <(vagrant_vm_names)

	if ((saved == 0)); then
		echo "env.sh: no running VMs snapshotted"
		return 1
	fi

	echo "env.sh: vagrant snapshot saved ($saved VM(s)) -> $snapdir/"
}

libvirt_restore() {
	local snapdir="$VAGRANT_SNAPSHOT_DIR" savefile vm domain state disk restored

	if [[ ! -d "$snapdir" ]]; then
		echo "env.sh: no vagrant snapshot found (missing $snapdir)" >&2
		return 1
	fi

	for savefile in "$snapdir"/*.save; do
		[[ -f "$savefile" ]] || continue
		vm="$(basename "$savefile" .save)"
		domain="$(libvirt_domain_for "$vm")"
		if [[ -n "$domain" ]]; then
			state="$(virsh -c "$LIBVIRT_URI" domstate "$domain" 2>/dev/null)"
			if [[ "$state" == "running" ]]; then
				echo "env.sh: virsh destroy $domain (running)"
				virsh -c "$LIBVIRT_URI" destroy "$domain" >/dev/null
			fi
		fi
	done

	for savefile in "$snapdir"/*.save; do
		[[ -f "$savefile" ]] || continue
		vm="$(basename "$savefile" .save)"
		domain="$(libvirt_domain_for "$vm")"
		[[ -n "$domain" ]] || continue
		while IFS= read -r disk; do
			[[ -n "$disk" ]] || continue
			echo "env.sh: qemu-img snapshot -a $VAGRANT_SNAPSHOT_NAME $disk"
			sudo qemu-img snapshot -a "$VAGRANT_SNAPSHOT_NAME" "$disk"
		done < <(virsh -c "$LIBVIRT_URI" domblklist "$domain" --details 2>/dev/null |
			awk '$2 == "disk" { print $NF }')
	done

	restored=0

	for savefile in "$snapdir"/*.save; do
		[[ -f "$savefile" ]] || continue
		echo "env.sh: virsh restore $savefile"
		virsh -c "$LIBVIRT_URI" restore "$savefile"
		restored=$((restored + 1))
	done

	if ((restored == 0)); then
		echo "env.sh: no save files in $snapdir" >&2
		return 1
	fi

	echo "env.sh: vagrant restored ($restored VM(s)) from $snapdir/"
}

# vagrant-qemu has no snapshot capability of its own, and the UEFI box rules
# out QEMU's savevm/loadvm (its writable pflash device can't be snapshotted),
# so we snapshot the qcow2 box disks directly.  qemu-img needs an exclusive
# write lock, so the VMs are halted around it.  Disk only, no RAM: a restore
# reboots the guest, same as `vagrant snapshot` on VirtualBox.
qemu_disks() {
	[[ -d .vagrant/machines ]] || return 0
	find .vagrant/machines -type f -path '*/qemu/*' -name 'linked-box*.img' 2>/dev/null | sort
}

qemu_snapshotted_disks() {
	local disk
	while IFS= read -r disk; do
		[[ -n "$disk" ]] || continue
		if qemu-img snapshot -l "$disk" 2>/dev/null |
			awk -v n="$VAGRANT_SNAPSHOT_NAME" '$2 == n { f = 1 } END { exit !f }'; then
			echo "$disk"
		fi
	done < <(qemu_disks)
}

qemu_snapshot() {
	local disks disk count

	disks="$(qemu_disks)"
	if [[ -z "$disks" ]]; then
		echo "env.sh: no qemu disks to snapshot" >&2
		return 1
	fi

	echo "env.sh: vagrant halt (qemu-img needs the disks unlocked)"
	vagrant_halt_parallel

	count=0
	while IFS= read -r disk; do
		echo "env.sh: qemu-img snapshot -c $VAGRANT_SNAPSHOT_NAME $disk"
		while qemu-img snapshot -d "$VAGRANT_SNAPSHOT_NAME" "$disk" >/dev/null 2>&1; do
			:
		done
		qemu-img snapshot -c "$VAGRANT_SNAPSHOT_NAME" "$disk"
		count=$((count + 1))
	done <<<"$disks"

	vagrant_up --parallel --no-provision

	echo "env.sh: vagrant snapshot saved ($count disk(s)) -> $VAGRANT_SNAPSHOT_NAME"
}

qemu_restore() {
	local all_disks disks disk count expected_count

	all_disks="$(qemu_disks)"
	if [[ -z "$all_disks" ]]; then
		echo "env.sh: no qemu disks to snapshot" >&2
		return 1
	fi

	echo "env.sh: vagrant halt (qemu-img needs the disks unlocked)"
	vagrant_halt_parallel

	disks="$(qemu_snapshotted_disks)"
	expected_count=0
	while IFS= read -r disk; do
		[[ -n "$disk" ]] || continue
		expected_count=$((expected_count + 1))
	done <<<"$all_disks"

	count=0
	while IFS= read -r disk; do
		[[ -n "$disk" ]] || continue
		count=$((count + 1))
	done <<<"$disks"
	if ((count != expected_count)); then
		echo "env.sh: snapshot $VAGRANT_SNAPSHOT_NAME is missing disk(s)" >&2
		vagrant_up --parallel --no-provision || true
		return 1
	fi

	count=0
	while IFS= read -r disk; do
		echo "env.sh: qemu-img snapshot -a $VAGRANT_SNAPSHOT_NAME $disk"
		qemu-img snapshot -a "$VAGRANT_SNAPSHOT_NAME" "$disk"
		count=$((count + 1))
	done <<<"$disks"

	vagrant_up --parallel --no-provision

	echo "env.sh: vagrant restored ($count disk(s)) from $VAGRANT_SNAPSHOT_NAME"
}

vagrant_snapshot() {
	require_vagrant
	if [[ "$provider" == "libvirt" ]]; then
		libvirt_snapshot
	elif [[ "$provider" == "qemu" ]]; then
		qemu_snapshot
	else
		echo "env.sh: vagrant snapshot save $VAGRANT_SNAPSHOT_NAME"
		vagrant snapshot delete "$VAGRANT_SNAPSHOT_NAME" >/dev/null 2>&1 || true
		vagrant snapshot save "$VAGRANT_SNAPSHOT_NAME"
	fi
}

vagrant_restore() {
	require_vagrant
	if [[ "$provider" == "libvirt" ]]; then
		libvirt_restore
	elif [[ "$provider" == "qemu" ]]; then
		qemu_restore
	else
		echo "env.sh: vagrant snapshot restore $VAGRANT_SNAPSHOT_NAME"
		vagrant snapshot restore "$VAGRANT_SNAPSHOT_NAME"
	fi

	# TODO(initialed85): because i'm too lazy to build something that polls
	sleep 1
}

#
# commands
#

cmd_up() {
	require_vagrant
	require_provider

	rm -f "$VAGRANT_SNAPSHOT_DIR"/*.save 2>/dev/null || true

	echo "env.sh: bringing up nodes on $platform/$arch via provider=${provider:-<default>}"
	if [[ "$provider" == "qemu" ]]; then
		vagrant_up --parallel
	else
		vagrant_up
	fi

	echo "env.sh: taking initial snapshot"
	cmd_snapshot
}

cmd_down() {
	require_vagrant
	if [[ "$provider" == "qemu" ]]; then
		vagrant destroy -f --parallel
	else
		vagrant destroy -f
	fi
	rm -f "$VAGRANT_SNAPSHOT_DIR"/*.save 2>/dev/null || true
}

cmd_snapshot() {
	vagrant_snapshot
}

cmd_restore() {
	vagrant_restore
	wait_for_nodes
}

cmd_status() {
	require_vagrant
	echo "env.sh: provider=${provider:-<none>} host=$platform/$arch"
	vagrant status
	local n
	for n in $(vagrant_vm_names); do
		if node_ssh_ready "$n"; then
			echo "env.sh: $n ssh ok at $(node_address "$n")"
		else
			echo "env.sh: $n not answering ssh at $(node_address "$n")" >&2
		fi
	done
	[[ -d "$VAGRANT_SNAPSHOT_DIR" ]] && ls -1 "$VAGRANT_SNAPSHOT_DIR"/*.save 2>/dev/null |
		sed 's|.*/||; s|\.save$||; s|^|env.sh: snapshot |' || true
}

cmd_vagrant() {
	require_vagrant
	vagrant "$@"
}

# Wait for ssh to come back on every node.  A restore reboots (or resumes)
# guests, and every test starts by talking to them.
#
# The nodes are addressed by their static private-network address, not by what
# `vagrant ssh-config` says.  vagrant only knows an address while libvirt is
# holding a DHCP lease for the guest, and after a few `virsh save`/`restore`
# cycles the lease database is empty: the guest is running and reachable, but
# vagrant reports it as having no IP and refuses to hand out ssh config.
NODE_SUBNET="192.168.78"

node_address() {
	local n=$1
	echo "${NODE_SUBNET}.1${n#node}"
}

node_key() {
	local n=$1
	ls .vagrant/machines/"$n"/*/private_key 2>/dev/null | head -1
}

node_ssh_opts() {
	local n=$1
	printf '%s' "-i $(node_key "$n") -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2"
}

node_ssh_ready() {
	local n=$1
	[[ -n "$(node_key "$n")" ]] || return 1
	# shellcheck disable=SC2046
	ssh $(node_ssh_opts "$n") "vagrant@$(node_address "$n")" true >/dev/null 2>&1
}

node_ssh() {
	local n=$1
	shift
	# shellcheck disable=SC2046
	ssh $(node_ssh_opts "$n") "vagrant@$(node_address "$n")" "$@"
}

# A guest restored from saved state comes back with its clock stopped where the
# snapshot left it.  Hours of skew is enough for apt to reject Ubuntu's own
# Release file as "not valid yet", which looks exactly like a broken mirror and
# is not one.  The host is NTP-synced, so it is the reference.
sync_clock() {
	local n=$1 out
	if ! out=$(node_ssh "$n" "sudo date -u -s @$(date -u +%s)" 2>&1); then
		echo "env.sh: $n: clock not set: $(tail -1 <<<"$out")" >&2
	fi
}

wait_for_nodes() {
	local n
	for n in $(vagrant_vm_names); do
		for _ in $(seq 90); do
			node_ssh_ready "$n" && break
			sleep 2
		done
		node_ssh_ready "$n" || {
			echo "env.sh: $n never came back" >&2
			return 1
		}
		sync_clock "$n"
		echo "env.sh: $n reachable"
	done
}

usage() {
	awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/,"  "); print; next } { exit }' "$0"
}

sub="${1:-}"
case "$sub" in
up) cmd_up ;;
down) cmd_down ;;
snapshot) cmd_snapshot ;;
restore) cmd_restore ;;
status) cmd_status ;;
vagrant)
	shift
	cmd_vagrant "$@"
	;;
"" | help | -h | --help) usage ;;
*)
	echo "env.sh: unknown command '$sub'" >&2
	usage >&2
	exit 1
	;;
esac

echo -e "\nenv.sh: done."
