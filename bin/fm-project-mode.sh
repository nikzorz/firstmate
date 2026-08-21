#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and project-memory posture from
# the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --project-memory, prints one word instead: agents-md|keep-claude-md.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Flags inside the brackets are order-independent and each is optional:
#   +yolo             autonomy posture (below)
#   +keep-claude-md   project-memory posture (below)
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# project memory (orthogonal) = which file a crewmate records durable project
#   knowledge in, queried with --project-memory:
#   agents-md        default: AGENTS.md via bin/fm-ensure-agents-md.sh
#   keep-claude-md   +keep-claude-md: the project keeps CLAUDE.md as the real
#                    file and no AGENTS.md is created for it. Set this only on a
#                    recorded captain decision for that project; bin/fm-brief.sh
#                    turns it into a prohibition in the generated ship brief,
#                    because a brief that merely omits the default instruction
#                    still ships the opposite of that decision.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, and a bracket token starting with "+" that is neither +yolo nor
# +keep-claude-md warns and is ignored, so a typo never silently drops a posture.
# The project-memory posture falls back to agents-md, the behavior every project
# had before the flag existed.
# Usage: fm-project-mode.sh [--project-memory] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

usage() {
  echo "usage: fm-project-mode.sh [--project-memory] <project-name>" >&2
  exit 1
}

QUERY=posture
NAME=
for arg in "$@"; do
  case "$arg" in
    --project-memory) QUERY=project-memory ;;
    -*) usage ;;
    *) [ -z "$NAME" ] || usage; NAME=$arg ;;
  esac
done
[ -n "$NAME" ] || usage

emit() {
  if [ "$QUERY" = project-memory ]; then
    echo "$3"
  else
    echo "$1 $2"
  fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  emit no-mistakes off agents-md
  exit 0
fi

# awk emits "<mode> <yolo> <memory> [unknown +flags...]" (one line) or nothing if
# the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; memory="agents-md"; unknown="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] !~ /^\+/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j]=="+keep-claude-md") memory="keep-claude-md";
        else if (a[j] ~ /^\+/) unknown = unknown (unknown==""?"":" ") a[j];
      }
    }
    print mode, yolo, memory, unknown; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  emit no-mistakes off agents-md
  exit 0
fi

read -r mode yolo memory unknown <<EOF
$parsed
EOF
for flag in $unknown; do
  echo "warn: unknown flag \"$flag\" for $NAME; ignoring it" >&2
done
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$memory" in agents-md|keep-claude-md) ;; *) memory=agents-md ;; esac
emit "$mode" "$yolo" "$memory"
