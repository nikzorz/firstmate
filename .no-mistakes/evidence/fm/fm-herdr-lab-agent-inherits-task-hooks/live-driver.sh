#!/usr/bin/env bash
# Live proof: a lab agent started with no --cwd runs in the lab scratch dir and
# never fires the task worktree's hooks; an explicit --cwd into the worktree
# (control) does fire them.
set -u
ROOT=$1 EV=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
WORK=/tmp/fm-lab-cwd-live
T="$WORK/task-worktree"
M="$WORK/worker-hook-events.log"
rm -rf "$T" "$M"; mkdir -p "$T/.claude"
git -C "$T" init -q
cat > "$T/.claude/settings.local.json" <<EOF
{"hooks":{
 "SessionStart":[{"hooks":[{"type":"command","command":"echo \"SessionStart \$PWD\" >> $M"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"echo \"Stop \$PWD\" >> $M"}]}],
 "StopFailure":[{"hooks":[{"type":"command","command":"echo \"StopFailure \$PWD\" >> $M"}]}],
 "SessionEnd":[{"hooks":[{"type":"command","command":"echo \"SessionEnd \$PWD\" >> $M"}]}]
}}
EOF
: > "$M"
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
lab() { "$HELPER" run "$SESSION" "$@"; }

SESSION=$("$HELPER" name cwdlive)
log "session=$SESSION  caller cwd=$T (simulated task worktree with worker hooks)"
cleanup() {
  log "teardown"
  "$HELPER" teardown "$SESSION"; log "teardown exit=$?"
  log "scratch dir after teardown: $(ls -d "${TMPDIR:-/tmp}/fm-herdr-lab-$UID/$SESSION.cwd" 2>&1)"
  log "worker hook events after teardown:"; cat "$M"; echo "--- end events"
}
trap cleanup EXIT
cd "$T" || exit 1
"$HELPER" provision "$SESSION" || { log "provision failed"; exit 1; }
SCRATCH="${TMPDIR:-/tmp}/fm-herdr-lab-$UID/$SESSION.cwd"
log "provisioned; scratch=$SCRATCH exists=$([ -d "$SCRATCH" ] && echo yes || echo no)"

start_claude() { # <label> <pane> <shot-prefix>
  local name=$1 pane=$2 shot=$3 i screen accepted=0 ready=0
  lab agent start "$name" --kind claude --pane "$pane" --timeout 120000 > "$WORK/$shot-agent-start.json" 2>&1 &
  local sp=$!
  for i in $(seq 1 120); do
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'trust this folder'*)
        if [ "$accepted" = 0 ]; then
          printf '%s\n' "$screen" > "$EV/$shot-1-trust-dialog.txt"
          log "$name: trust dialog shown (cursor on: $(printf '%s' "$screen" | grep -o '❯ [A-Za-z ,]*' | head -1)); sending down+enter via helper"
          lab pane send-keys "$pane" down enter >/dev/null; accepted=1
        fi ;;
      *'Claude Code v'*'❯'*) ready=1; break ;;
    esac
    sleep 1
  done
  wait "$sp"; log "$name: agent start exit=$? trust_accepted=$accepted composer_ready=$ready"
  sleep 2
  lab pane read "$pane" --source visible > "$EV/$shot-2-composer.txt" 2>&1
}

prompt_claude() { # <pane> <shot-prefix>
  local i n=0
  lab agent prompt "$1" "Reply with exactly LABPONG and nothing else." > "$WORK/$2-prompt.json" 2>&1
  log "prompt exit=$?"
  for i in $(seq 1 120); do
    n=$(lab pane read "$1" --source visible 2>/dev/null | grep -c 'LABPONG')
    [ "$n" -ge 2 ] && break
    sleep 1
  done
  log "reply observed=$([ "$n" -ge 2 ] && echo yes || echo no)"
  sleep 5
  lab pane read "$1" --source visible > "$EV/$2-3-after-reply.txt" 2>&1
}

# Scenario: default lab workspace (no --cwd) from inside the task worktree.
WS=$(lab workspace create --label probe --no-focus) || { log "workspace create failed"; exit 1; }
P=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
lab pane run "$P" 'echo "LAB_PWD=$(pwd -P)"' >/dev/null; sleep 2
log "default pane $P: $(lab pane read "$P" --source visible | grep -o 'LAB_PWD=[^ ]*' | tail -1)"
lab pane run "$P" 'clear' >/dev/null; sleep 1
start_claude probe "$P" default
before=$(wc -l < "$M")
prompt_claude "$P" default
log "worker hook events after default-cwd lab Claude turn: $(wc -l < "$M") (before prompt: $before)"
cp "$M" "$EV/default-worker-hook-events.log"

# Control: explicit --cwd into the task worktree reproduces the original leak.
WS2=$(lab workspace create --cwd "$T" --label control --no-focus) || { log "control workspace create failed"; exit 1; }
P2=$(printf '%s' "$WS2" | jq -r '.result.root_pane.pane_id')
lab pane run "$P2" 'echo "LAB_PWD=$(pwd -P)"' >/dev/null; sleep 2
log "control pane $P2: $(lab pane read "$P2" --source visible | grep -o 'LAB_PWD=[^ ]*' | tail -1)"
lab pane run "$P2" 'clear' >/dev/null; sleep 1
start_claude control "$P2" control
prompt_claude "$P2" control
log "worker hook events after control (worktree cwd) Claude turn:"; cat "$M"
cp "$M" "$EV/control-worker-hook-events.log"
