#!/bin/bash

set -euo pipefail

# Shared helpers for the tests in test/.  Sourced, not executed.
#
# Everything here talks to the Vagrant cluster over its private network
# (192.168.78.11-13), with the per-machine key vagrant left in .vagrant.
# Node -> node ssh uses the cluster key the Vagrantfile provisions.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NODES=(node1 node2 node3)
NODE_SUBNET="192.168.78"
SPIKE_SRC="test/spike"

failures=0

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

metric() { printf '    %-46s %s\n' "$1" "$2"; }

ok() {
	printf '    \033[32mok\033[0m      %s\n' "$*"
}

bad() {
	printf '    \033[31mFAIL\033[0m    %s\n' "$*"
	failures=$((failures + 1))
}

# check <description> <needle> <file>
check() {
	local what=$1 needle=$2 file=$3
	if grep -qF -- "$needle" "$file"; then
		ok "$what"
	else
		bad "$what (expected '$needle' in $file)"
		tail -20 "$file" | sed 's/^/          | /'
	fi
}

# check_absent <description> <needle> <file>
check_absent() {
	local what=$1 needle=$2 file=$3
	if grep -qF -- "$needle" "$file"; then
		bad "$what"
		grep -F -- "$needle" "$file" | head -5 | sed 's/^/          | /'
	else
		ok "$what"
	fi
}

node_init() {
	local n=$1
	[[ -n "${NODE_PORT[$n]:-}" ]] && return 0

	# The private address is static in the Vagrantfile, so it needs nothing from
	# vagrant or libvirt to know it.  `vagrant ssh-config` can report a running,
	# reachable guest as having no IP once the DHCP lease database goes stale,
	# which is a bad thing for a test run to depend on.
	NODE_HOST[$n]="${NODE_SUBNET}.1${n#node}"
	NODE_PORT[$n]=22
	NODE_USER[$n]=vagrant
	NODE_KEY[$n]="$(ls .vagrant/machines/"$n"/*/private_key 2>/dev/null | head -1)"

	[[ -n "${NODE_KEY[$n]}" ]] || {
		echo "test: no ssh key for $n, is the cluster up?" >&2
		exit 1
	}
}

declare -A NODE_HOST NODE_PORT NODE_USER NODE_KEY

ssh_opts() {
	local n=$1
	node_init "$n"
	printf '%s' "-i ${NODE_KEY[$n]} -p ${NODE_PORT[$n]} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
}

# node_ssh <node> <command...>
node_ssh() {
	local n=$1
	shift
	node_init "$n"
	# ssh_opts runs in a command substitution, so the node has to be initialised
	# here for the expansions on this line to see the parent's values.
	# shellcheck disable=SC2046
	ssh $(ssh_opts "$n") "${NODE_USER[$n]}@${NODE_HOST[$n]}" "$@"
}

# node_put <node> <local-src> <remote-dst>  (rsync, --delete so a node never
# keeps stale spike files that would change the cache key).  A directory's
# *contents* are copied, always, so the remote path means the same thing as
# the local one whether or not it already exists.
node_put() {
	local n=$1 src=$2 dst=$3
	node_init "$n"
	[[ -d "$src" && "$src" != */ ]] && src="$src/"
	# shellcheck disable=SC2046
	rsync -a --delete --human-readable -e "ssh $(ssh_opts "$n")" "$src" "${NODE_USER[$n]}@${NODE_HOST[$n]}:$dst"
}

# node_bash <node> <script>  - run a bash snippet as the node user
node_bash() {
	local n=$1 script=$2
	node_ssh "$n" "bash -s" <<<"$script"
}

require_cluster() {
	local n
	say "preflight"
	for n in "${NODES[@]}"; do
		if node_ssh "$n" true >/dev/null 2>&1; then
			ok "$n reachable"
		else
			bad "$n unreachable - run ./env.sh up (or ./env.sh restore)"
			exit 1
		fi
	done

	for n in "${NODES[@]}"; do
		if node_ssh "$n" docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
			ok "$n docker $(node_ssh "$n" docker version --format '{{.Server.Version}}')"
		else
			bad "$n docker daemon not usable by $(node_ssh "$n" id -un)"
			exit 1
		fi
	done

	# node -> node over the private network, with the cluster key.  This is the
	# path ddcache serve would use.
	local a b
	for a in "${NODES[@]}"; do
		b=node2
		[[ "$a" == "$b" ]] && b=node3
		if node_ssh "$a" "ssh -o ConnectTimeout=5 $b true" >/dev/null 2>&1; then
			ok "$a -> $b passwordless ssh"
		else
			bad "$a -> $b ssh over the private network"
			exit 1
		fi
	done

	# The host's apt proxy is optional, but whatever we decide has to be the
	# same value on every node or it changes the cache key between them.
	if node_ssh node1 'curl -sf -m 3 -o /dev/null http://apt-cache:3142/archive.ubuntu.com/ 2>/dev/null || curl -sf -m 3 -o /dev/null http://apt-cache:3142/' >/dev/null 2>&1; then
		APT_PROXY=http://apt-cache:3142
	else
		APT_PROXY=
	fi
	metric "apt proxy" "${APT_PROXY:-<none>, direct}"

	# A guest restored from saved state wakes up with its clock where the snapshot
	# left it, and apt then rejects Ubuntu's own Release file as "not valid yet".
	# That failure looks exactly like a broken mirror, so name it before a build
	# spends 45s discovering it.
	local worst=0 skew
	worst=0
	for n in "${NODES[@]}"; do
		skew=$(( $(date +%s) - $(node_bash "$n" 'date +%s') ))
		if ((skew < 0)); then skew=-skew; fi
		if ((skew > worst)); then worst=$skew; fi
	done
	if ((worst <= 120)); then
		ok "clocks within ${worst}s of the host"
	else
		bad "clocks ${worst}s off the host - ./env.sh restore steps them, otherwise apt fails 'not valid yet'"
	fi
}

# A cold builder on the node doing the "warm" build: otherwise a cache hit
# could be the node's own leftover state rather than what we replicated.
prune_builder() {
	local n=$1
	node_ssh "$n" docker builder prune -af >/dev/null
	node_bash "$n" 'docker image rm -f $(docker images -q "ddcache/spike") >/dev/null 2>&1 || true'
}

# build <node> <tag> <cache-from> <cache-to> <logfile>
#
# Runs the spike build on a node with --progress plain so we can count CACHED
# steps in the log, and leaves the wall-clock seconds in SECONDS_BUILD.
build() {
	local n=$1 tag=$2 cache_from=$3 cache_to=$4 log=$5
	local remote="set -e; cd spike && docker build --progress plain --build-arg APT_PROXY='${APT_PROXY:-}' -t ddcache/spike:${tag}"
	local start end

	[[ -n "$cache_from" ]] && remote+=" --cache-from '${cache_from}'"
	[[ -n "$cache_to" ]] && remote+=" --cache-to '${cache_to}'"
	remote+=" . 2>&1"

	start=$(date +%s)
	node_bash "$n" "$remote" >"$log" 2>&1
	end=$(date +%s)

	SECONDS_BUILD=$((end - start))

	grep -q 'naming to' "$log" || {
		echo "test: build on $n did not tag the image, see $log:" >&2
		tail -30 "$log" >&2
		return 1
	}
}

# image_digest <node> <tag> : run the image that node built and take the
# digest it prints.  BuildKit doesn't replay the output of a cached step, so
# this - not the build log - is how we know both nodes made the same thing.
image_digest() {
	local n=$1 tag=$2
	node_ssh "$n" docker run --rm "ddcache/spike:${tag}" ddcheck 5000 |
		grep -o 'ddcheck [0-9a-f]\{16\}'
}

cached_steps() {
	grep -c CACHED "$1" 2>/dev/null || true
}

built_steps() {
	grep -cE 'DONE [0-9.]+s' "$1" 2>/dev/null || true
}

# The last line of the build log's ddcheck output, i.e. the binary actually
# ran inside the image we just built.  Only present on builds that really
# compiled - a cached step's output is never replayed.
build_digest() {
	grep -o 'ddcheck [0-9a-f]\{16\}' "$1" | tail -1
}

report() {
	echo
	if ((failures == 0)); then
		printf '\033[32mall checks passed\033[0m\n'
	else
		printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
	fi
	return "$failures"
}

# Logs are the only evidence a measurement is what it claims to be, so they
# survive a failed run and go with the pass.
preserve_logs_on_failure() {
	trap "rc=\$?; if ((rc)); then printf 'test: logs kept in $1\n' >&2; else rm -rf '$1'; fi" EXIT
}
