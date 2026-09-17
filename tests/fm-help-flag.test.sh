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
# The check has two layers. The static layer proves the recognizer exists in
# source before anything is executed, so a newly added helper that still
# consumes $1 first is reported without this suite running its real work. The
# behavioral layer then proves the recognizer prints something and exits zero.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
is_exempt() {
  case "$1" in
    fm-pr-poll.sh|fm-send.sh|fm-limit-resume.sh) return 0 ;;
  esac
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

# True when the file recognizes the flag somewhere outside its comments.
recognizes_help() {
  grep -qE '^[^#]*--help' "$ROOT/bin/$1"
}

test_every_entrypoint_recognizes_help() {
  local base missing=
  while IFS= read -r base; do
    recognizes_help "$base" || missing="$missing $base"
  done < <(entrypoints)
  [ -z "$missing" ] || fail "bin helpers with no --help recognizer:$missing"
  pass "every bin entrypoint recognizes --help in source"
}

test_every_entrypoint_prints_usage_and_exits_zero() {
  local base flag out rc
  while IFS= read -r base; do
    recognizes_help "$base" || continue
    for flag in --help -h; do
      out=$(timeout 30 "$ROOT/bin/$base" "$flag" 2>&1)
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
    out=$("$ROOT/bin/$script" --help 2>&1) || fail "bin/$script --help exited nonzero"
    assert_contains "$out" "Usage: $script" "bin/$script --help must print its documented usage line"
  done
  pass "fm-pr-merge.sh and fm-promote.sh answer --help with their usage line"
}

# The exemption list must stay a statement about current reality, not a place
# defects can be parked: every exempt helper must still exist.
test_exemptions_still_exist() {
  local base
  for base in fm-pr-poll.sh fm-send.sh fm-limit-resume.sh; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
  done
  pass "every documented exemption still names a real helper"
}

test_every_entrypoint_recognizes_help
test_every_entrypoint_prints_usage_and_exits_zero
test_reported_helpers_answer_instead_of_rejecting
test_exemptions_still_exist
