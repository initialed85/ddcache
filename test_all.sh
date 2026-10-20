#!/bin/bash

set -e

# Every test in test/, each starting from a freshly restored cluster.  Takes a
# few minutes per test: a restore reboots the nodes and a cold build is meant
# to be cold.

for t in test/*.sh; do
	name="${t#test/}"
	name="${name%.sh}"
	[[ "$name" == *lib ]] && continue

	echo "=== $t ==="
	./test.sh restore "$name"
done

echo -e "\nall done."
