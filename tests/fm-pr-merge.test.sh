#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a squash merge supplies the forge's default message with agent
#       attribution stripped and human co-authors preserved
#   (j) a non-squash merge supplies no message, because replayed branch commits
#       keep their own
#   (k) a caller-written squash body is left alone, strip and reads stood down
#   (l) a caller-written squash subject keeps the caller's subject but still
#       gets the stripped default body underneath it
#   (m) a subject-only squash merge still refuses when the default body is
#       unreadable, rather than letting the forge compose one
#   (n) an unreadable default squash message refuses before merging
#   (o) a default squash message returned as a JSON null refuses before merging,
#       on the headline and on the body alike
#   (p) an all-digit repository name still gets a stripped body, because the
#       String! variables are sent as strings rather than typed fields
#   (q) a refusal carries the cause the forge CLI reported
#   (r) an already-merged PR merges with no default-message read attempted
#   (s) a merged state that cannot be read still takes the ordinary read path
#   (t) --auto is refused rather than freezing a supplied squash message
#   (u) --auto still merges when the caller owns the body
#
# The closing-keyword check is advisory: it reports and never blocks a merge, so
# every case below that finds a fault also proves the merge still ran.
#   (v) a task whose record names no issue merges with no PR-body read at all,
#       whether the row renders "links: none" or carries no links field at all
#   (w) a keyword the reference does not immediately follow warns, and merges
#   (x) a lowercase keyword is accepted, because the forge matches them case-insensitively
#   (y) every keyword spelling the forge acts on is accepted
#   (z) a shorter issue number does not satisfy a longer one it is a prefix of
#  (aa) a number with a letter after it is no reference, as GitHub reads it
#  (bb) a bare "#N" does not satisfy an issue in another repository
#  (cc) a warning names every issue the body fails to close, prescribes nothing,
#       and edits nothing
#  (dd) a record naming several issues is silent when every one of them is closed
#  (ee) a backlog that should have answered and did not warns, and merges
#  (ff) a not-found no readable store vouches for warns, and merges
#  (gg) a PR body that could not be read warns with its cause, and merges
#  (hh) an id a readable backlog does not hold merges unchanged and silently
#  (ii) a home with no tasks-axi merges, with one warning that the check was skipped
#  (jj) a repository name differing only in case is still the PR's own repository
#  (kk) an issue not observed closed right after this run's merge call is
#       reported as that, not as a defect; on a PR that landed earlier the
#       same open state is reported plainly as a miss
#  (ll) an issue the body does not close is not read back at all, because the
#       lagging-background-job explanation cannot apply to it
#  (mm) every named issue is read back only when the body read could not run,
#       and an already-merged PR narrows the same way while advising nothing
#  (nn) an issue that could not be read is reported as unknown
#  (oo) an armed --auto merge skips the post-merge read, which has nothing to see
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# assert_no_ere <ere> <file> <msg>: case-insensitive ERE must NOT match. The
# wordings these cases pin are prose shapes, which a fixed string cannot bound.
assert_no_ere() {
  ! grep -Eiq -- "$1" "$2" || fail "$3"
}

# System directories only, so a tool a case does not mock is genuinely absent
# from the sandbox rather than picked up from the developer's own PATH.
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# What run_pr_merge appends to the case's fakebin. Empty keeps the caller's PATH.
RUN_PATH_TAIL=

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # The closing-keyword gate reads the task's own backlog record before every
  # merge, so every case needs a record. "none" is the ordinary firstmate-repo
  # task that owns no issue; set_task_links gives a case one that does.
  printf 'none\n' > "$case_dir/task-links"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  [ -f "$FM_TEST_TASK_LINKS" ] || exit 1
  links=$(cat "$FM_TEST_TASK_LINKS")
  if [ "$links" = NOT_FOUND ]; then
    printf 'error: "Task \\"%s\\" not found in this backlog"\ncode: NOT_FOUND\n' "${2:-}" >&2
    exit 1
  fi
  if [ "$links" = NO_LINKS_FIELD ]; then
    printf '  id: %s\n' "${2:-}"
  elif [ "$links" = none ]; then
    printf '  id: %s\n  links: none\n' "${2:-}"
  else
    printf '  id: %s\n  links: "%s"\n' "${2:-}" "$links"
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# Set the links: value the tasks-axi mock renders, which quotes a non-empty
# value and prints a bare "none" for a row that links nothing. Args: case_dir value
set_task_links() {
  printf '%s\n' "$2" > "$1/task-links"
}

# Make the tasks-axi mock fail with no diagnosis at all, which is the answer a
# backlog that should have responded and did not gives.
drop_task_record() {
  rm -f "$1/task-links"
}

# Give the home a readable backlog store, which is what turns a NOT_FOUND from
# "the tool could not open anything" into "this backlog does not hold that id".
write_backlog_store() {
  printf '# Backlog\n' > "$1/backlog.md"
}

# The forge's default squash message for a task PR as this repo actually sees
# it: one agent-authored commit carrying its harness trailers, pipeline commits
# carrying none, and a hoisted co-author list mixing the captain with the agents.
write_default_message_fixture() {
  local case_dir=$1
  printf '%s\n' 'fix: do a thing (#7)' > "$case_dir/headline"
  cat > "$case_dir/body" <<'MSG'
* fix: do a thing

Some body text.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0TEST

* no-mistakes(review): tighten the thing

---------

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>
Co-authored-by: Claude Opus 5 <noreply@anthropic.com>
Co-authored-by: Codex <noreply@openai.com>
MSG
}

# gh-axi mock recording every invocation to a log file plus the squash message it
# was handed, and gh mock answering headRefOid for fm-pr-check.sh's pr_head
# lookup and the forge's default squash message. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  write_default_message_fixture "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
prev=
for arg in "$@"; do
  case "$prev" in
    --subject) printf '%s\n' "$arg" > "$FM_TEST_SUBJECT_OUT" ;;
    --body-file) cp "$arg" "$FM_TEST_BODY_OUT" ;;
  esac
  prev=$arg
done
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  write_default_message_fixture "$case_dir"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_SUBJECT_OUT="$case_dir/merge-subject" \
  FM_TEST_BODY_OUT="$case_dir/merge-body" \
  FM_TEST_GH_API_LOG="$case_dir/gh-api.log" \
  FM_TEST_TASK_LINKS="$case_dir/task-links" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_PR_BODY="$case_dir/pr-body" \
  FM_TEST_ISSUE_STATE="$case_dir/issue-state" \
  FM_HOME="$case_dir" \
  PATH="$case_dir/fakebin:${RUN_PATH_TAIL:-$PATH}" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qF 'pr merge 9 --repo example/repo --squash --subject fix: do a thing (#7) --body-file /' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, default --squash, and a supplied message"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qF ' --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qF 'pr merge 126 --repo my-org/my-repo --squash --subject ' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_squash_message_drops_agent_attribution() {
  local case_dir
  case_dir=$(make_case squash-message)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "squash-message: fm-pr-merge failed"

  assert_grep 'fix: do a thing (#7)' "$case_dir/merge-subject" \
    "squash-message: the forge's default headline was not supplied as the subject"
  assert_no_grep 'noreply@anthropic.com' "$case_dir/merge-body" \
    "squash-message: a claude co-author trailer survived into the squash message"
  assert_no_grep 'noreply@openai.com' "$case_dir/merge-body" \
    "squash-message: a codex co-author trailer survived into the squash message"
  assert_no_grep 'Claude-Session' "$case_dir/merge-body" \
    "squash-message: a session link survived into the squash message"
  assert_grep 'Co-authored-by: Kun Chen' "$case_dir/merge-body" \
    "squash-message: a human co-author was dropped along with the agent ones"
  assert_grep 'no-mistakes(review): tighten the thing' "$case_dir/merge-body" \
    "squash-message: the forge's commit list was not preserved"
  pass "fm-pr-merge supplies the forge's default squash message without agent attribution"
}

test_non_squash_merge_supplies_no_message() {
  local case_dir
  case_dir=$(make_case non-squash-message)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "non-squash-message: fm-pr-merge failed"

  grep -qxF 'pr merge 8 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "non-squash-message: a squash message was supplied for a merge-commit merge"
  assert_absent "$case_dir/merge-body" \
    "non-squash-message: a body file was written for a non-squash merge"
  pass "fm-pr-merge supplies no squash message when the caller merges without squashing"
}

test_caller_written_squash_body_is_kept() {
  local case_dir
  case_dir=$(make_case caller-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  # A caller who owns the body owns its trailers, so no default is even read.
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = api ] && exit 1
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/11 -- --squash --body 'mine, trailers and all' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "caller-body: fm-pr-merge failed"

  grep -qxF 'pr merge 11 --repo example/repo --squash --body mine, trailers and all' "$case_dir/gh-axi.log" \
    || fail "caller-body: a caller-written squash body was overridden"
  pass "fm-pr-merge leaves a caller-written squash body alone"
}

# The subject is not where agent trailers live, so a caller who names only the
# subject must still get the stripped body rather than a forge-composed one.
test_caller_written_subject_still_gets_stripped_body() {
  local case_dir
  case_dir=$(make_case caller-subject)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/25 -- --squash --subject 'chore: mine' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "caller-subject: fm-pr-merge failed"

  grep -qF 'pr merge 25 --repo example/repo --body-file /' "$case_dir/gh-axi.log" \
    || fail "caller-subject: no stripped body was supplied for a subject-only squash merge"
  grep -qF -- '--squash --subject chore: mine' "$case_dir/gh-axi.log" \
    || fail "caller-subject: the caller's subject was not forwarded"
  assert_no_grep '--subject fix: do a thing' "$case_dir/gh-axi.log" \
    "caller-subject: the forge headline was added alongside the caller's subject"
  assert_no_grep 'noreply@anthropic.com' "$case_dir/merge-body" \
    "caller-subject: a claude co-author trailer survived into the squash body"
  assert_no_grep 'noreply@openai.com' "$case_dir/merge-body" \
    "caller-subject: a codex co-author trailer survived into the squash body"
  assert_grep 'Co-authored-by: Kun Chen' "$case_dir/merge-body" \
    "caller-subject: a human co-author was dropped from the squash body"
  pass "fm-pr-merge supplies the stripped default body under a caller-written subject"
}

test_caller_written_subject_refuses_unreadable_body() {
  local case_dir rc
  case_dir=$(make_case caller-subject-unreadable-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = api ] && exit 1
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/26 -- --squash --subject 'chore: mine' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "caller-subject-unreadable-body: fm-pr-merge should refuse rather than let the forge compose the body"
  assert_grep 'default squash message could not be read' "$case_dir/stderr" \
    "caller-subject-unreadable-body: refusal did not name the unreadable default message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "caller-subject-unreadable-body: the merge ran with a forge-composed body"
  pass "fm-pr-merge refuses a subject-only squash merge when the default body cannot be read"
}

test_unreadable_default_message_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-message)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = api ] && exit 1
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-message: fm-pr-merge should refuse rather than let the forge compose one"
  assert_grep 'default squash message could not be read' "$case_dir/stderr" \
    "unreadable-message: refusal did not name the unreadable default message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unreadable-message: the merge ran without a supplied message"
  pass "fm-pr-merge refuses to merge when the forge's default squash message cannot be read"
}

# gh renders a JSON null field as the literal token `null` with a zero exit, so
# a null default message must land on the same refusal as a failed request.
# Args: case_dir headline_json_is_null(0|1)
add_gh_null_message_mock() {
  local case_dir=$1 headline_null=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText)
        if [ '$headline_null' = 1 ]; then printf 'null\n'; else printf 'fix: do a thing (#7)\n'; fi
        exit 0
        ;;
      *viewerMergeBodyText) printf 'null\n' ; exit 0 ;;
    esac
  done
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# The server rejects a String! variable it is handed as a JSON number, which is
# what gh's typed -F flag makes of an all-digit owner or repository name:
# `Could not coerce value 2048 to String`. This mock holds gh to that contract.
# Args: case_dir
add_gh_typed_string_strict_mock() {
  local case_dir=$1
  write_default_message_fixture "$case_dir"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  prev=
  for arg in "\$@"; do
    if [ "\$prev" = -F ]; then
      case "\$arg" in
        owner=*|repo=*)
          value=\${arg#*=}
          case "\$value" in
            ''|*[!0-9]*) ;;
            *)
              echo "gh: Variable of type String! was provided invalid value" >&2
              exit 1
              ;;
          esac
          ;;
      esac
    fi
    prev=\$arg
  done
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh mocks for the merged-state probe. Both record every `gh api` call so a test
# can prove the default-message read was never attempted, and both refuse that
# call so an attempted read would also fail the merge outright.
# Args: case_dir
add_gh_merged_state_mock() {
  local case_dir=$1
  write_default_message_fixture "$case_dir"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  printf '%s\n' "$*" >> "$FM_TEST_GH_API_LOG"
  exit 1
fi
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"--json state"*) printf '%s\n' MERGED ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# Args: case_dir
add_gh_unreadable_state_mock() {
  local case_dir=$1
  write_default_message_fixture "$case_dir"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"--json state"*) echo "gh: could not determine pull request state" >&2 ; exit 1 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh and gh-axi mocks for the closing-keyword gate: gh answers the PR body from
# a file the case writes and the issue state from another, and gh-axi records
# every invocation so a case can prove no PR body was ever edited.
# Args: case_dir head_sha
add_gh_issue_mocks() {
  local case_dir=$1 head=$2
  write_default_message_fixture "$case_dir"
  printf 'CLOSED\n' > "$case_dir/issue-state"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
prev=
for arg in "$@"; do
  case "$prev" in
    --subject) printf '%s\n' "$arg" > "$FM_TEST_SUBJECT_OUT" ;;
    --body-file) cp "$arg" "$FM_TEST_BODY_OUT" ;;
  esac
  prev=$arg
done
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *"--json body"*) cat "\$FM_TEST_PR_BODY" ; exit 0 ;;
    esac
    ;;
  "issue view") cat "\$FM_TEST_ISSUE_STATE" ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Args: case_dir name head_sha pr_body links
make_issue_case() {
  local case_dir
  case_dir=$(make_case "$1")
  mkdir -p "$case_dir/wt"
  add_gh_issue_mocks "$case_dir" "$2"
  printf '%s\n' "$3" > "$case_dir/pr-body"
  set_task_links "$case_dir" "$4"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

test_task_without_an_issue_merges_unchanged() {
  local case_dir
  case_dir=$(make_issue_case no-owning-issue aaaa111122223333444455556666777788889999 '' none)

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-owning-issue: fm-pr-merge refused a task that owns no issue"

  grep -qF 'pr merge 40 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-owning-issue: the merge did not run"
  assert_no_grep 'pr edit' "$case_dir/gh-axi.log" \
    "no-owning-issue: the check edited a PR body for a task that owns no issue"
  assert_no_grep '--json body' "$case_dir/gh.log" \
    "no-owning-issue: the PR body was read for a task that owns no issue"
  pass "fm-pr-merge merges a task that owns no issue without reading the PR body"
}

# A hand-edited backlog is a supported configuration, and a row written without
# a links field names no issue exactly as plainly as a rendered "links: none".
# Both belong on the silent path, so neither reports a missed check.
test_record_without_a_links_field_merges_silently() {
  local case_dir
  case_dir=$(make_issue_case no-links-field abcd333344445555666677778888999900001111 \
    '' NO_LINKS_FIELD)

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-links-field: a record with no links field blocked a merge"

  grep -qF 'pr merge 57 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-links-field: the merge did not run"
  assert_no_grep 'the closing-keyword check did not run' "$case_dir/stderr" \
    "no-links-field: a determinate no-issue answer reported a missed check"
  assert_no_grep 'does not close' "$case_dir/stderr" \
    "no-links-field: a record naming no issue produced a keyword warning"
  assert_no_grep '--json body' "$case_dir/gh.log" \
    "no-links-field: the PR body was read for a record that names no issue"
  pass "fm-pr-merge merges silently when the backlog record carries no links field"
}

test_keyword_not_adjacent_to_reference_warns() {
  local case_dir
  case_dir=$(make_issue_case keyword-not-adjacent bbbb111122223333444455556666777788889999 \
    'Close dota-oracle issues #148' \
    'doc:https://github.com/example/repo/issues/148')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "keyword-not-adjacent: the closing-keyword check blocked a merge"

  assert_grep 'does not close #148 (https://github.com/example/repo/issues/148)' "$case_dir/stderr" \
    "keyword-not-adjacent: the warning did not name the issue the body fails to close"
  assert_grep 'if the record only mentions it for context, nothing is wrong' "$case_dir/stderr" \
    "keyword-not-adjacent: the warning did not leave the judgment to a reader"
  assert_no_ere 'add .*(clos|fix|resolv)e?[sd]? .*#' "$case_dir/stderr" \
    "keyword-not-adjacent: the warning prescribed an edit the record cannot justify"
  assert_no_grep 'pr edit' "$case_dir/gh-axi.log" \
    "keyword-not-adjacent: the check rewrote the PR body"
  grep -qF 'pr merge 41 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "keyword-not-adjacent: the merge did not run"
  pass "fm-pr-merge warns and still merges when the reference does not follow the keyword"
}

test_lowercase_keyword_is_accepted() {
  local case_dir
  case_dir=$(make_issue_case lowercase-keyword cccc111122223333444455556666777788889999 \
    'closes #117' \
    'doc:https://github.com/example/repo/issues/117')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "lowercase-keyword: fm-pr-merge refused a well-formed lowercase keyword"

  assert_no_grep 'pr edit' "$case_dir/gh-axi.log" \
    "lowercase-keyword: a lowercase keyword was treated as missing"
  grep -qF 'pr merge 42 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "lowercase-keyword: the merge did not run"
  pass "fm-pr-merge accepts a closing keyword in any case"
}

# Every spelling GitHub itself acts on has to survive the form check, or the
# check reports a body that does close its issue.
test_every_acting_keyword_spelling_is_accepted() {
  local case_dir body i=0
  local -a spellings=(
    'Closes #7'
    'closes #7'
    'CLOSED #7'
    'Fixes #7'
    'resolved #7'
    'Closes #7.'
    'Closes example/repo#7'
    'Closes https://github.com/example/repo/issues/7'
  )
  for body in "${spellings[@]}"; do
    i=$((i + 1))
    case_dir=$(make_issue_case "spelling-$i" "$(printf 'b%039d' "$i")" \
      "$body" 'doc:https://github.com/example/repo/issues/7')

    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/6$i" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "spelling-$i: fm-pr-merge failed on a body reading \"$body\""

    assert_no_grep 'does not close' "$case_dir/stderr" \
      "spelling-$i: \"$body\" was not read as closing issue 7"
    grep -qF "pr merge 6$i --repo example/repo" "$case_dir/gh-axi.log" \
      || fail "spelling-$i: the merge did not run"
  done
  pass "fm-pr-merge accepts every closing-keyword spelling the forge acts on"
}

# GitHub needs a word boundary after the number, so "#117x" parses as no
# reference at all and closes nothing.
test_letter_after_the_issue_number_is_not_a_reference() {
  local case_dir
  case_dir=$(make_issue_case trailing-letter cccc222233334444555566667777888899990000 \
    'Closes #117x' \
    'doc:https://github.com/example/repo/issues/117')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "trailing-letter: the closing-keyword check blocked a merge"

  assert_grep 'does not close #117 (https://github.com/example/repo/issues/117)' "$case_dir/stderr" \
    "trailing-letter: Closes #117x was accepted for issue 117, which GitHub reads as no reference"
  grep -qF 'pr merge 55 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "trailing-letter: the merge did not run"
  pass "fm-pr-merge does not read a number with a letter after it as a reference"
}

test_unreadable_pr_body_warns_and_merges() {
  local case_dir
  case_dir=$(make_issue_case body-unreadable dddd222233334444555566667777888899990000 \
    'Closes #81' \
    'doc:https://github.com/example/repo/issues/81')
  printf 'OPEN\n' > "$case_dir/issue-state"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"--json body"*) echo "gh: HTTP 502: Bad gateway" >&2 ; exit 1 ;;
    esac
    ;;
  "issue view") cat "\$FM_TEST_ISSUE_STATE" ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "body-unreadable: an unreadable PR body blocked a merge"

  assert_grep 'the closing-keyword check did not run: the PR body could not be read' "$case_dir/stderr" \
    "body-unreadable: an unreadable PR body passed silently"
  assert_grep 'HTTP 502: Bad gateway' "$case_dir/stderr" \
    "body-unreadable: the cause the forge CLI reported was discarded"
  grep -qF 'pr merge 56 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "body-unreadable: the merge did not run"
  assert_grep 'issues/81 was not observed closed' "$case_dir/stderr" \
    "body-unreadable: no narrower set was knowable, so every named issue should have been read back"
  pass "fm-pr-merge warns and still merges when the PR body cannot be read"
}

test_shorter_issue_number_does_not_satisfy_a_longer_one() {
  local case_dir
  case_dir=$(make_issue_case number-prefix dddd111122223333444455556666777788889999 \
    'Closes #148' \
    'doc:https://github.com/example/repo/issues/14')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "number-prefix: the closing-keyword check blocked a merge"

  assert_grep 'does not close #14 (https://github.com/example/repo/issues/14)' "$case_dir/stderr" \
    "number-prefix: #148 was read as closing #14"
  pass "fm-pr-merge does not read #148 as a closing keyword for #14"
}

# A bare "#N" resolves against the PR's own repository, so it cannot close an
# issue that lives anywhere else no matter how well formed the line is.
test_cross_repository_bare_number_does_not_satisfy() {
  local case_dir
  case_dir=$(make_issue_case cross-repo-bare-number 5555aaaa22223333444455556666777788889999 \
    'Closes #5' \
    'doc:https://github.com/acme/api/issues/5')

  run_pr_merge "$case_dir" task-x1 https://github.com/acme/site/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "cross-repo-bare-number: the closing-keyword check blocked a merge"

  assert_grep 'does not close acme/api#5' "$case_dir/stderr" \
    "cross-repo-bare-number: a bare #5 was accepted for an issue in another repository"
  pass "fm-pr-merge does not read a bare #N as closing an issue in another repository"
}

test_several_issues_each_named_in_the_warning() {
  local case_dir
  case_dir=$(make_issue_case several-issues eeee111122223333444455556666777788889999 \
    'Close dota-oracle issues #148 and #117' \
    'doc:https://github.com/example/repo/issues/148,doc:https://github.com/example/repo/issues/117')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "several-issues: the closing-keyword check blocked a merge"

  assert_grep 'does not close #148 (https://github.com/example/repo/issues/148)' "$case_dir/stderr" \
    "several-issues: the warning did not name the first issue the body fails to close"
  assert_grep 'does not close #117 (https://github.com/example/repo/issues/117)' "$case_dir/stderr" \
    "several-issues: the warning did not name the second issue the body fails to close"
  assert_no_grep 'pr edit' "$case_dir/gh-axi.log" \
    "several-issues: the check rewrote the PR body"
  grep -qF 'pr merge 44 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "several-issues: the merge did not run"
  pass "fm-pr-merge names every issue the body fails to close and still merges"
}

test_several_issues_all_closed_still_merge() {
  local case_dir
  case_dir=$(make_issue_case several-issues-ok ffff111122223333444455556666777788889999 \
    'Closes #148 and closes #117' \
    'doc:https://github.com/example/repo/issues/148,doc:https://github.com/example/repo/issues/117')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "several-issues-ok: fm-pr-merge failed on a body that closes every issue named"

  assert_no_grep 'pr edit' "$case_dir/gh-axi.log" \
    "several-issues-ok: the check edited a PR body that was already well formed"
  grep -qF 'pr merge 45 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "several-issues-ok: the merge did not run"
  pass "fm-pr-merge merges when every issue the record names is already closed by the body"
}

test_unreadable_task_record_warns() {
  local case_dir
  case_dir=$(make_issue_case unreadable-record 1111111122223333444455556666777788889999 \
    'Closes #9' none)
  drop_task_record "$case_dir"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/46 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unreadable-record: an unreadable backlog blocked a merge"

  assert_grep 'the closing-keyword check did not run' "$case_dir/stderr" \
    "unreadable-record: an unreadable record passed silently"
  grep -qF 'pr merge 46 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "unreadable-record: the merge did not run"
  pass "fm-pr-merge warns and still merges when the task's own record cannot be read"
}

# A not-found the backlog store itself cannot vouch for is still indeterminate:
# tasks-axi answers NOT_FOUND both for an absent id and for a store it never
# opened, so absence counts only once the configured store is a readable file.
test_not_found_without_a_readable_store_warns() {
  local case_dir
  case_dir=$(make_issue_case not-found-no-store 6666aaaa22223333444455556666777788889999 \
    'Closes #9' NOT_FOUND)

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/50 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "not-found-no-store: an untrusted not-found blocked a merge"

  assert_grep 'the closing-keyword check did not run' "$case_dir/stderr" \
    "not-found-no-store: a not-found from an unopened store passed as a checked absence"
  assert_grep 'is not a readable file' "$case_dir/stderr" \
    "not-found-no-store: the warning did not name the store it could not vouch for"
  grep -qF 'pr merge 50 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "not-found-no-store: the merge did not run"
  pass "fm-pr-merge warns and still merges on a not-found its backlog store cannot vouch for"
}

# An id a readable backlog genuinely does not hold is a determinate answer: the
# task owns no issue, which is the ordinary firstmate-repo case and must be as
# quiet as a row that links none.
test_determinate_not_found_merges_unchanged() {
  local case_dir
  case_dir=$(make_issue_case not-found-determinate 7777aaaa22223333444455556666777788889999 \
    'Closes #9' NOT_FOUND)
  write_backlog_store "$case_dir"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "not-found-determinate: fm-pr-merge refused a task the backlog does not hold"

  grep -qF 'pr merge 51 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "not-found-determinate: the merge did not run"
  assert_no_grep '--json body' "$case_dir/gh.log" \
    "not-found-determinate: the PR body was read for a task that owns no issue"
  assert_no_grep 'the closing-keyword check did not run' "$case_dir/stderr" \
    "not-found-determinate: the common no-owning-issue path became noisy"
  pass "fm-pr-merge merges unchanged and silently when the backlog does not hold the task"
}

# A home without tasks-axi is a supported fallback, so the merge proceeds; the
# warning is what keeps that from being a silent no-op.
test_missing_tasks_axi_merges_with_a_warning() {
  local case_dir rc
  case_dir=$(make_issue_case no-tasks-axi 8888aaaa22223333444455556666777788889999 \
    'Closes #9' 'doc:https://github.com/example/repo/issues/9')
  rm -f "$case_dir/fakebin/tasks-axi"

  RUN_PATH_TAIL=$BASE_PATH
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  RUN_PATH_TAIL=

  expect_code 0 "$rc" "no-tasks-axi: fm-pr-merge bricked a merge in a home with no backlog tool"
  grep -qF 'pr merge 52 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-tasks-axi: the merge did not run"
  assert_grep 'the closing-keyword check did not run' "$case_dir/stderr" \
    "no-tasks-axi: the skipped check passed silently"
  assert_grep 'tasks-axi is not available in this home' "$case_dir/stderr" \
    "no-tasks-axi: the warning did not say why the check was skipped"
  pass "fm-pr-merge merges with one warning when the backlog tool is unavailable"
}

# GitHub resolves owner and repository case-insensitively, so a hand-typed
# "Repo" in a backlog row still names the PR's own repository and a bare "#N"
# still closes it.
test_repository_case_difference_is_still_the_same_repo() {
  local case_dir
  case_dir=$(make_issue_case repo-case 9999aaaa22223333444455556666777788889999 \
    'Closes #79' \
    'doc:https://github.com/example/repo/issues/79')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/Repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "repo-case: a case difference in the repository name refused a body GitHub would honor"

  grep -qF 'pr merge 53 --repo example/Repo' "$case_dir/gh-axi.log" \
    || fail "repo-case: the merge did not run"
  pass "fm-pr-merge reads a repository name that differs only in case as the same repository"
}

# An issue read that did not answer is unknown, never the negative outcome: the
# same rule this repo applies to an unconfirmed fm-send.
test_unreadable_issue_is_reported_as_unknown() {
  local case_dir
  case_dir=$(make_issue_case issue-unreadable aaaabbbb22223333444455556666777788889999 \
    'Closes #80' \
    'doc:https://github.com/example/repo/issues/80')
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *viewerMergeHeadlineText) cat '$case_dir/headline' ; exit 0 ;;
      *viewerMergeBodyText) cat '$case_dir/body' ; exit 0 ;;
    esac
  done
  exit 1
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"--json body"*) cat "\$FM_TEST_PR_BODY" ; exit 0 ;;
    esac
    ;;
  "issue view") echo "gh: HTTP 404: Not Found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "issue-unreadable: fm-pr-merge failed a merge whose body was well formed"

  assert_grep 'issues/80 could not be read, so whether it closed is unknown' "$case_dir/stderr" \
    "issue-unreadable: an unreadable issue was not reported as unknown"
  assert_no_grep 'was not observed closed' "$case_dir/stderr" \
    "issue-unreadable: an unconfirmed read was reported as a state that was observed"
  pass "fm-pr-merge reports an issue it could not read as unknown, not as left open"
}

test_issue_not_observed_closed_after_merge_is_reported() {
  local case_dir
  case_dir=$(make_issue_case issue-left-open 2222111122223333444455556666777788889999 \
    'Closes #77' \
    'doc:https://github.com/example/repo/issues/77')
  printf 'OPEN\n' > "$case_dir/issue-state"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "issue-left-open: fm-pr-merge failed a merge whose body was well formed"

  grep -qF 'pr merge 47 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "issue-left-open: the merge did not run"
  assert_grep 'issues/77 was not observed closed when read just after the merge call' "$case_dir/stderr" \
    "issue-left-open: an issue that did not read CLOSED went unreported"
  assert_grep 'background job' "$case_dir/stderr" \
    "issue-left-open: the report asserted a defect instead of naming why the read can be early"
  assert_no_grep 'landed before this run' "$case_dir/stderr" \
    "issue-left-open: a merge this run called was reported as a settled miss"
  assert_no_ere '(still open|left open|open) after this merge' "$case_dir/stderr" \
    "issue-left-open: the report called an early read a settled open state"
  pass "fm-pr-merge reports an issue it did not observe closed without calling it a defect"
}

# An issue the body does not close will never close on its own, so the
# background-job explanation is never the right one for it. The hedged pre-merge
# warning already said what can be said, and the post-merge read skips it.
test_issue_the_body_does_not_close_is_not_read_back() {
  local case_dir
  case_dir=$(make_issue_case context-only-link 4444bbbb22223333444455556666777788889999 \
    'No keyword here at all' \
    'doc:https://github.com/example/repo/issues/200')
  printf 'OPEN\n' > "$case_dir/issue-state"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "context-only-link: the closing-keyword check blocked a merge"

  grep -qF 'pr merge 58 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "context-only-link: the merge did not run"
  assert_grep 'does not close #200 (https://github.com/example/repo/issues/200)' "$case_dir/stderr" \
    "context-only-link: the pre-merge warning did not name the issue the body fails to close"
  assert_no_grep 'issue view' "$case_dir/gh.log" \
    "context-only-link: an issue the body does not close was read back after the merge"
  assert_no_grep 'was not observed closed' "$case_dir/stderr" \
    "context-only-link: an issue the body never asked to close was blamed on a lagging background job"
  pass "fm-pr-merge does not read back an issue its body does not close"
}

# An already-merged PR still gets its body read, so the post-merge report covers
# only the issues that body asks the forge to close. The advice is what the
# landed PR is past: nothing said now could change the body it merged with. Its
# close job has also had its whole chance, so an open issue there is a real miss
# rather than a read that arrived early.
test_already_merged_pr_narrows_without_advising() {
  local case_dir
  case_dir=$(make_issue_case merged-narrowing 5555bbbb22223333444455556666777788889999 \
    'Closes #201' \
    'doc:https://github.com/example/repo/issues/201,doc:https://github.com/example/repo/issues/202')
  printf 'OPEN\n' > "$case_dir/issue-state"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"--json state"*) printf '%s\n' MERGED ; exit 0 ;;
      *"--json body"*) cat "\$FM_TEST_PR_BODY" ; exit 0 ;;
    esac
    ;;
  "issue view") cat "\$FM_TEST_ISSUE_STATE" ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "merged-narrowing: fm-pr-merge refused a pull request that had already merged"

  assert_grep 'issues/201 is still open and this PR landed before this run' "$case_dir/stderr" \
    "merged-narrowing: an issue a landed PR left open was not reported as a real finding"
  assert_no_grep 'may still close on its own' "$case_dir/stderr" \
    "merged-narrowing: a miss the forge has already had its chance at was hedged as still pending"
  assert_no_grep 'issues/202' "$case_dir/stderr" \
    "merged-narrowing: an issue the body never asked to close was reported after the merge"
  assert_no_grep "does not close" "$case_dir/stderr" \
    "merged-narrowing: a landed PR was advised to fix the body it already merged with"
  assert_no_ere 'after this merge' "$case_dir/stderr" \
    "merged-narrowing: the report claimed a merge this run did not perform"
  pass "fm-pr-merge narrows the post-merge read on an already-merged PR without advising"
}

test_armed_auto_merge_reports_no_open_issue() {
  local case_dir
  case_dir=$(make_issue_case auto-merge-open-issue 3333aaaa22223333444455556666777788889999 \
    'Closes #78' \
    'doc:https://github.com/example/repo/issues/78')
  printf 'OPEN\n' > "$case_dir/issue-state"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/48 -- --squash --auto --body 'mine' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "auto-merge-open-issue: fm-pr-merge refused a caller who owns the message"

  grep -qF 'pr merge 48 --repo example/repo --squash --auto' "$case_dir/gh-axi.log" \
    || fail "auto-merge-open-issue: auto-merge was not armed"
  assert_no_grep 'issue view' "$case_dir/gh.log" \
    "auto-merge-open-issue: the post-merge issue read ran for a merge that has not landed"
  assert_no_grep 'was not observed closed' "$case_dir/stderr" \
    "auto-merge-open-issue: an armed auto-merge was reported as having left the issue open"
  pass "fm-pr-merge skips the post-merge issue read when the merge is only armed"
}

test_already_merged_pr_skips_the_message_read() {
  local case_dir
  case_dir=$(make_case already-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  add_gh_merged_state_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh-api.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/29 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "already-merged: fm-pr-merge refused a pull request that had already merged"

  grep -qxF 'pr merge 29 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "already-merged: gh-axi was not left to report the merge itself"
  [ ! -s "$case_dir/gh-api.log" ] \
    || fail "already-merged: a default-message read was attempted for an already-merged pull request"
  assert_absent "$case_dir/merge-body" \
    "already-merged: a squash body was supplied for a pull request with nothing to merge"
  pass "fm-pr-merge skips the default-message read when the pull request already merged"
}

test_unreadable_merged_state_takes_the_ordinary_path() {
  local case_dir
  case_dir=$(make_case unreadable-state)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_gh_unreadable_state_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/30 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unreadable-state: fm-pr-merge did not fall through to the ordinary read"

  grep -qF 'pr merge 30 --repo example/repo --squash --subject ' "$case_dir/gh-axi.log" \
    || fail "unreadable-state: an unreadable merged state was taken for already-merged"
  assert_no_grep 'noreply@anthropic.com' "$case_dir/merge-body" \
    "unreadable-state: a claude co-author trailer survived into the squash body"
  assert_grep 'Co-authored-by: Kun Chen' "$case_dir/merge-body" \
    "unreadable-state: a human co-author was dropped from the squash body"
  pass "fm-pr-merge treats an unreadable merged state as not merged and still strips the body"
}

test_auto_merge_refused_when_message_would_be_supplied() {
  local case_dir rc
  case_dir=$(make_case auto-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 -- --squash --auto \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "auto-merge: fm-pr-merge should refuse rather than freeze the squash message"
  assert_grep '--auto would freeze this squash message' "$case_dir/stderr" \
    "auto-merge: the refusal did not name the frozen message as the reason"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "auto-merge: auto-merge was armed with a message read at arm time"
  pass "fm-pr-merge refuses --auto rather than arming auto-merge with a frozen squash message"
}

test_auto_merge_allowed_when_caller_owns_the_body() {
  local case_dir
  case_dir=$(make_case auto-merge-own-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 -- --squash --auto --body 'mine, trailers and all' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "auto-merge-own-body: fm-pr-merge refused a caller who owns the message"

  grep -qxF 'pr merge 32 --repo example/repo --squash --auto --body mine, trailers and all' "$case_dir/gh-axi.log" \
    || fail "auto-merge-own-body: a caller-owned message was not armed unchanged"
  pass "fm-pr-merge arms --auto when the caller owns the squash body"
}

test_numeric_repository_name_still_gets_stripped_body() {
  local case_dir
  case_dir=$(make_case numeric-repo)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  add_gh_typed_string_strict_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/2048/pull/27 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "numeric-repo: fm-pr-merge refused a repository whose name is all digits"

  grep -qF 'pr merge 27 --repo example/2048 --squash --subject ' "$case_dir/gh-axi.log" \
    || fail "numeric-repo: no default squash message was supplied"
  assert_no_grep 'noreply@anthropic.com' "$case_dir/merge-body" \
    "numeric-repo: a claude co-author trailer survived into the squash body"
  assert_grep 'Co-authored-by: Kun Chen' "$case_dir/merge-body" \
    "numeric-repo: a human co-author was dropped from the squash body"
  pass "fm-pr-merge reads the default squash message for an all-digit repository name"
}

test_refusal_carries_the_forge_cli_cause() {
  local case_dir rc
  case_dir=$(make_case refusal-cause)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  echo "gh: Bad credentials (HTTP 401)" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/28 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refusal-cause: fm-pr-merge should still refuse"
  assert_grep 'default squash message could not be read' "$case_dir/stderr" \
    "refusal-cause: the fixed refusal was replaced rather than kept"
  assert_grep 'Bad credentials (HTTP 401)' "$case_dir/stderr" \
    "refusal-cause: the cause the forge CLI reported was discarded"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "refusal-cause: the merge ran despite an unreadable default message"
  pass "fm-pr-merge carries the forge CLI's cause into an unreadable-message refusal"
}

test_null_default_headline_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case null-headline)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  add_gh_null_message_mock "$case_dir" 1
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "null-headline: fm-pr-merge should refuse a null default headline"
  assert_grep 'default squash message could not be read' "$case_dir/stderr" \
    "null-headline: refusal did not name the unreadable default message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "null-headline: the merge ran with a null subject"
  pass "fm-pr-merge refuses when the forge returns a null default headline"
}

test_null_default_body_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case null-body)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  add_gh_null_message_mock "$case_dir" 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "null-body: fm-pr-merge should refuse a null default body"
  assert_grep 'default squash message could not be read' "$case_dir/stderr" \
    "null-body: refusal did not name the unreadable default message"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "null-body: the merge ran with a null body"
  pass "fm-pr-merge refuses when the forge returns a null default body"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_squash_message_drops_agent_attribution
test_non_squash_merge_supplies_no_message
test_caller_written_squash_body_is_kept
test_caller_written_subject_still_gets_stripped_body
test_caller_written_subject_refuses_unreadable_body
test_unreadable_default_message_refuses_before_merge
test_null_default_headline_refuses_before_merge
test_null_default_body_refuses_before_merge
test_numeric_repository_name_still_gets_stripped_body
test_refusal_carries_the_forge_cli_cause
test_already_merged_pr_skips_the_message_read
test_unreadable_merged_state_takes_the_ordinary_path
test_auto_merge_refused_when_message_would_be_supplied
test_auto_merge_allowed_when_caller_owns_the_body
test_task_without_an_issue_merges_unchanged
test_record_without_a_links_field_merges_silently
test_keyword_not_adjacent_to_reference_warns
test_lowercase_keyword_is_accepted
test_every_acting_keyword_spelling_is_accepted
test_letter_after_the_issue_number_is_not_a_reference
test_unreadable_pr_body_warns_and_merges
test_shorter_issue_number_does_not_satisfy_a_longer_one
test_cross_repository_bare_number_does_not_satisfy
test_several_issues_each_named_in_the_warning
test_several_issues_all_closed_still_merge
test_unreadable_task_record_warns
test_not_found_without_a_readable_store_warns
test_determinate_not_found_merges_unchanged
test_missing_tasks_axi_merges_with_a_warning
test_repository_case_difference_is_still_the_same_repo
test_issue_not_observed_closed_after_merge_is_reported
test_issue_the_body_does_not_close_is_not_read_back
test_already_merged_pr_narrows_without_advising
test_unreadable_issue_is_reported_as_unknown
test_armed_auto_merge_reports_no_open_issue
