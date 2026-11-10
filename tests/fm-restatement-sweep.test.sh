#!/usr/bin/env bash
# Behavior tests for bin/fm-restatement-sweep.sh: a sentence elsewhere that
# restates a rule the branch changed is listed, while moves, the diff's own
# file, unrelated prose, test paths, and interpreter here-documents are not;
# a line anywhere that keeps a phrase a rewritten sentence dropped is listed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-restatement-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-restatement-sweep)
fm_git_identity fmtest fmtest@example.invalid

OWNER_RULE='The quarantine ledger keeps every rejected parcel for nine days before the courier purges it.'
RESTATED='Remember that the quarantine ledger keeps a rejected parcel nine days until the courier purges it.'
UNRELATED='The lantern rota assigns harbour pilots to evening tides by seniority and recent leave.'

# Rarity is measured across the whole repository, so each fixture carries a
# realistic volume of prose whose words appear nowhere else.
write_filler() {  # <file>
  local i
  for i in $(seq 1 240); do
    printf 'Filler line alpha%s bravo%s charlie%s delta%s echo%s foxtrot%s.\n' "$i" "$i" "$i" "$i" "$i" "$i"
  done >"$1"
}

new_repo() {  # <dir>
  fm_git_init_commit "$1"
  mkdir -p "$1/docs"
  write_filler "$1/docs/filler.md"
  printf '# Owner\n\n%s\n' "$OWNER_RULE" >"$1/docs/owner.md"
  printf '# Guide\n\n%s\n\n%s\n' "$RESTATED" "$UNRELATED" >"$1/docs/guide.md"
  git -C "$1" add -A
  git -C "$1" commit -qm base
  git -C "$1" checkout -q -b work
}

commit_all() {  # <dir> <message>
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

sweep() {  # <dir> [args...]
  local dir=$1
  shift
  (cd "$dir" && "$SWEEP" "$@")
}

test_changed_owner_lists_stale_restatement() {
  local repo="$TMP_ROOT/changed" out
  new_repo "$repo"
  printf '# Owner\n\n%s\n' "${OWNER_RULE/nine/fourteen}" >"$repo/docs/owner.md"
  commit_all "$repo" 'widen the hold'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a clean committed branch"
  printf '%s\n' "$out" | grep -qxF "docs/guide.md:3: $RESTATED" \
    || fail "the stale restatement was not listed: $out"
  printf '%s\n' "$out" | grep -qF "  resembles - docs/owner.md:3: $OWNER_RULE" \
    || fail "the listing did not name the removed owner sentence: $out"
  printf '%s\n' "$out" | grep -qF "lantern rota" && fail "an unrelated sentence was listed: $out"
  printf '%s\n' "$out" | grep -q '^docs/owner.md:' && fail "the diff's own changed file was listed as a candidate: $out"
  pass "a changed rule lists its stale restatement and nothing unrelated"
}

test_move_is_not_a_restatement() {
  local repo="$TMP_ROOT/move" out
  new_repo "$repo"
  printf '# Owner\n' >"$repo/docs/owner.md"
  printf '# Rules\n\n%s\n' "${OWNER_RULE/nine days/nine whole days}" >"$repo/docs/rules.md"
  git -C "$repo" rm -q docs/guide.md
  commit_all "$repo" 'move the rule'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a move"
  printf '%s\n' "$out" | grep -q '^docs/rules.md:' && fail "a moved sentence was listed as its own restatement: $out"
  pass "a moved sentence is not listed as a restatement of itself"
}

test_two_new_copies_are_listed() {
  local repo="$TMP_ROOT/copies" out rule='The beacon relay retransmits a dropped semaphore thrice through the northern mast.'
  new_repo "$repo"
  printf '\n%s\n' "$rule" >>"$repo/docs/owner.md"
  printf '\nNote: the beacon relay retransmits each dropped semaphore thrice through the northern mast.\n' >>"$repo/docs/guide.md"
  commit_all "$repo" 'state the relay rule twice'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on two new copies"
  printf '%s\n' "$out" | grep -q '(also added by this diff).*beacon relay' \
    || fail "a second new copy of a rule in another file was not listed: $out"
  pass "two new copies of one rule in different files are listed"
}

test_removed_dash_comment_keeps_later_hunks() {
  local repo="$TMP_ROOT/dashcomment" out
  new_repo "$repo"
  printf -- '-- The signal lamp flickers amber whenever the tidal gauge drifts.\nlocal a = 1\n-- %s\nlocal b = 2\n' "$OWNER_RULE" >"$repo/docs/rules.lua"
  commit_all "$repo" 'add lua rules'
  git -C "$repo" branch -f main
  printf 'local a = 1\nlocal b = 2\n' >"$repo/docs/rules.lua"
  commit_all "$repo" 'retire lua rules'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a removed dash comment"
  printf '%s\n' "$out" | grep -qxF "docs/guide.md:3: $RESTATED" \
    || fail "a removed '-- ' comment hid the later hunk's restatement: $out"
  pass "a removed '-- ' comment line does not drop later hunks of its file"
}

test_test_paths_and_interpreter_heredocs_are_skipped() {
  local repo="$TMP_ROOT/skips" out
  new_repo "$repo"
  mkdir -p "$repo/tests" "$repo/bin"
  printf '# %s\n' "$RESTATED" >"$repo/tests/ledger.test.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf "python3 - <<'PY'\n%s\nPY\n" "$RESTATED"
    printf "cat <<EOF\n%s\nEOF\n" "${RESTATED/Remember/Recall}"
  } >"$repo/bin/tool.sh"
  commit_all "$repo" 'add restating code'
  git -C "$repo" checkout -q -b change
  printf '# Owner\n\n%s\n' "${OWNER_RULE/nine/fourteen}" >"$repo/docs/owner.md"
  commit_all "$repo" 'widen the hold'
  out=$(sweep "$repo" --base work) || fail "sweep exited $? with code fixtures"
  printf '%s\n' "$out" | grep -q '^tests/' && fail "a test path was listed: $out"
  printf '%s\n' "$out" | grep -q '^bin/tool.sh:3:' && fail "an interpreter here-document line was listed: $out"
  printf '%s\n' "$out" | grep -q '^bin/tool.sh:6: Recall' \
    || fail "a prose here-document fed to cat was not listed: $out"
  pass "test paths and interpreter here-documents are skipped, prose here-documents are swept"
}

test_rewrite_lists_lines_keeping_its_dropped_phrases() {
  local repo="$TMP_ROOT/dropped" out
  new_repo "$repo"
  mkdir -p "$repo/scripts" "$repo/tests/unit"
  printf '# The Boons this seat holds, by Source id, in the order it took them, the older first (ADR-0066): Match-Scoped State beside owned_relics.\nvar held_boons := []\n' >"$repo/scripts/player_progression.gd"
  printf '# The seat'\''s held Boons as the instances a fresh body is granted, the older first, each\n# once.\nfunc granted() -> void:\n\tpass\n' >"$repo/scripts/source_grant_wiring.gd"
  printf 'extends GutTest\n# A Blob draws the Element of each Boon\n# whose spell it holds, in the order it took them, and each Part at its place.\n# Every Boon is keyed by Source id here.\n' >"$repo/tests/unit/test_blob_body_look.gd"
  commit_all "$repo" 'hold boons oldest first'
  git -C "$repo" branch -f main
  printf '# The Boons this seat holds, by Source id, the lead first (ADR-0066): Match-Scoped State beside owned_relics.\nvar held_boons := []\n' >"$repo/scripts/player_progression.gd"
  printf '# Unlike the seat, the bench keeps its Boons the older first.\n' >"$repo/scripts/bench.gd"
  commit_all "$repo" 'hold boons lead first'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a rewrite: $out"
  printf '%s\n' "$out" | grep -qF "stale? scripts/source_grant_wiring.gd:1: # The seat's held Boons" \
    || fail "a line keeping 'the older first' was not listed: $out"
  printf '%s\n' "$out" | grep -qF 'stale? tests/unit/test_blob_body_look.gd:3: # whose spell it holds, in the order it took them' \
    || fail "a test-path line keeping 'in the order it took them' was not listed: $out"
  printf '%s\n' "$out" | grep -qF '  keeps "the older first" from - scripts/player_progression.gd:1: The Boons this seat holds' \
    || fail "the hit did not name its phrase and removed sentence: $out"
  printf '%s\n' "$out" | grep -q '^stale? scripts/bench.gd:' && fail "a line the diff added was listed: $out"
  printf '%s\n' "$out" | grep -q '^stale? tests/unit/test_blob_body_look.gd:4:' \
    && fail "a line sharing only words the rewrite kept was listed: $out"
  printf '%s\n' "$out" | grep -qxF 'removed-phrase grep: 1 rewritten sentences; 2 stale? lines' \
    || fail "the removed-phrase summary was wrong: $out"
  pass "a rewritten sentence lists the lines that keep the phrases it dropped"
}

test_dropped_phrase_is_found_across_a_wrap_and_on_every_line() {
  local repo="$TMP_ROOT/wrapped" out n
  new_repo "$repo"
  mkdir -p "$repo/scripts"
  printf '# Granted Boons come back in the order it took them, the older first today.\n' >"$repo/scripts/p.gd"
  printf '# The granted Boons come back the older\n# first, each once.\n' >"$repo/scripts/wrap.gd"
  for n in 1 2 3 4; do
    printf '# Copy %s keeps its Boons the older first.\n' "$n" >"$repo/scripts/copy$n.gd"
  done
  commit_all "$repo" 'hold boons oldest first'
  git -C "$repo" branch -f main
  printf '# Granted Boons come back in the order it took them, the lead first today.\n' >"$repo/scripts/p.gd"
  commit_all "$repo" 'hold boons lead first'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a rewrite: $out"
  printf '%s\n' "$out" | grep -qF 'stale? scripts/wrap.gd:1: # The granted Boons come back the older' \
    || fail "a phrase wrapped onto the next comment line was not listed at its first line: $out"
  for n in 1 2 3 4; do
    printf '%s\n' "$out" | grep -qF "stale? scripts/copy$n.gd:1:" \
      || fail "copy $n of a phrase kept on four lines was not listed: $out"
  done
  printf '%s\n' "$out" | grep -qxF 'removed-phrase grep: 1 rewritten sentences; 5 stale? lines' \
    || fail "the removed-phrase summary was wrong: $out"
  pass "a dropped phrase is listed across a comment wrap and on however many lines keep it"
}

test_phrase_wrapping_onto_an_added_line_is_skipped() {
  local repo="$TMP_ROOT/wrap-added" out
  new_repo "$repo"
  mkdir -p "$repo/s"
  printf '# Granted Boons come back in the order it took them, the older first today.\n' >"$repo/s/p.gd"
  printf '# Notes on boons follow and keep the\n# end.\n' >"$repo/s/q.gd"
  commit_all "$repo" 'hold boons oldest first'
  git -C "$repo" branch -f main
  printf '# Granted Boons come back in the order it took them, the lead first today.\n' >"$repo/s/p.gd"
  printf '# Notes on boons follow and keep the\n# older first order for ties.\n# end.\n' >"$repo/s/q.gd"
  commit_all "$repo" 'hold boons lead first'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a rewrite: $out"
  printf '%s\n' "$out" | grep -q '^stale? s/q.gd:' \
    && fail "a phrase the diff added was listed because it wraps from the line above: $out"
  printf '%s\n' "$out" | grep -qxF 'removed-phrase grep: 1 rewritten sentences; 0 stale? lines' \
    || fail "the removed-phrase summary was wrong: $out"
  pass "a phrase reaching onto a line the diff added is not listed"
}

test_split_rewrite_keeps_words_moved_to_its_other_sentence() {
  local repo="$TMP_ROOT/split" out
  new_repo "$repo"
  printf '#!/bin/sh\n# Hits on added lines are skipped, and a phrase on more than three lines is stock wording.\n' >"$repo/a.sh"
  printf 'Note that hits on added lines are skipped here.\n' >"$repo/notes.md"
  printf 'Any phrase repeated that often is stock wording.\n' >"$repo/style.md"
  commit_all "$repo" 'one sentence'
  git -C "$repo" branch -f main
  printf '#!/bin/sh\n# Hits on added lines are skipped.\n# A phrase on more than three added lines is house wording.\n' >"$repo/a.sh"
  commit_all "$repo" 'split sentence'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a split rewrite: $out"
  printf '%s\n' "$out" | grep -q '^stale? notes.md:' \
    && fail "a line keeping a claim the split rewrite still states was listed: $out"
  printf '%s\n' "$out" | grep -qF 'stale? style.md:1: Any phrase repeated that often is stock wording.' \
    || fail "a line keeping a word the split rewrite dropped from its hunk was not listed: $out"
  printf '%s\n' "$out" | grep -qxF 'removed-phrase grep: 1 rewritten sentences; 1 stale? lines' \
    || fail "the removed-phrase summary was wrong: $out"
  pass "a split rewrite lists only words that left its hunk, not words moved to its other sentence"
}

test_split_rewrite_across_a_blank_line_keeps_moved_words() {
  local repo="$TMP_ROOT/split-blank" out
  new_repo "$repo"
  printf '#!/bin/sh\n# Hits on added lines are skipped, and a phrase on more than three lines is stock wording.\n\n' >"$repo/a.sh"
  printf 'Note that hits on added lines are skipped here.\n' >"$repo/notes.md"
  printf 'Any phrase repeated that often is stock wording.\n' >"$repo/style.md"
  commit_all "$repo" 'one sentence'
  git -C "$repo" branch -f main
  printf '#!/bin/sh\n# Hits on added lines are skipped.\n\n# A phrase on more than three added lines is house wording.\n' >"$repo/a.sh"
  commit_all "$repo" 'split sentence across a blank line'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a split rewrite: $out"
  printf '%s\n' "$out" | grep -q '^stale? notes.md:' \
    && fail "a line keeping a claim the split rewrite still states past a blank line was listed: $out"
  printf '%s\n' "$out" | grep -qF 'stale? style.md:1: Any phrase repeated that often is stock wording.' \
    || fail "a line keeping a word the split rewrite dropped from its hunk group was not listed: $out"
  printf '%s\n' "$out" | grep -qxF 'removed-phrase grep: 1 rewritten sentences; 1 stale? lines' \
    || fail "the removed-phrase summary was wrong: $out"
  pass "a split rewrite whose halves a blank line separates keeps the words moved to its other half"
}

test_dirty_worktree_is_refused() {
  local repo="$TMP_ROOT/dirty" out rc
  new_repo "$repo"
  printf 'uncommitted\n' >>"$repo/docs/owner.md"
  out=$(sweep "$repo" --base main 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a modified worktree exited $rc, not 2: $out"
  git -C "$repo" checkout -q -- docs/owner.md
  printf 'scratch\n' >"$repo/notes.md"
  out=$(sweep "$repo" --base main 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an untracked file exited $rc, not 2: $out"
  printf '%s\n' "$out" | grep -qF 'notes.md' || fail "the refusal did not name the untracked file: $out"
  pass "uncommitted and untracked changes are refused"
}

test_owner_path_and_cwd_do_not_hide_a_change() {
  local repo name out
  for name in 'my owner.md' 'café.md' $'tab\towner.md' 'ow"n\\er.md'; do
    repo="$TMP_ROOT/paths-$RANDOM"
    new_repo "$repo"
    git -C "$repo" mv docs/owner.md "docs/$name"
    git -C "$repo" commit -qm 'rename the owner'
    git -C "$repo" branch -qf main
    git -C "$repo" config diff.noprefix true
    git -C "$repo" config diff.relative true
    printf '# Owner\n\n%s\n' "${OWNER_RULE/nine/fourteen}" >"$repo/docs/$name"
    commit_all "$repo" 'widen the hold'
    out=$(sweep "$repo/docs" --base main) || fail "sweep from a subdirectory exited $? for docs/$name: $out"
    printf '%s\n' "$out" | grep -qxF "docs/guide.md:3: $RESTATED" \
      || fail "the stale restatement was not listed for docs/$name: $out"
  done
  pass "an owner path with spaces, tabs, quotes, or non-ASCII, a subdirectory cwd, and prefix config still list the restatement"
}

test_default_base_resolution() {
  local repo="$TMP_ROOT/default" out
  new_repo "$repo"
  printf '# Owner\n\n%s\n' "${OWNER_RULE/nine/fourteen}" >"$repo/docs/owner.md"
  commit_all "$repo" 'widen the hold'
  out=$(sweep "$repo") || fail "sweep exited $? with no origin and a local main"
  printf '%s\n' "$out" | head -1 | grep -qF 'since main (' || fail "no-origin default base was not main: $out"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" fetch -q origin
  git -C "$repo" remote set-head origin main >/dev/null
  out=$(sweep "$repo") || fail "sweep exited $? with an origin"
  printf '%s\n' "$out" | head -1 | grep -qF 'since refs/remotes/origin/main (' \
    || fail "the default base was not origin's default branch: $out"
  printf '%s\n' "$out" | grep -qxF "docs/guide.md:3: $RESTATED" \
    || fail "the stale restatement was not listed against origin's default branch: $out"
  pass "the default base is origin's default branch, else the local main"
}

test_help_and_usage() {
  local out rc
  out=$("$SWEEP" --help) || fail "--help exited $?"
  printf '%s\n' "$out" | grep -q '^Usage: fm-restatement-sweep.sh' || fail "--help printed no usage: $out"
  out=$("$SWEEP" --bogus 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag exited $rc, not 2"
  pass "--help prints usage and an unknown flag is a usage error"
}
test_unrelated_added_sentence_does_not_keep_a_dropped_word() {
  local repo="$TMP_ROOT/unrelated-sibling" out
  new_repo "$repo"
  printf '#!/bin/sh\n# Hits on added lines are skipped, and a phrase on more than three lines is stock wording.\n# Keep one.\n# Keep two.\n# Keep three.\n' >"$repo/a.sh"
  printf 'Any phrase repeated that often is stock wording.\n' >"$repo/style.md"
  commit_all "$repo" 'one sentence'
  git -C "$repo" branch -f main
  printf '#!/bin/sh\n# Hits on added lines are skipped, and a phrase on more than three lines is house wording.\n# Keep one.\n# Keep two.\n# Keep three.\n# The stock ledger is reconciled weekly.\n' >"$repo/a.sh"
  commit_all "$repo" 'rewrite plus an unrelated sentence'
  out=$(sweep "$repo" --base main) || fail "sweep exited $? on a rewrite: $out"
  printf '%s\n' "$out" | grep -qF 'stale? style.md:1: Any phrase repeated that often is stock wording.' \
    || fail "a dropped word was masked by an unrelated added sentence in another hunk: $out"
  pass "an added sentence in another hunk of the rewrite's file does not keep a dropped word"
}


test_changed_owner_lists_stale_restatement
test_move_is_not_a_restatement
test_two_new_copies_are_listed
test_removed_dash_comment_keeps_later_hunks
test_test_paths_and_interpreter_heredocs_are_skipped
test_rewrite_lists_lines_keeping_its_dropped_phrases
test_dropped_phrase_is_found_across_a_wrap_and_on_every_line
test_phrase_wrapping_onto_an_added_line_is_skipped
test_split_rewrite_keeps_words_moved_to_its_other_sentence
test_split_rewrite_across_a_blank_line_keeps_moved_words
test_unrelated_added_sentence_does_not_keep_a_dropped_word
test_dirty_worktree_is_refused
test_owner_path_and_cwd_do_not_hide_a_change
test_default_base_resolution
test_help_and_usage

echo "all fm-restatement-sweep tests passed"
