#!/bin/bash

# Registry and "git" helpers for the tests in test/registry-*.sh.  Sourced.
#
# The shape here is the one ddcache would actually have to work in: every node
# runs its own registry, cache refs are named after the branch and commit they
# were built from, and moving cache between nodes is a blob-level copy rather
# than a directory copy.
#
# The "git" side is a real scratch repo on the host, exported to the nodes with
# `git archive`.  Git isn't what we're testing, but "a commit is a file that
# changed" was what made the directory-copy numbers hard to read.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REG_PORT=5000
REG_REPO=spike
REG_DATA=/srv/registry
REG_PRIVATE_NET="192.168.78"
SRC_DIR=/home/vagrant/src

registry_host() {
	echo "$1:${REG_PORT}"
}

# A cache ref per branch and commit.  The branch is what a node looks up when it
# is asked to build something old; the commit is what makes the ref unique.
cache_ref() {
	local node=$1 branch=$2 sha=$3
	echo "$(registry_host "$node")/$REG_REPO:cache-${branch//\//-}-${sha}"
}

# Insecure registries have to be known to the daemon before anything can push to
# them.  Written once per node, restarted only when it changed, so re-runs don't
# cost a dockerd bounce.
ensure_insecure_registries() {
	local n=$1 r json out
	local list=()
	for r in node1 node2 node3 "${REG_PRIVATE_NET}".11 "${REG_PRIVATE_NET}".12 \
		"${REG_PRIVATE_NET}".13 localhost 127.0.0.1; do
		list+=("\"$r:$REG_PORT\"")
	done
	local joined=${list[0]} r
	for r in "${list[@]:1}"; do joined+=,$r; done
	json="{\"insecure-registries\":[$joined]}"

	out=$(node_bash "$n" "
		set -e
		if [ \"\$(sudo cat /etc/docker/daemon.json 2>/dev/null)\" != '$json' ]; then
			sudo mkdir -p /etc/docker
			printf '%s' '$json' | sudo tee /etc/docker/daemon.json >/dev/null
			sudo systemctl restart docker
			echo restarted
		else
			echo unchanged
		fi
	")
	[[ "$out" == *restarted* ]] && metric "dockerd" "$n restarted, insecure registries set" ||
		metric "dockerd" "$n already configured"
}

# ensure_registry <node> - filesystem-backed registry, idempotent.  After a
# restore it comes back empty, which is what we want to measure.
ensure_registry() {
	local n=$1
	node_bash "$n" "
		set -e
		sudo mkdir -p $REG_DATA/data
		if ! docker ps --format '{{.Names}} | {{.Status}}' | grep -q '^registry | Up'; then
			docker rm -f registry >/dev/null 2>&1 || true
			docker run -d --name registry --restart unless-stopped \
				-v $REG_DATA/data:/var/lib/registry -p $REG_PORT:5000 registry:2 >/dev/null
		fi
		for i in \$(seq 30); do
			curl -sf -o /dev/null http://127.0.0.1:$REG_PORT/v2/ && exit 0
			sleep 1
		done
		echo 'registry never answered' >&2
		exit 1
	" >/dev/null
}

registry_bytes() {
	local n=$1 v
	v=$(node_bash "$n" "sudo du -sb $REG_DATA/data 2>/dev/null | cut -f1" || true)
	echo "${v:-0}"
}

registry_tags() {
	local n=$1
	node_bash "$n" "curl -s http://$(registry_host "$n")/v2/$REG_REPO/tags/list" |
		python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).get("tags", []))))'
}

# rx_bytes <node> : traffic in on the cluster network, so "bytes on the wire" is
# measured rather than inferred.  eth1 is the private NIC on every node.
rx_bytes() {
	node_bash "$1" "cat /sys/class/net/eth1/statistics/rx_bytes"
}

# build_from_registry <node> <tag> <cache-from-ref> <logfile> [cache-to-ref]
#
# Same as lib.sh's build() but against a registry, and building out of the tree
# git exported for this commit.
build_from_registry() {
	local n=$1 tag=$2 from=$3 log=$4 to=${5:-}
	local remote="set -e; cd $SRC_DIR && docker build --progress plain --build-arg APT_PROXY='${APT_PROXY:-}' -t ddcache/spike:${tag}"
	local start end

	[[ -n "$from" ]] && remote+=" --cache-from 'type=registry,ref=${from}'"

	if [[ -n "$to" ]]; then
		remote+=" --cache-to 'type=registry,ref=${to},mode=max,image-manifest=true,oci-mediatypes=true'"
	fi
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

# replicate <from> <to> <tag> - copy one ref into another node's registry.
# skopeo asks the destination which blobs it already has and sends the rest,
# which is the whole point of using a registry in the first place.
replicate() {
	local from=$1 to=$2 tag=$3 before after out start end

	say "replicate $REG_REPO:$tag  $from -> $to"
	before=$(rx_bytes "$to")
	start=$(date +%s)
	out=$(node_bash "$to" "skopeo copy --all --preserve-digests \
		--src-tls-verify=false --dest-tls-verify=false \
		docker://$(registry_host "$from")/$REG_REPO:$tag \
		docker://$(registry_host "$to")/$REG_REPO:$tag 2>&1")
	end=$(date +%s)
	after=$(rx_bytes "$to")

	WIRE_BYTES=$((after - before))
	WIRE_SECONDS=$((end - start))
	metric "blobs" "$(grep -c 'Copying blob' <<<"$out") (wire bytes below are the honest measure)"
	metric "bytes on the wire" "$WIRE_BYTES"
	metric "wall" "${WIRE_SECONDS}s"
}

#
# the scratch repo
#

mkrepo() {
	REPO_TMP="$(mktemp -d /tmp/ddcache-repo.XXXXXX)"
	(
		cd "$REPO_TMP"
		cp -r "$REPO_ROOT/$SPIKE_SRC"/. .
		git init -q .
		git config user.email spike@ddcache.invalid
		git config user.name "ddcache spike"
		git add -A
		git commit -qm "import spike"
	)
}

# commit_change <file> <sed-expression> <message> : one edit, one commit, prints
# the short sha.  This is what "a new commit on the branch" means for us.
commit_change() {
	local file=$1 expr=$2 msg=$3
	(
		cd "$REPO_TMP"
		sed -i "$expr" "$file"
		git add -A
		git commit -qm "$msg"
		git log --format=%h -1
	)
}

# branch_at <name> <sha>
branch_at() {
	(cd "$REPO_TMP" && git branch -q "$1" "$2" && git log --format=%h -1 "$1")
}

# checkout_node <sha> <node> : put a commit's tree on a node the way CI would
# after a fetch.  Nothing to do with the cache.
checkout_node() {
	local sha=$1 n=$2
	node_init "$n"
	node_bash "$n" "rm -rf $SRC_DIR && mkdir -p $SRC_DIR"
	(cd "$REPO_TMP" && git archive "$sha") |
		# shellcheck disable=SC2046
		ssh $(ssh_opts "$n") "${NODE_USER[$n]}@${NODE_HOST[$n]}" "tar -xm -C $SRC_DIR"
}
