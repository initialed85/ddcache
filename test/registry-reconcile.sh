#!/bin/bash
set -euo pipefail

#
#  The node tools, driven the way you would drive them by hand: docker.sh names a
#  ref for the commit and builds it, reconcile.sh moves it to the other nodes
#  because it is standing there and notices it is missing.
#
#  usage: ./test.sh spike/registry-reconcile
#
#  This is the asynchronous shape.  node1 never pushes to node2: it writes to its
#  own registry with --local, and node2's reconciler pulls.  The test asserts the
#  three things that design depends on: the ref arrives on its own, only the delta
#  arrives, and nothing arrives twice.
#

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

TOOLS=/home/vagrant/ddcache
REPO=/home/vagrant/repo
LOG_DIR="$REPO_ROOT/logs/$(basename "$0" .sh)-$$"
mkdir -p "$LOG_DIR"
preserve_logs_on_failure "$LOG_DIR"

say "deploy"
require_cluster
deploy_tools
metric "tools on nodes" "$TOOLS ($(node_bash node1 "ls $TOOLS | tr '\n' ' '"))"

say "a repo, on node1, with the shape the tests measured"
node_bash node1 "rm -rf $REPO"
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
"
M0=$(node_bash node1 "cd $REPO && git rev-parse --short HEAD")
node_bash node2 "rm -rf $REPO && git clone -q vagrant@${NODE_HOST[node1]}:$REPO $REPO && git -C $REPO log --oneline -1" | sed 's/^/      /'

say "node1 builds $M0 without pushing anywhere"
start_reconciler node2
built node1 --local
COLD=$WALL
((WALL > 0)) && ok "node1 built $REF in ${WALL}s" || bad "node1 built nothing"
metric "node1 wall" "${WALL}s, $CACHED steps were cached"
metric "ref node1 wrote" "$REF (cache-branch-commit)"
metric "node1 pushed to peers" "none, it was given --local"
((CACHED <= 1)) && ok "node1 really was cold, so the restore worked" ||
	bad "node1 found $CACHED cached steps before anything was built"
[[ -z "$FROM" ]] && ok "nothing to import for $M0, as expected on the first commit" ||
	bad "it imported $FROM for a commit nobody has built"

say "node2's reconciler pulls it, unasked"
NOTICED=$(wait_for_ref node2 "$REF")
metric "noticed in" "${NOTICED}s of polling at 1s"
node_bash node2 "tail -2 /tmp/reconcile.log" | sed 's/^/      /'
LAYERS=$(node_bash node2 "grep -oP '(?<=, )\d+(?= layers)' /tmp/reconcile.log | tail -1" || true)
ARRIVED=$(registry_bytes node2)
metric "registry on node2" "$ARRIVED bytes ($LAYERS layers pulled)"

say "node2 builds the same commit, from what landed in its own registry"
built node2 --local
# The cached-step count is what BuildKit chose to print, and a layer brought in
# from a registry does not always get its own CACHED line.  Wall time and the
# binary that comes out are the two numbers that are not negotiable.
metric "node2 wall" "${WALL}s against node1's ${COLD}s cold"
metric "cached steps printed" "$CACHED"
((WALL * 3 < COLD)) &&
	ok "the replicated ref cut node2's build by more than 3x" ||
	bad "node2 took ${WALL}s against a cold ${COLD}s, the replicated cache did not land"
[[ "$(image_digest node1 "$M0")" == "$(image_digest node2 "$M0")" ]] &&
	ok "both nodes on $M0 ran out the same binary" ||
	bad "the two nodes' binaries differ, so the replicated cache produced something else"

say "a second commit, and the delta it costs"
M1=$(node_bash node1 "
	set -e
	cd $REPO
	sed -i '0,/c + 1.0;/s//c + 2.0;/' src/mu3.c
	git commit -qam 'master: nudge mu_3_0 again'
	git rev-parse --short HEAD
")
node_bash node2 "cd $REPO && git fetch -q origin && git merge -q --ff-only origin/master"
built node1 --local
metric "node1 wall for $M1" "${WALL}s, $CACHED steps cached"
metric "it imported" "$FROM <- named by git, not by a moving tag"
[[ "$FROM" == *"cache-master-$M0 "* ]] &&
	ok "node1 pointed at its parent commit's ref, not at the newest thing" ||
	bad "node1 imported '$FROM', expected cache-master-$M0"
NOTICED=$(wait_for_ref node2 "$REF")
DELTA=$(($(registry_bytes node2) - ARRIVED))
metric "noticed in" "${NOTICED}s"
metric "node2 registry grew by" "$DELTA bytes for the whole ref"
metric "same commit via files" "would have been the entire directory again, see file-cache.sh"

say "the loop check: nothing arrives twice"
quiet=$(node_bash node2 "$TOOLS/reconcile.sh --once --verbose" | tail -1)
echo "      $quiet"
grep -q '0 brought over' <<<"$quiet" &&
	ok "a second pass found nothing to do" || bad "the second pass still moved things: $quiet"
same=$(node_bash node2 "$TOOLS/reconcile.sh --once --verbose" | grep -c 'from 192' || true)
((same == 0)) && ok "still idle, and it is not copying into itself either" ||
	bad "$same copies happened on an idle cluster"

say "node1 builds again without --local, and finds its peers ahead of it"
built node1
grep -q 'already has the ref, nothing to send' <<<"$BUILD_OUT" &&
	ok "the push path looked, and had nothing to push" ||
	bad "the push path re-sent a ref the peers already had"

say "the branch that is not master"
node_bash node1 "
	set -e
	cd $REPO
	git branch -q flight/v1.25 HEAD~1
	git checkout -q flight/v1.25
	sed -i 's|ca-certificates;|ca-certificates pkg-config;|' Dockerfile
	git commit -qam 'flight/v1.25: this branch still needs pkg-config to build'
"
F=$(node_bash node1 "cd $REPO && git rev-parse --short HEAD")
built node1 --local
metric "ref for flight/v1.25" "$REF (its own dependency layer, its own name)"
node_bash node2 "cd $REPO && git fetch -q origin && git checkout -qB flight/v1.25 origin/flight/v1.25"
NOTICED=$(wait_for_ref node2 "$REF")
built node2 --local
metric "noticed in" "${NOTICED}s"
metric "node2 on the branch commit" "${WALL}s, $CACHED steps cached"
[[ "$(image_digest node1 "$F")" == "$(image_digest node2 "$F")" ]] &&
	ok "the branch ref replicated and node2 built the same binary from it" ||
	bad "the branch build differs between nodes"

node_bash node2 "pkill -f 'reconcile.sh' || true"
say "what the reconciler did all run"
node_bash node2 "cat /tmp/reconcile.log" | sed 's/^/      /'
report
