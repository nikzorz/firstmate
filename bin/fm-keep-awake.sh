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
#                            way. That bound is a REPORTING bound only. A holder
#                            that has not confirmed yet is left running
#                            untouched, because a slow cold start may already
#                            have been accepted and the holder releases itself
#                            either way; only a holder that never came up at all
#                            is reported unavailable.
#   fm-keep-awake.sh stop    Release the request, the holder and the Windows
#                            process it owns. Tolerant of an already-gone
#                            holder, a missing record, and a stale record.
#   fm-keep-awake.sh status  Print "held pid=<holder> child=<windows-holder>",
#                            "leaked child=<windows-holder>" when a Windows
#                            holder outlived its holder and is awaiting release,
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
# A holder killed outright (SIGKILL, an OOM kill, VM teardown) never runs its
# release, so the Windows process it owned is left LEAKED: still holding, with
# nothing left to exit and drop the request. The record therefore carries the
# Windows-side pid AND a birth stamp from the moment it was spawned, before any
# of that can happen, and it is kept until that process is confirmed released.
# `start`, `stop`, and the crash reconcile in bin/fm-afk-launch.sh all release
# by that exact recorded id, so a leak is always reaped by the next lifecycle
# step rather than surviving until a reboot.
#
# Releasing a leak is deliberately NOT gated by the opt-in, while arming still
# is. Turning keep-awake off is exactly when a leftover would otherwise be
# stranded, because it is also when nobody is looking for one. That release is a
# purely local operation on a recorded pid: it needs no interop and no
# powershell.exe, and with no record it does nothing and says nothing.
#
# Env knobs and test seams:
#   FM_KEEP_AWAKE_PWSH        override the resolved powershell.exe path
#   FM_KEEP_AWAKE_INTEROP     override the WSL-interop probe path
#   FM_KEEP_AWAKE_READY_SECS  confirmation bound for `start` (default 5); a
#                             timeout changes only what is reported, never
#                             whether a live holder keeps holding
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

# The holder's own view of the Windows process it owns. Kept as state rather
# than trap arguments so the EXIT trap always signals the identity that is
# currently recorded, and never a bare pid.
FM_KEEP_AWAKE_CHILD_PID=""
FM_KEEP_AWAKE_CHILD_IDENT=""
FM_KEEP_AWAKE_CHILD_BIRTH=""
FM_KEEP_AWAKE_HOLD_IDENT=""

# fm-afk-start.sh owns the identity-backed daemon-lock liveness helpers and is
# sourceable (BASH_SOURCE guard). It sets `set -eu`; this script is best-effort
# by design, so errexit goes back off immediately.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_KEEP_AWAKE_DIR/fm-afk-start.sh"
set +e

fm_keepawake_log() { printf 'fm-keep-awake: %s\n' "$*" >&2; }

fm_keepawake_usage() {
  sed -n '2,90p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

fm_keepawake_record_write() {  # <holder-pid> <holder-identity> <child-pid> <child-identity> <child-birth>
  local pending
  mkdir -p "$FM_KEEP_AWAKE_STATE" || return 1
  pending=$(mktemp "$FM_KEEP_AWAKE_STATE/.afk-keep-awake.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$pending" \
    || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_KEEP_AWAKE_RECORD" || { rm -f "$pending"; return 1; }
}

# Read the record into FM_KEEP_AWAKE_REC_*. Returns 1 with no record, 2 when the
# record is malformed (which is treated as "nothing trustworthy to signal").
fm_keepawake_record_read() {
  FM_KEEP_AWAKE_REC_PID=""; FM_KEEP_AWAKE_REC_IDENT=""
  FM_KEEP_AWAKE_REC_CHILD=""; FM_KEEP_AWAKE_REC_CHILD_IDENT=""
  FM_KEEP_AWAKE_REC_CHILD_BIRTH=""
  [ -f "$FM_KEEP_AWAKE_RECORD" ] || return 1
  # Split field by field, never with `IFS=$'\t' read`: a tab counts as IFS
  # whitespace, so that form collapses the empty child-identity field an
  # unconfirmed record carries and silently shifts every field after it.
  {
    IFS= read -r FM_KEEP_AWAKE_REC_PID
    IFS= read -r FM_KEEP_AWAKE_REC_IDENT
    IFS= read -r FM_KEEP_AWAKE_REC_CHILD
    IFS= read -r FM_KEEP_AWAKE_REC_CHILD_IDENT
    IFS= read -r FM_KEEP_AWAKE_REC_CHILD_BIRTH
  } < <(awk -F '\t' 'NR == 1 { for (i = 1; i <= 5; i++) print $i }' \
    "$FM_KEEP_AWAKE_RECORD" 2>/dev/null)
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

# The exec-stable half of a pid identity. fm_pid_identity pairs a birth stamp
# (the /proc starttime on Linux, the ps lstart date elsewhere) with the command
# line; only the command line changes when the interop shim execs the Windows
# binary. A pid cannot be recycled without the replacement being born later, so
# the birth stamp alone is a sound anti-reuse guard, and it is the only one
# available for a Windows process that has not announced readiness yet.
fm_keepawake_pid_birth() {  # <pid>
  local identity stamp rest
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  case "$identity" in
    linux-starttime=*)
      stamp=${identity%% *}
      ;;
    *)
      # "Www Mmm dd HH:MM:SS YYYY <command>" under the pinned LC_ALL=C locale.
      read -r stamp rest <<< "$identity"
      stamp="lstart=$stamp $(printf '%s' "$rest" | cut -d' ' -f1-4)"
      ;;
  esac
  [ -n "$stamp" ] || return 1
  printf '%s\n' "$stamp"
}

# Is the recorded Windows process still alive and still the one we spawned?
# Either guard proves it: the full identity once readiness made it stable, or
# the birth stamp captured at spawn, which survives the interop exec.
fm_keepawake_child_present() {  # <pid> <identity> <birth>
  local pid=$1 identity=$2 birth=$3 current
  [ -n "$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
    [ "$current" = "$identity" ] && return 0
  fi
  [ -n "$birth" ] || return 1
  current=$(fm_keepawake_pid_birth "$pid") || return 1
  [ "$current" = "$birth" ]
}

fm_keepawake_signal_child() {  # <pid> <identity> <birth> <signal>
  fm_keepawake_child_present "$1" "$2" "$3" || return 1
  kill "-$4" "$1" 2>/dev/null
}

# Release the recorded Windows process and report whether it is actually gone.
# Returns 0 when there is nothing of ours left at that pid, 1 when it survived
# everything - the one case whose record must be kept so a later lifecycle step
# can try again instead of losing the leak.
fm_keepawake_release_child() {  # <pid> <identity> <birth> <term-deciseconds>
  local pid=$1 identity=$2 birth=$3 budget=$4 waited=0
  if ! fm_keepawake_child_present "$pid" "$identity" "$birth"; then
    # Nothing of ours is there - unless no guard was ever captured for a pid
    # that is still alive. Signalling that would break the anti-reuse rule and
    # reporting success would strand it, so say plainly that it is unreleased
    # and let the record keep pointing at it.
    if [ -n "$pid" ] && [ -z "$identity" ] && [ -z "$birth" ] && fm_pid_alive "$pid"; then
      return 1
    fi
    return 0
  fi
  fm_keepawake_signal_child "$pid" "$identity" "$birth" TERM
  while [ "$waited" -lt "$budget" ]; do
    fm_keepawake_child_present "$pid" "$identity" "$birth" || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  fm_keepawake_signal_child "$pid" "$identity" "$birth" KILL
  waited=0
  while [ "$waited" -lt 20 ]; do
    fm_keepawake_child_present "$pid" "$identity" "$birth" || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# Sleep as a background child and `wait` for it. bash only runs a trap once the
# foreground command returns, so a plain `sleep` would make the holder ignore
# TERM for a whole poll interval and delay the release, while `wait` is
# interrupted the moment a trapped signal arrives. The abandoned sleep child of
# an interrupted wait exits by itself within the same interval.
fm_keepawake_sleep() {  # <seconds>
  local remaining=$1 sleeper
  [ "$remaining" -gt 0 ] || return 0
  sleep "$remaining" &
  sleeper=$!
  wait "$sleeper" 2>/dev/null
}

fm_keepawake_marker_seen() {
  grep -q "$FM_KEEP_AWAKE_MARKER" "$FM_KEEP_AWAKE_OUT" 2>/dev/null
}

# Fill in the birth stamp while it is still missing. Kept retryable rather than
# captured once: a holder with neither a birth stamp nor an identity cannot
# prove what it owns, so it could neither release its own Windows process nor
# leave one anybody else is allowed to touch.
fm_keepawake_capture_child_birth() {
  local birth
  [ -z "$FM_KEEP_AWAKE_CHILD_BIRTH" ] || return 0
  [ -n "$FM_KEEP_AWAKE_CHILD_PID" ] || return 1
  birth=$(fm_keepawake_pid_birth "$FM_KEEP_AWAKE_CHILD_PID") || return 1
  [ -n "$birth" ] || return 1
  FM_KEEP_AWAKE_CHILD_BIRTH=$birth
}

# Upgrade the record written at spawn time with whatever ownership proof has
# become available since. The identity cannot be captured at spawn: the interop
# shim rewrites its own command line when it execs the Windows binary, so an
# earlier capture would never match afterwards and the trap below would refuse
# to reap the very process it owns. The readiness marker is printed by the
# Windows side, so seeing it proves that exec is done and the identity is stable.
fm_keepawake_confirm_child() {
  local child_identity="" birth_before=$FM_KEEP_AWAKE_CHILD_BIRTH changed=0
  [ -n "$FM_KEEP_AWAKE_CHILD_PID" ] || return 1
  fm_keepawake_capture_child_birth || true
  [ "$FM_KEEP_AWAKE_CHILD_BIRTH" = "$birth_before" ] || changed=1
  if [ -z "$FM_KEEP_AWAKE_CHILD_IDENT" ] && fm_keepawake_marker_seen; then
    child_identity=$(fm_pid_identity "$FM_KEEP_AWAKE_CHILD_PID" 2>/dev/null) || child_identity=""
    if [ -n "$child_identity" ]; then
      FM_KEEP_AWAKE_CHILD_IDENT=$child_identity
      changed=1
    fi
  fi
  [ "$changed" -eq 1 ] || return 1
  fm_keepawake_record_write "$$" "$FM_KEEP_AWAKE_HOLD_IDENT" \
    "$FM_KEEP_AWAKE_CHILD_PID" "$FM_KEEP_AWAKE_CHILD_IDENT" "$FM_KEEP_AWAKE_CHILD_BIRTH"
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
  local pwsh identity waited last_seen now poll grace ready

  fm_keepawake_enabled || return 1
  fm_keepawake_interop_ready || return 1
  pwsh=$(fm_keepawake_resolve_pwsh) || return 1
  identity=$(fm_pid_identity "$$" 2>/dev/null) || return 1
  mkdir -p "$FM_KEEP_AWAKE_STATE" || return 1

  poll=${FM_KEEP_AWAKE_POLL_SECS:-10}
  grace=${FM_KEEP_AWAKE_GRACE_SECS:-180}
  ready=${FM_KEEP_AWAKE_READY_SECS:-5}
  FM_KEEP_AWAKE_HOLD_IDENT=$identity

  : > "$FM_KEEP_AWAKE_OUT" || return 1
  "$pwsh" -NoProfile -NonInteractive -Command "$(fm_keepawake_ps_script)" \
    > "$FM_KEEP_AWAKE_OUT" 2>&1 < /dev/null &
  FM_KEEP_AWAKE_CHILD_PID=$!

  # Release on ANY exit path, including a signal, so the request never outlives
  # this process. The record is only removed when it is still ours.
  trap fm_keepawake_hold_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  # Record the exact Windows-holder pid and birth stamp immediately, before the
  # readiness wait, so a holder killed outright still leaves behind an id that
  # anyone can safely reap. The full identity is not stable yet and is filled in
  # by fm_keepawake_confirm_child once readiness proves the interop exec is done.
  fm_keepawake_capture_child_birth || true
  fm_keepawake_record_write "$$" "$identity" "$FM_KEEP_AWAKE_CHILD_PID" "" \
    "$FM_KEEP_AWAKE_CHILD_BIRTH" || return 1

  waited=0
  while [ "$waited" -lt "$((ready * 10))" ]; do
    fm_keepawake_marker_seen && break
    if ! fm_pid_alive "$FM_KEEP_AWAKE_CHILD_PID"; then
      # The Windows process is gone, so nothing is held and nothing can be -
      # a marker it printed on its way out does not make a dead request live.
      FM_KEEP_AWAKE_CHILD_PID=""
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # A readiness timeout means UNCONFIRMED, never FAILED. WSL interop spawn plus
  # .NET startup plus the in-box C# compiler can easily outrun any budget on a
  # loaded machine - exactly the condition this feature exists for - and by then
  # Windows may already have accepted the request. So the holder keeps running
  # and confirms late; only the Windows process actually dying ends the hold.
  fm_keepawake_confirm_child

  last_seen=$(date '+%s')
  while :; do
    fm_keepawake_sleep "$poll"
    if ! fm_pid_alive "$FM_KEEP_AWAKE_CHILD_PID"; then
      FM_KEEP_AWAKE_CHILD_PID=""
      return 0
    fi
    fm_keepawake_confirm_child
    [ -f "$FM_KEEP_AWAKE_STATE/.afk" ] || return 0
    if daemon_lock_held_by_live_daemon; then
      last_seen=$(date '+%s')
      continue
    fi
    now=$(date '+%s')
    [ "$((now - last_seen))" -lt "$grace" ] || return 0
  done
}

fm_keepawake_hold_cleanup() {
  # Last chance to learn what this holder owns, for the window between spawning
  # the Windows process and the first poll that would have retried the capture.
  fm_keepawake_capture_child_birth || true
  # A short release budget on purpose: `stop` gives this holder 5s to die before
  # escalating, and being SIGKILLed mid-cleanup is exactly what orphans a child.
  fm_keepawake_release_child "$FM_KEEP_AWAKE_CHILD_PID" "$FM_KEEP_AWAKE_CHILD_IDENT" \
    "$FM_KEEP_AWAKE_CHILD_BIRTH" 10 || return 0
  # Only clean up files this holder still owns; a later holder may already have
  # replaced the record, and its output file must survive. Returning above keeps
  # the record whenever the Windows process outlived this release, so the leak
  # stays reapable by the next arm, stand-down, or reconcile.
  if fm_keepawake_record_read && [ "$FM_KEEP_AWAKE_REC_PID" = "$$" ]; then
    rm -f "$FM_KEEP_AWAKE_RECORD" "$FM_KEEP_AWAKE_OUT"
  fi
}

# ---------------------------------------------------------------------------
# Lifecycle entry points used by bin/fm-afk-launch.sh.
# ---------------------------------------------------------------------------
# Release a recorded Windows process whose holder is gone. Reaping is cleanup of
# something this feature itself created, so it runs ahead of the opt-in gate and
# without touching the Windows side at all: with no record it does nothing, says
# nothing, and cannot fail in a way that reaches away mode.
fm_keepawake_reap_leak() {
  [ -f "$FM_KEEP_AWAKE_RECORD" ] || return 0
  fm_keepawake_holder_alive && return 0
  fm_keepawake_stop_quiet
}

fm_keepawake_start() {
  local pwsh waited ready
  fm_keepawake_reap_leak
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
    # The marker the Windows process prints is its own report that Windows
    # accepted the request; a live recorded holder is what still owns it, and
    # that process still has to BE there for the request to exist at all.
    if fm_keepawake_holder_alive && fm_keepawake_marker_seen \
      && fm_keepawake_child_present "$FM_KEEP_AWAKE_REC_CHILD" \
        "$FM_KEEP_AWAKE_REC_CHILD_IDENT" "$FM_KEEP_AWAKE_REC_CHILD_BIRTH"; then
      fm_keepawake_log "holding a system-awake request while away mode is armed (display unaffected)"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Unconfirmed is not failed. Killing a holder that may already be holding, on
  # nothing better than a stopwatch, would cost keep-awake for the whole
  # unattended window with nothing left to re-arm it, so a live holder is left
  # strictly alone: it either confirms late or releases itself when away mode
  # ends, and the machine stays awake in the meantime.
  if fm_keepawake_holder_alive; then
    fm_keepawake_log "the system-awake request is not confirmed yet; leaving its holder running (it releases itself when away mode ends)"
    return 0
  fi
  fm_keepawake_log "keep-awake is unavailable here (its holder did not come up); away mode continues without it"
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
  # The holder's own trap normally takes the Windows process with it. Releasing
  # the recorded child too is what reaps a holder that was killed outright and
  # leaked it, including one that never confirmed and so has only a birth stamp.
  # The record survives a child that would not go, because dropping it is what
  # would turn a reapable leak into an untraceable one.
  if fm_keepawake_release_child "$FM_KEEP_AWAKE_REC_CHILD" \
    "$FM_KEEP_AWAKE_REC_CHILD_IDENT" "$FM_KEEP_AWAKE_REC_CHILD_BIRTH" 50; then
    rm -f "$FM_KEEP_AWAKE_RECORD" "$FM_KEEP_AWAKE_OUT"
  fi
  return 0
}

fm_keepawake_status() {
  if fm_keepawake_record_read \
    && fm_keepawake_child_present "$FM_KEEP_AWAKE_REC_CHILD" \
      "$FM_KEEP_AWAKE_REC_CHILD_IDENT" "$FM_KEEP_AWAKE_REC_CHILD_BIRTH"; then
    if fm_keepawake_holder_alive; then
      printf 'held pid=%s child=%s\n' "$FM_KEEP_AWAKE_REC_PID" "$FM_KEEP_AWAKE_REC_CHILD"
    else
      # Still holding the request, but its owner is gone, so nothing will drop
      # it on its own. Named so the operator can see why the machine is awake.
      printf 'leaked child=%s\n' "$FM_KEEP_AWAKE_REC_CHILD"
    fi
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
