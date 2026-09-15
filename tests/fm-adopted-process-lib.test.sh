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
#   (b) that process's own child, sharing its session               -> ADOPTED
#   (c) a process that inherited an outside session                  -> not adopted
#   (d) a directory holding no processes at all                      -> clear
#   (e) a process one level deeper than the directory                -> ADOPTED
#   (f) a sibling directory's detached process                       -> not reported
#   (g) the scanning shell's own session                             -> never reported
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

# Start a process that detaches into its own session with cwd in <dir>, the
# defining act of a daemon. Echoes its pid once /proc (or ps) can see it.
start_detached_in() {
  local dir=$1 marker=$2 pid
  setsid bash -c "cd '$dir' && exec sleep 300" </dev/null >/dev/null 2>&1 &
  sleep 0.3
  pid=$(pgrep -f "^sleep 300$" | tail -1)
  [ -n "$pid" ] || fail "$marker: could not start a detached process in $dir"
  printf '%s\n' "$pid" >> "$SPAWNED_FILE"
  printf '%s\n' "$pid"
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

test_detached_process_and_its_child_are_adopted() {
  local dir="$TMP_ROOT/detached" pid found
  mkdir -p "$dir"
  pid=$(start_detached_in "$dir" detached)

  found=$(adopted_pids "$dir")
  assert_contains "$found" "$pid" "detached: the detached process should be reported as adopted"
  pass "a process that detached into its own session inside the directory is adopted"

  # A daemon's own worker inherits the daemon's session, whose leader is itself
  # resident, so the whole service is caught, not only its leader.
  local child_sid leader
  child_sid=$(fm_adopted_session_of "$pid")
  leader=$child_sid
  [ "$leader" = "$pid" ] || fail "detached-child: expected the process to lead its own session"
  pass "a detached service's session leader is itself, so its workers are caught with it"
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

test_scanning_shell_never_accuses_itself() {
  local dir found
  # The scan itself runs from somewhere; a scan of that somewhere must not
  # report the shell doing the scanning, whatever session shape it has.
  dir=$(pwd -P)
  found=$(adopted_pids "$dir")
  assert_not_contains "$found" "$$" "self: the scanning shell must never be reported"
  pass "the scanning shell's own session is never reported as adopted"
}

test_detached_process_and_its_child_are_adopted
test_attached_process_is_not_adopted
test_empty_directory_is_clear
test_process_in_a_subdirectory_is_seen
test_sibling_directory_is_not_reported
test_scanning_shell_never_accuses_itself

