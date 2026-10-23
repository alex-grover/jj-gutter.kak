# Map annotation TSV and unified diff hunks to live-line markers and labels.
# Labels arrive width-limited and Kakoune-escaped.
# Read paths from ENVIRON to preserve literal backslashes.
BEGIN {
    width = ENVIRON["width"] + 0
    old_count = ENVIRON["old_count"] + 0
    new_count = ENVIRON["new_count"] + 0
    flags = ENVIRON["flags"]
    labels = ENVIRON["labels"]
    marks = ENVIRON["marks"]
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
    flush_hunk()
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
    old = start_a + ac; new = start_b + bc
    hunk = 1
    next
}
hunk && /^-/ { left[++nr] = normalized(substr($0, 2)); next }
hunk && /^\+/ { right[++na] = normalized(substr($0, 2)); next }
/^--- / || /^\+\+\+ / || /^\\ No newline at end of file/ { next }
{ bad = 1 }
function normalized(text) {
    gsub(/[[:space:]]/, "", text)
    return text
}
# Prefer whitespace-equivalent lines, then common prefixes/suffixes. Character
# scans and the alignment matrix are bounded to keep large changes responsive.
function pair_cost(i, j,    x,y,p,s,shorter,longer) {
    x = left[i]; y = right[j]
    if (x == y) return 0.05
    if (x == "" || y == "") return 1.9
    shorter = length(x) < length(y) ? length(x) : length(y)
    longer = length(x) > length(y) ? length(x) : length(y)
    p = s = 0
    while (p < shorter && p < 128 && substr(x,p+1,1) == substr(y,p+1,1)) p++
    while (p+s < shorter && s < 128 && substr(x,length(x)-s,1) == substr(y,length(y)-s,1)) s++
    return 1.5 - (p+s) / longer
}
function deletion(after,    anchor) {
    anchor = start_b + after
    if (anchor > new_count) anchor = new_count
    if (anchor < 1) anchor = 1
    mark(anchor, "-")
}
function flush_hunk(    i,j,k,best,candidate,op) {
    if (!hunk) return
    if (nr != ac || na != bc) bad = 1
    if (ac == 0 || bc == 0 || ac*bc > 4096) {
        # Linear pairing skips excess blank lines in large replacement hunks.
        i = j = 1
        while (i <= ac && j <= bc) {
            if (bc-j > ac-i && right[j] == "" && left[i] != "") {
                mark(start_b+j-1, "+"); j++
            } else if (ac-i > bc-j && left[i] == "" && right[j] != "") {
                deletion(j-1); i++
            } else {
                mark(start_b+j-1, "~"); i++; j++
            }
        }
        while (j <= bc) { mark(start_b+j-1, "+"); j++ }
        if (i <= ac) deletion(bc)
    } else {
        for (i=0; i<=ac; i++) score[i,0] = i
        for (j=0; j<=bc; j++) score[0,j] = j
        for (i=1; i<=ac; i++) for (j=1; j<=bc; j++) {
            best = score[i-1,j-1] + pair_cost(i,j); op = "pair"
            candidate = score[i-1,j] + 1
            if (candidate < best - 0.000000001) { best = candidate; op = "delete" }
            candidate = score[i,j-1] + 1
            if (candidate < best - 0.000000001) { best = candidate; op = "insert" }
            score[i,j] = best; step[i,j] = op
        }
        i = ac; j = bc
        while (i || j) {
            op = i == 0 ? "insert" : (j == 0 ? "delete" : step[i,j])
            if (op == "pair") { mark(start_b+j-1, "~"); i--; j-- }
            else if (op == "insert") { mark(start_b+j-1, "+"); j-- }
            else { deletion(j); i-- }
        }
    }
    for (k in left) delete left[k]
    for (k in right) delete right[k]
    for (k in score) delete score[k]
    for (k in step) delete step[k]
    nr = na = hunk = 0
}
function mark(row, symbol) {
    if (row in markers && markers[row] != symbol) markers[row] = "*"
    else markers[row] = symbol
}
END {
    flush_hunk()
    if (annotations != old_count || old_count - old != new_count - new) bad = 1
    if (bad) exit 1
    if (marks != "") printf "%s", "" > marks
    while (new <= new_count) mapping[new++] = old++
    count = (new_count > 0 ? new_count : 1)
    # Off-buffer line-zero padding keeps the gutter one cell wide across edits.
    printf " %s0| %s", sq, sq > flags
    for (i = 1; i <= count; i++) {
        if (i in markers) {
            symbol = markers[i]
            face = (symbol == "+" ? "JJAdded" : (symbol == "-" ? "JJDeleted" : "JJModified"))
            printf " %s%d|{%s}%s%s", sq, i, face, symbol, sq > flags
            if (marks != "") printf "%d %s\n", i, symbol > marks
        }
        text = (i in mapping ? blame[mapping[i]] : sprintf("%-*s", width, substr("uncommitted", 1, width)))
        # Line-spec parsing reduces two backslashes to one; {\} makes labels literal.
        printf "%s%d|{JJBlame}{\\\\}%s%s\n", sq, i, text, sq > labels
    }
    printf "\n" > flags
}
