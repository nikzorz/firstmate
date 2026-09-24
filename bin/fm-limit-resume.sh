#!/usr/bin/env bash
# fm-limit-resume.sh - recover ONE crewmate stalled on Claude Code's usage-limit
# prompt, but only once the account window has actually reset.
#
# Usage: FM_HOME=<firstmate home> bin/fm-limit-resume.sh <task-id>
#        FM_HOME=<firstmate home> bin/fm-limit-resume.sh --check <task-id>
#
#   --check   report the verdict and exit without sending anything.
#
# Exit codes: 0 recovered, the bounded wait was recorded, or --check reported a
#               verdict it could establish.
#             1 refused - the condition is not proven or a step did not land.
#               The stderr line says which; a refusal after Escape says the
#               prompt was dismissed but the resume instruction was not sent.
#             2 usage error.
#
# WHY (incident 2026-07-29): a crew that exhausts the account usage limit
# mid-turn stops on an interactive choice prompt that waits for a human
# indefinitely. Three crews sat ~8.7 hours after the five-hour window had reset.
# Manual recovery was one Escape plus one steer; this is that, with the proofs.
#
# WHAT IT WILL NOT DO. It never tears down, restarts, rebases, or discards work:
# the crewmate's own agent, worktree, commits, and any in-flight validation run
# are left exactly as they are, and recovery is only a dismissed prompt plus a
# resume instruction. It also never guesses:
#
#   1. The task must record `harness=claude`. No other verified harness has been
#      observed presenting this prompt, so nothing else is even inspected.
#   2. The pane is captured and matched FRESH here, immediately before any key is
#      sent - a stale verdict from an earlier read is never sufficient, because
#      the crew may have moved on since.
#   3. The quota authority must report the window reset. `quota-axi` owns how
#      model and product windows relate to bounding account windows (AGENTS.md
#      section 4), so the decision is its current output, never elapsed time.
#   4. After Escape, the prompt must be PROVABLY gone on a re-read before the
#      steer is sent: a capture that succeeded, was non-empty, and did not match.
#      A prompt still showing stops the run rather than escalating keys, and a
#      pane that cannot be read proves nothing and stops it too.
#
# An unreadable pane, an uncertain match, or an unreadable quota window refuses
# and reports, because sending keys into a live crewmate's pane speculatively is
# worse than the stall it would fix.
#
# WINDOW STILL EXHAUSTED. That is a bounded external wait that clears on its own,
# not a wedge, so this records it with the fleet's existing `paused:` vocabulary
# (bin/fm-classify-lib.sh) on the task's status file. From that point the ordinary
# declared-pause handling in both supervisors applies: absorbed while idle and
# re-surfaced for a recheck, instead of aging toward a possible-wedge escalation
# every FM_STALE_ESCALATE_SECS. The append is idempotent, so re-running this every
# recheck does not stack duplicate lines.
#
# That pause also carries WHEN it is worth rechecking. The same quota read that
# proves the window is still exhausted reports when it resets, so a future reset
# is written into the pause line itself as ` until <YYYY-MM-DDTHH:MM:SSZ>` - the
# declared-wait grammar bin/fm-classify-lib.sh's status_paused_until reads - and
# both supervisors recheck at that time instead of purely on the fixed cadence.
# A reset time the provider does not report is simply left off, which leaves the
# fixed cadence in charge. A changed reset time appends one new pause line.
#
# That wait is OPENED and CLOSED here, as one contract. Unlike an ordinary pause,
# the crew never learns this line exists, so nothing else would ever close it: a
# `paused:` line left standing keeps a recovered crew on the hour-long pause
# recheck when it should be back on the wedge cadence, and this feature exists
# because crews sat frozen for hours unnoticed. So the recover path closes it,
# and only its OWN line, identified by the same note prefix the idempotent open
# uses. It closes only once bin/fm-send.sh has durably recorded the resume
# steer; a refusal that dismissed or sent nothing leaves the wait standing.
#
# THE STEER deliberately does not assert where the crew stopped. In the live
# incident the interrupted validation run had lost custody and the crew correctly
# started a fresh one; a steer that had asserted a remembered position would have
# been wrong. It tells the crew to re-read its own current state first.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Answered before the gate refusal and the FM_HOME check: reading the header
# resolves no target and touches no home.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# steer a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-limit-resume refuses to resolve a task without an explicit firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-claude-limit-lib.sh
. "$SCRIPT_DIR/fm-claude-limit-lib.sh"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi
ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-limit-resume.sh [--check] <task-id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
[ -f "$META" ] || { echo "refused: no metadata for task '$ID' in $STATE" >&2; exit 1; }

HARNESS=$(fm_meta_get "$META" harness)
BACKEND=$(fm_backend_of_meta "$META")
# `|| true`: fm_backend_target_of_meta reports absence by exit status, and under
# `set -e` that would abort here with no diagnostic instead of the refusal below.
TARGET=$(fm_backend_target_of_meta "$META" || true)
EXPECTED_LABEL="fm-$ID"

if [ "$HARNESS" != claude ]; then
  echo "refused: task '$ID' records harness='${HARNESS:-none}'; the usage-limit prompt is claude-specific" >&2
  exit 1
fi
[ -n "$TARGET" ] || { echo "refused: task '$ID' has no recorded backend target" >&2; exit 1; }

SCAN_LINES=$(fm_claude_limit_scan_lines)

# What a FRESH read of the live pane proves, as three distinct outcomes:
#   showing    - the pane is parked on the usage-limit prompt right now;
#   absent     - the capture succeeded, was non-empty, and did not match, so the
#                prompt is provably not there;
#   unreadable - the capture failed or came back empty, which proves nothing.
# The two callers need OPPOSITE proofs, and conflating them is what would let an
# unreadable pane authorize a keystroke: the entry gate requires `showing`, and
# the post-Escape dismissal proof requires `absent` specifically.
prompt_state() {  # -> showing|absent|unreadable
  local pane
  pane=$(fm_backend_capture "$BACKEND" "$TARGET" "$SCAN_LINES" "$EXPECTED_LABEL" 2>/dev/null) \
    || { printf 'unreadable'; return 0; }
  [ -n "$pane" ] || { printf 'unreadable'; return 0; }
  if printf '%s' "$pane" | fm_claude_limit_dialog_match; then
    printf 'showing'
  else
    printf 'absent'
  fi
  return 0
}

if [ "$(prompt_state)" != showing ]; then
  echo "refused: $ID is not showing the claude usage-limit prompt (pane unreadable, or the crew has moved on)" >&2
  exit 1
fi

# One quota read serves both the verdict and, when the window is exhausted, the
# epoch at which rechecking it can actually change the answer.
WINDOW_READ=$(fm_claude_limit_window_read)
WINDOW=${WINDOW_READ%%$'\t'*}
RECHECK_EPOCH=${WINDOW_READ#*$'\t'}

# Record the bounded external wait once, using the fleet's own pause vocabulary.
# Idempotent: a status stream whose last event is already this pause, with the
# same reset time or none newly known, is left alone, so repeated rechecks add no
# duplicate wake-triggering lines. Only a FUTURE reset is written as `until`: an
# elapsed one would make the supervisors recheck immediately, so a recheck that
# still finds the window exhausted returns to the fixed cadence instead of
# scheduling itself for a time that has already passed.
PAUSE_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
PAUSE_NOTE="claude usage limit reached; waiting for the account window to reset"
PAUSE_LINE="$PAUSE_VERB: $PAUSE_NOTE"

epoch_to_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# 0 when <line> is this script's own pause, with or without an `until` suffix.
own_pause_line() {  # <line>
  case "$1" in
    "$PAUSE_LINE"|"$PAUSE_LINE until "*) return 0 ;;
  esac
  return 1
}

record_pause() {
  local last line until_iso=''
  case "$RECHECK_EPOCH" in
    ''|*[!0-9]*) ;;
    *) [ "$RECHECK_EPOCH" -gt "$(date +%s)" ] && until_iso=$(epoch_to_iso "$RECHECK_EPOCH") ;;
  esac
  line=$PAUSE_LINE
  [ -z "$until_iso" ] || line="$line until $until_iso"
  last=$(last_status_line "$LOG")
  if own_pause_line "$last"; then
    [ -n "$until_iso" ] || return 0
    [ "$last" != "$line" ] || return 0
  fi
  printf '%s\n' "$line" >> "$LOG"
}

# Close that wait once recovery has landed, by appending the fleet's ordinary
# non-paused progress verb so the crew's last event stops satisfying
# status_is_paused and the wedge path is reachable again.
# Ownership is the same note-prefix identity record_pause uses: a `paused:` line
# the CREW wrote for its own reason still means what it says and is left alone,
# because closing a wait firstmate does not own would silence it. Nothing to
# close - never opened, no status file, or someone else's pause - is a no-op, and
# a close can never fail the recovery it follows.
RESUME_NOTE="claude usage limit window reset; prompt dismissed and the crew re-steered"
close_pause() {
  own_pause_line "$(last_status_line "$LOG")" || return 0
  printf 'working: %s\n' "$RESUME_NOTE" >> "$LOG" 2>/dev/null || true
  return 0
}

case "$WINDOW" in
  reset) ;;
  exhausted)
    if [ "$CHECK_ONLY" = 1 ]; then
      echo "$ID: parked on the claude usage-limit prompt; the account window is still exhausted (bounded external wait)"
      exit 0
    fi
    record_pause
    echo "$ID: account window still exhausted; recorded the bounded external wait and sent nothing"
    exit 0
    ;;
  *)
    echo "refused: $ID is parked on the claude usage-limit prompt but the quota window could not be read; not sending keys" >&2
    exit 1
    ;;
esac

if [ "$CHECK_ONLY" = 1 ]; then
  echo "$ID: parked on the claude usage-limit prompt and the account window has reset; recoverable"
  exit 0
fi

if ! fm_backend_send_key "$BACKEND" "$TARGET" Escape "$EXPECTED_LABEL"; then
  echo "refused: could not send Escape to $ID on backend '$BACKEND'" >&2
  exit 1
fi

# Settle, then require positive proof the prompt is GONE before steering. A
# prompt still showing means the dismissal did not take, and escalating more keys
# blind is exactly what this script exists to avoid. A malformed settle value
# falls back to the default rather than reaching sleep: aborting here, after
# Escape has already been sent, would leave the crew dismissed but unsteered with
# none of the refusals below reported.
SETTLE_DEFAULT=1
SETTLE=${FM_LIMIT_RESUME_SETTLE:-$SETTLE_DEFAULT}
[[ $SETTLE =~ ^[0-9]+(\.[0-9]+)?$ ]] || SETTLE=$SETTLE_DEFAULT
[ "$SETTLE" = 0 ] || sleep "$SETTLE"
case "$(prompt_state)" in
  absent) ;;
  showing)
    echo "refused: $ID still shows the claude usage-limit prompt after Escape; left untouched for inspection" >&2
    exit 1
    ;;
  *)
    echo "refused: $ID's pane could not be read after Escape, so the prompt's dismissal is unproven; left untouched for inspection" >&2
    exit 1
    ;;
esac

STEER=${FM_LIMIT_RESUME_STEER:-"The claude usage limit that stalled you has reset. Do not assume where you stopped: re-read your own current state first, including whether your validation run still exists and belongs to your current commit, then continue from what you actually find."}

# bin/fm-send.sh exits 0 only once the steer is durably recorded for the crew;
# any nonzero status means nothing was confirmed sent.
if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "$STEER"; then
  echo "refused: dismissed the prompt on $ID but the resume instruction was not sent; steer it by hand" >&2
  exit 1
fi

close_pause

echo "$ID: dismissed the claude usage-limit prompt and sent the resume instruction"
