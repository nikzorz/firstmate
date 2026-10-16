import json
import os
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

db_path, project, branch = sys.argv[1:]
SAFE = re.compile(r"[^\s,]+")


def unreadable(what):
    print(what, file=sys.stderr)
    sys.exit(1)


def given(reason):
    return isinstance(reason, str) and reason.strip() != ""


if not os.path.isfile(db_path):
    unreadable("the no-mistakes state database %s (absent)" % db_path)
try:
    with closing(sqlite3.connect(Path(db_path).as_uri() + "?mode=ro", uri=True, timeout=10)) as db:
        db.execute("BEGIN")
        want = os.path.realpath(project)
        repo_ids = [repo_id for repo_id, path in db.execute("SELECT id, working_path FROM repos")
                    if isinstance(path, str) and os.path.realpath(path) == want]
        rows = []
        for repo_id in repo_ids:
            rows += db.execute(
                "SELECT ru.id, s.id, s.step_name, s.approval_reason, r.round,"
                " r.selection_source, r.selected_finding_ids, r.findings_json"
                " FROM runs ru JOIN step_results s ON s.run_id = ru.id"
                " JOIN step_rounds r ON r.step_result_id = s.id"
                " WHERE ru.repo_id = ? AND ru.branch = ?"
                " ORDER BY ru.created_at, ru.id, s.step_order, r.round",
                (repo_id, branch)).fetchall()
except sqlite3.Error as error:
    unreadable("the no-mistakes state database %s (%s)" % (db_path, error))

steps = {}
for run, step_id, step, approval, round_no, source, selected, findings in rows:
    where = "no-mistakes run %s step %s round %s" % (run, step, round_no)
    if not (isinstance(run, str) and SAFE.fullmatch(run) and isinstance(step, str) and SAFE.fullmatch(step)
            and isinstance(round_no, int)):
        unreadable("a no-mistakes round record of branch %s" % branch)
    try:
        selected = json.loads(selected) if selected else []
        record = json.loads(findings) if findings else {}
        if not isinstance(selected, list) or not isinstance(record, dict):
            raise ValueError
        listed = record.get("findings") or []
        if not isinstance(listed, list) or not all(isinstance(f, dict) for f in listed):
            raise ValueError
    except ValueError:
        unreadable("the findings of %s" % where)
    entry = steps.setdefault(step_id, {"run": run, "step": step, "approval": approval, "rounds": []})
    entry["rounds"].append((round_no, source, selected, listed, where))

reported = set()
for entry in steps.values():
    run, step, approved = entry["run"], entry["step"], given(entry["approval"])
    if step == "test" and approved:
        continue
    last = max(r[0] for r in entry["rounds"])
    for round_no, source, selected, listed, where in entry["rounds"]:
        if not (source in ("user", "user_declined") or (round_no == last and approved)):
            continue
        for finding in listed:
            finding_id = finding.get("id")
            if finding.get("action") != "ask-user" or finding_id in selected:
                continue
            if not (isinstance(finding_id, str) and SAFE.fullmatch(finding_id)):
                unreadable("the id of a finding in %s" % where)
            if (run, step, finding_id) in reported:
                continue
            reported.add((run, step, finding_id))
            print("%s\t%s\t%s\t%s" % (run, step, round_no, finding_id))
