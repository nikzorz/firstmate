#!/usr/bin/env bash
# Behavior tests for Claude Code's usage-limit stall: the signature and quota
# reading in bin/fm-claude-limit-lib.sh, and the guarded recovery in
# bin/fm-limit-resume.sh.
#
# The 2026-07-29 incident these pin: three crewmates exhausted the account usage
# limit mid-turn and stopped on Claude Code's interactive choice prompt, which
# waits for a human indefinitely. They idled ~8.7 hours after the five-hour
# window had already reset. Two properties made it expensive, and both are
# covered here: the stalled pane looks healthy, and it never self-resumes.
#
# The safety direction matters more than the happy path. Every case that sends a
# key first proves the condition; every case that cannot prove it sends nothing:
#   (a) signature: the real prompt matches; ordinary worker output that discusses
#       limits does not, and neither does the prompt's own text quoted inside a
#       working pane;
#   (b) quota window: reset / exhausted / unknown, with every unreadable or
#       unmarked input failing closed to unknown;
#   (c) recovery: only a fresh live match plus a reset window sends Escape, the
#       prompt must be PROVABLY gone before the resume instruction is sent (a
#       pane that cannot be re-read refuses too), and the steer tells the crew to
#       re-read its own state rather than asserting one;
#   (d) a still-exhausted window records the bounded external wait with the
#       fleet's `paused:` vocabulary, idempotently, and sends nothing - and once
#       recovery lands, that wait is closed again, but only ever the one firstmate
#       itself opened;
#   (e) that wait also carries WHEN it ends, so the recheck is scheduled from the
#       window's reported reset instead of a blind hour. The 2026-07-29/30
#       follow-on these pin: detection and recovery were both correct, but the
#       window rolled about forty minutes into an hour-long recheck cadence, so
#       three crews stayed parked until the cadence came due. Absent, malformed,
#       or unreadable reset data must leave that cadence exactly as it was.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-limit-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-limit-resume)

# --- pane fixtures ----------------------------------------------------------

# The prompt exactly as Claude Code drew it in the incident. Nothing is rendered
# below it because the prompt replaces the composer.
limit_prompt_pane() {
  cat <<'EOF'
● Pushed the branch and opened the pull request.

Claude usage limit reached. Your limit will reset at 6:40pm.

   What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Upgrade your plan

   Enter to confirm · Esc to cancel
EOF
}

# Ordinary worker output that uses the word "limit" in prose, including the
# prompt's own question, inside a healthy pane whose composer box is still drawn.
limit_prose_pane() {
  cat <<'EOF'
● Bash(git commit -m "fix(api): back off when the provider rate limit is hit")
  ⎿  [fm/api-retry 1a2b3c4] fix(api): back off when the provider rate limit is hit

● The note records that we wait for limit to reset instead of hammering the
  endpoint, and that the limit resets on a five-hour window.
  What do you want to do?

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# The prompt's own text quoted inside tool output on a WORKING pane - a crewmate
# reading these very fixtures. Every text anchor is present and in order; only
# the composer box still drawn underneath separates it from the real stall.
limit_quoted_pane() {
  cat <<'EOF'
● Read(tests/fm-limit-resume.test.sh)
  ⎿     What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Upgrade your plan
        Enter to confirm · Esc to cancel

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# A dismissed prompt: the composer is back and the crew is idle.
dismissed_pane() {
  cat <<'EOF'
● Pushed the branch and opened the pull request.

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

quota_json() {  # <percent-remaining>
  cat <<EOF
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "plan": "max",
      "state": { "status": "fresh", "stale": false },
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "effectivePercentRemaining": $1 }
        ]
      }
    }
  ]
}
EOF
}

# The provider's fuller shape, with the bounding windows that carry the reset
# times: an account window array plus the availability block naming which of
# them bound every model. Effective availability is the minimum across those.
quota_json_windows() {  # <effective-remaining> <windows-json> <bounded-by-json>
  cat <<EOF
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "plan": "max",
      "state": { "status": "fresh", "stale": false },
      "windows": $2,
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known",
            "effectivePercentRemaining": $1, "boundedBy": $3 }
        ]
      }
    }
  ]
}
EOF
}

# One window object. A `-` reset time omits the field entirely, which is how the
# provider reports a window whose reset it does not know.
quota_window() {  # <id> <percent-remaining> <resetsAt|->
  if [ "$3" = - ]; then
    printf '{ "id": "%s", "percentRemaining": %s }' "$1" "$2"
  else
    printf '{ "id": "%s", "percentRemaining": %s, "resetsAt": "%s" }' "$1" "$2" "$3"
  fi
}

# quota-axi's own timestamp shape: microseconds and a numeric UTC offset.
iso_at() {  # <epoch>
  if [ "$(uname)" = Darwin ]; then
    date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000000+00:00'
  else
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000000+00:00'
  fi
}

# --- (a) dialog signature ---------------------------------------------------

test_signature_matches_the_real_prompt() {
  limit_prompt_pane | fm_claude_limit_dialog_match \
    || fail "the observed usage-limit prompt did not match"
  pass "the observed claude usage-limit prompt matches the signature"
}

test_signature_ignores_ordinary_limit_prose() {
  limit_prose_pane | fm_claude_limit_dialog_match \
    && fail "prose discussing rate limits matched the usage-limit signature"
  limit_quoted_pane | fm_claude_limit_dialog_match \
    && fail "the prompt's own text quoted in tool output matched on a working pane"
  pass "ordinary worker output never matches, quoted prompt text included"
}

test_signature_requires_every_anchor_in_order() {
  local base
  base=$(limit_prompt_pane)

  printf '%s' "$base" | grep -v 'What do you want to do' | fm_claude_limit_dialog_match \
    && fail "a missing question anchor still matched"
  printf '%s' "$base" | grep -v 'Stop and wait for limit to reset' | fm_claude_limit_dialog_match \
    && fail "a missing option anchor still matched"
  printf '%s' "$base" | grep -v 'Enter to confirm' | fm_claude_limit_dialog_match \
    && fail "a missing confirm anchor still matched"

  # Same anchors, reversed order: not a rendered prompt.
  printf '   Enter to confirm · Esc to cancel\n ❯ 1. Stop and wait for limit to reset\n   What do you want to do?\n' \
    | fm_claude_limit_dialog_match && fail "out-of-order anchors matched"

  # Same anchors, but with content below them: the live prompt owns the bottom
  # of the pane, so a block buried above other output is not one.
  { printf '%s\n' "$base"; printf '● Continuing with the next file.\n● And the next one.\n● And another.\n'; } \
    | fm_claude_limit_dialog_match && fail "a prompt block with output below it matched"

  printf '' | fm_claude_limit_dialog_match && fail "empty input matched"
  pass "the signature requires all three anchors, in order, owning the bottom of the pane"
}

test_signature_matches_plain_marker_and_ansi() {
  # A plain '>' selection marker instead of '❯', and the same content wrapped in
  # SGR styling, must both still match: the anchors are structural text.
  limit_prompt_pane | sed 's/❯/>/' | fm_claude_limit_dialog_match \
    || fail "a plain '>' selection marker did not match"
  limit_prompt_pane | sed 's/^\(.*\)$/\x1b[2m\1\x1b[0m/' | fm_claude_limit_dialog_match \
    || fail "a styled capture of the prompt did not match"
  pass "the signature tolerates the plain selection marker and ANSI styling"
}

# --- (b) quota window -------------------------------------------------------

# A fakebin whose quota-axi serves FM_FAKE_QUOTA_JSON (or fails on demand).
make_quota_bin() {  # <dir> -> echoes fakebin path
  local fb="$1/quotabin"
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_QUOTA_FAILS:-0}" = 1 ] && exit 1
printf '%s\n' "${FM_FAKE_QUOTA_JSON:-}"
exit 0
SH
  chmod +x "$fb/quota-axi"
  printf '%s\n' "$fb"
}

window_state_with() {  # <fakebin> <json>
  FM_FAKE_QUOTA_JSON="$2" PATH="$1:$PATH" fm_claude_limit_window_state
}

# The two-field read: "<verdict><TAB><recheck epoch, or empty>".
TAB=$'\t'
window_read_with() {  # <fakebin> <json>
  FM_FAKE_QUOTA_JSON="$2" PATH="$1:$PATH" fm_claude_limit_window_read
}

test_quota_window_reset_and_exhausted() {
  local fb; fb=$(make_quota_bin "$TMP_ROOT")
  [ "$(window_state_with "$fb" "$(quota_json 97)")" = reset ] \
    || fail "97% remaining was not read as a reset window"
  [ "$(window_state_with "$fb" "$(quota_json 0)")" = exhausted ] \
    || fail "0% remaining was not read as an exhausted window"
  # A sliver of headroom is still exhausted: resuming into it would re-exhaust
  # within seconds and re-present the prompt.
  [ "$(window_state_with "$fb" "$(quota_json 1)")" = exhausted ] \
    || fail "1% remaining was treated as a reset window"
  [ "$(FM_CLAUDE_LIMIT_RESET_MIN_REMAINING=1 window_state_with "$fb" "$(quota_json 1)")" = reset ] \
    || fail "the reset margin is not configurable"
  pass "the quota window reads reset above the margin and exhausted below it"
}

test_quota_window_fails_closed_to_unknown() {
  local fb; fb=$(make_quota_bin "$TMP_ROOT")
  [ "$(FM_FAKE_QUOTA_FAILS=1 PATH="$fb:$PATH" fm_claude_limit_window_state)" = unknown ] \
    || fail "a failing quota read was not unknown"
  [ "$(window_state_with "$fb" "")" = unknown ] \
    || fail "empty quota output was not unknown"
  [ "$(window_state_with "$fb" "not json at all")" = unknown ] \
    || fail "unparseable quota output was not unknown"
  # Provider-declared stale data is not an authority on whether the window reset.
  [ "$(window_state_with "$fb" "$(quota_json 97 | sed 's/"stale": false/"stale": true/')")" = unknown ] \
    || fail "provider-declared stale quota data was trusted"
  # Semantics the provider itself does not mark known.
  [ "$(window_state_with "$fb" "$(quota_json 97 | sed 's/"status": "known"/"status": "unknown"/')")" = unknown ] \
    || fail "quota semantics the provider did not mark known were trusted"
  # No quota-axi on PATH at all.
  [ "$(PATH=/nonexistent-for-fm-test fm_claude_limit_window_state)" = unknown ] \
    || fail "a missing quota-axi was not unknown"
  pass "every unreadable or unmarked quota input fails closed to unknown"
}

# --- (e) reset time and the scheduled recheck -------------------------------

# The parser is arithmetic rather than a `date` call precisely so its answer
# cannot depend on which platform ran it, so this pins it against known epochs -
# including the offsets, leap days, and the 2100 non-leap century that separate a
# correct civil-date conversion from an approximate one.
test_reset_time_parses_without_a_platform_date() {
  local ts want got
  while read -r ts want; do
    [ -n "$ts" ] || continue
    got=$(fm_claude_limit_parse_iso8601 "$ts")
    [ "$got" = "$want" ] || fail "parsing '$ts' gave '$got', expected '$want'"
  done <<'EOF'
2026-07-30T10:40:00.593064+00:00 1785408000
2026-07-30T10:40:00Z 1785408000
2026-07-30T10:40:00.5Z 1785408000
1970-01-01T00:00:00Z 0
2000-02-29T12:00:00Z 951825600
2024-02-29T00:00:00-07:00 1709190000
2026-03-01T00:00:00+05:30 1772303400
2100-03-01T00:00:00Z 4107542400
EOF
  # Everything unparseable is empty, never a guess: an absent reset time is the
  # documented fallback, and a wrong one would schedule a real recheck wrongly.
  for ts in '' 'not a date' '2026-07-30' '2026-07-30T10:40:00' '2026-13-01T00:00:00Z' \
            '2026-07-30T24:00:00Z' '1969-12-31T23:59:59Z' '2026-07-30T10:40:00+99:00'; do
    got=$(fm_claude_limit_parse_iso8601 "$ts")
    [ -z "$got" ] || fail "unparseable timestamp '$ts' produced '$got' instead of nothing"
  done
  pass "reset timestamps parse to fixed epochs on any platform, and fail closed to nothing"
}

test_exhausted_window_reports_when_it_resets() {
  local fb soon later got
  fb=$(make_quota_bin "$TMP_ROOT")
  soon=$(( $(date +%s) + 2400 ))
  later=$(( $(date +%s) + 9000 ))

  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")") ]" '["five_hour"]')")
  [ "$got" = "exhausted${TAB}$(( soon + 60 ))" ] \
    || fail "an exhausted window did not report its reset plus the grace, got '$got'"

  # The grace is what makes the recheck worth taking: landing on the reset itself
  # would just re-read the same exhausted window.
  got=$(FM_CLAUDE_LIMIT_RESET_GRACE_SECS=300 window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")") ]" '["five_hour"]')")
  [ "$got" = "exhausted${TAB}$(( soon + 300 ))" ] || fail "the reset grace is not configurable, got '$got'"

  # Two short bounding windows: effective availability is their MINIMUM, so the
  # account is short until the LATER of them has rolled. Rechecking at the
  # earlier one would only re-observe the other.
  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")"), $(quota_window seven_day 1 "$(iso_at "$later")") ]" \
    '["five_hour","seven_day"]')")
  [ "$got" = "exhausted${TAB}$(( later + 60 ))" ] \
    || fail "the recheck was not scheduled from the last short window to reset, got '$got'"

  # A bounding window with headroom is not what is holding the account back, so
  # its reset must not schedule anything.
  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")"), $(quota_window seven_day 80 "$(iso_at "$later")") ]" \
    '["five_hour","seven_day"]')")
  [ "$got" = "exhausted${TAB}$(( soon + 60 ))" ] \
    || fail "a window that still has headroom was treated as holding the account back, got '$got'"

  # A reset already in the past is reported as it is. It means the recheck is due
  # now, and the caller - not the reader - decides what to do about that.
  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$(( $(date +%s) - 900 ))")") ]" '["five_hour"]')")
  [ "${got%%"${TAB}"*}" = exhausted ] || fail "a past reset changed the window verdict"
  [ "${got#*"${TAB}"}" -lt "$(date +%s)" ] || fail "a reset already in the past was not reported as past"
  pass "an exhausted window reports when it resets, from the last short bounding window"
}

test_missing_or_unreadable_reset_time_falls_back() {
  local fb got soon
  fb=$(make_quota_bin "$TMP_ROOT")
  soon=$(( $(date +%s) + 2400 ))

  # No resetsAt on the short window: still a good exhausted verdict, but nothing
  # to schedule, so the caller keeps its own cadence.
  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 -) ]" '["five_hour"]')")
  [ "$got" = "exhausted${TAB}" ] || fail "a missing resetsAt did not fall back to no recheck time, got '$got'"

  # One short window with a reset and one without: the unknown one could be the
  # later, so the whole schedule is unknown rather than optimistically early.
  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")"), $(quota_window seven_day 0 -) ]" \
    '["five_hour","seven_day"]')")
  [ "$got" = "exhausted${TAB}" ] || fail "a partly-unknown reset schedule was guessed at, got '$got'"

  got=$(window_read_with "$fb" "$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "yesterday afternoon") ]" '["five_hour"]')")
  [ "$got" = "exhausted${TAB}" ] || fail "an unparseable resetsAt was not discarded, got '$got'"

  # The pre-existing shape, with no windows array at all.
  got=$(window_read_with "$fb" "$(quota_json 0)")
  [ "$got" = "exhausted${TAB}" ] || fail "quota output without windows did not fall back, got '$got'"

  # A quota read that fails outright, and a reset window: neither schedules.
  got=$(FM_FAKE_QUOTA_FAILS=1 PATH="$fb:$PATH" fm_claude_limit_window_read)
  [ "$got" = "unknown${TAB}" ] || fail "a failed quota read reported a recheck time, got '$got'"
  got=$(window_read_with "$fb" "$(quota_json_windows 97 \
    "[ $(quota_window five_hour 97 "$(iso_at "$soon")") ]" '["five_hour"]')")
  [ "$got" = "reset${TAB}" ] || fail "a reset window reported a recheck time, got '$got'"
  pass "absent, malformed, or unreadable reset data leaves the existing cadence in charge"
}

# The sidecar's three invariants, which are what keep a scheduled recheck from
# becoming a second cadence: only a future epoch is recorded, an elapsed one is
# due, and it is a plain one-shot record any consumer can clear.
test_pause_deadline_records_only_a_future_recheck() {
  local d now
  d="$TMP_ROOT/deadline"; mkdir -p "$d"
  now=$(date +%s)

  pause_deadline_set "$d" task "$(( now + 600 ))"
  [ -f "$d/task.pause-recheck" ] || fail "a future recheck deadline was not recorded"
  pause_deadline_reached "$d" task && fail "a deadline ten minutes out was already due"

  # An elapsed deadline is due immediately - the observed case, where the window
  # had rolled while the crew was still parked.
  printf '%s\n' "$(( now - 5 ))" > "$d/task.pause-recheck"
  pause_deadline_reached "$d" task || fail "an elapsed deadline was not due"

  # A deadline that is already due at the moment it is written carries nothing
  # the writer does not already know, and recording one would re-fire every poll.
  pause_deadline_set "$d" task "$(( now - 60 ))"
  [ ! -e "$d/task.pause-recheck" ] || fail "a non-future deadline was recorded instead of cleared"

  for bad in '' 'soon' '-5' '12x'; do
    printf '%s\n' "$(( now + 600 ))" > "$d/task.pause-recheck"
    pause_deadline_set "$d" task "$bad"
    [ ! -e "$d/task.pause-recheck" ] || fail "malformed deadline '$bad' was recorded"
  done

  printf 'not an epoch\n' > "$d/task.pause-recheck"
  pause_deadline_reached "$d" task && fail "a corrupt deadline file was read as due"
  pause_deadline_reached "$d" never-paused && fail "a task with no deadline file was read as due"

  pause_deadline_set "$d" task "$(( now + 600 ))"
  pause_deadline_clear "$d" task
  [ ! -e "$d/task.pause-recheck" ] || fail "clearing the deadline left the record behind"
  pass "only a future recheck deadline is recorded, an elapsed one is due, and clearing removes it"
}

# --- (c)/(d) guarded recovery ----------------------------------------------
#
# Each case gets a private copy of bin/ so the real fm-limit-resume.sh runs
# against its real source graph, with only fm-send.sh replaced by a recorder.
# A fake tmux serves the pane from a file and records every key; sending Escape
# swaps in the after-key pane when the case supplies one.
make_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1" fb
  mkdir -p "$d/state"
  cp -R "$ROOT/bin" "$d/bin"
  cat > "$d/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_SEND_FAILS:-0}" = 1 ]; then exit 1; fi
printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?}"
exit 0
SH
  chmod +x "$d/bin/fm-send.sh"
  fb="$d/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane)
    [ -f "${FM_FAKE_PANE_FILE:-}" ] || exit 1
    cat "$FM_FAKE_PANE_FILE" ;;
  send-keys)
    shift
    printf '%s\n' "$*" >> "${FM_FAKE_KEYLOG:?}"
    if [ "${FM_FAKE_PANE_UNREADABLE_AFTER_KEY:-0}" = 1 ]; then
      rm -f "${FM_FAKE_PANE_FILE:-}"
    elif [ -n "${FM_FAKE_PANE_AFTER_KEY:-}" ] && [ -f "${FM_FAKE_PANE_AFTER_KEY:-}" ]; then
      cat "$FM_FAKE_PANE_AFTER_KEY" > "$FM_FAKE_PANE_FILE"
    fi ;;
esac
exit 0
SH
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_QUOTA_FAILS:-0}" = 1 ] && exit 1
printf '%s\n' "${FM_FAKE_QUOTA_JSON:-}"
exit 0
SH
  chmod +x "$fb/tmux" "$fb/quota-axi"
  : > "$d/keys.log"
  : > "$d/sent.log"
  printf '%s\n' "$d"
}

run_resume() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/fakebin:$PATH" \
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
  FM_FAKE_KEYLOG="$d/keys.log" FM_FAKE_SENDLOG="$d/sent.log" \
  FM_LIMIT_RESUME_SETTLE="${FM_LIMIT_RESUME_SETTLE:-0}" \
    "$d/bin/fm-limit-resume.sh" "$@"
}

setup_task() {  # <case-dir> <id> <harness>
  fm_write_meta "$1/state/$2.meta" "window=fm:fm-$2" "kind=ship" "harness=$3" "backend=tmux"
}

test_recovery_refuses_non_claude_harness() {
  local d; d=$(make_case refuse-harness)
  setup_task "$d" stalled codex
  limit_prompt_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 97)" \
    run_resume "$d" stalled >/dev/null 2>&1 && fail "recovery ran against a non-claude harness"
  [ ! -s "$d/keys.log" ] || fail "a key was sent to a non-claude harness"
  pass "recovery refuses a task whose recorded harness is not claude"
}

test_recovery_refuses_unresolvable_targets() {
  local d out; d=$(make_case refuse-target)
  out=$(run_resume "$d" ghost 2>&1) && fail "recovery ran for a task with no metadata"
  assert_contains "$out" "no metadata" "an unknown task did not report a missing record"

  fm_write_meta "$d/state/notarget.meta" "kind=ship" "harness=claude" "backend=tmux"
  out=$(run_resume "$d" notarget 2>&1) && fail "recovery ran for a task with no recorded endpoint"
  assert_contains "$out" "no recorded backend target" "a task with no endpoint did not report it"
  [ ! -s "$d/keys.log" ] || fail "a key was sent for an unresolvable target"
  pass "recovery refuses, with a diagnostic, when the task or its endpoint cannot be resolved"
}

test_recovery_refuses_without_a_live_match() {
  local d; d=$(make_case refuse-no-match)
  setup_task "$d" stalled claude
  limit_prose_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 97)" \
    run_resume "$d" stalled >/dev/null 2>&1 && fail "recovery ran against a working pane"
  [ ! -s "$d/keys.log" ] || fail "a key was sent to a working pane"

  # An unreadable pane must refuse too, never assume.
  FM_FAKE_PANE_FILE="$d/missing.txt" FM_FAKE_QUOTA_JSON="$(quota_json 97)" \
    run_resume "$d" stalled >/dev/null 2>&1 && fail "recovery ran against an unreadable pane"
  [ ! -s "$d/keys.log" ] || fail "a key was sent to an unreadable pane"
  pass "recovery refuses unless the live pane proves the prompt is showing"
}

test_recovery_refuses_on_unreadable_quota() {
  local d; d=$(make_case refuse-quota)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_FAILS=1 \
    run_resume "$d" stalled >/dev/null 2>&1 && fail "recovery ran without a readable quota window"
  [ ! -s "$d/keys.log" ] || fail "a key was sent without a readable quota window"
  [ ! -s "$d/state/stalled.status" ] || fail "an unreadable quota window was recorded as a settled wait"
  pass "recovery refuses when the quota window cannot be read"
}

test_exhausted_window_records_a_bounded_wait() {
  local d out; d=$(make_case exhausted-wait)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 0)" \
    run_resume "$d" stalled) || fail "recording a bounded wait exited non-zero"
  [ ! -s "$d/keys.log" ] || fail "a key was sent while the window was still exhausted"
  [ ! -s "$d/sent.log" ] || fail "a steer was sent while the window was still exhausted"
  assert_contains "$out" "still exhausted" "the exhausted-window outcome was not reported"
  grep -q '^paused: ' "$d/state/stalled.status" \
    || fail "the bounded external wait was not recorded with the paused: vocabulary"

  # Idempotent: a recheck on the same unchanged wait must not stack lines, since
  # every status append wakes the supervisor.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 0)" \
    run_resume "$d" stalled >/dev/null || fail "the second recheck exited non-zero"
  [ "$(grep -c '^paused: ' "$d/state/stalled.status")" -eq 1 ] \
    || fail "re-running against an unchanged wait stacked duplicate paused: lines"
  pass "a still-exhausted window records one bounded external wait and sends nothing"
}

test_reset_window_dismisses_and_resumes() {
  local d out
  d=$(make_case reset-recover)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled) \
    || fail "recovery of a reset window exited non-zero"
  grep -qw Escape "$d/keys.log" || fail "recovery did not dismiss the prompt with Escape"
  [ "$(grep -c . "$d/keys.log")" -eq 1 ] || fail "recovery sent more than the single Escape"
  [ -s "$d/sent.log" ] || fail "recovery did not send a resume instruction"
  assert_contains "$(cat "$d/sent.log")" "re-read your own current state" \
    "the resume instruction did not tell the crew to re-check its actual state"
  assert_not_contains "$(cat "$d/sent.log")" "resume where you" \
    "the resume instruction asserted a remembered position"
  assert_contains "$out" "dismissed" "the recovery outcome was not reported"
  pass "a reset window is recovered with one Escape plus a re-check-your-state instruction"
}

test_recovery_stops_when_the_prompt_survives_escape() {
  local d; d=$(make_case escape-ignored)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  # No after-key pane: the prompt is still showing on the re-read.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 97)" \
    run_resume "$d" stalled >/dev/null 2>&1 && fail "recovery continued past a prompt that survived Escape"
  [ "$(grep -c . "$d/keys.log")" -eq 1 ] || fail "recovery escalated more keys after Escape did not land"
  [ ! -s "$d/sent.log" ] || fail "a resume instruction was sent while the prompt was still showing"
  pass "a prompt that survives Escape stops the run instead of escalating keys"
}

# The wait firstmate opens on the crew's behalf must not outlive the condition it
# describes. The crew never learns that line exists, so if recovery leaves it
# standing, a resume that silently does not take idles on the hour-long pause
# recheck instead of surfacing on the wedge cadence - the exact hours-unnoticed
# failure this feature exists to end.
test_recovery_closes_the_wait_it_opened() {
  local d last; d=$(make_case close-pause)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 0)" \
    run_resume "$d" stalled >/dev/null || fail "recording the bounded wait exited non-zero"
  grep -q '^paused: ' "$d/state/stalled.status" || fail "the bounded external wait was not recorded"

  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled >/dev/null \
    || fail "recovery after a recorded wait exited non-zero"
  [ -s "$d/sent.log" ] || fail "recovery did not send the resume instruction"
  last=$(grep -v '^[[:space:]]*$' "$d/state/stalled.status" | tail -1)
  case "$last" in
    paused:*) fail "recovery left its own paused: line standing as the crew's last event" ;;
  esac
  pass "recovery closes the bounded wait it opened, returning the crew to the wedge cadence"
}

# The close is owned, not blanket: it fires only for the line this script wrote.
test_recovery_closes_only_a_wait_it_owns() {
  local d; d=$(make_case foreign-pause)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled >/dev/null \
    || fail "recovery with no recorded wait exited non-zero"
  [ ! -s "$d/state/stalled.status" ] \
    || fail "recovery wrote a status line although it had no wait to close"

  # A pause the CREW declared for its own reason still means what it says.
  printf 'paused: waiting on the upstream release\n' > "$d/state/stalled.status"
  limit_prompt_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled >/dev/null \
    || fail "recovery over a crew-declared pause exited non-zero"
  [ "$(cat "$d/state/stalled.status")" = "paused: waiting on the upstream release" ] \
    || fail "recovery closed a paused: line it did not open"
  pass "recovery writes nothing when there is no wait of its own, and never closes the crew's"
}

# The dismissal proof must be POSITIVE. A pane that cannot be re-read after
# Escape establishes nothing about the prompt, so it must refuse exactly like a
# prompt that survived, rather than reading "did not match" as "gone".
test_recovery_stops_when_the_pane_is_unreadable_after_escape() {
  local d out; d=$(make_case escape-unreadable)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_UNREADABLE_AFTER_KEY=1 \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled 2>&1) \
    && fail "recovery continued past a pane it could not re-read after Escape"
  assert_contains "$out" "could not be read" "an unreadable re-read was not reported"
  [ "$(grep -c . "$d/keys.log")" -eq 1 ] || fail "recovery escalated more keys after an unreadable re-read"
  [ ! -s "$d/sent.log" ] || fail "a resume instruction was sent without proof the prompt was gone"
  pass "an unreadable pane after Escape refuses instead of steering on unproven dismissal"
}

# A malformed operator knob must never abort the run between the Escape and the
# steer: that would leave the crew dismissed, unsteered, and undiagnosed.
test_malformed_settle_falls_back_to_the_default() {
  local d; d=$(make_case settle-malformed)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" FM_LIMIT_RESUME_SETTLE=1.2.3 \
    run_resume "$d" stalled >/dev/null 2>&1 \
    || fail "a malformed settle value aborted the run after Escape had been sent"
  [ -s "$d/sent.log" ] || fail "the resume instruction did not land under a malformed settle value"
  pass "a malformed settle value falls back to the default instead of aborting mid-recovery"
}

test_failed_steer_is_reported_not_swallowed() {
  local d; d=$(make_case steer-fails)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" FM_FAKE_SEND_FAILS=1 \
    run_resume "$d" stalled >/dev/null 2>&1 \
    && fail "a resume instruction that did not land was reported as success"
  pass "a resume instruction that does not land is reported, not swallowed"
}

# The end the whole feature turns on: the recorded wait carries the reset time,
# so the supervisors recheck when the window actually rolls rather than up to an
# hour later. It is refreshed on each recheck, never left behind after recovery,
# and simply absent when the provider did not report a usable reset.
test_exhausted_wait_schedules_its_own_recheck() {
  local d soon later deadline
  d=$(make_case recheck-deadline)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  soon=$(( $(date +%s) + 2400 ))
  later=$(( $(date +%s) + 4800 ))

  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")") ]" '["five_hour"]')" \
    run_resume "$d" stalled >/dev/null || fail "recording the bounded wait exited non-zero"
  deadline=$(cat "$d/state/stalled.pause-recheck" 2>/dev/null || true)
  [ "$deadline" = "$(( soon + 60 ))" ] \
    || fail "the wait did not schedule its recheck from the reported reset, got '$deadline'"

  # A later recheck sees a window that will now roll later; the schedule follows
  # the current read rather than the first one.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$later")") ]" '["five_hour"]')" \
    run_resume "$d" stalled >/dev/null || fail "the second recheck exited non-zero"
  deadline=$(cat "$d/state/stalled.pause-recheck" 2>/dev/null || true)
  [ "$deadline" = "$(( later + 60 ))" ] || fail "the recheck deadline was not refreshed, got '$deadline'"

  # A window whose reset has already passed schedules nothing: the recheck is
  # happening now, and re-recording an elapsed deadline would fire every poll.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$(( $(date +%s) - 300 ))")") ]" '["five_hour"]')" \
    run_resume "$d" stalled >/dev/null || fail "the recheck on an elapsed reset exited non-zero"
  [ ! -e "$d/state/stalled.pause-recheck" ] \
    || fail "an elapsed reset was recorded as a deadline, which would re-fire every poll"

  # No reset reported at all: the wait is still recorded, just without a schedule.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 0)" \
    run_resume "$d" stalled >/dev/null || fail "the recheck without reset data exited non-zero"
  grep -q '^paused: ' "$d/state/stalled.status" || fail "the bounded wait itself was lost"
  [ ! -e "$d/state/stalled.pause-recheck" ] || fail "a deadline was invented without reset data"

  # Recovery clears the schedule with the wait, so nothing is left to fire later.
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json_windows 0 \
    "[ $(quota_window five_hour 0 "$(iso_at "$soon")") ]" '["five_hour"]')" \
    run_resume "$d" stalled >/dev/null || fail "re-recording the bounded wait exited non-zero"
  [ -e "$d/state/stalled.pause-recheck" ] || fail "the recheck deadline was not re-recorded"
  limit_prompt_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    FM_FAKE_QUOTA_JSON="$(quota_json 97)" run_resume "$d" stalled >/dev/null \
    || fail "recovery of the reset window exited non-zero"
  [ ! -e "$d/state/stalled.pause-recheck" ] || fail "recovery left its recheck deadline behind"
  pass "the recorded wait schedules its recheck from the reported reset, refreshes it, and clears it on recovery"
}

test_check_only_never_sends() {
  local d out; d=$(make_case check-only)
  setup_task "$d" stalled claude
  limit_prompt_pane > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 97)" \
    run_resume "$d" --check stalled) || fail "--check exited non-zero on a recoverable stall"
  assert_contains "$out" "recoverable" "--check did not report a recoverable stall"
  [ ! -s "$d/keys.log" ] || fail "--check sent a key"
  [ ! -s "$d/sent.log" ] || fail "--check sent a steer"
  [ ! -s "$d/state/stalled.status" ] || fail "--check wrote a status line"

  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_QUOTA_JSON="$(quota_json 0)" \
    run_resume "$d" --check stalled) || fail "--check exited non-zero on an exhausted window"
  assert_contains "$out" "still exhausted" "--check did not report the exhausted window"
  [ ! -s "$d/state/stalled.status" ] || fail "--check wrote a status line for an exhausted window"
  pass "--check reports the verdict without sending or recording anything"
}

test_signature_matches_the_real_prompt
test_signature_ignores_ordinary_limit_prose
test_signature_requires_every_anchor_in_order
test_signature_matches_plain_marker_and_ansi
test_quota_window_reset_and_exhausted
test_quota_window_fails_closed_to_unknown
test_reset_time_parses_without_a_platform_date
test_exhausted_window_reports_when_it_resets
test_missing_or_unreadable_reset_time_falls_back
test_pause_deadline_records_only_a_future_recheck
test_recovery_refuses_non_claude_harness
test_recovery_refuses_unresolvable_targets
test_recovery_refuses_without_a_live_match
test_recovery_refuses_on_unreadable_quota
test_exhausted_window_records_a_bounded_wait
test_reset_window_dismisses_and_resumes
test_recovery_stops_when_the_prompt_survives_escape
test_recovery_closes_the_wait_it_opened
test_recovery_closes_only_a_wait_it_owns
test_recovery_stops_when_the_pane_is_unreadable_after_escape
test_malformed_settle_falls_back_to_the_default
test_failed_steer_is_reported_not_swallowed
test_exhausted_wait_schedules_its_own_recheck
test_check_only_never_sends

echo "all fm-limit-resume tests passed"
