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
# Two limits, stated rather than hidden. A shared service started as an ordinary
# child of a crew's own terminal session, never detaching, is invisible to this
# test - it is indistinguishable from the crew's own work by any process fact.
# And a task's own deliberately detached leftover (a background server the crew
# setsid'd) is caught and refused even though killing it would have been fine;
# the caller resolves that by ending the process and returning again. Refusing
# where the answer is unknown is the cheap error: no work is lost, and the
# expensive error - killing another lane's run - is the one this scan exists to
# make impossible.
#
# Enumeration reads /proc where it exists and falls back to lsof elsewhere. A
# scan that cannot run at all reports that distinctly (exit 2) so a caller can
# refuse rather than proceed blind.

# fm_adopted_scan_supported: 0 when some enumeration path is available.
fm_adopted_scan_supported() {
  [ -r /proc/self/cwd ] && return 0
  command -v lsof >/dev/null 2>&1 && command -v ps >/dev/null 2>&1
}

# fm_adopted_session_of <pid>: print the process's session id, or nothing.
fm_adopted_session_of() {
  local pid=$1 stat rest
  if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    # comm can contain spaces and parentheses, so read the fields after the last ')'.
    rest=${stat##*) }
    # rest starts at field 3 (state); session is field 6, i.e. the 4th here.
    printf '%s\n' "$rest" | awk '{print $4}'
    return 0
  fi
  ps -o sid= -p "$pid" 2>/dev/null | tr -d ' '
}

# fm_adopted_command_of <pid>: print a short command name, or nothing.
fm_adopted_command_of() {
  local pid=$1
  if [ -r "/proc/$pid/comm" ]; then
    tr -d '\n' < "/proc/$pid/comm" 2>/dev/null
    return 0
  fi
  ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n'
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
# Exit 2 when no enumeration path could run.
fm_adopted_resident_pids() {
  local dir=$1 pid cwd entry
  if [ -r /proc/self/cwd ]; then
    for entry in /proc/[0-9]*; do
      pid=${entry#/proc/}
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
      fm_adopted_path_within "$cwd" "$dir" && printf '%s\n' "$pid"
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 2
  lsof -w -n -P -d cwd -F pn 2>/dev/null | awk -v dir="$dir" '
    /^p/ { pid = substr($0, 2); next }
    /^n/ {
      path = substr($0, 2)
      if (path == dir || index(path, dir "/") == 1) print pid
    }
  '
}

# fm_adopted_processes <dir>: print "<pid>\t<command>" for each process living in
# dir that nothing inside dir's own task lineage started. Exit 0 when at least
# one was found, 1 when the directory is clear, 2 when the scan could not run.
# The caller's own session is never reported: a scan run from inside the
# directory would otherwise accuse the shell doing the scanning.
fm_adopted_processes() {
  local dir=$1 pids pid sid own_sid found=0
  fm_adopted_scan_supported || return 2
  pids=$(fm_adopted_resident_pids "$dir") || return 2
  own_sid=$(fm_adopted_session_of $$) || own_sid=

  local -A resident=()
  for pid in $pids; do
    resident[$pid]=1
  done

  for pid in $pids; do
    sid=$(fm_adopted_session_of "$pid") || continue
    [ -n "$sid" ] || continue
    [ -n "$own_sid" ] && [ "$sid" = "$own_sid" ] && continue
    [ -n "${resident[$sid]:-}" ] || continue
    printf '%s\t%s\n' "$pid" "$(fm_adopted_command_of "$pid")"
    found=1
  done

  [ "$found" = 1 ] && return 0
  return 1
}
