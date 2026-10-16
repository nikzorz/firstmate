#!/usr/bin/env bash
# The postmortem skill's session helper, .agents/skills/postmortem/sessions.py,
# finds the agent session that wrote a line and shows what that session had in
# front of it. These cases drive it against a fixture transcript root.
#
# A write made through the shell (git mv, a redirect, a heredoc) must count as
# WROTE, not as a mention, or the trace lands on the wrong session; and a
# no-mistakes agent's session must be labelled as the pipeline's, because the
# reviewer side and pipeline fix rounds are traced through those sessions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/.agents/skills/postmortem/sessions.py"
TMP_ROOT=$(fm_test_tmproot fm-postmortem-sessions)
TR="$TMP_ROOT/projects"

sessions() {
  python3 -I "$HELPER" --root "$TR" "$@" 2>&1
}

# transcript <relative path> <cwd> <start time> <end time> <prompt> <tool use JSON>...
# Writes one session: a prompt at the start time, one assistant record per tool
# use, and a closing record at the end time.
transcript() {
  local rel=$1 cwd=$2 start=$3 end=$4 prompt=$5 use
  shift 5
  mkdir -p "$(dirname "$TR/$rel")"
  {
    printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"%s"}}\n' "$start" "$cwd" "$prompt"
    for use in "$@"; do
      printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"tool_use","name":%s]}}\n' "$start" "$cwd" "$use"
    done
    printf '{"type":"system","timestamp":"%s","cwd":"%s"}\n' "$end" "$cwd"
  } >"$TR/$rel"
}

WT=/work/pool/1/arena
transcript -work-pool-1-arena/edit.jsonl "$WT" 2026-10-15T10:00:00Z 2026-10-15T11:00:00Z "ship the motion test" \
  '"Edit","input":{"file_path":"/work/pool/1/arena/scripts/motion.gd","old_string":"a","new_string":"var settle_frames = 2"}}'
transcript -work-pool-1-arena/reader.jsonl "$WT" 2026-10-15T10:10:00Z 2026-10-15T10:20:00Z "look around" \
  '"Bash","input":{"command":"grep -n settle_frames scripts/motion.gd > /tmp/hits.txt"}}' \
  '"Read","input":{"file_path":"/work/pool/1/arena/scripts/motion.gd"}}'
transcript -work-pool-1-arena/later.jsonl "$WT" 2026-10-16T10:00:00Z 2026-10-16T10:30:00Z "a later session" \
  '"Write","input":{"file_path":"/work/pool/1/arena/notes.md","content":"var settle_frames = 2"}}'
transcript -work-pool-1-arena/gitmv.jsonl "$WT" 2026-10-15T12:00:00Z 2026-10-15T12:30:00Z "move the test" \
  '"Bash","input":{"command":"git mv tests/unit/test_motion.gd tests/integration/test_motion.gd"}}'
transcript -work-pool-1-arena/heredoc.jsonl "$WT" 2026-10-15T13:00:00Z 2026-10-15T13:30:00Z "write the doc" \
  '"Bash","input":{"command":"cd docs && cat > design.md <<'"'"'EOF'"'"'\nThe frame budget is unit_budget_ms.\nEOF"}}'
transcript -work-pool-1-arena/redirect.jsonl "$WT" 2026-10-15T14:00:00Z 2026-10-15T14:30:00Z "append a row" \
  '"Bash","input":{"command":"printf x >> docs/ledger.tsv"}}'
transcript -work-pool-1-arena/script.jsonl "$WT" 2026-10-15T15:00:00Z 2026-10-15T15:30:00Z "patch it" \
  '"Bash","input":{"command":"python3 - <<'"'"'EOF'"'"'\np = '"'"'tools/ci/setup.sh'"'"'\ns = open(p).read()\nopen(p, '"'"'w'"'"').write(s)\nEOF"}}'
transcript -work-pool-1-arena/script-read.jsonl "$WT" 2026-10-15T15:40:00Z 2026-10-15T15:50:00Z "count it" \
  '"Bash","input":{"command":"python3 -c \"print(open('"'"'tools/ci/setup.sh'"'"').read().count(chr(10)))\""}}'
transcript -work-pool-1-arena/quoted.jsonl "$WT" 2026-10-15T16:00:00Z 2026-10-15T16:10:00Z "search it" \
  '"Bash","input":{"command":"rg -n \"=> settle_frames\" scripts"}}'
transcript -work-pool-1-arena/heredoc-then-run.jsonl "$WT" 2026-10-15T16:20:00Z 2026-10-15T16:30:00Z "note and run" \
  '"Bash","input":{"command":"cat > /tmp/notes.md <<EOF\nscratch\nEOF\nbash tests/motion.test.sh"}}'
transcript -work-pool-1-arena/script-then-read.jsonl "$WT" 2026-10-15T16:40:00Z 2026-10-15T16:50:00Z "scratch then read" \
  '"Bash","input":{"command":"python3 -c \"open('"'"'/tmp/o'"'"', '"'"'w'"'"').write('"'"'x'"'"')\"; cat docs/ledger.tsv"}}'
transcript -work-pool-1-arena/edit-removes.jsonl "$WT" 2026-10-15T17:00:00Z 2026-10-15T17:10:00Z "drop the budget" \
  '"Edit","input":{"file_path":"/work/pool/1/arena/docs/design.md","old_string":"The frame budget is unit_budget_ms.","new_string":""}}'
# shellcheck disable=SC2016  # literal fixture command, must not expand
transcript -work-pool-1-arena/commit.jsonl "$WT" 2026-10-15T17:20:00Z 2026-10-15T17:30:00Z "commit it" \
  '"Bash","input":{"command":"git commit -m \"settle_frames: a patch\""}}' \
  '"Bash","input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nrm the old settle_frames patch\nEOF\n)\""}}'
transcript -work-pool-1-arena/comment.jsonl "$WT" 2026-10-15T17:40:00Z 2026-10-15T17:50:00Z "tidy up" \
  '"Bash","input":{"command":"echo hi # don'"'"'t clobber it\nprintf row >> docs/comment-ledger.tsv\n# don'"'"'t keep it\nrm docs/old-notes.md"}}'
bash_session() {  # <name> <command, JSON-escaped>
  transcript "-work-pool-1-arena/$1.jsonl" "$WT" 2026-10-15T18:00:00Z 2026-10-15T18:10:00Z "$1" \
    '"Bash","input":{"command":"'"$2"'"}}'
}
bash_session quoted-gt 'grep -c \">\" scripts/quoted-gt.gd && rg -n '"'"'>'"'"' scripts/quoted-gt.gd'
bash_session url-fragment 'curl -sL https://example.com/page#top > docs/page.html'
# shellcheck disable=SC2016  # literal fixture command, must not expand
bash_session array-length 'echo ${#arr[@]} > out/count.txt'
bash_session sed-hash 'sed -i s#old#new# scripts/sed-target.gd'
bash_session quoted-heredoc 'rg \"<<EOF\" docs\ncp a scripts/after-quoted-heredoc.gd'
# shellcheck disable=SC2016  # literal fixture command, must not expand
bash_session arithmetic-shift 'echo $((1<<3))\ncp a scripts/after-shift.gd'
bash_session for-do 'for f in a b; do sed -i s/x/y/ scripts/loop-target.gd; done'
bash_session if-then 'if true; then cp a scripts/if-target.gd; fi'
bash_session while-do 'while read f; do rm scripts/while-target.gd; done < list.txt'
bash_session xargs-sed 'rg -l x | xargs -n 1 sed -i s/x/y/ scripts/xargs-target.gd'
bash_session sudo-cp 'sudo -u root cp a scripts/sudo-target.gd'
bash_session sudo-n 'sudo -n cp a scripts/sudo-n-target.gd'
bash_session timeout-read 'timeout 5 rg install scripts/timeout-read.gd'
bash_session xargs-read 'rg -l x | xargs grep -n patch scripts/xargs-read.gd'
bash_session sudo-e 'sudo -E cp a scripts/sudo-e-target.gd'
bash_session env-cp 'env -i FOO=1 cp a scripts/env-target.gd'
bash_session timeout-cp 'timeout -s KILL 5s cp a scripts/timeout-target.gd'
transcript -work-pool-1-arena/edit/subagents/agent-1.jsonl "$WT" 2026-10-15T10:30:00Z 2026-10-15T10:40:00Z "subagent task" \
  '"Read","input":{"file_path":"/work/pool/1/arena/scripts/motion.gd","note":"var settle_frames = 2"}}'
transcript -home-me--no-mistakes-worktrees-8558e7c04f3e-01RUNID/review.jsonl \
  /home/me/.no-mistakes/worktrees/8558e7c04f3e/01RUNID 2026-10-15T15:00:00Z 2026-10-15T15:20:00Z \
  "Workspace boundary. You are the review phase inside an already active no-mistakes run. Review it." \
  '"Read","input":{"file_path":"/home/me/.no-mistakes/worktrees/8558e7c04f3e/01RUNID/docs/ledger.tsv"}}'

line_for() {  # <output> <transcript basename>
  printf '%s\n' "$1" | grep -F -- "$2" | head -1
}

test_find_marks_the_writer_at_the_commit_time() {
  local out
  out=$(sessions find 'var settle_frames = 2' --at 2026-10-15T10:30:00Z)
  assert_contains "$(line_for "$out" edit.jsonl)" 'WROTE AT' "the Edit session spanning the commit time is the AT writer"
  assert_contains "$(line_for "$out" agent-1.jsonl)" 'mentions AT' "a subagent that only read the text is a mention"
  assert_contains "$(line_for "$out" agent-1.jsonl)" 'subagent' "a subagent transcript is labelled as one"
  assert_not_contains "$out" later.jsonl "a session a day away is outside the window"
  out=$(sessions show "$(line_for "$out" edit.jsonl | awk '{print $NF}')")
  assert_contains "$out" "== Files edited (1)" "show takes the transcript path exactly as find printed it"
  pass "find marks the session that wrote the needle at the commit time"
}

test_find_without_a_time_lists_every_session_oldest_first() {
  local out first last
  out=$(sessions find 'var settle_frames = 2' | grep -E '^(WROTE|mentions)')
  first=$(printf '%s\n' "$out" | head -1)
  last=$(printf '%s\n' "$out" | tail -1)
  assert_contains "$first" edit.jsonl "the oldest session comes first"
  assert_contains "$last" later.jsonl "the newest session comes last"
  pass "find with no --at lists every matching session in time order"
}

test_shell_writes_count_as_writes() {
  local out
  out=$(sessions find tests/integration/test_motion.gd)
  assert_contains "$(line_for "$out" gitmv.jsonl)" WROTE "a git mv onto the path is a write"
  out=$(sessions find unit_budget_ms)
  assert_contains "$(line_for "$out" heredoc.jsonl)" WROTE "text written out through a heredoc is a write"
  out=$(sessions find docs/ledger.tsv)
  assert_contains "$(line_for "$out" redirect.jsonl)" WROTE "a redirect onto the path is a write"
  assert_contains "$(line_for "$out" review.jsonl)" mentions "reading the path is only a mention"
  out=$(sessions find tools/ci/setup.sh)
  assert_contains "$(line_for "$out" script.jsonl)" WROTE "an inline script that opens the path for writing is a write"
  assert_contains "$(line_for "$out" script-read.jsonl)" mentions "an inline script that only reads the path is a mention"
  out=$(sessions find scripts/motion.gd)
  assert_contains "$(line_for "$out" reader.jsonl)" mentions "a grep of the path redirected elsewhere is not a write to it"
  pass "shell-made writes are reported as WROTE and reads as mentions"
}

test_reads_that_look_like_writes_are_mentions() {
  local out
  out=$(sessions find settle_frames)
  assert_contains "$(line_for "$out" quoted.jsonl)" mentions "a > inside a quoted argument is not a redirect"
  assert_contains "$(line_for "$out" commit.jsonl)" mentions "a write verb inside a commit message is not a write"
  out=$(sessions find tests/motion.test.sh)
  assert_contains "$(line_for "$out" heredoc-then-run.jsonl)" mentions "a command after a heredoc's terminator is not in its body"
  out=$(sessions find docs/ledger.tsv)
  assert_contains "$(line_for "$out" script-then-read.jsonl)" mentions "a read beside a writing inline script is not written by it"
  out=$(sessions find unit_budget_ms)
  assert_contains "$(line_for "$out" edit-removes.jsonl)" mentions "an Edit that removes the text does not write it"
  out=$(sessions find scratch)
  assert_contains "$(line_for "$out" heredoc-then-run.jsonl)" WROTE "the heredoc body itself is still written"
  out=$(sessions find docs/comment-ledger.tsv)
  assert_contains "$(line_for "$out" comment.jsonl)" WROTE "an apostrophe in a comment does not hide a later redirect"
  out=$(sessions find docs/old-notes.md)
  assert_contains "$(line_for "$out" comment.jsonl)" WROTE "a write verb on the line after a comment is in command position"
  out=$(sessions find scripts/quoted-gt.gd)
  assert_contains "$(line_for "$out" quoted-gt.jsonl)" mentions "a quoted > before the path is not a redirect onto it"
  pass "reads shaped like writes are reported as mentions"
}

test_hash_and_shift_inside_words_hide_no_writes() {
  local out
  out=$(sessions find docs/page.html)
  assert_contains "$(line_for "$out" url-fragment.jsonl)" WROTE "a # inside a URL does not start a comment"
  out=$(sessions find out/count.txt)
  assert_contains "$(line_for "$out" array-length.jsonl)" WROTE "a # inside \${#arr[@]} does not start a comment"
  out=$(sessions find scripts/sed-target.gd)
  assert_contains "$(line_for "$out" sed-hash.jsonl)" WROTE "a # inside a sed expression does not start a comment"
  out=$(sessions find scripts/after-quoted-heredoc.gd)
  assert_contains "$(line_for "$out" quoted-heredoc.jsonl)" WROTE "a quoted <<EOF opens no heredoc"
  out=$(sessions find scripts/after-shift.gd)
  assert_contains "$(line_for "$out" arithmetic-shift.jsonl)" WROTE "a shift inside \$((...)) opens no heredoc"
  pass "a # or << inside a word hides no later write"
}

test_writes_behind_keywords_and_wrappers_count() {
  local out name target
  for name in for-do:loop-target if-then:if-target while-do:while-target xargs-sed:xargs-target sudo-cp:sudo-target \
    sudo-n:sudo-n-target sudo-e:sudo-e-target env-cp:env-target timeout-cp:timeout-target; do
    target=scripts/${name#*:}.gd
    out=$(sessions find "$target")
    assert_contains "$(line_for "$out" "${name%%:*}.jsonl")" WROTE "a write after ${name%%:*} is a write to $target"
  done
  for name in timeout-read xargs-read; do
    out=$(sessions find "scripts/$name.gd")
    assert_contains "$(line_for "$out" "$name.jsonl")" mentions "a read behind a wrapper is not a write, even with a verb as an argument"
  done
  pass "a write verb behind a shell keyword or wrapper is reported as WROTE"
}

test_pipeline_sessions_are_labelled() {
  local out
  out=$(sessions find docs/ledger.tsv)
  assert_contains "$(line_for "$out" review.jsonl)" 'pipeline 01RUNID review' "a no-mistakes agent session names its run and phase"
  assert_contains "$(line_for "$out" redirect.jsonl)" 'session' "a worker session keeps the plain label"
  pass "no-mistakes agent sessions are labelled with their run and phase"
}

test_no_match_fails_with_a_hint() {
  local out code
  out=$(sessions find 'text nobody wrote' --at 2026-10-15T10:30:00Z)
  code=$?
  expect_code 1 "$code" "find with no match"
  assert_contains "$out" 'No session matched. Widen --slack' "the miss names the next step"
  pass "find with no match exits non-zero and suggests widening"
}

test_show_lists_what_the_session_had() {
  local rel=-work-pool-1-arena/shown.jsonl out
  mkdir -p "$TR/-work-pool-1-arena"
  cat >"$TR/$rel" <<EOF
{"type":"attachment","timestamp":"2026-10-15T09:00:00Z","cwd":"$WT","attachment":{"type":"instructions","files":[{"path":"$WT/AGENTS.md","type":"Project","content":"rules"}]}}
{"type":"user","timestamp":"2026-10-15T09:00:01Z","cwd":"$WT","message":{"role":"user","content":"<command-name>/no-mistakes</command-name>"}}
{"type":"assistant","timestamp":"2026-10-15T09:01:00Z","cwd":"$WT","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"diagnostic-reasoning"}},{"type":"tool_use","name":"Read","input":{"file_path":"$WT/scripts/motion.gd"}},{"type":"tool_use","name":"Read","input":{"file_path":"$WT/scripts/motion.gd"}}]}}
{"type":"attachment","timestamp":"2026-10-15T09:01:01Z","cwd":"$WT","attachment":{"type":"nested_memory","path":"$WT/.claude/rules/test-placement.md","content":{}}}
{"type":"assistant","timestamp":"2026-10-15T09:02:00Z","cwd":"$WT","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"$WT/scripts/motion.gd"}},{"type":"tool_use","name":"Bash","input":{"command":"git mv a.gd b.gd"}},{"type":"tool_use","name":"Bash","input":{"command":"git status"}},{"type":"tool_use","name":"Bash","input":{"command":"awk '\$2 > 0' f.tsv"}},{"type":"tool_use","name":"Bash","input":{"command":"git commit -m \\"a patch\\""}},{"type":"tool_use","name":"Bash","input":{"command":"command -v rm"}}]}}
{"type":"attachment","timestamp":"2026-10-15T09:30:00Z","cwd":"$WT","attachment":{"type":"nested_memory","path":"$WT/.claude/rules/late-rule.md","content":{}}}
EOF
  out=$(sessions show -- "$rel")
  assert_contains "$out" "Project  $WT/AGENTS.md" "always-on instructions are listed as loaded at start"
  assert_contains "$out" ".claude/rules/test-placement.md" "a path-scoped rule loaded mid-session is listed"
  assert_contains "$out" "/no-mistakes" "a slash command is listed as a skill"
  assert_contains "$out" "diagnostic-reasoning" "a Skill tool call is listed"
  assert_contains "$out" "== Files edited (1)" "the Edit is listed as an edit"
  assert_contains "$out" "WRITE git mv a.gd b.gd" "a write-shaped command is marked"
  assert_contains "$out" "      git status" "a read-only command is not marked"
  assert_contains "$out" "      awk '\$2 > 0' f.tsv" "a > inside quotes does not mark a command"
  assert_contains "$out" '      git commit -m "a patch"' "a write verb inside a quoted argument does not mark a command"
  assert_contains "$out" "      command -v rm" "a command -v lookup is not marked"
  assert_contains "$out" "== Files read (1)" "a file read twice counts once"
  assert_contains "$out" "late-rule.md" "without --before every rule is listed"
  out=$(sessions show "$TR/$rel" --before 2026-10-15T09:10:00Z)
  assert_not_contains "$out" "late-rule.md" "--before drops what the session loaded after that time"
  assert_contains "$out" "test-placement.md" "--before keeps what it had by then"
  pass "show lists what one session loaded, invoked, read, edited and ran"
}

test_helper_changes_nothing() {
  local before after
  before=$(find "$TR" -type f -exec cksum {} + | LC_ALL=C sort)
  sessions find 'var settle_frames = 2' >/dev/null
  sessions show -work-pool-1-arena/edit.jsonl >/dev/null
  after=$(find "$TR" -type f -exec cksum {} + | LC_ALL=C sort)
  assert_equals "$before" "$after" "the transcript root is unchanged"
  pass "the helper only reads"
}

test_find_marks_the_writer_at_the_commit_time
test_find_without_a_time_lists_every_session_oldest_first
test_shell_writes_count_as_writes
test_reads_that_look_like_writes_are_mentions
test_hash_and_shift_inside_words_hide_no_writes
test_writes_behind_keywords_and_wrappers_count
test_pipeline_sessions_are_labelled
test_no_match_fails_with_a_hint
test_show_lists_what_the_session_had
test_helper_changes_nothing
