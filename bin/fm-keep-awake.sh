#!/usr/bin/env bash
# fm-keep-awake.sh - hold a Windows SYSTEM-awake request for exactly as long as
# away mode is armed, and release it on stand-down.
#
# Why this exists: on a Windows laptop using Modern Standby (S0 Low Power Idle),
# going idle freezes the whole WSL VM - every crewmate, the watcher, and the
# away-mode daemon stop mid-run. A busy WSL VM does not itself ask Windows to
# stay awake, so unattended away-mode work silently stalls for hours. This asks
# Windows, for the duration of away mode only, to keep the SYSTEM awake.
#
# The DISPLAY is deliberately never touched: the request omits
# ES_DISPLAY_REQUIRED, so the screen keeps sleeping on its normal timeout. No
# persistent system setting is changed either - this is a runtime request that
# Windows drops the moment the requesting process exits, so nothing has to be
# undone and nothing can be left behind in the captain's power plan.
#
# Mechanism: a detached holder process runs powershell.exe, which calls
# kernel32!SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED) and then
# idles, re-asserting periodically. Killing the Linux-side holder terminates the
# Windows process (verified WSL interop behavior), and Windows then resumes
# normal power management on its own. That makes the request SELF-RELEASING: it
# cannot outlive its reason even if nothing ever calls `stop`.
#
# PowerToys Awake is not used. It is single-instance, and on a machine where the
# PowerToys runner already owns the Awake module a second standalone instance
# exits immediately; its --pid binding also takes a WINDOWS pid, which the
# away-mode daemon's Linux pid is not. See docs/verification/supervision.md.
#
# OPT-IN, and off unless the local gitignored config/keep-awake file exists.
# This is a Windows/WSL-specific remedy; macOS and non-WSL Linux homes are
# unaffected because the platform gate refuses before anything is launched.
#
# FAIL OPEN, always. Away mode is a supervision path, and a supervision path
# that refuses to start is worse than one that lets the machine sleep, so every
# unavailable condition here reports one line and returns non-zero WITHOUT
# affecting the caller's lifecycle. bin/fm-afk-launch.sh ignores this script's
# exit status by contract.
#
# Usage:
#   fm-keep-awake.sh start   Arm the request (idempotent: an already-live holder
#                            is left alone). Silent and successful when the
#                            opt-in file is absent. Bounded: it waits at most
#                            FM_KEEP_AWAKE_READY_SECS for the holder to confirm
#                            Windows accepted the request, then returns either
#                            way.
#   fm-keep-awake.sh stop    Release the request. Tolerant of an already-gone
#                            holder, a missing record, and a stale record.
#   fm-keep-awake.sh status  Print "held pid=<holder> child=<windows-holder>",
#                            "off", or "unavailable: <reason>".
#   fm-keep-awake.sh hold    INTERNAL. The detached holder loop itself; `start`
#                            spawns it. Running it by hand blocks the terminal.
#
# The holder exits - releasing the request - as soon as any of these is true:
# the Windows process died, state/.afk is gone (away mode stood down), or the
# away-mode daemon has not been alive for FM_KEEP_AWAKE_GRACE_SECS. The grace
# window exists because `start-native` prepares lifecycle state BEFORE the
# harness starts the daemon, so a brand-new holder must tolerate a not-yet-live
# daemon without releasing.
#
# Env knobs and test seams:
#   FM_KEEP_AWAKE_PWSH        override the resolved powershell.exe path
#   FM_KEEP_AWAKE_INTEROP     override the WSL-interop probe path
#   FM_KEEP_AWAKE_READY_SECS  confirmation bound for `start` (default 5)
#   FM_KEEP_AWAKE_POLL_SECS   holder poll interval (default 10)
#   FM_KEEP_AWAKE_GRACE_SECS  daemon-absence tolerance (default 180)
set -u

FM_KEEP_AWAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_KEEP_AWAKE_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_KEEP_AWAKE_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_KEEP_AWAKE_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/keep-awake"
FM_KEEP_AWAKE_RECORD="$FM_KEEP_AWAKE_STATE/.afk-keep-awake"
FM_KEEP_AWAKE_OUT="$FM_KEEP_AWAKE_STATE/.afk-keep-awake.out"
FM_KEEP_AWAKE_MARKER=FM_AWAKE_HELD

# fm-afk-start.sh owns the identity-backed daemon-lock liveness helpers and is
# sourceable (BASH_SOURCE guard). It sets `set -eu`; this script is best-effort
# by design, so errexit goes back off immediately.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_KEEP_AWAKE_DIR/fm-afk-start.sh"
set +e

fm_keepawake_log() { printf 'fm-keep-awake: %s\n' "$*" >&2; }

fm_keepawake_usage() {
  sed -n '2,65p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Opt-in gate. Absent file means off. A present file may be empty or hold "auto";
# "off" is an explicit local kill switch. Anything else is a config error that
# stays off rather than guessing.
fm_keepawake_enabled() {
  local value
  [ -f "$FM_KEEP_AWAKE_CONFIG" ] || return 1
  value=$(grep -v '^[[:space:]]*#' "$FM_KEEP_AWAKE_CONFIG" 2>/dev/null \
    | tr -d '[:space:]' | head -c 32)
  case "$value" in
    ''|auto|on) return 0 ;;
    off) return 1 ;;
    *)
      fm_keepawake_log "ignoring unknown config/keep-awake value '$value'; keep-awake stays off"
      return 1
      ;;
  esac
}

# WSL interop must be registered, or launching a Windows binary from here is
# meaningless. This is also the macOS / non-WSL-Linux refusal.
fm_keepawake_interop_ready() {
  local probe
  if [ -n "${FM_KEEP_AWAKE_INTEROP:-}" ]; then
    [ -e "$FM_KEEP_AWAKE_INTEROP" ]
    return
  fi
  for probe in /proc/sys/fs/binfmt_misc/WSLInterop /proc/sys/fs/binfmt_misc/WSLInterop-late; do
    [ -e "$probe" ] && return 0
  done
  return 1
}

fm_keepawake_resolve_pwsh() {
  local candidate
  if [ -n "${FM_KEEP_AWAKE_PWSH:-}" ]; then
    [ -x "$FM_KEEP_AWAKE_PWSH" ] || return 1
    printf '%s' "$FM_KEEP_AWAKE_PWSH"
    return 0
  fi
  candidate=$(command -v powershell.exe 2>/dev/null)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$candidate" ] || return 1
  printf '%s' "$candidate"
}

# The Windows side. ES_CONTINUOUS|ES_SYSTEM_REQUIRED is 0x80000001 = 2147483649;
# ES_DISPLAY_REQUIRED (0x2) is deliberately absent so the screen still sleeps.
# SetThreadExecutionState returns the previous state and 0 only on failure, so a
# zero return is the one real "Windows refused" signal.
fm_keepawake_ps_script() {
  cat <<'FM_KEEP_AWAKE_PS'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class FmAwake{[DllImport("kernel32.dll",SetLastError=true)]public static extern uint SetThreadExecutionState(uint esFlags);}'
$flags = [uint32]2147483649
if ([FmAwake]::SetThreadExecutionState($flags) -eq 0) { exit 1 }
[Console]::Out.WriteLine('FM_AWAKE_HELD')
[Console]::Out.Flush()
while ($true) { [void][FmAwake]::SetThreadExecutionState($flags); Start-Sleep -Seconds 30 }
FM_KEEP_AWAKE_PS
}

fm_keepawake_record_write() {  # <holder-pid> <holder-identity> <child-pid> <child-identity>
  local pending
  mkdir -p "$FM_KEEP_AWAKE_STATE" || return 1
  pending=$(mktemp "$FM_KEEP_AWAKE_STATE/.afk-keep-awake.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_KEEP_AWAKE_RECORD" || { rm -f "$pending"; return 1; }
}

# Read the record into FM_KEEP_AWAKE_REC_*. Returns 1 with no record, 2 when the
# record is malformed (which is treated as "nothing trustworthy to signal").
fm_keepawake_record_read() {
  FM_KEEP_AWAKE_REC_PID=""; FM_KEEP_AWAKE_REC_IDENT=""
  FM_KEEP_AWAKE_REC_CHILD=""; FM_KEEP_AWAKE_REC_CHILD_IDENT=""
  [ -f "$FM_KEEP_AWAKE_RECORD" ] || return 1
  IFS=$'\t' read -r FM_KEEP_AWAKE_REC_PID FM_KEEP_AWAKE_REC_IDENT \
    FM_KEEP_AWAKE_REC_CHILD FM_KEEP_AWAKE_REC_CHILD_IDENT \
    < "$FM_KEEP_AWAKE_RECORD" || true
  [ -n "$FM_KEEP_AWAKE_REC_PID" ] && [ -n "$FM_KEEP_AWAKE_REC_IDENT" ] || return 2
}

# Signal only a pid whose recorded identity still matches, so a reused pid can
# never make this script kill an unrelated process.
fm_keepawake_signal_recorded() {  # <pid> <identity> <signal>
  local pid=$1 identity=$2 signal=$3 current
  [ -n "$pid" ] && [ -n "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ] || return 1
  kill "-$signal" "$pid" 2>/dev/null
}

# Sleep in one-second slices. bash only runs a trap once the foreground command
# returns, so a single long sleep would make the holder ignore TERM for a whole
# poll interval and delay the release.
fm_keepawake_sleep() {  # <seconds>
  local remaining=$1
  while [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
  done
}

fm_keepawake_holder_alive() {
  fm_keepawake_record_read || return 1
  fm_pid_alive "$FM_KEEP_AWAKE_REC_PID" || return 1
  [ "$(fm_pid_identity "$FM_KEEP_AWAKE_REC_PID" 2>/dev/null)" = "$FM_KEEP_AWAKE_REC_IDENT" ]
}

# ---------------------------------------------------------------------------
# The holder: owns the Windows process for the whole armed window.
# ---------------------------------------------------------------------------
fm_keepawake_hold() {
  local pwsh child child_identity identity waited last_seen now poll grace ready

  fm_keepawake_enabled || return 1
  fm_keepawake_interop_ready || return 1
  pwsh=$(fm_keepawake_resolve_pwsh) || return 1
  identity=$(fm_pid_identity "$$" 2>/dev/null) || return 1
  mkdir -p "$FM_KEEP_AWAKE_STATE" || return 1

  poll=${FM_KEEP_AWAKE_POLL_SECS:-10}
  grace=${FM_KEEP_AWAKE_GRACE_SECS:-180}
  ready=${FM_KEEP_AWAKE_READY_SECS:-5}

  : > "$FM_KEEP_AWAKE_OUT" || return 1
  "$pwsh" -NoProfile -NonInteractive -Command "$(fm_keepawake_ps_script)" \
    > "$FM_KEEP_AWAKE_OUT" 2>&1 < /dev/null &
  child=$!

  # Release on ANY exit path, including a signal, so the request never outlives
  # this process. The record is only removed when it is still ours.
  # shellcheck disable=SC2064
  trap "fm_keepawake_hold_cleanup $child" EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  # Record the exact Windows-holder pid immediately, before the readiness wait,
  # so even a killed holder leaves a reconcilable id behind. Its identity is
  # still unknown here: the interop shim rewrites its own command line when it
  # execs the Windows binary, so an identity captured now would never match
  # afterwards. Until the handshake below replaces it, only this holder's own
  # exit trap can reap the child.
  fm_keepawake_record_write "$$" "$identity" "$child" "" || return 1

  waited=0
  while [ "$waited" -lt "$((ready * 10))" ]; do
    grep -q "$FM_KEEP_AWAKE_MARKER" "$FM_KEEP_AWAKE_OUT" 2>/dev/null && break
    fm_pid_alive "$child" || return 1
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -q "$FM_KEEP_AWAKE_MARKER" "$FM_KEEP_AWAKE_OUT" 2>/dev/null || return 1

  child_identity=$(fm_pid_identity "$child" 2>/dev/null || true)
  fm_keepawake_record_write "$$" "$identity" "$child" "$child_identity" || return 1

  last_seen=$(date '+%s')
  while :; do
    fm_keepawake_sleep "$poll"
    fm_pid_alive "$child" || return 0
    [ -f "$FM_KEEP_AWAKE_STATE/.afk" ] || return 0
    if daemon_lock_held_by_live_daemon; then
      last_seen=$(date '+%s')
      continue
    fi
    now=$(date '+%s')
    [ "$((now - last_seen))" -lt "$grace" ] || return 0
  done
}

fm_keepawake_hold_cleanup() {  # <child-pid>
  local child=$1
  kill -TERM "$child" 2>/dev/null
  # Only clean up files this holder still owns; a later holder may already have
  # replaced the record, and its output file must survive.
  if fm_keepawake_record_read && [ "$FM_KEEP_AWAKE_REC_PID" = "$$" ]; then
    rm -f "$FM_KEEP_AWAKE_RECORD" "$FM_KEEP_AWAKE_OUT"
  fi
}

# ---------------------------------------------------------------------------
# Lifecycle entry points used by bin/fm-afk-launch.sh.
# ---------------------------------------------------------------------------
fm_keepawake_start() {
  local pwsh waited ready
  fm_keepawake_enabled || return 0
  if ! fm_keepawake_interop_ready; then
    fm_keepawake_log "keep-awake is unavailable here (no Windows/WSL interop); away mode continues without it"
    return 1
  fi
  if ! pwsh=$(fm_keepawake_resolve_pwsh); then
    fm_keepawake_log "keep-awake is unavailable here (powershell.exe not found); away mode continues without it"
    return 1
  fi
  fm_keepawake_holder_alive && return 0
  fm_keepawake_stop_quiet

  # A reaped holder is a SAFE failure - the Windows process dies with it and the
  # machine simply sleeps as it does today - so a detached background start is
  # acceptable here, unlike the daemon's own tracked-terminal requirement.
  if command -v setsid >/dev/null 2>&1; then
    setsid "${BASH_SOURCE[0]}" hold >/dev/null 2>&1 < /dev/null &
  else
    "${BASH_SOURCE[0]}" hold >/dev/null 2>&1 < /dev/null &
  fi
  disown 2>/dev/null

  ready=${FM_KEEP_AWAKE_READY_SECS:-5}
  waited=0
  while [ "$waited" -lt "$(((ready + 1) * 10))" ]; do
    # A complete record - including the post-exec child identity - is the
    # holder's own signal that Windows accepted the request.
    if fm_keepawake_holder_alive && [ -n "$FM_KEEP_AWAKE_REC_CHILD_IDENT" ] \
      && grep -q "$FM_KEEP_AWAKE_MARKER" "$FM_KEEP_AWAKE_OUT" 2>/dev/null; then
      fm_keepawake_log "holding a system-awake request while away mode is armed (display unaffected)"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  fm_keepawake_log "could not confirm the system-awake request; away mode continues without it"
  fm_keepawake_stop_quiet
  return 1
}

fm_keepawake_stop_quiet() {
  local waited=0
  fm_keepawake_record_read || { rm -f "$FM_KEEP_AWAKE_RECORD" "$FM_KEEP_AWAKE_OUT"; return 0; }
  fm_keepawake_signal_recorded "$FM_KEEP_AWAKE_REC_PID" "$FM_KEEP_AWAKE_REC_IDENT" TERM
  while [ "$waited" -lt 50 ] && fm_pid_alive "$FM_KEEP_AWAKE_REC_PID"; do
    sleep 0.1
    waited=$((waited + 1))
  done
  fm_keepawake_signal_recorded "$FM_KEEP_AWAKE_REC_PID" "$FM_KEEP_AWAKE_REC_IDENT" KILL
  # The holder's own trap normally takes the Windows process with it. Signalling
  # the recorded child too covers a holder that was killed outright and orphaned
  # it; the identity check keeps a reused pid out of range.
  fm_keepawake_signal_recorded "$FM_KEEP_AWAKE_REC_CHILD" "$FM_KEEP_AWAKE_REC_CHILD_IDENT" TERM
  rm -f "$FM_KEEP_AWAKE_RECORD" "$FM_KEEP_AWAKE_OUT"
  return 0
}

fm_keepawake_status() {
  if fm_keepawake_holder_alive; then
    printf 'held pid=%s child=%s\n' "$FM_KEEP_AWAKE_REC_PID" "$FM_KEEP_AWAKE_REC_CHILD"
    return 0
  fi
  if ! fm_keepawake_enabled; then
    printf 'off\n'
    return 0
  fi
  if ! fm_keepawake_interop_ready; then
    printf 'unavailable: no Windows/WSL interop\n'
    return 0
  fi
  if ! fm_keepawake_resolve_pwsh >/dev/null; then
    printf 'unavailable: powershell.exe not found\n'
    return 0
  fi
  printf 'off\n'
}

fm_keepawake_main() {
  case "${1:-status}" in
    start) fm_keepawake_start ;;
    stop) fm_keepawake_stop_quiet ;;
    status) fm_keepawake_status ;;
    hold) fm_keepawake_hold ;;
    -h|--help|help) fm_keepawake_usage ;;
    *) fm_keepawake_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_keepawake_main "$@"
fi
