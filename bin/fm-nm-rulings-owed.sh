#!/usr/bin/env bash
# fm-nm-rulings-owed.sh - list every no-mistakes pipeline round a task still
# owes a decision line, before the merge refuses over it.
#
# Usage: fm-nm-rulings-owed.sh <task-id>
#
# Prints the verdict bin/fm-pr-merge.sh would refuse a merge over, from the
# same judgment (bin/fm-nm-rulings-lib.sh owns which rounds owe a line and what
# names one): one line per owed finding or approved coverage park, then the
# exact decision lines that clear them, so a worker can append those lines
# before its ready report. Reads the task record and status log under the
# home's state directory (FM_STATE_OVERRIDE, default $FM_HOME/state), names
# snapshot files under its data directory (FM_DATA_OVERRIDE, default
# $FM_HOME/data), and reads no-mistakes' state database (NM_HOME, default
# ~/.no-mistakes). Writes nothing.
#
# Exit status: 0 when nothing is owed, including a task that is not a
# no-mistakes task or records no branch; 1 when a ruling is owed; 3 when what
# the judgment needs could not be read, named on stdout; 2 on a usage error.
set -eu

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-nm-rulings-lib.sh
. "$SCRIPT_DIR/fm-nm-rulings-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  usage >&2
  exit 2
fi
id=$1

fm_nm_rulings_owed "$id" "$STATE" "$DATA"
if [ "$FM_NM_RULINGS_UNREADABLE" = true ]; then
  printf 'whether task %s owes a decision line could not be judged:\n%s' "$id" "$FM_NM_RULINGS_OWED"
  exit 3
fi
if [ -z "$FM_NM_RULINGS_OWED" ]; then
  printf 'task %s owes no decision line\n' "$id"
  exit 0
fi
printf 'task %s owes a decision line for:\n%s' "$id" "$FM_NM_RULINGS_OWED"
fm_nm_rulings_clearing_text "$STATE/$id.status"
exit 1
