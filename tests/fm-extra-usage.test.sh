#!/usr/bin/env bash
# Behavior tests for Claude extra-usage detection: the footer signature in
# bin/fm-claude-limit-lib.sh and the check, scan, and steer in
# bin/fm-extra-usage.sh.
#
# The safety direction matters more than the happy path, because a false match
# stops healthy workers:
#   (a) signature: the notice counts only as a whole segment of the live footer
#       under a provable claude composer; the same words in the transcript, under
#       a shell an exited agent left behind, truncated, or in a zone too tall to
#       be a footer never do, and neither does the out-of-credits notice;
#   (b) check: silent unless a pane shows the notice, and silent for the
#       episode once the fleet was stopped, which ends only when a live claude
#       composer shows no notice, never on an uncertain read;
#   (c) steer: re-proves the match and sends nothing without it, reaches every
#       live worker once (any harness, never a secondmate), reports the credit
#       spend when the footer shows it, and retries only what did not land;
#   (d) arm and disarm write and retire a bound watcher check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-limit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-extra-usage)
RULE='────────────────────────────────────────────────────────────'

# A claude pane as current releases draw it, with <footer> as the row(s) under
# the composer.
claude_pane() {  # <footer-rows...>
  printf '%s\n' '● Pushed the branch and opened the pull request.' '' "$RULE" '❯ ' "$RULE"
  printf '%s\n' "$@"
}

FOOTER_HINTS='  ⏵⏵ bypass permissions on · 1 shell · esc to interrupt'

test_signature_matches_the_footer_notice() {
  local got
  got=$(claude_pane "$FOOTER_HINTS        Now using usage credits" | fm_claude_extra_usage_read) \
    || fail "the persistent footer notice did not match"
  [ "$got" = "using"$'\t' ] || fail "unexpected verdict: $got"
  got=$(claude_pane "$FOOTER_HINTS" "      You're now using extra usage · Your session limit resets 3pm (America/Denver)" \
    | fm_claude_extra_usage_read) || fail "the older extra-usage wording on its own row did not match"
  [ "$got" = "using"$'\t' ] || fail "unexpected verdict: $got"
  got=$(claude_pane "$FOOTER_HINTS   You're close to your usage credit limit" \
    "      You've used 91% of your usage credits · resets Oct 1" | fm_claude_extra_usage_read) \
    || fail "the credit-limit warning did not match"
  [ "$got" = "near-limit"$'\t'"You've used 91% of your usage credits · resets Oct 1" ] \
    || fail "near-limit verdict or spend lost: $got"
  got=$(claude_pane $'\033[2m'"$FOOTER_HINTS"$'\033[0m    \033[2mNow using usage credits\033[0m' \
    | fm_claude_extra_usage_read) || fail "a styled footer did not match"
  pass "the live footer notice matches, with its class and any credit spend"
}

test_signature_ignores_the_notice_anywhere_else() {
  local rc
  claude_pane "$FOOTER_HINTS" | fm_claude_extra_usage_read >/dev/null && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "a live composer with no notice did not read as a proven clear (status $rc)"
  printf '%s\n' "$RULE" '  Now using usage credits' "$RULE" 'user@host:~$ ' \
    | fm_claude_extra_usage_read >/dev/null && rc=0 || rc=$?
  [ "$rc" = 1 ] || fail "a pane with no claude composer did not read as uncertain (status $rc)"
  { printf '%s\n' '● The footer says:' '  Now using usage credits' "  You're close to your usage credit limit"
    claude_pane "$FOOTER_HINTS"; } | fm_claude_extra_usage_read >/dev/null \
    && fail "the notice quoted in the transcript matched"
  printf '%s\n' "$RULE" '  Now using usage credits' "$RULE" 'user@host:~$ ' \
    | fm_claude_extra_usage_read >/dev/null && fail "text under a shell with no claude composer matched"
  { claude_pane "$FOOTER_HINTS"; printf '%s\n' a b c d e '    Now using usage credits'; } \
    | fm_claude_extra_usage_read >/dev/null && fail "a zone too tall to be a footer matched"
  claude_pane "$FOOTER_HINTS    Now using usage cre…" | fm_claude_extra_usage_read >/dev/null \
    && fail "a truncated notice matched"
  claude_pane "$FOOTER_HINTS    You're out of usage credits · resets 3pm" | fm_claude_extra_usage_read >/dev/null \
    && fail "the out-of-credits notice matched"
  claude_pane "$FOOTER_HINTS    Tip: Now using usage credits" | fm_claude_extra_usage_read >/dev/null \
    && fail "a segment that only contains the words matched"
  printf '' | fm_claude_extra_usage_read >/dev/null && fail "empty input matched"
  pass "the notice outside a live claude footer, truncated, or out-of-credits never matches"
}

# --- script cases -----------------------------------------------------------
#
# Each case runs the real bin/ against a fake tmux that serves each window's
# pane from its own file, with fm-send.sh replaced by a recorder.
make_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1" fb
  mkdir -p "$d/state" "$d/panes"
  cp -R "$ROOT/bin" "$d/bin"
  cat > "$d/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
case " ${FM_FAKE_SEND_FAILS:-} " in *" $1 "*) exit 1 ;; esac
printf '%s\t%s\n' "$1" "$2" >> "${FM_FAKE_SENDLOG:?}"
exit 0
SH
  chmod +x "$d/bin/fm-send.sh"
  fb="$d/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) [ -f "$FM_FAKE_PANES/$target" ] || exit 1; cat "$FM_FAKE_PANES/$target" ;;
  list-windows)
    case " ${FM_FAKE_GONE:-} " in
      *" $target "*) echo "can't find session: $target" >&2 ;;
      *) echo "unreadable in this fake" >&2 ;;
    esac
    exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  : > "$d/sent.log"
  printf '%s\n' "$d"
}

task() {  # <case-dir> <id> <harness> [kind] [session]
  fm_write_meta "$1/state/$2.meta" "window=${5:-fm}:fm-$2" "kind=${4:-ship}" "harness=$3" "backend=tmux"
}

show() {  # <case-dir> <id> <footer-rows...>
  local d=$1 id=$2
  shift 2
  claude_pane "$@" > "$d/panes/fm:fm-$id"
}

run_eu() {  # <case-dir> <args...>
  local d=$1
  shift
  PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    FM_FAKE_PANES="$d/panes" FM_FAKE_SENDLOG="$d/sent.log" \
    "$d/bin/fm-extra-usage.sh" "$@"
}

test_check_is_silent_without_the_notice() {
  local d out
  d=$(make_case quiet)
  task "$d" a claude
  task "$d" b claude
  show "$d" a "$FOOTER_HINTS"
  out=$(run_eu "$d" check) || fail "check exited non-zero with no notice"
  [ -z "$out" ] || fail "check spoke with no notice: $out"
  out=$(run_eu "$d" steer 2>&1) && fail "steer ran with no notice on any pane"
  assert_contains "$out" "nothing sent" "steer refusal did not say nothing was sent"
  [ ! -s "$d/sent.log" ] || fail "steer sent without a fresh match"
  [ ! -e "$d/state/.extra-usage-steered" ] || fail "steer recorded an episode without a match"
  pass "no notice: check is silent and steer refuses without sending"
}

test_check_reads_only_claude_panes() {
  local d out
  d=$(make_case harness)
  task "$d" c codex
  show "$d" c "$FOOTER_HINTS    Now using usage credits"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check read a non-claude pane: $out"
  pass "only claude panes are read for the notice"
}

test_steer_stops_every_live_worker_once() {
  local d out
  d=$(make_case steer)
  task "$d" a claude
  task "$d" b claude
  task "$d" c codex
  task "$d" gone claude ship dead
  task "$d" sm claude secondmate
  show "$d" a "$FOOTER_HINTS"
  show "$d" b "$FOOTER_HINTS   You're close to your usage credit limit" "   You've used 91% of your usage credits"
  out=$(run_eu "$d" check)
  assert_contains "$out" "extra-usage near-limit on b" "check did not name the class and task"
  assert_contains "$out" "fm-extra-usage.sh steer" "check did not name the next command"
  out=$(FM_FAKE_GONE="dead" run_eu "$d" steer) || fail "steer failed: $out"
  assert_contains "$out" "credit spend: You've used 91% of your usage credits" "steer lost the credit spend"
  assert_contains "$out" "sent to: a b c" "steer did not reach every live worker"
  assert_contains "$out" "endpoint dead: gone" "steer did not report the dead endpoint"
  [ "$(cut -f1 "$d/sent.log" | tr '\n' ' ')" = "a b c " ] || fail "unexpected recipients: $(cut -f1 "$d/sent.log")"
  assert_contains "$(head -1 "$d/sent.log")" "do not abort it" "the stop instruction lost its validation-run rule"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check woke again inside the episode: $out"
  out=$(FM_FAKE_GONE="dead" run_eu "$d" steer) || fail "a repeat steer failed"
  [ "$(grep -c '' "$d/sent.log")" = 3 ] || fail "a repeat steer re-sent to reached workers"
  pass "steer stops every live worker once and reports the credit spend"
}

test_steer_retries_only_what_did_not_land() {
  local d out
  d=$(make_case retry)
  task "$d" a claude
  task "$d" b claude
  show "$d" a "$FOOTER_HINTS    Now using usage credits"
  out=$(FM_FAKE_SEND_FAILS=b run_eu "$d" steer 2>&1) && fail "a failed send was reported as success"
  assert_contains "$out" "did not land for: b" "the failed recipient was not named"
  out=$(run_eu "$d" steer) || fail "the retry failed: $out"
  assert_contains "$out" "sent to: b" "the retry did not reach only the missed worker"
  [ "$(cut -f1 "$d/sent.log" | tr '\n' ' ')" = "a b " ] || fail "unexpected sends: $(cut -f1 "$d/sent.log")"
  pass "a failed stop instruction is reported and retried alone"
}

test_episode_ends_when_a_readable_scan_finds_no_notice() {
  local d out
  d=$(make_case episode)
  task "$d" a claude
  show "$d" a "$FOOTER_HINTS    Now using usage credits"
  run_eu "$d" steer >/dev/null || fail "steer failed"
  rm -f "$d/panes/fm:fm-a"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check spoke with no readable pane: $out"
  [ -e "$d/state/.extra-usage-steered" ] || fail "an unreadable fleet ended the episode"
  printf '%s\n' '● Running the tests.' '' ' Do you want to proceed?' ' ❯ 1. Yes' '   2. No' '' ' Esc to cancel' \
    > "$d/panes/fm:fm-a"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check spoke over a dialog: $out"
  [ -e "$d/state/.extra-usage-steered" ] || fail "a dialog in place of the composer ended the episode"
  show "$d" a "$FOOTER_HINTS"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check spoke with no notice: $out"
  [ ! -e "$d/state/.extra-usage-steered" ] || fail "a notice-free readable scan did not end the episode"
  show "$d" a "$FOOTER_HINTS    Now using usage credits"
  out=$(run_eu "$d" check)
  assert_contains "$out" "extra-usage using on a" "check stayed silent on the next flip"
  run_eu "$d" steer >/dev/null || fail "a new episode's steer failed"
  [ "$(grep -c '' "$d/sent.log")" = 2 ] || fail "a new episode did not stop the worker again"
  pass "a notice-free readable scan ends the episode, so the next flip wakes and stops the fleet again"
}

test_episode_holds_while_the_notice_shows() {
  local d out
  d=$(make_case holds)
  task "$d" a claude
  show "$d" a "$FOOTER_HINTS    Now using usage credits"
  run_eu "$d" steer >/dev/null || fail "steer failed"
  printf 'fm-extra-usage-v1 %s using a\nsteered a\n' "$(( $(date +%s) - 10 * 86400 ))" > "$d/state/.extra-usage-steered"
  out=$(run_eu "$d" check)
  [ -z "$out" ] || fail "check woke inside an old episode while the notice still shows: $out"
  [ -e "$d/state/.extra-usage-steered" ] || fail "the episode ended while the notice still shows"
  [ "$(grep -c '' "$d/sent.log")" = 1 ] || fail "the worker was stopped again"
  pass "while the notice shows, check stays silent with no time limit"
}

test_arm_and_disarm() {
  local d out
  d=$(make_case arm)
  out=$(run_eu "$d" arm) || fail "arm failed: $out"
  [ -f "$d/state/extra-usage.check.sh" ] && [ -f "$d/state/extra-usage.check-trust" ] \
    || fail "arm did not write a bound check"
  task "$d" a claude
  show "$d" a "$FOOTER_HINTS    Now using usage credits"
  out=$(PATH="$d/fakebin:$PATH" FM_FAKE_PANES="$d/panes" "$d/state/extra-usage.check.sh")
  assert_contains "$out" "extra-usage using on a" "the armed check did not run the detector"
  run_eu "$d" steer >/dev/null || fail "steer failed"
  run_eu "$d" disarm >/dev/null || fail "disarm failed"
  [ ! -e "$d/state/extra-usage.check.sh" ] && [ ! -e "$d/state/extra-usage.check-trust" ] \
    && [ ! -e "$d/state/.extra-usage-steered" ] || fail "disarm left records behind"
  pass "arm writes a bound watcher check and disarm retires it"
}

test_signature_matches_the_footer_notice
test_signature_ignores_the_notice_anywhere_else
test_check_is_silent_without_the_notice
test_check_reads_only_claude_panes
test_steer_stops_every_live_worker_once
test_steer_retries_only_what_did_not_land
test_episode_ends_when_a_readable_scan_finds_no_notice
test_episode_holds_while_the_notice_shows
test_arm_and_disarm

echo "all fm-extra-usage tests passed"
