#!/usr/bin/env bash
# Live driver: real Claude Code in an isolated fm-lab Herdr session, driven
# through bin/fm-herdr-lab.sh. Exercises the doorbell-fragment guards of
# fm_task_inbox_ring and `fm-control.sh <id> exit` against a real composer.
set -u
ROOT=${ROOT:?}
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name doorbell-exit)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-doorbell-exit-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
FAILS=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; FAILS=$((FAILS + 1)); }
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || echo "teardown failed" >&2
  rm -rf "$TMP_ROOT"
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
  echo "wrapper requires trailing --session $SESSION" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

HOME_DIR="$TMP_ROOT/home"; export FM_HOME="$HOME_DIR"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "backend source failed"; exit 1; }
. "$ROOT/bin/fm-task-inbox-lib.sh"

HOME_DIR="$TMP_ROOT/home"; ID=dbx; LABEL=fm-$ID
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nLive doorbell exit check.\n\n## Firstmate spec\nNone.\n' > "$HOME_DIR/data/$ID/brief.md"
PROJ="$TMP_ROOT/proj"; WT="$TMP_ROOT/wt"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# p\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b "$ID" "$WT"

WS_JSON=$(lab workspace create --cwd "$WT" --label "$LABEL" --no-focus) || { echo "workspace create failed"; exit 1; }
echo "$WS_JSON" | jq -c '.result.root_pane | {pane_id, tab_id, workspace_id}'
PANE_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id')
TAB_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.tab_id')
WS_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.workspace_id // .result.workspace.workspace_id')
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"; echo "endpoint_task_id=$ID"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
  echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WS_ID"; echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/$ID.meta"

lab pane run "$PANE_ID" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
idle=0
for _ in $(seq 60); do
  st=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) idle=1; break ;;
    blocked) case "$(lab pane read "$PANE_ID" --source visible 2>/dev/null)" in
      *'Yes, I trust this folder'*) lab pane send-keys "$PANE_ID" down enter >/dev/null ;; esac ;;
  esac
  sleep 1
done
[ "$idle" = 1 ] || { echo "claude never idle"; exit 1; }
sleep 5

STATE="$HOME_DIR/state"
REC=$(fm_task_inbox_write "$STATE" "$ID" "Reply with exactly DOORBELLLIVE and nothing else.")
LINE=$(fm_task_inbox_doorbell_line "$REC")
printf 'doorbell line (%d chars): %s\n' "${#LINE}" "$LINE"

composer_text() {
  local cap
  cap=$(fm_backend_capture herdr "$TARGET" "$FM_COMPOSER_CAPTURE_LINES" "$LABEL" 2>/dev/null) || return 1
  fm_composer_extract_selected_content styled=0 "$cap" | tr -d '[:space:]'
}
screen() { printf -- '--- visible pane: %s ---\n' "$1"; lab pane read "$PANE_ID" --source visible 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -14; }
put() {  # clear then type text without Enter
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do lab pane send-keys "$PANE_ID" ctrl+u >/dev/null; done
  sleep 1
  lab pane send-text "$PANE_ID" "$1" >/dev/null
  sleep 2
}
run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=20 "$ROOT/bin/fm-control.sh" "$@" 2>&1
}
nows() { printf '%s' "$1" | tr -d '[:space:]'; }


# Control: plain exit on an empty composer, the path this change does not touch.
put ""
screen "E before exit (empty composer)"
echo "composer_state=$(fm_backend_composer_state herdr "$TARGET" "$LABEL")"
v=$(bash -x -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_send_text_submit herdr "$2" /exit 3 0.3 1.2 "$3"' _ "$ROOT" "$TARGET" "$LABEL" 2>"$EVDIR/e-trace.txt"); rc=$?
echo "send_text_submit /exit on empty composer: rc=$rc verdict=$v"
sleep 5
echo "agent_state after=$(fm_backend_agent_state herdr "$TARGET")"
screen "E after"
