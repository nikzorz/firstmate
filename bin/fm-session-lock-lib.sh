#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process belong to that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# SAME SESSION, NEW PID. A harness can move an executing session into a NEW
# process while the process that recorded the lock is still alive: Claude Code's
# background and forked sessions run as a descendant of the session that spawned
# them (session process -> background pty host -> forked session), and a resumed
# session behaves the same way. Pid equality alone reads that as a competing
# session, so the home's own session is refused its own lock. Descent from the
# recorded owner is the evidence that separates the two cases: a genuinely
# different session is launched independently - from another terminal, another
# login, another tool - and therefore never descends from the recorded owner,
# so it is still refused exactly as before.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'

# A harness that execs a VERSION-NAMED binary reports that version as its comm
# instead of the harness name: Claude Code's background and forked sessions run
# <prefix>/share/claude/versions/<version>, so their comm is a bare "2.1.220"
# and only the daemon further up the tree still reports "claude". Without this
# rescue the ancestry walk skips the real session process and resolves to that
# shared daemon, which outlives every session it hosts - a lock naming it would
# never be recognized as stale. Match the harness segment of the EXECUTABLE PATH
# only, never the whole argument vector, so a shell whose arguments merely
# mention a harness (a tool call sourcing a snapshot under ~/.claude, this
# repo's own fm-claude-*.sh scripts) is never mistaken for the session process.
FM_HARNESS_VERSION_COMM_RE='^[0-9]+(\.[0-9]+)+$'
FM_HARNESS_EXEC_PATH_RE='(^|/)(claude|codex|opencode|grok|kimi|pi)(/|$)'

# Bounded ancestry hops for the lineage walk. Deep enough for the longest real
# chain - recorded owner, session host, forked session, tool shell, wrapper
# script, caller - and short enough that the walk cannot reach an unrelated
# common ancestor far up a login or multiplexer tree.
FM_SESSION_LOCK_MAX_ANCESTRY_HOPS=16

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Version-named harness binary: a bare version comm plus a harness segment
    # in the executable path.
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_VERSION_COMM_RE" \
      && printf '%s' "${args%% *}" | grep -qE "$FM_HARNESS_EXEC_PATH_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

# True when pid $1 is a process ancestor of the current process, within
# FM_SESSION_LOCK_MAX_ANCESTRY_HOPS. One ps snapshot feeds the whole walk, so a
# reparent part-way through cannot produce a half-old, half-new chain.
fm_pid_is_ancestor() {
  local target=$1
  case "$target" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps -eo pid=,ppid= 2>/dev/null | awk \
    -v start="$$" -v target="$target" -v max="$FM_SESSION_LOCK_MAX_ANCESTRY_HOPS" '
      { parent[$1 + 0] = $2 + 0 }
      END {
        pid = start + 0
        for (hop = 0; hop < max; hop++) {
          if (!(pid in parent)) exit 1
          pid = parent[pid]
          if (pid <= 1) exit 1
          if (pid == target + 0) exit 0
        }
        exit 1
      }
    '
}

# True when the session that recorded pid $1 in a session lock is the session
# this process belongs to, under a new pid: the recorded owner is still a live
# harness AND it is a process ancestor of this process. See SAME SESSION, NEW
# PID in this file's header for why descent is the discriminator.
#
# The liveness conjunct is not redundant with descent: it also refuses a
# recycled pid, so a dead owner's number reassigned to an unrelated ancestor
# (a login shell, a multiplexer) can never be read as the owning session.
fm_session_lock_owner_launched_self() {
  local owner=$1
  fm_harness_pid_alive "$owner" || return 1
  fm_pid_is_ancestor "$owner"
}

# True when state dir $1 holds a session lock owned by this process's session:
# either the recorded pid IS this session's harness ancestor, or the recorded
# owner launched this session under a new pid. A missing lock, a lock held by
# a genuinely different live harness, or an ancestry that cannot be resolved
# all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ] && return 0
  fm_session_lock_owner_launched_self "$lock_pid"
}
