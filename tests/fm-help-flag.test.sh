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

repo_state_listing() {
  find "$ROOT/state" 2>/dev/null | LC_ALL=C sort
}

REPO_STATE_BEFORE=$(repo_state_listing)

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
EXEMPT_PERMANENT=(fm-pr-poll.sh)

# A helper held by concurrent work when it should join the sweep is parked here.
# The exemption retires itself: it is asserted below to still be true, so the
# change that teaches the helper the flag fails here until the name is removed.
# Empty is the normal state, so every expansion below must survive set -u on an
# empty array under macOS's stock bash.
EXEMPT_PENDING=()

# These helpers answer the flag but their help text states no call form. Their
# headers track the upstream project's text, so a usage line added here would
# diverge from it; they are carried instead of edited. Like EXEMPT_PENDING this
# retires itself: each is asserted below to still lack a call form, so the change
# that gives one a usage line fails here until its name is removed.
EXEMPT_NO_CALL_FORM=(
  fm-busy-event.sh
  fm-decision-hold.sh
  fm-extension.sh
  fm-mail.sh
  fm-remote-entrypoint.sh
  fm-remote-job-worker.sh
  fm-test-run.sh
  fm-turnend-guard-cursor.sh
)

lacks_call_form_by_exemption() {
  local base
  for base in "${EXEMPT_NO_CALL_FORM[@]}"; do
    [ "$1" = "$base" ] && return 0
  done
  return 1
}

# Answering the flag is not enough: a helper that prints an error such as
# "unknown argument --help" and still exits zero is the defect this sweep exists
# to catch. Every conforming helper opens a line with "usage:" in some case.
has_call_form() {
  printf '%s\n' "$1" | grep -qiE '^[[:space:]]*usage:'
}

is_exempt() {
  local base
  for base in "${EXEMPT_PERMANENT[@]}" "${EXEMPT_PENDING[@]:-}"; do
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
  # Backend .sh files are sourced; only the executable helpers there run directly.
  for path in "$ROOT"/bin/backends/*; do
    [ -f "$path" ] && [ -x "$path" ] || continue
    printf 'backends/%s\n' "${path##*/}"
  done
}

# Every home-derived path a helper can resolve points into <home>, so a helper
# that works before it reads its flag cannot reach an operator's real home.
in_sandbox_home() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
    fm_test_timeout "$HELP_BUDGET_SECS" "$@"
}

# The sweep asks only whether the flag is answered, so it merges both streams.
run_help() {  # <home> <program> <flag>
  in_sandbox_home "$1" "$2" "$3" 2>&1
}

# A stand-in helper that resolves its home the way bin/ helpers do and writes
# before it reads its flag. Owning one keeps the proof that the sandbox holds
# such a write independent of any real helper's argument ordering, which is free
# to improve.
write_before_help_fixture() {  # <dir>
  local path="$1/bin/fm-pre-help-writer.sh"
  mkdir -p "$1/bin"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"
: > "$STATE/pre-help-write"
case "${1:-}" in
  -h|--help) printf 'usage: %s\n' "${0##*/}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

test_pre_help_writes_land_in_the_sandbox_home() {
  local home fixture_root fixture out rc
  home=$(fm_test_tmproot fm-help-flag-probe-home)
  fixture_root=$(fm_test_tmproot fm-help-flag-probe-root)
  fixture=$(write_before_help_fixture "$fixture_root")
  out=$(run_help "$home" "$fixture" --help)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the pre-help writer exited $rc: $out"
  assert_present "$home/state/pre-help-write" \
    "a write made before the flag check must land in the sandbox home"
  assert_absent "$fixture_root/state" \
    "a write made before the flag check reached the default home instead of the sandbox"
  pass "a write made before the flag check lands in the sandbox home"
}

test_every_entrypoint_answers_help_and_exits_zero() {
  local base flag out rc
  while IFS= read -r base; do
    for flag in --help -h; do
      out=$(run_help "$HELP_HOME" "$ROOT/bin/$base" "$flag")
      rc=$?
      [ "$rc" -eq 0 ] || fail "bin/$base $flag exited $rc: $out"
      [ -n "$out" ] || fail "bin/$base $flag printed nothing"
      lacks_call_form_by_exemption "$base" && continue
      has_call_form "$out" || fail "bin/$base $flag printed no usage line: $out"
    done
  done < <(entrypoints)
  pass "every bin entrypoint answers --help and -h with a usage line and exits zero"
}

test_call_form_anchor_rejects_an_error_in_place_of_help() {
  local error_text="error: unknown argument --help"
  ! has_call_form "$error_text" \
    || fail "an error printed in place of help must not read as a call form"
  has_call_form "Usage: fm-example.sh <task-id>" \
    || fail "a documented usage line must read as a call form"
  pass "the call-form anchor rejects an error printed in place of help"
}

# The two reported helpers, named so a regression in either is unambiguous.
test_reported_helpers_answer_instead_of_rejecting() {
  local script out
  for script in fm-pr-merge.sh fm-promote.sh; do
    out=$(run_help "$HELP_HOME" "$ROOT/bin/$script" --help) || fail "bin/$script --help exited nonzero"
    assert_contains "$out" "Usage: $script" "bin/$script --help must print its documented usage line"
  done
  pass "fm-pr-merge.sh and fm-promote.sh answer --help with their usage line"
}

# bin/fm-x-dismiss.sh and bin/fm-x-link.sh answer the flag through the same
# usage() their argument error uses, so for these two the stream is the whole
# question: an operator keeps the text with `fm-x-dismiss.sh --help > notes.txt`
# and still wants a genuine usage error where errors belong. The sweep merges
# both streams and so cannot tell the two apart.
test_shared_usage_helpers_answer_on_stdout() {
  local base out err rc
  for base in fm-x-dismiss.sh fm-x-link.sh; do
    out=$(in_sandbox_home "$HELP_HOME" "$ROOT/bin/$base" --help 2>/dev/null)
    rc=$?
    expect_code 0 "$rc" "bin/$base --help"
    [ -n "$out" ] || fail "bin/$base --help wrote nothing to stdout, so redirecting it to a file keeps an empty file"
    err=$(in_sandbox_home "$HELP_HOME" "$ROOT/bin/$base" --help 2>&1 >/dev/null)
    [ -z "$err" ] || fail "bin/$base --help wrote to stderr: $err"

    out=$(in_sandbox_home "$HELP_HOME" "$ROOT/bin/$base" 2>/dev/null)
    rc=$?
    expect_code 2 "$rc" "bin/$base with no arguments"
    [ -z "$out" ] || fail "bin/$base with no arguments wrote its usage error to stdout: $out"
    err=$(in_sandbox_home "$HELP_HOME" "$ROOT/bin/$base" 2>&1 >/dev/null)
    assert_contains "$err" "usage: $base" \
      "bin/$base with no arguments must still fail with its usage error on stderr"
  done
  pass "the helpers that share usage() with their error path send help to stdout and errors to stderr"
}

# The exemption list must stay a statement about current reality, not a place
# defects can be parked: every exempt helper must still exist.
test_permanent_exemptions_still_exist() {
  local base
  for base in "${EXEMPT_PERMANENT[@]}"; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
  done
  pass "every permanent exemption still names a real helper"
}

test_call_form_exemptions_still_lack_one() {
  local base flag out rc
  for base in "${EXEMPT_NO_CALL_FORM[@]}"; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
    for flag in --help -h; do
      out=$(run_help "$HELP_HOME" "$ROOT/bin/$base" "$flag")
      rc=$?
      [ "$rc" -eq 0 ] || fail "bin/$base $flag exited $rc: $out"
      ! has_call_form "$out" \
        || fail "bin/$base $flag now prints a usage line; remove it from EXEMPT_NO_CALL_FORM so the sweep requires one"
    done
  done
  pass "every call-form exemption still answers the flag without a usage line"
}

test_pending_exemptions_still_reject_help() {
  local base flag out rc
  [ "${#EXEMPT_PENDING[@]}" -gt 0 ] || return
  for base in "${EXEMPT_PENDING[@]}"; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
    for flag in --help -h; do
      out=$(run_help "$HELP_HOME" "$ROOT/bin/$base" "$flag")
      rc=$?
      [ "$rc" -ne 0 ] \
        || fail "bin/$base now answers $flag; move it out of EXEMPT_PENDING so the sweep covers it: $out"
    done
  done
  pass "every pending exemption still rejects --help and -h"
}

# The snapshot is a set of paths, so an in-place write to a path that already
# exists is deliberately out of reach. Catching that needs modification times,
# and on a live home those turn ordinary concurrent fleet activity into a
# failure often enough to cost more than the case is worth.
test_sweep_never_touched_the_repo_home() {
  local after added removed
  after=$(repo_state_listing)
  if [ "$after" != "$REPO_STATE_BEFORE" ]; then
    added=$(LC_ALL=C comm -13 <(printf '%s\n' "$REPO_STATE_BEFORE") <(printf '%s\n' "$after") | grep -v '^$')
    removed=$(LC_ALL=C comm -23 <(printf '%s\n' "$REPO_STATE_BEFORE") <(printf '%s\n' "$after") | grep -v '^$')
    fail "the set of paths under $ROOT/state differs from before the sweep: either a helper resolved the live home instead of the sandbox, or ordinary fleet activity wrote to this live home while the suite ran"$'\n'"added:"$'\n'"$added"$'\n'"removed:"$'\n'"$removed"
  fi
  pass "the sweep adds and removes no path under this repo's own state directory"
}

test_pre_help_writes_land_in_the_sandbox_home
test_call_form_anchor_rejects_an_error_in_place_of_help
test_every_entrypoint_answers_help_and_exits_zero
test_reported_helpers_answer_instead_of_rejecting
test_shared_usage_helpers_answer_on_stdout
test_permanent_exemptions_still_exist
test_call_form_exemptions_still_lack_one
test_pending_exemptions_still_reject_help
test_sweep_never_touched_the_repo_home
