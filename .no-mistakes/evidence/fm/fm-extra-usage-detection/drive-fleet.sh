#!/usr/bin/env bash
# Drives bin/fm-extra-usage.sh (check/scan/steer/arm/disarm) with the REAL fm-send.sh
# against an isolated tmux server (own -L socket). Panes redraw a footer file so the
# notice can be placed/removed; one scenario uses a real idle claude pane.
set -u
WT=${WT:?}; SOCK=fm-eu-drive-$$; W=$(mktemp -d /tmp/fm-eu-drive.XXXXXX)
REAL=$(command -v tmux); mkdir -p $W/shim
printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL" "$SOCK" > $W/shim/tmux; chmod +x $W/shim/tmux
export PATH="$W/shim:$PATH"
trap 'tmux kill-server 2>/dev/null; rm -rf "$W"' EXIT
RULE='────────────────────────────────────────────────────────────'
HINTS='  ⏵⏵ bypass permissions on · 1 shell'
frame() { printf '%s\n' '● Working on the step.' '' "$RULE" '❯ ' "$RULE" "$@"; }
say() { printf '\n$ %s\n' "$*"; }
eu() { say "fm-extra-usage.sh $*"; FM_GATE_REFUSE_BYPASS=1 FM_HOME=$H "$WT/bin/fm-extra-usage.sh" "$@"; echo "[exit=$?]"; }
pane() { # id file
  NW=$((NW+1)); tmux new-window -d -t "fm:$NW" -n "fm-$1" "stty -echo; while :; do printf '\033[H\033[2J'; cat '$2'; sleep 0.3; done"
}
meta() { printf 'window=fm:fm-%s\nkind=%s\nharness=%s\nbackend=tmux\n' "$1" "$3" "$2" > $H/state/$1.meta; }
H=$W/home; mkdir -p $H/state
tmux new-session -d -s fm -n base -x 200 -y 40 sleep 99999

echo "=== S2: inert with extra usage off (real idle claude pane) ==="
NW=1; tmux new-window -d -t fm:1 -n fm-real -c /home/nik/firstmate claude
meta real claude ship
for i in $(seq 1 45); do tmux capture-pane -p -t fm:fm-real | grep -q '^❯' && break; sleep 1; done; sleep 2
echo "--- real claude pane (last rows) ---"; tmux capture-pane -p -t fm:fm-real -S -40 | grep '[^[:space:]]' | tail -6
eu scan; eu check; eu steer
echo "inbox after refused steer: $(ls $H/state/real.inbox 2>/dev/null | wc -l) entries; episode record: $([ -e $H/state/.extra-usage-steered ] && echo present || echo absent)"
tmux kill-window -t fm:fm-real; rm -f $H/state/real.meta

echo; echo "=== S3/S4: flip detected, fleet stopped once, secondmate/dead excluded ==="
frame "$HINTS" > $W/a.txt
frame "$HINTS   You're close to your usage credit limit" "   You've used 91% of your usage credits · resets Oct 1" > $W/b.txt
printf 'codex> idle\n' > $W/c.txt
frame "$HINTS    Now using usage credits" > $W/sm.txt
pane a $W/a.txt; pane b $W/b.txt; pane c $W/c.txt; pane sm $W/sm.txt
meta a claude ship; meta b claude ship; meta c codex ship; meta sm claude secondmate; meta gone claude ship
sed -i 's/window=fm:fm-gone/window=fm:fm-gone-nowhere/' $H/state/gone.meta
sleep 1
echo "--- pane b as tmux shows it ---"; tmux capture-pane -p -t fm:fm-b | grep '[^[:space:]]'
eu scan; eu check; eu steer
echo "--- durable steer records written by real fm-send ---"
for id in a b c sm gone; do n=$(ls $H/state/$id.inbox 2>/dev/null | grep -vc '^$'); echo "$id.inbox: $(find $H/state/$id.inbox -type f 2>/dev/null | wc -l) files"; done
f=$(find $H/state/b.inbox -type f 2>/dev/null | head -1); [ -n "$f" ] && { echo "--- b's inbox record ---"; cat "$f"; echo; }
echo "--- episode record ---"; cat $H/state/.extra-usage-steered
eu check; eu steer

echo; echo "=== S5: uncertain reads never end the episode ==="
printf '%s\n' '● Running the tests.' '' ' Do you want to proceed?' ' ❯ 1. Yes' '   2. No' '' ' Esc to cancel' > $W/b.txt
cp $W/b.txt $W/sm.txt; cp $W/b.txt $W/a.txt; sleep 1
echo "--- pane b now a dialog ---"; tmux capture-pane -p -t fm:fm-b | grep '[^[:space:]]'
eu check; echo "episode record: $([ -e $H/state/.extra-usage-steered ] && echo present || echo absent)"
tmux kill-window -t fm:fm-a; tmux kill-window -t fm:fm-b; sleep 0.5
eu check; echo "episode record after panes vanished: $([ -e $H/state/.extra-usage-steered ] && echo present || echo absent)"

echo; echo "=== S6: notice still up keeps check silent; proven clear composer ends episode; next flip wakes ==="
frame "$HINTS    Now using usage credits" > $W/a.txt; pane a $W/a.txt; sleep 1
eu check; echo "episode record: $([ -e $H/state/.extra-usage-steered ] && echo present || echo absent)"
frame "$HINTS" > $W/a.txt; sleep 1
eu check; echo "episode record after proven notice-free composer: $([ -e $H/state/.extra-usage-steered ] && echo present || echo absent)"
frame "$HINTS    Now using usage credits" > $W/a.txt; sleep 1
eu check

echo; echo "=== S7: arm / armed shim / disarm ==="
eu arm; ls $H/state | grep extra-usage
say "state/extra-usage.check.sh (as the watcher runs it)"; FM_GATE_REFUSE_BYPASS=1 $H/state/extra-usage.check.sh; echo "[exit=$?]"
eu disarm; ls -a $H/state | grep extra-usage || echo "(no extra-usage files left)"
