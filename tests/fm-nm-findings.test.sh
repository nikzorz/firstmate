#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-findings.sh over a fixture no-mistakes state
# database: a description far longer than a gate prints comes back whole, the
# step and finding-id filters select what they name, and a finding id, run, or
# database that cannot be found exits nonzero naming it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-findings)
NM_HOME="$TMP_ROOT/nm"
export NM_HOME
RUN=01RUNFIXTURE
LONG_FILE="$TMP_ROOT/long-description"

# A 1,427-character description whose proposed fix sits only at its end.
python3 -I -c '
import sys
head = "The guard compares the left bound against the right bound but never the right against the left. "
tail = " Proposed fix: compare both directions of the same bound in one check."
body = (head * 20)[: 1427 - len(tail)]
sys.stdout.write(body + tail)
' > "$LONG_FILE"
LONG=$(cat "$LONG_FILE")
assert_equals 1427 "${#LONG}" "the fixture description must be 1,427 characters"

mkdir -p "$NM_HOME"
python3 -I - "$NM_HOME/state.sqlite" "$RUN" "$LONG" <<'PY' || fail "could not write the no-mistakes fixture"
import json
import sqlite3
import sys

db_path, run, long_description = sys.argv[1:]
db = sqlite3.connect(db_path)
db.executescript("""
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
  step_order INTEGER NOT NULL, approval_reason TEXT);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
  findings_json TEXT, selected_finding_ids TEXT, selection_source TEXT);
""")
db.execute("INSERT INTO runs VALUES (?, 'r1', 'fm/x', 1)", (run,))
db.execute("INSERT INTO runs VALUES ('01OTHERRUN', 'r1', 'fm/x', 2)")


def finding(fid, action, description, line=12):
    return {"id": fid, "severity": "warning", "file": "bin/guard.sh", "line": line,
            "action": action, "description": description}


rounds = [
    ("s1", run, "review", 3, 1, [finding("mirror-bound", "ask-user", long_description), finding("note-1", "no-op", "fine")]),
    ("s1", run, "review", 3, 2, [finding("mirror-bound", "ask-user", "round two text", 40)]),
    ("s2", run, "document", 5, 1, []),
    ("s3", "01OTHERRUN", "review", 3, 1, [finding("other-run-only", "ask-user", "other run")]),
]
for i, (sid, rid, step, order, rnd, found) in enumerate(rounds):
    db.execute("INSERT OR IGNORE INTO step_results VALUES (?, ?, ?, ?, NULL)", (sid, rid, step, order))
    db.execute("INSERT INTO step_rounds VALUES (?, ?, ?, ?, '[]', 'user')",
               ("r%d" % i, sid, rnd, json.dumps({"findings": found})))
db.commit()
PY

test_prints_a_long_description_whole() {
  local out code=0
  out=$("$ROOT/bin/fm-nm-findings.sh" "$RUN" --step review mirror-bound) || code=$?
  expect_code 0 "$code" "a found finding"
  assert_contains "$out" "description: $LONG" "the 1,427-character description must print verbatim"
  assert_contains "$out" "Proposed fix: compare both directions of the same bound in one check." \
    "the proposed fix at the description's end must print"
  assert_contains "$out" "== run $RUN step review round 1" "round 1 must be labelled"
  assert_contains "$out" "== run $RUN step review round 2" "a later round raising the same id must print too"
  assert_contains "$out" $'id: mirror-bound\nseverity: warning\nfile: bin/guard.sh\nline: 12\naction: ask-user' \
    "id, severity, file, line and action must print"
  assert_not_contains "$out" "note-1" "a finding id filter must leave other findings out"
  pass "fm-nm-findings prints a 1,427-character description whole with every field"
}

test_whole_run_prints_every_step_and_round_of_that_run_only() {
  local out code=0
  out=$("$ROOT/bin/fm-nm-findings.sh" "$RUN") || code=$?
  expect_code 0 "$code" "a whole run"
  assert_contains "$out" "id: note-1" "every finding of the run must print"
  assert_contains "$out" $'== run '"$RUN"$' step document round 1\n(no findings)' "an empty round must say so"
  assert_not_contains "$out" "other-run-only" "another run's findings must stay out"
  pass "fm-nm-findings prints every round of the named run only"
}

test_unknown_finding_id_fails_naming_it() {
  local out err code=0
  out=$("$ROOT/bin/fm-nm-findings.sh" "$RUN" mirror-bound no-such-finding 2>"$TMP_ROOT/err") || code=$?
  err=$(cat "$TMP_ROOT/err")
  expect_code 1 "$code" "an unknown finding id"
  assert_contains "$err" "finding no-such-finding is in no round of no-mistakes run $RUN" "the missing id must be named"
  assert_contains "$out" "id: mirror-bound" "the ids that were found still print"
  code=0
  "$ROOT/bin/fm-nm-findings.sh" "$RUN" --step document mirror-bound >/dev/null 2>"$TMP_ROOT/err" || code=$?
  expect_code 1 "$code" "an id outside the named step"
  assert_grep "finding mirror-bound is in no round of no-mistakes run $RUN step document" "$TMP_ROOT/err" \
    "an id outside the named step must be named"
  pass "fm-nm-findings exits nonzero naming a finding id it cannot find"
}

test_unknown_run_step_or_database_fails() {
  local code=0
  "$ROOT/bin/fm-nm-findings.sh" 01NOSUCHRUN >/dev/null 2>"$TMP_ROOT/err" || code=$?
  expect_code 1 "$code" "an unknown run"
  assert_grep "no-mistakes run 01NOSUCHRUN has no recorded round" "$TMP_ROOT/err" "the unknown run must be named"
  code=0
  "$ROOT/bin/fm-nm-findings.sh" "$RUN" --step ci >/dev/null 2>"$TMP_ROOT/err" || code=$?
  expect_code 1 "$code" "an unknown step"
  assert_grep "no-mistakes run $RUN step ci has no recorded round" "$TMP_ROOT/err" "the unknown step must be named"
  code=0
  NM_HOME="$TMP_ROOT/absent" "$ROOT/bin/fm-nm-findings.sh" "$RUN" >/dev/null 2>"$TMP_ROOT/err" || code=$?
  expect_code 1 "$code" "an absent database"
  assert_grep "the no-mistakes state database $TMP_ROOT/absent/state.sqlite (absent)" "$TMP_ROOT/err" \
    "the absent database must be named"
  code=0
  "$ROOT/bin/fm-nm-findings.sh" >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "no run id"
  pass "fm-nm-findings exits nonzero naming an unknown run, step, or database"
}

test_prints_a_long_description_whole
test_whole_run_prints_every_step_and_round_of_that_run_only
test_unknown_finding_id_fails_naming_it
test_unknown_run_step_or_database_fails
