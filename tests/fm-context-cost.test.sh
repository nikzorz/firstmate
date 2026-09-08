#!/usr/bin/env bash
# Behavior tests for the read-only context-cost report.
# Covers surface coverage (AGENTS.md, digest context, fleet state, supervision
# blocks, every generated brief variant, every agent skill with its trigger),
# the absent vs unreadable vs zero distinctions, the honest bytes-not-tokens
# statement, and the read-only guarantee that the report never mutates the home
# it measures - contents included, not just the set of paths.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COST="$ROOT/bin/fm-context-cost.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-cost)

# A populated home: every digest surface present, plus one per-project note and
# one task's runtime records, so the report has something to measure everywhere.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/alpha" "$HOME_DIR/state"
printf 'alpha /repos/alpha\n' > "$HOME_DIR/data/projects.md"
printf '# secondmates\n' > "$HOME_DIR/data/secondmates.md"
printf '# captain\n' > "$HOME_DIR/data/captain.md"
printf '# shared captain\n' > "$HOME_DIR/data/captain-shared.md"
printf '# learnings\n' > "$HOME_DIR/data/learnings.md"
printf '# backlog\n' > "$HOME_DIR/data/backlog.md"
printf '# alpha learnings\n' > "$HOME_DIR/data/learnings-alpha.md"
fm_write_meta "$HOME_DIR/state/task-one.meta" 'window=firstmate:task-one' 'harness=claude'
printf 'working: under way\n' > "$HOME_DIR/state/task-one.status"

BEFORE_MANIFEST="$TMP_ROOT/before.txt"
AFTER_MANIFEST="$TMP_ROOT/after.txt"
# The manifest carries content, not just paths: an in-place truncate, append, or
# overwrite of a measured file is exactly the mutation this guarantee is about,
# and a path-only diff cannot see it.
manifest() {  # <out>
  local f
  find "$HOME_DIR" | LC_ALL=C sort > "$1"
  find "$HOME_DIR" -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(cksum < "$f")" "$f"
  done >> "$1"
}

manifest "$BEFORE_MANIFEST"
OUT=$(FM_HOME="$HOME_DIR" "$COST" 2>&1)
rc=$?
expect_code 0 "$rc" 'report on a populated home exits clean'
manifest "$AFTER_MANIFEST"

# --- read-only guarantee ----------------------------------------------------

diff -q "$BEFORE_MANIFEST" "$AFTER_MANIFEST" >/dev/null ||
  fail 'report mutated the home it measured'
pass 'report leaves the measured home untouched'

# The manifest must actually be able to see an in-place edit, or the guarantee
# above is vacuous.
MUTATED_MANIFEST="$TMP_ROOT/mutated.txt"
printf '# captain, edited\n' > "$HOME_DIR/data/captain.md"
manifest "$MUTATED_MANIFEST"
diff -q "$BEFORE_MANIFEST" "$MUTATED_MANIFEST" >/dev/null &&
  fail 'the read-only manifest cannot detect an in-place file edit'
printf '# captain\n' > "$HOME_DIR/data/captain.md"
pass 'the read-only manifest detects an in-place file edit'

# --- honest bytes-versus-tokens position ------------------------------------

assert_contains "$OUT" 'All sizes below are BYTES' 'report states its unit'
assert_contains "$OUT" 'no bytes-to-token conversion' 'report disclaims token conversion'
pass 'report states bytes are a proxy and applies no token conversion'

# The constraint this test exists to hold: no confident token figure anywhere.
case "$OUT" in
  *[0-9]" tokens"*|*[0-9]" token"*|*"est. tokens"*|*"~"[0-9]*"tok"*)
    fail "report printed a token figure derived from an uncalibrated ratio"$'\n'"$OUT" ;;
esac
pass 'report prints no derived token count'

# --- always-loaded surfaces -------------------------------------------------

assert_contains "$OUT" 'AGENTS.md' 'AGENTS.md is measured'
for f in projects.md secondmates.md captain.md captain-shared.md learnings.md backlog.md; do
  assert_contains "$OUT" "data/$f" "data/$f is measured"
done
assert_contains "$OUT" 'state/*.meta (1 files)' 'meta records are counted'
assert_contains "$OUT" 'state/*.status (1 files)' 'status records are counted'
assert_contains "$OUT" 'data/learnings-alpha.md' 'per-project notes are measured'
pass 'every always-loaded and conditional note surface appears'

# AGENTS.md's real size is reported, not a placeholder.
agents_bytes=$(wc -c < "$ROOT/AGENTS.md" | tr -d ' ')
assert_contains "$OUT" "$agents_bytes  AGENTS.md" 'AGENTS.md reports its real byte size'
pass 'measured sizes are real file sizes'

# --- supervision blocks and brief boilerplate -------------------------------

for harness in claude codex pi; do
  printf '%s' "$OUT" | grep -Eq "^ +[0-9]+  $harness\$" ||
    fail "supervision block for $harness is missing a measured size"
done
pass 'each primary harness supervision block is measured'

for variant in 'ship brief \(no-mistakes\)' 'ship brief \(direct-PR\)' \
               'ship brief \(local-only\)' 'scout brief'; do
  printf '%s' "$OUT" | grep -Eq "^ +[0-9]+  $variant\$" ||
    fail "${variant//\\/} boilerplate is missing a measured size"
done
pass 'every generated brief variant is measured, ship modes named'

# The delivery mode must really reach fm-brief.sh: three identical numbers mean
# the probe registry was ignored and all three rows measured the same brief.
ship_sizes=$(printf '%s\n' "$OUT" |
  sed -n 's/^ *\([0-9][0-9]*\)  ship brief (.*)$/\1/p' | LC_ALL=C sort -u | wc -l)
[ "$ship_sizes" -gt 1 ] ||
  fail 'every ship brief mode reported the same size; the delivery mode was not applied'
pass 'the ship brief rows differ by delivery mode'

# --- skills and their triggers ----------------------------------------------

for skill in "$ROOT"/.agents/skills/*/; do
  name=$(basename "$skill")
  printf '%s' "$OUT" | grep -Eq "^ +[0-9]+  $name\$" ||
    fail "skill $name is missing from the report"
done
pass 'every agent skill is measured'

trigger_lines=$(printf '%s\n' "$OUT" | grep -cE '^ +trigger: ' || true)
skill_count=$(find "$ROOT/.agents/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$trigger_lines" = "$skill_count" ] ||
  fail "expected $skill_count skill triggers, got $trigger_lines"
assert_not_contains "$OUT" 'trigger: >-' 'folded frontmatter descriptions are unfolded'
pass 'every skill carries a readable load trigger'

# ahoy states what it does before it states when to load it, so a trigger taken
# from the head of the description would miss the trigger entirely.
assert_contains "$OUT" 'trigger: when the captain explicitly invokes /ahoy' \
  "a trigger stated late in the description is the one reported"
pass 'the reported trigger is the real trigger, not the description opening'

# A description with no trigger clause at all says so, instead of printing a
# leading excerpt that only looks like a trigger.
FAKE_ROOT="$TMP_ROOT/fakeroot"
mkdir -p "$FAKE_ROOT/.agents/skills/triggerless"
cat > "$FAKE_ROOT/.agents/skills/triggerless/SKILL.md" <<'SKILLEOF'
---
name: triggerless
description: A probe skill whose description states no load trigger at all.
---

# triggerless
SKILLEOF
FAKE_OUT=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" "$COST" 2>&1)
expect_code 0 "$?" 'a skill with no stated trigger does not break the report'
assert_contains "$FAKE_OUT" 'trigger: (not detected)' 'an undetectable trigger is named as such'
pass 'a description with no trigger clause reports (not detected)'

# --- absent surfaces are distinguished from empty ones ----------------------

EMPTY_HOME="$TMP_ROOT/empty"
mkdir -p "$EMPTY_HOME"
EMPTY_OUT=$(FM_HOME="$EMPTY_HOME" "$COST" 2>&1)
expect_code 0 "$?" 'report on a home with no records exits clean'
assert_contains "$EMPTY_OUT" 'ABSENT  data/captain.md' 'a missing note reads ABSENT'
assert_contains "$EMPTY_OUT" 'none present' 'no per-project notes is stated plainly'
pass 'absent records are reported as absent, not as zero bytes'

# An empty-but-present file must read 0, never ABSENT.
mkdir -p "$EMPTY_HOME/data"
: > "$EMPTY_HOME/data/captain.md"
ZERO_OUT=$(FM_HOME="$EMPTY_HOME" "$COST" 2>&1)
assert_contains "$ZERO_OUT" '0  data/captain.md' 'an empty note reports zero bytes'
assert_not_contains "$ZERO_OUT" 'ABSENT  data/captain.md' 'an empty note is not reported absent'
pass 'an empty note is distinguished from a missing one'

# --- a record that cannot be read is reported, not fatal --------------------
#
# A live fleet tears records down while the report runs, so a measured file can
# stop being readable between the test and the read. That must cost one honest
# row, never the whole report.
if [ "$(id -u)" -eq 0 ]; then
  pass 'unreadable-record coverage skipped: running as root reads any mode'
else
  DENIED_HOME="$TMP_ROOT/denied"
  mkdir -p "$DENIED_HOME/data" "$DENIED_HOME/state"
  printf '# captain\n' > "$DENIED_HOME/data/captain.md"
  printf '# learnings\n' > "$DENIED_HOME/data/learnings.md"
  fm_write_meta "$DENIED_HOME/state/task-one.meta" 'window=firstmate:task-one'
  chmod 000 "$DENIED_HOME/data/captain.md" "$DENIED_HOME/state/task-one.meta"
  DENIED_OUT=$(FM_HOME="$DENIED_HOME" "$COST" 2>&1)
  denied_rc=$?
  chmod 644 "$DENIED_HOME/data/captain.md" "$DENIED_HOME/state/task-one.meta"
  expect_code 0 "$denied_rc" 'a home with an unreadable record still exits clean'
  assert_contains "$DENIED_OUT" 'UNREADABLE  data/captain.md' 'an unreadable note is named unreadable'
  assert_not_contains "$DENIED_OUT" 'ABSENT  data/captain.md' 'an unreadable note is not reported absent'
  assert_contains "$DENIED_OUT" 'state/*.meta (1 files, 1 unreadable)' \
    'an unreadable record is counted, not folded into zero bytes'
  printf '%s' "$DENIED_OUT" | grep -Eq '^ +[0-9]+  data/learnings.md$' ||
    fail 'a readable sibling stopped being measured after an unreadable record'
  pass 'an unreadable record is reported honestly and does not abort the report'
fi

# --- no enforcement ---------------------------------------------------------

# The report must never fail on size: a home whose notes dwarf AGENTS.md still
# exits 0, because this script reports and does not gate.
BIG_HOME="$TMP_ROOT/big"
mkdir -p "$BIG_HOME/data"
head -c 400000 /dev/zero | tr '\0' 'x' > "$BIG_HOME/data/learnings.md"
FM_HOME="$BIG_HOME" "$COST" >/dev/null 2>&1
expect_code 0 "$?" 'an oversized home still exits clean'
BIG_OUT=$(FM_HOME="$BIG_HOME" "$COST" 2>&1)
for word in 'WARNING' 'exceeds' 'over budget' 'too large'; do
  assert_not_contains "$BIG_OUT" "$word" "report raises no size warning ($word)"
done
pass 'report never gates or warns on size'

# --- argument handling ------------------------------------------------------

HELP=$("$COST" --help 2>&1)
expect_code 0 "$?" '--help exits clean'
assert_contains "$HELP" 'Usage: fm-context-cost.sh' '--help prints usage'

"$COST" --nonsense >/dev/null 2>&1
expect_code 2 "$?" 'an unknown argument is refused'
pass 'usage and unknown arguments behave'

printf 'all ok - fm-context-cost\n'
