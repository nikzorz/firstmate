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

# bin/fm-send.sh and bin/fm-limit-resume.sh are pending the same fix; they were
# held by concurrent work when this sweep landed. Their exemption retires
# itself: it is asserted below to still be true, so the follow-up that teaches
# either one the flag fails here until the name is moved into the sweep.
EXEMPT_PENDING=(fm-send.sh fm-limit-resume.sh)

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
}

# Every home-derived path a helper can resolve points into <home>, so a helper
# that works before it reads its flag cannot reach an operator's real home.
run_help() {  # <home> <program> <flag>
  FM_HOME="$1" \
  FM_STATE_OVERRIDE="$1/state" \
  FM_DATA_OVERRIDE="$1/data" \
  FM_CONFIG_OVERRIDE="$1/config" \
  FM_PROJECTS_OVERRIDE="$1/projects" \
    fm_test_timeout "$HELP_BUDGET_SECS" "$2" "$3" 2>&1
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
    done
  done < <(entrypoints)
  pass "every bin entrypoint answers --help and -h with output and exits zero"
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

# The exemption list must stay a statement about current reality, not a place
# defects can be parked: every exempt helper must still exist.
test_permanent_exemptions_still_exist() {
  local base
  for base in "${EXEMPT_PERMANENT[@]}"; do
    assert_present "$ROOT/bin/$base" "exempt helper bin/$base no longer exists; drop or update the exemption"
  done
  pass "every permanent exemption still names a real helper"
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
test_every_entrypoint_answers_help_and_exits_zero
test_reported_helpers_answer_instead_of_rejecting
test_permanent_exemptions_still_exist
test_pending_exemptions_still_reject_help
test_sweep_never_touched_the_repo_home
