#!/usr/bin/env bash
# Live driver: park a real Claude Code under Herdr agent_status=done in an
# isolated fm-lab-* session, record it as a firstmate task, then run the
# operator's command `bin/fm-control.sh <id> exit` from the checkout at $1.
# Every Herdr call is routed through the lab helper of the checkout under test.
set -u
ROOT=$(cd "$1" && pwd)
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_PANE_ID HERDR_SESSION
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name fmctl-exit)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fmctl-exit.XXXXXX")
say() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
cleanup() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && say "lab $SESSION torn down"; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] \
  || { echo "wrapper refused a call not scoped to $SESSION" >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$TMP/fakebin/herdr"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

"$LAB_HELPER" provision "$SESSION" >/dev/null || { say "provision failed"; exit 1; }
say "provisioned lab $SESSION (herdr $(herdr --version | head -1), claude $(claude --version | head -1))"

# Task worktree the worker runs in.
H=$TMP/home; WT=$TMP/wt; ID=parked1
mkdir -p "$H/state" "$H/data" "$WT"
git -C "$WT" init -q && git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

WS_JSON=$(lab workspace create --cwd "$WT" --label fm-fmctl --no-focus)
WS=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id')
TAB_JSON=$(lab tab create --workspace "$WS" --cwd "$WT" --label "fm-$ID" --no-focus)
TAB=$(printf '%s' "$TAB_JSON" | jq -er '.result.tab.tab_id')
PANE=$(printf '%s' "$TAB_JSON" | jq -er '.result.root_pane.pane_id')
say "worker pane $PANE in unfocused tab $TAB of workspace $WS"

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
for i in $(seq 1 45); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; blocked)
    case "$(lab pane read "$PANE" --source visible 2>/dev/null)" in
      *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;; esac ;;
  esac
  sleep 1
done
say "claude registered: agent_status=$st"

export PATH="$TMP/fakebin:$ORIGINAL_PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
v=$(fm_backend_herdr_send_text_submit "$SESSION:$PANE" "Reply with exactly PARKED and nothing else." 3 0.4 0.4)
say "steer turn verdict: $v"
for i in $(seq 1 60); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$st" = done ] && break
  sleep 1
done
say "parked worker: herdr agent_status=$st"
lab pane list --workspace "$WS" 2>/dev/null | jq -c '.result.panes[]? | {pane_id, agent, agent_status}'
say "fm_backend_herdr_agent_state -> $(fm_backend_herdr_agent_state "$SESSION:$PANE")"
echo "--- composer before exit (visible) ---"
lab pane read "$PANE" --source visible 2>/dev/null | tail -8

cat > "$H/state/$ID.meta" <<EOF
window=$SESSION:$PANE
backend=herdr
endpoint_task_id=$ID
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
worktree=$WT
project=$WT
harness=claude
kind=ship
EOF

say "RUN: FM_HOME=<lab home> bin/fm-control.sh $ID exit"
# Isolated lab + temp FM_HOME: the sandbox bypass tests/lib.sh exports.
FM_GATE_REFUSE_BYPASS=1 FM_HOME=$H "$ROOT/bin/fm-control.sh" "$ID" exit
rc=$?
say "fm-control.sh exit rc=$rc"
say "after exit: fm_backend_herdr_agent_state -> $(fm_backend_herdr_agent_state "$SESSION:$PANE")"
lab pane list --workspace "$WS" 2>/dev/null | jq -c '.result.panes[]? | {pane_id, agent, agent_status}'
echo "--- pane after exit (visible) ---"
lab pane read "$PANE" --source visible 2>/dev/null | tail -6
exit "$rc"
