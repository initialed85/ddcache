#!/bin/bash

# Does the registry path work at all?
#
#   node1 builds            -> --cache-to type=registry into its own registry
#   node1 -> node2          -> one ref, copied at blob level (skopeo)
#   node2 builds            -> hits, from its local copy
#   node3 builds            -> hits, pulling straight out of node1's registry
#
# The last one matters on its own: with a registry there is no replication step
# at all, a node just names the ref it wants.  Replication is for locality, not
# for making it work.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

LOG_DIR="$(mktemp -d /tmp/ddcache-test.XXXXXX)"
preserve_logs_on_failure "$LOG_DIR"

require_cluster

for n in node1 node2 node3; do
	ensure_insecure_registries "$n"
	ensure_registry "$n"
done
ok "registry answering on all three nodes"

node_bash node1 "rm -rf $SRC_DIR /home/vagrant/spike /home/vagrant/cache && mkdir -p $SRC_DIR"
for n in node2 node3; do
	node_bash "$n" "rm -rf $SRC_DIR /home/vagrant/spike /home/vagrant/cache"
done
prune_builder node1
prune_builder node2
prune_builder node3

node_put node1 "$SPIKE_SRC" src
node_put node2 "$SPIKE_SRC" src
node_put node3 "$SPIKE_SRC" src

REF=$(cache_ref node1 main initial)
metric "cache ref" "$REF"

say "cold build on node1, exporting to its own registry"
build_from_registry node1 main-initial "" "$LOG_DIR/n1.log" "$REF"
T_COLD=$SECONDS_BUILD
metric "wall" "${SECONDS_BUILD}s"
metric "cached steps" "$(cached_steps "$LOG_DIR/n1.log") (expect 0)"
metric "node1 registry" "$(registry_bytes node1) bytes"
metric "tags" "$(registry_tags node1)"
[[ "$(cached_steps "$LOG_DIR/n1.log")" == "0" ]] &&
	ok "node1 had nothing to hit" || bad "node1 hit a cache it should not have had"

say "replicate the ref to node2"
R0=$(rx_bytes node2)
replicate node1 node2 "cache-main-initial"
WIRE_FIRST=$WIRE_BYTES
[[ "$WIRE_FIRST" -gt 100000000 ]] &&
	ok "first copy of a ref is the whole thing ($WIRE_BYTES bytes)" ||
	bad "expected the first replication to move the full cache, moved $WIRE_BYTES"

say "node2 builds warm, from its own registry"
prune_builder node2
build_from_registry node2 main-initial "$(cache_ref node2 main initial)" "$LOG_DIR/n2.log"
T_N2=$SECONDS_BUILD
STEPS2=$(cached_steps "$LOG_DIR/n2.log")
metric "wall" "${T_N2}s (node1 cold: ${T_COLD}s)"
metric "cached steps" "$STEPS2"
metric "image" "$(image_digest node2 main-initial)"

[[ "$STEPS2" -ge 3 ]] && ok "node2 hit its local copy" || bad "node2 got $STEPS2 cached steps"
[[ "$(image_digest node1 main-initial)" == "$(image_digest node2 main-initial)" ]] &&
	ok "same binary on both nodes" || bad "digests differ between node1 and node2"

say "node3 builds warm, straight out of node1's registry"
prune_builder node3
R3=$(rx_bytes node3)
build_from_registry node3 main-initial "$(cache_ref node1 main initial)" "$LOG_DIR/n3.log"
T_N3=$SECONDS_BUILD
STEPS3=$(cached_steps "$LOG_DIR/n3.log")
metric "wall" "${T_N3}s"
metric "cached steps" "$STEPS3"
metric "node3 pulled" "$(( $(rx_bytes node3) - R3 )) bytes over the cluster network"
metric "node3 registry" "$(registry_bytes node3) bytes (expect untouched)"

[[ "$STEPS3" -ge 3 ]] && ok "node3 hit a registry it does not own" ||
	bad "node3 got $STEPS3 cached steps pulling from node1"
[[ "$(image_digest node3 main-initial)" == "$(image_digest node1 main-initial)" ]] &&
	ok "node3 too" || bad "node3 digest differs"

cat <<EOF

  Summary

    The registry route works on both shapes.  node2 built the image in ${T_N2}s
    off a replicated ref (node1 took ${T_COLD}s cold); node3 built it in ${T_N3}s
    without anyone copying anything, by naming node1's registry in --cache-from.
    A BuildKit cache is an image in a registry, so push, pull, content
    addressing, tagging and garbage collection are already built, and ddcache
    does not have to invent a file layout or a transfer format.

    The first replication of a ref still moves everything (${WIRE_FIRST} bytes).
    What happens on the *second* commit is the actual comparison against the
    directory copy, and that is registry-cache.sh.

EOF

report
