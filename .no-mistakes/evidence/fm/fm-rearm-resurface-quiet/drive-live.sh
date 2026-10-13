#!/usr/bin/env bash
# Live drive of the real watcher (bin/fm-watch-arm.sh, bin/fm-watch.sh) and the
# real drain (bin/fm-wake-drain.sh) in a disposable lab home. No fake binaries.
# Usage: drive-live.sh <bin-dir> <label>
set -u
BIN=$1
LABEL=$2

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
STATE="$LAB/state"
PIDS=()

lab() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@"
}

say() { printf '\n== %s\n' "$*"; }
show() { printf '   %s\n' "$*"; }
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }

ARM_PID=
arm() {  # <out-file> [args...]
  local out=$1 i=0
  shift
  lab "$BIN/fm-watch-arm.sh" "$@" > "$out" 2>&1 &
  ARM_PID=$!
  PIDS+=("$ARM_PID")
  while [ "$i" -lt 400 ]; do
    grep -q '^watcher: ' "$out" 2>/dev/null && return 0
    alive "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
}

# Stop only the processes this script started, by pid.
stop_cycle() {
  local wpid
  wpid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  if [ -n "$wpid" ] && alive "$wpid"; then
    if grep -qa "$LAB" "/proc/$wpid/environ" 2>/dev/null; then kill -TERM "$wpid" 2>/dev/null || true; fi
  fi
  local i=0
  while [ "$i" -lt 100 ] && [ -n "$wpid" ] && alive "$wpid"; do sleep 0.1; i=$((i + 1)); done
}

observe() {  # <seconds> <out-file>: wait, then report whether the arm closed its cycle
  local secs=$1 out=$2 i=0
  while [ "$i" -lt $((secs * 10)) ] && alive "$ARM_PID"; do sleep 0.1; i=$((i + 1)); done
  if alive "$ARM_PID"; then
    show "after ${secs}s: arm pid $ARM_PID still LIVE (cycle not closed, no turn requested)"
  else
    wait "$ARM_PID" 2>/dev/null
    show "arm pid $ARM_PID EXITED rc=$? (cycle closed: the harness would take a turn)"
  fi
  show "arm output:"; sed 's/^/     | /' "$out"
}

state_view() {
  show "recovery marker: $(cat "$STATE/.watcher-down" 2>/dev/null || echo '<none>')"
  show "wake queue rows: $(awk 'NF{n++} END{print n+0}' "$STATE/.wake-queue" 2>/dev/null || echo 0)"
  if [ -e "$STATE/.watcher-recovered" ]; then
    show "deferred note state/.watcher-recovered: $(grep -c . "$STATE/.watcher-recovered") line(s): $(tr '\n' ' ' < "$STATE/.watcher-recovered")"
  else
    show "deferred note state/.watcher-recovered: <absent>"
  fi
}

drain() {  # <tag> [env...]
  local tag=$1
  shift
  lab env "$@" "$BIN/fm-wake-drain.sh" > "$LAB/$tag.out" 2> "$LAB/$tag.err"
  show "drain rc=$?"
  show "drain stdout:"; sed 's/^/     | /' "$LAB/$tag.out"
  show "drain stderr:"; sed 's/^/     | /' "$LAB/$tag.err"
  ACK_SEQ=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$LAB/$tag.out" "$LAB/$tag.err" | tail -n 1)
  ACK_GEN=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$LAB/$tag.out" "$LAB/$tag.err" | tail -n 1)
}

ack() {
  if [ -n "${ACK_SEQ:-}" ] && [ -n "${ACK_GEN:-}" ]; then
    lab "$BIN/fm-wake-drain.sh" --ack-through "$ACK_SEQ" --recovery-generation "$ACK_GEN"
    show "ack --ack-through $ACK_SEQ --recovery-generation $ACK_GEN rc=$?"
  else
    show "no acknowledgement requested"
  fi
}

append() {  # <kind> <key> <payload>
  lab bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$BIN/fm-wake-lib.sh" "$@"
  show "appended durable wake: $3"
}

cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  stop_cycle 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

echo "# live drive [$LABEL] bin=$BIN"
echo "# commit: $(git -C "$BIN" rev-parse --short HEAD 2>/dev/null || echo "$LABEL")  lab home: disposable, marked by fm-lab-home.sh"

say "S0 first arm in a fresh home, then the watcher goes down"
arm "$LAB/arm0.out"
observe 3 "$LAB/arm0.out"
stop_cycle
show "watcher stopped (downtime begins)"
state_view

say "S1 re-arm after downtime with NOTHING queued"
arm "$LAB/arm1.out"
observe 8 "$LAB/arm1.out"
state_view
show "watcher triage log tail:"; tail -n 3 "$STATE"/.watch-triage.log 2>/dev/null | sed 's/^/     | /'

if [ "${MODE:-full}" = baseline ]; then exit 0; fi

say "S1b the watcher goes down and comes back twice more, still nothing queued (recovery-loop probe)"
for n in 2 3; do
  stop_cycle
  arm "$LAB/arm1-$n.out"
  observe 6 "$LAB/arm1-$n.out"
  state_view
done

say "S2 away-daemon style drain (FM_WAKE_DRAIN_HOLD_ANNOUNCEMENT=1) must not consume the note"
drain hold FM_WAKE_DRAIN_HOLD_ANNOUNCEMENT=1
state_view

say "S3 two concurrent session drains: the announcement is printed exactly once"
lab "$BIN/fm-wake-drain.sh" > "$LAB/c1.out" 2> "$LAB/c1.err" &
c1=$!
lab "$BIN/fm-wake-drain.sh" > "$LAB/c2.out" 2> "$LAB/c2.err" &
c2=$!
wait "$c1"; wait "$c2"
show "drain A stdout:"; sed 's/^/     | /' "$LAB/c1.out"
show "drain B stdout:"; sed 's/^/     | /' "$LAB/c2.out"
show "stderr of both:"; cat "$LAB/c1.err" "$LAB/c2.err" | sed 's/^/     | /'
show "WATCHER RECOVERED lines across both drains: $(cat "$LAB/c1.out" "$LAB/c2.out" | grep -c '^WATCHER RECOVERED ')"
state_view
ACK_SEQ=$(cat "$LAB/c1.err" "$LAB/c2.err" "$LAB/c1.out" "$LAB/c2.out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' | tail -n 1)
ACK_GEN=$(cat "$LAB/c1.err" "$LAB/c2.err" "$LAB/c1.out" "$LAB/c2.out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -n 1)
ack
say "S3b a repeat drain does not announce the same recovery again"
drain repeat
state_view
show "the watcher that deferred is still live: $(alive "$ARM_PID" && echo yes || echo NO)"

say "S4 work appended while the deferring watcher is live wakes it at once (nothing is lost)"
stop_cycle
arm "$LAB/arm4.out"
observe 5 "$LAB/arm4.out"
state_view
append check inbox:live-after-deferral 'check: work that arrived after a deferred recovery'
observe 15 "$LAB/arm4.out"
state_view
drain s4
ack
state_view

say "S5 re-arm after downtime WITH a wake queued"
append check inbox:queued-during-downtime 'check: work queued while the watcher was down'
state_view
arm "$LAB/arm5.out"
observe 15 "$LAB/arm5.out"
show "wake lines printed by the arm: $(grep -c '^check: ' "$LAB/arm5.out")"
state_view
drain s5
ack
state_view

say "S6 adversarial: the deferral cannot be recorded (note path is a directory), nothing queued"
mkdir -p "$STATE/.watcher-recovered"
arm "$LAB/arm6a.out"
observe 3 "$LAB/arm6a.out"
stop_cycle
arm "$LAB/arm6.out"
observe 15 "$LAB/arm6.out"
state_view 2>/dev/null
show "note path is still a directory: $([ -d "$STATE/.watcher-recovered" ] && echo yes || echo no)"
