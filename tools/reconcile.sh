#!/bin/bash
set -euo pipefail

#
#  The background half: bring over the refs this node's registry does not have.
#
#  usage (on a node, as vagrant):
#    ~/ddcache/reconcile.sh                  # forever, every 5s
#    ~/ddcache/reconcile.sh --once
#    ~/ddcache/reconcile.sh --interval 2 --verbose
#    nohup ~/ddcache/reconcile.sh >/tmp/reconcile.log 2>&1 &   # leave it running
#
#  Why it can't echo itself: this is state, not events.  The work is "refs the
#  cluster has that this registry doesn't", every copy makes that set smaller, and
#  the empty set is a fixed point.  Nothing here reacts to a log line, so a
#  replication does not look like anything to react to - which is the loop you
#  were worried about.
#
#  Why a half-finished push is safe: a registry will not serve a manifest until
#  every blob that manifest names has been uploaded, so a ref in a tag list is a
#  complete cache item by definition.  That is the signal, and it is free.
#
#  This pulls, it never pushes: the node that built a ref is no different from any
#  other node once the blobs are where they are.  So `docker.sh --local` followed
#  by this is the asynchronous shape, and `docker.sh` without --local is the same
#  thing done synchronously.
#

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

interval=5
once=0
verbose=0

while (($#)); do
	case $1 in
	--once) once=1 ;;
	--interval)
		interval=$2
		shift
		;;
	--verbose) verbose=1 ;;
	-*) die "unknown option '$1'" ;;
	esac
	shift
done

# One pass.  Returns 0 even when a peer went away mid-pass: a reconciler that
# exits on a transient failure is a cron job that silently stopped working.
pass() {
	local self inv missing src tag line t n=0
	self=$(self_ip)
	inv=$(inventory)

	declare -A have
	while read -r t; do have[$t]=1; done < <(tags_on "$self")

	missing=()
	while read -r src tag; do
		[[ -n "${tag:-}" ]] || continue
		[[ -n "${have[$tag]:-}" ]] && continue
		missing+=("$src $tag")
	done <<<"$inv"

	# One pass may need several refs; a ref pulled this pass is "had" from now on,
	# so an earlier peer's copy of it is not chased again.
	declare -A taken
	for line in "${missing[@]+"${missing[@]}"}"; do
		read -r src tag <<<"$line"
		[[ -n "${taken[$tag]:-}" ]] && continue
		taken[$tag]=1
		if copy_ref "$src" "$self" "$tag"; then
			printf '%s: %s from %s, %s layers, %s in %ss\n' \
				"$(date +%T)" "$tag" "$src" "$LAYERS" "$(human "$BYTES_MOVED")" "$COPY_SECONDS"
			n=$((n + 1))
		else
			printf '%s: %s from %s failed, trying again next pass\n' "$(date +%T)" "$tag" "$src"
		fi
	done

	((verbose)) && printf '%s: %s refs here, %s brought over\n' \
		"$(date +%T)" "${#have[@]}" "$n"
	return 0
}

while :; do
	pass || true
	((once)) && break
	sleep "$interval"
done
