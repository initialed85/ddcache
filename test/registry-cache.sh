#!/bin/bash

# The second commit.  This is the number the directory copy can't get to.
#
#   master m0 -> m1        one line of repo code: how many bytes does the
#                          registry grow by, and how many does a node have to
#                          pull to get up to date?
#   flight/v1.25 cut from m0 with its own (older) build deps, built once, then
#   left alone while master moves - and much later a security fix lands on it.
#   Two ways to build that fix, and the difference between them is the whole
#   argument for tracking commits instead of a "latest" tag:
#
#     --cache-from the branch's own ref    dependency layer hits
#     --cache-from master's newest ref     dependency layer was never there
#
# Git is a scratch repo on the host; each node gets a commit exported with
# `git archive`, exactly as CI would.  Only the cache is ddcache's problem.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

LOG_DIR="$(mktemp -d /tmp/ddcache-test.XXXXXX)"
preserve_logs_on_failure "$LOG_DIR"

require_cluster

for n in node1 node2; do
	ensure_insecure_registries "$n"
	ensure_registry "$n"
done

node_bash node1 "rm -rf $SRC_DIR /home/vagrant/spike /home/vagrant/cache"
node_bash node2 "rm -rf $SRC_DIR /home/vagrant/spike /home/vagrant/cache"
prune_builder node1
prune_builder node2

mkrepo

M0=$(cd "$REPO_TMP" && git log --format=%h -1)
R0=$(registry_bytes node1)
metric "master m0" "$M0"
metric "node1 registry" "$R0 bytes"

say "m0: node1 builds master from nothing, exports to a ref named after the commit"
checkout_node "$M0" node1
build_from_registry node1 "m0" "" "$LOG_DIR/n1-m0.log" "$(cache_ref node1 main "$M0")"
T_M0=$SECONDS_BUILD
metric "wall" "${T_M0}s"
metric "cached steps" "$(cached_steps "$LOG_DIR/n1-m0.log") (expect 0)"
R_AFTER_M0=$(registry_bytes node1)
metric "registry after m0" "$R_AFTER_M0 bytes"

say "m0: node2 replicates the ref and builds it"
replicate node1 node2 "cache-main-$M0"
WIRE_M0=$WIRE_BYTES
prune_builder node2
checkout_node "$M0" node2
build_from_registry node2 "m0" "$(cache_ref node2 main "$M0")" "$LOG_DIR/n2-m0.log"
metric "node2 wall" "${SECONDS_BUILD}s (node1 cold: ${T_M0}s)"
metric "cached steps" "$(cached_steps "$LOG_DIR/n2-m0.log")"

# One line of repo code, on master.
M1=$(commit_change src/mu3.c '0,/return a + b + c;/s//return a + b + c + 1.0;/' \
	"master: nudge mu_3_0")
metric "master m1" "$M1 (1 file, $(cd "$REPO_TMP" && git diff --shortstat HEAD~1 | tr -d '\n'))"

say "m1: node1 builds the new commit against m0's ref"
checkout_node "$M1" node1
build_from_registry node1 "m1" "$(cache_ref node1 main "$M0")" "$LOG_DIR/n1-m1.log" \
	"$(cache_ref node1 main "$M1")"
T_M1=$SECONDS_BUILD
STEPS_M1=$(cached_steps "$LOG_DIR/n1-m1.log")
REG_M1=$(registry_bytes node1)
DELTA=$((REG_M1 - R_AFTER_M0))
metric "wall" "${T_M1}s"
metric "cached steps" "$STEPS_M1"
metric "registry after m1" "$REG_M1 bytes"
metric "registry grew by" "$DELTA bytes"

((STEPS_M1 >= 2)) && ok "m1 reused m0's dependency layer" ||
	bad "m1 only got $STEPS_M1 cached steps, the dependency layer should have survived"

say "m1: node2 pulls up to date"
replicate node1 node2 "cache-main-$M1"
metric "for comparison, m0 cost" "$WIRE_M0 bytes"
awk -v a="$WIRE_M0" -v b="$WIRE_BYTES" 'BEGIN { printf "    %-46s %.0fx less than the first copy\n", "second commit", a / (b > 0 ? b : 1) }'

((WIRE_BYTES < WIRE_M0 / 10)) &&
	ok "the second commit cost ${WIRE_BYTES} bytes against ${WIRE_M0} for the first" ||
	bad "second replication was ${WIRE_BYTES} bytes, expected a fraction of ${WIRE_M0}"

prune_builder node2
checkout_node "$M1" node2
build_from_registry node2 "m1" "$(cache_ref node2 main "$M1")" "$LOG_DIR/n2-m1.log"
metric "node2 wall" "${SECONDS_BUILD}s"
metric "node2 cached steps" "$(cached_steps "$LOG_DIR/n2-m1.log")"
[[ "$(image_digest node1 m1)" == "$(image_digest node2 m1)" ]] &&
	ok "both nodes on m1 ran out the same binary" || bad "m1 digests differ between nodes"

#
# The old branch.
#
# Cut from m0, and its build dependencies are different from master's - which
# is what four months of not updating a Dockerfile looks like.  It gets built
# once, here, and then nothing touches it.
#
F0_BRANCH=flight/v1.25
F0_BASE=$M0
branch_at "$F0_BRANCH" "$F0_BASE" >/dev/null
metric "flight/v1.25" "cut at $F0_BASE"
say "flight/v1.25: the branch's own dependency layer"
F0SHA=$(
	cd "$REPO_TMP"
	git checkout -q "$F0_BRANCH"
	sed -i 's|ca-certificates;|ca-certificates pkg-config;|' Dockerfile
	git diff --quiet && { echo "the branch deps edit did not apply" >&2; exit 1; }
	git commit -qam "flight/v1.25: this branch still needs pkg-config to build"
	git log --format=%h -1
)
metric "flight f0" "$F0SHA"
[[ "$(cd "$REPO_TMP" && git diff --name-only "$M0" "$F0SHA" | tr '\n' ' ')" == "Dockerfile " ]] &&
	ok "the branch differs from master in Dockerfile only" ||
	bad "expected only Dockerfile to differ between master and the branch"

checkout_node "$F0SHA" node1
build_from_registry node1 "f0" "$(cache_ref node1 main "$M1")" "$LOG_DIR/n1-f0.log" \
	"$(cache_ref node1 "${F0_BRANCH}" "$F0SHA")"
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$(cached_steps "$LOG_DIR/n1-f0.log") (expect 0-1, deps changed)"
metric "registry after f0" "$(registry_bytes node1) bytes"
metric "tags now" "$(registry_tags node1)"

# Much later, on the node that has never seen this branch, a security fix.
say "flight/v1.25: a security fix lands months later, built on node2"
F1=$(
	cd "$REPO_TMP"
	sed -i '0,/return a + b + c;/s//return a + b + c + 2.5;/' src/mu5.c
	git diff --quiet && { echo "the security fix edit did not apply" >&2; exit 1; }
	git commit -qam "flight/v1.25: fix the constant in mu_5_0"
	git log --format=%h -1
)
metric "flight f1" "$F1"
[[ "$(cd "$REPO_TMP" && git diff --name-only "$F0SHA" "$F1" | tr '\n' ' ')" == "src/mu5.c " ]] &&
	ok "the fix touches one source file" || bad "the fix changed more than src/mu5.c"
checkout_node "$F1" node2

R_BEFORE=$(rx_bytes node2)
build_from_registry node2 "f1" "$(cache_ref node1 "${F0_BRANCH}" "$F0SHA")" "$LOG_DIR/n2-f1-branch.log"
T_F1_BRANCH=$SECONDS_BUILD
STEPS_F1_BRANCH=$(cached_steps "$LOG_DIR/n2-f1-branch.log")
PULLED_F1=$(( $(rx_bytes node2) - R_BEFORE ))
metric "against the branch ref" "${T_F1_BRANCH}s, ${STEPS_F1_BRANCH} cached steps, ${PULLED_F1} bytes pulled"

# The same build, pointed at what master left behind: the naive "the newest
# cache" that most CI cache keys actually are.
prune_builder node2
R_BEFORE=$(rx_bytes node2)
build_from_registry node2 "f1" "$(cache_ref node1 main "$M1")" "$LOG_DIR/n2-f1-master.log"
T_F1_MASTER=$SECONDS_BUILD
STEPS_F1_MASTER=$(cached_steps "$LOG_DIR/n2-f1-master.log")
PULLED_F1_MASTER=$(( $(rx_bytes node2) - R_BEFORE ))
metric "against master's newest" "${T_F1_MASTER}s, ${STEPS_F1_MASTER} cached steps, ${PULLED_F1_MASTER} bytes pulled"

[[ "$(image_digest node1 f0)" != "$(image_digest node2 f1)" ]] &&
	ok "the fix changed what the binary prints" || bad "f1 is indistinguishable from f0"
metric "f1 digest" "$(image_digest node2 f1)"

((STEPS_F1_BRANCH > STEPS_F1_MASTER)) &&
	ok "the branch ref was worth $((STEPS_F1_BRANCH - STEPS_F1_MASTER)) more cached steps" ||
	bad "pointing at the branch's own ref bought nothing ($STEPS_F1_BRANCH vs $STEPS_F1_MASTER)"

((T_F1_BRANCH < T_F1_MASTER)) &&
	ok "${F1}: ${T_F1_BRANCH}s with the branch ref, ${T_F1_MASTER}s with master's" ||
	bad "the branch ref was not faster (${T_F1_BRANCH}s vs ${T_F1_MASTER}s)"

cat <<EOF

  Summary

    master m0 -> m1 is one line of repo code.  It grew node1's registry by
    ${DELTA} bytes, and brought node2 up to date for ${WIRE_BYTES} bytes on the
    wire - against ${WIRE_M0} for the first commit, and against the 147 MB a
    directory copy of this same cache costs for every commit however small the
    change (file-cache.sh).  Content addressing does the dedup, and the ref is
    the index.

    The old branch is the interesting part.  node2 had never seen flight/v1.25,
    and the fix was written four months after anyone built it.  Pointed at the
    branch's own ref it built in ${T_F1_BRANCH}s with ${STEPS_F1_BRANCH} cached
    steps; pointed at master's newest ref - which is what a "latest" cache key
    gets you - the same build took ${T_F1_MASTER}s with ${STEPS_F1_MASTER}
    cached steps, because the dependency layer on that branch is not in master's
    cache and never will be.  node2 had to pull ${PULLED_F1} bytes to make that
    happen, which is the price of not having replicated the branch ref in
    advance; replication is about where those bytes come from and when, not
    about whether the hit exists.

    So the mapping is: a cache ref per branch and commit, kept as long as the
    branch is buildable, and a build asks for its branch's ref by name.  That
    is a git question, not a Docker one, and it is why ddcache wants the commit
    graph rather than a bucket of files.

    Two things this does NOT measure: whether a registry that keeps every
    branch ref forever is a storage plan, and what happens when two nodes push
    the same ref at the same time.  registry:2 has no garbage collection
    enabled here, so the old-branch refs cost nothing to keep right now, which
    is exactly the situation a real deployment would not be in.

EOF

rm -rf "$REPO_TMP"
report
