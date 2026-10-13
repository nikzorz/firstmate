#!/usr/bin/env bash
# Live driver: real bin/fm-watch-arm.sh, bin/fm-watch.sh and bin/fm-wake-drain.sh
# against a disposable marked lab home. Usage: live-lab-driver.sh <worktree> <lab-home>
set -u
cd "$1" || exit 1
LAB=$2
. "$(dirname "$0")/lab-env.sh"
S=$LAB/state
say() { printf '\n=== %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; }
watcher_pid() { cat "$S/.watch.lock/pid" 2>/dev/null; }
ARM=
stop_cycle() {  # stop only this lab's own watcher and arm, by recorded pid
  local w; w=$(watcher_pid)
  [ -z "$w" ] || { kill -TERM "$w" 2>/dev/null; while kill -0 "$w" 2>/dev/null; do sleep 0.2; done; }
  [ -z "$ARM" ] || { wait "$ARM" 2>/dev/null; }
  ARM=
}
arm() {  # <out> [args]
  local out=$1; shift
  lab bin/fm-watch-arm.sh "$@" > "$out" 2>&1 &
  ARM=$!
}
settle() {  # <out> <seconds>: wait until arm exits or seconds pass
  local i=0
  while [ "$i" -lt $(( $2 * 5 )) ]; do kill -0 "$ARM" 2>/dev/null || break; sleep 0.2; i=$((i+1)); done
  if kill -0 "$ARM" 2>/dev/null; then echo "arm pid $ARM: STILL LIVE after ${2}s (no wake, no turn)"; else wait "$ARM"; echo "arm pid $ARM: EXITED rc=$? (a wake: one session turn)"; ARM=; fi
  echo "--- arm output:"; cat "$1"
}
state() {
  echo "--- marker: $(cat "$S/.watcher-down" 2>/dev/null)"
  echo "--- queue rows: $(grep -c . "$S/.wake-queue" 2>/dev/null || echo 0)"
  if [ -f "$S/.watcher-recovered" ]; then echo "--- .watcher-recovered: $(tr '\n' ' ' < "$S/.watcher-recovered")"; else echo "--- .watcher-recovered: (absent)"; fi
}
drain() {  # [env...]
  show "fm-wake-drain.sh $*"
  lab env "$@" bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$LAB/drain.err"; echo "rc=$?"
  echo "--- stdout:"; cat "$LAB/drain.out"; echo "--- stderr:"; cat "$LAB/drain.err"
}
ack() {
  local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*$/\1/p' "$LAB/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \(.*\)$/\1/p' "$LAB/drain.err")
  [ -n "$gen" ] || { echo "(no ack required)"; return; }
  show "fm-wake-drain.sh --ack-through $seq --recovery-generation $gen"
  lab bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "rc=$?"
}
append() { lab bash -c '. bin/fm-wake-lib.sh; fm_wake_append "$1" "$2" "$3"' _ "$@"; }

say "S0 baseline: a live watcher cycle in the lab home"
ARM=$(cat "$LAB/.first-arm-pid" 2>/dev/null); echo "watcher pid $(watcher_pid)"; state

say "S1 watcher goes down and is re-armed with NOTHING queued"
stop_cycle; sleep 1; state
arm "$LAB/s1-arm.out" --restart; settle "$LAB/s1-arm.out" 12; state
grep -rh "deferred to the next drain" "$S" 2>/dev/null | tail -n 2

say "S2 recovery-loop guard: repeated empty-queue re-arms of the same announced generation"
for n in 1 2 3; do stop_cycle; sleep 1; arm "$LAB/s2-arm$n.out" --restart; settle "$LAB/s2-arm$n.out" 8; state; done

say "S3 away-daemon style drain (FM_WAKE_DRAIN_HOLD_ANNOUNCEMENT=1) must leave the note"
drain FM_WAKE_DRAIN_HOLD_ANNOUNCEMENT=1; state

say "S4 next session drain carries the announcement once, then never again"
drain X=1; state; ack; drain X=1; state
echo "watcher still live: $(kill -0 "$(watcher_pid)" 2>/dev/null && echo yes || echo no)"

say "S5 watcher goes down, a wake is queued, re-arm: one turn, for the wake"
stop_cycle; sleep 1
append check lab-probe 'check: lab-probe queued while the watcher was down'
state
arm "$LAB/s5-arm.out" --restart; settle "$LAB/s5-arm.out" 20; state
drain X=1; ack; state
say "S5b the successor after that turn stays quiet (no second turn, no recursion)"
arm "$LAB/s5b-arm.out"; settle "$LAB/s5b-arm.out" 8; state

say "S6 adversarial: deferral cannot be recorded (note path is a directory) -> must fall back to the wake"
stop_cycle; sleep 1; rm -f "$S/.watcher-recovered"; mkdir "$S/.watcher-recovered"; state
arm "$LAB/s6-arm.out" --restart; settle "$LAB/s6-arm.out" 20; state
rmdir "$S/.watcher-recovered"
stop_cycle
echo; echo "lab watcher pid at end: $(watcher_pid || true)"
