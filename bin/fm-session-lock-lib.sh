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
#
# ONE OWNER AT A TIME. Descent admits a second answer of "yes" for one home: the
# recorded owner is still a live process, so it keeps passing pid equality while
# the session that descends from it passes on descent, and both would supervise
# the home. So descent is a title to CLAIM, never a standing second ownership -
# a caller that acts on it re-points the lock at itself through fm-lock.sh, and
# the recorded owner then reads the home as another session's on its next check.
# The deepest session wins because it is the one executing turns; the process it
# descends from is either an inert host or a superseded session.

# Known harness command names; extend when a new adapter is verified. This is
# the ONE list: every harness pattern in this file is derived from it, so a new
# adapter reaches both the command-name match and the version-named-binary
# rescue below in a single edit. "pi" carries whole-name anchors because it is
# short enough to occur inside an unrelated word; the other names are
# distinctive enough to match as a substring of an argument vector.
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
# The names come from FM_HARNESS_RE with its whole-name anchors traded for
# path-segment anchors, so the two patterns cannot drift apart.
FM_HARNESS_VERSION_COMM_RE='^[0-9]+(\.[0-9]+)+$'
_fm_harness_names=${FM_HARNESS_RE//^/}
_fm_harness_names=${_fm_harness_names//$/}
FM_HARNESS_EXEC_PATH_RE="(^|/)($_fm_harness_names)(/|\$)"
unset _fm_harness_names

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
# reparent part-way through cannot produce a half-old, half-new chain. One
# keyword per -o flag: BSD ps reads everything after a keyword's "=" as that
# column's header, so a comma-joined "-o pid=,ppid=" asks macOS for a single
# pid column and the parent of every process would read as 0.
fm_pid_is_ancestor() {
  local target=$1
  case "$target" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps -A -o pid= -o ppid= 2>/dev/null | awk \
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
# The liveness conjunct is not redundant with descent: it demands that the
# recorded number still name a live process that LOOKS like a harness, which is
# what keeps a recycled pid landing on an ordinary ancestor (a login shell, a
# multiplexer) from being read as the owning session. It is a shape test, not
# proof of identity: fm_harness_pid_alive matches FM_HARNESS_RE against the
# command name AND the whole argument vector, so an ancestor whose arguments
# merely mention a harness would satisfy it.
fm_session_lock_owner_launched_self() {
  local owner=$1
  fm_harness_pid_alive "$owner" || return 1
  fm_pid_is_ancestor "$owner"
}

# True when pid $1 is a live harness belonging to a DIFFERENT session than this
# process's - the one case a claim on an existing lock must refuse. The inverse
# of the rule above rather than its negation: a dead or non-harness owner is
# neither this session nor a competitor, it is stale. Composed here so a caller
# reads both facts from ONE liveness probe and this file stays the single owner
# of the rule.
fm_session_lock_owner_is_other_session() {
  local owner=$1
  fm_harness_pid_alive "$owner" || return 1
  ! fm_pid_is_ancestor "$owner"
}

# Print how the session lock in state dir $1 stands relative to THIS process,
# as exactly one word. A caller that only arms or refuses can read the yes/no
# predicate below, but a caller that must leave the home with a single owner
# needs the REASON ownership was granted, because only descent has a second
# live session still answering yes - see ONE OWNER AT A TIME in this file's
# header. Naming it here keeps that distinction from being re-derived, and
# drifting, at each call site.
#
#   self    - the recorded pid IS this session's harness ancestor; nothing to
#             collapse, because no other process can answer yes.
#   descent - a live recorded owner launched this session under a new pid; this
#             session's title is good but shared, so a caller acting on it must
#             claim the lock before it supervises.
#   other   - a live harness of a genuinely different session holds the lock.
#   stale   - the recorded pid no longer names a live harness.
#   none    - no lock, a malformed lock, or an ancestry this process cannot
#             resolve, which is uncertainty rather than any claim to the home.
fm_session_lock_class() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) echo none; return 0 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || { echo none; return 0; }
  if [ "$my_pid" = "$lock_pid" ]; then echo self; return 0; fi
  if fm_session_lock_owner_launched_self "$lock_pid"; then echo descent; return 0; fi
  if fm_session_lock_owner_is_other_session "$lock_pid"; then echo other; return 0; fi
  echo stale
}

# True when state dir $1 holds a session lock this process's session may act on:
# either the recorded pid IS this session's harness ancestor, or the recorded
# owner launched this session under a new pid. A missing lock, a lock held by
# a genuinely different live harness, or an ancestry that cannot be resolved
# all fail closed. This answers "may I act", not "am I alone": a caller that
# arms supervision must reach the single-owner state fm_session_lock_class
# names "self" first.
fm_session_lock_owned_by_self() {
  case "$(fm_session_lock_class "$1")" in
    self|descent) return 0 ;;
  esac
  return 1
}
