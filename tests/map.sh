#!/bin/sh
# Check hunk mapping and line endings with the selected diff executable.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
tmp=$(mktemp -d /tmp/jj-map-tests.XXXXXXXX)
trap 'rm -rf "$tmp"' 0
DIFF=${DIFF:-diff}
cases=0
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
    cases=$((cases + 1))
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
# Pair a changed declaration with its closest replacement, not inserted blanks.
check 'export type DetectedProject = {\n' '\n\n export type DetectedProject = {\n' '1|{JJAdded}+' '3|{JJBlame}{\\}uncommitted'
grep -F -q '2|{JJAdded}+' "$flags"
grep -F -q '3|{JJModified}~' "$flags"
check 'export type DetectedProject = {\n' ' export type DetectedProject = {\n\n\n' '1|{JJModified}~' ''
grep -F -q '2|{JJAdded}+' "$flags"
grep -F -q '3|{JJAdded}+' "$flags"
check 'first\nlast\n' '\n first\n\n last\n' '2|{JJModified}~' ''
grep -F -q '1|{JJAdded}+' "$flags"
grep -F -q '3|{JJAdded}+' "$flags"
grep -F -q '4|{JJModified}~' "$flags"
check 'const answer = 1\n' 'inserted declaration\nconst answer = 2\n' '2|{JJModified}~' ''
grep -F -q '1|{JJAdded}+' "$flags"
check '\nfoo\n' '\n\n foo\n' '2|{JJAdded}+' '1|{JJBlame}{\\}baseline-1'
grep -F -q '3|{JJModified}~' "$flags"
check '--- old\n+++ stable\n' '\n--- old \n+++ stable\n' '2|{JJModified}~' '3|{JJBlame}{\\}baseline-2'
grep -F -q '1|{JJAdded}+' "$flags"
check 'first\nremoved\nlast\n' '\n first\n last\n' '1|{JJAdded}+' ''
grep -F -q '2|{JJModified}~' "$flags"
grep -F -q '3|{JJModified}*' "$flags"
check 'const x = "a b"\n' 'const x = "ab"\n' '1|{JJModified}~' '1|{JJBlame}{\\}uncommitted'
# Large replacement hunks stay on the bounded linear path.
before=$(awk 'BEGIN {for (i=1;i<=80;i++) print "old-" i}')
after=$(awk 'BEGIN {for (i=1;i<=80;i++) print "new-" i}')
check "$before\n" "$after\n" '1|{JJModified}~' ''
grep -F -q '80|{JJModified}~' "$flags"
after=$(awk 'BEGIN {print ""; print ""; for (i=1;i<=80;i++) print " old-" i}')
check "$before\n" "$after\n" '1|{JJAdded}+' ''
grep -F -q '2|{JJAdded}+' "$flags"
grep -F -q '3|{JJModified}~' "$flags"
grep -F -q '82|{JJModified}~' "$flags"
printf '%s mapping cases passed (%s)\n' "$cases" "$DIFF"
