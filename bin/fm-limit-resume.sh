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
#             1 refused - the condition is not proven, or a step did not land.
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
# proves the window is still exhausted reports when it resets, so this records a
# one-shot recheck deadline (bin/fm-classify-lib.sh's pause_deadline_set) and the
# supervisors recheck at the reset instead of purely on FM_PAUSE_RESURFACE_SECS.
# Without it the recheck was up to a full hour late for a window that had already
# rolled - correct recovery, but late enough on a short window to read as none.
# A reset time the provider does not report simply is not recorded, which leaves
# the fixed cadence in charge exactly as before.
#
# That wait is OPENED and CLOSED here, as one contract. Unlike an ordinary pause,
# the crew never learns this line exists, so nothing else would ever close it: a
# `paused:` line left standing keeps a recovered crew on the hour-long pause
# recheck when it should be back on the wedge cadence, and this feature exists
# because crews sat frozen for hours unnoticed. So the recover path closes it,
# and only its OWN line, identified exactly as the idempotent open identifies it.
#
# THE STEER deliberately does not assert where the crew stopped. In the live
# incident the interrupted validation run had lost custody and the crew correctly
# started a fresh one; a steer that had asserted a remembered position would have
# been wrong. It tells the crew to re-read its own current state first.
set -eu

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
# Idempotent: a status stream whose last event is already this pause is left
# alone, so repeated rechecks add no duplicate wake-triggering lines.
# The recheck deadline is refreshed on every recheck rather than only on the
# first append, because the window that will actually clear the wait can change
# between reads - and an elapsed deadline is dropped rather than re-recorded, so
# a recheck that finds the window still exhausted returns to the fixed cadence
# instead of scheduling itself again for a time that has already passed.
PAUSE_NOTE="claude usage limit reached; waiting for the account window to reset"
record_pause() {
  local last
  pause_deadline_set "$STATE" "$ID" "$RECHECK_EPOCH"
  last=$(last_status_line "$LOG")
  case "$last" in
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}: $PAUSE_NOTE") return 0 ;;
  esac
  printf '%s: %s\n' "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" "$PAUSE_NOTE" >> "$LOG"
}

# Close that wait once recovery has landed, by appending the fleet's ordinary
# non-paused progress verb so the crew's last event stops satisfying
# status_is_paused and the daemon's wedge branch is reachable again.
# Ownership is the same exact-match identity record_pause uses: a `paused:` line
# the CREW wrote for its own reason still means what it says and is left alone,
# because closing a wait firstmate does not own would silence it. Nothing to
# close - never opened, no status file, or someone else's pause - is a no-op, and
# a close can never fail the recovery it follows.
# The recheck deadline is dropped unconditionally here, unlike the status line:
# it is firstmate's own artifact with no other writer, so recovery through this
# path leaves nothing behind. It is not the guarantee, though - recovery can also
# happen without this script running at all, e.g. a human dismissing the prompt in
# the pane. What actually bounds the deadline's life to the pause it was written
# for is each supervisor's clear_pause_tracking (bin/fm-watch.sh,
# bin/fm-supervise-daemon.sh), which drops it alongside every other pause artifact
# the moment the crew stops declaring the pause.
RESUME_NOTE="claude usage limit window reset; prompt dismissed and the crew re-steered"
close_pause() {
  local last
  pause_deadline_clear "$STATE" "$ID"
  last=$(last_status_line "$LOG")
  case "$last" in
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}: $PAUSE_NOTE") ;;
    *) return 0 ;;
  esac
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

if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "$STEER"; then
  echo "refused: dismissed the prompt on $ID but the resume instruction did not land; steer it by hand" >&2
  exit 1
fi

close_pause

echo "$ID: dismissed the claude usage-limit prompt and sent the resume instruction"
