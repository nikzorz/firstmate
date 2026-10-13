#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report
#   fm-startup-memory-budget.sh check
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/captain.md, data/captain-shared.md, and data/learnings.md together.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
#
# `report` ends with the oversized-entry section, and `check` prints only that
# section:
#   entry_size_limit_tokens=<N>
#   oversized_entries=<count>
#   oversized_entry=data/<file> line=<N> bytes=<N> estimated_tokens=<N> heading=<text>
# with one oversized_entry line per entry whose estimate exceeds the limit,
# largest first.  An entry is one top-level list item with its continuation
# lines; text outside a list item is not an entry.  heading is the nearest
# Markdown heading above the entry, or (none).  The limit is the one positive
# decimal in the optional local config/startup-memory-entry-size, held to the
# budget file's exact format, and 150 estimated tokens when that file is absent.
#
# Exit status: 0 success; 1 `check` found an oversized entry; 2 usage error or
# an unsafe or invalid input.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

ENTRY_SIZE_FILE="startup-memory-entry-size"
ENTRY_SIZE_DEFAULT="150"

usage() {
  sed -n '2,28{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

# The per-entry limit is optional, so only absence falls back to the default;
# a present but unsafe or malformed file stays an error like the budget's.
read_entry_size_limit() {
  local path="$CONFIG/$ENTRY_SIZE_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$ENTRY_SIZE_DEFAULT"
    return 0
  fi
  if ! fm_startup_memory_budget_config_dir_safe "$CONFIG" \
    || ! fm_startup_memory_budget_file_valid "$path"; then
    print_error "invalid config/$ENTRY_SIZE_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

# list_entries <path> <label>
# Prints "<bytes><TAB><estimated-tokens><TAB><line><TAB><label><TAB><heading>"
# for every entry of one present memory file.
list_entries() {
  LC_ALL=C awk -v label="$2" '
    function flush(   tokens) {
      if (!open) return
      tokens = int(bytes / 3)
      if (bytes % 3) tokens++
      printf "%d\t%d\t%d\t%s\t%s\n", bytes, tokens, start, label, heading
      open = 0
    }
    BEGIN { heading = "(none)" }
    {
      size = length($0) + 1
      if ($0 ~ /^[ \t]*(```|~~~)/) {
        if (!fenced && $0 !~ /^[ \t]/) flush()
        fenced = !fenced
      } else if (!fenced && $0 ~ /^#+[ \t]/) {
        flush()
        heading = $0
        sub(/[ \t]+#+[ \t]*$/, "", heading)
        sub(/^#+[ \t]*/, "", heading)
        sub(/[ \t]+$/, "", heading)
        gsub(/\t/, " ", heading)
        if (heading == "") heading = "(none)"
        next
      } else if (!fenced && $0 ~ /^([-*+]|[0-9]+[.)])[ \t]/) {
        flush()
        open = 1; bytes = size; start = NR; gap = 0
        next
      } else if (!fenced && $0 ~ /^[ \t]*$/) {
        gap += size
        next
      } else if (!fenced && gap && $0 !~ /^[ \t]/) {
        # An unindented line after a blank line is a new paragraph, not a
        # continuation of the list item above it.
        flush()
      }
      if (open) { bytes += gap + size; gap = 0 }
    }
    END { flush() }
  ' "$1"
}

# report_oversized_entries <limit>
# Prints the oversized-entry section and returns 1 when it lists any entry.
report_oversized_entries() {
  local limit=$1 file entries="" listed count=0 bytes tokens line label heading
  for file in captain.md captain-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    [ "$FM_STARTUP_MEMORY_MEASURE_PRESENCE" = present ] || continue
    if ! listed=$(list_entries "$DATA/$file" "data/$file"); then
      print_error "could not read memory entries: $DATA/$file"
      return 2
    fi
    [ -z "$listed" ] || entries+="$listed"$'\n'
  done

  listed=""
  while IFS=$'\t' read -r bytes tokens line label heading; do
    [ -n "$bytes" ] || continue
    ! fm_startup_memory_decimal_le "$tokens" "$limit" || continue
    count=$((count + 1))
    listed+="oversized_entry=$label line=$line bytes=$bytes estimated_tokens=$tokens heading=$heading"$'\n'
  done < <(printf '%s' "$entries" | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1nr)

  printf 'entry_size_limit_tokens=%s\n' "$limit"
  printf 'oversized_entries=%s\n' "$count"
  printf '%s' "$listed"
  [ "$count" -eq 0 ]
}

report() {
  local budget entry_limit bytes tokens presence total=0 shared_tokens=0 role=primary
  local entries_status=0
  if ! budget=$(read_budget) || ! entry_limit=$(read_entry_size_limit); then
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in captain.md captain-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$FM_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != captain-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = secondmate ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi
  # Only `check` turns an oversized entry into a failing status.
  report_oversized_entries "$entry_limit" || entries_status=$?
  [ "$entries_status" -le 1 ] || return "$entries_status"
}

check() {
  local entry_limit
  if ! entry_limit=$(read_entry_size_limit); then
    return 2
  fi
  report_oversized_entries "$entry_limit"
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  check)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    check
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
