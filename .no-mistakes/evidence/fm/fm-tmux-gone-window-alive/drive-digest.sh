#!/usr/bin/env bash
# Session-start digest lane lines, then sends at a recorded lane whose window is
# gone while a prefix sibling lives, in a lab home on a private tmux server.
# Usage: drive-digest.sh <tree> <label>
set -u
TREE=$1
for v in TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do unset "$v"; done
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$TREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCK=$("$TREE/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCK FM_HOME=$LAB
trap 'tmux kill-server 2>/dev/null; "$TREE/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
tmux new-session -d -s firstmate -n fm-live
tmux new-window -d -t firstmate: -n fm-mate-2
lane() { mkdir -p "$LAB/wt-$1"; printf '%s\n' "window=$2" "worktree=$LAB/wt-$1" "kind=ship" "harness=claude" "backend=tmux" > "$LAB/state/$1.meta"; printf 'working: %s\n' "$3" > "$LAB/state/$1.status"; }
lane live  firstmate:fm-live        "holding course"
lane mate  firstmate:fm-mate        "window gone, sibling fm-mate-2 live"
lane ghost no-such-session:fm-ghost "session gone"
echo "== $2: live tmux inventory =="; tmux list-windows -a -F '  #{session_name}:#{window_name}'
echo "== $2: fm-session-start.sh lane lines =="
"$TREE/bin/fm-session-start.sh" --source startup 2>&1 | grep -E '^(live|mate|ghost) \|'
echo "== $2: fm-fleet-snapshot.sh lane lines =="
"$TREE/bin/fm-fleet-snapshot.sh" 2>&1 | grep -E 'live|mate|ghost' | sed "s#$LAB#<lab>#g" | head -12
echo "== $2: fm-send.sh firstmate:fm-mate 'ahoy'  (recorded window, gone) =="
"$TREE/bin/fm-send.sh" firstmate:fm-mate 'ahoy' 2>&1 | grep -vE '^●|^WARNING|fm-gate-refuse' | sed "s#$LAB#<lab>#g"; echo "  exit=${PIPESTATUS[0]}"
echo "== $2: sibling pane firstmate:fm-mate-2 afterwards =="
tmux capture-pane -p -t '=firstmate:=fm-mate-2' | grep -v '^$' | sed 's/^/  | /'
