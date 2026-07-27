#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Unicode whitespace is whitespace (task composer-nbsp) ------------------
#
# claude Code renders its idle, empty composer as `❯` + U+00A0 NO-BREAK SPACE.
# Bash's [:space:] class is ASCII-only, so the row kept residual bytes through
# every trim and read `pending`, and away-mode escalation deferred forever
# against a genuinely idle pane. These pin that the shared owner now treats the
# invisible spaces a TUI plausibly draws as blank - WITHOUT relaxing any of the
# safety verdicts above.

# The exact reported row: `❯` immediately followed by U+00A0.
NBSP=$(printf '\xc2\xa0')

test_nbsp_padded_agent_glyph_is_empty() {
  local out
  out=$(classify 1 "❯$NBSP")
  [ "$out" = empty ] || fail "claude's idle '❯'+U+00A0 composer row should read empty, got '$out'"
  out=$(classify 0 "❯$NBSP")
  [ "$out" = empty ] || fail "a bare '❯'+U+00A0 row should read empty, got '$out'"
  out=$(classify 1 "❯$NBSP$NBSP$NBSP")
  [ "$out" = empty ] || fail "a '❯' row padded with several U+00A0 should read empty, got '$out'"
  out=$(classify 1 "$NBSP")
  [ "$out" = empty ] || fail "a composer row holding only U+00A0 should read empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph padded with U+00A0 reads empty (the reported idle claude row)"
}

# The safety direction: widening what counts as blank must NOT make a dead shell
# look injectable. A shell glyph padded with a Unicode space is still a bare
# shell prompt outside a composer box.
test_nbsp_padded_shell_glyph_stays_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g$NBSP")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' padded with U+00A0 must stay unknown (dead shell), got '$out'"
    out=$(classify 0 "$NBSP$g$NBSP")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' surrounded by U+00A0 must stay unknown, got '$out'"
    out=$(classify 0 '' '' sensitive "$g$NBSP")
    [ "$out" = unknown ] \
      || fail "a ghost-stripped bare shell glyph '$g'+U+00A0 must stay unknown, got '$out'"
    out=$(classify 1 "$g$NBSP")
    [ "$out" = empty ] \
      || fail "shell glyph '$g'+U+00A0 inside a composer box should read empty, got '$out'"
  done
  out=$(classify 0 "user@host \$$NBSP")
  [ "$out" != empty ] || fail "a dead shell prompt padded with U+00A0 must never read empty, got '$out'"
  pass "fm_composer_classify_content: a Unicode-padded bare shell prompt keeps its unknown verdict"
}

test_real_text_with_unicode_space_is_pending() {
  local out
  out=$(classify 1 "fix${NBSP}findings 1 and 3")
  [ "$out" = pending ] || fail "typed text containing U+00A0 should read pending, got '$out'"
  out=$(classify 1 "❯${NBSP}deploy staging now")
  [ "$out" = pending ] || fail "typed text after a glyph and a U+00A0 should read pending, got '$out'"
  out=$(classify 1 "deploy$NBSP")
  [ "$out" = pending ] || fail "typed text trailed by U+00A0 should read pending, got '$out'"
  pass "fm_composer_classify_content: real typed text containing a Unicode space is still pending"
}

# The full handled set, one row per character: every invisible space a TUI
# plausibly emits as padding reads blank, alone and after the prompt glyph.
test_handled_unicode_space_set_reads_blank() {
  local ws out label
  # U+00A0, U+2000-U+200A, U+200B, U+202F, U+205F, U+3000, U+FEFF.
  for ws in '\xc2\xa0' \
            '\xe2\x80\x80' '\xe2\x80\x81' '\xe2\x80\x82' '\xe2\x80\x83' \
            '\xe2\x80\x84' '\xe2\x80\x85' '\xe2\x80\x86' '\xe2\x80\x87' \
            '\xe2\x80\x88' '\xe2\x80\x89' '\xe2\x80\x8a' '\xe2\x80\x8b' \
            '\xe2\x80\xaf' '\xe2\x81\x9f' '\xe3\x80\x80' '\xef\xbb\xbf'; do
    label=$ws
    ws=$(printf '%b' "$ws")
    out=$(classify 1 "❯$ws")
    [ "$out" = empty ] || fail "'❯' padded with $label should read empty, got '$out'"
    out=$(classify 1 "$ws")
    [ "$out" = empty ] || fail "a row holding only $label should read empty, got '$out'"
    out=$(classify 0 ">$ws")
    [ "$out" = unknown ] || fail "a bare shell glyph padded with $label must stay unknown, got '$out'"
  done
  pass "fm_composer_classify_content: every handled Unicode space reads blank without relaxing the shell-glyph verdict"
}

# The joiners are deliberately excluded: they carry meaning inside real typed
# text (emoji and script sequences), so a row is not blank because one is there.
test_zero_width_joiners_are_not_blank() {
  local ws out label
  for ws in '\xe2\x80\x8c' '\xe2\x80\x8d'; do   # U+200C ZWNJ, U+200D ZWJ
    label=$ws
    ws=$(printf '%b' "$ws")
    out=$(classify 1 "❯ $ws")
    [ "$out" = pending ] || fail "$label is not padding and should keep the row pending, got '$out'"
  done
  pass "fm_composer_classify_content: zero-width joiners are content, not blank padding"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_nbsp_padded_agent_glyph_is_empty
test_nbsp_padded_shell_glyph_stays_unknown
test_real_text_with_unicode_space_is_pending
test_handled_unicode_space_set_reads_blank
test_zero_width_joiners_are_not_blank
