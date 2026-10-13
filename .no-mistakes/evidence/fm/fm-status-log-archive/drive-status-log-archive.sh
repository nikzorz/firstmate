#!/usr/bin/env bash
# Live driver: runs the real bin/fm-teardown.sh against a disposable marked lab
# home, a real treehouse pool slot, and a real tmux window on the lab's private
# socket. Run from inside a pane of that socket so $TMUX names it.
set -u
ROOT=$1 LAB=$2 BASE_ROOT=$3
export FM_HOME=$LAB TREEHOUSE_ROOT=$LAB/pool
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TD=$ROOT/bin/fm-teardown.sh
say() { printf '\n===== %s =====\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
P=$LAB/projects/demo

git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$P" 2>/dev/null
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
git -C "$P" branch -M main; git -C "$P" push -q origin main; git -C "$P" remote set-head origin main
touch "$LAB/state/.last-watcher-beat"

# launch <id> <landed|unlanded>: what a spawn leaves behind for a local-only ship task.
launch() {
  local id=$1 landed=$2 wt
  wt=$(cd "$P" && treehouse get --lease --lease-holder "$id" -b "fm/$id" 2>/dev/null) || { echo "treehouse get failed"; exit 1; }
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "work for $id $RANDOM"
  [ "$landed" = landed ] && git -C "$P" merge -q --ff-only "fm/$id"
  tmux new-window -d -t primary -n "fm-$id" -c "$wt"
  printf '%s\n' "window=primary:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$P" \
    kind=ship mode=local-only "spawn_gen=lab-$id-$RANDOM" > "$LAB/state/$id.meta"
  WT=$wt
}
facts() {  # <id>
  local id=$1
  printf -- '-- state records for %s: ' "$id"; (cd "$LAB/state" && ls -1 | grep "^$id\." | tr '\n' ' '); echo
  printf -- '-- tmux window fm-%s: ' "$id"; tmux list-windows -t primary -F '#W' | grep -qx "fm-$id" && echo alive || echo gone
  printf -- '-- branch fm/%s: ' "$id"; git -C "$P" rev-parse -q --verify "refs/heads/fm/$id" >/dev/null && echo present || echo deleted
  printf -- '-- data/%s: ' "$id"; ls -la "$LAB/data/$id" 2>&1 | sed 1d | tr '\n' ';'; echo
}

say "S1 cleanup archives the status log into a data/<id>/ it creates"
launch arch-a1 landed
printf '%s\n' 'working [at=1760000100]: setup complete' 'paused [at=1760000200]: waiting on validation round' 'done [at=1760000300]: ready in branch' > "$LAB/state/arch-a1.status"
cp "$LAB/state/arch-a1.status" "$LAB/expect.s1"
facts arch-a1
show "$TD" arch-a1
facts arch-a1
show cat "$LAB/data/arch-a1/status.log"
show cmp "$LAB/expect.s1" "$LAB/data/arch-a1/status.log"

say "S2 relaunch of the same id: second cleanup appends, never overwrites"
launch arch-a1 landed
printf '%s\n' 'working [at=1760000400]: relaunched' 'done [at=1760000500]: relaunch landed' > "$LAB/state/arch-a1.status"
cat "$LAB/expect.s1" "$LAB/state/arch-a1.status" > "$LAB/expect.s2"
show "$TD" arch-a1
facts arch-a1
show cat "$LAB/data/arch-a1/status.log"
show cmp "$LAB/expect.s2" "$LAB/data/arch-a1/status.log"

say "S3 task with no status file cleans up as before, no archive made"
launch nostat-b1 landed
facts nostat-b1
show "$TD" nostat-b1
facts nostat-b1

say "S4 unusable archive destination (a directory): refuse before anything is cleared, then retry"
launch block-c1 landed
printf '%s\n' 'working [at=1760000600]: setup complete' 'done [at=1760000700]: ready in branch' > "$LAB/state/block-c1.status"
cp "$LAB/state/block-c1.status" "$LAB/expect.s4"
: > "$LAB/state/block-c1.turn-ended"
mkdir -p "$LAB/data/block-c1/status.log"
show "$TD" block-c1
facts block-c1
printf -- '-- worktree still checked out on: %s\n' "$(git -C "$WT" branch --show-current)"
show cmp "$LAB/expect.s4" "$LAB/state/block-c1.status"
echo "-- operator clears the destination and reruns"
rmdir "$LAB/data/block-c1/status.log"
show "$TD" block-c1
facts block-c1
show cmp "$LAB/expect.s4" "$LAB/data/block-c1/status.log"

say "S5 read-only existing archive: refuse with the reason, then retry"
launch ro-d1 landed
printf '%s\n' 'done [at=1760000800]: ready in branch' > "$LAB/state/ro-d1.status"
mkdir -p "$LAB/data/ro-d1"; printf '%s\n' 'working [at=1760000750]: first launch' > "$LAB/data/ro-d1/status.log"; chmod a-w "$LAB/data/ro-d1/status.log"
show "$TD" ro-d1
facts ro-d1
chmod u+w "$LAB/data/ro-d1/status.log"
show "$TD" ro-d1
facts ro-d1
show cat "$LAB/data/ro-d1/status.log"

say "S6 landed-work refusal unchanged: unlanded work, change vs base commit script"
launch unl-e1 unlanded
printf '%s\n' 'working [at=1760000900]: in progress' > "$LAB/state/unl-e1.status"
echo "-- change under test:"
"$TD" unl-e1 > "$LAB/s6.new.out" 2> "$LAB/s6.new.err"; echo "[exit $?]" | tee "$LAB/s6.new.rc"
cat "$LAB/s6.new.err"
facts unl-e1
show cat "$LAB/state/unl-e1.status"
echo "-- base commit script, same task:"
"$BASE_ROOT/bin/fm-teardown.sh" unl-e1 > "$LAB/s6.base.out" 2> "$LAB/s6.base.err"; echo "[exit $?]" | tee "$LAB/s6.base.rc"
show diff "$LAB/s6.base.err" "$LAB/s6.new.err"
show diff "$LAB/s6.base.out" "$LAB/s6.new.out"
show diff "$LAB/s6.base.rc" "$LAB/s6.new.rc"
echo "-- --force then discards the work and still archives the log:"
show "$TD" unl-e1 --force
facts unl-e1
show cat "$LAB/data/unl-e1/status.log"
say "driver finished"
