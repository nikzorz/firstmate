#!/usr/bin/env bash
# Live end-user drive: park a real Claude worker under Herdr agent_status=done
# in an isolated fm-lab-* session, then free it with `fm-control.sh <id> exit`.
# Usage: drive-fm-control-exit-done-parked.sh <repo-root-under-test> <label>
# The lab session, scratch FM_HOME, and scratch project are all throwaway.
set -u
ROOT=$1
LABEL=$2
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name "$LABEL")
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctl-done.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd -P)
FAKEBIN=$SCRATCH/fakebin; mkdir -p "$FAKEBIN"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || { say "TEARDOWN FAILED for $SESSION"; rc=1; }
  rm -rf "$SCRATCH"
  say "teardown of $SESSION done (rc=$rc)"
  exit "$rc"
}
trap cleanup EXIT

# Same routing wrapper the repo's live guard uses: every herdr call the product
# makes must name this lab session and goes through the lab helper.
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

"$LAB_HELPER" provision "$SESSION" >/dev/null || { say "provision failed"; exit 1; }
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
say "repo under test: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.commit" 2>/dev/null))"
say "lab session: $SESSION; $(herdr --version); claude $(claude --version | head -1)"

HOME_DIR=$SCRATCH/home; PROJ=$SCRATCH/proj; WT=$SCRATCH/wt
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/parked" "$PROJ"
printf '# Task\n## Captain'"'"'s intent\nPark then exit.\n' > "$HOME_DIR/data/parked/brief.md"
git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b parked "$WT"

WS_JSON=$(lab workspace create --cwd "$WT" --label fm-ctl-done --no-focus) || { say "workspace create failed"; exit 1; }
WS=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id')
# A parked worker's pane is not the focused one: Herdr reports done only then.
TAB_JSON=$(lab tab create --workspace "$WS" --cwd "$WT" --label fm-parked --no-focus) || { say "tab create failed"; exit 1; }
TAB=$(printf '%s' "$TAB_JSON" | jq -er '.result.tab.tab_id')
PANE=$(printf '%s' "$TAB_JSON" | jq -er '.result.root_pane.pane_id')
T="$SESSION:$PANE"
say "parked worker endpoint: $T (workspace $WS, unfocused tab $TAB)"

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
for i in $(seq 1 45); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) break ;;
    blocked) case "$(lab pane read "$PANE" --source visible 2>/dev/null)" in
      *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;; esac ;;
  esac
  sleep 1
done
say "claude registered: agent_status=$st"

export PATH="$FAKEBIN:$ORIGINAL_PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
v=$(fm_backend_herdr_send_text_submit "$T" "Reply with exactly PARKEDTURN and nothing else." 3 0.4 0.4)
say "one worker turn submitted: verdict=$v"
for i in $(seq 1 60); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$st" = done ] && break
  sleep 1
done
say "herdr pane list row for the parked worker:"
lab pane list 2>/dev/null | jq -c --arg p "$PANE" '.result.panes[] | select(.pane_id==$p) | {pane_id, agent, agent_status}'
say "fm_backend_herdr_agent_state before exit: $(fm_backend_herdr_agent_state "$T")"
say "composer as the operator sees it (last visible rows):"
lab pane read "$PANE" --source visible 2>/dev/null | grep -v '^\s*$' | tail -n 6 | sed 's/^/    | /'

{
  echo "window=$T"; echo "endpoint_task_id=parked"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
  echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"
} > "$HOME_DIR/state/parked.meta"

if [ -n "${FM_DRIVE_PENDING_DRAFT:-}" ]; then
  # Adversarial: an operator draft sits unsent in the parked composer.
  lab pane send-text "$PANE" "$FM_DRIVE_PENDING_DRAFT" >/dev/null
  sleep 1
  say "typed an unsent draft into the parked composer: $(lab pane read "$PANE" --source visible 2>/dev/null | grep -F "$FM_DRIVE_PENDING_DRAFT" | tail -1)"
fi
say "\$ bin/fm-control.sh parked exit"
# Scratch FM_HOME + lab-only herdr wrapper: the documented test-harness bypass.
OUT=$(env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" parked exit 2>&1)
RC=$?
printf '%s\n' "$OUT" | sed 's/^/    > /'
say "fm-control exit rc=$RC"
say "fm_backend_herdr_agent_state after exit: $(fm_backend_herdr_agent_state "$T")"
say "pane still present (endpoint preserved): $(lab pane get "$PANE" >/dev/null 2>&1 && echo yes || echo no)"
say "claude processes left in the pane: $(lab pane process-info "$PANE" 2>/dev/null | jq -r '[.result.process_info.foreground_processes[]?.name] | join(",")')"
if [ -n "${FM_DRIVE_PENDING_DRAFT:-}" ]; then
  still=$(lab pane read "$PANE" --source visible 2>/dev/null | grep -cF "$FM_DRIVE_PENDING_DRAFT")
  say "draft still in composer after refusal: $([ "$still" -gt 0 ] && echo yes || echo no)"
  [ "$RC" != 0 ] && [ "$still" -gt 0 ] && [ "$(fm_backend_herdr_agent_state "$T")" = alive ] \
    && { say "RESULT: PASS (refused, draft preserved, agent alive)"; exit 0; } || { say "RESULT: FAIL"; exit 1; }
fi
[ "$RC" = 0 ] && case "$OUT" in stopped*) true ;; *) false ;; esac && say "RESULT: PASS" || { say "RESULT: FAIL"; exit 1; }
