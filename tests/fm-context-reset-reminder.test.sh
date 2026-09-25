#!/usr/bin/env bash
# Behavior tests for bin/fm-context-reset-reminder.sh, the Claude Stop hook that
# suggests the stow-then-clear session reset once per threshold crossing.
# Hermetic: synthetic Claude-shaped transcripts in temp primary homes; no real
# agent session is invoked (tests/fm-context-reset-reminder-live-e2e.test.sh
# covers the real transcript shape).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-reset-reminder)
fm_git_identity fmtest fmtest@example.invalid

install_reminder() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-context-reset-reminder.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
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
prompt() { jq -cn --arg t "$2" '{type:"user",message:{role:"user",content:$t}}' >> "$1"; }
meta_prompt() { jq -cn '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:"skill body"}]}}' >> "$1"; }
tool_result() { jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}' >> "$1"; }
assistant() {  # <file> <context-tokens> [sidechain]
  jq -cn --argjson n "$2" --argjson side "${3:-false}" \
    '{type:"assistant",isSidechain:$side,message:{role:"assistant",content:[{type:"text",text:"x"}],usage:{input_tokens:3,cache_read_input_tokens:($n - 13),cache_creation_input_tokens:10,output_tokens:5}}}' >> "$1"
}

synthetic() { jq -cn '{type:"assistant",message:{role:"assistant",model:"<synthetic>",content:[{type:"text",text:"No response requested."}],usage:{input_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:0}}}' >> "$1"; }

stop() {  # <home> <transcript> [extra payload jq] -> stdout; status in STOP_RC
  local payload
  payload=$(jq -cn --arg t "$2" "{session_id:\"s1\",transcript_path:\$t,hook_event_name:\"Stop\",stop_hook_active:false} ${3:-}")
  printf '%s' "$payload" | FM_CONTEXT_RESET_TOKENS=1000 "$1/bin/fm-context-reset-reminder.sh"
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
  assert_contains "$out" "/stow, then /clear" "reminder names the reset procedure"
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
      | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$home" FM_CONTEXT_RESET_TOKENS=1000 bash -c "$cmd")
    all="$all$out"
  done < <(jq -r '.hooks.Stop[].hooks[].command' "$ROOT/.claude/settings.json")
  assert_contains "$all" "systemMessage" "the tracked Claude Stop hooks deliver the reminder"
  pass "tracked .claude/settings.json Stop hooks run the reminder"
}

test_fires_once_on_the_crossing_turn
test_compaction_rearms
test_synthetic_entries_are_not_measurements
test_first_turn_and_sidechain
test_silent_outside_scope_or_without_input
test_tracked_claude_stop_registration_runs_the_reminder
