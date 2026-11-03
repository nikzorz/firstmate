#!/usr/bin/env bash
# Behavior tests for bin/fm-claim-lib.sh: many concurrent claimants racing for
# one directory claim end with exactly one winner, both under the host's own
# mkdir and under a stub mkdir that reports success to every caller (the
# non-atomic shape uutils coreutils mkdir has), and release frees the claim.
# shellcheck disable=SC2030,SC2031 # each claimant subshell sets its own PATH on purpose
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claim-lib)
RACERS=12
ROUNDS=25

# A mkdir that succeeds for every caller once the directory exists: the worst
# case of a check-then-create mkdir losing the race.
NONATOMIC_BIN="$TMP_ROOT/nonatomic-bin"
mkdir -p "$NONATOMIC_BIN"
REAL_MKDIR=$(command -v mkdir)
cat > "$NONATOMIC_BIN/mkdir" <<SH
#!/bin/sh
[ "\$1" = -- ] && shift
[ -d "\$1" ] && exit 0
"$REAL_MKDIR" -p -- "\$1"
SH
chmod +x "$NONATOMIC_BIN/mkdir"

# race_round <path-prefix-or-empty> <round-dir> <claimant-command>: start
# RACERS claimants behind one barrier and print how many reported a win.
race_round() {
  local path_prefix=$1 dir=$2 claimant=$3 i pids=()
  mkdir -p "$dir/wins"
  for i in $(seq 1 "$RACERS"); do
    (
      [ -z "$path_prefix" ] || PATH="$path_prefix:$PATH"
      # shellcheck source=bin/fm-claim-lib.sh
      . "$ROOT/bin/fm-claim-lib.sh"
      while [ ! -e "$dir/go" ]; do :; done
      if "$claimant" "$dir/claim"; then : > "$dir/wins/$i"; fi
    ) &
    pids+=("$!")
  done
  : > "$dir/go"
  for i in "${pids[@]}"; do wait "$i"; done
  find "$dir/wins" -type f | wc -l | tr -d ' '
}

plain_mkdir() { mkdir -- "$1" 2>/dev/null; }

# max_winners <path-prefix-or-empty> <label> <claimant>: the most winners any
# round saw.
max_winners() {
  local path_prefix=$1 label=$2 claimant=$3 round wins most=0
  for round in $(seq 1 "$ROUNDS"); do
    wins=$(race_round "$path_prefix" "$TMP_ROOT/$label-$round" "$claimant")
    [ "$wins" -gt "$most" ] && most=$wins
    [ "$wins" -ge 1 ] || { echo 0; return; }
  done
  echo "$most"
}

# The stub must really let several callers win, or the claim cases below
# would pass without proving anything.
most=$(max_winners "$NONATOMIC_BIN" stub-plain plain_mkdir)
[ "$most" -gt 1 ] \
  || fail "the non-atomic mkdir stub did not let several plain mkdir callers win (most=$most)"
pass "the non-atomic mkdir stub lets several plain mkdir callers win one directory"

most=$(max_winners "$NONATOMIC_BIN" stub-claim fm_claim_dir)
[ "$most" = 1 ] \
  || fail "fm_claim_dir under a non-atomic mkdir did not give each claim exactly one winner (most=$most)"
pass "fm_claim_dir gives each claim exactly one winner under a non-atomic mkdir"

most=$(max_winners "" host-claim fm_claim_dir)
[ "$most" = 1 ] \
  || fail "fm_claim_dir under the host mkdir did not give each claim exactly one winner (most=$most)"
pass "fm_claim_dir gives each claim exactly one winner under the host mkdir"

(
  # shellcheck source=bin/fm-claim-lib.sh
  . "$ROOT/bin/fm-claim-lib.sh"
  claim="$TMP_ROOT/release/claim"
  mkdir -p "$TMP_ROOT/release"
  fm_claim_dir "$claim" || fail "a fresh claim was refused"
  [ -d "$claim" ] || fail "a won claim left no directory"
  if fm_claim_dir "$claim"; then fail "a held claim was won again"; fi
  if PATH="$NONATOMIC_BIN:$PATH" fm_claim_dir "$claim"; then
    fail "a held claim was won again through a non-atomic mkdir"
  fi
  : > "$claim/record"
  if fm_claim_dir_release "$claim"; then fail "release removed a claim that still held a record"; fi
  [ -d "$claim" ] || fail "a refused release removed the claim directory"
  rm -f "$claim/record"
  fm_claim_dir_release "$claim" || fail "release of an emptied claim failed"
  [ ! -e "$claim" ] || fail "release left the claim directory behind"
  fm_claim_dir "$claim" || fail "a released claim could not be claimed again"
) || exit 1
pass "a held claim refuses, release frees it only once its records are gone"

mkdir -p "$TMP_ROOT/preexisting/claim"
(
  # shellcheck source=bin/fm-claim-lib.sh
  . "$ROOT/bin/fm-claim-lib.sh"
  if fm_claim_dir "$TMP_ROOT/preexisting/claim"; then
    fail "a directory that already existed was claimed"
  fi
) || exit 1
pass "a directory that already exists is not claimed"

echo "ALL TESTS PASSED"
