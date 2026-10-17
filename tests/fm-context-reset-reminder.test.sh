#!/usr/bin/env bash
# Behavior tests for bin/fm-context-reset-reminder.sh, the Claude Stop hook that
# resets a primary session past its threshold: automatically through a typist
# when the session's own pane can be found, otherwise by suggesting the
# stow-then-clear reset once per threshold crossing.
# Hermetic: synthetic Claude-shaped transcripts in temp primary homes; no real
# agent session is invoked and no pane is typed into: the automatic path is
# driven by sourcing the script with its launch and pane primitives replaced
# (tests/fm-context-reset-reminder-live-e2e.test.sh covers the real transcript
# shape, and tests/fm-context-reset-auto-live-e2e.test.sh the real pane).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-reset-reminder)
fm_git_identity fmtest fmtest@example.invalid

install_reminder() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-context-reset-reminder.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-hook-host-lib.sh" \
    "$ROOT/bin/fm-supervisor-target-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-context-reset-reminder.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_reminder "$dir"
  printf '%s\n' "$dir"
}

# Transcript entry writers, in the shape Claude Code records.
prompt() {  # <file> <text> [epoch]
  jq -cn --arg t "$2" --argjson at "${3:-1700000000}" \
    '{type:"user",timestamp:($at | todate | sub("Z$"; ".123Z")),message:{role:"user",content:$t}}' >> "$1"
}
meta_prompt() { jq -cn '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:"skill body"}]}}' >> "$1"; }
tool_result() { jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}' >> "$1"; }
assistant() {  # <file> <context-tokens> [sidechain] [text]
  jq -cn --argjson n "$2" --argjson side "${3:-false}" --arg text "${4:-x}" \
    '{type:"assistant",isSidechain:$side,message:{role:"assistant",content:[{type:"text",text:$text}],usage:{input_tokens:3,cache_read_input_tokens:($n - 13),cache_creation_input_tokens:10,output_tokens:5}}}' >> "$1"
}

synthetic() { jq -cn '{type:"assistant",message:{role:"assistant",model:"<synthetic>",content:[{type:"text",text:"No response requested."}],usage:{input_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:0}}}' >> "$1"; }

stop() {  # <home> <transcript> [extra payload jq] -> stdout; status in STOP_RC
  local payload
  payload=$(jq -cn --arg t "$2" "{session_id:\"s1\",transcript_path:\$t,hook_event_name:\"Stop\",stop_hook_active:false} ${3:-}")
  printf '%s' "$payload" | FM_CONTEXT_RESET_AUTO=0 FM_CONTEXT_RESET_TOKENS=1000 "$1/bin/fm-context-reset-reminder.sh"
}

test_fires_once_on_the_crossing_turn() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/once")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 400
  out=$(stop "$home" "$t"); expect_code 0 $? "below threshold"
  assert_equals "" "$out" "no reminder below the threshold"
  prompt "$t" two; assistant "$t" 700; tool_result "$t"; assistant "$t" 1100; tool_result "$t"; meta_prompt "$t"; assistant "$t" 1150
  out=$(stop "$home" "$t"); expect_code 0 $? "crossing turn"
  printf '%s' "$out" | jq -e '.systemMessage | type == "string"' >/dev/null || fail "reminder is not a JSON systemMessage: $out"
  assert_contains "$out" "run /stow, then /clear" "reminder names the full pass when none is recorded"
  assert_contains "$out" "about 1k tokens" "reminder reports the measured context"
  out=$(stop "$home" "$t")
  assert_contains "$out" "systemMessage" "a repeated Stop inside the crossing turn still reminds"
  prompt "$t" three; assistant "$t" 1300
  out=$(stop "$home" "$t")
  assert_equals "" "$out" "no second reminder on a later turn past the threshold"
  pass "reminder fires once, on the turn that crosses the threshold, ignoring mid-turn tool results and metadata entries"
}

test_compaction_rearms() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/rearm")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 1200
  prompt "$t" compacted; assistant "$t" 300
  out=$(stop "$home" "$t")
  assert_equals "" "$out" "no reminder after the count drops"
  prompt "$t" grow; assistant "$t" 1050
  out=$(stop "$home" "$t")
  assert_contains "$out" "systemMessage" "crossing again after a drop reminds again"
  pass "a context drop re-arms the reminder with no marker state"
}

test_synthetic_entries_are_not_measurements() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/synthetic")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 400
  prompt "$t" two; assistant "$t" 1100
  prompt "$t" three; synthetic "$t"
  out=$(stop "$home" "$t")
  assert_equals "" "$out" "a turn ending on a synthetic entry does not remind again"
  prompt "$t" four; assistant "$t" 1200
  out=$(stop "$home" "$t")
  assert_equals "" "$out" "the turn after a synthetic entry, still past the threshold, does not remind"
  t="$home/crossing.jsonl"
  prompt "$t" one; assistant "$t" 400
  prompt "$t" two; assistant "$t" 1100; synthetic "$t"
  out=$(stop "$home" "$t")
  assert_contains "$out" "systemMessage" "a crossing turn ending on a synthetic entry still reminds"
  pass "synthetic zero-usage entries neither re-arm nor hide the reminder"
}

test_first_turn_and_sidechain() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/first")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 200; assistant "$t" 5000 true
  out=$(stop "$home" "$t")
  assert_equals "" "$out" "sidechain usage is not this session's context"
  t="$home/first.jsonl"
  printf 'not json\n' > "$t"
  prompt "$t" one; assistant "$t" 1500
  out=$(stop "$home" "$t")
  assert_contains "$out" "systemMessage" "a first turn that crosses reminds, past an unparsable line"
  pass "sidechain calls are ignored and a crossing first turn reminds"
}

test_silent_outside_scope_or_without_input() {
  local home base wt t out
  home=$(make_primary_dir "$TMP_ROOT/scope")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 1500
  out=$(stop "$home" "$t" '+ {cursor_version:"1.0"}'); expect_code 0 $? "foreign host"
  assert_equals "" "$out" "a foreign-host duplicate payload stays silent"
  out=$(stop "$home" "$home/missing.jsonl"); expect_code 0 $? "missing transcript"
  assert_equals "" "$out" "a missing transcript stays silent"
  out=$(printf '' | "$home/bin/fm-context-reset-reminder.sh"); expect_code 0 $? "empty payload"
  assert_equals "" "$out" "an empty payload stays silent"
  base="$TMP_ROOT/scope-base"
  wt="$TMP_ROOT/scope-worktree"
  fm_git_worktree "$base" "$wt" fm/reminder-test
  mkdir -p "$wt/state"
  : > "$wt/AGENTS.md"
  install_reminder "$wt"
  out=$(stop "$wt" "$t"); expect_code 0 $? "task worktree"
  assert_equals "" "$out" "a task worktree is not a primary and stays silent"
  pass "silent for a foreign host, a missing transcript, an empty payload, and a task worktree"
}

test_tracked_claude_stop_registration_runs_the_reminder() {
  local home t cmd out all=''
  home=$(make_primary_dir "$TMP_ROOT/registered")
  printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$home/bin/fm-turnend-guard.sh"
  cp "$home/bin/fm-turnend-guard.sh" "$home/bin/fm-claude-stop-autoarm.sh"
  chmod +x "$home/bin/fm-turnend-guard.sh" "$home/bin/fm-claude-stop-autoarm.sh"
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 400; prompt "$t" two; assistant "$t" 1100
  while IFS= read -r cmd; do
    out=$(jq -cn --arg t "$t" '{session_id:"s1",transcript_path:$t,hook_event_name:"Stop"}' \
      | env -u GROK_AGENT -u GROK_HOOK_EVENT -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
        CLAUDE_PROJECT_DIR="$home" FM_CONTEXT_RESET_TOKENS=1000 bash -c "$cmd")
    all="$all$out"
  done < <(jq -r '.hooks.Stop[].hooks[].command' "$ROOT/.claude/settings.json")
  assert_contains "$all" "systemMessage" "the tracked Claude Stop hooks deliver the reminder"
  pass "tracked .claude/settings.json Stop hooks run the reminder"
}

# Drives the Stop hook in-process with the typist launch recorded instead of
# run, against a pane the discovery helper reports from its explicit override.
auto_stop() {  # <home> <transcript> [extra env assignments...] -> stdout; launches appended to $home/launches
  local home=$1 t=$2
  shift 2
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  jq -cn --arg t "$t" '{session_id:"s1",transcript_path:$t,hook_event_name:"Stop"}' \
    | env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID FM_SUPERVISOR_TARGET=lab:p1 FM_SUPERVISOR_BACKEND=herdr \
        FM_CONTEXT_RESET_TOKENS=1000 "$@" bash -c '
      home=$1
      . "$home/bin/fm-context-reset-reminder.sh"
      fm_context_reset_launch() { printf "%s\n" "$*" >> "$home/launches"; }
      fm_context_reset_stop_hook' _ "$home"
}

record_field() { sed -n "s/^$2=//p" "$1/state/.context-reset" 2>/dev/null; }
launches() { cat "$1/launches" 2>/dev/null; }

test_auto_types_the_stow_then_clear() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/auto")
  t="$home/t.jsonl"
  prompt "$t" one 1700000000; assistant "$t" 400
  out=$(auto_stop "$home" "$t")
  assert_equals "" "$out$(launches "$home")" "nothing happens below the threshold"
  prompt "$t" two 1700000100; assistant "$t" 1200
  out=$(auto_stop "$home" "$t")
  assert_equals "" "$out" "the automatic path never needs the operator"
  assert_contains "$(launches "$home")" "herdr lab:p1 /stow" "with no curation pass recorded the typist types the full pass"
  assert_equals typing "$(record_field "$home" phase)" "the record holds the pending typist"
  out=$(auto_stop "$home" "$t")
  assert_equals 1 "$(launches "$home" | wc -l | tr -d ' ')" "a repeated Stop inside the same turn does not launch a second typist"
  date +%s > "$home/state/.stow-curated"
  printf 'phase=stow\ntranscript=%s\n' "$t" > "$home/state/.context-reset"
  prompt "$t" "/stow light" 1700000200; assistant "$t" 1250
  echo 1700000250 > "$home/state/.context-reset-safe"
  out=$(auto_stop "$home" "$t")
  assert_equals "" "$out" "a safe stow needs no message"
  assert_contains "$(launches "$home" | tail -1)" "herdr lab:p1 /clear" "a reset-safe verdict written during the turn types /clear"
  : > "$home/launches"
  rm -f "$home/state/.context-reset"
  prompt "$t" three 1700000300; assistant "$t" 1300
  out=$(auto_stop "$home" "$t")
  assert_contains "$(launches "$home")" "herdr lab:p1 /stow light" "a recent curation pass makes the typist type the light pass"
  assert_not_contains "$(launches "$home")" "/clear" "a reset-safe verdict from an earlier turn never types /clear"
  pass "automatic reset: stow first (light once curated), /clear only on a verdict from the turn that just ended"
}

test_auto_declined_stow_stops_once() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/declined")
  t="$home/t.jsonl"
  prompt "$t" "/stow light" 1700000000; assistant "$t" 1200
  printf 'phase=stow\ntranscript=%s\n' "$t" > "$home/state/.context-reset"
  out=$(auto_stop "$home" "$t")
  assert_contains "$out" "did not report this session safe" "a declined stow is reported to the operator"
  assert_equals "" "$(launches "$home")" "a declined stow types nothing"
  prompt "$t" four 1700000100; assistant "$t" 1300
  out=$(auto_stop "$home" "$t")
  assert_equals "" "$out$(launches "$home")" "after a decline the transcript gets no further attempt or message"
  prompt "$t" compacted 1700000200; assistant "$t" 300
  out=$(auto_stop "$home" "$t")
  [ ! -e "$home/state/.context-reset" ] || fail "a drop below the threshold did not clear the record"
  prompt "$t" grow 1700000300; assistant "$t" 1100
  out=$(auto_stop "$home" "$t")
  assert_contains "$(launches "$home")" "/stow" "a drop below the threshold re-arms the automatic reset"
  pass "a declined stow is reported once, and only a context drop re-arms it"
}

test_auto_waits_for_an_open_question() {
  local home t
  home=$(make_primary_dir "$TMP_ROOT/question")
  t="$home/t.jsonl"
  prompt "$t" one 1700000000; assistant "$t" 1200 false "The PR is green. Merge https://example.invalid/pr?x=1 now?"
  auto_stop "$home" "$t" >/dev/null
  assert_equals "" "$(launches "$home")" "a final message asking the operator a question defers the reset"
  assert_equals armed "$(record_field "$home" phase)" "the deferred attempt stays armed"
  prompt "$t" yes 1700000100; assistant "$t" 1250 false "Merged https://example.invalid/pr?x=1 and cleaned up."
  auto_stop "$home" "$t" >/dev/null
  assert_contains "$(launches "$home")" "/stow" "once answered, the next Stop starts the reset; a ? inside a URL is no question"
  pass "an open question to the operator defers the automatic reset until a later Stop"
}

test_auto_falls_back_to_the_reminder() {
  local home t out
  home=$(make_primary_dir "$TMP_ROOT/fallback")
  t="$home/t.jsonl"
  prompt "$t" one; assistant "$t" 1200
  out=$(auto_stop "$home" "$t" FM_CONTEXT_RESET_AUTO=0)
  assert_contains "$out" "then /clear" "automation off reminds instead"
  out=$(jq -cn --arg t "$t" '{transcript_path:$t}' | env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
    FM_CONTEXT_RESET_TOKENS=1000 "$home/bin/fm-context-reset-reminder.sh")
  assert_contains "$out" "then /clear" "with no pane to type into the hook reminds instead"
  printf 'mate1\n' > "$home/.fm-secondmate-home"
  out=$(auto_stop "$home" "$t")
  assert_contains "$out" "then /clear" "a secondmate home reminds instead"
  assert_equals "" "$(launches "$home")" "no fallback ever launches a typist"
  pass "automation off, no pane, and a secondmate home all fall back to the one-time reminder"
}

# Runs the typist in-process against scripted pane reads.
deliver() {  # <home> <token> <idle-script> <submit-verdict> -> submits appended to $home/submits
  local home=$1
  FM_CONTEXT_RESET_WAIT_SECS=2 FM_CONTEXT_RESET_SETTLE_SECS=1 bash -c '
    home=$1 token=$2 idle_script=$3 submit_verdict=$4
    . "$home/bin/fm-context-reset-reminder.sh"
    fm_context_reset_pane_idle() { eval "$idle_script"; }
    fm_backend_send_text_submit() { printf "%s\n" "$*" >> "$home/submits"; printf "%s" "$submit_verdict"; }
    fm_context_reset_deliver "$token" herdr lab:p1 "/stow light"' _ "$home" "$2" "$3" "$4"
}

test_deliver_types_only_into_an_idle_pane() {
  local home
  home=$(make_primary_dir "$TMP_ROOT/deliver")
  printf 'transcript=t\nphase=typing\ntoken=k1\n' > "$home/state/.context-reset"
  deliver "$home" k1 'return 0' empty
  assert_contains "$(cat "$home/submits")" "herdr lab:p1 /stow light 3 0.5 1.2" "an idle pane receives the text"
  assert_equals stow "$(record_field "$home" phase)" "a confirmed stow submit is recorded"
  rm -f "$home/submits"
  printf 'transcript=t\nphase=typing\ntoken=k2\n' > "$home/state/.context-reset"
  deliver "$home" k2 'return 1' empty
  [ ! -e "$home/submits" ] || fail "a pane that never went idle was typed into"
  assert_equals armed "$(record_field "$home" phase)" "an idle wait that times out leaves the attempt armed"
  assert_contains "$(record_field "$home" note)" "not idle" "the timeout is noted"
  printf 'transcript=t\nphase=typing\ntoken=k3\n' > "$home/state/.context-reset"
  deliver "$home" k3 'return 0' pending
  assert_equals armed "$(record_field "$home" phase)" "an unconfirmed submit leaves the attempt armed"
  rm -f "$home/submits"
  printf 'transcript=t\nphase=typing\ntoken=newer\n' > "$home/state/.context-reset"
  deliver "$home" k4 'return 0' empty
  [ ! -e "$home/submits" ] || fail "a superseded typist typed"
  assert_equals newer "$(record_field "$home" token)" "a superseded typist leaves the newer record alone"
  pass "the typist types only into a pane read idle twice, only while its record is current"
}

test_record_command() {
  local home
  home=$(make_primary_dir "$TMP_ROOT/record")
  "$home/bin/fm-context-reset-reminder.sh" record reset-safe; expect_code 0 $? "record reset-safe"
  "$home/bin/fm-context-reset-reminder.sh" record curated; expect_code 0 $? "record curated"
  grep -qE '^[0-9]+$' "$home/state/.context-reset-safe" || fail "reset-safe record holds no epoch"
  grep -qE '^[0-9]+$' "$home/state/.stow-curated" || fail "curated record holds no epoch"
  "$home/bin/fm-context-reset-reminder.sh" record other 2>/dev/null; expect_code 2 $? "unknown record kind"
  pass "record writes the reset-safe and curated epochs and refuses an unknown kind"
}

test_fires_once_on_the_crossing_turn
test_compaction_rearms
test_synthetic_entries_are_not_measurements
test_first_turn_and_sidechain
test_silent_outside_scope_or_without_input
test_tracked_claude_stop_registration_runs_the_reminder
test_auto_types_the_stow_then_clear
test_auto_declined_stow_stops_once
test_auto_waits_for_an_open_question
test_auto_falls_back_to_the_reminder
test_deliver_types_only_into_an_idle_pane
test_record_command
