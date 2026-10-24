#!/usr/bin/env bash
# tests/fm-steer.test.sh - bin/fm-steer.sh, a worker's read and acknowledge
# commands, against records written by the real steering-inbox writer
# (fm_task_inbox_write in bin/fm-task-inbox-lib.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-steer)
STEER="$ROOT/bin/fm-steer.sh"

# Write one steer into <state>/<task>.inbox the way bin/fm-send.sh does.
write_steer() {  # <state-dir> <task> <text>
  bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "$4" >/dev/null' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$1" "$2" "$3"
}

test_read_prints_unread_in_order_and_acknowledges_nothing() {
  local state inbox out
  state="$TMP_ROOT/read/state"
  mkdir -p "$state"
  inbox="$state/t1.inbox"
  write_steer "$state" t1 "first steer"
  write_steer "$state" t1 "$(printf 'second steer\nwith two lines')"
  out=$(bash "$STEER" read --inbox "$inbox" 2>&1) || fail "read failed: $out"
  assert_contains "$out" "=== 001.msg (at " "a header for the first record"
  assert_contains "$out" "first steer" "the first body"
  assert_contains "$out" "$(printf 'second steer\nwith two lines')" "the second body, newlines kept"
  assert_not_contains "$out" "schema=" "record metadata is not presented as message text"
  case "$out" in *"001.msg"*"002.msg"*) ;; *) fail "records out of numeric order: $out" ;; esac
  assert_contains "$out" "ack --inbox '$inbox' 001 002" "the ack command for what was read"
  [ -f "$inbox/001.msg" ] && [ -f "$inbox/002.msg" ] || fail "reading acknowledged a message"
  pass "fm-steer: read prints unread steers oldest first under headers and leaves them unacknowledged"
}

test_ack_moves_into_handled_and_reissued_numbers_stay_unique() {
  local state inbox out rc
  state="$TMP_ROOT/ack/state"
  mkdir -p "$state"
  inbox="$state/t1.inbox"
  write_steer "$state" t1 one
  write_steer "$state" t1 two
  out=$(FM_TASK_INBOX="$inbox" bash "$STEER" ack 1 002.msg 2>&1) || fail "ack failed: $out"
  assert_contains "$out" "acknowledged 001.msg" "first ack"
  assert_contains "$out" "acknowledged 002.msg" "second ack"
  [ -f "$inbox/handled/001.msg" ] && [ -f "$inbox/handled/002.msg" ] || fail "ack did not move into handled/"
  out=$(FM_TASK_INBOX="$inbox" bash "$STEER" read 2>&1) || fail "read failed: $out"
  assert_equals "no unread messages" "$out" "an acknowledged inbox"
  out=$(FM_TASK_INBOX="$inbox" bash "$STEER" ack 001 2>&1) || fail "a repeated ack failed: $out"
  assert_contains "$out" "already acknowledged 001.msg" "a repeated ack"
  write_steer "$state" t1 three
  [ -f "$inbox/003.msg" ] || fail "the writer reissued an acknowledged number"
  rc=0; out=$(FM_TASK_INBOX="$inbox" bash "$STEER" ack 9 003 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown message"
  assert_contains "$out" "no message 9" "the unknown message is named"
  [ -f "$inbox/handled/003.msg" ] || fail "an unknown number stopped the other acknowledgements"
  pass "fm-steer: ack moves each named steer into handled/, repeats are harmless, and an unknown one is an error"
}

test_absent_inbox_and_usage() {
  local out rc
  out=$(bash "$STEER" read --inbox "$TMP_ROOT/none/t1.inbox" 2>&1) || fail "absent inbox read failed: $out"
  assert_equals "no unread messages" "$out" "an absent inbox"
  rc=0; out=$(env -u FM_TASK_INBOX bash "$STEER" read 2>&1) || rc=$?
  expect_code 2 "$rc" "no inbox named"
  rc=0; out=$(bash "$STEER" ack --inbox "$TMP_ROOT/none" 2>&1) || rc=$?
  expect_code 2 "$rc" "ack without numbers"
  rc=0; out=$(bash "$STEER" ack --inbox "$TMP_ROOT/none" abc 2>&1) || rc=$?
  expect_code 2 "$rc" "ack of a non-number"
  rc=0; out=$(bash "$STEER" send --inbox "$TMP_ROOT/none" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown command"
  pass "fm-steer: an absent inbox reads empty, and malformed calls exit 2"
}

test_read_prints_unread_in_order_and_acknowledges_nothing
test_ack_moves_into_handled_and_reissued_numbers_stay_unique
test_absent_inbox_and_usage
