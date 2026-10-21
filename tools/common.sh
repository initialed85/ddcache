#!/bin/bash

# Shared bits for the scripts in tools/ that run *on* a node as vagrant.
# Sourced, not executed.
#
# What a node needs to know to be useful: which addresses exist, what its
# registry holds, and what a ref should be called.  Everything else is a curl.

REG_PORT=5000
REG_REPO=spike
NODES_FILE="${NODES_FILE:-$HOME/ddcache/nodes}"

# shellcheck disable=SC1091
if [[ -r "$HOME/ddcache/env" ]]; then
	source "$HOME/ddcache/env"
fi

die() {
	echo "$(basename "$0"): $*" >&2
	exit 1
}

self_ip() {
	hostname -I | tr ' ' '\n' | grep -m1 '^192\.168\.78\.' ||
		die "this is not a ddcache node (no 192.168.78.x address)"
}

all_nodes() {
	[[ -r "$NODES_FILE" ]] || die "no $NODES_FILE - run ./tools/deploy.sh on the host"
	tr -d ' \t\r' <"$NODES_FILE" | grep -v '^$'
}

peers() {
	all_nodes | grep -vx "$(self_ip)"
}

reg() { echo "$1:$REG_PORT"; }

# branch_slug <context> : flight/v1.25 -> flight-v1.25, the only form a tag can
# take.  Refs are named cache-<branch>-<sha>; the branch is what a node looks up
# when it is asked to build something old, the commit is what makes it its own.
branch_slug() {
	git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null | tr / -
}

ref_tag() {
	local b sha
	b=$(branch_slug "$1")
	[[ -n "$b" && "$b" != HEAD ]] || die "$1 is not on a branch; cache refs are named after a branch and a commit"
	sha=$(git -C "$1" rev-parse --short HEAD)
	echo "cache-${b}-${sha}"
}

# tags_on <ip> : the refs that node's registry will serve.  An empty answer is a
# node with nothing, or a node that isn't up; the reconciler treats them the same.
tags_on() {
	curl -sf --connect-timeout 2 "http://$(reg "$1")/v2/$REG_REPO/tags/list" |
		jq -r '.tags // [] | .[]' 2>/dev/null || true
}

has_tag_on() {
	tags_on "$1" | grep -qx -- "$2"
}

# inventory : every "ip tag" pair in the cluster, so a build can be pointed at the
# node that actually holds the ref it wants.
inventory() {
	local n t
	for n in $(all_nodes); do
		while read -r t; do
			[[ -n "$t" ]] && echo "$n $t"
		done < <(tags_on "$n")
	done
}

# ends_with <suffix> : the refs for a given commit.  Tags are short-sha suffixed,
# so this is endswith rather than a substring match.
matching() {
	local inv=$1 suffix="-$2"
	awk -v s="$suffix" 'index($2, s) == length($2) - length(s) + 1 { print }' <<<"$inv"
}

# net_bytes <rx|tx> [dev] : what the kernel counted, on one interface if you name
# it.  The registry does not count what it served and skopeo's log says
# "Copying blob" whether or not the blob was already there, so the only honest
# number for "what did this replication cost" is the one off the interface counters.
#
# Field order after the colon becomes a space: iface, rx bytes..multicast (8),
# tx bytes..compressed (8).  Names that start in column 1 (docker0) have to be
# handled the same as the indented ones, hence the strip rather than a field split.
net_bytes() {
	awk -v f="$1" -v d="${2:-}" '
		{ sub(/^[ \t]+/, ""); gsub(/:/, " ") }
		/^[a-z0-9]/ { if (d && $1 != d) next
		               if ($1 == "lo") next
		               s += (f == "rx" ? $2 : $10) }
		END { print s + 0 }' /proc/net/dev
}

# dev_for <ip> : the interface that reaches it, so a build pulling packages over
# eth1 does not get billed for it when we are measuring a replication on eth0.
dev_for() {
	ip -o route get "$1" 2>/dev/null |
		awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

human() {
	numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "$1 B"
}

# copy_ref <src-ip> <dst-ip> <tag> : the blob-level copy.  skopeo asks the
# destination which blobs it already has and sends the rest, so repeating this for
# a ref that is already there costs a few hundred milliseconds and no bytes.  That
# is what makes "just do it again on a timer" a design rather than a workaround.
#
# LAYERS is what skopeo looked at, BYTES_MOVED what crossed the wire here - the
# bigger of the two counters, since a copy run by the puller is receive-heavy and
# one run by the pusher is send-heavy, and both are measuring the same transfer.
LAYERS=0
BYTES_MOVED=0
COPY_SECONDS=0
copy_ref() {
	local src=$1 dst=$2 tag=$3 out start dev peer rx0 tx0 rx1 tx1

	# Measure the interface that faces the other end: asking for the route to this
	# node's own address answers "lo", which is true and useless.
	peer=$dst
	if [[ "$src" != "$(self_ip)" ]]; then peer=$src; fi
	dev=$(dev_for "$peer")
	start=$(date +%s)
	rx0=$(net_bytes rx "$dev")
	tx0=$(net_bytes tx "$dev")
	out=$(skopeo copy --all --preserve-digests \
		--src-tls-verify=false --dest-tls-verify=false \
		"docker://$(reg "$src")/$REG_REPO:$tag" \
		"docker://$(reg "$dst")/$REG_REPO:$tag" 2>&1) || {
		echo "$out" >&2
		return 1
	}
	rx1=$(net_bytes rx "$dev")
	tx1=$(net_bytes tx "$dev")

	LAYERS=$(grep -c 'Copying blob' <<<"$out" || true)
	BYTES_MOVED=$((rx1 - rx0 > tx1 - tx0 ? rx1 - rx0 : tx1 - tx0))
	COPY_SECONDS=$(($(date +%s) - start))
}
