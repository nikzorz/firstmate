#!/usr/bin/env bash
# Live driver: a real deferred recovery standing at away return. Usage: <worktree> <lab-home>
set -u
cd "$1" || exit 1
LAB=$2
. "$(dirname "$0")/lab-env.sh"
S=$LAB/state
state() { echo "--- marker: $(cat "$S/.watcher-down" 2>/dev/null) | queue rows: $(grep -c . "$S/.wake-queue" 2>/dev/null) | note: $(cat "$S/.watcher-recovered" 2>/dev/null | tr "\n" " ")"; }
wpid() { cat "$S/.watch.lock/pid" 2>/dev/null; }
echo "=== R1 a live watcher goes down, comes back with nothing queued (deferred), captain returns before any drain"
lab bin/fm-watch-arm.sh > "$LAB/r1-seed.out" 2>&1 & A1=$!
sleep 6; cat "$LAB/r1-seed.out"; state
w=$(wpid); kill -TERM "$w"; while kill -0 "$w" 2>/dev/null; do sleep 0.2; done; wait "$A1" 2>/dev/null; state
lab bin/fm-watch-arm.sh --restart > "$LAB/r1-arm.out" 2>&1 & A2=$!
sleep 10; kill -0 "$A2" 2>/dev/null && echo "arm: STILL LIVE (no wake)"; cat "$LAB/r1-arm.out"; state
echo '$ fm-afk-contract.sh enter'; lab bin/fm-afk-contract.sh enter >/dev/null 2>&1; echo "rc=$?"
echo '$ fm-afk-return.sh begin'; lab bin/fm-afk-return.sh begin > "$LAB/return.out" 2>&1; echo "rc=$?"; cat "$LAB/return.out"; state
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \(.*\)$/\1/p' "$LAB/return.out" | tail -1)
[ -z "$gen" ] || { echo "\$ fm-wake-drain.sh --ack-through 0 --recovery-generation $gen"; lab bin/fm-wake-drain.sh --ack-through 0 --recovery-generation "$gen"; echo "rc=$?"; }
state
w=$(wpid); [ -z "$w" ] || { kill -TERM "$w"; while kill -0 "$w" 2>/dev/null; do sleep 0.2; done; }; wait "$A2" 2>/dev/null
echo "lab watcher pid at end: $(wpid)"
