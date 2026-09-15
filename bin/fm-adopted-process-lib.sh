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
# Enumeration reads /proc where it exists and falls back to lsof plus ps
# elsewhere. Every way the scan can come up short - no enumeration path, an lsof
# that produced nothing, a live process whose session this platform will not
# report - reports that distinctly (exit 2) rather than as a clear directory, so
# a caller refuses instead of proceeding blind.

# fm_adopted_proc_available: 0 when this kernel exposes the /proc fields used here.
fm_adopted_proc_available() {
  [ -r /proc/self/cwd ] && [ -r /proc/self/stat ]
}

# fm_adopted_scan_supported: 0 when some enumeration path is available.
fm_adopted_scan_supported() {
  fm_adopted_proc_available && return 0
  command -v lsof >/dev/null 2>&1 && command -v ps >/dev/null 2>&1
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
# process is gone, 2 when it is alive and this platform will not say.
fm_adopted_session_of() {
  local pid=$1 sid
  if fm_adopted_proc_available; then
    sid=$(fm_adopted_stat_field "$pid" 4) || return 1
    [ -n "$sid" ] || return 2
    printf '%s\n' "$sid"
    return 0
  fi
  sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$sid" ]; then
    printf '%s\n' "$sid"
    return 0
  fi
  ps -o pid= -p "$pid" >/dev/null 2>&1 || return 1
  return 2
}

# fm_adopted_parent_of <pid>: print the process's parent pid, or nothing.
fm_adopted_parent_of() {
  local pid=$1
  if fm_adopted_proc_available; then
    fm_adopted_stat_field "$pid" 2 || return 1
    return 0
  fi
  ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
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
# <dir> must already be resolved, because every cwd it is compared against is.
# Exit 2 when no enumeration path could run.
fm_adopted_resident_pids() {
  local dir=$1 pid cwd entry listing status
  if fm_adopted_proc_available; then
    for entry in /proc/[0-9]*; do
      pid=${entry#/proc/}
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
      fm_adopted_path_within "$cwd" "$dir" && printf '%s\n' "$pid"
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 2
  listing=$(lsof -w -n -P -d cwd -F pn 2>/dev/null)
  status=$?
  # An empty listing is never a real answer: every machine has processes with a
  # working directory. lsof's exit 1 over a non-empty listing means only that
  # some process could not be inspected, which the /proc path tolerates too.
  [ -n "$listing" ] || return 2
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || return 2
  printf '%s\n' "$listing" | awk -v dir="$dir" '
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
fm_adopted_processes() {
  local dir=$1 resolved pids resident pid sid sid_rc lineage found=0
  fm_adopted_scan_supported || return 2
  # Every cwd this is compared against comes back fully resolved, so a recorded
  # path reached through a symlinked pool, home or TMPDIR has to be resolved too
  # or it matches nothing at all and the scan reports a false clear.
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) && dir=$resolved
  pids=$(fm_adopted_resident_pids "$dir") || return 2
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
      return 2
    fi
    case "$resident" in *" $sid "*) ;; *) continue ;; esac
    printf '%s\t%s\n' "$pid" "$(fm_adopted_command_of "$pid")"
    found=1
  done

  [ "$found" = 1 ] && return 0
  return 1
}
