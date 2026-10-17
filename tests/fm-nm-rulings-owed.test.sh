#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-rulings-owed.sh over fixture no-mistakes state
# databases shaped like real runs, and for the RULINGS OWED section
# bin/fm-wake-drain.sh prints from it for a task's CI-ready report.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-rulings-owed)
CHECK="$ROOT/bin/fm-nm-rulings-owed.sh"
RUN_1752=01M52KCB3JD1D4AVBY40ZG9EPW
RUN_1749=01M52JSXS8KXT89X4FE5H6REKN

# A case directory holding a no-mistakes task record for task-x1 on branch
# fm/task-x1 of project <case>/project, and a state database of the runs the
# JSON shape describes: {"run": id, "steps": [{"name", "order", "status",
# "approval", "rounds": [{"round", "source", "selected", "verdict",
# "findings": [[id, action], ...]}]}]}. A step's status defaults to completed;
# each review step gets a log with one unparked review segment per round.
# Args: name shape_json
make_nm_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data" "$dir/nm" "$dir/project"
  printf '%s\n' "mode=no-mistakes" "kind=ship" "branch=fm/task-x1" "project=$dir/project" > "$dir/state/task-x1.meta"
  : > "$dir/state/task-x1.status"
  python3 -I - "$dir/nm/state.sqlite" "$dir/project" "$2" <<'PY' || fail "could not write the no-mistakes fixture"
import json
import os
import sqlite3
import sys

db_path, project, shape = sys.argv[1:]
shape = json.loads(shape)
log_dir = os.path.join(os.path.dirname(db_path), "logs")
os.makedirs(log_dir, exist_ok=True)
db = sqlite3.connect(db_path)
db.executescript("""
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
  step_order INTEGER NOT NULL, status TEXT NOT NULL, approval_reason TEXT, skip_reason TEXT, log_path TEXT);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
  findings_json TEXT, selected_finding_ids TEXT, selection_source TEXT);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES (?, 'r1', 'fm/task-x1', 1)", (shape["run"],))
for s, step in enumerate(shape["steps"]):
    log_path = os.path.join(log_dir, "s%d.log" % s)
    with open(log_path, "w") as log:
        log.write("reviewing changes...\n" * len(step["rounds"]))
    db.execute("INSERT INTO step_results VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
               ("s%d" % s, shape["run"], step["name"], step["order"], step.get("status", "completed"),
                step.get("approval"), log_path))
    for rnd in step["rounds"]:
        found = json.dumps({"verdict": rnd.get("verdict"), "findings": [
            {"id": i, "action": a, "severity": "warning", "description": ""} for i, a in rnd.get("findings", [])]})
        db.execute("INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?)",
                   ("s%dr%d" % (s, rnd["round"]), "s%d" % s, rnd["round"], found,
                    json.dumps(rnd.get("selected", [])), rnd.get("source")))
db.commit()
PY
  printf '%s\n' "$dir"
}

# Runs the check for task-x1 of a case, leaving stdout in OUT and the exit code
# in RC.
run_check() {
  local dir=$1
  RC=0
  OUT=$(NM_HOME="$dir/nm" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$CHECK" task-x1) || RC=$?
}

# Appends the clearing lines the last check printed to the case's status log.
append_printed_lines() {
  printf '%s\n' "$OUT" | grep '^needs-decision ' >> "$1/state/task-x1.status" || true
}

owed_count() {
  printf '%s\n' "$OUT" | grep -c "^  - no-mistakes run " || true
}

# Run 01M52KCB3JD1D4AVBY40ZG9EPW's recorded rounds: the review step completed
# on its own over an info finding round 3 never fixed, and the test step's
# auto-fix rounds passed over an ask-user finding they never selected.
shape_1752() {
  jq -nc --arg run "$RUN_1752" '
    {run: $run, steps: [
      {name: "review", order: 3, rounds: [
        {round: 1, source: "user", selected: ["caps-import-cache", "tests-yml-lane", "wrapper-contract-weak"],
         findings: [["caps-import-cache", "ask-user"], ["tests-yml-lane", "auto-fix"], ["wrapper-contract-weak", "auto-fix"]]},
        {round: 2, source: "user_declined",
         findings: [["tests-yml-lane", "auto-fix"], ["class-cache-stale-lane", "auto-fix"]]},
        {round: 3, source: null, findings: [["review-1", "auto-fix"]]}]},
      {name: "test", order: 4, rounds: [
        {round: 1, source: null, verdict: "go"},
        {round: 2, source: "auto_fix", verdict: "no-go", selected: ["guard-command-contract-recursion", "test-3"],
         findings: [["guard-command-contract-recursion", "auto-fix"], ["class-cache-stale-lane-red", "ask-user"],
                    ["test-3", "auto-fix"]]},
        {round: 3, source: "auto_fix", verdict: "no-go", selected: ["test-2"],
         findings: [["class-cache-stale-lane-red", "ask-user"], ["test-2", "auto-fix"]]},
        {round: 4, source: null, verdict: "go"}]},
      {name: "ci", order: 9, rounds: [
        {round: 1, source: "auto_fix", selected: ["ci-1"], findings: [["ci-1", "auto-fix"]]},
        {round: 2, source: "user", selected: ["ci-fix-agent-timeout", "ci-1"],
         findings: [["ci-fix-agent-timeout", "ask-user"], ["ci-1", "ask-user"]]},
        {round: 3, source: null}, {round: 4, source: null}]}]}'
}

# Run 01M52JSXS8KXT89X4FE5H6REKN's review rounds: round 2 fixed only the
# auto-fix finding it selected and carried the two ask-user findings unruled.
shape_1749() {
  jq -nc --arg run "$RUN_1749" '
    {run: $run, steps: [
      {name: "review", order: 3, rounds: [
        {round: 1, source: "user", selected: ["other-shape-source"],
         findings: [["other-shape-source", "ask-user"], ["entry-citation", "ask-user"]]},
        {round: 2, source: "user", selected: ["push-lookup-permission"],
         findings: [["other-shape-source", "ask-user"], ["entry-citation", "ask-user"],
                    ["push-lookup-permission", "auto-fix"]]},
        {round: 3, source: "user_declined", findings: [["entry-citation", "ask-user"]]}]}]}'
}

test_completed_step_and_unselected_ask_user_findings_are_owed() {
  local dir
  dir=$(make_nm_case run-1752 "$(shape_1752)")
  printf 'needs-decision [at=1] [key=nm-%s-review]: ask-user round=2 findings=tests-yml-lane,class-cache-stale-lane file=x\n' \
    "$RUN_1752" >> "$dir/state/task-x1.status"
  run_check "$dir"

  expect_code 1 "$RC" "run-1752: owed rulings must exit 1"
  assert_contains "$OUT" "no-mistakes run $RUN_1752 step test round 2 declined ask-user finding 'class-cache-stale-lane-red'" \
    "run-1752: test round 2's unselected ask-user finding was not owed"
  assert_contains "$OUT" "no-mistakes run $RUN_1752 step test round 3 declined ask-user finding 'class-cache-stale-lane-red'" \
    "run-1752: test round 3's unselected ask-user finding was not owed"
  assert_contains "$OUT" "no-mistakes run $RUN_1752 step review round 3 declined auto-fix finding 'review-1'" \
    "run-1752: the completed review step's last-round finding was not owed"
  assert_equals 3 "$(owed_count)" "run-1752: a selected, named, or fixed finding was owed: $OUT"
  assert_contains "$OUT" "append these lines to $dir/state/task-x1.status" "run-1752: the clearing lines were not introduced"

  append_printed_lines "$dir"
  run_check "$dir"
  expect_code 0 "$RC" "run-1752: the printed lines did not clear every owed ruling: $OUT"
  assert_contains "$OUT" "task task-x1 owes no decision line" "run-1752: a clear task did not say so"
  pass "fm-nm-rulings-owed owes unselected ask-user findings of auto-fix rounds and a completed step's last round"
}

test_same_theme_line_owes_the_gate_ids_it_left_out() {
  local dir
  dir=$(make_nm_case run-1749 "$(shape_1749)")
  {
    printf 'needs-decision [at=1] [key=nm-%s-review]: ask-user round=1 findings=other-shape-source,entry-citation file=x\n' "$RUN_1749"
    printf 'needs-decision [at=2] [key=nm-%s-same-theme]: same theme fixed again findings=push-lookup-permission rounds=1,2 (also carried: other-shape-source, entry-citation; full snapshot file=x)\n' "$RUN_1749"
    printf 'needs-decision [at=3] [key=nm-%s-review]: ask-user round=3 findings=entry-citation file=x\n' "$RUN_1749"
  } >> "$dir/state/task-x1.status"
  run_check "$dir"

  expect_code 1 "$RC" "run-1749: the carried findings must be owed"
  assert_contains "$OUT" "no-mistakes run $RUN_1749 step review round 2 declined ask-user finding 'other-shape-source'" \
    "run-1749: round 2 other-shape-source was not owed"
  assert_contains "$OUT" "no-mistakes run $RUN_1749 step review round 2 declined ask-user finding 'entry-citation'" \
    "run-1749: round 2 entry-citation was not owed"
  assert_equals 2 "$(owed_count)" "run-1749: only round 2's two carried findings are owed: $OUT"
  assert_contains "$OUT" "[key=nm-$RUN_1749-review]: ask-user round=2 findings=other-shape-source,entry-citation file=$dir/data/task-x1/nm-$RUN_1749-findings.txt" \
    "run-1749: the clearing line does not name both carried ids for round 2"
  pass "fm-nm-rulings-owed owes the gate ids a same-theme line left out"
}

test_same_theme_line_names_every_gate_id_for_its_round() {
  local dir
  dir=$(make_nm_case same-theme-round "$(shape_1749)")
  {
    printf 'needs-decision [at=1] [key=nm-%s-review]: ask-user round=1 findings=other-shape-source,entry-citation file=x\n' "$RUN_1749"
    printf 'needs-decision [at=2] [key=nm-%s-same-theme]: same theme fixed again round=2 findings=other-shape-source,entry-citation,push-lookup-permission rounds=1 file=x\n' "$RUN_1749"
    printf 'needs-decision [at=3] [key=nm-%s-review]: ask-user round=3 findings=entry-citation file=x\n' "$RUN_1749"
  } >> "$dir/state/task-x1.status"
  run_check "$dir"
  expect_code 0 "$RC" "same-theme-round: a same-theme line's round= did not name its gate ids: $OUT"
  pass "fm-nm-rulings-owed takes a same-theme line's round= as the round its ids are named for"
}

test_task_binding_no_run_owes_nothing() {
  local dir
  dir=$(make_nm_case direct-pr "$(shape_1749)")
  printf '%s\n' "mode=direct-PR" "branch=fm/task-x1" "project=$dir/project" > "$dir/state/task-x1.meta"
  run_check "$dir"
  expect_code 0 "$RC" "direct-pr: a task outside the pipeline owes nothing"
  pass "fm-nm-rulings-owed owes nothing for a task that is not a pipeline task"
}

test_unreadable_database_is_named_not_judged() {
  local dir
  dir=$(make_nm_case absent-db "$(shape_1749)")
  rm -f "$dir/nm/state.sqlite"
  run_check "$dir"
  expect_code 3 "$RC" "absent-db: an unreadable database must exit 3"
  assert_contains "$OUT" "the no-mistakes state database $dir/nm/state.sqlite (absent) could not be read" \
    "absent-db: what could not be read was not named"
  pass "fm-nm-rulings-owed names an unreadable database instead of reporting nothing owed"
}

test_usage_errors_exit_2() {
  local rc=0
  "$CHECK" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no task id"
  rc=0
  "$CHECK" ../escape >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a path-unsafe task id"
  pass "fm-nm-rulings-owed refuses a missing or unsafe task id"
}

test_wake_drain_surfaces_owed_rulings_on_a_ready_report() {
  local dir out
  dir=$(make_nm_case drain "$(shape_1749)")
  printf 'done [at=4]: PR https://github.com/example/repo/pull/7 checks green\n' >> "$dir/state/task-x1.status"
  out=$(NM_HOME="$dir/nm" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "drain: the drain failed: $out"
  assert_contains "$out" "RULINGS OWED" "drain: a ready report owing rulings printed no RULINGS OWED section: $out"
  assert_contains "$out" "no-mistakes run $RUN_1749 step review round 2 declined ask-user finding 'entry-citation'" \
    "drain: the owed round was not listed"

  printf 'note [at=5]: still waiting\n' >> "$dir/state/task-x1.status"
  out=$(NM_HOME="$dir/nm" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "drain: the second drain failed: $out"
  case "$out" in
    *"RULINGS OWED"*) fail "drain: the section printed although the ready report is no longer the latest event: $out" ;;
  esac
  pass "the wake drain lists owed rulings while a pipeline task's ready report is its latest event"
}

test_wake_drain_names_a_task_whose_owed_rulings_exceed_the_byte_cap() {
  local dir out shape
  shape=$(python3 -I -c 'import json; print(json.dumps({"run": "'"$RUN_1749"'", "steps": [{"name": "review", "order": 1,
    "rounds": [{"round": 1, "source": "auto", "findings": [["finding-%02d" % i, "ask-user"] for i in range(40)]}]}]}))')
  dir=$(make_nm_case drain-cap "$shape")
  printf 'done [at=4]: PR https://github.com/example/repo/pull/7 checks green\n' >> "$dir/state/task-x1.status"
  out=$(NM_HOME="$dir/nm" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
    || fail "drain-cap: the drain failed: $out"
  assert_contains "$out" "RULINGS OWED" "drain-cap: no RULINGS OWED section: $out"
  case "$out" in
    *"finding-00"*) fail "drain-cap: a verdict over the byte cap was printed whole: $out" ;;
  esac
  printf '%s\n' "$out" | grep -q '^RULINGS OWED: .*task-x1' \
    || fail "drain-cap: the task dropped by the byte cap was not named: $out"
  pass "the wake drain names a task whose owed rulings exceed the byte cap"
}

test_completed_step_and_unselected_ask_user_findings_are_owed
test_same_theme_line_owes_the_gate_ids_it_left_out
test_same_theme_line_names_every_gate_id_for_its_round
test_task_binding_no_run_owes_nothing
test_unreadable_database_is_named_not_judged
test_usage_errors_exit_2
test_wake_drain_surfaces_owed_rulings_on_a_ready_report
test_wake_drain_names_a_task_whose_owed_rulings_exceed_the_byte_cap
