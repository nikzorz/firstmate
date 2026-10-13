#!/usr/bin/env bash
# Drives fm-crew-state.sh and fm-send.sh (base and target commit) at a recorded
# tmux window that is gone on a still-running private-socket server.
# Usage: drive-consumers.sh <target-root> <base-root>
set -u
NEW=$1 OLD=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-lab-consumers-$$"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-consumer-shim.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap '"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1; rm -rf "$SHIM" "$LAB"' EXIT
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export PATH="$SHIM:$PATH"
"$NEW/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/wt"
export FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1

tmux new-session -d -s firstmate -n main 'sleep 600'
tmux new-window -d -t firstmate -n fm-mate 'sleep 600'
tmux new-window -d -t firstmate -n fm-mate-2 'sleep 600'
printf 'window=firstmate:fm-mate\nworktree=%s\nkind=secondmate\nharness=claude\nhome=%s\n' "$LAB/wt" "$LAB/wt" > "$LAB/state/mate.meta"
printf 'working: charting the course\n' > "$LAB/state/mate.status"
echo "tmux version: $(tmux -V)"
echo "recorded lane: $(grep '^window=' "$LAB/state/mate.meta") kind=secondmate, last status-log line: $(cat "$LAB/state/mate.status")"

show() {
  echo "windows now: $(tmux list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"
  for pair in "base:$OLD" "target:$NEW"; do
    printf '  %-6s fm-crew-state.sh mate -> %s\n' "${pair%%:*}" "$("${pair#*:}/bin/fm-crew-state.sh" mate 2>&1 | tail -1)"
  done
  for pair in "base:$OLD" "target:$NEW"; do
    out=$("${pair#*:}/bin/fm-send.sh" firstmate:fm-mate --key Enter 2>&1); rc=$?
    printf '  %-6s fm-send.sh firstmate:fm-mate --key Enter -> exit %s %s\n' "${pair%%:*}" "$rc" "$(printf '%s' "$out" | head -c 150)"
  done
}
echo "=== 1. window live"
show
tmux kill-window -t '=firstmate:=fm-mate'
echo "=== 2. recorded window killed, prefix sibling fm-mate-2 and the server still live"
show
tmux kill-window -t '=firstmate:=fm-mate-2'
echo "=== 3. sibling killed too, session firstmate and server still live"
show
