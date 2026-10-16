#!/usr/bin/env bash
# fm-spec-intent-check.sh - flag ship-brief spec bullets that add scope the
# captain's words never asked for.
#
# Usage: fm-spec-intent-check.sh <brief> <record>
#
# AGENTS.md section 11 requires every trigger, condition, case or guarantee a
# `## Firstmate spec` bullet adds to trace to words in `## Captain's intent`.
# Written alone that rule has been broken by briefs that read as plain build
# instructions, so bin/fm-spawn.sh runs this before a fresh ship launches and
# refuses while it fails.
#
# Whether a bullet adds behaviour is a reading of meaning, not of vocabulary:
# an added fallback usually reuses the intent's own nouns, while a legitimate
# bullet names files and primitives the intent never mentions. No word or
# pattern test separates the two, so one bounded model call judges each bullet.
#
# Each top-level list item of the spec, with its continuation lines, is one
# bullet; a paragraph outside a list is one bullet too. A flagged bullet passes
# only when it carries the justification marker `[justified: <reason>]` with a
# nonempty reason, which records on the bullet itself why firstmate kept scope
# the intent does not name.
#
# The judge is Claude Code run headless with no tools, no session persistence,
# and safe mode (no project instructions, skills, hooks or MCP servers), bounded
# by fm_run_timed (bin/fm-timeout-lib.sh). Its answer must hold exactly one
# `<n> ok` or `<n> flag: <what it adds>` line per bullet; anything else, a
# non-zero exit, or the bound is a refusal, never a pass. A host with no claude
# installed cannot run the judge at all, and refusing there would block every
# ship launch on a home whose primary harness is not Claude, so the check steps
# aside with a warning instead.
# FM_SPEC_INTENT_CHECK_CLAUDE_BIN names the claude executable (default: claude
# on PATH), so a hermetic test can run a stub judge through the real call.
#
# <record> receives the model, the judge's exit status, the intent, the
# numbered bullets, the raw answer and the verdict, so every pass and refusal
# can be read back after the launch.
#
# Exit status: 0 when no unjustified bullet is flagged; 1 when one or more is,
# printing each on stdout; 2 when the installed judge failed or its answer was
# malformed, or on a usage error; 3 when claude is not installed and the check
# was skipped.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SPEC_INTENT_CHECK_MODEL=opus
SPEC_INTENT_CHECK_TIMEOUT_SECS=300

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
BRIEF=$1
RECORD=$2
[ -f "$BRIEF" ] && [ -r "$BRIEF" ] || { echo "error: cannot read brief $BRIEF" >&2; exit 2; }

INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
SPEC=$(fm_brief_task_heading_body "$BRIEF" "## Firstmate spec")
if [ -z "$(printf '%s' "$INTENT" | tr -d '[:space:]')" ] || [ -z "$(printf '%s' "$SPEC" | tr -d '[:space:]')" ]; then
  echo "error: $BRIEF needs nonempty ## Captain's intent and ## Firstmate spec subsections to check" >&2
  exit 2
fi

# One bullet per output line, its marker stripped and its continuation lines
# joined, so a bullet's number is its line number.
BULLETS=$(printf '%s\n' "$SPEC" | awk '
  function flush() { if (item != "") print item; item = "" }
  /^[[:space:]]*$/ { gap = 1; next }
  /^([-*+]|[0-9]+[.)])[[:space:]]/ {
    flush()
    item = $0
    sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", item)
    gap = 0
    next
  }
  {
    text = $0
    indented = (text ~ /^[[:space:]]/)
    sub(/^[[:space:]]+/, "", text)
    if (item == "" || (gap && !indented)) { flush(); item = text } else item = item " " text
    gap = 0
  }
  END { flush() }
')
BULLET_COUNT=$(printf '%s\n' "$BULLETS" | awk 'END { print NR }')

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-intent-check.XXXXXX") || { echo "error: cannot create a scratch directory" >&2; exit 2; }
trap 'rm -rf -- "$WORK"' EXIT

cat > "$WORK/system.txt" <<'EOF'
You check one task brief before a worker builds it.
The captain's intent is what the captain asked for, in the captain's words.
The firstmate spec is the supervisor's build instructions for the worker, split into numbered bullets.
The rule: every trigger, condition, fallback, case, option or guarantee a spec bullet requires the delivered change to have must trace to words in the captain's intent.
Flag a bullet when it requires behaviour the intent's words do not call for, such as an extra trigger or condition, a fallback or backward-compatibility path, an additional case or input the change must handle, an extra option, argument, filter or mode, or a guarantee beyond the ask.
A test bullet that asserts such added behaviour is flagged too.
Do not flag a bullet that only says where or how to build what the intent asks (which files, owners or existing primitives to use), how to test the asked behaviour, what is out of scope, or which process steps the worker follows, such as loading a skill or starting validation.
Judge against the intent text alone, not against what seems sensible or what the bullet's own justification says.
Answer with exactly one line per bullet, in bullet order, and nothing else:
<n> ok
<n> flag: <the added trigger, condition, fallback, case, option or guarantee, in a few words>
EOF

{
  printf '# Captain'"'"'s intent\n%s\n\n# Firstmate spec bullets\n' "$INTENT"
  printf '%s\n' "$BULLETS" | awk '{ printf "%d. %s\n", NR, $0 }'
} > "$WORK/message.txt"

CLAUDE_BIN=${FM_SPEC_INTENT_CHECK_CLAUDE_BIN:-claude}
JUDGE_STATUS=127
RESULT=""
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  (
    cd "$WORK" || exit 127
    fm_run_timed "$SPEC_INTENT_CHECK_TIMEOUT_SECS" "$CLAUDE_BIN" -p --safe-mode --tools "" \
      --no-session-persistence --model "$SPEC_INTENT_CHECK_MODEL" --output-format text \
      --system-prompt-file "$WORK/system.txt"
  ) < "$WORK/message.txt" > "$WORK/answer.txt" 2> "$WORK/errors.txt"
  JUDGE_STATUS=$?
else
  printf '%s is not installed\n' "$CLAUDE_BIN" > "$WORK/errors.txt"
  : > "$WORK/answer.txt"
  RESULT="skipped: $CLAUDE_BIN is not installed"
fi

# verdict lines: "ok <n>", "flag <n> <reason>", or "malformed <why>".
VERDICT=$(tr -d '\r' < "$WORK/answer.txt" | awk -v count="$BULLET_COUNT" '
  /^[[:space:]]*$/ { next }
  match($0, /^[[:space:]]*[0-9]+[[:space:]]+ok[[:space:]]*$/) {
    n = $1 + 0
    if (n < 1 || n > count || (n in seen)) { print "malformed bullet " n " answered out of range or twice"; bad = 1; exit }
    seen[n] = 1; print "ok " n; next
  }
  match($0, /^[[:space:]]*[0-9]+[[:space:]]+flag:[[:space:]]*[^[:space:]]/) {
    n = $1 + 0
    if (n < 1 || n > count || (n in seen)) { print "malformed bullet " n " answered out of range or twice"; bad = 1; exit }
    reason = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+flag:[[:space:]]*/, "", reason)
    seen[n] = 1; print "flag " n " " reason; next
  }
  { print "malformed unexpected answer line: " $0; bad = 1; exit }
  END {
    if (bad) exit
    for (n = 1; n <= count; n++) if (!(n in seen)) { print "malformed bullet " n " has no answer"; exit }
  }
')

FLAGGED=''
JUSTIFIED=''
if [ -n "$RESULT" ]; then
  :
elif [ "$JUDGE_STATUS" -ne 0 ]; then
  RESULT="cannot-run: the judge exited $JUDGE_STATUS"
  fm_timed_out "$JUDGE_STATUS" && RESULT="cannot-run: the judge hit its ${SPEC_INTENT_CHECK_TIMEOUT_SECS}s bound"
elif printf '%s\n' "$VERDICT" | grep -q '^malformed '; then
  RESULT="cannot-run: $(printf '%s\n' "$VERDICT" | sed -n 's/^malformed //p' | head -n 1)"
else
  while read -r kind n reason; do
    [ "$kind" = flag ] || continue
    bullet=$(printf '%s\n' "$BULLETS" | sed -n "${n}p")
    if printf '%s\n' "$bullet" | grep -Eq '\[justified:[[:space:]]*[^][:space:]][^]]*\]'; then
      JUSTIFIED="${JUSTIFIED}bullet $n adds $reason: $bullet
"
    else
      FLAGGED="${FLAGGED}bullet $n adds $reason: $bullet
"
    fi
  done <<EOF
$VERDICT
EOF
  RESULT=pass
  [ -z "$FLAGGED" ] || RESULT=flagged
fi

{
  printf 'model: %s\njudge exit: %s\nresult: %s\n\n' "$SPEC_INTENT_CHECK_MODEL" "$JUDGE_STATUS" "$RESULT"
  cat "$WORK/message.txt"
  printf '\n# Judge answer\n'
  cat "$WORK/answer.txt"
  if [ -s "$WORK/errors.txt" ]; then
    printf '\n# Judge errors\n'
    cat "$WORK/errors.txt"
  fi
  if [ -n "$JUSTIFIED" ]; then
    printf '\n# Justified bullets\n%s' "$JUSTIFIED"
  fi
  if [ -n "$FLAGGED" ]; then
    printf '\n# Unjustified bullets\n%s' "$FLAGGED"
  fi
} > "$RECORD" || { echo "error: cannot write the check record $RECORD" >&2; exit 2; }

case "$RESULT" in
  pass) exit 0 ;;
  flagged) printf '%s' "$FLAGGED"; exit 1 ;;
  skipped:*) echo "warning: the spec-intent check of $BRIEF was skipped ($CLAUDE_BIN is not installed); its spec bullets were not judged against the captain's intent" >&2; exit 3 ;;
  *) echo "error: the spec-intent check could not judge $BRIEF ($RESULT); see $RECORD" >&2; exit 2 ;;
esac
