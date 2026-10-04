#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer, to recover the steering doorbell from a fragment a stalled render
# leaves in the composer, and to read a Claude parked under agent_status=done as
# alive. It then requires the same submit path to prove and submit a typed /exit
# slash command behind the command popup Claude renders below the composer and
# verifies the agent actually exited. It fails naming the harness and version
# rather than degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
WS=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id') \
  || fail "workspace create did not return a workspace id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

launch_claude() {  # <pane>
  local pane=$1 st screen trusted=0 i=0
  lab pane run "$pane" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
    || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane $pane"
  while [ "$i" -lt 60 ]; do
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        # The composer footer means Claude is past any folder-trust prompt. Herdr
        # can report the agent idle while that prompt is still up, so the wait
        # keys off the rendered composer rather than the native status alone.
        st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        # A fresh checkout path stops on Claude's folder-trust prompt, which the
        # pre-send proof would read as a non-empty composer. Accept it once and
        # keep waiting for a real idle composer; the accepted dialog stays in the
        # viewport. The prompt preselects "No, exit", so move to "Yes" before
        # confirming; a bare Enter quits Claude.
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$pane" down enter >/dev/null \
            || fail "could not accept Claude's folder-trust prompt"
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane $pane"
}

launch_claude "$PANE"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# A doorbell rung while the worker's render is stalled, as on a saturated
# host, fails its payload proof against a screen that has not caught up, and
# the Ctrl+U clear then reads that stale screen as empty. Once the agent runs
# again it applies the whole line and then one Ctrl+U, which leaves a doorbell
# prefix in the composer. Stopping only the agent process reproduces the stall;
# the agent is exec'd so no job-control shell takes the pane over while it is
# stopped. The next ring must clear that prefix and deliver the full line.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
STALL_CWD="$TMP_ROOT/stall-cwd"
STALL_STATE="$TMP_ROOT/stall-state"
mkdir -p "$STALL_CWD" "$STALL_STATE"
STALL_WS=$(lab workspace create --cwd "$STALL_CWD" --label fm-stalllive --no-focus) \
  || fail "could not create the isolated doorbell-stall workspace"
STALL_PANE=$(printf '%s' "$STALL_WS" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a doorbell-stall pane id"
STALL_TARGET="$SESSION:$STALL_PANE"
lab pane run "$STALL_PANE" "exec env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the doorbell-stall pane"
idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$STALL_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) idle=1; break ;;
    blocked)
      case "$(lab pane read "$STALL_PANE" --source visible 2>/dev/null || true)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$STALL_PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt in the doorbell-stall pane" ;;
      esac
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the doorbell-stall pane"
sleep 5
[ "$(fm_backend_composer_state herdr "$STALL_TARGET")" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the doorbell-stall composer is not empty before the ring"
STALL_PID=
for p in $(pgrep -x claude); do
  [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$STALL_CWD" ] && STALL_PID=$p
done
[ -n "$STALL_PID" ] || fail "could not find the doorbell-stall Claude process to stall"
STALL_FILE="$STALL_CWD/stall-acted"
stall_rec=$(fm_task_inbox_write "$STALL_STATE" stall "Create the empty file $STALL_FILE, then reply done.") \
  || fail "could not write the doorbell-stall inbox record"
stall_line=$(fm_task_inbox_doorbell_line "$stall_rec")
kill -STOP "$STALL_PID"
ring_rc=0
fm_task_inbox_ring herdr "$STALL_TARGET" "$stall_rec" || ring_rc=$?
kill -CONT "$STALL_PID"
sleep 3
[ "$(fm_task_inbox_composer_doorbell herdr "$STALL_TARGET" "$stall_line")" = fragment ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a doorbell rung into a stalled render (ring rc $ring_rc) no longer leaves a doorbell fragment; re-verify the stall reproduction"
ring_rc=0
fm_task_inbox_ring herdr "$STALL_TARGET" "$stall_rec" || ring_rc=$?
[ "$ring_rc" = 0 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ring skipped a composer holding only its own doorbell fragment (rc $ring_rc)"
acked=0
i=0
while [ "$i" -lt 90 ]; do
  if [ -f "$STALL_FILE" ] && [ -f "${stall_rec%/*}/handled/${stall_rec##*/}" ]; then
    acked=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$acked" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the re-rung doorbell never led the worker to act on and acknowledge its instruction"
pass "live Herdr doorbell stall: Claude Code ($VERSION) on $HERDR_VER recovers a doorbell fragment left by a stalled render, and the worker acts and acknowledges"

# A parked worker is a Claude whose turn finished while its pane was unfocused,
# which Herdr reports as done; a focused pane stays idle. Park one in a
# background tab and require lifecycle control to read it alive.
PARK_TAB=$(lab tab create --workspace "$WS" --cwd "$ROOT" --label fm-submitlive-park --no-focus) \
  || fail "could not create the unfocused parked tab"
PARK_PANE=$(printf '%s' "$PARK_TAB" | jq -er '.result.root_pane.pane_id') \
  || fail "tab create did not return a pane id"
PARK_TARGET="$SESSION:$PARK_PANE"
launch_claude "$PARK_PANE"
DONE_TOKEN="FMHERDRDONE$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$PARK_TARGET" "Reply with exactly $DONE_TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run in the unfocused tab against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a steer to the unfocused tab must confirm empty, got '$verdict'"
parked=0
i=0
while [ "$i" -lt 60 ]; do
  st=$(lab agent get "$PARK_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  if [ "$st" = "done" ]; then
    parked=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$parked" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: an unfocused finished turn never reported agent_status=done (last '$st')"
state=$(fm_backend_herdr_agent_state "$PARK_TARGET")
[ "$state" = alive ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a parked Claude under agent_status=done must read alive, got '$state'"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER parked under agent_status=done reads alive"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. The viewport
# capture must prove the typed /exit and submit it; Claude must actually
# exit. This scenario runs last because it ends the lab's Claude process.
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 1.2) \
  || fail "send_text_submit failed to run the /exit submission against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a typed /exit behind its command popup was judged unsent and cleared instead of submitted"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the /exit submission reported '$verdict' but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
