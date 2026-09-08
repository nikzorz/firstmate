#!/usr/bin/env bash
# fm-context-cost.sh - read-only report of what every session and every worker
# loads before it does any work.
#
# Usage:
#   bin/fm-context-cost.sh
#   bin/fm-context-cost.sh --help
#
# Answers one question repeatably: what does a session cost before it does any
# work? It reads the always-loaded surfaces, renders the generated brief
# boilerplate for the scout variant and for each delivery-mode ship variant,
# and prints each surface's size.
#
# BYTES, NOT TOKENS. Every figure is bytes. This script applies no
# bytes-to-token conversion because it has no calibrated measurement to derive
# one from, and a conversion invented from a plausible-looking ratio would read
# as a measurement while being a guess. Byte figures are comparable against
# each other and against the same report run later; they are not a token count.
#
# REPORT ONLY. There is deliberately no budget, threshold, warning level, or
# non-zero exit on size. Making the cost visible when someone asks is the whole
# job; deciding what to do about it is not this script's call.
#
# It mutates nothing under the active home: the only writes go to a temp
# directory holding one throwaway FM_HOME per brief scaffold, removed on exit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
Usage: fm-context-cost.sh [--help]

Print a read-only report of every surface loaded before any work happens:
AGENTS.md, the session digest's parts, the private notes, the generated brief
boilerplate, and each skill with its load trigger.

All sizes are BYTES. No token conversion is applied; see the script header.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') : ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-cost.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

SUBTOTAL=0

# size_of <path>: echo the byte size of a regular file, -1 when absent, or -2
# when it is there but cannot be read. A file measured on a live fleet can be
# unlinked or made unreadable between the test and the read, and a report that
# died on an arithmetic error there would be useless exactly when it is wanted.
size_of() {
  local bytes
  [ -f "$1" ] || { printf '%s\n' -1; return 0; }
  bytes=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$bytes" in
    '' | *[!0-9]*) printf '%s\n' -2 ;;
    *) printf '%s\n' "$bytes" ;;
  esac
}

# tree_bytes <dir>: echo the summed byte size of every regular file below <dir>.
tree_bytes() {
  [ -d "$1" ] || { printf '%s\n' 0; return 0; }
  find "$1" -type f -exec wc -c {} + 2>/dev/null |
    awk '$2 != "total" { n += $1 } END { print n + 0 }'
}

# row <bytes> <label>: print one measured line and accumulate the subtotal.
# The size_of sentinels -1 and -2 print as words and contribute nothing.
row() {
  case "$1" in
    -1) printf '%10s  %s\n' ABSENT "$2"; return 0 ;;
    -2) printf '%10s  %s\n' UNREADABLE "$2"; return 0 ;;
  esac
  SUBTOTAL=$((SUBTOTAL + $1))
  printf '%10d  %s\n' "$1" "$2"
}

# subtotal <label>: print and reset the running subtotal.
subtotal() {
  printf '  --------\n%10d  %s\n' "$SUBTOTAL" "$1"
  SUBTOTAL=0
}

# section <title>: start a section with a zeroed subtotal.
section() {
  SUBTOTAL=0
  printf '\n== %s ==\n' "$1"
}

# glob_group <label> <dir> <pattern>: print one aggregated row for every file
# in <dir> matching <pattern>, naming how many files it covers and how many of
# those it could not read rather than folding an unreadable file into zero.
glob_group() {
  local label=$1 dir=$2 pattern=$3 total=0 count=0 unread=0 f bytes
  if [ -d "$dir" ]; then
    for f in "$dir"/$pattern; do
      [ -f "$f" ] || continue
      count=$((count + 1))
      bytes=$(size_of "$f")
      if [ "$bytes" -lt 0 ]; then
        unread=$((unread + 1))
      else
        total=$((total + bytes))
      fi
    done
  fi
  if [ "$unread" -gt 0 ]; then
    row "$total" "$label ($count files, $unread unreadable)"
  else
    row "$total" "$label ($count files)"
  fi
}

# skill_trigger <skill.md>: echo the skill's load trigger, taken from the
# frontmatter description and trimmed to one readable line. Handles both a
# plain scalar description and a folded block scalar continued on later lines.
# The trigger clause is searched for across the whole description, not just its
# opening, because a description may state what the skill does before it states
# when to load it; a leading excerpt that contains no trigger is worse than
# saying plainly that none was found.
skill_trigger() {
  [ -f "$1" ] || { printf '%s\n' '(not detected)'; return 0; }
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    !infm { next }
    /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      if ($0 == ">" || $0 == ">-" || $0 == "|" || $0 == "|-") { $0 = "" }
      desc = $0
      folding = 1
      next
    }
    folding {
      if ($0 ~ /^[^[:space:]]/) { folding = 0; next }
      sub(/^[[:space:]]+/, "")
      desc = (desc == "" ? $0 : desc " " $0)
    }
    END {
      start = 0
      if (match(desc, /(Use|Load) (when|before|on|this|it)/)) {
        start = RSTART
      } else {
        if (match(desc, /[Ww]hen(ever)?[^[:alpha:]]/)) { start = RSTART }
        if (match(desc, /[Bb]efore[^[:alpha:]]/) && (start == 0 || RSTART < start)) {
          start = RSTART
        }
      }
      if (start == 0) { print "(not detected)"; exit }
      desc = substr(desc, start)
      if (length(desc) > 104) { desc = substr(desc, 1, 101) "..." }
      print desc
    }
  ' "$1"
}

printf 'firstmate context cost\n'
printf 'code root: %s\n' "$FM_ROOT"
printf 'home:      %s\n' "$FM_HOME"
cat <<'EOF'

All sizes below are BYTES. Bytes are a proxy for tokens, and this report
applies no bytes-to-token conversion: it has no calibrated measurement to
derive a ratio from, so a token figure here would be a guess wearing the
clothes of a measurement. Compare these numbers with each other and with the
same report run later, not against a token budget.
EOF

section 'Always loaded: instructions, every session'
row "$(size_of "$FM_ROOT/AGENTS.md")" 'AGENTS.md'
subtotal 'instructions'

section 'Always loaded: session digest context, every session'
row "$(size_of "$DATA/projects.md")" 'data/projects.md'
row "$(size_of "$DATA/secondmates.md")" 'data/secondmates.md'
row "$(size_of "$DATA/captain.md")" 'data/captain.md'
row "$(size_of "$DATA/captain-shared.md")" 'data/captain-shared.md'
row "$(size_of "$DATA/learnings.md")" 'data/learnings.md'
subtotal 'private notes and fleet records'

section 'Always loaded: session digest fleet state, every session'
printf 'Neither an upper nor a lower bound: the digest prints a bounded projection of\n'
printf 'the backlog and a bounded tail of each status log, so those two rows over-state,\n'
printf 'while it prints every meta record in full plus per-task framing counted nowhere\n'
printf 'here.\n'
row "$(size_of "$DATA/backlog.md")" 'data/backlog.md'
glob_group 'state/*.meta' "$STATE" '*.meta'
glob_group 'state/*.status' "$STATE" '*.status'
subtotal 'fleet state, approximate'

section 'Always loaded: supervision block, one harness per session'
printf 'A session pays exactly one of these, for its own primary harness.\n'
for proto in "$FM_ROOT"/docs/supervision-protocols/*.md; do
  [ -f "$proto" ] || continue
  harness=$(basename "$proto" .md)
  rendered="$TMP/supervision-$harness.txt"
  if "$FM_ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" > "$rendered" 2>/dev/null; then
    row "$(size_of "$rendered")" "$harness"
  else
    row -1 "$harness (render failed)"
  fi
done

section 'Per worker: generated brief boilerplate, one per crewmate'
printf 'Scaffolded into a throwaway home with the {TASK} placeholder unfilled, so\n'
printf 'this is the boilerplate cost before any task text is added. A ship task pays\n'
printf 'exactly one delivery-mode variant, the one its project is registered for.\n'
PROBE_ID=probe-task
PROBE_PROJECT=probe-project

# brief_bytes <slot> <mode> <label> [flag...]: scaffold one brief into its own
# throwaway home and measure it. Each slot gets an equal-length home path and
# the same task id and project name, so the only thing that moves between the
# ship rows is the delivery mode the probe registry selects.
brief_bytes() {
  local slot=$1 mode=$2 label=$3 home
  shift 3
  home="$TMP/brief$slot"
  mkdir -p "$home/data"
  printf -- '- %s [%s] - context cost probe\n' "$PROBE_PROJECT" "$mode" > "$home/data/projects.md"
  if (
    unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
    FM_HOME="$home" \
      "$FM_ROOT/bin/fm-brief.sh" "$PROBE_ID" "$PROBE_PROJECT" "$@" >/dev/null 2>&1
  ); then
    row "$(size_of "$home/data/$PROBE_ID/brief.md")" "$label"
  else
    row -1 "$label (scaffold failed)"
  fi
}
brief_bytes 1 no-mistakes 'ship brief (no-mistakes)'
brief_bytes 2 direct-PR 'ship brief (direct-PR)'
brief_bytes 3 local-only 'ship brief (local-only)'
brief_bytes 4 no-mistakes 'scout brief' --scout

section 'On trigger: agent skills, paid only by sessions that load them'
for skill in "$FM_ROOT"/.agents/skills/*/; do
  [ -d "$skill" ] || continue
  name=$(basename "$skill")
  row "$(tree_bytes "$skill")" "$name"
  trigger=$(skill_trigger "$skill/SKILL.md" 2>/dev/null || true)
  printf '            trigger: %s\n' "${trigger:-(not detected)}"
done
subtotal 'every agent skill, if a single session loaded all of them'

section 'Conditional: per-project private notes'
printf 'Loaded only when working the project they name.\n'
found=0
for note in "$DATA"/learnings-*.md "$DATA"/captain-*.md; do
  case "$note" in
    "$DATA/captain-shared.md") continue ;;
  esac
  [ -f "$note" ] || continue
  found=1
  row "$(size_of "$note")" "data/$(basename "$note")"
done
[ "$found" = 1 ] || printf '%10s  %s\n' '-' 'none present'
subtotal 'conditional project notes'

cat <<'EOF'

Public skills/ is installer-facing and is not loaded by a firstmate session, so
it carries no session cost and is not measured here.
EOF
