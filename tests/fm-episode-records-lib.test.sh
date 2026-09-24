#!/usr/bin/env bash
# tests/fm-episode-records-lib.test.sh - unit tests for the records a task must
# not inherit from a previous occupant of its endpoint or its id
# (bin/fm-episode-records-lib.sh). Pure file operations, no backend required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-episode-records-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-episode-records-lib)

KEY_FAMILIES=(hash count stale stale-since churn-since paused paused-rechecked
  paused-resurfaced waiting-resurfaced writing-since writing-resurfaced wedge-escalations
  dead-reported advancing-resurfaced advancing-absorbs herdr-escalated)
ID_FAMILIES=(subsuper-stale subsuper-paused subsuper-pause-until-due subsuper-advancing
  subsuper-advancing-resurfaced subsuper-advancing-absorbs subsuper-seen-status hb-surfaced)
# Keyed by the raw id rather than its folded spelling, as the secondmate wake-stall
# writers key them; the receipts directory is counted as one more record.
RAW_ID_FAMILIES=(secondmate-wake-progress secondmate-wake-ring secondmate-wake-stall)

# seed_occupant <state> <target> <id> writes every record a supervisor keeps for
# one task on one endpoint, spelled the way the writers spell them.
seed_occupant() {
  local state=$1 key idkey f
  key=$(printf '%s' "$2" | tr ':/.' '___')
  idkey=$(printf '%s' "$3" | tr ':/.' '___')
  for f in "${KEY_FAMILIES[@]}"; do printf '3\n' > "$state/.$f-$key"; done
  for f in "${ID_FAMILIES[@]}"; do printf '3\n' > "$state/.$f-$idkey"; done
  printf 'sig\n' > "$state/.seen-$(printf '%s.status' "$3" | tr '.' '_')"
  printf 'sig\n' > "$state/.seen-$(printf '%s.turn-ended' "$3" | tr '.' '_')"
  for f in "${RAW_ID_FAMILIES[@]}"; do printf '3\n' > "$state/.$f-$3"; done
  mkdir -p "$state/.secondmate-wake-stall-receipts/$3"
  printf '1-1\n' > "$state/.secondmate-wake-stall-receipts/$3/1-1"
}

# count_occupant <state> <target> <id> prints how many of those records exist.
count_occupant() {
  local state=$1 key idkey f n=0
  key=$(printf '%s' "$2" | tr ':/.' '___')
  idkey=$(printf '%s' "$3" | tr ':/.' '___')
  for f in "${KEY_FAMILIES[@]}"; do [ -e "$state/.$f-$key" ] && n=$((n + 1)); done
  for f in "${ID_FAMILIES[@]}"; do [ -e "$state/.$f-$idkey" ] && n=$((n + 1)); done
  [ -e "$state/.seen-$(printf '%s.status' "$3" | tr '.' '_')" ] && n=$((n + 1))
  [ -e "$state/.seen-$(printf '%s.turn-ended' "$3" | tr '.' '_')" ] && n=$((n + 1))
  for f in "${RAW_ID_FAMILIES[@]}"; do [ -e "$state/.$f-$3" ] && n=$((n + 1)); done
  [ -e "$state/.secondmate-wake-stall-receipts/$3" ] && n=$((n + 1))
  printf '%s\n' "$n"
}

test_clears_every_record_a_reused_id_would_inherit() {
  local state="$TMP_ROOT/reuse/state"
  mkdir -p "$state"
  seed_occupant "$state" "firstmate:fm-build.v2" "build.v2"
  [ "$(count_occupant "$state" "firstmate:fm-build.v2" "build.v2")" -gt 0 ] || fail "seeding wrote nothing"
  fm_episode_records_clear "$state" "firstmate:fm-build.v2" "build.v2" || fail "clear returned nonzero"
  expect_code 0 "$(count_occupant "$state" "firstmate:fm-build.v2" "build.v2")" \
    "records a reused id would inherit survived the clear"
  pass "every endpoint-keyed and id-keyed supervision record is cleared for a reused id"
}

# The key folds ':/.' only, so hyphens survive and one key can be a hyphenated
# suffix of another; the clear must not reach a live neighbor that way.
test_leaves_a_live_neighbor_and_home_records_alone() {
  local state="$TMP_ROOT/neighbor/state" total
  mkdir -p "$state"
  seed_occupant "$state" "firstmate:fm-build" "build"
  seed_occupant "$state" "firstmate:sub-fm-build" "sub-build"
  seed_occupant "$state" "firstmate:fm-build-2" "build-2"
  printf 'x\n' > "$state/.wake-queue"
  printf 'x\n' > "$state/.subsuper-escalations"
  printf 'x\n' > "$state/.subsuper-last-scan"
  printf 'x\n' > "$state/build.status"
  fm_episode_records_clear "$state" "firstmate:fm-build" "build" || fail "clear returned nonzero"
  expect_code 0 "$(count_occupant "$state" "firstmate:fm-build" "build")" "the target's own records survived"
  total=$(( ${#KEY_FAMILIES[@]} + ${#ID_FAMILIES[@]} + ${#RAW_ID_FAMILIES[@]} + 3 ))
  expect_code "$total" "$(count_occupant "$state" "firstmate:sub-fm-build" "sub-build")" \
    "a hyphen-prefixed neighbor lost records as collateral"
  expect_code "$total" "$(count_occupant "$state" "firstmate:fm-build-2" "build-2")" \
    "a hyphen-suffixed neighbor lost records as collateral"
  assert_present "$state/.wake-queue" "the home-scoped wake queue was cleared"
  assert_present "$state/.subsuper-escalations" "the home-scoped escalation digest was cleared"
  assert_present "$state/.subsuper-last-scan" "the home-scoped daemon beacon was cleared"
  assert_present "$state/build.status" "the id-keyed namespace belongs to teardown, not this clear"
  pass "the clear removes only its own key and id, never a neighbor or home-scoped record"
}

test_either_argument_may_be_empty() {
  local state="$TMP_ROOT/partial/state"
  mkdir -p "$state"
  seed_occupant "$state" "firstmate:fm-p1" "p1"
  fm_episode_records_clear "$state" "" "p1" || fail "an empty target must still succeed"
  assert_present "$state/.stale-firstmate_fm-p1" "an empty target must leave key-named records"
  assert_absent "$state/.subsuper-stale-p1" "an empty target must still clear id-named records"
  fm_episode_records_clear "$state" "firstmate:fm-p1" "" || fail "an empty id must still succeed"
  assert_absent "$state/.stale-firstmate_fm-p1" "an empty id must still clear key-named records"
  fm_episode_records_clear "$TMP_ROOT/missing" "x" "y" || fail "a missing state dir is not an error"
  pass "an unknown target or id clears what it can, and a missing state dir is success"
}

test_clears_every_record_a_reused_id_would_inherit
test_leaves_a_live_neighbor_and_home_records_alone
test_either_argument_may_be_empty

echo "# fm-episode-records-lib.test.sh: all assertions passed"
