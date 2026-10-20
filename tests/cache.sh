#!/bin/sh
# Verify cache readiness and recovery with callbacks captured by a test shim.
set -eu
repo=$(CDPATH= cd -- "${0%/*}/.." && pwd -P)
real_mv=$(command -v mv)
tmp=$(mktemp -d /tmp/jj-cache-tests.XXXXXXXX)
trap 'rm -rf "$tmp"' 0
mkdir "$tmp/bin" "$tmp/state"
jj --config 'user.name="Cache fixture"' --config 'user.email="fixture@example.invalid"' git init --no-colocate "$tmp/ws" >/dev/null 2>&1
printf 'alpha\nbeta\n' > "$tmp/ws/file"
jj --config 'user.name="Cache fixture"' --config 'user.email="fixture@example.invalid"' -R "$tmp/ws" new >/dev/null 2>&1
cat > "$tmp/bin/kak" <<'SH'
#!/bin/sh
cat >> "$TEST_CALLBACKS"
SH
cat > "$tmp/bin/mv" <<'SH'
#!/bin/sh
"$TEST_MV" "$@" || exit $?
case "$1" in
    */key)
        # Verify the parent worker's PID before signaling it.
        if [ -f "$TEST_INTERRUPT" ] && [ "$PPID" = "$TEST_OWNER" ]; then
            rm "$TEST_INTERRUPT"
            kill -TERM "$PPID"
        fi
        ;;
esac
SH
chmod +x "$tmp/bin/kak" "$tmp/bin/mv"
export TEST_MV="$real_mv" TEST_CALLBACKS="$tmp/callbacks" TEST_INTERRUPT="$tmp/interrupt"
export PATH="$tmp/bin:$PATH" TEST_WORKER="$repo/lib/worker.sh"
export kak_opt_jj_dir="$tmp/state" kak_timestamp=1 kak_session=cache-test-only
export kak_buffile="$tmp/ws/file" kak_opt_finaleol=present kak_opt_eolformat=lf kak_opt_BOM=none kak_opt_jj_blame_width=40
: > "$TEST_INTERRUPT"
printf 1 > "$tmp/state/generation"
export kak_opt_jj_generation=1
sh -c 'TEST_OWNER=$$; export TEST_OWNER; exec sh "$TEST_WORKER"' < "$tmp/ws/file" > "$tmp/first.out" 2> "$tmp/first.err" || :
[ ! -e "$TEST_INTERRUPT" ] || { printf 'cache interruption did not run\n' >&2; exit 1; }
for name in key base annotations; do
    [ -r "$tmp/state/cache/$name" ] || { printf 'cache key published before %s\n' "$name" >&2; exit 1; }
done
printf 2 > "$tmp/state/generation"
export kak_opt_jj_generation=2
sh -c 'TEST_OWNER=$$; export TEST_OWNER; exec sh "$TEST_WORKER"' < "$tmp/ws/file" > "$tmp/second.out" 2> "$tmp/second.err"
[ -s "$tmp/state/2.labels" ]
grep -F -q "set-option buffer jj_error ''" "$tmp/state/2.kak"
# Verify missing cached data is rebuilt.
rm "$tmp/state/cache/annotations"
printf 3 > "$tmp/state/generation"
export kak_opt_jj_generation=3
sh -c 'TEST_OWNER=$$; export TEST_OWNER; exec sh "$TEST_WORKER"' < "$tmp/ws/file" > "$tmp/third.out" 2> "$tmp/third.err"
[ -s "$tmp/state/cache/annotations" ]
[ -s "$tmp/state/3.labels" ]
grep -F -q "set-option buffer jj_error ''" "$tmp/state/3.kak"
printf 'cache publication interruption and incomplete-cache recovery checks passed\n'
