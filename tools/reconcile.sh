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
#  `--watch <checkout>` names a repo that a build is going to happen in.  The refs
#  that a build there would ask for are copied over first, ahead of the general
#  sweep, which is how a node gets the cache for the commit it has already checked
#  out before the build step starts instead of paying for it inside docker.sh.
#

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

interval=5
once=0
verbose=0
watch=()

while (($#)); do
	case $1 in
	--once) once=1 ;;
	--interval)
		interval=$2
		shift
		;;
	--watch)
		watch+=("$2")
		shift
		;;
	--verbose) verbose=1 ;;
	-*) die "unknown option '$1'" ;;
	esac
	shift
done

# predicted <checkout> : the refs a build in that checkout would import - its own
# commit and the history behind it.  Cheap to compute and it is the only lookahead
# available: the checkout is the announcement.
predicted() {
	local d sha slug c
	for d in "${watch[@]+"${watch[@]}"}"; do
		sha=$(git -C "$d" rev-parse --short HEAD 2>/dev/null) || continue
		slug=$(branch_slug "$d") || continue
		[[ -n "$slug" && "$slug" != HEAD ]] || continue
		for c in "$sha" $(git -C "$d" log --format=%h -n 3 "$sha^" 2>/dev/null || true); do
			echo "cache-${slug}-${c}"
		done
	done
}

# One pass.  Returns 0 even when a peer went away mid-pass: a reconciler that
# exits on a transient failure is a cron job that silently stopped working.
pass() {
	local self inv missing src tag line t n=0
	self=$(self_ip)
	inv=$(inventory)

	# tags_on answers with the same bare tag names inventory answers with, so this
	# map is the whole difference between a pass that copies and a pass that looks.
	# An earlier draft keying it by full ref never matched, and a draft that built the
	# priority list from the raw inventory re-chased every ref on the cluster every
	# pass, which is how you get a log that says "1 ref brought over" once a second
	# for something skopeo had already skipped.
	declare -A have=()
	while read -r t; do [[ -n "$t" ]] && have[$t]=1; done < <(tags_on "$self")

	# A ref some build here is about to ask for is worth chasing before the ones
	# nobody has asked for yet; the rest of the sweep still happens in the pass.
	local -a prio=() rest=() missing=()
	local pred tag src
	pred=$(predicted)
	while read -r src tag; do
		[[ -n "${tag:-}" ]] || continue
		[[ -n "${have[$tag]:-}" ]] && continue
		if [[ -n "$pred" ]] && grep -qx -- "$tag" <<<"$pred"; then prio+=("$src $tag"); else rest+=("$src $tag"); fi
	done <<<"$inv"
	missing=(${prio[@]+"${prio[@]}"} ${rest[@]+"${rest[@]}"})

	# One pass may need several refs; a ref pulled this pass is "had" from now on,
	# so an earlier peer's copy of it is not chased again.
	declare -A taken=()
	local from
	for line in "${missing[@]+"${missing[@]}"}"; do
		read -r src tag <<<"$line"
		[[ -n "${taken[$tag]:-}" ]] && continue
		taken[$tag]=1
		from=""
		[[ -n "$pred" ]] && grep -qx -- "$tag" <<<"$pred" && from=" (watched)"
		if copy_ref "$src" "$self" "$tag"; then
			printf '%s: %s from %s, %s layers, %s in %ss%s\n' \
				"$(date +%T)" "$tag" "$src" "$LAYERS" "$(human "$BYTES_MOVED")" "$COPY_SECONDS" "$from"
			n=$((n + 1))
		else
			printf '%s: %s from %s failed, trying again next pass\n' "$(date +%T)" "$tag" "$src"
		fi
	done

	((verbose)) && printf '%s: %s refs here, %s wanted, %s brought over\n' \
		"$(date +%T)" "${#have[@]}" "${#missing[@]}" "$n"
	return 0
}

while :; do
	pass || true
	((once)) && break
	sleep "$interval"
done
