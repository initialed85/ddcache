#!/bin/bash

# The file-based cache transfer from the README, measured properly:
#
#   node1 builds            -> exports a BuildKit cache directory
#   node1 -> node2 scp      -> the "dumb" replication
#   node2 builds            -> does it get hits?
#   node1 builds a new commit-> how many *new* bytes are there, and how many
#                              bytes do we have to copy to move them?
#
# Everything runs against the Vagrant cluster and node2's own builder is
# pruned before its "warm" build, so a hit there can only have come from the
# replicated directory.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG_DIR="$(mktemp -d /tmp/ddcache-test.XXXXXX)"
trap 'rm -rf "$LOG_DIR"' EXIT

CACHE_ARGS="mode=max,compression=zstd,force-compression=true"
SRC=/home/vagrant/spike
DST=/home/vagrant/cache

# bytes_new <older-commit> <newer-commit> : the blobs in the newer export that
# the older one doesn't have.  Blob files are named by digest, so a path that
# is missing from the previous commit is genuinely new data.
bytes_new() {
	local old=$1 new=$2
	node_bash node1 "
		cd $DST
		comm -13 <(cd $old && find . -type f | sort) <(cd $new && find . -type f | sort) |
			while read -r f; do stat -c %s \"$new/\$f\"; done | awk '{ s += \$1 } END { print s+0 }'
	"
}

cache_size() {
	node_bash node1 "du -sb $DST/$1 | cut -f1"
}

file_count() {
	node_bash node1 "find $DST/$1 -type f | wc -l"
}

# replicate <commit> : the plain directory copy, node1 -> node2 over the
# private network.  Leaves bytes moved and seconds taken in $TRANSFERRED /
# $TRANSFER_SECONDS.
replicate() {
	local commit=$1 out start end

	say "replicate $commit node1 -> node2 (directory copy)"
	start=$(date +%s)
	out=$(node_bash node1 "
		set -e
		mkdir -p $DST
		rsync -a --stats -e 'ssh -o ConnectTimeout=5' \
			$DST/$commit node2:$DST/ 2>&1
	")
	end=$(date +%s)
	TRANSFER_SECONDS=$((end - start))
	TRANSFERRED=$(sed -n 's/^Literal data: \([0-9,]*\) bytes/\1/p' <<<"$out" | tr -d ,)
	printf '%s\n' "$out" | grep -E '^(Number of files:|Literal data:|Matched data:|speedup)' |
		sed 's/^/    /'
	metric "wall" "${TRANSFER_SECONDS}s"
}

require_cluster

node_bash node1 "rm -rf $DST && mkdir -p $DST"
node_bash node2 "rm -rf $DST"
prune_builder node1
prune_builder node2

node_put node1 "$SPIKE_SRC" spike
node_put node2 "$SPIKE_SRC" spike

say "commit 0: cold build on node1"
build node1 c0 "" "type=local,dest=$DST/c0,$CACHE_ARGS" "$LOG_DIR/n1-c0.log"
T_N1_COLD=$SECONDS_BUILD
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$(cached_steps "$LOG_DIR/n1-c0.log") (expect 0)"
metric "export size" "$(cache_size c0) bytes in $(file_count c0) files"
D_C0=$(image_digest node1 c0)
metric "digest" "$D_C0"

[[ "$(cached_steps "$LOG_DIR/n1-c0.log")" == "0" ]] &&
	ok "cold build had no local hits" || bad "cold build had hits, node1 was not clean"

replicate c0
node_ssh node2 "du -sb $DST/c0 | cut -f1" | { read -r n; metric "on node2" "$n bytes"; }

say "commit 0: warm build on node2 from the replicated directory"
prune_builder node2
build node2 c0 "type=local,src=$DST/c0" "" "$LOG_DIR/n2-c0.log"
T_N2_WARM0=$SECONDS_BUILD
STEPS=$(cached_steps "$LOG_DIR/n2-c0.log")
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$STEPS"
D_C0_NODE2=$(image_digest node2 c0)
metric "digest" "$D_C0_NODE2"

((SECONDS_BUILD < T_N1_COLD / 2)) &&
	ok "node2 built commit 0 in ${T_N2_WARM0}s against node1's ${T_N1_COLD}s" ||
	bad "node2 was not much faster than node1 (${T_N2_WARM0}s vs ${T_N1_COLD}s)"

[[ "$STEPS" -ge 3 ]] &&
	ok "$STEPS steps came from node1's cache" ||
	bad "only $STEPS steps cached, expected the whole build"

[[ "$D_C0" == "$D_C0_NODE2" ]] &&
	ok "node2 produced the same binary as node1" ||
	bad "digests differ between nodes ($D_C0 vs $D_C0_NODE2)"

# One changed line of repo code, which is what a commit actually is: the
# dependency layer stays valid, the compile does not.
say "commit 1: one line of repo code changes on node1"
node_bash node1 "
	set -e
	sed -i '0,/return a + b + c;/s//return a + b + c + 1.0;/' $SRC/src/mu3.c
"
CHANGED=$(node_bash node1 "grep -c 'return a + b + c + 1.0;' $SRC/src/mu3.c")
[[ "$CHANGED" -ge 1 ]] &&
	ok "$CHANGED line of src/mu3.c rewritten" ||
	bad "the commit-1 edit did not apply, the rest of this test is meaningless"

# Both nodes are assumed to have the same commit checked out - that's git's
# job, not ddcache's.  Rsync stands in for `git fetch && checkout` so the only
# thing under test is the cache.
node_bash node1 "rsync -a --delete -e 'ssh -o ConnectTimeout=5' $SRC/ node2:$SRC/"
build node1 c1 "" "type=local,dest=$DST/c1,$CACHE_ARGS" "$LOG_DIR/n1-c1.log"
T_N1_C1=$SECONDS_BUILD
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$(cached_steps "$LOG_DIR/n1-c1.log")"
NEW=$(bytes_new c0 c1)
metric "new blobs in c1" "$NEW bytes"
metric "export c1 total" "$(cache_size c1) bytes in $(file_count c1) files"

[[ "$(cached_steps "$LOG_DIR/n1-c1.log")" -ge 2 ]] &&
	ok "dependency layer survived the new commit" ||
	bad "dependency layer missed on a one-line change"

replicate c1
SIZE_C1=$(cache_size c1)
metric "new data" "$NEW bytes"
metric "copied over the wire" "$TRANSFERRED bytes"
metric "export c1 on disk" "$SIZE_C1 bytes"
awk -v t="$TRANSFERRED" -v n="$NEW" \
	'BEGIN { printf "    %-46s %.0fx\n", "amplification (copied / new)", t / (n > 0 ? n : 1) }'

say "commit 1: warm build on node2 from the replicated directory"
prune_builder node2
build node2 c1 "type=local,src=$DST/c1" "" "$LOG_DIR/n2-c1.log"
T_N2_WARM1=$SECONDS_BUILD
STEPS1=$(cached_steps "$LOG_DIR/n2-c1.log")
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$STEPS1"
D_C1=$(image_digest node2 c1)
metric "digest" "$D_C1 (was $D_C0)"

[[ "$STEPS1" -ge 4 ]] &&
	ok "commit 1 on node2 reused the compile node1 had already done ($STEPS1 cached steps)" ||
	bad "commit 1 on node2 only got $STEPS1 cached steps"

((T_N2_WARM1 < T_N1_COLD)) &&
	ok "commit 1 on node2: ${T_N2_WARM1}s against a ${T_N1_COLD}s cold build" ||
	bad "commit 1 on node2 was no faster than cold (${T_N2_WARM1}s)"

[[ "$(image_digest node1 c1)" == "$D_C1" ]] &&
	ok "node2 reproduced commit 1 from node1's cache" ||
	bad "commit 1 digest differs between nodes"

cat <<EOF

  Summary

    The mechanism works.  Commit 0 took ${T_N1_COLD}s on node1 from nothing and
    ${T_N2_WARM0}s on node2 off a replicated directory, and both nodes ran out
    the same digest.  Commit 1 - one line in one source file - cost ${NEW} bytes
    of new blobs, and node2 still only took ${T_N2_WARM1}s.

    Moving commit 1 to node2 put ${TRANSFERRED} bytes on the wire to move ${NEW}
    bytes of new data, in an export that is ${SIZE_C1} bytes all by itself.  So
    each commit costs a full copy of the cache again, on the wire and on disk,
    and neither scales with the change.  Nothing in the directory layout lets a
    node say "I already have c0, send me the rest", and nothing lets it ask for
    one blob by digest.  That is what the registry branch is for.

EOF

report
