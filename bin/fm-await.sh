#!/usr/bin/env bash
# fm-await.sh - wait, in one bounded call, for a line in a file or for a process to exit.
#
# Usage:
#   fm-await.sh <file> --match <regex> [--max <seconds>]
#   fm-await.sh <pid> [--max <seconds>]
#
# A target of digits only is a process id; anything else is a file path (name
# a file called only digits as ./<digits>).
# File form: returns as soon as any line of <file> matches the extended
# regular expression <regex> and prints the first such line. A file that does
# not exist yet is waited for. Lines already present count, so calling again
# after "still waiting" never misses a line that landed between the calls.
# Process form: returns as soon as process <pid> no longer runs (a zombie
# counts as exited) and prints "pid <pid> exited". The process is watched by
# id, so the wait can never match its own shell the way a `pgrep -f` loop does.
#
# --max (default 540, a little under a ten-minute harness command limit)
# bounds the whole call: when it passes first, the call prints
# "still waiting: ..." and exits 1, and running it again continues the wait.
#
# Exit status: 0 when the line appeared or the process exited, 1 when --max
# passed first, 2 on a usage error.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

die_usage() {
  printf 'fm-await.sh: %s\n' "$1" >&2
  printf "run 'fm-await.sh --help' for usage\n" >&2
  exit 2
}

TARGET=
MATCH=
MATCH_SET=0
MAX=540
while [ "$#" -gt 0 ]; do
  case "$1" in
    --match) [ "$#" -ge 2 ] || die_usage "--match requires a value"; MATCH=$2; MATCH_SET=1; shift 2 ;;
    --max) [ "$#" -ge 2 ] || die_usage "--max requires a value"; MAX=$2; shift 2 ;;
    --*) die_usage "unknown option: $1" ;;
    *) [ -z "$TARGET" ] || die_usage "one target only: $TARGET, then $1"; TARGET=$1; shift ;;
  esac
done

[ -n "$TARGET" ] || die_usage "missing the file or pid to wait on"
case "$MAX" in ''|*[!0-9]*|0) die_usage "--max must be a positive whole number of seconds" ;; esac
[ "${#MAX}" -le 6 ] || die_usage "--max $MAX is too long for one call"

case "$TARGET" in
  *[!0-9]*) KIND='file' ;;
  *) KIND='pid' ;;
esac
if [ "$KIND" = pid ]; then
  [ "$MATCH_SET" -eq 0 ] || die_usage "--match applies to a file; $TARGET is a pid"
else
  [ "$MATCH_SET" -eq 1 ] || die_usage "waiting on a file needs --match <regex>"
  [ -n "$MATCH" ] || die_usage "--match is empty"
  printf '' | grep -E -- "$MATCH" >/dev/null 2>&1
  [ "$?" -ne 2 ] || die_usage "--match '$MATCH' is not a valid extended regex"
fi

# 0 when the awaited condition holds, printing what the caller reports.
condition_met() {
  local stat
  if [ "$KIND" = pid ]; then
    stat=$(ps -o stat= -p "$TARGET" 2>/dev/null) || stat=
    case "$stat" in
      ''|Z*) printf 'pid %s exited\n' "$TARGET"; return 0 ;;
    esac
    return 1
  fi
  [ -f "$TARGET" ] || return 1
  grep -E -m 1 -- "$MATCH" "$TARGET" 2>/dev/null
}

deadline=$((SECONDS + MAX))
while :; do
  condition_met && exit 0
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 1
done
if [ "$KIND" = pid ]; then
  printf 'still waiting: pid %s still running after %ss\n' "$TARGET" "$MAX"
else
  printf "still waiting: no line of %s matches '%s' after %ss\n" "$TARGET" "$MATCH" "$MAX"
fi
exit 1
