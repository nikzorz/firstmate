#!/usr/bin/env bash
# fm-status.sh - append one worker status line and record it in the fleet ledger.
#
# Usage:
#   fm-status.sh <status-file> <state> [--key <slug>] [--until <when>] [--config <dir>] [--] <note>...
#   fm-status.sh <status-file> --line <status-line> [--config <dir>]
#
# The first form writes "<state> [at=<epoch>] [key=<slug>]: <note>", the
# grammar bin/fm-classify-lib.sh parses, with the epoch read from the clock
# here so a caller never types one. Note words are joined with single spaces.
# <state> is any status verb bin/fm-classify-lib.sh recognizes except note and
# the captain-held verb: working, needs-decision, blocked, done, failed, and the
# configured paused and resolve verbs (FM_CLASSIFY_PAUSED_VERB, default
# "paused"; FM_CLASSIFY_RESOLVE_VERB, default "resolved").
# --until is accepted only on a paused line and appends " until <UTC time>":
# <when> is +N, +Ns, +Nm, or +Nh from now, rounded up to the next whole minute,
# or an explicit YYYY-MM-DDTHH:MMZ.
# The second form appends a complete line some other command printed for the
# worker to append, adding the time stamp only when the line has none.
# A note or line holding a newline is refused, because each status event is
# one line.
#
# After the append succeeds, and only while <config>/fleet-ledger exists, the
# line is handed to bin/fm-fleet-ledger.sh `appended`; a ledger failure is
# silent and never changes this command's result (docs/fleet-ledger.md).
# <config> defaults to the config/ directory beside the status file's state/
# directory, which is where it sits unless the home overrides its state or
# config location.
#
# Prints the appended line. Exit status: 0 when the line was appended, 1 when
# the append failed, 2 on a usage error (nothing is written).
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die_usage() {
  printf 'fm-status.sh: %s\n' "$1" >&2
  printf "run 'fm-status.sh --help' for usage\n" >&2
  exit 2
}

PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
STATUS_FILE=
STATE_WORD=
KEY=
KEY_SET=0
UNTIL=
UNTIL_SET=0
RAW_LINE=
RAW_SET=0
CONFIG=
NOTE=
positional=0
take_value() {  # <option> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) take_value "$1" "$#"; KEY=$2; KEY_SET=1; shift 2; continue ;;
    --until) take_value "$1" "$#"; UNTIL=$2; UNTIL_SET=1; shift 2; continue ;;
    --line) take_value "$1" "$#"; RAW_LINE=$2; RAW_SET=1; shift 2; continue ;;
    --config) take_value "$1" "$#"; CONFIG=$2; shift 2; continue ;;
    --) shift
      while [ "$#" -gt 0 ]; do NOTE="${NOTE:+$NOTE }$1"; shift; done
      break ;;
    --*) die_usage "unknown option: $1" ;;
  esac
  case "$positional" in
    0) STATUS_FILE=$1 ;;
    1) if [ "$RAW_SET" -eq 1 ]; then NOTE="${NOTE:+$NOTE }$1"; else STATE_WORD=$1; fi ;;
    *) NOTE="${NOTE:+$NOTE }$1" ;;
  esac
  positional=$((positional + 1))
  shift
done

[ -n "$STATUS_FILE" ] || die_usage "missing the status file"
case "$STATUS_FILE" in /*) ;; *) STATUS_FILE="$PWD/$STATUS_FILE" ;; esac

case "$RAW_LINE$NOTE" in
  *$'\n'*|*$'\r'*) die_usage "a status line is one line; the note holds a newline" ;;
esac

if [ "$RAW_SET" -eq 1 ]; then
  [ -n "$STATE_WORD$NOTE" ] && die_usage "--line takes the whole line; drop the state and note"
  [ "$KEY_SET$UNTIL_SET" = 00 ] || die_usage "--line takes the whole line; drop --key and --until"
  [ -n "$RAW_LINE" ] || die_usage "--line is empty"
  LINE=$(status_stamp_line "$RAW_LINE")
else
  [ -n "$STATE_WORD" ] || die_usage "missing the state"
  if [ "$STATE_WORD" = note ] \
    || [ "$STATE_WORD" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ] \
    || ! _fm_status_verb_recognized "$STATE_WORD"; then
    die_usage "unknown state '$STATE_WORD' (working, needs-decision, blocked, $PAUSED_VERB, done, failed, ${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT})"
  fi
  [ -n "$NOTE" ] || die_usage "missing the note"
  if [ "$KEY_SET" -eq 1 ] && ! _fm_decision_slug_ok "$KEY"; then
    die_usage "key '$KEY' is not a slug of A-Za-z0-9._-"
  fi
  NOW=$(date +%s 2>/dev/null) || NOW=
  case "$NOW" in ''|*[!0-9]*) NOW= ;; esac
  if [ "$UNTIL_SET" -eq 1 ]; then
    [ "$STATE_WORD" = "$PAUSED_VERB" ] || die_usage "--until applies only to a $PAUSED_VERB line"
    case "$UNTIL" in
      +*)
        amount=${UNTIL#+}
        unit=s
        case "$amount" in *[smh]) unit=${amount#"${amount%?}"}; amount=${amount%?} ;; esac
        case "$amount" in ''|*[!0-9]*|0[0-9]*) die_usage "--until '$UNTIL' is not +N, +Ns, +Nm, or +Nh" ;; esac
        [ "${#amount}" -le 9 ] || die_usage "--until '$UNTIL' is too far away"
        [ -n "$NOW" ] || { echo "fm-status.sh: the clock could not be read for --until" >&2; exit 1; }
        case "$unit" in m) amount=$((amount * 60)) ;; h) amount=$((amount * 3600)) ;; esac
        due=$((NOW + amount))
        [ $((due % 60)) -eq 0 ] || due=$((due + 60 - due % 60))
        UNTIL=$(date -u -r "$due" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$due" +%Y-%m-%dT%H:%MZ 2>/dev/null) \
          || { echo "fm-status.sh: the --until time could not be formatted" >&2; exit 1; }
        ;;
      *)
        case "$UNTIL" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) ;;
          *) die_usage "--until '$UNTIL' is not +N[smh] or YYYY-MM-DDTHH:MMZ" ;;
        esac
        fm_utc_iso_to_epoch "$UNTIL" >/dev/null || die_usage "--until '$UNTIL' is not a real UTC time"
        ;;
    esac
    NOTE="$NOTE until $UNTIL"
  fi
  # An unreadable clock still records the event, unstamped, exactly as
  # status_stamp_line does: a missing time is unknown, never invented.
  LINE=$STATE_WORD
  [ -z "$NOW" ] || LINE="$LINE [at=$NOW]"
  [ "$KEY_SET" -eq 0 ] || LINE="$LINE [key=$KEY]"
  LINE="$LINE: $NOTE"
fi

printf '%s\n' "$LINE" >> "$STATUS_FILE" || {
  echo "fm-status.sh: could not append to $STATUS_FILE" >&2
  exit 1
}
printf '%s\n' "$LINE"

if [ -z "$CONFIG" ]; then
  state_dir=${STATUS_FILE%/*}
  CONFIG="${state_dir%/*}/config"
fi
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
if [ -e "$CONFIG/fleet-ledger" ]; then
  "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATUS_FILE" >/dev/null 2>&1 || true
fi
exit 0
