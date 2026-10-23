# Apply a single-selection typing edit to cached markers and annotations.
# Inputs are compact marker rows and Kakoune-quoted annotation records.
BEGIN {
    action = ENVIRON["action"]
    line = ENVIRON["edit_line"] + 0
    count = ENVIRON["new_count"] + 0
    old_count = ENVIRON["previous_count"] + 0
    width = ENVIRON["view_width"] + 0
    stamp = ENVIRON["edit_stamp"] + 0
    marks_out = ENVIRON["view_base"] ".marks"
    labels_out = ENVIRON["view_base"] ".labels"
    sq = sprintf("%c", 39)
    uncommitted = "|{JJBlame}{\\\\}" sprintf("%-*s", width, substr("uncommitted",1,width)) sq
}
FILENAME == ARGV[1] {
    if ($1 !~ /^[0-9]+$/ || $1 < 1 || $1 > old_count || $2 !~ /^[+~*-]$/) bad = 1
    old_marks[$1] = $2
    next
}
{
    bar = index($0, "|")
    row = substr($0, 2, bar-2) + 0
    if (bar < 3 || row != ++records || substr($0,1,1) != sq || substr($0,length($0),1) != sq) bad = 1
    old_labels[row] = substr($0, bar)
}
function quote(text) { gsub(sq, sq sq, text); return sq text sq }
function copy_line(source, target) {
    labels[target] = old_labels[source]
    if (old_marks[source] != "") markers[target] = old_marks[source]
    else delete markers[target]
}
function deleted(row) {
    if (row > count) row = count
    if (row < 1) row = 1
    if (markers[row] != "" && markers[row] != "-") markers[row] = "*"
    else markers[row] = "-"
}
function changed(row) {
    if (markers[row] == "-") markers[row] = "*"
    else if (markers[row] != "+" && markers[row] != "*") markers[row] = "~"
    labels[row] = uncommitted
}
END {
    expected = old_count + (action == "modify" ? 0 : (action == "join" || action == "remove" ? -1 : 1))
    if (bad || records != old_count || count != expected || count < 1 || count > 10000 || line < 1 || line > old_count || action !~ /^(modify|above|below|split|join|remove)$/ || (action == "join" && line == old_count)) exit 1
    for (i=1; i<=old_count; i++) {
        target = i
        if (action == "above" && i >= line) target++
        if ((action == "below" || action == "split") && i > line) target++
        if (action == "join" || action == "remove") {
            removed = action == "join" ? line+1 : line
            if (i == removed) continue
            if (i > removed) target--
        }
        labels[target] = old_labels[i]
        if (i in old_marks) markers[target] = old_marks[i]
    }
    if (action == "modify" || action == "split") changed(line)
    if (action == "remove" && old_marks[line] != "+") deleted(line)
    if (action == "join") {
        before_added = old_marks[line] == "+"
        after_added = old_marks[line+1] == "+"
        before_empty = ENVIRON["empty_before"] == "true"
        after_empty = ENVIRON["empty_after"] == "true"
        touched = ENVIRON["touch_original"] == "true"
        if (before_added && after_added) {
            markers[line] = "+"; labels[line] = uncommitted
        } else if (before_added || after_added) {
            # Keep the baseline line's identity when removing an added newline.
            copy_line(before_added ? line+1 : line, line)
            if (!(before_added ? before_empty : after_empty) || touched) changed(line)
        } else if ((before_empty || after_empty) && !touched) {
            copy_line(before_empty ? line+1 : line, line)
            deleted(before_empty ? line : line+1)
        } else {
            changed(line)
            deleted(line+1)
        }
    }
    if (action == "above" || action == "below" || action == "split") {
        added = action == "above" ? line : line+1
        markers[added] = "+"
        labels[added] = uncommitted
        if (action == "above" && ENVIRON["touch_original"] == "true") changed(line+1)
    }
    printf "%s", "" > marks_out
    printf "set-option buffer jj_markers %s0| %s", sq, sq
    for (i=1; i<=count; i++) {
        if (i in markers) {
            symbol = markers[i]
            face = symbol == "+" ? "JJAdded" : (symbol == "-" ? "JJDeleted" : "JJModified")
            printf " %s%d|{%s}%s%s", sq, i, face, symbol, sq
            printf "%d %s\n", i, symbol > marks_out
        }
        if (!(i in labels)) labels[i] = uncommitted
        printf "%s%d%s\n", sq, i, labels[i] > labels_out
    }
    if (action == "modify") {
        # Inline edits replace one cached label; line shifts rebuild the list.
        printf "\nset-option -remove buffer jj_annotations %s%d%s", sq, line, old_labels[line]
        printf "\nset-option -add buffer jj_annotations %s%d%s", sq, line, labels[line]
    } else {
        printf "\nset-option buffer jj_annotations %s0|%*s%s", sq, width, "", sq
        for (i=1; i<=count; i++) printf " %s%d%s", sq, i, labels[i]
    }
    printf "\nset-option buffer jj_mark_file %s\n", quote(marks_out)
    printf "set-option buffer jj_labels %s\n", quote(labels_out)
    printf "set-option buffer jj_optimistic_timestamp %d\n", stamp
    printf "set-option buffer jj_optimistic_lines %d\n", count
}
