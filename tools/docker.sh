#!/bin/bash
set -euo pipefail

#
#  A docker build that knows where it is, and who else is.
#
#  usage (on a node, as vagrant):
#    cd ~/repo && hack, git commit, then:
#      ~/ddcache/docker.sh .
#
#  options:
#    --local        build and export to this node's registry only.  The ref then
#                   reaches the other nodes because reconcile.sh notices it, which
#                   is the asynchronous shape you actually want to watch.
#    --ref NAME     name the exported ref something other than cache-<branch>-<sha>
#    --tag NAME     image tag to leave behind (default: the short commit sha)
#    --no-cache     --no-cache, and ignore what the cluster has
#    --print        say what it would do, build nothing
#
#  What it does:
#    1. names the ref for this commit
#    2. asks every registry in the cluster which refs exist for this commit and
#       its two parents, and imports the best one for each: this branch's ref
#       beats another branch's, this node beats a peer's
#    3. builds, and exports mode=max into this node's registry
#    4. copies the new ref to every peer that does not have it, unless --local
#
#  Step 2 is the git-aware bit and the reason the ref is named after a commit:
#  pointing at "the newest cache on master" instead of "my parent's cache" is what
#  cost a warm build 46s and zero cached steps in registry-cache.sh.
#

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ctx=.
async=0
ref=
tag=
nocache=()
print_only=0

while (($#)); do
	case $1 in
	--local) async=1 ;;
	--ref)
		ref=$2
		shift
		;;
	--tag)
		tag=$2
		shift
		;;
	--no-cache) nocache=(--no-cache) ;;
	--print) print_only=1 ;;
	-*) die "unknown option '$1'" ;;
	*) ctx=$1 ;;
	esac
	shift
done

self=$(self_ip)
sha=$(git -C "$ctx" rev-parse --short HEAD 2>/dev/null) || die "$ctx has no commit to build"
slug=$(branch_slug "$ctx")
[[ -n "$slug" && "$slug" != HEAD ]] || die "$ctx is detached; name the ref with --ref"
ref=${ref:-$(ref_tag "$ctx")}
tag=${tag:-$sha}

# own commit, then the two commits behind it.  A build never writes anyone else's
# ref, which is what makes two nodes building two commits concurrently boring.
cands=("$sha")
while read -r h; do cands+=("$h"); done < <(git -C "$ctx" log --format=%h -n 2 "$sha^" 2>/dev/null || true)

# pick_ref <sha> : the "ip ref" to import this commit's cache from, if any.
pick_ref() {
	local c
	c=$(matching "$INV" "$1")
	[[ -z "$c" ]] && return 0

	for f in "^$self cache-${slug}-" "^[^ ]* cache-${slug}-" "^$self " ".*"; do
		grep -- "$f" <<<"$c" | head -1
	done | head -1
}

imports=()
INV=""
if ((!${#nocache[@]})); then
	INV=$(inventory)
	for cand in "${cands[@]}"; do
		line=$(pick_ref "$cand" || true)
		[[ -z "$line" ]] && continue
		# the first candidate is our own commit: --cache-from and --cache-to naming
		# the same ref is the rerun case, BuildKit reads the manifest before it
		# writes one
		imports+=("$line ${cand}")
	done
fi

args=(build --progress plain "${nocache[@]+"${nocache[@]}"}" --build-arg "APT_PROXY=${APT_PROXY:-}"
	-t "ddcache/spike:${tag}")
for i in "${imports[@]+"${imports[@]}"}"; do
	read -r ip name cand <<<"$i"
	args+=(--cache-from "type=registry,ref=$(reg "$ip")/$REG_REPO:$name")
done
args+=(--cache-to "type=registry,ref=$(reg "$self")/$REG_REPO:$ref,mode=max,image-manifest=true,oci-mediatypes=true")
args+=("$ctx")

echo "docker.sh: $(hostname) ($self)"
echo "docker.sh: ref  $ref"
for i in "${imports[@]+"${imports[@]}"}"; do
	read -r ip name cand <<<"$i"
	printf 'docker.sh: from %s on %s%s\n' "$name" "$ip" "${cand:+ (commit $cand)}"
done
((${#imports[@]})) || echo "docker.sh: from nothing - this cluster has not built $sha or its parents"

if ((print_only)); then
	printf 'docker.sh: would run: docker'
	printf ' %q' "${args[@]}"
	printf '\ndocker.sh: and then replicate %s to: %s\n' "$ref" "$(peers | tr '\n' ' ')"
	exit 0
fi

start=$(date +%s)
if docker "${args[@]}" 2>&1 | tee /tmp/ddcache-build.log; then
	:
else
	die "build failed, log kept in /tmp/ddcache-build.log"
fi
echo "docker.sh: built in $(($(date +%s) - start))s, $(grep -c CACHED /tmp/ddcache-build.log || true) steps were cached"

if ((async)); then
	echo "docker.sh: --local, leaving $(peers | tr '\n' ' ') to notice"
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
