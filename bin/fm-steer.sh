#!/usr/bin/env bash
# fm-steer.sh - a worker's read and acknowledge commands for its steering inbox.
#
# Usage:
#   fm-steer.sh read [--inbox <dir>]
#   fm-steer.sh ack [--inbox <dir>] <NNN>...
#
# The inbox is --inbox, or else $FM_TASK_INBOX, which every launched worker
# carries. bin/fm-task-inbox-lib.sh owns the inbox layout and record format;
# this script only reads and acknowledges records through it. It is the
# worker's side of steering; bin/fm-send.sh writes the records, and the
# captain's own capture inbox is bin/fm-inbox.sh, which this never touches.
#
# read prints every unacknowledged message, oldest first, each under a
# "=== <NNN>.msg (at <time>) ===" header followed by its exact text, then the
# ack command naming the messages it printed. Reading acknowledges nothing, so
# a message read but not yet acted on still rings again. An empty or absent
# inbox prints "no unread messages".
# ack moves each named message into handled/, which is the acknowledgement.
# <NNN> is digits only and compared numerically, so 7 and 007 name the same
# message; a .msg suffix or a path is refused. A message already in handled/ is
# reported and not an error; one found nowhere is an error, after the others
# are still acknowledged.
#
# Exit status: 0 on success, 1 when a named message could not be
# acknowledged, 2 on a usage error.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

die_usage() {
  printf 'fm-steer.sh: %s\n' "$1" >&2
  printf "run 'fm-steer.sh --help' for usage\n" >&2
  exit 2
}

ACTION=
INBOX=${FM_TASK_INBOX:-}
INBOX_FLAG=0
SEQS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --inbox) [ "$#" -ge 2 ] || die_usage "--inbox requires a value"; INBOX=$2; INBOX_FLAG=1; shift 2; continue ;;
    --*) die_usage "unknown option: $1" ;;
  esac
  if [ -z "$ACTION" ]; then
    case "$1" in
      read|ack) ACTION=$1 ;;
      *) die_usage "unknown command: $1 (read or ack)" ;;
    esac
  else
    [ "$ACTION" = ack ] || die_usage "read takes no message names"
    SEQS+=("$1")
  fi
  shift
done

[ -n "$ACTION" ] || die_usage "missing the command (read or ack)"
[ -n "$INBOX" ] || die_usage "no inbox: pass --inbox <dir> or set FM_TASK_INBOX"
INBOX=${INBOX%/}

# The ack command a reader runs next, spelled as this call was spelled.
ack_hint() {  # <seq>...
  local hint
  hint="$(shell_quote "$0") ack"
  [ "$INBOX_FLAG" -eq 0 ] || hint="$hint --inbox $(shell_quote "$INBOX")"
  printf 'acknowledge after acting: %s %s\n' "$hint" "$*"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if [ "$ACTION" = read ]; then
  records=()
  for f in "$INBOX"/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    records+=("$(printf '%012d' "$n") $f")
  done
  if [ "${#records[@]}" -eq 0 ]; then
    echo "no unread messages"
    exit 0
  fi
  names=()
  while IFS= read -r entry; do
    f=${entry#* }
    base=${f##*/}
    names+=("${base%.msg}")
    at=$(sed -n '/^--$/q; s/^at=//p' "$f" 2>/dev/null | head -1)
    printf '=== %s%s ===\n' "$base" "${at:+ (at $at)}"
    if ! fm_task_inbox_body "$f"; then
      echo "(record has no header; its whole text follows)"
      cat "$f"
    fi
    printf '\n'
  done < <(printf '%s\n' "${records[@]}" | sort)
  ack_hint "${names[@]}"
  exit 0
fi

[ "${#SEQS[@]}" -gt 0 ] || die_usage "ack needs at least one message number"
for s in "${SEQS[@]}"; do
  case "$s" in ''|*[!0-9]*) die_usage "'$s' is not a message number" ;; esac
done

rc=0
for s in "${SEQS[@]}"; do
  want=$((10#$s))
  found=
  for f in "$INBOX"/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -eq "$want" ] && { found=$f; break; }
  done
  if [ -n "$found" ]; then
    if mkdir -p "$INBOX/handled" && mv "$found" "$INBOX/handled/"; then
      printf 'acknowledged %s\n' "${found##*/}"
    else
      printf 'fm-steer.sh: could not move %s into handled/\n' "${found##*/}" >&2
      rc=1
    fi
    continue
  fi
  done_already=
  for f in "$INBOX"/handled/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -eq "$want" ] && { done_already=$f; break; }
  done
  if [ -n "$done_already" ]; then
    printf 'already acknowledged %s\n' "${done_already##*/}"
  else
    printf 'fm-steer.sh: no message %s in %s\n' "$s" "$INBOX" >&2
    rc=1
  fi
done
exit "$rc"
