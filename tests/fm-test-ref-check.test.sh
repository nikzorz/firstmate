#!/usr/bin/env bash
# Regression tests for bin/fm-test-ref-check.sh, the stale test-case reference check.
# shellcheck disable=SC2016 # Fixture lines carry literal backticks and $test_root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-test-ref-check.sh"
# Fixture paths are spelled through $SPLIT and $OTHER so this file's own lines stay
# outside the pattern the repository-wide check scans.
SPLIT=fm-split
OTHER=fm-other
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-ref-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# A split suite: the case lives in the second file, the first keeps another.
make_split_repo() {
  local repo=$1
  mkdir -p "$repo/docs" "$repo/tests"
  git -C "$repo" init -q
  printf 'test_kept_case() {\n  :\n}\n' > "$repo/tests/$SPLIT.test.sh"
  printf 'test_moved_case() {\n  :\n}\n' > "$repo/tests/$SPLIT-2.test.sh"
  printf 'test_subshell_case() (\n  :\n)\ntest_commented_case() { # why\n  :\n}\ntest_one_line_case() { :; }\nfunction test_keyword_case {\n  :\n}\n' >> "$repo/tests/$SPLIT-2.test.sh"
}

test_repository_passes() {
  local out
  out=$("$CHECK") || fail "the check reports stale test references on this repository: $out"
  assert_contains "$out" "fm-test-ref-check: ok refs=" "the passing check did not report its reference count"
  pass "every tracked docs/ and tests/ reference to a test case names a file that defines it"
}

test_moved_case_credited_to_old_file_fails() {
  local repo="$TMP_ROOT/moved" out rc
  make_split_repo "$repo"
  printf '`tests/%s.test.sh` covers it (`test_moved_case`).\n' "$SPLIT" > "$repo/docs/note.md"
  printf '# See tests/%s.test.sh:test_moved_case for the fake.\n' "$SPLIT" > "$repo/tests/$OTHER.test.sh"
  git -C "$repo" add -A
  set +e
  out=$("$CHECK" --root "$repo" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a case credited to the file it moved out of should fail (rc=$rc): $out"
  assert_contains "$out" "docs/note.md:1: test_moved_case is not defined in tests/$SPLIT.test.sh" \
    "the doc reference was not reported with its location"
  assert_contains "$out" "tests/$OTHER.test.sh:1: test_moved_case" \
    "the test comment reference was not reported"
  pass "a doc line or test comment that credits a moved case to its old file fails"
}

test_correct_and_out_of_scope_references_pass() {
  local repo="$TMP_ROOT/clean" out
  make_split_repo "$repo"
  {
    printf '`tests/%s-2.test.sh` covers it (`test_moved_case`).\n' "$SPLIT"
    printf 'Covered by `tests/%s.test.sh` and `tests/%s-2.test.sh` (`test_moved_case`, `test_kept_case`).\n' "$SPLIT" "$SPLIT"
    printf 'Covered by fakes in `tests/%s.test.sh`.\n' "$SPLIT"
    printf '`tests/%s-2.test.sh` (`test_subshell_case`, `test_commented_case`, `test_one_line_case`, `test_keyword_case`).\n' "$SPLIT"
  } > "$repo/docs/note.md"
  printf 'fixture="$test_root/tests/%s.test.sh"\n' "$SPLIT" > "$repo/tests/$OTHER.test.sh"
  printf '`tests/%s.test.sh` covers it (`test_moved_case`).\n' "$SPLIT" > "$repo/docs/untracked.md"
  git -C "$repo" add docs/note.md tests
  out=$("$CHECK" --root "$repo") || fail "correct, file-only, variable, and untracked references should pass: $out"
  assert_contains "$out" "fm-test-ref-check: ok refs=7" "only the seven case names should count as references"
  pass "a case named with any file that defines it, in any definition form, passes; file-only, variable, and untracked lines are not checked"
}

test_repository_passes
test_moved_case_credited_to_old_file_fails
test_correct_and_out_of_scope_references_pass
