#!/usr/bin/env bash
# Tests for bin/fm-attribution-lib.sh: the single owner of what counts as an
# agent attribution trailer, used by bin/fm-pr-merge.sh to keep the harnesses'
# injected co-author and session lines off the default branch. The
# .claude/settings.json knob that keeps those lines off branch commits in the
# first place is guarded here too, because it is the same guarantee.
#
# Matrix:
#   (a) a claude co-author trailer and its session link are removed
#   (b) a codex co-author trailer is removed
#   (c) human co-authors survive, whatever the agent display name was
#   (d) a message with no agent attribution keeps every interior byte
#   (e) the forge's nine-hyphen separator left introducing an emptied co-author
#       block is dropped
#   (f) the forge's separator introducing surviving co-authors is kept
#   (g) an author's own rule survives a removal made above it
#   (h) an author's own rule survives an agent trailer removed directly under it
#   (i) leading and trailing blank lines are dropped with or without a removal
#   (j) blank runs are collapsed only where a removal created them
#   (k) the .claude/settings.json knob still disables claude's own injection
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-attribution-lib.sh
. "$ROOT/bin/fm-attribution-lib.sh"

# Compare fm_attribution_strip's output against an expected message, byte for
# byte: the sentinel keeps command substitution from eating trailing newlines,
# which is where the leading/trailing blank-line contract is observable.
# Args: label input expected
expect_strip() {
  local label=$1 input=$2 expected=$3 actual
  actual=$(printf '%s' "$input" | fm_attribution_strip; printf 'X')
  actual=${actual%X}
  [ "$actual" = "$expected" ] || fail "$label: expected
---
$expected
---
but got
---
$actual
---"
}

test_removes_claude_trailers() {
  expect_strip "claude" \
'fix: a thing

Body.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0TEST
' \
'fix: a thing

Body.
'
  pass "fm_attribution_strip removes a claude co-author trailer and its session link"
}

test_removes_codex_trailer() {
  expect_strip "codex" \
'fix: a thing

Co-authored-by: Codex <noreply@openai.com>
' \
'fix: a thing
'
  pass "fm_attribution_strip removes a codex co-author trailer"
}

test_keeps_human_coauthors() {
  expect_strip "humans" \
'fix: a thing

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>
Co-authored-by: Claude <noreply@anthropic.com>
Co-authored-by: A Person Named Claude <person@example.invalid>
' \
'fix: a thing

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>
Co-authored-by: A Person Named Claude <person@example.invalid>
'
  pass "fm_attribution_strip keeps human co-authors and matches agents by address, not name"
}

test_clean_message_is_unchanged() {
  local message='fix: a thing

First paragraph.


Second paragraph after a deliberate double blank.

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>'
  expect_strip "clean" "$message
" "$message
"
  pass "fm_attribution_strip passes a message with no agent attribution through unchanged"
}

test_drops_separator_left_introducing_nothing() {
  expect_strip "empty-separator" \
'* fix: a thing

* no-mistakes(review): tighten it

---------

Co-authored-by: Claude Opus 5 <noreply@anthropic.com>
' \
'* fix: a thing

* no-mistakes(review): tighten it
'
  pass "fm_attribution_strip drops a separator whose whole co-author block was agents"
}

test_keeps_separator_with_surviving_coauthors() {
  expect_strip "kept-separator" \
'* fix: a thing

---------

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>
Co-authored-by: Codex <noreply@openai.com>
' \
'* fix: a thing

---------

Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>
'
  pass "fm_attribution_strip keeps a separator that still introduces a human co-author"
}

test_keeps_a_trailing_separator_the_author_wrote() {
  expect_strip "author-separator" \
'* fix: a thing

Body.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

* chore: other

Closing note

---
' \
'* fix: a thing

Body.

* chore: other

Closing note

---
'
  pass "fm_attribution_strip keeps a trailing separator no removal emptied"
}

test_keeps_an_author_rule_the_trailer_sat_under() {
  expect_strip "author-rule-above-trailer" \
'fix: a thing

body

---

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
' \
'fix: a thing

body

---
'
  pass "fm_attribution_strip keeps an author's rule with an agent trailer under it"
}

test_drops_only_edge_blank_lines() {
  expect_strip "edge-blanks" \
'

fix: a thing

Body.


' \
'fix: a thing

Body.
'
  pass "fm_attribution_strip drops leading and trailing blank lines with no removal"
}

test_collapses_only_the_gap_a_removal_created() {
  expect_strip "gap" \
'* fix: a thing

Body.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

* no-mistakes(review): tighten it
' \
'* fix: a thing

Body.

* no-mistakes(review): tighten it
'
  pass "fm_attribution_strip collapses the blank run a removal created into a single gap"
}

# The other half of the guarantee: the strip cleans a trailer that reached a
# branch commit, and this knob stops claude putting one there in the first place.
# Claude Code merges settings and resolves both keys independently, so the
# session link survives an empty co-author text and both must stay false;
# docs/verification/agent-attribution.md records the runtime measurement.
test_claude_settings_disable_agent_attribution() {
  local settings="$ROOT/.claude/settings.json"
  jq -e '.includeCoAuthoredBy == false' "$settings" >/dev/null \
    || fail "settings: .claude/settings.json no longer disables the co-author trailer"
  jq -e '.attribution.sessionUrl == false' "$settings" >/dev/null \
    || fail "settings: .claude/settings.json no longer disables the session link"
  pass ".claude/settings.json disables claude's co-author trailer and session link"
}

test_removes_claude_trailers
test_removes_codex_trailer
test_keeps_human_coauthors
test_clean_message_is_unchanged
test_drops_separator_left_introducing_nothing
test_keeps_separator_with_surviving_coauthors
test_keeps_a_trailing_separator_the_author_wrote
test_keeps_an_author_rule_the_trailer_sat_under
test_drops_only_edge_blank_lines
test_collapses_only_the_gap_a_removal_created
test_claude_settings_disable_agent_attribution
