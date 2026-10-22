# Quote a string for Kakoune; the result is returned in jj_quoted.
kakquote() {
    _jj_rest=$1
    jj_quoted="'"
    while :; do
        case "$_jj_rest" in
            *"'"*)
                jj_quoted=$jj_quoted${_jj_rest%%"'"*}"''"
                _jj_rest=${_jj_rest#*"'"}
                ;;
            *) jj_quoted=$jj_quoted$_jj_rest"'"; return ;;
        esac
    done
}
