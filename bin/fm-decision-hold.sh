#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh gate-link <item-id> <origin-id> <decision-key>
#   fm-decision-hold.sh gate-resolve <origin-id> <decision-key> \
#     (--answered-by <captain|firstmate> --answer-file <path> | --not-raised)
#   fm-decision-hold.sh gate-status <origin-id>
#   fm-decision-hold.sh gate-verify <origin-id>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# The gate-* commands cover the separate case of a captain-gated backlog item
# filed mid-flight, whose question a live worker's own gate will also raise. They
# never guess that pairing: `gate-link` records it, and every other gate-*
# command reads only that record. The link lives in
# data/gate-links/<origin-id>/<decision-key> as key=value lines, one file per
# gate identity, and that index is the single authority for the pairing. The
# backlog item carries the outcome, not the pairing, so the two never drift.
#
# `gate-resolve` is the reconciliation the answering path owes. It is safe to run
# for every gate answered: an unlinked gate reports that and succeeds, so the
# call can be unconditional. For a linked gate, --answered-by replaces the item's
# body with the recorded answer and who decided it, archiving the superseded
# body, then closes the item.
#
# When the item was already closed by another authority, --answered-by is still
# the verb: the existing body is left intact because it records whoever actually
# closed it, and this gate's answer is appended as a note. Retries are idempotent
# against the recorded decider, answer digest, and closing authority, and refuse
# a changed answer, decider, or closing authority.
#
# Both verbs are statements about the link record, which this home always holds,
# so neither fails because the item was removed, handed to a secondmate, pruned,
# renamed, re-kinded, or made unreadable by the backlog backend. The item write
# is best effort and what this home could observe is recorded. Choose the verb by
# what actually happened: --answered-by when this gate settled the question, and
# --not-raised when it never asked it.
#
# docs/decision-hold-lifecycle.md owns the link record's field contract and the
# symmetry between the two verbs.
#
# `gate-verify` reads only the index, never tasks-axi. Its reader has no silent
# skip: any entry in data/gate-links/<origin-id>/ that is not a fully recognised
# regular link record is itself an unreconciled link, including a dangling
# symlink or a device node, and no field is read from an entry before it is known
# to be a regular file. The refusal names the path for an unrecognised record and
# for an open link alike. Teardown calls it so a landed task cannot quietly leave
# its linked captain item asserting the captain still owes an answer. Cleanup
# therefore now refuses where it previously passed, on an unrecognised or
# hand-edited index entry as well as on an open link. --force remains the
# captain-approved discard escape hatch and still bypasses the check.
#
# `gate-status` reads the same index and prints an unrecognised entry as such,
# so what gate-verify refuses on is visible rather than silently absent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

gate_slug_ok() {  # <value>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

validate_gate_slug() {  # <label> <value>
  validate_slug "$1" "$2"
  gate_slug_ok "$2" || fail "$1 must not begin with a dot: $2"
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

tasks_axi_gap() {  # prints why the captain-hold contract is unusable, empty when it is usable
  fm_tasks_axi_compatible || { printf 'compatible tasks-axi is required'; return 0; }
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || printf 'tasks-axi does not expose the captain-hold contract'
}

require_tasks_axi() {
  local gap
  gap=$(tasks_axi_gap)
  [ -z "$gap" ] || fail "$gap"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A failed read is not an absent task. tasks-axi reports NOT_FOUND for a task
# that is genuinely not in this backlog and another code when it could not read
# the backlog at all, so callers never state absence they did not establish.
refuse_unreadable_backlog() {  # <failed-task-show-output> <what-was-being-checked>
  local code
  code=$(printf '%s\n' "$1" | sed -n 's/^code: //p' | head -1)
  [ -n "$code" ] && [ "$code" != NOT_FOUND ] || return 0
  fail "could not read $FM_HOME/data/backlog.md while checking $2; tasks-axi reported $code"
}

origin_exists_here() {  # <origin-id>
  local out
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  out=$(task_show "$1") && return 0
  refuse_unreadable_backlog "$out" "origin $1"
  return 1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

record_value() {  # <key=value-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(record_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

gate_link_file() {  # <origin-id> <decision-key>
  validate_gate_slug origin-id "$1"
  validate_gate_slug decision-key "$2"
  printf '%s/gate-links/%s/%s\n' "$DATA" "$1" "$2"
}

write_gate_link() {  # <link-file> <item> <origin> <key> <state> [observed] [decided-by] [digest] [closed-by]
  local file=$1 tmp
  mkdir -p "$(dirname "$file")"
  # Staged outside the globbed index directory so a killed write leaves no
  # record the index would read back as a link.
  tmp="$DATA/gate-links/.staged.$$"
  {
    printf 'item=%s\n' "$2"
    printf 'origin=%s\n' "$3"
    printf 'key=%s\n' "$4"
    printf 'state=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'item_observed=%s\n' "$6"
    [ -z "${7:-}" ] || printf 'decided_by=%s\n' "$7"
    [ -z "${8:-}" ] || printf 'answer_digest=%s\n' "$8"
    [ -z "${9:-}" ] || printf 'closed_by=%s\n' "$9"
  } > "$tmp"
  mv "$tmp" "$file"
}

gate_answer_body() {  # <origin> <key> <decided-by> <digest> <answer>
  printf 'Answered through gate %s/%s.\nDecided by: %s\nAnswer digest: %s\n\n%s\n' \
    "$1" "$2" "$3" "$4" "$5"
}

gate_marker_identity() {  # <item-body>
  local body=$1 marker='Answered through gate ' sep='.\n' rest identity
  body=${body#\"}
  case "$body" in
    "$marker"*) rest=${body#"$marker"} ;;
    *) return 0 ;;
  esac
  case "$rest" in
    *"$sep"*) identity=${rest%%"$sep"*} ;;
    *) return 0 ;;
  esac
  case "$identity" in
    *[!A-Za-z0-9._/-]*|/*|*/|*/*/*) return 0 ;;
    */*) printf '%s' "$identity" ;;
  esac
}

# The index reader has no silent skip: an entry it cannot fully recognise is an
# unreconciled link, not a file to pass over. Every earlier narrowing here was
# correct on its own and each one added another way to be skipped, because the
# reader's default was permissive. A file the reader cannot understand is a
# reason to stop, not a reason to continue.
#
# Emits one tab-separated verdict line per directory entry, dotfiles included:
#   ok<TAB><file><TAB><key><TAB><state><TAB><item>
#   unrecognised<TAB><file><TAB><TAB><TAB>
origin_gate_records() {  # <origin-id>
  local origin=$1 dir file base state item dotglob=off
  validate_gate_slug origin-id "$origin"
  dir="$DATA/gate-links/$origin"
  [ -d "$dir" ] || return 0
  shopt -q dotglob && dotglob=on
  shopt -s dotglob
  for file in "$dir"/*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base=${file##*/}
    if [ ! -f "$file" ] || ! gate_slug_ok "$base"; then
      printf 'unrecognised\t%s\t\t\t\n' "$file"
      continue
    fi
    item=$(record_value "$file" item)
    state=$(record_value "$file" state)
    if [ -z "$item" ] \
      || [ "$(record_value "$file" origin)" != "$origin" ] \
      || [ "$(record_value "$file" key)" != "$base" ]; then
      printf 'unrecognised\t%s\t\t\t\n' "$file"
      continue
    fi
    case "$state" in
      open|answered|not-raised) printf 'ok\t%s\t%s\t%s\t%s\n' "$file" "$base" "$state" "$item" ;;
      *) printf 'unrecognised\t%s\t\t\t\n' "$file" ;;
    esac
  done
  [ "$dotglob" = on ] || shopt -u dotglob
}

# What was observed about the item is its own record field, separate from who
# closed it, so no value ever does duty for two situations. Every situation is
# named; an unnamed one refuses rather than folding into the nearest token.
# The result lands in these variables rather than on stdout, so a refusal here
# ends the command instead of dying inside a command substitution.
GATE_ITEM_OBSERVED=''
GATE_ITEM_STATE=''
GATE_ITEM_BODY=''
GATE_ITEM_HELD=''

observe_gate_item() {  # <item-id>
  local item=$1 show
  GATE_ITEM_OBSERVED=''
  GATE_ITEM_STATE=''
  GATE_ITEM_BODY=''
  GATE_ITEM_HELD=''
  if ! fm_tasks_axi_version_parts >/dev/null 2>&1; then
    GATE_ITEM_OBSERVED=backend-unusable
    return 0
  fi
  if ! show=$(task_show "$item"); then
    refuse_unreadable_backlog "$show" "captain-gated item $item"
    GATE_ITEM_OBSERVED=absent-here
    return 0
  fi
  GATE_ITEM_STATE=$(show_field "$show" state)
  GATE_ITEM_BODY=$(show_field "$show" body)
  GATE_ITEM_HELD=$(show_field "$show" held)
  if [ "$(show_field "$show" kind)" = captain ]; then
    GATE_ITEM_OBSERVED=present-captain
  else
    GATE_ITEM_OBSERVED=present-other-kind
  fi
}

# Both verbs are statements about the link record, which this home always holds.
# Neither requires the item to exist, to still be kind captain, or to be readable
# at all: the item write is best effort and what was observed is recorded.
gate_closing_authority() {  # <item-state> <item-body> <origin> <key> <item>; sets GATE_CLOSED_BY
  GATE_CLOSED_BY=''
  [ "$1" = "done" ] || return 0
  GATE_CLOSED_BY=$(gate_marker_identity "$2")
  [ "$GATE_CLOSED_BY" != "$3/$4" ] \
    || fail "captain-gated item $5 was closed through gate $3/$4; reconcile it with --answered-by"
  [ -n "$GATE_CLOSED_BY" ] || GATE_CLOSED_BY=external
}

retire_gate_link() {  # <link-file> <item> <origin> <key>
  local file=$1 item=$2 origin=$3 key=$4
  local observed item_state item_body closed_by='' recorded outcome
  observe_gate_item "$item"
  observed=$GATE_ITEM_OBSERVED
  item_state=$GATE_ITEM_STATE
  item_body=$GATE_ITEM_BODY
  case "$observed" in
    present-captain|present-other-kind)
      gate_closing_authority "$item_state" "$item_body" "$origin" "$key" "$item"
      closed_by=$GATE_CLOSED_BY
      if [ "$observed" = present-captain ]; then
        outcome="$item left open"
        [ -z "$closed_by" ] || outcome="$item was already closed by $closed_by"
      else
        outcome="$item is no longer a captain item and is still open"
        [ -z "$closed_by" ] \
          || outcome="$item is no longer a captain item and was already closed by $closed_by"
      fi
      ;;
    absent-here) outcome="$item is absent from this home" ;;
    backend-unusable) outcome="$item could not be read because the backlog backend is unusable" ;;
    *) fail "could not classify what this home observes about captain-gated item $item: $observed" ;;
  esac
  recorded=$(record_value "$file" closed_by)
  [ -z "$recorded" ] || [ -z "$closed_by" ] || [ "$recorded" = "$closed_by" ] \
    || fail "gate $origin/$key records a different authority for closing $item"
  write_gate_link "$file" "$item" "$origin" "$key" not-raised "$observed" '' '' "$closed_by"
  printf 'gate-resolve: %s/%s not raised; %s\n' "$origin" "$key" "$outcome"
}

command_gate_link() {
  local item=${1:-} origin=${2:-} key=${3:-} file show state kind existing
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  validate_slug item-id "$item"
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  file=$(gate_link_file "$origin" "$key")
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  show=$(task_show "$item") || fail "captain-gated item $item is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  [ "$kind" = captain ] || fail "backlog item $item is not kind captain"
  [ "$state" != "done" ] || fail "backlog item $item is already closed"
  if [ -f "$file" ]; then
    existing=$(record_value "$file" item)
    [ "$existing" = "$item" ] \
      || fail "gate $origin/$key is already linked to a different captain item: $existing"
    [ "$(record_value "$file" state)" = open ] \
      || fail "gate link $origin/$key is already reconciled; use a new decision key for a new question"
    printf '%s\n' "$file"
    return 0
  fi
  write_gate_link "$file" "$item" "$origin" "$key" open present-captain
  printf '%s\n' "$file"
}

command_gate_resolve() {
  local origin=${1:-} key=${2:-} decided_by='' answer_file='' not_raised=0
  local file item state observed item_state item_body answer digest body closed_by recorded note
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answered-by) shift; decided_by=${1:-} ;;
      --answer-file) shift; answer_file=${1:-} ;;
      --not-raised) not_raised=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  if [ "$not_raised" = 1 ]; then
    [ -z "$decided_by" ] && [ -z "$answer_file" ] \
      || fail "--not-raised cannot be combined with --answered-by or --answer-file"
  else
    case "$decided_by" in
      captain|firstmate) : ;;
      *) fail "--answered-by must be captain or firstmate" ;;
    esac
    [ -n "$answer_file" ] || fail "--answer-file is required"
    [ -f "$answer_file" ] || fail "answer file does not exist: $answer_file"
    answer=$(cat "$answer_file")
    [ -n "$answer" ] || fail "answer file must not be empty"
    [ "$(printf '%s' "$answer" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
      || fail "answer file exceeds 8192 bytes"
    digest=$(sha256_text "$answer")
  fi
  file=$(gate_link_file "$origin" "$key")
  if [ ! -f "$file" ]; then
    printf 'gate-resolve: %s/%s has no linked captain-gated item\n' "$origin" "$key"
    return 0
  fi
  item=$(record_value "$file" item)
  [ -n "$item" ] || fail "gate link $file records no captain-gated item"
  validate_slug item-id "$item"
  state=$(record_value "$file" state)
  case "$state" in
    open) : ;;
    not-raised)
      [ "$not_raised" = 1 ] \
        || fail "gate $origin/$key was already reconciled as not raised"
      ;;
    answered)
      [ "$not_raised" = 0 ] \
        || fail "gate $origin/$key was already answered; it cannot be retired as not raised"
      ;;
    *) fail "gate link $file has an unrecognised state: $state" ;;
  esac

  if [ "$not_raised" = 1 ]; then
    retire_gate_link "$file" "$item" "$origin" "$key"
    return 0
  fi

  observe_gate_item "$item"
  observed=$GATE_ITEM_OBSERVED
  item_state=$GATE_ITEM_STATE
  item_body=$GATE_ITEM_BODY

  # Who closed the item is read only from this mechanism's own marker, never
  # from free prose: self when this gate closed it, the gate identity recorded
  # in the marker when another gate did, external otherwise. It stays empty
  # whenever the item was not observed closed.
  closed_by=''
  case "$observed" in
    present-captain|present-other-kind)
      if [ "$item_state" = "done" ]; then
        case "$item_body" in
          *"Answered through gate $origin/$key."*"Answer digest: $digest"*) closed_by=self ;;
          *)
            closed_by=$(gate_marker_identity "$item_body")
            [ "$closed_by" != "$origin/$key" ] \
              || fail "captain-gated item $item is already closed with a different answer from gate $origin/$key"
            [ -n "$closed_by" ] || closed_by=external
            ;;
        esac
      elif [ "$observed" = present-captain ]; then
        closed_by=self
      fi
      ;;
    absent-here|backend-unusable) : ;;
    *) fail "could not classify what this home observes about captain-gated item $item: $observed" ;;
  esac

  if [ "$state" = answered ]; then
    [ "$(record_value "$file" decided_by)" = "$decided_by" ] \
      || fail "gate $origin/$key records a different decider"
    [ "$(record_value "$file" answer_digest)" = "$digest" ] \
      || fail "gate $origin/$key records a different answer"
    recorded=$(record_value "$file" closed_by)
    [ -z "$recorded" ] || [ -z "$closed_by" ] || [ "$recorded" = "$closed_by" ] \
      || fail "gate $origin/$key records a different authority for closing $item"
    printf 'gate-resolve: %s/%s already answered by %s (%s closed)\n' \
      "$origin" "$key" "$decided_by" "$item"
    return 0
  fi

  if [ "$observed" = present-captain ]; then
    require_tasks_axi
    if [ "$item_state" != "done" ]; then
      body=$(gate_answer_body "$origin" "$key" "$decided_by" "$digest" "$answer")
      if [ "$GATE_ITEM_HELD" = yes ]; then
        tasks_axi unhold "$item" >/dev/null || fail "could not release the captain hold on $item"
      fi
      printf '%s' "$body" > "$STATE/.gate-answer.$$"
      tasks_axi update "$item" --body-file "$STATE/.gate-answer.$$" --archive-body >/dev/null \
        || { rm -f "$STATE/.gate-answer.$$"; fail "could not record the gate answer on $item"; }
      rm -f "$STATE/.gate-answer.$$"
      tasks_axi "done" "$item" >/dev/null || fail "could not close answered captain item $item"
    elif [ "$closed_by" != self ]; then
      # The closed item already records who actually answered it, so this gate's
      # outcome is appended rather than allowed to overwrite that record.
      note="Also answered through gate $origin/$key. Decided by: $decided_by."
      case "$item_body" in
        *"$note"*) : ;;
        *) tasks_axi "done" "$item" --note "$note" >/dev/null \
             || fail "could not record this gate's answer on already closed $item" ;;
      esac
    fi
  fi
  write_gate_link "$file" "$item" "$origin" "$key" answered "$observed" \
    "$decided_by" "$digest" "$closed_by"
  case "$observed" in
    present-captain)
      if [ "$closed_by" = self ]; then
        printf 'gate-resolve: %s/%s answered by %s -> %s closed\n' "$origin" "$key" "$decided_by" "$item"
      else
        printf 'gate-resolve: %s/%s answered by %s; %s was already closed by %s\n' \
          "$origin" "$key" "$decided_by" "$item" "$closed_by"
      fi
      ;;
    present-other-kind)
      printf 'gate-resolve: %s/%s answered by %s; recorded against the link only because %s is no longer a captain item and was not written\n' \
        "$origin" "$key" "$decided_by" "$item"
      ;;
    absent-here)
      printf 'gate-resolve: %s/%s answered by %s; recorded against the link only because %s is absent from this home and was not written\n' \
        "$origin" "$key" "$decided_by" "$item"
      ;;
    backend-unusable)
      printf 'gate-resolve: %s/%s answered by %s; recorded against the link only because %s could not be written while the backlog backend is unusable\n' \
        "$origin" "$key" "$decided_by" "$item"
      ;;
  esac
}

command_gate_status() {
  local origin=${1:-} verdict file key state item
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_gate_slug origin-id "$origin"
  while IFS=$'\t' read -r verdict file key state item; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = ok ]; then
      printf '%s\t%s\t%s\n' "$key" "$state" "$item"
    else
      printf '%s\tunrecognised\t%s\n' "${file##*/}" "$file"
    fi
  done <<EOF
$(origin_gate_records "$origin")
EOF
}

command_gate_verify() {
  local origin=${1:-} verdict file key state item open='' unrecognised='' problems=''
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_gate_slug origin-id "$origin"
  while IFS=$'\t' read -r verdict file key state item; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" != ok ]; then
      unrecognised="${unrecognised}${unrecognised:+, }$file"
      continue
    fi
    [ "$state" = open ] || continue
    open="${open}${open:+, }$key ($file)"
  done <<EOF
$(origin_gate_records "$origin")
EOF
  [ -z "$unrecognised" ] || problems="unrecognised captain-gated link records: $unrecognised"
  [ -z "$open" ] \
    || problems="${problems}${problems:+; }unreconciled captain-gated links: $open"
  [ -z "$problems" ] || fail "origin $origin has $problems"
  printf 'verified: %s captain-gated links\n' "$origin"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    refuse_unreadable_backlog "$show" "captain decision $id"
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(record_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(record_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(record_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(record_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(record_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  gate-link) shift; command_gate_link "$@" ;;
  gate-resolve) shift; command_gate_resolve "$@" ;;
  gate-status) shift; command_gate_status "$@" ;;
  gate-verify) shift; command_gate_verify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
