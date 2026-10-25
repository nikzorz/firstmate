#!/usr/bin/env bash
# The one judge of which no-mistakes pipeline rounds a task still owes a
# decision line, shared by bin/fm-nm-rulings-owed.sh, which reports them before
# a merge is attempted, and bin/fm-pr-merge.sh, which refuses a merge over them.
#
# A round answered with an approval or skip leaves every finding unruled,
# whatever its action, since a worker approves or skips a gate only after
# escalating all of it. Such a round is one whose selection was declined, or the
# last round of a step that carries an approval or skip reason. The last round
# of a step that completed with no approval reason is held to the same rule,
# because a finding the pipeline passed over on its own reaches the merge with
# nothing deciding it. Every other round leaves unruled each ask-user finding it
# did not select, whichever source made the selection.
# An unruled finding must appear in a
# `needs-decision [key=nm-<run>-...] ... findings=<id>,...` line of the task's
# status log whose key names the finding's own run, since finding ids repeat
# across runs, and whose `round=<n>` names the finding's round of the step its
# key names, since ids also repeat across the rounds of one step. A
# `[key=nm-<run>-same-theme]` line, whose key names no step, names its ids for
# its `round=<n>` and for each round its `rounds=<a>,<b>,...` list names, in any
# step of its run. A line whose round is missing or is not a number names
# nothing. The one exception is the captain's test-step grant: in a test step
# approved with a non-empty reason, the question no-mistakes itself asks when
# its recorded live validation verdict is inconclusive or no-surface (scenarios
# not driven live). The verdict is the round's structured field; which finding
# is that question is told by the pipeline's own wording, the only mark it
# carries. A review round that parked on incomplete coverage and was approved -
# its selection declined, or it is the last round of a completed step - or that
# still awaits its answer as the last round of a parked step also needs a `needs-decision [key=nm-<run>-...]` line of its run and round naming
# the reserved id `coverage` in findings=, since such a park holds no finding to
# name and the review key alone also marks every ordinary review escalation.
#
# Every round of every no-mistakes run of the task record's branch=, in the
# repository whose working path is its project=, is read live through
# bin/fm-nm-findings-lib.sh (NM_HOME, default ~/.no-mistakes). A database, round
# record, review log, or status log that cannot be read is reported as what
# could not be read rather than judged; a repository no-mistakes holds no record
# for, or a branch with no run, has nothing to rule. A task record that is not
# mode=no-mistakes, or records no branch=, binds no run.
#
# fm_nm_rulings_owed <task-id> <state-dir> <data-dir>
#   Sets FM_NM_RULINGS_OWED to one "  - ..." line per finding or approved or
#   awaiting coverage park no decision line names, a finding carried through several
#   rounds once for every round no line names; FM_NM_RULINGS_CLEARING to the
#   decision line that names every owed id of each run, step, and round, in
#   first-owed order, pointing at <data-dir>/<task-id>/nm-<run>-findings.txt;
#   FM_NM_RULINGS_COVERAGE to one run<TAB>round<TAB>unverified-files line per
#   owed coverage park; and FM_NM_RULINGS_UNREADABLE to true, with FM_NM_RULINGS_OWED holding the
#   one line naming what could not be read, when nothing could be judged.
#   Returns 0 in every case; reads only.
# fm_nm_rulings_clearing_text <status-file>
#   Prints, after a list of owed rulings, the lines that clear them; prints
#   nothing when none are owed.
# fm_nm_relay_mismatches <task-id> <state-dir> [<run>:<step>:<round>]
#   Sets FM_NM_RELAY_MISMATCHES to one "  - ..." line per user-selected round
#   whose stored respond instructions lack the body of the steer that answered
#   its gate, naming the round and both texts, and FM_NM_RELAY_ACCEPTED to true
#   when the optional accepted round was one of them; that round is then left
#   out of the lines. The steer binds to a round through the task's status log:
#   a `needs-decision [key=nm-<run>-<step>] ... round=<n>` line, the first later
#   `resolved [key=<that key>] ...: answered: <excerpt>` close bin/fm-send.sh
#   wrote for it, and the task inbox record (pending or handled) whose body,
#   flattened the way that close flattens it, starts with the excerpt, the
#   latest such record when several do. Every finding the round selected must
#   carry instructions that contain that body, trimmed, verbatim. A round with
#   no bound steer was answered on the worker's own judgment and is not judged;
#   nothing here reports what cannot be read, which fm_nm_rulings_owed already
#   refuses over. Returns 0 in every case; reads only.

# shellcheck source=bin/fm-nm-findings-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-nm-findings-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-dod-lib.sh"

# Prints run<TAB>step<TAB>round<TAB>kind<TAB>id<TAB>action for every finding
# the no-mistakes runs of one branch left unruled and every review coverage
# park they approved or still await an answer on, once per run, step, round,
# and id (kind finding, or kind coverage with id coverage and the park's
# unverified files, comma-joined, in place of the action). Exits nonzero, naming what could
# not be read, rather than printing a partial set.
nm_unruled_findings() {  # <state-db> <project> <branch>
  local rounds
  rounds=$(fm_nm_rounds "$1" --branch "$2" "$3") || return 1
  printf '%s\n' "$rounds" | python3 -I -c '
import json
import re
import sys

SAFE = re.compile(r"[^\s,]+")
# The captain-granted test-step class: the question no-mistakes itself asks
# for each verdict that leaves scenarios not driven live, in its own wording.
GRANTED_QUESTION = {
    "inconclusive": "live validation verdict: inconclusive (",
    "no-surface": "this change has no live-validatable surface; proceed without live validation? (",
}
PARKED = ("awaiting_approval", "fix_review")


def given(reason):
    return isinstance(reason, str) and reason.strip() != ""


def granted(entry, r, finding):
    question = GRANTED_QUESTION.get(r["verdict"])
    description = finding.get("description")
    return (entry["step"] == "test" and given(entry["approval"]) and question is not None
            and isinstance(description, str) and description.startswith(question))


steps = {}
for line in sys.stdin:
    if not line.strip():
        continue
    r = json.loads(line)
    entry = steps.setdefault(r["step_result"], {"run": r["run"], "step": r["step"], "status": r["step_status"],
                                                "approval": r["approval"], "skip": r["skip"], "rounds": []})
    entry["rounds"].append(r)

reported = set()
for entry in steps.values():
    run, step = entry["run"], entry["step"]
    answered_last = given(entry["approval"]) or given(entry["skip"]) or entry["status"] == "completed"
    last = max(r["round"] for r in entry["rounds"])
    for r in entry["rounds"]:
        declined = r["source"] == "user_declined" or (r["round"] == last and answered_last)
        awaiting = r["round"] == last and entry["status"] in PARKED
        if step == "review" and (declined or awaiting):
            if r["coverage_parked"] is None:
                print("the review log of %s" % r["where"], file=sys.stderr)
                sys.exit(1)
            if r["coverage_parked"]:
                print("%s\t%s\t%s\tcoverage\tcoverage\t%s" % (run, step, r["round"],
                                                                 ", ".join(r["coverage_unverified"])))
        for finding in r["findings"]:
            finding_id, action = finding.get("id"), finding.get("action")
            if finding_id in r["selected"] or (not declined and action != "ask-user"):
                continue
            if declined and granted(entry, r, finding):
                continue
            if not (isinstance(finding_id, str) and SAFE.fullmatch(finding_id)):
                print("the id of a finding in %s" % r["where"], file=sys.stderr)
                sys.exit(1)
            if (run, step, r["round"], finding_id) in reported:
                continue
            reported.add((run, step, r["round"], finding_id))
            print("%s\t%s\t%s\tfinding\t%s\t%s" % (run, step, r["round"], finding_id,
                                                     action if isinstance(action, str) and SAFE.fullmatch(action) else "-"))
'
}

FM_NM_RULINGS_OWED=
FM_NM_RULINGS_CLEARING=
# shellcheck disable=SC2034 # Read by the sourcing callers.
FM_NM_RULINGS_COVERAGE=
# shellcheck disable=SC2034 # Read by the sourcing callers.
FM_NM_RULINGS_UNREADABLE=false
# shellcheck disable=SC2034 # FM_NM_RULINGS_COVERAGE and FM_NM_RULINGS_UNREADABLE are read by the sourcing callers.
fm_nm_rulings_owed() {  # <task-id> <state-dir> <data-dir>
  local id=$1 state=$2 data=$3 meta mode branch project status_file db unruled named='' owed=''
  local run step round kind finding_id action reader_err what now ids
  local cannot="so an unruled pipeline finding cannot be ruled out"
  FM_NM_RULINGS_OWED=
  FM_NM_RULINGS_CLEARING=
  FM_NM_RULINGS_COVERAGE=
  FM_NM_RULINGS_UNREADABLE=false
  meta="$state/$id.meta"
  if [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
    FM_NM_RULINGS_UNREADABLE=true
    FM_NM_RULINGS_OWED="  - the task record $meta could not be read, $cannot
"
    return 0
  fi
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  branch=$(grep '^branch=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] && [ -n "$branch" ] || return 0
  project=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
  if [ -z "$project" ]; then
    FM_NM_RULINGS_UNREADABLE=true
    FM_NM_RULINGS_OWED="  - task $id records no project, so its no-mistakes runs cannot be read, $cannot
"
    return 0
  fi
  status_file="$state/$id.status"
  if [ -e "$status_file" ] || [ -L "$status_file" ]; then
    if [ ! -f "$status_file" ] || [ ! -r "$status_file" ]; then
      FM_NM_RULINGS_UNREADABLE=true
      FM_NM_RULINGS_OWED="  - the status log $status_file could not be read, $cannot
"
      return 0
    fi
    # run<TAB>step<TAB>round<TAB>id, with step * for a same-theme line.
    named=$(sed -n 's/^needs-decision[^:]*\[key=nm-\([^]-]*\)-\([^]]*\)\][^:]*:\(.*\)/\1 \2 \3/p' "$status_file" \
      | awk '{
          step = $2; ids = ""; rounds = ""; listed = ""
          for (i = 3; i <= NF; i++) {
            if ($i ~ /^findings=/) ids = substr($i, 10)
            else if ($i ~ /^round=/) rounds = substr($i, 7)
            else if ($i ~ /^rounds=/) listed = substr($i, 8)
          }
          if (rounds !~ /^[0-9]+$/) rounds = ""
          if (step == "same-theme") {
            step = "*"
            if (listed ~ /^[0-9]+(,[0-9]+)*$/) rounds = rounds (rounds == "" ? "" : ",") listed
          }
          if (rounds == "") next
          r = split(rounds, round, ",")
          n = split(ids, id, ",")
          for (j = 1; j <= r; j++)
            for (i = 1; i <= n; i++) print $1 "\t" step "\t" round[j] "\t" id[i]
        }')
  fi
  db="${NM_HOME:-${HOME:-}/.no-mistakes}/state.sqlite"
  reader_err=$(mktemp "${TMPDIR:-/tmp}/fm-nm-rulings.XXXXXX" 2>/dev/null) || reader_err=
  if [ -z "$reader_err" ] || ! unruled=$(nm_unruled_findings "$db" "$project" "$branch" 2>"$reader_err"); then
    what=$(sed -n '$p' "${reader_err:-/dev/null}" 2>/dev/null || true)
    [ -z "$reader_err" ] || rm -f -- "$reader_err"
    FM_NM_RULINGS_UNREADABLE=true
    FM_NM_RULINGS_OWED="  - ${what:-the no-mistakes state database $db} could not be read, $cannot
"
    return 0
  fi
  rm -f -- "$reader_err"
  while IFS=$'\t' read -r run step round kind finding_id action; do
    [ -n "$finding_id" ] || continue
    printf '%s\n' "$named" | grep -qxF -e "$run"$'\t'"$step"$'\t'"$round"$'\t'"$finding_id" -e "$run"$'\t*\t'"$round"$'\t'"$finding_id" && continue
    owed="$owed$run"$'\t'"$step"$'\t'"$round"$'\t'"$finding_id"$'\n'
    if [ "$kind" = coverage ]; then
      FM_NM_RULINGS_COVERAGE="$FM_NM_RULINGS_COVERAGE$run"$'\t'"$round"$'\t'"$action"$'\n'
      FM_NM_RULINGS_OWED="$FM_NM_RULINGS_OWED  - no-mistakes run $run step $step round $round parked on incomplete review coverage and was approved or still awaits its answer, which no needs-decision line of task $id's status log names as coverage for that run and round
"
      continue
    fi
    [ "$action" = - ] && action=unlabelled
    FM_NM_RULINGS_OWED="$FM_NM_RULINGS_OWED  - no-mistakes run $run step $step round $round declined $action finding '$finding_id', which no needs-decision line of task $id's status log names for that run and round
"
  done <<EOF
$unruled
EOF
  [ -n "$owed" ] || return 0
  now=$(date +%s)
  # One line per run, step, and round, naming its ids in first-owed order.
  while IFS=$'\t' read -r run step round ids; do
    FM_NM_RULINGS_CLEARING="$FM_NM_RULINGS_CLEARING$(fm_nm_gate_decision_line "$now" "$run" "$step" "$round" "$ids" "$data/$id/nm-$run-findings.txt")
"
  done < <(printf '%s' "$owed" | awk -F '\t' '
    { gate = $1 "\t" $2 "\t" $3 }
    !(gate in ids) { order[++n] = gate; ids[gate] = $4; next }
    { ids[gate] = ids[gate] "," $4 }
    END { for (i = 1; i <= n; i++) print order[i] "\t" ids[order[i]] }')
}

fm_nm_rulings_clearing_text() {  # <status-file>
  [ -n "$FM_NM_RULINGS_CLEARING" ] || return 0
  printf 'after writing the named snapshot file of each run with the findings of every round its lines name (written once or appended to, never overwritten per round), append these lines to %s to name every unruled finding above:\n' "$1"
  printf '%s' "$FM_NM_RULINGS_CLEARING"
}

# shellcheck disable=SC2034 # Read by the sourcing callers.
FM_NM_RELAY_MISMATCHES=
# shellcheck disable=SC2034 # Read by the sourcing callers.
FM_NM_RELAY_ACCEPTED=false
# shellcheck disable=SC2034 # FM_NM_RELAY_MISMATCHES and FM_NM_RELAY_ACCEPTED are read by the sourcing callers.
fm_nm_relay_mismatches() {  # <task-id> <state-dir> [<run>:<step>:<round>]
  local id=$1 state=$2 accept=${3:-} meta mode branch project db rounds out
  FM_NM_RELAY_MISMATCHES=
  FM_NM_RELAY_ACCEPTED=false
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ -r "$meta" ] && [ -f "$state/$id.status" ] && [ -r "$state/$id.status" ] || return 0
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  branch=$(grep '^branch=' "$meta" | tail -1 | cut -d= -f2- || true)
  project=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] && [ -n "$branch" ] && [ -n "$project" ] || return 0
  db="${NM_HOME:-${HOME:-}/.no-mistakes}/state.sqlite"
  rounds=$(fm_nm_rounds "$db" --branch "$project" "$branch" 2>/dev/null) || return 0
  out=$(printf '%s\n' "$rounds" | python3 -I -c '
import calendar
import glob
import json
import os
import re
import sys
import time

status_path, inbox, accept = sys.argv[1:]
ASK = re.compile(r"^needs-decision\b[^:]*\[key=(nm-([^]\s-]+)-([^]\s]+))\][^:]*:(.*)$")
# The answered close bin/fm-send.sh appends through status_stamp_line. Every
# other keyed line (a re-escalation, a captain-held transfer from
# bin/fm-captain-hold.sh, a close from bin/fm-status.sh) leaves the round
# unpaired, because the steer that answered it is not on this inbox plane.
CLOSE = re.compile(r"^resolved\b[^:]*\[at=(\d+)\][^:]*: answered: (.*)$")
TRUNCATED = " [truncated]"


def line_key(line):
    # The key positions _fm_decision_key in bin/fm-classify-lib.sh reads.
    head, sep, note = line.partition(":")
    found = re.search(r"\[key=([^]]*)\]", head) or (sep and re.match(r"\s*\[key=([^]]*)\]", note))
    return found.group(1) if found else None


def enqueued(text):
    # The at= header bin/fm-task-inbox-lib.sh stamps on each record.
    stamp = re.search(r"^at=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$", text, re.M)
    if not stamp:
        return None
    return calendar.timegm(time.strptime(stamp.group(1), "%Y-%m-%dT%H:%M:%SZ"))


def flat(text):
    # The flattening bin/fm-send.sh applies to the excerpt its close records.
    text = re.sub(r"[\n\r\t]", " ", text)
    return re.sub(r"[\x00-\x1f\x7f]", "", text)


def body(path):
    # The record format bin/fm-task-inbox-lib.sh owns: headers, a -- line, the text.
    try:
        with open(path, encoding="utf-8", errors="replace") as record:
            text = record.read()
    except OSError:
        return None
    head, sep, rest = text.partition("\n--\n")
    return (enqueued(head + "\n"), rest) if sep else None


records = []
for path in glob.glob(os.path.join(inbox, "*.msg")) + glob.glob(os.path.join(inbox, "handled", "*.msg")):
    match = re.fullmatch(r"(\d+)\.msg", os.path.basename(path))
    record = body(path)
    if match and record is not None and record[0] is not None:
        records.append((int(match.group(1)),) + record)
records.sort()

with open(status_path, encoding="utf-8", errors="replace") as status:
    lines = status.read().splitlines()
bound = {}
for i, line in enumerate(lines):
    ask = ASK.match(line)
    if not ask:
        continue
    key, run, step, rest = ask.groups()
    round_no = re.search(r"(?:^|\s)round=(\d+)(?:\s|$)", rest)
    if not round_no:
        continue
    closing = next((later for later in lines[i + 1:] if line_key(later) == key), None)
    close = CLOSE.match(closing) if closing else None
    if not close:
        continue
    excerpt = close.group(2)
    if excerpt.endswith(TRUNCATED):
        excerpt = excerpt[:-len(TRUNCATED)]
    excerpt = excerpt.rstrip()
    before = [text for _, at, text in records if at <= int(close.group(1))]
    if excerpt and before and flat(before[-1]).startswith(excerpt):
        bound[(run, step, int(round_no.group(1)))] = before[-1].strip()

accepted = False
for line in sys.stdin:
    if not line.strip():
        continue
    r = json.loads(line)
    steer = bound.get((r["run"], r["step"], r["round"]))
    if r["source"] != "user" or not steer:
        continue
    given = [r["instructions"].get(f) for f in r["selected"]]
    lacking = [text for text in given if not (isinstance(text, str) and steer in text)]
    if not lacking:
        continue
    if accept == "%s:%s:%s" % (r["run"], r["step"], r["round"]):
        accepted = True
        continue
    print("  - no-mistakes run %s step %s round %s was fixed with instructions that lack the body of the steer that answered its gate; steer: %s; instructions: %s"
          % (r["run"], r["step"], r["round"], json.dumps(steer), json.dumps(lacking[0] or "")))
print("accepted=%s" % ("true" if accepted else "false"))
' "$state/$id.status" "$state/$id.inbox" "$accept" 2>/dev/null) || return 0
  case "$out" in *accepted=true) FM_NM_RELAY_ACCEPTED=true ;; esac
  out=${out%accepted=*}
  FM_NM_RELAY_MISMATCHES=$out
}
