#!/usr/bin/env bash
# Live driver: real fm-brief.sh + fm-spawn.sh in a scratch home; fake tmux refuses, so no agent/worktree starts.
set -u
SRC=$1; EV=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-rr.XXXXXX"); trap 'rm -rf "$W"' EXIT
setup() { # name
  H=$W/$1/home; P=$W/$1/proj; FB=$W/$1/fb; C=$W/$1/code
  mkdir -p $P $FB $C; $SRC/bin/fm-lab-home.sh create $H >/dev/null
  git -C $P init -q
  printf '#!/bin/sh\nexit 1\n' > $FB/tmux; chmod +x $FB/tmux
  cp -R $SRC/bin $C/bin
}
spawn() { # id
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$H FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "PATH=$FB:$PATH" \
   $C/bin/fm-spawn.sh $1 $P claude --mode no-mistakes --yolo off --branch-prefix fix/ 2>&1
}
mutate() {
  sed -i 's/^Ship branch: \$branch$/Ship branch: $branch\nScaffold revision marker: current/' $C/bin/fm-dod-lib.sh
  grep -q 'Scaffold revision marker' $C/bin/fm-dod-lib.sh || echo "MUTATION FAILED"
}
fill() { c=$(cat $1); c=${c//'{TASK}'/'Work the existing external PR'}; c=${c//'{FIRSTMATE_SPEC}'/'Work the existing external PR branch'}; printf '%s\n' "$c" > $1; }

echo "=== S1 stale DoD re-rendered"
setup s1; id=s1t
FM_HOME=$H $C/bin/fm-brief.sh $id proj --mode no-mistakes --branch-prefix fix/ >/dev/null 2>&1 || echo scaffold-fail
fill $H/data/$id/brief.md; mutate
spawn $id | tail -5
echo "--- marker in launch-brief:"; grep -n "Scaffold revision marker\|external PR" $H/data/$id/launch-brief.md
echo "--- marker in brief.md (expect none):"; grep -c "Scaffold revision marker" $H/data/$id/brief.md
cp $H/data/$id/launch-brief.md $EV/s1-launch-brief.md

echo "=== S2 edited DoD kept with warning"
setup s2; id=s2t
FM_HOME=$H $C/bin/fm-brief.sh $id proj --mode no-mistakes --branch-prefix fix/ >/dev/null 2>&1
fill $H/data/$id/brief.md
printf '%s\n' "Push to the existing PR's branch; do not open a new PR." >> $H/data/$id/brief.md
mutate
spawn $id > $EV/s2-spawn-output.txt; grep -i "warn\|edited" $EV/s2-spawn-output.txt
echo "--- launch-brief:"; grep -n "existing PR's branch\|Scaffold revision marker" $H/data/$id/launch-brief.md
cp $H/data/$id/launch-brief.md $EV/s2-launch-brief.md

echo "=== S3 unfilled placeholders refused"
setup s3; id=s3t
FM_HOME=$H $C/bin/fm-brief.sh $id proj --mode no-mistakes --branch-prefix fix/ >/dev/null 2>&1
spawn $id; echo "exit=$?"; ls $H/data/$id
echo "=== S3b half filled (spec left) refused"
c=$(cat $H/data/$id/brief.md); printf '%s\n' "${c//'{TASK}'/Intent}" > $H/data/$id/brief.md
spawn $id | head -5
