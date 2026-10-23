#!/bin/sh
# Calculate markers and blame from a live buffer selection on stdin.
set -u
JJ=jj
DIFF=diff
KAK=kak
lib=${0%/*}
. "$lib/quote.sh"
dir=$kak_opt_jj_dir
generation=$kak_opt_jj_generation
stamp=$kak_timestamp
identity=''
active=''
watcher=''
locked=false
job=''

valid() {
    [ -r "$dir/generation" ] || return 1
    current=''
    IFS= read -r current < "$dir/generation" 2>/dev/null || [ -n "$current" ]
    [ "$current" = "$generation" ]
}
quote() { kakquote "$1"; printf '%s' "$jj_quoted"; }
send() {
    valid || return 1
    kakquote "$1"
    printf "evaluate-commands -client '*' %s\n" "$jj_quoted" |
        "$KAK" -p "$kak_session" >/dev/null 2>&1
}
callback() {
    command=$1; shift
    for argument in "$dir" "$stamp" "$generation" "$identity" "$@"; do
        kakquote "$argument"
        command="$command $jj_quoted"
    done
    send "$command"
}
error() {
    valid || exit 0
    # Retain command diagnostics in the buffer's state directory.
    [ ! -f "$job/error" ] || cp "$job/error" "$dir/error"
    callback jj--expect || :
    { printf "set-option buffer jj_mark_file ''\nset-option buffer jj_optimistic_timestamp -1\n"
      printf 'set-option buffer jj_markers\nset-option buffer jj_annotations\njj--hold-markers\n'
      printf "set-option buffer jj_labels ''\nset-option buffer jj_column_width 0\nset-option buffer jj_error "; quote "$1"; printf '\n'
    } > "$dir/$generation.kak"
    callback jj--apply "$dir/$generation.kak" || :
    exit 1
}
cleanup() {
    trap - 0 HUP INT TERM
    [ -z "$watcher" ] || kill "$watcher" 2>/dev/null || :
    [ -z "$active" ] || kill -KILL "$active" 2>/dev/null || :
    [ -z "$watcher" ] || wait "$watcher" 2>/dev/null || :
    [ -z "$active" ] || wait "$active" 2>/dev/null || :
    $locked && rmdir "$dir/lock" 2>/dev/null || :
    [ -z "$job" ] || rm -rf "$job"
}
trap cleanup 0
trap 'error "refresh exceeded 10-second limit"' HUP INT TERM
valid || exit 0
job=$(mktemp -d "$dir/job.XXXXXXXX") || exit 1
# Cancel obsolete requests and enforce a ten-second request deadline.
owner=$$
(
    i=0
    while valid && [ "$i" -lt 100 ]; do sleep .1; i=$((i + 1)); done
    kill -TERM "$owner" 2>/dev/null || :
) &
watcher=$!
run() {
    "$@" <&0 2>"$job/error" &
    active=$!
    wait "$active"; status=$?
    active=''
    valid || exit 0
    return "$status"
}
jj_read() { run "$JJ" --ignore-working-copy --at-operation=@ --no-pager --color=never "$@"; }
run cat > "$job/raw" || exit 0
[ "$(wc -c < "$job/raw")" -le 1048576 ] || error 'live buffer exceeds 1 MiB limit'
[ "$(awk 'END {print NR}' "$job/raw")" -le 10000 ] || error 'live buffer exceeds 10000 line limit'
while ! mkdir "$dir/lock" 2>/dev/null; do valid || exit 0; sleep .1; done
locked=true

# Reconstruct file bytes from Kakoune's normalized LF and synthetic final newline.
: > "$job/live"
[ "$kak_opt_BOM" != utf8 ] || printf '\357\273\277' >> "$job/live"
LC_ALL=C awk -v final="$kak_opt_finaleol" -v eol="$kak_opt_eolformat" '
    { line[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            suffix = (eol == "crlf" ? "\r\n" : "\n")
            if (i == NR && (final == "missing" || (final == "ifnotempty" && NR == 1 && line[1] == ""))) suffix = ""
            printf "%s%s", line[i], suffix
        }
    }' "$job/raw" >> "$job/live"
file=$kak_buffile
newline='
'
case "$file" in *"$newline"*) error 'newline in filename is unsupported' ;; esac
parent=${file%/*}
while [ ! -d "$parent" ] && [ "$parent" != / ]; do parent=${parent%/*}; [ -n "$parent" ] || parent=/; done
cd -P "$parent" || error 'cannot access buffer directory'
jj_read workspace root > "$job/root" || error 'not a jj workspace, or workspace root query failed'
[ "$(wc -l < "$job/root")" -eq 1 ] || error 'newline in workspace root is unsupported'
IFS= read -r root < "$job/root"
# Find a lexical workspace prefix with the same physical path. This handles
# /var -> /private/var on macOS while retaining symlinks *inside* the workspace.
parent=$file
relative=''
while [ "$parent" != / ]; do
    leaf=${parent##*/}; parent=${parent%/*}; [ -n "$parent" ] || parent=/
    relative=$leaf${relative:+/}$relative
    physical=$(cd -P "$parent" 2>/dev/null && pwd -P) || continue
    [ "$physical" != "$root" ] || break
done
[ "$physical" = "$root" ] || error 'file outside resolved workspace'
cd -P "$root" || error 'cannot enter workspace'
rest=$relative; component_path=$root
while [ -n "$rest" ]; do
    component=${rest%%/*}; component_path=$component_path/$component
    [ ! -L "$component_path" ] || error 'symlinks are unsupported'
    case "$rest" in */*) rest=${rest#*/} ;; *) rest='' ;; esac
done
state_template='commit_id ++ "\n" ++ parents.len() ++ "\n" ++ conflict ++ "\n" ++ parents.map(|p| p.commit_id() ++ "\n" ++ p.conflict()).join("\n") ++ "\n"'
resolve() {
    jj_read log -r @ --no-graph -T "$state_template" > "$job/state" || return 1
    { IFS= read -r working; IFS= read -r parents; IFS= read -r conflict;
      IFS= read -r baseline; IFS= read -r parent_conflict;
    } < "$job/state"
    [ "$parents" = 1 ] || error 'requires exactly one working-copy parent'
    [ "$conflict" = false ] && [ "$parent_conflict" = false ] || error 'conflicted working-copy or parent revision'
    resolved=$working:$baseline
}
resolve || error 'cannot resolve working-copy parent'
identity=$resolved
callback jj--expect || exit 0
width=$kak_opt_jj_blame_width
[ "$width" -ge 8 ] || width=8
[ "$width" -le 80 ] || width=80
printf '%s\n%s\n%s\n%s\n' "$root" "$baseline" "$relative" "$width" > "$job/key"
cache=$dir/cache
if [ ! -r "$cache/key" ] || [ ! -r "$cache/base" ] || [ ! -r "$cache/annotations" ] ||
   ! "$DIFF" -q "$job/key" "$cache/key" >/dev/null 2>&1; then
    escaped=$(printf '%s' "$relative" | sed 's/\\/\\\\/g; s/"/\\"/g')
    fileset="root-file:\"$escaped\""
    jj_read file list -r "$baseline" -T 'file_type ++ "\n"' -- "$fileset" > "$job/kind" || error 'baseline file query failed'
    kind=$(cat "$job/kind")
    case "$kind" in
        '') : > "$job/base"; : > "$job/annotations" ;; # An absent baseline is empty.
        file)
            jj_read file show -r "$baseline" -T '' -- "$fileset" > "$job/base" || error 'baseline file show failed'
            [ "$(wc -c < "$job/base")" -le 1048576 ] || error 'baseline exceeds 1 MiB limit'
            [ "$(awk 'END {print NR}' "$job/base")" -le 10000 ] || error 'baseline exceeds 10000 line limit'
            template=$(sed "s/@WIDTH@/$width/g" "$lib/annotate.template")
            jj_read file annotate -r "$baseline" -T "$template" -- "$relative" > "$job/annotations" || error 'baseline annotation failed'
            ;;
        *) error 'unsupported baseline entry (symlink, tree, or conflict)' ;;
    esac
    valid || exit 0
    rm -rf "$cache"
    mkdir "$cache" || exit 0
    # Publish the readiness key after both data files so interrupted writes retry.
    for name in base annotations key; do mv "$job/$name" "$cache/$name" || exit 0; done
fi
# Reject NUL-containing input.
for text in "$cache/base" "$job/live"; do
    [ "$(LC_ALL=C tr -d '\000' < "$text" | wc -c)" -eq "$(wc -c < "$text")" ] || error 'binary file is unsupported'
done
old_count=$(awk 'END {print NR}' "$cache/base")
new_count=$(awk 'END {print NR}' "$job/live")
[ "$old_count" -le 10000 ] || error 'baseline exceeds 10000 line limit'
run "$DIFF" -U0 -- "$cache/base" "$job/live" > "$job/diff"
status=$?
[ "$status" -le 1 ] || error 'system diff failed'
flags=$job/flags
labels=$dir/$generation.labels
marks=$dir/$generation.marks
export width old_count new_count flags labels marks
run awk -f "$lib/map.awk" "$cache/annotations" "$job/diff" || error 'diff or annotation mapping failed'
# Verify the working-copy and parent IDs again before publishing.
resolve || error 'cannot recheck parent revision'
[ "$resolved" = "$identity" ] || error 'revision changed during refresh; refresh again'
valid || exit 0
{ printf 'set-option buffer jj_markers'; cat "$flags"
  printf "set-option buffer jj_annotations '0|%*s' " "$width" ''
  tr '\n' ' ' < "$labels"; printf '\njj--hold-markers\n'
  printf 'set-option buffer jj_labels '; quote "$labels"; printf '\n'
  printf 'set-option buffer jj_mark_file '; quote "$marks"; printf '\n'
  printf 'set-option buffer jj_optimistic_timestamp %s\n' "$stamp"
  printf 'set-option buffer jj_optimistic_lines %s\n' "$((new_count > 0 ? new_count : 1))"
  printf 'set-option buffer jj_column_width %s\n' "$width"
  printf "set-option buffer jj_error ''\n"
} > "$dir/$generation.kak"
callback jj--apply "$dir/$generation.kak" || :
