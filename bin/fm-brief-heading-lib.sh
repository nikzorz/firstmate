# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies.

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" body <<<"$task"
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" present >/dev/null <<<"$task"
}


# Split a scaffolded brief into its top-level sections, one file per section
# under <dir>, each trimmed of the blank lines that separate it from the next,
# and print "<n>\t<key>" for each in order. The key is the heading line, or
# "(opening)" for the text before the first heading. `# Task` runs to the Herdr
# heading bin/fm-brief.sh writes after it and `# Home brief additions` to the
# end of the file, because filled text may carry headings of its own.
fm_brief_split_sections() {  # <file> <dir>
  awk -v dir="$2" '
    function start(key) { if (n) close(file); n++; file = dir "/" n; blanks = 0; printf "%d\t%s\n", n, key }
    function emit(l) {
      if (l == "") { blanks++; return }
      for (; blanks > 0; blanks--) print "" > file
      print l > file
    }
    function is_herdr(l) { return l == "# Herdr isolation - HARD SAFETY CONTRACT" || l == "# Herdr lifecycle declaration - NOT ENABLED" }
    {
      l = $0
      if (region == "home") { emit(l); next }
      if (region == "task" && !is_herdr(l) && l != "# Home brief additions") { emit(l); next }
      if (l ~ /^(```|~~~)/) fenced = !fenced
      if (!fenced && l ~ /^# /) {
        start(l)
        region = l == "# Task" ? "task" : l == "# Home brief additions" ? "home" : ""
      } else if (!n) {
        start("(opening)")
      }
      emit(l)
    }
  ' "$1"
}

# A section's fingerprint is its trimmed text's POSIX cksum, enough to tell an
# edited section from the one bin/fm-brief.sh wrote.
fm_brief_section_fingerprint() {  # <section-file>
  cksum <"$1" | awk '{ print $1 "-" $2 }'
}

# Print "section\t<fingerprint>\t<key>" for every section of a ship scaffold
# except the `# Task` and `# Home brief additions` text firstmate fills.
fm_brief_scaffold_fingerprints() {  # <brief>
  local dir n key rc=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief-sections.XXXXXX") || return 1
  while IFS=$'\t' read -r n key; do
    case "$key" in "# Task" | "# Home brief additions") continue ;; esac
    printf 'section\t%s\t%s\n' "$(fm_brief_section_fingerprint "$dir/$n")" "$key" || rc=1
  done < <(fm_brief_split_sections "$1" "$dir")
  rm -rf -- "$dir"
  return "$rc"
}
