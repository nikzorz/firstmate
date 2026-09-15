#!/usr/bin/env bash
# Shared "which processes living in this directory did nobody here start?" scan.
#
# `treehouse return` terminates every process whose working directory sits inside
# the worktree it is returning, with no regard for who started it. That is right
# for a task's own agent tree and wrong for a long-lived service that merely
# happens to be sitting there: one measured return killed the shared validation
# daemon and, with it, two other lanes' in-flight runs. The processes were never
# the returned task's children. Callers use this scan to refuse handing the return
# tool anything it is not entitled to kill.
#
# The test is provenance by construction, not by name. A task's processes inherit
# the terminal session they were launched in, whose leader lives outside the
# worktree. A service that detaches - the defining act of a daemon - calls setsid
# and becomes its own session leader from wherever it started, so its session
# leader's own working directory is inside the worktree too. So:
#
#   a process is ADOPTED when its working directory is inside the directory AND
#   its session leader's working directory is inside the directory as well.
#
# That covers the whole family at once: any detached service is caught, whatever
# it is called, and a task's own agent tree never is.
#
# Only the scanning process itself and the processes that launched it are left
# out of the answer, so a scan run from inside the directory does not accuse the
# shell doing the scanning. The exemption is that lineage and nothing wider: a
# service that happens to share a session with the scanner is still reported.
#
# ONE PLATFORM. Every fact above is read from /proc, and nothing else is guessed
# at. BSD ps reports a session as a kernel address rather than a numeric id, so
# there is no honest way to run this test off /proc, and an unverifiable guess in
# the one place that decides whether a live shared service survives is worse than
# a stated limit. Off /proc the scan says it could not run (exit 3) and the caller
# proceeds exactly as cleanup did before this guard existed, behind a warning.
# That is deliberately NOT the same as an ownership question the scan could not
# answer: a scan that ran and could not attribute a process still refuses.
#
# THREE LIMITS, stated rather than hidden, all of them cheap errors next to the
# expensive one this scan exists to make impossible - killing another lane's run.
# (a) A shared service started as an ordinary child of a crew's own terminal
# session, never detaching, is invisible to this test; no process fact separates
# it from that crew's own work. (b) A task's own deliberately detached leftover (a
# background server the crew setsid'd) is caught and refused even though killing
# it would have been fine. (c) A resident process whose session leader has already
# exited is unattributable, so it refuses: the double-forked daemon has that shape
# (fork, setsid, fork again, middle process exits), and so, far more ordinarily,
# does a lane's own leftover orphaned when its window died. (b) and (c) are both
# resolved the same way, by ending the named process and running cleanup again.
#
# Exit codes: 0 when at least one process was found that this test convicts or
# cannot attribute (those processes are the printed lines), 1 when the directory
# is clear, 2 when a resident process's ownership could not be established, 3 when
# this platform cannot run the scan at all.

# fm_adopted_scan_supported: 0 when this platform exposes the process facts the
# ownership test reads - a working directory per pid and a stat line carrying the
# session id.
fm_adopted_scan_supported() {
  [ -r /proc/self/cwd ] && [ -r /proc/self/stat ]
}

# fm_adopted_stat_field <pid> <n>: print field <n> of /proc/<pid>/stat counted
# from the state field, which is where the fields stop being ambiguous - comm can
# contain spaces and parentheses, so everything is read after the last ')'.
fm_adopted_stat_field() {
  local pid=$1 field=$2 stat rest
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  printf '%s\n' "$rest" | awk -v n="$field" '{print $n}'
}

# fm_adopted_session_of <pid>: print the process's session id. Exit 1 when the
# process is gone, 2 when it is there and the field could not be read.
fm_adopted_session_of() {
  local pid=$1 sid
  sid=$(fm_adopted_stat_field "$pid" 4) || return 1
  [ -n "$sid" ] || return 2
  printf '%s\n' "$sid"
}

# fm_adopted_pid_alive <pid>: 0 when the process still exists as a running one.
# A zombie has already exited and holds no working directory, so it counts as
# gone: a pid that is only waiting to be reaped can convict nobody of residency.
fm_adopted_pid_alive() {
  local pid=$1 state
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  state=$(fm_adopted_stat_field "$pid" 1) || return 1
  [ -n "$state" ] && [ "$state" != Z ]
}

# fm_adopted_parent_of <pid>: print the process's parent pid, or nothing.
fm_adopted_parent_of() {
  fm_adopted_stat_field "$1" 2
}

# fm_adopted_own_lineage: print " <pid> <pid> ... " for the scanning process and
# every process that launched it, so a membership test can leave exactly those
# out of the answer.
fm_adopted_own_lineage() {
  local pid=${BASHPID:-$$} parent depth=0 chain=' '
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$depth" -lt 64 ]; do
    chain="$chain$pid "
    parent=$(fm_adopted_parent_of "$pid") || break
    [ -n "$parent" ] || break
    [ "$parent" = "$pid" ] && break
    pid=$parent
    depth=$(( depth + 1 ))
  done
  printf '%s\n' "$chain"
}

# fm_adopted_command_of <pid>: print a short command name, or nothing.
fm_adopted_command_of() {
  local pid=$1
  [ -r "/proc/$pid/comm" ] || return 0
  tr -d '\n' < "/proc/$pid/comm" 2>/dev/null
  return 0
}

# fm_adopted_path_within <path> <dir>: 0 when path is dir or sits under it.
fm_adopted_path_within() {
  local path=$1 dir=$2
  [ -n "$path" ] && [ -n "$dir" ] || return 1
  [ "$path" = "$dir" ] && return 0
  case "$path" in "$dir"/*) return 0 ;; esac
  return 1
}

# fm_adopted_resident_pids <dir>: print each live pid whose cwd is inside dir.
# <dir> must already be resolved, because every cwd it is compared against is.
fm_adopted_resident_pids() {
  local dir=$1 pid cwd entry
  for entry in /proc/[0-9]*; do
    pid=${entry#/proc/}
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    fm_adopted_path_within "$cwd" "$dir" && printf '%s\n' "$pid"
  done
  return 0
}

# fm_adopted_name_pid <pid>: the one output line shape callers parse.
fm_adopted_name_pid() {
  printf '%s\t%s\n' "$1" "$(fm_adopted_command_of "$1")"
}

# fm_adopted_processes <dir>: print "<pid>\t<command>" for each process living in
# dir that this test convicts or cannot attribute. See the exit codes above.
fm_adopted_processes() {
  local dir=$1 resolved pids resident pid sid sid_rc lineage found=0
  fm_adopted_scan_supported || return 3
  # Every cwd this is compared against comes back fully resolved, so a recorded
  # path reached through a symlinked pool, home or TMPDIR has to be resolved too
  # or it matches nothing at all and the scan reports a false clear.
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) && dir=$resolved
  pids=$(fm_adopted_resident_pids "$dir")
  [ -n "$pids" ] || return 1
  resident=" $(printf '%s\n' "$pids" | tr '\n' ' ') "
  lineage=$(fm_adopted_own_lineage)

  for pid in $pids; do
    case "$lineage" in *" $pid "*) continue ;; esac
    sid=$(fm_adopted_session_of "$pid") && sid_rc=0 || sid_rc=$?
    # A pid that has since exited says nothing about ownership; a live one whose
    # session cannot be read leaves the whole answer unknown.
    if [ "$sid_rc" -eq 1 ]; then
      continue
    fi
    if [ "$sid_rc" -ne 0 ] || [ -z "$sid" ]; then
      fm_adopted_name_pid "$pid"
      return 2
    fi
    case "$resident" in
      *" $sid "*) ;;
      *)
        # A session led from outside the directory is the task's own shape, but
        # only while that leader is still there to be looked at. A session id
        # naming a process that has gone is the double-forked daemon's shape as
        # much as an orphaned crew process's, and nothing here can tell them
        # apart, so the whole answer is unknown rather than clear.
        if fm_adopted_pid_alive "$sid"; then
          continue
        fi
        fm_adopted_name_pid "$pid"
        return 2
        ;;
    esac
    fm_adopted_name_pid "$pid"
    found=1
  done

  [ "$found" = 1 ] && return 0
  return 1
}
