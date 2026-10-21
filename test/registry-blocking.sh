#!/bin/bash
set -euo pipefail

#
#  "I don't get the cache until I need it, and then I wait for it" - what is that
#  wait worth?
#
#  usage: ./test.sh restore registry-blocking
#         ./test.sh restore registry-blocking --profile '200mbit 15ms'
#
#  These three nodes are VMs on one desktop: 155 MB crosses the private network in
#  about a second and the RTT is 0.15ms, so unshaped seconds say nothing about a
#  real fleet.  Bytes carry between experiments, seconds do not, so every transfer
#  here goes through a shaped link, and each profile is a link you could rent - the
#  default pair is 1 Gbit inside one DC and 200 Mbit with 15ms one way, which is
#  roughly "cloud VM down the hall" and "cloud VM in another building".
#
#  Three things get measured, in the order a fleet would meet them:
#
#    on demand   - the ref is only on a peer.  docker.sh copies it into this node's
#                  own registry, prints what that cost, and then builds against
#                  localhost.  This is the shape a build falls into when nobody
#                  replicated ahead of it.
#    prefetched  - reconcile.sh --watch copies the ref in before the build starts,
#                  so docker.sh has nothing to fetch at all.
#    the peer dies - once before the build (docker.sh never names it), and once with
#                  the layers half-pulled (the fetch fails and the build runs without
#                  that cache).  Both have to end in a built image.
#
#  Neither shape lets BuildKit read cache over the network: that is the whole point
#  of the design, and the assertion that matters most here is not a timing, it is
#  that after a prefetch the build takes 0 MB off the wire, and that the build step
#  costs the same whether the bytes arrived a minute ago or six seconds ago.
#
#  The verdict on total time is a metric, not a check: which shape wins depends on
#  the link.  What is asserted is that each path paid the cost it claims to have
#  paid, and that a peer going away never loses a build.
#

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

LOG_DIR="$REPO_ROOT/logs/$(basename "$0" .sh)-$$"
mkdir -p "$LOG_DIR"
preserve_logs_on_failure "$LOG_DIR"

SERVING=node1
RECEIVING=node2
shaped=0

# The shaper sits on the node serving the bytes: its egress is what the receiver
# sees.  Shaping the receiver's ingress would need an IFB device to redirect into,
# and both ends count the same 155 MB either way.
shape() {
	local rate=$1 lat=$2
	node_bash "$SERVING" "
		set -e
		sudo tc qdisc replace dev eth1 root handle 1: htb default 10
		sudo tc class add dev eth1 parent 1: classid 1:10 htb rate $rate burst 64k cburst 64k
		sudo tc qdisc add dev eth1 parent 1:10 handle 20: netem latency $lat limit 10000
	" 2>&1 | grep -v quantum || true
	shaped=1
}

unshape() {
	node_bash "$SERVING" "sudo tc qdisc del dev eth1 root 2>/dev/null || true"
	shaped=0
}

# link_dies / link_lives <node> : stop this node's transfers with the serving peer
# at the transport, which is what "the peer went away mid-pull" looks like to the
# side that is reading.  Cutting it on the *serving* node was tried first and does
# not work: the published registry port is served through the bridge and FORWARD, and
# the bulk flow ignored the rules there while a fresh curl to the same address timed
# out on queueing delay alone - the shape is 50 Mbit with 10000 packets of backlog, so
# "unreachable" and "congested" were indistinguishable, and the stage measured nothing
# twice over.  Rules on the reader's own INPUT/OUTPUT are host-local sockets, so they
# are unambiguously on the path, and rx_bytes proves it either way.
link_dies() {
	local n=$1
	node_bash "$n" "
		sudo iptables -I INPUT -i eth1 -p tcp -s ${NODE_HOST[$SERVING]} --sport $REG_PORT -j REJECT --reject-with tcp-reset
		sudo iptables -I OUTPUT -o eth1 -p tcp -d ${NODE_HOST[$SERVING]} --dport $REG_PORT -j REJECT --reject-with tcp-reset
	" 2>&1 | grep -v quantum || true
}

link_lives() {
	local n=$1
	node_bash "$n" "
		sudo iptables -D INPUT -i eth1 -p tcp -s ${NODE_HOST[$SERVING]} --sport $REG_PORT -j REJECT --reject-with tcp-reset 2>/dev/null || true
		sudo iptables -D OUTPUT -o eth1 -p tcp -d ${NODE_HOST[$SERVING]} --dport $REG_PORT -j REJECT --reject-with tcp-reset 2>/dev/null || true
	" 2>&1 | grep -v quantum || true
}

# A cluster left with a 200 Mbit cap or a hard reset in its netfilter tables is a
# cluster nobody can use, and neither survives the shell exiting.
cleanup() {
	if ((shaped)); then unshape; fi
	for node in "${NODES[@]}"; do link_lives "$node"; done
}
trap cleanup EXIT

# mb() to one decimal.  At 200 Mbit the interesting number is "the delta was
# 2.9 MB", and integer megabytes turns that into 0 MB, which is a lie of the most
# flattering kind.
mb() { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1000000}'; }

# clean_receiver <node> : "this node has never seen a cache ref", in both the
# registry and the builder, which is the only state the two paths can share.
clean_receiver() {
	clear_registry "$1"
	prune_builder "$1"
}

# nudge <node> : a new commit that only that node has seen, and its short sha.
# Appending a translation unit is state-independent, which matters when a probe
# runs twice without a restore underneath it.
nudge() {
	node_bash "$1" "
		set -e
		cd $REPO
		printf 'double nudge_%d(void){return 1.0;}\\n' \$(date +%s) >> src/nudge.c
		git add -A && git commit -qm \"master: nudge \$(date +%s)\"
		git rev-parse --short HEAD
	"
}

profiles=()
while (($#)); do
	case $1 in
	--profile)
		profiles+=("$2")
		shift
		;;
	-*)
		echo "registry-blocking: unknown option '$1'" >&2
		exit 1
		;;
	*) profiles+=("$1") ;;
	esac
	shift
done
((${#profiles[@]})) || profiles=("1gbit 500us" "200mbit 15ms")

say "deploy"
require_cluster
deploy_tools

say "one commit, built cold on $SERVING and nowhere else"
node_bash "$SERVING" "rm -rf $REPO"
node_put "$SERVING" "$REPO_ROOT/test/spike" "$REPO"
node_bash "$SERVING" "
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
SHA=$(node_bash "$SERVING" "cd $REPO && git rev-parse --short HEAD")
node_bash "$RECEIVING" "rm -rf $REPO && git clone -q vagrant@${NODE_HOST[$SERVING]}:$REPO $REPO"
# "cold" has to be arranged, not assumed.  A restore rolls the disks back, but the
# nodes have been used by every stage before this one, and a producer with a warm
# builder makes each number after it meaningless.
for n in "${NODES[@]}"; do clean_receiver "$n"; done
built "$SERVING" --local
metric "ref" "$REF, on $SERVING's registry and nowhere else"
metric "size of that ref" "$(mb $(registry_bytes "$SERVING")) MB"
((WALL > 20)) && ok "$SERVING built $SHA cold, so the receiver has nothing to lean on" ||
	bad "$SERVING built in ${WALL}s, that was not a cold build and nothing after it is comparable"

for p in "${profiles[@]}"; do
	read -r rate lat <<<"$p"
	say "link: $rate out of $SERVING, ${lat} one way"
	shape "$rate" "$lat"

	say "  on demand - docker.sh brings the ref home, then builds against localhost"
	clean_receiver "$RECEIVING"
	rx0=$(rx_bytes "$RECEIVING")
	built "$RECEIVING" --local
	ONDEMAND_FETCH=$FETCH
	ONDEMAND_WALL=$WALL
	ONDEMAND_BYTES=$(($(rx_bytes "$RECEIVING") - rx0))
	metric "fetch" "${ONDEMAND_FETCH}s, $(mb $ONDEMAND_BYTES) MB in from $SERVING"
	metric "then the build" "${ONDEMAND_WALL}s, $CACHED steps cached"
	SYNC_DIGEST=$(image_digest "$RECEIVING" "$SHA")

	say "  prefetched - reconcile --watch copies it in before the build starts"
	clean_receiver "$RECEIVING"
	rx0=$(rx_bytes "$RECEIVING")
	t0=$(date +%s)
	node_bash "$RECEIVING" "$TOOLS/reconcile.sh --once --verbose --watch $REPO" 2>&1 |
		tee "$LOG_DIR/reconcile-$rate.log" | grep 'from ' | sed 's/^/      /' || true
	PREFETCH_WALL=$(($(date +%s) - t0))
	PREFETCH_BYTES=$(($(rx_bytes "$RECEIVING") - rx0))
	prune_builder "$RECEIVING"
	rx0=$(rx_bytes "$RECEIVING")
	built "$RECEIVING" --local
	LOCAL_WALL=$WALL
	LOCAL_BYTES=$(($(rx_bytes "$RECEIVING") - rx0))
	FETCH_LINES=$(grep -c 'docker.sh: fetched' "$LOG_DIR/docker-$RECEIVING-$BUILT_N.log" || true)
	metric "prefetch" "${PREFETCH_WALL}s, $(mb $PREFETCH_BYTES) MB in from $SERVING"
	metric "then the build" "${LOCAL_WALL}s, $(mb $LOCAL_BYTES) MB from anywhere else"
	metric "link actually delivered" "$(awk -v b=$PREFETCH_BYTES -v t=$PREFETCH_WALL \
		'BEGIN{printf "%.0f MB/s", b/1000000/(t>0?t:1)}') over the wire, against ${rate} asked for"
	metric "TIME TO A FINISHED IMAGE" "$((ONDEMAND_FETCH + ONDEMAND_WALL))s on demand (${ONDEMAND_FETCH}s fetch + ${ONDEMAND_WALL}s build) vs $((PREFETCH_WALL + LOCAL_WALL))s prefetched (${PREFETCH_WALL}s + ${LOCAL_WALL}s)"

	((ONDEMAND_BYTES > 20000000)) && ok "the on-demand path really did fetch across the link" ||
		bad "on demand pulled only $(mb $ONDEMAND_BYTES) MB, it found cache somewhere unexpected"
	((LOCAL_BYTES < 1000000)) && ok "after the prefetch the build took nothing off the network" ||
		bad "the build still pulled $(mb $LOCAL_BYTES) MB after a full prefetch"
	((FETCH_LINES == 0)) && ok "with the ref already home, docker.sh fetched nothing" ||
		bad "docker.sh fetched $FETCH_LINES refs even though the reconciler had run"
	[[ "$(image_digest "$RECEIVING" "$SHA")" == "$SYNC_DIGEST" ]] &&
		ok "both paths produced the same binary" ||
		bad "the two paths produced different images, so this is not one comparison"
	# The claim about the shape rather than the link: the build step should not care
	# whether the bytes arrived a minute ago or six seconds ago, because it only ever
	# reads localhost.
	((LOCAL_WALL >= ONDEMAND_WALL - 2 && LOCAL_WALL <= ONDEMAND_WALL + 2)) &&
		ok "the build step cost the same either way: ${ONDEMAND_WALL}s after fetching, ${LOCAL_WALL}s with it done" ||
		bad "the build step itself varied with the network: ${ONDEMAND_WALL}s vs ${LOCAL_WALL}s"
	if ((ONDEMAND_FETCH + ONDEMAND_WALL <= PREFETCH_WALL + LOCAL_WALL)); then
		metric "verdict" "waiting at build time was $(((PREFETCH_WALL + LOCAL_WALL) - (ONDEMAND_FETCH + ONDEMAND_WALL)))s cheaper overall"
	else
		metric "verdict" "prefetching first won by $(((ONDEMAND_FETCH + ONDEMAND_WALL) - (PREFETCH_WALL + LOCAL_WALL)))s"
	fi

	unshape
done

say "steady state: the next commit, on a node that has been building this branch"
# $RECEIVING is warm and holds its own last ref, which is the state a real runner
# lives in.  node1 makes the next commit and nobody else has seen it.
M1=$(nudge "$SERVING")
node_bash "$RECEIVING" "cd $REPO && git fetch -q origin && git merge -q --ff-only origin/master"
built "$SERVING" --local
metric "$SERVING for the new commit" "${WALL}s, imported ${FROM:-nothing}"
shape "200mbit" "15ms"
rx0=$(rx_bytes "$RECEIVING")
built "$RECEIVING" --local
STEADY_BYTES=$(($(rx_bytes "$RECEIVING") - rx0))
metric "on demand, 200mbit link" "${FETCH}s to fetch, ${WALL}s to build, $(mb $STEADY_BYTES) MB in from $SERVING"
metric "what it fetched" "${FROM}, named by git"
STEADY_TOTAL=$((FETCH + WALL))
unshape

say "the peer is gone before the build starts"
# docker.sh names a peer only if its registry answered the tag list, so a machine
# that is down is not on the critical path at all.  What is lost is the cache, and
# the cost of that is the difference between a warm build and a rebuild.
M2=$(nudge "$SERVING")
built "$SERVING" --local
HOT=$WALL
node_bash "$SERVING" "docker kill registry >/dev/null"
node_bash "$RECEIVING" "cd $REPO && git fetch -q origin && git merge -q --ff-only origin/master"
rx0=$(rx_bytes "$RECEIVING")
if built "$RECEIVING" --local; then
	DEAD_OK=1
else
	DEAD_OK=0
fi
metric "the same shape of change, peer answering" "${STEADY_TOTAL}s fetch and build together"
metric "peer's registry killed first" "${FETCH}s fetched, ${WALL}s, $(mb $(($(rx_bytes "$RECEIVING") - rx0))) MB in, $CACHED steps cached"
((DEAD_OK)) && ok "a silent peer did not fail the build" ||
	bad "a peer that stopped answering failed the build outright"
metric "cost of the missing cache" "$((WALL - STEADY_TOTAL))s of rebuild, paid to git's fallback to the nearest ancestor"
node_bash "$SERVING" "docker start registry >/dev/null"

say "and the peer dies with the layers half-pulled"
# The case no tag list can protect against: the registry answered, was named, and
# then stopped serving while the bytes were coming.
KILLER=node3
M3=$(nudge "$SERVING")
built "$SERVING" --local
node_bash "$KILLER" "rm -rf $REPO && git clone -q vagrant@${NODE_HOST[$SERVING]}:$REPO $REPO"
clean_receiver "$KILLER"
# 50 Mbit, so a whole ref takes ~25s across this link and a cut at 4s is inside it
shape "50mbit" "15ms"
link_lives "$KILLER"
# The build runs in the foreground on the node and the cut happens from the host in
# parallel.  An earlier draft backgrounded the build over ssh and grepped its log for
# a completion line, which raced with the previous run's leftover log and reported a
# fetch that had not happened yet - the counters said 0 MB while the log said 157 MB,
# and the contradiction was the harness, not ddcache.  Foreground plus a marker file
# per run makes "finished" a fact about the process, and the byte counters are read on
# both ends of the transfer so neither side's account can be taken on trust.
rm -f "$LOG_DIR"/midfetch-*.{out,rc} 2>/dev/null || true
{
	sleep 4
	link_dies "$KILLER"
	node_bash "$KILLER" 'date +%T' >"$LOG_DIR/midfetch-cut.out" 2>/dev/null
	rx_bytes "$KILLER" >"$LOG_DIR/midfetch-cut-rx.out" 2>/dev/null
} &
CUTTER=$!
LAUNCH=$(node_bash "$KILLER" 'date +%T')
IN_LAUNCH=$(rx_bytes "$KILLER")
node_bash "$KILLER" "cd $REPO && ~/ddcache/docker.sh --local ." >"$LOG_DIR/midfetch-build.out" 2>&1 || true
wait "$CUTTER" 2>/dev/null || true
IN_CUT=$(cat "$LOG_DIR/midfetch-cut-rx.out" 2>/dev/null || echo "$IN_LAUNCH")
CUT=$(cat "$LOG_DIR/midfetch-cut-rx.out" >/dev/null 2>&1 && cat "$LOG_DIR/midfetch-cut.out")
IN_END=$(rx_bytes "$KILLER")
metric "build launched / wire cut" "${LAUNCH} / ${CUT}, $(mb $((IN_CUT - IN_LAUNCH))) MB of it already in"
if node_bash "$KILLER" "curl -m 5 -sfo /dev/null http://${NODE_HOST[$SERVING]}:$REG_PORT/v2/"; then
	bad "the peer was still reachable after the cut, so this stage measured nothing"
else
	ok "the peer is unreachable from $KILLER, and that is the reader's own answer, not queueing delay"
fi
grep 'docker.sh: ' "$LOG_DIR/midfetch-build.out" | sed 's/^/      /' || true
link_lives "$KILLER"
unshape
metric "bytes in on $KILLER" "$(mb $((IN_CUT - IN_LAUNCH))) before the cut, $(mb $((IN_END - IN_CUT))) after it, $(mb $((IN_END - IN_LAUNCH))) in all"
# What docker.sh reported versus what the receiver counted.  The tool's number is the
# size of the ref it moved; the counter is the truth about the wire.  When they
# disagree the stage is lying and says so.
CLAIM=$(grep -oP '(?<=, )\S+(?= in \d+s$)' "$LOG_DIR/midfetch-build.out" | head -1 || true)
metric "docker.sh's own account" "fetched ${CLAIM:-nothing}"
if grep -q 'fetch of ' "$LOG_DIR/midfetch-build.out"; then
	ok "docker.sh named the fetch that failed, and built anyway"
else
	bad "docker.sh never reported a failed fetch, so the fallback this stage is about was not exercised"
fi
if grep -q 'docker.sh: built in' "$LOG_DIR/midfetch-build.out"; then
	ok "the build finished although the wire died with the fetch half-done"
else
	bad "a peer dying mid-fetch lost the build: the fetch has to fall back to building without it"
fi
(( IN_END - IN_CUT < 20000000 )) &&
	ok "the cut stopped the transfer: only $(mb $((IN_END - IN_CUT))) MB arrived after it" ||
	bad "the transfer kept receiving after the cut ($(mb $((IN_END - IN_CUT))) MB in), so the stage proved nothing"
metric "what the failed fetch cost" "a build with $(grep -oP '(?<=, )\d+(?= steps)' "$LOG_DIR/midfetch-build.out" | tail -1 || echo '?') steps cached, on a node whose only other cache was its ancestors"
metric "and what it did not cost" "the build still produced an image; the peer is not on the critical path of correctness"

say "the same ref on a link with no shaping, for scale"
clean_receiver "$RECEIVING"
rx0=$(rx_bytes "$RECEIVING")
built "$RECEIVING" --local
metric "unshaped on-demand build" "${FETCH}s fetch, ${WALL}s build, $(mb $(($(rx_bytes "$RECEIVING") - rx0))) MB in from $SERVING"
metric "why those seconds mean little" "RTT node1 to node2 is 0.153ms; tc matches the rate, never the latency"

report
