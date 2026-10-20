#!/bin/bash

set -e

#
#  usage:
#    ./test.sh                    run test/file-cache.sh against the cluster
#    ./test.sh <name>             run test/<name>.sh (registry, file-cache, ...)
#    ./test.sh restore            restore the cluster first, then run it
#    ./test.sh watch [restore]    re-run on every change with entr
#
#  `restore` matters for cache work: every test has to start with empty
#  builder caches on every node, otherwise a "cache hit" might just be the
#  node remembering the last run.
#

which_test="file-cache"

do_restore="0"
do_watch="0"

while [[ "${1:-}" == restore || "${1:-}" == watch || "${1:-}" == watch-restore ]]; do
	case "$1" in
	restore) do_restore="1" ;;
	watch) do_watch="1" ;;
	watch-restore)
		do_watch="1"
		do_restore="1"
		;;
	esac
	shift
done

if [[ "${1:-}" != "" ]]; then
	which_test="$1"
	shift
fi

test_script="test/${which_test}.sh"
[[ -f "$test_script" ]] || {
	echo "test.sh: no such test '$which_test' (looked for $test_script)" >&2
	ls test/*.sh | grep -v "lib.sh$" | sed 's|test/||; s|\.sh$||; s/^/  /' >&2
	exit 1
}

args=""
for arg in "$@"; do
	printf -v quoted_arg "%q" "$arg"
	args="${args} ${quoted_arg}"
done

command=""
if [[ "$do_restore" == "1" ]]; then
	command="./env.sh restore"
fi
command="${command}${command:+ && }bash $test_script$args"
command="set -e; $command"

if [[ "$do_watch" == "1" ]]; then
	command -v entr >/dev/null || {
		echo "test.sh: watch needs entr (sudo pacman -S entr / brew install entr)" >&2
		exit 1
	}
	find test Vagrantfile | entr -n -cc -s "$command"
else
	bash -c "$command"
fi

exit 0
