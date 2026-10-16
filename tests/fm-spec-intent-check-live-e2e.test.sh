#!/usr/bin/env bash
# Credentialed behaviour guard for bin/fm-spec-intent-check.sh's real judge.
#
# The hermetic tests prove the plumbing with a stub judge; only the model
# decides which bullets add scope, so this asks the real one about the fixture
# briefs. The PR 109 brief must be refused for its per-finding-id filter, the
# round-binding brief for its fallback for lines with no round, a spec of pure
# build instructions must pass, and that same spec must still pass with the
# fallback bullet added under a justification the judge did flag.
# shellcheck disable=SC2016 # Backticks are literal Markdown in brief text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SPEC_INTENT_CHECK_LIVE_E2E claude
unset FM_SPEC_INTENT_CHECK_CLAUDE_BIN

CHECK="$ROOT/bin/fm-spec-intent-check.sh"
FIXTURES="$ROOT/tests/spec-intent-fixtures"
TMP_ROOT=$(fm_test_tmproot fm-spec-intent-check-live)
RECORD="$TMP_ROOT/record.txt"

run_check() {  # <brief> -> sets OUT and STATUS
  OUT=$("$CHECK" "$1" "$RECORD" 2>&1)
  STATUS=$?
}

test_pr_109_brief_flags_its_finding_id_filter() {
  run_check "$FIXTURES/nm-findings-reader.md"
  expect_code 1 "$STATUS" "the PR 109 brief should be refused: $OUT"$'\n'"$(cat "$RECORD")"
  assert_contains "$OUT" 'bullet 2 adds' "the per-finding-id bullet was not flagged"
  pass "the PR 109 brief is refused for its per-finding-id filter"
}

test_round_binding_brief_flags_its_no_round_fallback() {
  run_check "$FIXTURES/merge-guard-round-ids.md"
  expect_code 1 "$STATUS" "the round-binding brief should be refused: $OUT"$'\n'"$(cat "$RECORD")"
  assert_contains "$OUT" 'bullet 3 adds' "the no-round fallback bullet was not flagged"
  pass "the round-binding brief is refused for its fallback for lines with no round"
}

test_pure_build_spec_passes() {
  run_check "$FIXTURES/pure-build.md"
  expect_code 0 "$STATUS" "a spec of pure build instructions should pass: $OUT"$'\n'"$(cat "$RECORD")"
  pass "a spec of pure build instructions passes"
}

test_justified_fallback_passes() {
  local brief="$TMP_ROOT/justified.md"
  {
    cat "$FIXTURES/pure-build.md"
    printf '%s\n' '- A `needs-decision` line written before this change, with no round, still matches as today, so in-flight lanes are not refused for an old line. [justified: lanes already parked at a gate are not refused mid-run]'
  } > "$brief"
  run_check "$brief"
  expect_code 0 "$STATUS" "a justified fallback should pass: $OUT"$'\n'"$(cat "$RECORD")"
  assert_contains "$(cat "$RECORD")" $'# Justified bullets\nbullet 6 adds' \
    "the judge did not flag the fallback, so its justification was never tested"
  pass "the fallback bullet passes once it carries a justification"
}

test_pr_109_brief_flags_its_finding_id_filter
test_round_binding_brief_flags_its_no_round_fallback
test_pure_build_spec_passes
test_justified_fallback_passes

echo "# all fm-spec-intent-check-live-e2e tests passed"
