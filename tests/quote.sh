#!/bin/sh
# Round-trip quoted metadata through Kakoune's argument parser.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
. "$repo/lib/quote.sh"
tmp=$(mktemp -d /tmp/jj-quote-tests.XXXXXXXX)
trap 'rm -rf "$tmp"' 0
cases=0
for value in '' plain "a'b''c" 'a "quote" and \ path' 'café 世界 | {Error}' '%sh{printf unexpected}' 'first
second
'; do
    kakquote "$value"
    printf '%s' "$value" > "$tmp/expected"
    printf '%s\n' "define-command -params 1 capture %{ echo -to-file $tmp/result %arg{1} }" "capture $jj_quoted" 'quit!' > "$tmp/commands.kak"
    kak -n -ui dummy -e "source '$tmp/commands.kak'"
    diff -q "$tmp/expected" "$tmp/result" >/dev/null
    cases=$((cases+1))
done
printf '%s metadata quoting cases passed\n' "$cases"
