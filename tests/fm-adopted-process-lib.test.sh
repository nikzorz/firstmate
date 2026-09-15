#!/usr/bin/env bash
# Tests for bin/fm-adopted-process-lib.sh: the single owner of "which processes
# living in this directory did nobody here start?".
#
# `treehouse return` terminates by working directory alone. bin/fm-teardown.sh
# uses this scan to keep it away from a detached service that merely happens to
# sit in the worktree - measured once as the shared validation daemon, and with
# it two other lanes' in-flight runs.
#
# Matrix:
#   (a) a detached process (its own session leader) in the directory -> ADOPTED
#   (b) that process's own worker, sharing its session               -> ADOPTED
#   (c) a process that inherited an outside session                  -> not adopted
#   (d) a directory holding no processes at all                      -> clear
#   (e) a process one level deeper than the directory                -> ADOPTED
#   (f) a sibling directory's detached process                       -> not reported
#   (g) the scanning shell itself                                    -> never reported
#   (h) a directory reached through a symlink                        -> ADOPTED
#   (i) a resident process whose session leader has died             -> UNKNOWN
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-adopted-process-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-adopted)
# fm_test_tmproot registers its cleanup inside the command substitution's own
# subshell, so this shell has to claim the directory itself to have it removed.
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

# The pid registry is a file, not an array: every process below is started
# inside a command substitution, so a shell variable would be set in a subshell
# and this shell's cleanup would find nothing to kill.
SPAWNED_FILE="$TMP_ROOT/spawned.pids"
: > "$SPAWNED_FILE"

cleanup_spawned() {
  local pid
  # An EXIT trap is inherited by command-substitution subshells, and every
  # process below is started inside one. Without this the first spawn's subshell
  # would exit and take the whole fixture down with it.
  if [ "$BASHPID" = "$$" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$SPAWNED_FILE"
    fm_test_cleanup
  fi
  # An EXIT trap's own last status becomes the script's, so end on a true
  # command: a cleanup that found nothing to do is not a failing test run.
  :
}
trap cleanup_spawned EXIT

# Wait for a spawned process to report its own pid. A pid the fixture reads back
# from the process it started is the only one it can be sure of; the machine may
# be running any number of identical commands for other reasons.
read_reported_pid() {
  local pidfile=$1 marker=$2 waited=0
  while [ ! -s "$pidfile" ]; do
    [ "$waited" -lt 200 ] || fail "$marker: the spawned process never reported its pid"
    sleep 0.05
    waited=$(( waited + 1 ))
  done
  cat "$pidfile"
}

# Start a process that detaches into its own session with cwd in <dir>, the
# defining act of a daemon. `exec` keeps the pid it reported.
start_detached_in() {
  local dir=$1 marker=$2 pidfile pid
  pidfile=$(mktemp "$TMP_ROOT/detached.XXXXXX")
  setsid bash -c "cd '$dir' && printf '%s\n' \$\$ > '$pidfile' && exec sleep 300" \
    </dev/null >/dev/null 2>&1 &
  pid=$(read_reported_pid "$pidfile" "$marker")
  kill -0 "$pid" 2>/dev/null || fail "$marker: could not start a detached process in $dir"
  printf '%s\n' "$pid" >> "$SPAWNED_FILE"
  printf '%s\n' "$pid"
}

# Start a detached service that keeps a worker child, the shape the shared
# validation daemon has: the leader detaches, and the worker inherits that
# session without leading one. Echoes "<leader> <worker>".
start_detached_service_with_worker_in() {
  local dir=$1 marker=$2 leader_file worker_file leader worker
  leader_file=$(mktemp "$TMP_ROOT/leader.XXXXXX")
  worker_file=$(mktemp "$TMP_ROOT/worker.XXXXXX")
  setsid bash -c "cd '$dir' || exit 1
    sleep 300 &
    printf '%s\n' \$! > '$worker_file'
    printf '%s\n' \$\$ > '$leader_file'
    wait" </dev/null >/dev/null 2>&1 &
  leader=$(read_reported_pid "$leader_file" "$marker leader")
  worker=$(read_reported_pid "$worker_file" "$marker worker")
  printf '%s\n' "$leader" "$worker" >> "$SPAWNED_FILE"
  kill -0 "$leader" 2>/dev/null || fail "$marker: the service leader did not stay alive"
  kill -0 "$worker" 2>/dev/null || fail "$marker: the service worker did not stay alive"
  printf '%s %s\n' "$leader" "$worker"
}

# Start a process in <dir> whose session leader then exits, the state a daemon
# that double-forks leaves behind: the survivor's session id names a pid that is
# no longer there. The leader is started from a subshell that exits immediately so
# init reaps it, because a leader still waiting to be reaped is not yet gone.
start_orphaned_in() {
  local dir=$1 marker=$2 child_file leader_file child leader waited=0
  child_file=$(mktemp "$TMP_ROOT/orphan-child.XXXXXX")
  leader_file=$(mktemp "$TMP_ROOT/orphan-leader.XXXXXX")
  ( setsid bash -c "cd '$dir' || exit 1
    sleep 300 &
    printf '%s\n' \$! > '$child_file'
    printf '%s\n' \$\$ > '$leader_file'" </dev/null >/dev/null 2>&1 & )
  child=$(read_reported_pid "$child_file" "$marker child")
  leader=$(read_reported_pid "$leader_file" "$marker leader")
  printf '%s\n' "$child" >> "$SPAWNED_FILE"
  while ! pid_has_gone "$leader"; do
    [ "$waited" -lt 200 ] || fail "$marker: the session leader never exited"
    sleep 0.05
    waited=$(( waited + 1 ))
  done
  kill -0 "$child" 2>/dev/null || fail "$marker: the orphan did not outlive its session leader"
  printf '%s\n' "$child"
}

# Decided without the library under test, so the fixture's precondition does not
# rest on the same reading of "gone" the assertion is checking.
pid_has_gone() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 0
  state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$state" in Z*) return 0 ;; esac
  return 1
}

# Start a process in <dir> that stays in the caller's own session, the shape a
# crewmate's agent tree takes under its terminal.
start_attached_in() {
  local dir=$1 marker=$2 pid
  ( cd "$dir" && exec sleep 300 ) </dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "$marker: could not start an attached process in $dir"
  printf '%s\n' "$pid" >> "$SPAWNED_FILE"
  printf '%s\n' "$pid"
}

adopted_pids() {
  local dir=$1 out
  out=$(fm_adopted_processes "$dir") || true
  printf '%s\n' "$out" | awk 'NF {print $1}'
}

test_detached_process_is_adopted() {
  local dir="$TMP_ROOT/detached" pid found
  mkdir -p "$dir"
  pid=$(start_detached_in "$dir" detached)

  found=$(adopted_pids "$dir")
  assert_contains "$found" "$pid" "detached: the detached process should be reported as adopted"
  pass "a process that detached into its own session inside the directory is adopted"
}

# The worker is the case the measured incident turned on: the daemon's log sink
# leads no session of its own, so only its leader's residency can convict it.
test_a_services_worker_is_adopted_with_its_leader() {
  local dir="$TMP_ROOT/service" pair leader worker found
  mkdir -p "$dir"
  pair=$(start_detached_service_with_worker_in "$dir" service)
  leader=${pair% *}
  worker=${pair#* }
  [ "$worker" != "$leader" ] || fail "service: the worker should be a separate process"

  found=$(adopted_pids "$dir")
  assert_contains "$found" "$leader" "service: the detached leader should be reported"
  assert_contains "$found" "$worker" "service: the leader's worker should be reported too"
  pass "a detached service's worker is adopted along with the leader whose session it inherited"
}

test_attached_process_is_not_adopted() {
  local dir="$TMP_ROOT/attached" pid found
  mkdir -p "$dir"
  pid=$(start_attached_in "$dir" attached)

  found=$(adopted_pids "$dir")
  assert_not_contains "$found" "$pid" "attached: a process in the caller's session must not be adopted"
  pass "a process that inherited a session led from outside the directory is not adopted"
}

test_empty_directory_is_clear() {
  local dir="$TMP_ROOT/empty" rc
  mkdir -p "$dir"

  set +e
  fm_adopted_processes "$dir" >/dev/null
  rc=$?
  set -e

  expect_code 1 "$rc" "empty: a directory with no resident processes should report clear"
  pass "a directory holding no processes reports clear"
}

test_process_in_a_subdirectory_is_seen() {
  local dir="$TMP_ROOT/deep" sub pid found
  sub="$dir/a/b"
  mkdir -p "$sub"
  pid=$(start_detached_in "$sub" deep)

  found=$(adopted_pids "$dir")
  assert_contains "$found" "$pid" "deep: a process below the directory should be seen"
  pass "a detached process below the directory is seen, not just one at its root"
}

test_sibling_directory_is_not_reported() {
  local mine="$TMP_ROOT/lane-a" theirs="$TMP_ROOT/lane-a-extra" pid found
  mkdir -p "$mine" "$theirs"
  pid=$(start_detached_in "$theirs" sibling)

  found=$(adopted_pids "$mine")
  assert_not_contains "$found" "$pid" "sibling: a name-prefix neighbour must not be swept in"
  pass "a detached process in a directory that merely shares a name prefix is not reported"
}

# A recorded worktree path routinely reaches its directory through a symlink (a
# pooled slot, a symlinked home, macOS's /var TMPDIR). The kernel reports every
# process's cwd resolved, so an unresolved path on this side matches nothing and
# the scan would report a clear directory it never actually looked at.
test_symlinked_directory_still_finds_the_process() {
  local real="$TMP_ROOT/pool-real" link="$TMP_ROOT/pool-link" pid found
  mkdir -p "$real"
  ln -sfn "$real" "$link"
  pid=$(start_detached_in "$real" symlink)

  found=$(adopted_pids "$link")
  assert_contains "$found" "$pid" "symlink: a directory reached through a symlink must still be scanned"
  pass "a directory named through a symlink is scanned as the directory it resolves to"
}

# The exemption only makes a difference when the scanning shell is itself a
# resident session leader, so the scan is run from exactly that shape rather than
# from wherever the runner happened to start. Without the exemption this shell
# matches the adopted test on every count and convicts itself.
test_scanning_shell_never_accuses_itself() {
  local dir="$TMP_ROOT/self-scan" out scanner found
  mkdir -p "$dir"
  out=$(setsid bash -c "cd '$dir' && printf 'SCANNER %s\n' \$\$ \
    && . '$ROOT/bin/fm-adopted-process-lib.sh' \
    && fm_adopted_processes '$dir'" </dev/null 2>/dev/null) || true
  scanner=$(printf '%s\n' "$out" | awk '$1 == "SCANNER" { print $2 }')
  [ -n "$scanner" ] || fail "self: the scanning shell never reported its own pid"
  found=" $(printf '%s\n' "$out" | awk '$1 != "SCANNER" && NF { print $1 }' | tr '\n' ' ') "
  assert_not_contains "$found" " $scanner " "self: the scanning shell must never be reported"
  pass "a scanning shell that is its own resident session leader never reports itself"
}

# The double-fork daemon (fork, setsid, fork, middle process exits) leaves a
# survivor whose session id names a pid that is gone. Nothing can tell that apart
# from an orphaned crew process, so the scan must say so rather than call the
# directory clear and let the return tool kill whatever is there.
test_dead_session_leader_reads_as_unknown() {
  local dir="$TMP_ROOT/orphan" pid rc
  mkdir -p "$dir"
  pid=$(start_orphaned_in "$dir" orphan)

  set +e
  fm_adopted_processes "$dir" >/dev/null
  rc=$?
  set -e

  expect_code 2 "$rc" "orphan: a process whose session leader is gone should read as unknown"
  kill -0 "$pid" 2>/dev/null || fail "orphan: the orphaned process did not survive the scan"
  pass "a resident process whose session leader has died reads as unknown, not as clear"
}

test_detached_process_is_adopted
test_a_services_worker_is_adopted_with_its_leader
test_attached_process_is_not_adopted
test_empty_directory_is_clear
test_process_in_a_subdirectory_is_seen
test_sibling_directory_is_not_reported
test_symlinked_directory_still_finds_the_process
test_scanning_shell_never_accuses_itself
test_dead_session_leader_reads_as_unknown
