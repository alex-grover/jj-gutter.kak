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
declare-option -hidden str jj_mark_file ''
declare-option -hidden int jj_optimistic_timestamp -1
declare-option -hidden int jj_optimistic_lines 0
declare-option -hidden str-list jj_key_state
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
    set-option buffer jj_mark_file ''
    set-option buffer jj_labels ''
    set-option buffer jj_markers
    set-option buffer jj_annotations
    set-option buffer jj_column_width 0
    set-option buffer jj_optimistic_timestamp -1
    set-option buffer jj_error ''
    jj--hold-markers
    try %{ remove-highlighter window/jj-column }
    set-option window jj_line_key ''
}

define-command -hidden jj--remember-key %{
    set-option window jj_key_state %val{timestamp} %val{cursor_line} %val{cursor_column} %val{cursor_char_value} %val{buf_line_count} %val{selection_count} %val{selection_desc}
}

define-command -hidden -params 2 jj--on-key %{
    evaluate-commands %sh{
        mode=$1; key=$2
        printf 'jj--remember-key\n'
        trap 'printf "jj--hold-markers\n"' 0
        [ "$kak_buffile" = "$kak_opt_jj_file" ] || { printf 'jj--tick\n'; exit; }
        [ -r "$kak_opt_jj_mark_file" ] && [ -r "$kak_opt_jj_labels" ] || exit
        eval set -- "$kak_quoted_opt_jj_key_state"
        [ "$#" -eq 7 ] || exit
        if [ "$kak_timestamp" = "$1" ] || [ "$kak_timestamp" = "$kak_opt_jj_optimistic_timestamp" ]; then trap - 0; exit; fi
        printf 'set-option buffer jj_optimistic_timestamp -1\n'
        [ "$1" = "$kak_opt_jj_optimistic_timestamp" ] &&
        [ "$5" = "$kak_opt_jj_optimistic_lines" ] && [ "$6" = 1 ] && [ "$kak_selection_count" = 1 ] || exit
        previous_count=$5; new_count=$kak_buf_line_count
        [ "$new_count" -le 10000 ] || exit
        delta=$((new_count - previous_count))
        anchor=${7%%.*}; cursor=${7#*,}; cursor=${cursor%%.*}
        edit_line=$2; action=''; touch_original=false; empty_before=false; empty_after=false
        if [ "$delta" = 0 ] && [ $((kak_timestamp - $1)) = 1 ] && [ "$kak_cursor_line" = "$2" ]; then
            [ "$mode" != normal ] || [ "$anchor" = "$cursor" ] || exit
            case "$mode:$key" in
                normal:d|normal:D|normal:'<a-d>'|normal:c|normal:'<a-c>'|normal:p|normal:P|normal:r|normal:R|normal:'~') ;;
                normal:*|insert:'<esc>'|insert:'<left>'|insert:'<right>'|insert:'<up>'|insert:'<down>'|insert:'<home>'|insert:'<end>') exit ;;
            esac
            action=modify
        elif [ "$delta" = 1 ] && [ "$mode" = insert ] && [ "$key" = '<ret>' ] && [ "$kak_cursor_line" = "$(($2 + 1))" ]; then
            if [ "$4" = 10 ]; then action=below
            elif [ "$3" = 1 ]; then
                action=above
                [ "$kak_cursor_column" = 1 ] || touch_original=true
            else action=split; fi
        elif [ "$delta" = 1 ] && [ "$mode" = normal ]; then
            [ "$anchor" = "$cursor" ] || exit
            case "$key" in
                o) [ "$kak_cursor_line" != "$(($2 + 1))" ] || action=below ;;
                O) [ "$kak_cursor_line" != "$2" ] || action=above ;;
            esac
        elif [ "$delta" = -1 ] && [ "$mode" = normal ]; then
            case "$key" in
                d|'<a-d>'|'<del>')
                    [ "$anchor" = "$cursor" ] && [ $((kak_timestamp - $1)) = 1 ] || exit
                    left=${7%%,*}; left=${left#*.}; right=${7#*,}; right=${right#*.}
                    if [ "$left" -gt "$right" ]; then swap=$left; left=$right; right=$swap; fi
                    if [ "$left" = 1 ] && { [ "$right" -gt 1 ] || [ "$2" = "$previous_count" ]; }; then action=remove
                    else
                        action=join
                        [ "$left" != 1 ] || empty_before=true
                        [ "$kak_cursor_char_value" != 10 ] || empty_after=true
                        [ "$left" = "$right" ] || touch_original=true
                    fi ;;
                '<a-j>'|'<a-J>')
                    if [ "$anchor" -le "$cursor" ]; then edit_line=$anchor; distance=$((cursor-anchor)); else edit_line=$cursor; distance=$((anchor-cursor)); fi
                    [ "$distance" -le 1 ] && [ "$kak_cursor_line" = "$edit_line" ] || exit
                    action=join; touch_original=true ;;
            esac
        elif [ "$delta" = -1 ] && [ "$mode" = insert ]; then
            case "$key" in
                '<backspace>'|'<c-h>')
                    if [ "$3" = 1 ] && [ "$kak_cursor_line" = "$(($2 - 1))" ]; then
                        action=join; edit_line=$kak_cursor_line
                        [ "$kak_cursor_column" != 1 ] || empty_before=true
                        [ "$4" != 10 ] || empty_after=true
                    fi ;;
                '<del>')
                    if [ "$4" = 10 ] && [ "$kak_cursor_line" = "$2" ]; then
                        action=join
                        [ "$3" != 1 ] || empty_before=true
                        [ "$kak_cursor_char_value" != 10 ] || empty_after=true
                    fi ;;
            esac
        fi
        [ -n "$action" ] || exit
        edit_stamp=$kak_timestamp; view_width=$kak_opt_jj_column_width
        view_base=$kak_opt_jj_dir/key-$edit_stamp
        export action edit_line previous_count new_count edit_stamp view_width view_base touch_original empty_before empty_after
        if awk -f "${kak_opt_jj_worker%/*}/optimistic.awk" "$kak_opt_jj_mark_file" "$kak_opt_jj_labels" > "$view_base.kak" 2>/dev/null; then
            . "${kak_opt_jj_worker%/*}/quote.sh"
            kakquote "$view_base.kak"
            printf 'source %s\n' "$jj_quoted"
            case "$kak_opt_jj_mark_file" in "$kak_opt_jj_dir"/key-*.marks) rm -f "$kak_opt_jj_mark_file" ;; esac
            case "$kak_opt_jj_labels" in "$kak_opt_jj_dir"/key-*.labels) rm -f "$kak_opt_jj_labels" "${kak_opt_jj_labels%.labels}.kak" ;; esac
        fi
    }
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
            printf "set-option buffer jj_labels ''\nset-option buffer jj_mark_file ''\nset-option buffer jj_revision ''\n"
            printf 'add-highlighter -override buffer/jj-diff flag-lines default jj_flags\n'
            printf '%s\n' 'hook -group jj-gutter buffer NormalKey .* %{ jj--on-key normal %val{hook_param} }'
            printf '%s\n' 'hook -group jj-gutter buffer InsertKey .* %{ jj--on-key insert %val{hook_param} }'
            printf '%s\n' 'set-option buffer jj_file %val{buffile}'
            printf 'set-option buffer jj_requested -1\nset-option buffer jj_checked 0\n'
            printf "set-option window jj_line_key '%s:%s'\n" "$kak_opt_jj_show_blame" "$width"
            if [ "$kak_opt_jj_show_blame" = true ]; then
                printf 'add-highlighter -override window/jj-column ref -passes move jj-column\n'
            else
                printf '%s\n' 'try %{ remove-highlighter window/jj-column }'
            fi
            # Paint the reserved columns first; NormalIdle starts the calculation.
            printf 'jj--remember-key\n'
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
            for file in "$kak_opt_jj_dir/"*.labels "$kak_opt_jj_dir/"*.marks "$kak_opt_jj_dir/"*.kak; do
                [ ! -f "$file" ] || [ "$file" = "$kak_opt_jj_labels" ] || [ "$file" = "$kak_opt_jj_mark_file" ] || rm -f "$file"
            done
            printf 'set-option buffer jj_generation %s\n' "$generation"
            printf 'set-option buffer jj_requested %s\n' "$kak_timestamp"
            printf 'set-option buffer jj_checked %s\n' "$now"
            printf '%s\n' 'set-option buffer jj_file %val{buffile}'
            # Keep both cached gutters until replacement; invalidate them on path changes.
            if [ "$kak_opt_jj_requested" != "$kak_timestamp" ] || [ "$kak_opt_jj_file" != "$kak_buffile" ]; then
                if [ "$kak_opt_jj_file" != "$kak_buffile" ] || [ "$kak_opt_jj_column_width" -eq 0 ]; then
                    printf "set-option buffer jj_markers\nset-option buffer jj_annotations\nset-option buffer jj_labels ''\nset-option buffer jj_mark_file ''\n"
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
        printf 'jj--line\njj--remember-key\n'
    }
}

define-command -hidden jj--refresh %{
    set-option buffer jj_checked 0
    set-option window jj_line_key ''
    set-option window jj_key_state
    jj--tick
    jj--remember-key
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
        set-option buffer jj_mark_file ''
        set-option buffer jj_optimistic_timestamp -1
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
