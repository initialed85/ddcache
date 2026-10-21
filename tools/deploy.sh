#!/bin/bash
set -euo pipefail

#
#  Host side: put the node tools, a registry, and a repo to play with on every
#  node, so the cluster can be driven by hand.
#
#  usage:
#    ./tools/deploy.sh            # idempotent
#    ./tools/deploy.sh --reset    # also wipe the playground repos
#
#  Run it after ./env.sh restore: a restore rolls the disks back and takes the
#  tools, the registries and the repos with it.  It reuses the test harness to
#  talk to the nodes, so the addressing is the same one the tests use.
#
#  What it leaves you:
#    ssh ddn1                             # 192.168.78.11, key under .vagrant/machines
#    cd ~/repo && hack && git commit
#    ~/ddcache/docker.sh .                # build here, ref named after the commit,
#                                         # replicated to node2 and node3
#    on node2: ~/ddcache/reconcile.sh --once
#    ~/ddcache/docker.sh --local .        # the asynchronous shape: the ref reaches
#                                         # the others only because a reconciler is
#                                         # running and noticed it
#
#  node1's ~/repo is the origin and the other two cloned it, with the same
#  shape the tests measured: master with two commits, and flight/v1.25 cut from
#  the first one carrying its own dependency layer.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/test/lib.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/test/registry-lib.sh"

reset=0
if [[ "${1:-}" == --reset ]]; then
	reset=1
fi

TOOLS=/home/vagrant/ddcache
REPO=/home/vagrant/repo

require_cluster

say "registries and tools"
for n in "${NODES[@]}"; do
	ensure_insecure_registries "$n"
	ensure_registry "$n"

	node_put "$n" "$REPO_ROOT/tools" "$TOOLS"
	node_bash "$n" "chmod +x $TOOLS/*.sh"
done

# The node list and the one build arg that has to be identical everywhere, so a
# per-node value can't quietly change the cache key between nodes.
list=""
for n in "${NODES[@]}"; do
	node_init "$n"
	list+="${NODE_HOST[$n]}"$'\n'
done
origin_ip=$(sed -n 1p <<<"$list")

for n in "${NODES[@]}"; do
	node_ssh "$n" "cat >$TOOLS/nodes" <<<"$list"
	node_ssh "$n" "cat >$TOOLS/env" <<<"APT_PROXY=${APT_PROXY:-}"
done

cat >"$REPO_ROOT/.vagrant/ssh_config" <<EOF
Host ddn1 ddn2 ddn3
    User vagrant
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
for n in "${NODES[@]}"; do
	node_init "$n"
	cat >>"$REPO_ROOT/.vagrant/ssh_config" <<EOF
Host ddn${n#node}
    HostName ${NODE_HOST[$n]}
    IdentityFile $REPO_ROOT/.vagrant/machines/$n/libvirt/private_key
EOF
done

say "playground repos"
if ((reset)); then
	for n in "${NODES[@]}"; do node_bash "$n" "rm -rf $REPO"; done
fi

if node_bash node1 "test -d $REPO/.git" >/dev/null 2>&1; then
	ok "node1:$REPO already there, left alone (--reset to rebuild)"
else
	node_put node1 "$REPO_ROOT/test/spike" "$REPO"
	node_bash node1 "
		set -e
		cd $REPO
		git init -q .
		git config user.email spike@ddcache.invalid
		git config user.name 'ddcache spike'
		git add -A
		git commit -qm 'import spike'
		sed -i '0,/return a + b + c;/s//return a + b + c + 1.0;/' src/mu3.c
		git commit -qam 'master: nudge mu_3_0'
		git branch -q flight/v1.25 HEAD~1
		git checkout -q flight/v1.25
		sed -i 's|ca-certificates;|ca-certificates pkg-config;|' Dockerfile
		git commit -qam 'flight/v1.25: this branch still needs pkg-config to build'
		git checkout -q master
		git log --oneline --decorate --all | sed 's/^/    node1 repo: /'
	"

	for n in node2 node3; do
		node_bash "$n" "
			set -e
			git clone -q vagrant@${origin_ip}:$REPO $REPO
			git -C $REPO log --oneline --all | head -2 | sed 's/^/    $n repo: /'
		" >/dev/null
		ok "$n cloned node1's repo (git fetch vagrant@${origin_ip}:$REPO to see new commits)"
	done
fi

cat <<EOF

  Try it:
    ssh -F .vagrant/ssh_config ddn1
    cd ~/repo && git checkout flight/v1.25
    ~/ddcache/docker.sh --print .      # what it would build, from which refs
    ~/ddcache/docker.sh .              # and then do it
    ssh -F .vagrant/ssh_config ddn2 '~/ddcache/reconcile.sh --once --verbose'
EOF
