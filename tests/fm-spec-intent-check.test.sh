#!/usr/bin/env bash
# bin/fm-spec-intent-check.sh splits a brief's `## Firstmate spec` into
# numbered bullets, refuses an unjustified flagged bullet, lets a bullet carrying
# `[justified: <reason>]` through, refuses rather than passes whenever an
# installed judge cannot give one well-formed answer per bullet, and skips with
# a warning when no judge is installed. The judge here is
# tests/spec-intent-judge-stub.sh; tests/fm-spec-intent-check-live-e2e.test.sh
# drives the real model over the same fixture briefs.
# shellcheck disable=SC2016 # Backticks are literal Markdown in brief text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-spec-intent-check.sh"
FIXTURES="$ROOT/tests/spec-intent-fixtures"
TMP_ROOT=$(fm_test_tmproot fm-spec-intent-check)
LOG="$TMP_ROOT/judge.log"
RECORD="$TMP_ROOT/record.txt"

run_check() {  # <brief> -> sets OUT and STATUS
  rm -f "$LOG" "$RECORD"
  OUT=$(FM_STUB_JUDGE_LOG="$LOG" "$CHECK" "$1" "$RECORD" 2>&1)
  STATUS=$?
}

brief_with_spec() {  # <name> <spec-body> -> prints the brief path
  local path="$TMP_ROOT/$1.md"
  printf '# Task\n## Captain'"'"'s intent\nFix the widget.\n\n## Firstmate spec\n%s\n' "$2" > "$path"
  printf '%s\n' "$path"
}

answer_file() {  # <name> <answer> -> prints the answer path
  local path="$TMP_ROOT/$1.answer"
  printf '%s' "$2" > "$path"
  printf '%s\n' "$path"
}

test_fixture_briefs_flag_their_extra_bullet() {
  FM_STUB_JUDGE_FLAG='<finding-id>' run_check "$FIXTURES/nm-findings-reader.md"
  expect_code 1 "$STATUS" "the PR 109 brief should be refused: $OUT"
  assert_contains "$OUT" 'bullet 2 adds matched the stub pattern: New `bin/fm-nm-findings.sh <run-id> [--step <step>] [<finding-id>...]`' \
    "the refusal did not name the per-finding-id bullet"
  assert_contains "$(cat "$LOG")" '7. When the change is committed' "the judge was not sent every bullet numbered in order"

  FM_STUB_JUDGE_FLAG='with no round, still matches' run_check "$FIXTURES/merge-guard-round-ids.md"
  expect_code 1 "$STATUS" "the round-binding brief should be refused: $OUT"
  assert_contains "$OUT" 'bullet 3 adds matched the stub pattern: A `needs-decision` line written before this change, with no round' \
    "the refusal did not name the no-round fallback bullet"
  assert_contains "$(cat "$RECORD")" '# Unjustified bullets' "the record does not show the refused bullet"
  pass "each fixture brief is refused naming its extra bullet"
}

test_pure_build_spec_passes() {
  run_check "$FIXTURES/pure-build.md"
  expect_code 0 "$STATUS" "a spec of pure build instructions should pass: $OUT"
  assert_contains "$(cat "$RECORD")" 'result: pass' "the record does not show the pass"
  pass "a spec of pure build instructions passes"
}

test_justified_bullet_passes() {
  local brief
  brief=$(brief_with_spec justified "$(printf -- '- Edit `bin/widget.sh`.\n- Old widgets still work. [justified: parked lanes use them]')")
  FM_STUB_JUDGE_FLAG='Old widgets' run_check "$brief"
  expect_code 0 "$STATUS" "a flagged bullet carrying a justification should pass: $OUT"
  assert_contains "$(cat "$RECORD")" '# Justified bullets' "the record does not show the justified flag"

  brief=$(brief_with_spec empty-reason "$(printf -- '- Edit `bin/widget.sh`.\n- Old widgets still work. [justified: ]')")
  FM_STUB_JUDGE_FLAG='Old widgets' run_check "$brief"
  expect_code 1 "$STATUS" "a justification with no reason should not pass: $OUT"
  pass "a justified bullet passes and an empty justification does not"
}

test_bullets_keep_their_continuation_lines() {
  local brief
  brief=$(brief_with_spec continuation "$(printf -- 'Lead paragraph\nwrapped here.\n\n- First bullet\n  continues indented\nand unindented.\n* Second bullet.\n\n  Indented after a gap.\n1. Third bullet.\nTrailing paragraph.')")
  run_check "$brief"
  expect_code 0 "$STATUS" "the stub answers ok for every bullet: $OUT"
  assert_contains "$(cat "$LOG")" '1. Lead paragraph wrapped here.' "a leading paragraph is not its own bullet"
  assert_contains "$(cat "$LOG")" '2. First bullet continues indented and unindented.' "continuation lines were not joined"
  assert_contains "$(cat "$LOG")" '3. Second bullet. Indented after a gap.' "an indented line after a gap did not continue its bullet"
  assert_contains "$(cat "$LOG")" '4. Third bullet. Trailing paragraph.' "a numbered item was not a bullet"
  pass "each bullet carries its continuation lines"
}

test_judge_runs_without_tools() {
  run_check "$FIXTURES/pure-build.md"
  assert_contains "$(head -n 1 "$LOG")" '[--tools] []' "the judge was given tools"
  assert_contains "$(head -n 1 "$LOG")" '[--safe-mode]' "the judge loaded customizations"
  pass "the judge runs with no tools in safe mode"
}

expect_cannot_run() {  # <label> <expected-detail>
  expect_code 2 "$STATUS" "$1 should refuse as unable to judge: $OUT"
  assert_contains "$OUT" "could not judge" "$1 refusal does not say the check could not judge"
  assert_contains "$(cat "$RECORD")" "result: cannot-run: $2" "$1 record does not name why"
}

test_skips_when_the_judge_is_not_installed() {
  OUT=$(FM_SPEC_INTENT_CHECK_CLAUDE_BIN="$TMP_ROOT/no-such-claude" "$CHECK" "$FIXTURES/pure-build.md" "$RECORD" 2>&1)
  STATUS=$?
  expect_code 3 "$STATUS" "a judge that is not installed should skip the check: $OUT"
  assert_contains "$OUT" "warning: the spec-intent check of $FIXTURES/pure-build.md was skipped" \
    "the skip does not warn that the check did not run"
  assert_contains "$(cat "$RECORD")" "result: skipped: $TMP_ROOT/no-such-claude is not installed" "the record does not name the skip"
  pass "a judge that is not installed skips the check with a warning"
}

test_refuses_when_the_judge_cannot_answer() {
  FM_STUB_JUDGE_EXIT=3 run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "a failing judge" 'the judge exited 3'

  FM_STUB_JUDGE_ANSWER=$(answer_file prose "$(printf 'Here is my verdict:\n1 ok\n2 ok\n3 ok\n4 ok\n5 ok\n')") run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "an answer with prose" 'unexpected answer line: Here is my verdict:'

  FM_STUB_JUDGE_ANSWER=$(answer_file short "$(printf '1 ok\n2 ok\n3 ok\n4 ok\n')") run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "an answer missing a bullet" 'bullet 5 has no answer'

  FM_STUB_JUDGE_ANSWER=$(answer_file twice "$(printf '1 ok\n1 ok\n2 ok\n3 ok\n4 ok\n5 ok\n')") run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "an answer repeating a bullet" 'bullet 1 answered out of range or twice'

  FM_STUB_JUDGE_ANSWER=$(answer_file range "$(printf '1 ok\n2 ok\n3 ok\n4 ok\n5 ok\n6 ok\n')") run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "an answer past the last bullet" 'bullet 6 answered out of range or twice'

  FM_STUB_JUDGE_ANSWER=$(answer_file empty '') run_check "$FIXTURES/pure-build.md"
  expect_cannot_run "an empty answer" 'bullet 1 has no answer'
  pass "an installed judge that fails or answers malformed refuses instead of passing"
}

test_refuses_a_brief_without_both_subsections() {
  local brief="$TMP_ROOT/legacy.md"
  printf '# Task\nFix the widget.\n' > "$brief"
  run_check "$brief"
  expect_code 2 "$STATUS" "a brief with no spec should refuse: $OUT"
  [ ! -e "$LOG" ] || fail "the judge was asked about a brief with no spec"
  pass "a brief without both subsections refuses before asking the judge"
}

test_fixture_briefs_flag_their_extra_bullet
test_pure_build_spec_passes
test_justified_bullet_passes
test_bullets_keep_their_continuation_lines
test_judge_runs_without_tools
test_skips_when_the_judge_is_not_installed
test_refuses_when_the_judge_cannot_answer
test_refuses_a_brief_without_both_subsections

echo "# all fm-spec-intent-check tests passed"
