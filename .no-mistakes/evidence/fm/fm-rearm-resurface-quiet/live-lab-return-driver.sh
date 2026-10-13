#!/usr/bin/env bash
# Live driver: real bin/fm-afk-return.sh against the lab home after a real deferred recovery.
# Usage: live-lab-return-driver.sh <worktree> <lab-home>
set -u
cd "$1" || exit 1
LAB=$2
. "$(dirname "$0")/lab-env.sh"
S=$LAB/state
say() { printf '\n=== %s\n' "$*"; }
watcher_pid() { cat "$S/.watch.lock/pid" 2>/dev/null; }
ARM=
stop_cycle() { local w; w=$(watcher_pid); [ -z "$w" ] || { kill -TERM "$w" 2>/dev/null; while kill -0 "$w" 2>/dev/null; do sleep 0.2; done; }; [ -z "$ARM" ] || wait "$ARM" 2>/dev/null; ARM=; }
arm() { local out=$1; shift; lab bin/fm-watch-arm.sh "$@" > "$out" 2>&1 & ARM=$!; }
settle() { local i=0; while [ "$i" -lt $(( $2 * 5 )) ]; do kill -0 "$ARM" 2>/dev/null || break; sleep 0.2; i=$((i+1)); done
  if kill -0 "$ARM" 2>/dev/null; then echo "arm: STILL LIVE after ${2}s (no wake)"; else wait "$ARM"; echo "arm: EXITED rc=$? (wake)"; ARM=; fi; echo "--- arm output:"; cat "$1"; }
state() { echo "--- marker: $(cat "$S/.watcher-down" 2>/dev/null) | queue rows: $(grep -c . "$S/.wake-queue" 2>/dev/null) | note: $(cat "$S/.watcher-recovered" 2>/dev/null | tr "\n" " ")"; }
ret() { echo '$ fm-afk-contract.sh enter'; lab bin/fm-afk-contract.sh enter >/dev/null 2>&1; echo "rc=$?"
  echo '$ fm-afk-return.sh begin'; lab bin/fm-afk-return.sh begin > "$LAB/return.out" 2>&1; echo "rc=$?"; cat "$LAB/return.out"; }
ack() { local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*$/\1/p' "$LAB/return.out" | tail -1)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \(.*\)$/\1/p' "$LAB/return.out" | tail -1)
  [ -n "$gen" ] || { echo "(no ack required)"; return; }
  echo "\$ fm-wake-drain.sh --ack-through $seq --recovery-generation $gen"; lab bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "rc=$?"; }

cp .tasks.toml "$LAB/.tasks.toml"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

say "R1 deferred recovery, then the captain returns before any drain: must not read as a gap"
stop_cycle; arm "$LAB/r1-arm.out" --restart; settle "$LAB/r1-arm.out" 10; state
ret; state; ack; state

say "R2 adversarial: an older deferred note stands, then a recovery WITH queued work is undrained at return: must read as a GAP"
stop_cycle; arm "$LAB/r2a-arm.out" --restart; settle "$LAB/r2a-arm.out" 10; state
stop_cycle
lab bash -c '. bin/fm-wake-lib.sh; fm_wake_append check lab-probe-2 "check: lab-probe-2 queued while the watcher was down"'
arm "$LAB/r2b-arm.out" --restart; settle "$LAB/r2b-arm.out" 20; state
ret; state; ack; state
stop_cycle; echo "lab watcher pid at end: $(watcher_pid)"
