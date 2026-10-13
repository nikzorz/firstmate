#!/usr/bin/env bash
# Drives fm_backend_target_exists (base and target commit) against a real tmux
# server on a private socket. Usage: drive-probe.sh <target-root> <base-root>
set -u
NEW=$1 OLD=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-lab-probe-$$"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe-shim.XXXXXX")
trap '"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1; rm -rf "$SHIM"' EXIT
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
unset TMUX
export PATH="$SHIM:$PATH"

echo "tmux version: $(tmux -V)"
tmux new-session -d -s firstmate -n main 'sleep 600'
tmux new-window -d -t firstmate -n fm-auth-fix 'sleep 600'
tmux new-window -d -t firstmate -n fm-auth-fix-2 'sleep 600'
tmux new-session -d -s other -n fm-k7 'sleep 600'
live_pane=$(tmux list-panes -t '=firstmate:=fm-auth-fix-2' -F '#{pane_id}')
gone_pane=$(tmux list-panes -t '=firstmate:=fm-auth-fix' -F '#{pane_id}')
main_index=$(tmux list-windows -t '=firstmate' -F '#{window_index} #{window_name}' | awk '$2=="main"{print $1}')
echo "--- before kill:"; tmux list-windows -a -F '#{session_name}:#{window_name} #{pane_id}'

probe() {  # <root> <target>
  ( . "$1/bin/fm-backend.sh"; fm_backend_target_exists tmux "$2" ) && echo alive || echo dead
}
row() {  # <expected> <target> <what>
  local old new verdict
  old=$(probe "$OLD" "$2"); new=$(probe "$NEW" "$2")
  [ "$new" = "$1" ] && verdict=PASS || { verdict=FAIL; RC=1; }
  printf '%-4s  %-28s  base=%-5s  target=%-5s  expect=%-5s  %s\n' "$verdict" "$2" "$old" "$new" "$1" "$3"
}
RC=0
echo "--- all endpoints live:"
row alive "firstmate:fm-auth-fix"      "live window"
row alive "firstmate:fm-auth-fix-2"    "live window (longer sibling)"
row alive "firstmate:$main_index"      "live window by index"
row alive "firstmate:fm-auth-fix.0"    "live window.pane"
row alive "$live_pane"                 "live pane id"
row alive "other:fm-k7"                "live window in second session"

tmux kill-window -t '=firstmate:=fm-auth-fix'
tmux kill-session -t '=other'
echo "--- after kill-window firstmate:fm-auth-fix and kill-session other (server still running):"
tmux list-windows -a -F '#{session_name}:#{window_name} #{pane_id}'
echo "--- raw tmux exit codes on the gone window (the reported defect):"
tmux display-message -p -t firstmate:fm-never '#{pane_id}' >/dev/null 2>&1; echo "display-message -t firstmate:fm-never -> exit $?"
tmux display-message -p -t other:fm-k7 '#{pane_id}' >/dev/null 2>&1; echo "display-message -t other:fm-k7 (gone session) -> exit $?"
tmux has-session -t firstmate:fm-never >/dev/null 2>&1; echo "has-session -t firstmate:fm-never -> exit $?"
tmux has-session -t firstmate:fm-auth-fix >/dev/null 2>&1; echo "has-session -t firstmate:fm-auth-fix (prefix of live fm-auth-fix-2) -> exit $?"
tmux has-session -t '=firstmate:=fm-auth-fix' >/dev/null 2>&1; echo "has-session -t =firstmate:=fm-auth-fix -> exit $?"

echo "--- gone endpoints on the running server:"
row dead  "firstmate:fm-auth-fix"      "gone window, live prefix sibling fm-auth-fix-2"
row dead  "firstmate:fm-never"         "window never created"
row dead  "firstmate:fm-auth"          "gone name, prefix of a live window"
row dead  "firstmate:fm-auth-fix.0"    "window.pane of gone window"
row dead  "other:fm-k7"                "gone session"
row dead  "first:main"                 "gone session, prefix of live session"
row dead  "$gone_pane"                 "pane id of killed window"
row dead  "firstmate:99"               "window index that does not exist"
row dead  "firstmate:fm-*"             "glob must not match a live window"
echo "--- survivors still alive:"
row alive "firstmate:fm-auth-fix-2"    "live sibling"
row alive "firstmate:main"             "live window"
row alive "$live_pane"                 "live pane id"
tmux has-session -t '=firstmate' && echo "server + session firstmate still running: yes"
exit $RC
