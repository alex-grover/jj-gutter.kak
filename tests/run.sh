#!/bin/sh
# Integration checks in disposable non-colocated jj workspaces.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
real_jj=$(command -v jj)
real_kak=$(command -v kak)
tmp=$(mktemp -d /tmp/jj-gutter-tests.XXXXXXXX)
session=jjg-$$
pid=''
other_pid=''
passed=0
stop() {
    [ -z "$pid" ] || { printf 'kill!\n' | "$real_kak" -p "$session" >/dev/null 2>&1 || :; wait "$pid" 2>/dev/null || :; }
    [ -z "$other_pid" ] || wait "$other_pid" 2>/dev/null || :
    pid=''; other_pid=''
}
cleanup() { status=$?; stop; [ "$status" -ne 0 ] || rm -rf "$tmp"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
fail() {
    printf 'FAIL: %s\nArtifacts: %s\n' "$1" "$tmp" >&2
    if [ -n "$pid" ]; then
        printf "evaluate-commands -client client0 %%{ echo -to-file '$tmp/failed.options' %%val{buffile} %%opt{jj_labels} %%opt{jj_show_blame} %%opt{jj_generation} %%opt{jj_revision} %%opt{jj_error}; echo -to-file '$tmp/failed.state' %%opt{jj_state} }\n" | "$real_kak" -p "$session" || :
        sleep .1
        [ ! -f "$tmp/failed.state" ] || cp -R "$(cat "$tmp/failed.state")" "$tmp/worker-state" 2>/dev/null || :
    fi
    exit 1
}
ok() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
jj_fixture() {
    "$real_jj" --config 'user.name="Test {Error} | Author"' --config 'user.email="fixture@example.invalid"' "$@" 2>"$tmp/setup.log"
}
mkdir "$tmp/bin"
# Record jj invocations and provide controlled pauses and failures.
cat > "$tmp/bin/jj" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TRACE"
if [ -f "$TEST_PAUSE_FILE" ]; then
    : > "$TEST_PAUSE_FILE.started"
    while [ -f "$TEST_PAUSE_FILE" ]; do sleep .02; done
fi
case " $* " in
    *' file annotate '*)
        if [ -n "${TEST_BLOCK:-}" ]; then printf '%s\n' "$$" > "$TEST_BLOCK_PID"; exec sleep 30; fi
        [ -z "${TEST_DELAY:-}" ] || sleep "$TEST_DELAY"
        ;;
    *' file list '*) [ -z "${TEST_FAIL:-}" ] || { printf 'test failure\n' >&2; exit 42; } ;;
esac
exec "$TEST_REAL_JJ" "$@"
SHIM
chmod +x "$tmp/bin/jj"
export TEST_REAL_JJ="$real_jj" TEST_TRACE="$tmp/trace" TEST_DELAY='' TEST_PAUSE_FILE="$tmp/pause"
PATH=$tmp/bin:$PATH
export PATH
ws=$tmp/workspace
jj_fixture git init --no-colocate "$ws"
file=$ws/"café ' \" [x] | {y} \\.txt"
printf 'alpha\ncafé 世界\tone\nlast\n' > "$file"
jj_fixture -R "$ws" new
jj_fixture -R "$ws" describe @- -m "source {Error} | O'Neil \\ test"
[ ! -e "$ws/.git" ] || fail 'workspace unexpectedly colocated'

# Quote arguments for Kakoune command strings.
q() { printf "'"; printf '%s' "$1" | sed "s/'/''/g"; printf "'"; }
client() {
    name=$1; shift
    rm -f "$tmp/ack"
    { printf 'evaluate-commands -client '; q "$name"; printf ' '; q "$*; echo -to-file '$tmp/ack' done"; printf '\n'; } | "$real_kak" -p "$session"
    attempts=0
    until [ -f "$tmp/ack" ]; do
        attempts=$((attempts + 1)); [ "$attempts" -lt 100 ] || fail "Kakoune command failed: $*"
        sleep .01
    done
}
command() { client client0 "$@"; }
get() { command "echo -to-file $(q "$tmp/value") %opt{$1}"; cat "$tmp/value"; }
flags_have() { get jj_flags | grep -F -q "$1"; }
column_line_has() { get jj_column | grep -E -q "(^| )$1[|][^ ]*$2"; }
wait_flags() {
    i=0
    # Wait for this generation's label result and the requested marker state.
    while ! flags_have "$1" || ! current_result || { [ "$1" = '0| ' ] && get jj_flags | grep -q JJ; }; do
        i=$((i + 1)); [ "$i" -lt 60 ] || fail "expected flags: $1; actual=$(get jj_flags); error=$(get jj_error)"
        sleep .1
    done
}
start() {
    : > "$TEST_TRACE"
    init="source $(q "$repo/rc/jj-gutter.kak"); set-option global jj_check_seconds 60; edit $(q "$1"); jj-enable"
    "$real_kak" -n -ui dummy -s "$session" -e "$init" >"$tmp/kak.out" 2>"$tmp/kak.err" &
    pid=$!
    i=0
    until "$real_kak" -l | grep -q "^$session$"; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'session startup'; sleep .1; done
}
refresh() { command jj-refresh; }
annotates() { grep -c ' file annotate ' "$TEST_TRACE" || :; }
current_result() {
    case "$(get jj_labels)" in */"$(get jj_generation)".labels) return 0 ;; *) return 1 ;; esac
}
# Extract widget-column counts from native draw notifications.
json_widths() { awk '/"method": "draw"/ { value=$0; sub(/^.*,[[:space:]]*/, "", value); sub(/[^0-9].*$/, "", value); print value }'; }
# Count fixture labels and display rows in the latest draw.
json_label_count() { awk '/"method": "draw"/ { value=$0 } END { print gsub(/Test \{Error\}/, "", value) }'; }
json_row_count() { awk '/"method": "draw"/ { value=$0 } END { print gsub(/\], \[/, "", value) + 1 }'; }

# Start fresh sessions with the backend held before workspace discovery. Check
# every draw, including the very first frame, before and after the first result.
for startup_blame in true false; do
    : > "$TEST_TRACE"
    rm -f "$TEST_PAUSE_FILE.started"
    : > "$TEST_PAUSE_FILE"
    mkfifo "$tmp/startup-$startup_blame.input"
    exec 3<> "$tmp/startup-$startup_blame.input"
    # -E enables before any client/window exists, as a normal kakrc does.
    startup_global="source $(q "$repo/rc/jj-gutter.kak"); set-option global jj_check_seconds 60; set-option global jj_blame_width 28; set-option global jj_show_blame $startup_blame; jj-enable"
    startup_init="edit $(q "$file"); add-highlighter window/test-numbers number-lines -relative -min-digits 4 -separator '  '; declare-option line-specs test_diagnostics; set-option window test_diagnostics %val{timestamp} '0| ' '2|!'; add-highlighter window/test-diagnostics flag-lines default test_diagnostics; jj--tick"
    "$real_kak" -n -ui json -s "$session" -E "$startup_global" -e "$startup_init" < "$tmp/startup-$startup_blame.input" > "$tmp/startup-$startup_blame.jsonl" 2> "$tmp/startup.err" &
    pid=$!
    expected=8
    [ "$startup_blame" = false ] || expected=36
    i=0
    until [ -f "$TEST_PAUSE_FILE.started" ] && [ -n "$(json_widths < "$tmp/startup-$startup_blame.jsonl")" ]; do
        i=$((i+1)); [ "$i" -lt 50 ] || fail 'initial paused render setup'
        sleep .1
    done
    [ -z "$(get jj_labels)" ] || fail 'startup test did not pause before the first result'
    flags_have '0| ' || fail 'initial diff reservation missing'
    get jj_flags | grep -q JJ && fail 'startup placeholder contains a change icon'
    get jj_column | grep -Eq 'Test|JJBlame|uncommitted' && fail 'startup placeholder contains blame'
    json_widths < "$tmp/startup-$startup_blame.jsonl" > "$tmp/startup-widths"
    grep -v "^$expected\$" "$tmp/startup-widths" > "$tmp/shifted-startup-widths" || :
    [ ! -s "$tmp/shifted-startup-widths" ] || fail "startup did not reserve $expected cells from the first draw"
    rm "$TEST_PAUSE_FILE"
    wait_flags '0| '
    sleep .1
    json_widths < "$tmp/startup-$startup_blame.jsonl" > "$tmp/startup-widths"
    grep -v "^$expected\$" "$tmp/startup-widths" > "$tmp/shifted-startup-widths" || :
    [ ! -s "$tmp/shifted-startup-widths" ] || fail 'first result changed the reserved startup width'
    stop
    exec 3>&-
    ok "startup reserves space before any jj result (annotation=$startup_blame)"
done

operation=$("$real_jj" --ignore-working-copy -R "$ws" op log --limit 1 -T id)
start "$file"
wait_flags '0| '
[ -z "$(get jj_error)" ] || fail 'initial baseline'
ok 'clean, non-colocated workspace; UTF-8 / spaces / quotes / brackets / pipes / backslash filename'

# Keep the rendering client's input open while inspecting native draw events.
mkfifo "$tmp/render.input"
exec 3<> "$tmp/render.input"
render_init="rename-client renderer; edit $(q "$file"); set-option window jj_show_blame true; add-highlighter window/test-numbers number-lines -relative -min-digits 4 -separator '  '; declare-option line-specs test_diagnostics; set-option window test_diagnostics %val{timestamp} '0| ' '2|!'; add-highlighter window/test-diagnostics flag-lines default test_diagnostics; jj--tick"
"$real_kak" -c "$session" -ui json -e "$render_init" < "$tmp/render.input" > "$tmp/render.jsonl" 2> "$tmp/render.err" &
other_pid=$!
i=0
until [ "$(json_widths < "$tmp/render.jsonl" | tail -n 1)" = 48 ]; do
    i=$((i+1)); [ "$i" -lt 50 ] || fail 'initial rendered gutter width (40 blame + 1 diff + 6 numbers + 1 diagnostics)'
    sleep .1
done
i=0
until [ "$(json_label_count < "$tmp/render.jsonl")" = 3 ]; do
    i=$((i+1)); [ "$i" -lt 50 ] || fail 'native column does not label all three logical lines'
    sleep .1
done
# Verify one label per logical line while UTF-8/tabbed source wraps at 12 cells.
printf '%s\n' '{"jsonrpc":"2.0","method":"resize","params":[24,60]}' >&3
client renderer 'add-highlighter window/test-wrap wrap'
i=0
until [ "$(json_row_count < "$tmp/render.jsonl")" -gt 3 ]; do
    i=$((i+1)); [ "$i" -lt 50 ] || fail 'native wrapping test did not create continuation rows'
    sleep .1
done
[ "$(json_label_count < "$tmp/render.jsonl")" = 3 ] || fail 'wrapped lines duplicate or hide blame labels'
client renderer 'remove-highlighter window/test-wrap'
printf '%s\n' '{"jsonrpc":"2.0","method":"resize","params":[24,80]}' >&3
client renderer jj-blame-toggle
i=0
until [ "$(json_widths < "$tmp/render.jsonl" | tail -n 1)" = 8 ]; do
    i=$((i+1)); [ "$i" -lt 50 ] || fail 'blame toggle did not remove the annotation width'
    sleep .1
done
client renderer jj-blame-toggle
i=0
until [ "$(json_label_count < "$tmp/render.jsonl")" = 3 ]; do
    i=$((i+1)); [ "$i" -lt 50 ] || fail 'blame toggle did not restore cached labels'
    sleep .1
done
ok 'native column labels all lines, wraps once, and toggles cached annotations'

# Pause a refresh after deleting the prefix from a marked line.
client renderer "select 1.1,1.1; execute-keys 'iSHIFT<esc>'; jj--tick"
wait_flags '1|{JJModified}~'
get jj_annotations > "$tmp/cached-annotations"
first_frame=$(wc -l < "$tmp/render.jsonl")
: > "$TEST_PAUSE_FILE"
client renderer 'select 1.1,1.5'
printf '%s\n' '{"jsonrpc":"2.0","method":"keys","params":["d"]}' >&3
i=0
until [ -f "$TEST_PAUSE_FILE.started" ]; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'paused refresh setup'; sleep .02; done
flags_have '0| ' || fail 'pending diff width reservation missing'
flags_have '1|{JJModified}~' || fail 'previous icon disappeared while recalculating'
# Editing through a client with blame closed must retain the open client's data.
command "select 2.1,2.1; execute-keys -with-hooks 'aX<esc>'; jj--tick"
command "execute-keys -with-hooks u; jj--tick"
tail -n +$((first_frame + 1)) "$tmp/render.jsonl" > "$tmp/pending-frames"
grep -F -q '"contents": "~"' "$tmp/pending-frames" || fail 'previous icon not rendered during pending refresh'
awk '/"method": "draw"/ && !index($0, "\"contents\": \"~\"") { missing=1 } END {exit missing}' "$tmp/pending-frames" || fail 'previous icon flickered before the pending-refresh frame'
client renderer "echo -to-file '$tmp/pending-column' %opt{jj_column}"
grep -q '0|' "$tmp/pending-column" || fail 'pending annotation width reservation missing'
get jj_annotations > "$tmp/pending-annotations"
diff -q "$tmp/cached-annotations" "$tmp/pending-annotations" >/dev/null || fail 'cached annotations changed while recalculating'
grep -q uncommitted "$tmp/pending-column" || fail 'pending annotation lost its cached changed-line label'
grep -q Test "$tmp/pending-column" || fail 'pending annotation lost its cached historical labels'
awk '/"method": "draw"/ { value=$0; if (gsub(/Test \{Error\}/,"",value) != 2 || !index(value,"uncommitted")) missing=1 } END {exit missing}' "$tmp/pending-frames" || fail 'blame flickered before the pending-refresh frame'
# Exercise width anchors during line insertion and complete-buffer deletion.
client renderer "select 1.1,1.1; execute-keys -with-hooks 'iNEW<ret><esc>'; jj--tick"
flags_have '1|{JJModified}~' || fail 'previous icon did not remain at its last calculated line'
rm "$TEST_PAUSE_FILE"
wait_flags '1|{JJAdded}+'
get jj_flags | grep -q JJModified && fail 'completed refresh did not replace old markers'
: > "$TEST_PAUSE_FILE"
client renderer "execute-keys '%d'"
client renderer jj--tick
sleep .1
rm "$TEST_PAUSE_FILE"
wait_flags '1|{JJModified}*'
client renderer "edit! $(q "$file"); jj-refresh"
wait_flags '0| '
sleep .1
tail -n +$((first_frame + 1)) "$tmp/render.jsonl" | json_widths > "$tmp/edit-widths"
[ -s "$tmp/edit-widths" ] || fail 'no edit redraws recorded'
grep -v '^48$' "$tmp/edit-widths" > "$tmp/shifted-widths" || :
[ ! -s "$tmp/shifted-widths" ] || fail 'source shifted during edit, deletion, or pending/completed refresh'
# Reset the view before Kakoune reuses it for another client.
client renderer 'set-option window jj_show_blame false; jj--line; remove-highlighter window/test-numbers; remove-highlighter window/test-diagnostics'
printf 'evaluate-commands -client renderer quit\n' | "$real_kak" -p "$session"
wait "$other_pid"; other_pid=''
exec 3>&-
ok 'native icons persist until replacement; widths stay fixed through pending refreshes'

command jj-blame-toggle
for row in 1 2 3; do
    column_line_has "$row" Test || fail "annotation missing on logical line $row"
done
get jj_column > "$tmp/all-lines-column"
command 'select 2.1,2.1; jj--tick'
get jj_column > "$tmp/after-cursor-column"
diff -q "$tmp/all-lines-column" "$tmp/after-cursor-column" >/dev/null || fail 'cursor movement changed all-line annotations'
[ "$(annotates)" -eq 1 ] || fail 'cursor reran annotate'
ok 'column shows all logical lines and cursor movement reuses unchanged annotations'

# Two new blank lines and a leading space belong to one replacement hunk.
command "select 1.1,1.1; execute-keys 'i<ret><ret><space><esc>'; jj--tick"
wait_flags '3|{JJModified}~'
flags_have '1|{JJAdded}+' || fail 'first inserted newline was not added'
flags_have '2|{JJAdded}+' || fail 'second inserted newline was not added'
for row in 1 2 3; do
    column_line_has "$row" uncommitted || fail 'changed replacement line inherited historical blame'
done
column_line_has 4 Test || fail 'unchanged row lost attribution beside a refined replacement'
command 'execute-keys u; jj--tick'
wait_flags '0| '
ok 'inserted newlines are added and the whitespace-edited existing line is modified'

# Unsaved edit, insertion, then deletion; inspect native line-spec options.
command "select 1.1,1.1; execute-keys 'iUNSAVED<esc>'"
command jj--tick
wait_flags '1|{JJModified}~'
column_line_has 1 uncommitted || fail 'modified line inherited historical blame'
column_line_has 2 Test || fail 'unchanged line lost attribution beside a modification'
column_line_has 3 Test || fail 'last line annotation missing beside a modification'
grep -q UNSAVED "$file" && fail 'plugin saved unsaved edits'
command "execute-keys u; select 1.1,1.1; execute-keys 'iinserted<ret><esc>'"
command jj--tick
wait_flags '1|{JJAdded}+'
command 'select 2.1,2.1; jj--tick'
column_line_has 1 uncommitted || fail 'inserted line inherited historical blame'
column_line_has 2 Test || fail 'unchanged line lost attribution after insertion'
column_line_has 4 Test || fail 'last line lost attribution after insertion'
command 'select 1.1,1.9; execute-keys d; select 1.1,1.6; execute-keys d'
command jj--tick
wait_flags '1|{JJDeleted}-'
column_line_has 1 Test || fail 'unchanged line lost attribution after deletion'
column_line_has 2 Test || fail 'last line lost attribution after deletion'
get jj_column | grep -E -q '(^| )3[|]' && fail 'deleted row retained an annotation'
[ "$(annotates)" -eq 1 ] || fail 'edits reran cached annotate'
[ "$("$real_jj" --ignore-working-copy -R "$ws" op log --limit 1 -T id)" = "$operation" ] || fail 'plugin modified jj operation log'
ok 'unsaved modification/insertion/deletion, blame mapping, no snapshots or saves'

# Compare yanked text and an explicit test-only save, with the column enabled.
get jj_column | grep -q Test || fail 'annotation not active during invariance test'
command "execute-keys '%\"zy'; evaluate-commands %sh{ printf %s \"\$kak_reg_z\" > '$tmp/copied' }; write -force '$tmp/saved'"
diff -q "$tmp/copied" "$tmp/saved" >/dev/null || fail 'annotation changed copied/saved source'
ok 'column text is absent from yanks and explicit test-only saves'

# Reload source before exercising an external parent revision change.
command "edit! $(q "$file"); jj-refresh"
wait_flags '0| '
printf 'external\ncafé 世界\tone\nlast\n' > "$file"
jj_fixture -R "$ws" new
refresh
wait_flags '1|{JJModified}~'
printf 'alpha\ncafé 世界\tone\nlast\n' > "$file"
jj_fixture -R "$ws" new
command 'set-option global jj_check_seconds 1'
sleep 1.1
command jj--tick
wait_flags '0| '
ok 'external jj new changes observed by refresh and bounded idle check'

# Both clients show all lines regardless of cursor; toggles remain independent.
command "set-option global jj_check_seconds 60; set-option window jj_show_blame true; set-option window jj_line_key ''; jj--tick"
"$real_kak" -c "$session" -ui dummy -e "rename-client second; edit $(q "$file"); jj-blame-toggle" >"$tmp/other.out" 2>"$tmp/other.err" &
other_pid=$!
sleep .3
command 'select 1.1,1.1; jj--tick'
i=0
until get jj_column | grep -q '1|{JJBlame}'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'first client column not ready'; sleep .1; done
client second 'select 3.1,3.1; jj--tick'
client second "echo -to-file '$tmp/second-column' %opt{jj_column}"
get jj_column > "$tmp/first-column"
for row in 1 2 3; do
    grep -E -q "(^| )$row[|][^ ]*Test" "$tmp/first-column" || fail 'first client omitted a line'
    grep -E -q "(^| )$row[|][^ ]*Test" "$tmp/second-column" || fail 'second client omitted a line'
done
diff -q "$tmp/first-column" "$tmp/second-column" >/dev/null || fail 'client cursors changed all-line attribution'
client second jj-blame-toggle
client second "echo -to-file '$tmp/second-column' %opt{jj_column}"
client second "echo -to-file '$tmp/second-toggle' %opt{jj_show_blame}"
grep -qx false "$tmp/second-toggle" || fail 'second client toggle failed'
diff -q "$tmp/first-column" "$tmp/second-column" >/dev/null || fail 'toggle discarded shared cached annotations'
get jj_column > "$tmp/first-column-after-toggle"
diff -q "$tmp/first-column" "$tmp/first-column-after-toggle" >/dev/null || fail 'second client toggle affected first'
ok 'two clients show all lines with independent column toggles'
printf 'evaluate-commands -client second quit\n' | "$real_kak" -p "$session"
wait "$other_pid"; other_pid=''

# New/empty/absent files and deletions through empty buffers.
new=$ws/new
: > "$new"
command "edit $(q "$new")"
wait_flags '0| '
command "execute-keys 'iadded<esc>'; jj--tick"
wait_flags '1|{JJAdded}+'
[ ! -s "$new" ] || fail 'new empty file was saved'
command "edit $(q "$file"); execute-keys '%d'; jj--tick"
i=0
until get jj_flags | grep -Eq '\{JJ(Deleted|Modified)\}[-*]'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'empty-buffer deletion'; sleep .1; done
ok 'new/empty files and deletion to empty buffer'

# Multi-buffer state, outside-workspace clearing, closure cleanup.
directory=$(get jj_dir)
state=$(get jj_state)
printf 'outside\n' > "$tmp/outside"
command "edit '$tmp/outside'"
sleep .3
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'stale gutter outside workspace'
command "delete-buffer! $(q "$file")"
[ ! -d "$directory" ] || fail 'buffer state not removed'
command jj-disable
[ ! -d "$state" ] || fail 'session state not removed on disable'
ok 'buffer switching, outside-workspace clearing, buffer/disable cleanup'
stop

# Compare saved disk changes with the parent baseline.
printf 'saved change\ncafé 世界\tone\nlast\n' > "$file"
start "$file"
wait_flags '1|{JJModified}~'
stop
ok 'saved disk modification compared to the parent'

# Verify path invalidation independently of text changes.
start "$file"
wait_flags '1|{JJModified}~'
command "rename-buffer -file '$ws/renamed-buffer'; jj--tick"
wait_flags '1|{JJAdded}+'
command jj-blame-toggle
get jj_column | grep -q uncommitted || fail 'buffer rename retained old-path blame'
stop
ok 'buffer path changes invalidate mappings even without text edits'

# Exercise identity and generation guards during an edit/refresh race.
printf 'alpha\ncafé 世界\tone\nlast\n' > "$file"
TEST_DELAY=.8; export TEST_DELAY
start "$file"
i=0
until grep -q ' file annotate ' "$TEST_TRACE"; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'delayed annotate not started'; sleep .1; done
command "execute-keys 'iracing<esc>'; jj--tick"
wait_flags '1|{JJModified}~'
command jj-blame-toggle
column_line_has 1 uncommitted || fail 'stale blame after async edit'
column_line_has 2 Test || fail 'unchanged row lost attribution after async edit'
directory=$(get jj_dir); generation=$(get jj_generation); revision=$(get jj_revision)
command "echo -to-file '$tmp/stamp' %val{timestamp}"
stamp=$(cat "$tmp/stamp")
printf "set-option buffer jj_error 'STALE APPLIED'\n" > "$tmp/stale.kak"
for mismatch in buffer timestamp generation revision; do
    identity=$directory; request_stamp=$stamp; request_generation=$generation; request_revision=$revision
    case "$mismatch" in
        buffer) identity=${directory}wrong ;;
        timestamp) request_stamp=0 ;;
        generation) request_generation=0 ;;
        revision) request_revision=wrong ;;
    esac
    command "jj--apply $(q "$identity") $(q "$request_stamp") $(q "$request_generation") $(q "$request_revision") '$tmp/stale.kak'"
    [ "$(get jj_error)" != 'STALE APPLIED' ] || fail "stale $mismatch accepted"
done
stop
TEST_DELAY=''
ok 'asynchronous edit race and all four stale-response guards'

# A revision changing while annotate runs is rejected before publication.
TEST_DELAY=.8
start "$file"
i=0
until grep -q ' file annotate ' "$TEST_TRACE"; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'revision race setup'; sleep .1; done
printf 'changed parent\ncafé 世界\tone\nlast\n' > "$file"
jj_fixture -R "$ws" new
i=0
until get jj_error | grep -q 'revision changed'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'revision race not rejected'; sleep .1; done
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'mixed revision markers published'
stop
TEST_DELAY=''
ok 'revision identity rechecked before publishing asynchronous data'

TEST_FAIL=1; export TEST_FAIL
start "$file"
i=0
until get jj_error | grep -q 'file query failed'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'command error misclassified'; sleep .1; done
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'command error rendered as new file'
stop
TEST_FAIL=''
ok 'command failures are not treated as absent baseline files'

TEST_BLOCK=1; TEST_BLOCK_PID=$tmp/blocked-pid; export TEST_BLOCK TEST_BLOCK_PID
start "$file"
i=0
until [ -f "$TEST_BLOCK_PID" ]; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'blocking job setup'; sleep .1; done
state=$(get jj_state)
blocked=$(cat "$TEST_BLOCK_PID")
command jj-disable
sleep .4
[ ! -d "$state" ] || fail 'disable retained temporary state'
kill -0 "$blocked" 2>/dev/null && fail 'disable left child running'
stop
TEST_BLOCK=''
ok 'disable cancels an expensive subprocess and removes temporary state'

# Reject working-copy revisions with multiple parents.
base=$("$real_jj" --ignore-working-copy -R "$ws" log -r @- --no-graph -T commit_id)
jj_fixture -R "$ws" new 'root()'
printf 'other\n' > "$ws/other"
jj_fixture -R "$ws" new "$base" @
start "$file"
i=0
until get jj_error | grep -q 'exactly one'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'merge not rejected'; sleep .1; done
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'merge rendered markers'
[ "$(annotates)" -eq 0 ] || fail 'merge ran annotate'
stop
ok 'merge parents fail closed'

# Inspect every runtime command captured across the last request.
grep -v -- '--ignore-working-copy --at-operation=@' "$TEST_TRACE" > "$tmp/bad-commands" || :
[ ! -s "$tmp/bad-commands" ] || fail 'runtime command omitted read-only flags'
ok 'runtime jj operations explicitly ignore working-copy snapshots/integration'

# Reject a symlink baseline when the live file is regular.
jj_fixture -R "$ws" new "$base"
link=$ws/link
ln -s "${file##*/}" "$link"
jj_fixture -R "$ws" new
rm "$link"; printf 'regular now\n' > "$link"
start "$link"
i=0
until get jj_error | grep -q 'unsupported baseline'; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'symlink baseline not rejected'; sleep .1; done
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'symlink baseline rendered markers'
stop
ok 'symlink baseline fails closed'

jj_fixture -R "$ws" new "$base"
mv "$file" "$ws/renamed"
start "$ws/renamed"
wait_flags '1|{JJAdded}+'
command jj-blame-toggle
get jj_column | grep -q uncommitted || fail 'rename attached unrelated historical blame'
stop
ok 'renames use current-path baseline semantics (new path is new content)'

# Use a single-parent child of a conflicted merge to exercise conflict rejection.
jj_fixture -R "$ws" new "$base"
printf 'left\n' > "$file"
jj_fixture -R "$ws" new
left=$("$real_jj" --ignore-working-copy -R "$ws" log -r @- --no-graph -T commit_id)
jj_fixture -R "$ws" new "$base"
printf 'right\n' > "$file"
jj_fixture -R "$ws" new "$left" @
jj_fixture -R "$ws" new
start "$file"
i=0
until get jj_error | grep -q conflicted; do i=$((i+1)); [ "$i" -lt 50 ] || fail 'conflict not rejected'; sleep .1; done
[ "$(get jj_flags | wc -w)" -eq 1 ] || fail 'conflict rendered markers'
stop
ok 'conflicted working-copy/parent revisions fail closed'

# Native capture must preserve CRLF and the missing final newline; Kakoune's
# internal selection still ends in a synthetic LF.
jj_fixture -R "$ws" new "$base"
printf 'first\r\nlast' > "$file"
jj_fixture -R "$ws" new
start "$file"
wait_flags '0| '
command "select 2.1,2.1; execute-keys 'aX<esc>'; jj--tick"
wait_flags '2|{JJModified}~'
stop
ok 'CRLF and missing-final-newline live capture'
printf '\357\273\277UTF-8 BOM\n' > "$file"
jj_fixture -R "$ws" new
start "$file"
wait_flags '0| '
stop
ok 'UTF-8 BOM capture agrees with baseline bytes'
sh "$repo/tests/cache.sh"
ok 'interrupted cache publication leaves complete data and a reusable cache'
sh "$repo/tests/map.sh"
printf '\n%s integration checks passed\n' "$passed"
