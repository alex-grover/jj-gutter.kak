# Jujutsu change markers and blame columns. Load once per session.
declare-option str jj_shell sh
declare-option str jj_worker %sh{ file=${kak_source##*/}; printf '%s../lib/worker.sh' "${kak_source%"$file"}"; }
declare-option int jj_blame_width 40
declare-option int jj_check_seconds 2
declare-option bool jj_show_blame false
set-face global JJAdded rgb:a6e3a1
set-face global JJModified rgb:f9e2af
set-face global JJDeleted rgb:f38ba8
set-face global JJBlame rgb:6c7086

declare-option -hidden bool jj_enabled false
declare-option -hidden str jj_state ''
declare-option -hidden str jj_dir ''
declare-option -hidden str jj_file ''
declare-option -hidden int jj_generation 0
declare-option -hidden int jj_requested -1
declare-option -hidden int jj_checked 0
declare-option -hidden str jj_revision ''
declare-option -hidden str jj_labels ''
declare-option -hidden int jj_column_width 0
declare-option str jj_error ''
declare-option -hidden str-list jj_markers
declare-option -hidden str-list jj_annotations
declare-option -hidden line-specs jj_flags
declare-option -hidden line-specs jj_column
declare-option -hidden str jj_line_key ''
add-highlighter shared/jj-column group -passes move

define-command -hidden jj--line %{
    evaluate-commands %sh{
        key="$kak_opt_jj_show_blame:$kak_opt_jj_column_width"
        [ "$key" = "$kak_opt_jj_line_key" ] && exit
        printf "set-option window jj_line_key '%s'\n" "$key"
        if [ "$kak_opt_jj_show_blame" = true ] && [ "$kak_opt_jj_column_width" -gt 0 ]; then
            printf 'add-highlighter -override window/jj-column ref -passes move jj-column\n'
        else
            printf '%s\n' 'try %{ remove-highlighter window/jj-column }'
        fi
    }
}

# Republish cached gutters at the current timestamp to retain touched-line flags.
define-command -hidden jj--hold-markers %{
    set-option buffer jj_flags %val{timestamp} %opt{jj_markers}
    set-option buffer jj_column %val{timestamp} %opt{jj_annotations}
}

define-command -hidden jj--detach %{
    remove-hooks buffer jj-gutter
    try %{ remove-highlighter buffer/jj-diff }
    set-option buffer jj_dir ''
    set-option buffer jj_labels ''
    set-option buffer jj_markers
    set-option buffer jj_annotations
    set-option buffer jj_column_width 0
    set-option buffer jj_error ''
    jj--hold-markers
    try %{ remove-highlighter window/jj-column }
    set-option window jj_line_key ''
}

define-command -hidden jj--capture %{
    evaluate-commands -draft -no-hooks -save-regs '|' %{
        # Pipe the live buffer to the worker and discard command output.
        set-register '|' %{
            # These mentions export request metadata into the child environment:
            # kak_session kak_buffile kak_timestamp
            # kak_opt_jj_generation kak_opt_jj_dir
            # kak_opt_finaleol kak_opt_eolformat kak_opt_BOM kak_opt_jj_blame_width
            "$kak_opt_jj_shell" "$kak_opt_jj_worker" <&0 >/dev/null 2>"$kak_opt_jj_dir/worker.log" &
        }
        execute-keys '%<a-|><ret>'
    }
}

define-command -hidden jj--tick %{
    evaluate-commands %sh{
        [ "$kak_opt_jj_enabled" = true ] || exit
        detach() {
            [ -z "$kak_opt_jj_dir" ] || rm -rf "$kak_opt_jj_dir"
            printf 'jj--detach\n'
        }
        # File-backed buffers have absolute buffile paths, including new files.
        case "$kak_buffile" in
            /*) ;;
            *) detach; exit ;;
        esac
        probe=${kak_buffile%/*}
        while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe=${probe%/*}; [ -n "$probe" ] || probe=/; done
        probe=$(cd -P "$probe" 2>/dev/null && pwd -P) || { detach; exit; }
        while [ ! -d "$probe/.jj" ]; do
            [ "$probe" != / ] || { detach; exit; }
            probe=${probe%/*}; [ -n "$probe" ] || probe=/
        done
        if [ -z "$kak_opt_jj_dir" ] || [ ! -d "$kak_opt_jj_dir" ]; then
            . "${kak_opt_jj_worker%/*}/quote.sh"
            state=$kak_opt_jj_state
            if [ -z "$state" ] || [ ! -d "$state" ]; then
                state=$(mktemp -d "${TMPDIR:-/tmp}/kak-jj.XXXXXXXX") || exit
                kakquote "$state"
                printf 'set-option global jj_state %s\n' "$jj_quoted"
            fi
            dir=$(mktemp -d "$state/b.XXXXXXXX") || exit
            kakquote "$dir"
            printf 'set-option buffer jj_dir %s\n' "$jj_quoted"
            # Reserve display width before launching the first request.
            width=$kak_opt_jj_blame_width
            [ "$width" -ge 8 ] || width=8
            [ "$width" -le 80 ] || width=80
            printf 'set-option buffer jj_column_width %s\n' "$width"
            printf "set-option buffer jj_markers '0| '\n"
            printf "set-option buffer jj_annotations '0|%*s'\njj--hold-markers\n" "$width" ''
            printf "set-option buffer jj_labels ''\nset-option buffer jj_revision ''\n"
            printf 'add-highlighter -override buffer/jj-diff flag-lines default jj_flags\n'
            printf '%s\n' 'hook -group jj-gutter buffer NormalKey .* %{ jj--hold-markers }'
            printf '%s\n' 'hook -group jj-gutter buffer InsertKey .* %{ jj--hold-markers }'
            printf '%s\n' 'set-option buffer jj_file %val{buffile}'
            printf 'set-option buffer jj_requested -1\nset-option buffer jj_checked 0\n'
            printf "set-option window jj_line_key '%s:%s'\n" "$kak_opt_jj_show_blame" "$width"
            if [ "$kak_opt_jj_show_blame" = true ]; then
                printf 'add-highlighter -override window/jj-column ref -passes move jj-column\n'
            else
                printf '%s\n' 'try %{ remove-highlighter window/jj-column }'
            fi
            # Paint the reserved columns first; NormalIdle starts the calculation.
            exit
        fi
        now=$(date +%s)
        interval=$kak_opt_jj_check_seconds
        [ "$interval" -ge 1 ] || interval=1
        if [ "$kak_opt_jj_requested" != "$kak_timestamp" ] ||
           [ "$kak_opt_jj_file" != "$kak_buffile" ] ||
           [ $((now - kak_opt_jj_checked)) -ge "$interval" ]; then
            generation=$((kak_opt_jj_generation + 1))
            printf '%s' "$generation" > "$kak_opt_jj_dir/generation"
            # Keep only the result still in use; cancel guards protect in-flight results.
            for file in "$kak_opt_jj_dir/"*.labels "$kak_opt_jj_dir/"*.kak; do
                [ ! -f "$file" ] || [ "$file" = "$kak_opt_jj_labels" ] || rm -f "$file"
            done
            printf 'set-option buffer jj_generation %s\n' "$generation"
            printf 'set-option buffer jj_requested %s\n' "$kak_timestamp"
            printf 'set-option buffer jj_checked %s\n' "$now"
            printf '%s\n' 'set-option buffer jj_file %val{buffile}'
            # Keep both cached gutters until replacement; invalidate them on path changes.
            if [ "$kak_opt_jj_requested" != "$kak_timestamp" ] || [ "$kak_opt_jj_file" != "$kak_buffile" ]; then
                if [ "$kak_opt_jj_file" != "$kak_buffile" ] || [ "$kak_opt_jj_column_width" -eq 0 ]; then
                    printf "set-option buffer jj_markers\nset-option buffer jj_annotations\nset-option buffer jj_labels ''\n"
                    printf 'set-option buffer jj_column_width 0\n'
                fi
                printf "jj--hold-markers\nset-option buffer jj_revision ''\n"
            fi
            printf 'jj--capture\n'
        fi
        printf 'jj--line\n'
    }
}

# Accept results matching the buffer, timestamp, generation, path, and revision.
define-command -hidden -params 4 jj--expect %{
    evaluate-commands %sh{
        [ "$kak_opt_jj_enabled" = true ] && [ "$1" = "$kak_opt_jj_dir" ] &&
        [ "$2" = "$kak_timestamp" ] && [ "$3" = "$kak_opt_jj_generation" ] &&
        [ "$kak_buffile" = "$kak_opt_jj_file" ] || exit
        printf "set-option buffer jj_revision '%s'\n" "$4"
    }
}
define-command -hidden -params 5 jj--apply %{
    evaluate-commands %sh{
        [ "$kak_opt_jj_enabled" = true ] && [ "$1" = "$kak_opt_jj_dir" ] &&
        [ "$2" = "$kak_timestamp" ] && [ "$3" = "$kak_opt_jj_generation" ] &&
        [ "$4" = "$kak_opt_jj_revision" ] && [ "$kak_buffile" = "$kak_opt_jj_file" ] && [ -r "$5" ] || exit
        # Apply the generated marker and annotation state.
        . "${kak_opt_jj_worker%/*}/quote.sh"
        kakquote "$5"
        printf 'source %s\n' "$jj_quoted"
        # Refresh the receiving window after updating shared buffer data.
        printf 'jj--line\n'
    }
}

define-command -hidden jj--refresh %{
    set-option buffer jj_checked 0
    set-option window jj_line_key ''
    jj--tick
}
define-command jj-refresh -docstring 'Refresh live jj gutters and cached parent attribution.' %{
    set-option buffer jj_requested -1
    jj--refresh
}
define-command jj-blame-toggle -docstring 'Toggle the current window annotation column.' %{
    evaluate-commands %sh{
        if [ "$kak_opt_jj_show_blame" = true ]; then
            printf 'set-option window jj_show_blame false\n'
        else
            printf 'set-option window jj_show_blame true\n'
        fi
    }
    set-option window jj_line_key ''
    jj--line
}
define-command jj-enable -docstring 'Enable read-only jj visuals for file buffers.' %{
    set-option global jj_enabled true
    add-highlighter -override shared/jj-column/text flag-lines default jj_column
    remove-hooks global jj-gutter
    hook -group jj-gutter global NormalIdle .* %{ jj--tick }
    hook -group jj-gutter global InsertIdle .* %{ jj--tick }
    hook -group jj-gutter global BufWritePost .* %{ try %{ jj--refresh } }
    hook -group jj-gutter global BufReload .* %{ try %{ jj-refresh } }
    hook -group jj-gutter global WinDisplay .* %{ jj-refresh }
    hook -group jj-gutter global FocusIn .* %{ jj--refresh }
    hook -group jj-gutter global BufClose .* %{
        nop %sh{ [ -z "$kak_opt_jj_dir" ] || rm -rf "$kak_opt_jj_dir" }
    }
    hook -group jj-gutter global KakEnd .* %{
        nop %sh{ [ -z "$kak_opt_jj_state" ] || rm -rf "$kak_opt_jj_state" }
    }
    # WinDisplay attaches file buffers when enabled from kakrc.
    # Refresh immediately when a window is available.
    try %{ jj-refresh }
}
define-command jj-disable -docstring 'Disable jj visuals and remove session-local cached data.' %{
    set-option global jj_enabled false
    remove-hooks global jj-gutter
    try %{ remove-highlighter shared/jj-column/text }
    evaluate-commands -buffer '*' %{
        remove-hooks buffer jj-gutter
        try %{ remove-highlighter buffer/jj-diff }
        set-option buffer jj_markers
        set-option buffer jj_annotations
        jj--hold-markers
        set-option buffer jj_labels ''
        set-option buffer jj_column_width 0
        set-option buffer jj_dir ''
        set-option buffer jj_file ''
        set-option buffer jj_revision ''
        set-option buffer jj_error ''
    }
    evaluate-commands -client '*' %{
        try %{ remove-highlighter window/jj-column }
        set-option window jj_line_key ''
    }
    nop %sh{ [ -z "$kak_opt_jj_state" ] || rm -rf "$kak_opt_jj_state" }
    set-option global jj_state ''
}
