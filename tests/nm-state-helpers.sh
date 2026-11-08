#!/usr/bin/env bash
# tests/nm-state-helpers.sh - a fixture no-mistakes state database for suites
# that judge a task's pipeline rounds through bin/fm-nm-rulings-lib.sh.

# Writes <db-path>, and a logs/ directory beside it, holding one run of branch
# <branch> in the repository whose working path is <project>, shaped by the
# JSON <shape>: {"run": id, "steps": [{"name", "order", "status", "approval",
# "rounds": [{"round", "source", "selected", "verdict", "findings": [[id,
# action] or [id, action, description], ...]}]}]}. A step's status defaults to
# completed; each step gets a log with one unparked review segment per round.
nm_state_fixture() {  # <db-path> <project> <branch> <shape>
  python3 -I - "$@" <<'PY'
import json
import os
import sqlite3
import sys

db_path, project, branch, shape = sys.argv[1:]
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
db.execute("INSERT INTO runs VALUES (?, 'r1', ?, 1)", (shape["run"], branch))
for s, step in enumerate(shape["steps"]):
    log_path = os.path.join(log_dir, "s%d.log" % s)
    with open(log_path, "w") as log:
        log.write("reviewing changes...\n" * len(step["rounds"]))
    db.execute("INSERT INTO step_results VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
               ("s%d" % s, shape["run"], step["name"], step["order"], step.get("status", "completed"),
                step.get("approval"), log_path))
    for rnd in step["rounds"]:
        found = json.dumps({"verdict": rnd.get("verdict"), "findings": [
            {"id": f[0], "action": f[1], "severity": "warning", "description": f[2] if len(f) > 2 else ""}
            for f in rnd.get("findings", [])]})
        db.execute("INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?, ?)",
                   ("s%dr%d" % (s, rnd["round"]), "s%d" % s, rnd["round"], found,
                    json.dumps(rnd.get("selected", [])), rnd.get("source")))
db.commit()
PY
}
