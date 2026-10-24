#!/usr/bin/env bash
# fm-nm-findings.sh - print a no-mistakes run's findings whole.
#
# Usage: fm-nm-findings.sh <run-id> [--step <step>]
#
# A no-mistakes gate cuts each finding's description short, and no axi command
# prints it whole, so a gate answered from the gate's own output answers a
# finding nobody read in full. This prints every round of the run, or of one
# step, with each finding's id, severity, file, line, action and description
# verbatim, read-only from no-mistakes' state database (NM_HOME, default
# ~/.no-mistakes) through bin/fm-nm-findings-lib.sh.
#
# Rounds print in step order, then round order, under a
# `== run <run> step <step> round <n>` line, so a step's last block is the gate
# it is parked at and the blocks before it are what earlier rounds raised.
# A finding identical in every stored field to one an earlier round of its step
# selected carries a `carried: round <n>` line naming that round, because
# no-mistakes can store a finding again on a round whose review never raised it.
# A review round parked on incomplete review coverage also carries an entry with
# the reserved id `coverage` listing its unverified files, because that park
# holds no finding of its own yet still needs a ruling before approval.
#
# Exit status: 0 when everything asked for printed; 1 when the database cannot
# be read or the run (or step) has no recorded round; 2 on a usage error.
set -eu

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-findings-lib.sh
. "$SCRIPT_DIR/fm-nm-findings-lib.sh"

case "${1:-}" in ''|-*) usage >&2; exit 2 ;; esac
run=$1
shift
step=
while [ $# -gt 0 ]; do
  case "$1" in
    --step)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --step needs a step name" >&2; exit 2; }
      step=$2
      shift 2
      ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) echo "error: unexpected argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

db="${NM_HOME:-${HOME:-}/.no-mistakes}/state.sqlite"
rounds=$(fm_nm_rounds "$db" --run "$run") || {
  echo "error: could not read no-mistakes run $run's findings" >&2
  exit 1
}

printf '%s\n' "$rounds" | python3 -I -c '
import json
import sys

run, step = sys.argv[1:]
rounds = [json.loads(line) for line in sys.stdin if line.strip()]
if step:
    rounds = [r for r in rounds if r["step"] == step]
if not rounds:
    where = "run %s step %s" % (run, step) if step else "run %s" % run
    print("error: no-mistakes %s has no recorded round" % where, file=sys.stderr)
    sys.exit(1)


def field(finding, key):
    value = finding.get(key)
    return "" if value is None else str(value)


# (step, finding as stored) -> the earliest round of that step that selected it.
selected = {}
for r in rounds:
    for f in r["findings"]:
        if f.get("id") in r["selected"]:
            selected.setdefault((r["step_result"], json.dumps(f, sort_keys=True)), r["round"])

blocks = []
for r in rounds:
    shown = r["findings"]
    lines = ["== run %s step %s round %s" % (r["run"], r["step"], r["round"])]
    if r.get("coverage_parked"):
        lines += ["id: coverage", "action: ask-user",
                  "unverified: " + ", ".join(r.get("coverage_unverified") or []), ""]
    elif not shown:
        lines.append("(no findings)")
    for f in shown:
        lines.append("id: " + field(f, "id"))
        earlier = selected.get((r["step_result"], json.dumps(f, sort_keys=True)))
        if earlier is not None and earlier < r["round"]:
            lines.append("carried: round %s" % earlier)
        lines += ["severity: " + field(f, "severity"),
                  "file: " + field(f, "file"), "line: " + field(f, "line"),
                  "action: " + field(f, "action"), "description: " + field(f, "description"), ""]
    blocks.append("\n".join(lines).rstrip("\n"))
print("\n\n".join(blocks))
' "$run" "$step"
