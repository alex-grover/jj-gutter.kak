#!/bin/sh
# Check hunk mapping and line endings with the selected diff executable.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
tmp=$(mktemp -d /tmp/jj-map-tests.XXXXXXXX)
trap 'rm -rf "$tmp"' 0
DIFF=${DIFF:-diff}
check() {
    printf '%b' "$1" > "$tmp/base"
    printf '%b' "$2" > "$tmp/live"
    old_count=$(awk 'END {print NR}' "$tmp/base")
    new_count=$(awk 'END {print NR}' "$tmp/live")
    awk 'END {for (i=1;i<=NR;i++) printf "%d\tabcdef\tbaseline-%d\n", i, i}' "$tmp/base" > "$tmp/annotations"
    "$DIFF" -U0 "$tmp/base" "$tmp/live" > "$tmp/diff" && status=0 || status=$?
    [ "$status" -le 1 ]
    flags=$tmp/flags; labels=$tmp/labels; width=20
    export old_count new_count flags labels width
    awk -f "$repo/lib/map.awk" "$tmp/annotations" "$tmp/diff"
    grep -F -q -- "$3" "$flags"
    [ -z "$4" ] || grep -F -q -- "$4" "$labels"
}
check 'a\nb\n' 'new\na\nb\n' '1|{JJAdded}+' '2|{JJBlame}{\\}baseline-1'
check 'a\nb\n' 'a\nnew\nb\n' '2|{JJAdded}+' '3|{JJBlame}{\\}baseline-2'
check 'a\nb\n' 'a\nb\nnew\n' '3|{JJAdded}+' ''
check 'a\nb\n' 'b\n' '1|{JJDeleted}-' '1|{JJBlame}{\\}baseline-2'
check 'a\nb\n' 'a\n' '1|{JJDeleted}-' '1|{JJBlame}{\\}baseline-1'
check 'a\nb\n' '' '1|{JJDeleted}-' 'uncommitted'
check 'a\nb\n' 'changed\n' '1|{JJModified}*' 'uncommitted'
check '' '' '0| ' 'uncommitted'
check '' 'new\n' '1|{JJAdded}+' 'uncommitted'
check 'a' 'a\n' '1|{JJModified}~' 'uncommitted'
check 'a\r\n' 'a\r\n' '0| ' 'baseline-1'
printf '11 mapping cases passed (%s)\n' "$DIFF"
