#!/usr/bin/env bash
# Regression tests for bin/fm-nm-post-test-retest.sh, the post-Lint gate that
# re-runs tests for scripts a Document, Lint, or gate fix round changed after Test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-nm-post-test-retest.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-post-test-retest) || fail "could not create the fixture root"
fm_git_identity

# commit_touching <repo> <subject> <path>...: write each path and commit them.
commit_touching() {
  local repo=$1 subject=$2 path
  shift 2
  for path in "$@"; do
    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$subject" >> "$repo/$path"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$subject"
}

# A repo whose tests/ holds a colocated test for every script but e.sh.
make_repo() {
  local repo=$1 name
  fm_git_init_commit "$repo"
  for name in a b c d f; do
    mkdir -p "$repo/tests"
    printf '#!/usr/bin/env bash\n' > "$repo/tests/$name.test.sh"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add colocated tests"
}

test_selects_only_post_test_fix_commits() {
  local repo="$TMP_ROOT/select" out err
  make_repo "$repo"
  commit_touching "$repo" "fix(bin): author change" bin/a.sh
  commit_touching "$repo" "no-mistakes(review): review fix" bin/b.sh
  commit_touching "$repo" "no-mistakes(document): doc fix" bin/c.sh docs/x.md
  commit_touching "$repo" "no-mistakes(lint): lint fix" tests/d.test.sh bin/e.sh bin/sub/g.sh
  commit_touching "$repo" "no-mistakes(gate.lint.post-test-retest): gate repair" bin/f.sh
  out=$(cd "$repo" && "$GATE" --list 2>"$TMP_ROOT/select.err") || fail "--list failed: $out"
  err=$(cat "$TMP_ROOT/select.err")
  assert_equals "$(printf 'tests/c.test.sh\ntests/d.test.sh\ntests/f.test.sh')" "$out" \
    "only the Document, Lint, and gate commits after the last other commit should select tests"
  assert_contains "$err" "no tests/e.test.sh for bin/e.sh; skipped" \
    "a touched script with no colocated test was not reported"
  pass "the gate selects colocated tests for the Document, Lint, and gate repair commits at the tip"
}

test_no_post_test_commits_passes() {
  local repo="$TMP_ROOT/none" out
  make_repo "$repo"
  commit_touching "$repo" "no-mistakes(lint): earlier lint fix" bin/c.sh
  commit_touching "$repo" "no-mistakes(test): test fix" bin/a.sh
  out=$(cd "$repo" && "$GATE") || fail "a tip with no post-test fix commit should pass: $out"
  assert_equals "fm-nm-post-test-retest: no tests to re-run" "$out" \
    "the passing gate did not say it had nothing to re-run"
  pass "a fix commit that a later Test step already covered selects nothing and passes"
}

test_runs_selected_tests_and_keeps_their_status() {
  local repo="$TMP_ROOT/run" out rc
  make_repo "$repo"
  mkdir -p "$repo/bin"
  printf '#!/usr/bin/env bash\nprintf "ran %%s\\n" "$*"\nexit 3\n' > "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add the runner"
  commit_touching "$repo" "no-mistakes(lint): lint fix" tests/d.test.sh
  out=$(cd "$repo" && "$GATE" 2>&1); rc=$?
  assert_equals 3 "$rc" "the gate did not exit with the test runner's status"
  assert_contains "$out" "ran tests/d.test.sh" "the gate did not hand the selected test to the repository's runner"
  pass "the gate runs the selected tests through the repository's own runner and exits with its status"
}

test_selects_only_post_test_fix_commits
test_no_post_test_commits_passes
test_runs_selected_tests_and_keeps_their_status
