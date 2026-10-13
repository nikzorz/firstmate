#!/usr/bin/env bash
# Drives fm-send.sh with an explicit, unrecorded session:window target that is
# gone on a still-running private-socket tmux server.
# Usage: drive-send.sh <target-root> <base-root>
set -u
NEW=$1 OLD=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-lab-send-$$"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-shim.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap '"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1; rm -rf "$SHIM" "$LAB"' EXIT
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export PATH="$SHIM:$PATH"
"$NEW/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
tmux new-session -d -s firstmate -n main 'sleep 600'
tmux new-window -d -t firstmate -n fm-loose 'cat'
tmux new-window -d -t firstmate -n fm-loose-2 'cat'
send() {
  for pair in "base:$OLD" "target:$NEW"; do
    out=$("${pair#*:}/bin/fm-send.sh" firstmate:fm-loose "hello-from-${pair%%:*}" 2>&1); rc=$?
    printf '  %-6s fm-send.sh firstmate:fm-loose <text> -> exit %s\n' "${pair%%:*}" "$rc"
    printf '%s\n' "$out" | grep -v -e 'fm-gate-refuse' -e 'watcher' | sed 's/^/         | /' | cut -c1-260
  done
}
echo "tmux version: $(tmux -V)"
echo "=== 1. explicit target live"
send
tmux kill-window -t '=firstmate:=fm-loose'
echo "=== 2. explicit target killed; prefix sibling fm-loose-2 and the server still live"
echo "windows now: $(tmux list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"
send
sleep 0.5
echo "sibling fm-loose-2 pane content (text that landed in the wrong window):"
tmux capture-pane -p -t '=firstmate:=fm-loose-2' | grep -v '^$' | sed 's/^/         | /'
