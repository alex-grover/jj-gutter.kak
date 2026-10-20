# Map annotation TSV and unified diff hunks to live-line markers and labels.
# Labels arrive width-limited and Kakoune-escaped.
# Read paths from ENVIRON to preserve literal backslashes.
BEGIN {
    width = ENVIRON["width"] + 0
    old_count = ENVIRON["old_count"] + 0
    new_count = ENVIRON["new_count"] + 0
    flags = ENVIRON["flags"]
    labels = ENVIRON["labels"]
    old = new = 1
    sq = sprintf("%c", 39)
}
FILENAME == ARGV[1] {
    tab = index($0, "\t")
    n = substr($0, 1, tab - 1)
    rest = substr($0, tab + 1)
    tab = index(rest, "\t")
    revision = substr(rest, 1, tab - 1)
    if (!tab || n != ++annotations || revision !~ /^[0-9a-f]+$/) bad = 1
    blame[n] = substr(rest, tab + 1)
    next
}
/^@@ / {
    split($2, a, ","); split($3, b, ",")
    ac = (a[2] == "" ? 1 : a[2] + 0)
    bc = (b[2] == "" ? 1 : b[2] + 0)
    start_a = substr(a[1], 2) + 0
    start_b = substr(b[1], 2) + 0
    # Derive empty-range positions from the opposite range and unchanged span.
    if (ac == 0) start_a = old + start_b - new
    if (bc == 0) start_b = new + start_a - old
    if (start_a < old || start_b < new || start_a - old != start_b - new) bad = 1
    while (new < start_b) mapping[new++] = old++
    paired = (ac < bc ? ac : bc)
    for (i = 0; i < bc; i++) mark(start_b + i, i < paired ? "~" : "+")
    if (ac > bc) {
        anchor = start_b + bc
        if (anchor > new_count) anchor = new_count
        if (anchor < 1) anchor = 1
        mark(anchor, "-")
    }
    old = start_a + ac; new = start_b + bc
    next
}
# Standard unified diff content, headers, and missing-final-newline notices.
/^[-+ ]/ || /^\\ No newline at end of file/ { next }
{ bad = 1 }
function mark(row, symbol) {
    if (row in markers && markers[row] != symbol) markers[row] = "*"
    else markers[row] = symbol
}
END {
    if (annotations != old_count || old_count - old != new_count - new) bad = 1
    if (bad) exit 1
    while (new <= new_count) mapping[new++] = old++
    count = (new_count > 0 ? new_count : 1)
    # Off-buffer line-zero padding keeps the gutter one cell wide across edits.
    printf " %s0| %s", sq, sq > flags
    for (i = 1; i <= count; i++) {
        if (i in markers) {
            symbol = markers[i]
            face = (symbol == "+" ? "JJAdded" : (symbol == "-" ? "JJDeleted" : "JJModified"))
            printf " %s%d|{%s}%s%s", sq, i, face, symbol, sq > flags
        }
        text = (i in mapping ? blame[mapping[i]] : sprintf("%-*s", width, substr("uncommitted", 1, width)))
        # Line-spec parsing reduces two backslashes to one; {\} makes labels literal.
        printf "%s%d|{JJBlame}{\\\\}%s%s\n", sq, i, text, sq > labels
    }
    printf "\n" > flags
}
