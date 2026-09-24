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
LIB="$ROOT/bin/fm-episode-records-lib.sh"

KEY_FAMILIES=(hash count stale stale-since paused paused-rechecked paused-resurfaced
  wedge-escalations advancing-resurfaced advancing-absorbs herdr-escalated)
ID_FAMILIES=(subsuper-stale subsuper-paused subsuper-advancing
  subsuper-advancing-resurfaced subsuper-advancing-absorbs subsuper-seen-status hb-surfaced)

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
  total=$(( ${#KEY_FAMILIES[@]} + ${#ID_FAMILIES[@]} + 2 ))
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

# Drift guard: a record family some supervisor writes on a watcher key or a task
# key, but that the clear does not name, is one a later task inherits. Every
# writer spells those records as <state>/.<family>-$<key var>.
test_every_keyed_family_written_in_bin_is_cleared() {
  local family missing=''
  # The patterns below match a literal "$" in bin/ source.
  # shellcheck disable=SC2016
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    grep -qF "/.$family-\$" "$LIB" || missing="$missing $family"
  done <<EOF
$(grep -ohE '/\.[a-z][a-z-]*-\$(\{?key\}?|\{?idkey\}?|2|watcher_key|\(_stale_key)' \
    "$ROOT"/bin/fm-watch.sh "$ROOT"/bin/fm-supervise-daemon.sh "$ROOT"/bin/fm-push-transition-lib.sh \
  | sed -E 's|^/\.||; s|-\$.*$||' | sort -u)
EOF
  # shellcheck disable=SC2016
  grep -qF '"$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"' "$ROOT/bin/backends/herdr.sh" \
    || fail "herdr's escalation marker is no longer spelled from the watcher key; recheck the clear"
  [ -z "$missing" ] || fail "keyed record families written in bin/ but not cleared:$missing"
  pass "every keyed record family a supervisor writes is named by the clear"
}

test_clears_every_record_a_reused_id_would_inherit
test_leaves_a_live_neighbor_and_home_records_alone
test_either_argument_may_be_empty
test_every_keyed_family_written_in_bin_is_cleared

echo "# fm-episode-records-lib.test.sh: all assertions passed"
