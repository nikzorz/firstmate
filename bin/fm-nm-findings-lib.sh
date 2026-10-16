#!/usr/bin/env bash
# The one reader of no-mistakes' per-round finding records.
#
# no-mistakes' axi surface prints no per-round findings and cuts each finding's
# description short, so every firstmate reader of those records goes through
# fm_nm_rounds below, which reads its state database (state.sqlite) read-only.
# bin/fm-nm-findings.sh prints a run's findings whole, and bin/fm-pr-merge.sh
# judges which ask-user findings a branch's runs left unruled.
#
# fm_nm_rounds <state-db> --run <run-id>
# fm_nm_rounds <state-db> --branch <repo-working-path> <branch>
#   Prints one JSON object per step round, in run, step, then round order:
#   {"run", "step_result", "step", "approval", "round", "source", "selected",
#    "findings", "where"}, where "selected" is the round's selected finding id
#   list, "findings" is its finding object list as no-mistakes stored it, and
#   "where" names the round for messages. --branch reads every run of that
#   branch in each repository whose working path resolves to the given path.
#   An absent database, or a round whose record cannot be read, exits nonzero
#   with one stderr line naming what could not be read and prints nothing, so a
#   caller never acts on a partial set. A run, repository, or branch with no
#   round prints nothing and exits 0. The read is bounded at 30 seconds, and a
#   read that outlives it fails like any other unreadable record.

# shellcheck source=bin/fm-nm-run-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-nm-run-lib.sh"

fm_nm_rounds() {  # <state-db> --run <run-id> | --branch <path> <branch>
  fm_nm_bounded "$PWD" 30 python3 -I - "$@" <<'PY'
import json
import os
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

db_path, mode, *keys = sys.argv[1:]
SAFE = re.compile(r"[^\s,]+")
SELECT = ("SELECT ru.id, s.id, s.step_name, s.approval_reason, r.round,"
          " r.selection_source, r.selected_finding_ids, r.findings_json"
          " FROM runs ru JOIN step_results s ON s.run_id = ru.id"
          " JOIN step_rounds r ON r.step_result_id = s.id")
ORDER = " ORDER BY ru.created_at, ru.id, s.step_order, r.round"


def unreadable(what):
    print(what, file=sys.stderr)
    sys.exit(1)


if mode not in ("--run", "--branch") or len(keys) != (1 if mode == "--run" else 2):
    unreadable("usage: fm_nm_rounds <state-db> --run <run-id> | --branch <repo-working-path> <branch>")
if not os.path.isfile(db_path):
    unreadable("the no-mistakes state database %s (absent)" % db_path)
try:
    with closing(sqlite3.connect(Path(db_path).as_uri() + "?mode=ro", uri=True, timeout=10)) as db:
        db.execute("BEGIN")
        if mode == "--run":
            subject = "run %s" % keys[0]
            rows = db.execute(SELECT + " WHERE ru.id = ?" + ORDER, keys).fetchall()
        else:
            want, branch = os.path.realpath(keys[0]), keys[1]
            subject = "branch %s" % branch
            repo_ids = [repo_id for repo_id, path in db.execute("SELECT id, working_path FROM repos")
                        if isinstance(path, str) and os.path.realpath(path) == want]
            rows = []
            for repo_id in repo_ids:
                rows += db.execute(SELECT + " WHERE ru.repo_id = ? AND ru.branch = ?" + ORDER,
                                   (repo_id, branch)).fetchall()
except sqlite3.Error as error:
    unreadable("the no-mistakes state database %s (%s)" % (db_path, error))

out = []
for run, step_id, step, approval, round_no, source, selected, findings in rows:
    if not (isinstance(run, str) and SAFE.fullmatch(run) and isinstance(step, str) and SAFE.fullmatch(step)
            and isinstance(round_no, int)):
        unreadable("a no-mistakes round record of %s" % subject)
    where = "no-mistakes run %s step %s round %s" % (run, step, round_no)
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
    out.append(json.dumps({"run": run, "step_result": step_id, "step": step, "approval": approval,
                           "round": round_no, "source": source, "selected": selected,
                           "findings": listed, "where": where}))
for line in out:
    print(line)
PY
}
