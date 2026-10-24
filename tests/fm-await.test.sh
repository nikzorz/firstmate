#!/usr/bin/env bash
# tests/fm-await.test.sh - bin/fm-await.sh, the one-call bounded wait, driven
# with real files and real processes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-await)
AWAIT="$ROOT/bin/fm-await.sh"

test_file_line_already_present_returns_at_once() {
  local f out start
  f="$TMP_ROOT/present.log"
  printf 'build started\nPASS 12 tests\nPASS again\n' > "$f"
  start=$SECONDS
  out=$(bash "$AWAIT" "$f" --match '^PASS' --max 30 2>&1) || fail "await failed: $out"
  assert_equals "PASS 12 tests" "$out" "the first matching line"
  [ $((SECONDS - start)) -le 2 ] || fail "a present line still waited"
  pass "fm-await: a matching line already in the file returns at once with that line"
}

test_file_line_written_later_is_seen() {
  local f out
  f="$TMP_ROOT/later.log"
  ( sleep 2; printf 'done [at=1]: ready\n' >> "$f" ) &
  out=$(bash "$AWAIT" "$f" --match '^done' --max 20 2>&1) || fail "await failed: $out"
  assert_equals "done [at=1]: ready" "$out" "the line written while waiting"
  wait
  pass "fm-await: a file that does not exist yet is waited for until its line lands"
}

test_cap_reports_still_waiting() {
  local f out rc start
  f="$TMP_ROOT/never.log"
  printf 'nothing here\n' > "$f"
  start=$SECONDS
  rc=0; out=$(bash "$AWAIT" "$f" --match '^never' --max 2 2>&1) || rc=$?
  expect_code 1 "$rc" "a cap that passes first"
  assert_contains "$out" "still waiting" "the cap message"
  [ $((SECONDS - start)) -le 5 ] || fail "the call ran past its --max"
  pass "fm-await: when --max passes first the call prints still waiting and exits 1 near its cap"
}

test_pid_exit_is_seen_and_the_wait_never_matches_itself() {
  local pid out rc
  sleep 2 &
  pid=$!
  out=$(bash "$AWAIT" "$pid" --max 20 2>&1) || fail "pid await failed: $out"
  assert_equals "pid $pid exited" "$out" "pid exit"
  # A process still running is reported running at the cap. The awaited
  # command line names "sleep", which a pgrep -f loop for "sleep" would also
  # match in its own shell; waiting by id cannot.
  sleep 30 &
  pid=$!
  rc=0; out=$(bash "$AWAIT" "$pid" --max 1 2>&1) || rc=$?
  expect_code 1 "$rc" "a live process at the cap"
  assert_contains "$out" "still waiting: pid $pid still running" "the live-process cap message"
  kill "$pid" 2>/dev/null
  wait 2>/dev/null
  pass "fm-await: a pid wait returns when the process exits, including an unreaped child, and reports one still running"
}

test_usage_errors() {
  local rc out label
  while IFS='|' read -r label args; do
    rc=0
    # shellcheck disable=SC2086 # Each case is a deliberately word-split argument list.
    out=$(bash "$AWAIT" $args 2>&1) || rc=$?
    expect_code 2 "$rc" "$label"
  done <<CASES
no target|
file without --match|$TMP_ROOT/x.log
pid with --match|123 --match x
zero max|$TMP_ROOT/x.log --match x --max 0
word max|$TMP_ROOT/x.log --match x --max soon
bad regex|$TMP_ROOT/x.log --match (
two targets|a b --match x
CASES
  pass "fm-await: malformed calls exit 2 without waiting"
}

test_file_line_already_present_returns_at_once
test_file_line_written_later_is_seen
test_cap_reports_still_waiting
test_pid_exit_is_seen_and_the_wait_never_matches_itself
test_usage_errors
