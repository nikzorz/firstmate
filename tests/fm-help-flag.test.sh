#!/usr/bin/env bash
# Every bin/ helper must answer --help and -h with its documented usage.
#
# Regression origin: bin/fm-pr-merge.sh and bin/fm-promote.sh consumed $1 as a
# task id before any flag check, so `--help` was read as an identifier and the
# helper exited with "invalid PR merge request" or "no meta for task --help".
# Both discoveries happened mid-merge and mid-promotion, and both cost a fall
# back to reading the script header. The shape is easy to reintroduce, so this
# test sweeps every entrypoint rather than the two that were reported.
#
# The sweep proves the contract by running each helper, so it runs them against
# a throwaway home. A helper whose flag check sits behind top-level work claims
# locks and one-shot markers in whatever home it resolves, and FM_HOME defaults
# to this repo root, which on a captain's machine is the live one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELP_BUDGET_SECS=30

REPO_STATE_BEFORE=absent
[ -e "$ROOT/state" ] && REPO_STATE_BEFORE=present

HELP_HOME=$(fm_test_tmproot fm-help-flag)
mkdir -p "$HELP_HOME/state" "$HELP_HOME/data" "$HELP_HOME/config" "$HELP_HOME/projects"

# Sourced libraries have no command line of their own. bin/fm-backend.sh is one
# despite its name: it defines functions and has no main.
is_library() {
  case "$1" in
    *-lib.sh|fm-backend.sh) return 0 ;;
  esac
  return 1
}

# bin/fm-pr-poll.sh is a static watcher program, not an operator helper: its
# bytes are copied verbatim into state/<id>.check.sh and revalidated against
# this template, so adding a flag to it would invalidate every published poll.
# It already exits zero and silently on any unrecognized argument.
#
# bin/fm-send.sh and bin/fm-limit-resume.sh are pending the same fix; they were
# held by concurrent work when this sweep landed.
EXEMPT=(fm-pr-poll.sh fm-send.sh fm-limit-resume.sh)

is_exempt() {
  local base
  for base in "${EXEMPT[@]}"; do
    [ "$1" = "$base" ] && return 0
  done
  return 1
}

entrypoints() {
  local path base
  for path in "$ROOT"/bin/*.sh; do
    base=${path##*/}
    is_library "$base" && continue
    is_exempt "$base" && continue
    printf '%s\n' "$base"
  done
}

# Every home-derived path a helper can resolve points into <home>, so a helper
# that works before it reads its flag cannot reach an operator's real home.
run_help() {  # <home> <basename> <flag>
  FM_HOME="$1" \
  FM_STATE_OVERRIDE="$1/state" \
  FM_DATA_OVERRIDE="$1/data" \
  FM_CONFIG_OVERRIDE="$1/config" \
  FM_PROJECTS_OVERRIDE="$1/projects" \
    fm_test_timeout "$HELP_BUDGET_SECS" "$ROOT/bin/$2" "$3" 2>&1
}

# bin/fm-afk-launch.sh takes the launcher lock, creating its state directory,
# before it dispatches -h, so it shows the sandbox absorbing a real write rather
# than the sweep merely assuming one cannot escape.
test_pre_help_writes_land_in_the_sandbox_home() {
  local home out rc
  home=$(fm_test_tmproot fm-help-flag-probe)
  out=$(run_help "$home" fm-afk-launch.sh --help)
  rc=$?
  [ "$rc" -eq 0 ] || fail "bin/fm-afk-launch.sh --help exited $rc: $out"
  assert_present "$home/state" \
    "bin/fm-afk-launch.sh --help must resolve its state directory from the sandbox home"
  pass "a helper that writes before its flag check writes into the sandbox home"
}

test_every_entrypoint_prints_usage_and_exits_zero() {
  local base flag out rc
  while IFS= read -r base; do
    for flag in --help -h; do
      out=$(run_help "$HELP_HOME" "$base" "$flag")
      rc=$?
      [ "$rc" -eq 0 ] || fail "bin/$base $flag exited $rc: $out"
      [ -n "$out" ] || fail "bin/$base $flag printed nothing"
    done
  done < <(entrypoints)
  pass "every bin entrypoint prints usage and exits zero for --help and -h"
}

# The two reported helpers, named so a regression in either is unambiguous.
test_reported_helpers_answer_instead_of_rejecting() {
  local script out
  for script in fm-pr-merge.sh fm-promote.sh; do
    out=$(run_help "$HELP_HOME" "$script" --help) || fail "bin/$script --help exited nonzero"
    assert_contains "$out" "Usage: $script" "bin/$script --help must print its documented usage line"
  done
  pass "fm-pr-merge.sh and fm-promote.sh answer --help with their usage line"
}

# The exemption list must stay a statement about current reality, not a place
# defects can be parked: every exempt helper must still exist.
test_exemptions_still_exist() {
  local base
  for base in "${EXEMPT[@]}"; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
  done
  pass "every documented exemption still names a real helper"
}

test_sweep_never_touched_the_repo_home() {
  local now=absent
  [ -e "$ROOT/state" ] && now=present
  [ "$now" = "$REPO_STATE_BEFORE" ] \
    || fail "the sweep changed $ROOT/state; helpers resolved the live home instead of the sandbox"
  pass "the sweep leaves this repo's own state directory as it found it"
}

test_pre_help_writes_land_in_the_sandbox_home
test_every_entrypoint_prints_usage_and_exits_zero
test_reported_helpers_answer_instead_of_rejecting
test_exemptions_still_exist
test_sweep_never_touched_the_repo_home
