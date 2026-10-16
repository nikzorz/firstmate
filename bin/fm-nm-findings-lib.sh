#!/usr/bin/env bash
# The one reader of no-mistakes' per-round finding records.
#
# no-mistakes' axi surface prints no per-round findings and cuts each finding's
# description short, so every firstmate reader of those records goes through
# fm_nm_rounds below, which reads its state database (state.sqlite) and review
# step logs read-only.
# bin/fm-nm-findings.sh prints a run's findings whole, and bin/fm-pr-merge.sh
# judges which findings and coverage parks a branch's runs left unruled.
#
# fm_nm_rounds <state-db> --run <run-id>
# fm_nm_rounds <state-db> --branch <repo-working-path> <branch>
#   Prints one JSON object per step round, in run, step, then round order:
#   {"run", "step_result", "step", "step_status", "approval", "skip", "round",
#    "source", "selected", "findings", "verdict", "coverage_parked", "where"},
#   where "selected" is the round's selected finding id list, "findings" is its
#   finding object list as no-mistakes stored it, "verdict" is the live
#   validation verdict a test round recorded (null when none), and "where"
#   names the round for messages. --branch reads every run of that branch in
#   each repository whose working path resolves to the given path.
#   "coverage_parked" says whether a review round parked for approval because
#   its review left changed files unverified. no-mistakes records that park in
#   no field, only as a line of the step's log, so it is read from the log
#   segment the round's own "reviewing changes..." line opens; it is false off
#   the review step and null when the log cannot be read or its segments do not
#   match the recorded rounds, leaving the caller to judge whether it matters.
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
SELECT = ("SELECT ru.id, s.id, s.step_name, s.status, s.approval_reason, s.skip_reason,"
          " s.log_path, r.round, r.selection_source, r.selected_finding_ids, r.findings_json"
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

# The pipeline's own wording for a review coverage park, with and without a
# reviewed_paths report.
COVERAGE_PARKS = ("review coverage is incomplete; parking for approval",
                  "review reported no reviewed_paths; parking for approval")
REVIEW_ROUND = "reviewing changes..."


def coverage_parks(log_path, rounds):
    # Round numbers whose log segment parked on coverage, or None when the log
    # cannot be read or holds a different number of rounds than were recorded.
    try:
        with open(log_path, encoding="utf-8", errors="replace") as log:
            lines = log.read().splitlines()
    except (OSError, TypeError):
        return None
    segment, parked = 0, set()
    for line in lines:
        if line.startswith(REVIEW_ROUND):
            segment += 1
        elif segment and line.startswith(COVERAGE_PARKS):
            parked.add(segment)
    return {rounds[k - 1] for k in parked} if segment == len(rounds) else None


parks = {}
for row in rows:
    if row[2] == "review" and row[1] not in parks:
        parks[row[1]] = coverage_parks(row[6], sorted({r[7] for r in rows if r[1] == row[1]}))

out = []
for run, step_id, step, status, approval, skip, log_path, round_no, source, selected, findings in rows:
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
    verdict = record.get("verdict")
    parked = parks.get(step_id, set())
    out.append(json.dumps({"run": run, "step_result": step_id, "step": step, "step_status": status,
                           "approval": approval, "skip": skip, "round": round_no, "source": source,
                           "selected": selected, "findings": listed,
                           "verdict": verdict if isinstance(verdict, str) else None,
                           "coverage_parked": None if parked is None else round_no in parked,
                           "where": where}))
for line in out:
    print(line)
PY
}
