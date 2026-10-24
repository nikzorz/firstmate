#!/usr/bin/env bash
# tests/fm-status.test.sh - bin/fm-status.sh, the worker status append.
#
# Every line the script writes is read back through bin/fm-classify-lib.sh's own
# readers, so the test pins the grammar the supervisor parses rather than a
# spelling: the verb, the stamp, the decision key, and the paused recheck time.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status)
STATUS="$ROOT/bin/fm-status.sh"

# Sets HOME_DIR and FILE for one isolated case.
make_case() {  # <name>
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  FILE="$HOME_DIR/state/t1.status"
}

# Field <name> of a status line through the classifier's own reader.
read_field() {  # <verb|key|at|until|note> <line>
  bash -c '
    . "$1"
    case "$2" in
      verb) status_line_verb "$3" ;;
      key) _fm_decision_key "$3" ;;
      at) status_line_at_epoch "$3" ;;
      until) status_paused_until "$3" ;;
      note) status_line_note "$3" ;;
    esac' _ "$ROOT/bin/fm-classify-lib.sh" "$1" "$2"
}

test_plain_line_is_stamped_and_parsed() {
  local out before after at
  make_case plain
  before=$(date +%s)
  out=$(env -i PATH="$PATH" bash "$STATUS" "$FILE" working setup 'done' 2>&1) \
    || fail "status append failed: $out"
  after=$(date +%s)
  assert_equals "$out" "$(cat "$FILE")" "the printed line is the appended line"
  assert_equals working "$(read_field verb "$out")" "verb"
  assert_equals default "$(read_field key "$out")" "an unkeyed line"
  assert_equals "setup done" "$(read_field note "$out")" "note words joined with single spaces"
  at=$(read_field at "$out")
  [ "$at" -ge "$before" ] && [ "$at" -le "$after" ] || fail "stamp $at is not the append time"
  pass "fm-status: a plain line carries the clock's stamp and parses as the supervisor reads it"
}

test_keyed_line_round_trips_the_key() {
  local out
  make_case keyed
  out=$(bash "$STATUS" "$FILE" needs-decision --key nm-r1-review "ask-user round=1 findings=a,b" 2>&1) \
    || fail "keyed append failed: $out"
  assert_equals needs-decision "$(read_field verb "$out")" "verb"
  assert_equals nm-r1-review "$(read_field key "$out")" "key"
  assert_equals "ask-user round=1 findings=a,b" "$(read_field note "$out")" "note"
  out=$(bash "$STATUS" "$FILE" resolved --key nm-r1-review answered 2>&1) || fail "resolve failed: $out"
  assert_equals nm-r1-review "$(read_field key "$out")" "the closing line names the same key"
  assert_equals 2 "$(wc -l < "$FILE" | tr -d ' ')" "one line per call"
  pass "fm-status: --key writes a decision key that opens and closes through the classifier"
}

# A time-only `until HH:MMZ` reads as its next occurrence at or after the line's
# own `[at=]` stamp; any other time-like token, an unstamped time-only one
# included, reads as already due (0) instead of falling back to the cadence.
# Prose after `until` (no colon, no `YYYY-` date) still names no time, and a
# dated time wins over a later prose `until`.
test_until_time_only_and_unreadable() {
  local at=1792162543 v
  v=$(read_field until "paused [at=$at]: fix round (b) running until 15:35Z") || fail "time-only until unread"
  [ "$v" = 1792164900 ] || fail "time-only until read as $v, not the same day's 15:35Z"
  v=$(read_field until "paused [at=$at]: overnight job until 02:00Z.") || fail "next-day time-only until unread"
  [ "$v" = 1792202400 ] || fail "an earlier clock time read as $v, not the next day's"
  v=$(read_field until "paused: x until 2026-10-16T15:35Z") || fail "dated until unread"
  [ "$v" = 1792164900 ] || fail "dated until read as $v"
  for line in 'paused: fix round running until 15:35Z' 'paused: until 15:35 local' \
    "paused [at=$at]: until 25:00Z" 'paused: until 2026-10-16 15:35'; do
    v=$(read_field until "$line") || fail "unreadable until on '$line' fell back to the cadence"
    [ "$v" = 0 ] || fail "unreadable until on '$line' read as $v, not due"
  done
  for line in 'paused: waiting until CI finishes' 'paused: waiting until 2 required checks pass' \
    'paused: until 3 reviewers approve'; do
    if read_field until "$line" >/dev/null; then fail "prose after until on '$line' was read as a time"; fi
  done
  v=$(read_field until 'paused: until 2026-10-16T15:35Z (retry until 3 attempts)') \
    || fail "a dated until followed by a prose until was unread"
  [ "$v" = 1792164900 ] || fail "a later prose until displaced the dated time: $v"
  pass "fm-classify: a time-only until reads from its stamp, and an unreadable one is due at once"
}

test_until_relative_rounds_up_to_the_minute() {
  local out before until
  make_case until-rel
  before=$(date +%s)
  out=$(bash "$STATUS" "$FILE" paused --until +600s waiting on my run 2>&1) || fail "paused append failed: $out"
  until=$(read_field until "$out") || fail "the paused line carries no recheck time: $out"
  [ $((until % 60)) -eq 0 ] || fail "recheck $until is not a whole minute"
  [ "$until" -ge $((before + 600)) ] && [ "$until" -lt $((before + 600 + 60 + 2)) ] \
    || fail "recheck $until is not start plus 600s rounded up (start $before)"
  out=$(bash "$STATUS" "$FILE" paused --until +2h long job 2>&1) || fail "hours failed: $out"
  until=$(read_field until "$out")
  [ "$until" -ge $((before + 7200)) ] && [ "$until" -lt $((before + 7200 + 60 + 5)) ] \
    || fail "recheck $until is not start plus two hours"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting bash "$STATUS" "$FILE" awaiting --until +5m slot 2>&1) \
    || fail "configured pause verb refused: $out"
  assert_contains "$out" "awaiting [at=" "the configured pause verb is the state"
  pass "fm-status: --until +N[smh] becomes the recheck time rounded up to the minute"
}

test_until_absolute_is_kept_and_validated() {
  local out rc
  make_case until-abs
  out=$(bash "$STATUS" "$FILE" paused --until 2031-01-02T03:04Z heavy slot 2>&1) || fail "absolute failed: $out"
  assert_equals "$(bash -c '. "$1"; fm_utc_iso_to_epoch 2031-01-02T03:04Z' _ "$ROOT/bin/fm-classify-lib.sh")" \
    "$(read_field until "$out")" "absolute recheck time"
  rc=0; out=$(bash "$STATUS" "$FILE" paused --until 2031-13-45T99:99Z x 2>&1) || rc=$?
  expect_code 2 "$rc" "an impossible time"
  rc=0; out=$(bash "$STATUS" "$FILE" paused --until soon x 2>&1) || rc=$?
  expect_code 2 "$rc" "a free-text time"
  rc=0; out=$(bash "$STATUS" "$FILE" 'done' --until +5m x 2>&1) || rc=$?
  expect_code 2 "$rc" "--until on a done line"
  assert_contains "$out" "only to a paused line" "the refusal names why"
  assert_equals 1 "$(wc -l < "$FILE" | tr -d ' ')" "refused calls append nothing"
  pass "fm-status: an explicit --until is kept, and a malformed or misplaced one is refused unwritten"
}

test_line_form_stamps_only_an_unstamped_line() {
  local out
  make_case line
  out=$(bash "$STATUS" "$FILE" --line 'needs-decision [key=nm-r2-review]: ruling owed round=2' 2>&1) \
    || fail "--line failed: $out"
  assert_equals nm-r2-review "$(read_field key "$out")" "key from the copied line"
  read_field at "$out" >/dev/null || fail "an unstamped copied line was not stamped: $out"
  out=$(bash "$STATUS" "$FILE" --line 'blocked [at=1790000000]: kept' 2>&1) || fail "--line stamped failed"
  assert_equals 'blocked [at=1790000000]: kept' "$out" "an already stamped line is appended as given"
  pass "fm-status: --line appends a printed line, stamping it only when it carries no time"
}

test_usage_errors_write_nothing() {
  local rc out case_args
  make_case usage
  while IFS='|' read -r label case_args; do
    rc=0
    # shellcheck disable=SC2086 # Each case is a deliberately word-split argument list.
    out=$(bash "$STATUS" "$FILE" $case_args 2>&1) || rc=$?
    expect_code 2 "$rc" "$label"
  done <<'CASES'
unknown state|bogus note
note verb|note x
captain-held verb|captain-held x
missing note|working
bad key|needs-decision --key a/b why
line plus state|--line x working
unknown option|working --loud x
CASES
  rc=0; out=$(bash "$STATUS" "$FILE" working "$(printf 'two\nlines')" 2>&1) || rc=$?
  expect_code 2 "$rc" "a note with a newline"
  rc=0; out=$(bash "$STATUS" 2>&1) || rc=$?
  expect_code 2 "$rc" "no arguments"
  assert_absent "$FILE" "a refused call created the status file"
  pass "fm-status: every usage error exits 2 and writes nothing"
}

test_append_failure_is_reported() {
  local rc out
  make_case append-fails
  mkdir -p "$FILE"
  rc=0; out=$(bash "$STATUS" "$FILE" failed tests broke 2>&1) || rc=$?
  expect_code 1 "$rc" "an append into a directory"
  assert_contains "$out" "could not append" "the failure names the append"
  pass "fm-status: a failed append exits 1"
}

test_ledger_follows_the_flag_and_config_override() {
  local out moved
  make_case ledger
  out=$(bash "$STATUS" "$FILE" working no flag 2>&1) || fail "append failed: $out"
  assert_absent "$HOME_DIR/state/fleet-ledger.jsonl" "a ledger written with the flag absent"
  : > "$HOME_DIR/config/fleet-ledger"
  out=$(bash "$STATUS" "$FILE" 'done' flagged 2>&1) || fail "append failed: $out"
  assert_grep '"state":"done"' "$HOME_DIR/state/fleet-ledger.jsonl" "the flagged line reached the ledger"
  moved="$TMP_ROOT/ledger/moved-config"
  mkdir -p "$moved"
  rm "$HOME_DIR/config/fleet-ledger"
  : > "$moved/fleet-ledger"
  out=$(bash "$STATUS" "$FILE" --config "$moved" blocked need a token 2>&1) || fail "append failed: $out"
  assert_grep '"state":"blocked"' "$HOME_DIR/state/fleet-ledger.jsonl" "--config names the flag's home"
  pass "fm-status: the fleet ledger records a line only while the flag exists, read from config/ or --config"
}

test_plain_line_is_stamped_and_parsed
test_keyed_line_round_trips_the_key
test_until_time_only_and_unreadable
test_until_relative_rounds_up_to_the_minute
test_until_absolute_is_kept_and_validated
test_line_form_stamps_only_an_unstamped_line
test_usage_errors_write_nothing
test_append_failure_is_reported
test_ledger_follows_the_flag_and_config_override
