#!/usr/bin/env bash
# docker.sh - the thing CI would call.  Builds with the registry cache backend and
# names the ref after the commit, so cache is chosen by git history rather than by
# whoever wrote to a branch tag last.
#
#   ./docker.sh <ctx>          build, export the cache ref, then copy it to every
#                              peer before returning (the eager shape)
#   ./docker.sh --local <ctx>  build and export to this node's registry only; the
#                              peers are not bothered, a reconciler notices later
#                              (the asynchronous shape, what CI on a fleet wants)
#   ./docker.sh --no-cache     rebuild from scratch, importing nothing
#   ./docker.sh --print <ctx>  the plan: which refs would be fetched, which build
#
# A build never reads cache across the network.  If a ref this node could use is
# not in its own registry, docker.sh copies it in first - one bounded wait, paid
# for in bytes it can print - and then BuildKit talks to localhost only.  So a
# slow peer shows up as a slow fetch that docker.sh can time, and a dead peer as
# a build that runs without that cache, never as a step of the build hanging on
# someone else's machine.
#
# Requires: docker with BuildKit, git, jq, skopeo, and registry:2 on this node and
# on every node in $DDCACHE_NODES (tools/deploy.sh arranges all of that).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"

MODE=push
ctx=.
ref=""
tag=""
nocache=()
print_only=0

while (($#)); do
	case $1 in
	--local) MODE=local ;;
	--no-cache) nocache=(--no-cache) ;;
	--print) print_only=1 ;;
	--ref)
		ref=$2
		shift
		;;
	--tag)
		tag=$2
		shift
		;;
	-*) die "unknown option '$1'" ;;
	*) ctx=$1 ;;
	esac
	shift
done
ctx=$(readlink -f "$ctx")

self=$(self_ip)
sha=$(git -C "$ctx" rev-parse --short HEAD 2>/dev/null) || die "$ctx has no commit to build"
slug=$(branch_slug "$ctx")
[[ -n "$slug" && "$slug" != HEAD ]] || die "$ctx is detached; name the ref with --ref"
ref=${ref:-$(ref_tag "$ctx")}
tag=${tag:-$sha}
echo "docker.sh: $(hostname) ($self)"
echo "docker.sh: ref  $ref"

# Candidate commits: this one, then its parents.  A build reads the most specific
# cache available and falls back down the history, which is why an incomplete
# replication costs a rebuild rather than a blank run.
cands=("$sha")
while read -r h; do cands+=("$h"); done < <(git log --format=%h -n 3 "$sha^" 2>/dev/null || true)

if ((${#nocache[@]})); then
	INV=""   # --no-cache means rebuild from scratch, not rebuild after fetching
else
	INV=$(inventory)
fi

# ref_for <sha> : the cache ref holding that commit, preferring this branch's, and
# the ip of a node whose registry will serve it.  Nothing local means nothing to
# import, which is the ordinary case on the first commit of a new branch.
ref_for() {
	local c line
	c=$(matching "$INV" "$1")   # matching prepends the dash: tags end -<sha>
	[[ -z "$c" ]] && return 0
	for f in "^$self cache-${slug}-" "^[^ ]* cache-${slug}-" "^$self " ".*"; do
		line=$(grep -- "$f" <<<"$c" | head -1)
		[[ -n "$line" ]] && { echo "$line"; return 0; }
	done
	return 0
}

imports=()
fetched=0
for cand in "${cands[@]}"; do
	line=$(ref_for "$cand" || true)
	[[ -z "$line" ]] && continue
	read -r ip name <<<"$line"
	if [[ "$ip" == "$self" ]]; then
		imports+=("$name $self")
		continue
	fi
	# Not here, but someone has it: bring it home before the build starts.
	if ((fetched)); then
		echo "docker.sh: not fetching $name, nearer cache already coming"
		continue
	fi
	if ((print_only)); then
		imports+=("$name $ip (fetch)")
		continue
	fi
	if copy_ref "$ip" "$self" "$name"; then
		echo "docker.sh: fetched $name from $ip, $(human $BYTES_MOVED) in ${COPY_SECONDS}s"
		fetched=1
		imports+=("$name $self")
	else
		echo "docker.sh: fetch of $name from $ip failed; building without it"
	fi
done

args=(build --progress plain "${nocache[@]+"${nocache[@]}"}"
	--build-arg "APT_PROXY=${APT_PROXY:-}"
	-t "ddcache/spike:${tag}")
for i in "${imports[@]+"${imports[@]}"}"; do
	read -r name ip rest <<<"$i"
	args+=(--cache-from "type=registry,ref=$(reg "$self")/$REG_REPO:$name")
done
args+=(--cache-to "type=registry,ref=$(reg "$self")/$REG_REPO:$ref,mode=max,image-manifest=true,oci-mediatypes=true")
args+=("$ctx")

for i in "${imports[@]+"${imports[@]}"}"; do
	read -r name ip rest <<<"$i"
	printf 'docker.sh: from %s on %s%s\n' "$name" "$ip" "${rest:+ $rest}"
done
((${#imports[@]})) || echo "docker.sh: from nothing - this cluster has not built $sha or its parents"

if ((print_only)); then
	printf 'docker.sh: would run: docker'
	printf ' %q' "${args[@]}"
	printf '\n'
	exit 0
fi

start=$(date +%s)
docker "${args[@]}" >/tmp/ddcache-build.log 2>&1 || {
	tail -30 /tmp/ddcache-build.log >&2
	die "build failed, log kept in /tmp/ddcache-build.log"
}
echo "docker.sh: built in $(($(date +%s) - start))s, $(grep -c CACHED /tmp/ddcache-build.log || true) steps were cached"

if [[ $MODE == local ]]; then
	echo "docker.sh: --local, leaving $(peers | tr '\n' ' ')to notice"
	exit 0
fi

for p in $(peers); do
	if has_tag_on "$p" "$ref"; then
		printf 'docker.sh: %-15s already has the ref, nothing to send\n' "$p"
		continue
	fi
	if copy_ref "$self" "$p" "$ref"; then
		printf 'docker.sh: %-15s %s layers, %s in %ss\n' \
			"$p" "$LAYERS" "$(human "$BYTES_MOVED")" "$COPY_SECONDS"
	else
		printf 'docker.sh: %-15s copy failed\n' "$p"
	fi
done
