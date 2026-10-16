#!/usr/bin/env bash
# fm-nm-findings.sh - print a no-mistakes run's findings whole.
#
# Usage: fm-nm-findings.sh <run-id> [--step <step>] [<finding-id>...]
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
# Naming finding ids prints only those findings, in every round that raised
# them.
#
# Exit status: 0 when everything asked for printed; 1 when the database cannot
# be read, the run (or step) has no recorded round, or a named finding id is in
# none of the rounds read, naming each missing id; 2 on a usage error.
set -eu

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-findings-lib.sh
. "$SCRIPT_DIR/fm-nm-findings-lib.sh"

[ $# -ge 1 ] && [ -n "$1" ] && case "$1" in -*) false ;; esac \
  || { usage >&2; exit 2; }
run=$1
shift
step=
ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --step)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --step needs a step name" >&2; exit 2; }
      step=$2
      shift 2
      ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) ids+=("$1"); shift ;;
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

run, step, *ids = sys.argv[1:]
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


seen = set()
blocks = []
for r in rounds:
    shown = [f for f in r["findings"] if not ids or f.get("id") in ids]
    seen.update(f.get("id") for f in shown)
    if ids and not shown:
        continue
    lines = ["== run %s step %s round %s" % (r["run"], r["step"], r["round"])]
    if not shown:
        lines.append("(no findings)")
    for f in shown:
        lines += ["id: " + field(f, "id"), "severity: " + field(f, "severity"),
                  "file: " + field(f, "file"), "line: " + field(f, "line"),
                  "action: " + field(f, "action"), "description: " + field(f, "description"), ""]
    blocks.append("\n".join(lines).rstrip("\n"))
missing = [i for i in ids if i not in seen]
if blocks:
    print("\n\n".join(blocks))
for i in missing:
    print("error: finding %s is in no round of no-mistakes %s" % (i, "run %s step %s" % (run, step) if step else "run %s" % run),
          file=sys.stderr)
sys.exit(1 if missing else 0)
' "$run" "$step" ${ids[@]+"${ids[@]}"}
