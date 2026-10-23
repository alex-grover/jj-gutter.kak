#!/bin/sh
# Exercise provisional marker and annotation transforms with cached line data.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
tmp=$(mktemp -d /tmp/jj-optimistic-tests.XXXXXXXX)
trap 'rm -rf "$tmp"' 0
previous_count=3; view_width=20; edit_stamp=2; view_base=$tmp/result
export previous_count view_width edit_stamp view_base
cases=0
awk 'BEGIN { q=sprintf("%c",39); for(i=1;i<=3;i++) printf "%s%d|{JJBlame}{\\\\}author-%d%s\n", q,i,i,q }' > "$tmp/labels"
run() {
    action=$1; edit_line=$2; new_count=$3
    touch_original=${5:-false}; empty_before=${6:-false}; empty_after=${7:-false}
    printf '%b' "$4" > "$tmp/marks"
    export action edit_line new_count touch_original empty_before empty_after
    cases=$((cases + 1))
    awk -f "$repo/lib/optimistic.awk" "$tmp/marks" "$tmp/labels" > "$tmp/update.kak"
}
run above 1 4 ''
grep -qx '1 +' "$view_base.marks"
grep -F -q '2|{JJBlame}{\\}author-1' "$view_base.labels"
grep -F -q '4|{JJBlame}{\\}author-3' "$view_base.labels"
run below 1 4 ''
grep -qx '2 +' "$view_base.marks"
grep -F -q '1|{JJBlame}{\\}author-1' "$view_base.labels"
run split 1 4 ''
grep -qx '1 ~' "$view_base.marks"
grep -qx '2 +' "$view_base.marks"
grep -F -q '3|{JJBlame}{\\}author-2' "$view_base.labels"
run modify 2 3 '2 +'
grep -qx '2 +' "$view_base.marks"
grep -F -q '2|{JJBlame}{\\}uncommitted' "$view_base.labels"
run modify 1 3 '1 -'
grep -F -qx '1 *' "$view_base.marks"
run join 1 2 ''
grep -qx '1 ~' "$view_base.marks"
grep -qx '2 -' "$view_base.marks"
grep -F -q '2|{JJBlame}{\\}author-3' "$view_base.labels"
run above 1 4 '' true
grep -qx '1 +' "$view_base.marks"
grep -qx '2 ~' "$view_base.marks"
# Removing an added empty row preserves the surviving baseline attribution.
run join 1 2 '1 +' false true false
[ ! -s "$view_base.marks" ]
grep -F -q '1|{JJBlame}{\\}author-2' "$view_base.labels"
run join 1 2 '2 +' false false true
[ ! -s "$view_base.marks" ]
grep -F -q '1|{JJBlame}{\\}author-1' "$view_base.labels"
run join 1 2 '1 +\n2 +'
grep -qx '1 +' "$view_base.marks"
run join 1 2 '' false true false
grep -qx '1 -' "$view_base.marks"
grep -F -q '1|{JJBlame}{\\}author-2' "$view_base.labels"
run join 1 2 '1 +'
grep -qx '1 ~' "$view_base.marks"
grep -q uncommitted "$view_base.labels"
# Whole-line removal shifts surviving metadata and anchors baseline deletions.
run remove 1 2 '1 +'
[ ! -s "$view_base.marks" ]
grep -F -q '1|{JJBlame}{\\}author-2' "$view_base.labels"
run remove 2 2 ''
grep -qx '2 -' "$view_base.marks"
grep -F -q '2|{JJBlame}{\\}author-3' "$view_base.labels"
run remove 3 2 ''
grep -qx '2 -' "$view_base.marks"
grep -F -q '2|{JJBlame}{\\}author-2' "$view_base.labels"
if run join 3 2 ''; then printf 'invalid join accepted\n' >&2; exit 1; fi
printf '%s optimistic update cases passed\n' "$cases"
