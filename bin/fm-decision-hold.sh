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
#   fm-decision-hold.sh gate-answered <origin-id> <decision-key> \
#     --answered-by <captain|firstmate> --answer-file <path>
#   fm-decision-hold.sh gate-not-raised <origin-id> <decision-key>
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
# ---------------------------------------------------------------------------
# The gate-* commands: one record, not two.
#
# A captain-gated backlog item filed mid-flight can ask the same question a live
# worker's own gate later raises under a different decision key. Answering only
# the gate used to leave that item claiming the captain still owes an answer.
#
# THE BACKLOG ITEM IS THE SINGLE RECORD of whether a decision is owed. The link
# holds only the one thing the item cannot: the origin-keyed pairing. Teardown
# asks "does this origin have an unreconciled pairing?", and the item store has
# no origin key, so that query needs an index of its own. Nothing else about the
# decision is duplicated here.
#
# Two properties carry the design. Both are stated, not incidental:
#
#   1. `gate-verify` NEVER reads the linked item and NEVER calls tasks-axi. A
#      surviving link is an unreconciled link, full stop. Every way the item can
#      depart or become unreadable is therefore irrelevant by construction rather
#      than classified, and cleanup does not depend on the backlog backend.
#   2. THE LINK RECORD IS FROZEN AT `item`, `origin`, `key`. It is created once
#      and deleted once, never rewritten. A proposal to add a field - a decider, a
#      timestamp, a deferred marker - is this design's declared failure signal,
#      because a mutable durable classification here is what an earlier two-record
#      shape carried, and keeping it in agreement with an item this home does not
#      control is what it could not do.
#
# `gate-answered` performs the item write and only then removes the link, so a
# surviving link always means the write did not land. Idempotency comes from the
# item's own state rather than from anything recorded here.
# `gate-not-raised` removes the link and writes nothing anywhere.
#
# An item "asserts an owed captain decision" when `hold_kind` is captain, a
# `hold_reason` is present, and its state is not done. `kind` is deliberately not
# part of that test: `tasks-axi update --kind` leaves the hold fields intact, so
# reading `kind` classifies a still-held item as no longer captain-owned and lets
# cleanup pass over it. `bin/fm-fleet-snapshot.sh` reads the same fields for
# Bearings and deliberately does not share this code.
#
# Accepted documented limit: a captain item that is RENAMED, or handed to another
# backlog, is indistinguishable from one that was removed, because the link's only
# handle on the item is its id. Both read as "no longer in this backlog" and the
# item keeps asserting an owed decision wherever it now lives. That limit is
# tested as the behaviour it is, not folded into absence.
#
# A read that cannot establish the item's state must never produce the same
# outcome as establishing that the item is fine. Every refusal below is raised
# from the command's own shell, never from inside a `$( )`, because `fail` there
# would exit the subshell and let the caller continue on a permissive default.
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

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
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

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
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

# --- gate-linked captain items -------------------------------------------
#
# See the "one record, not two" section of this script's header for the design.

# `.` and `..` would escape the index directory, and a leading dot hides an entry
# from a plain glob. `fm_task_id_path_safe` in bin/fm-pr-lib.sh sets the same
# precedent for task ids.
gate_slug_ok() {  # <value>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

validate_gate_slug() {  # <label> <value>
  gate_slug_ok "$2" || fail "$1 must be a privacy-safe slug that does not start with a dot: $2"
}

# The item a record names is handed to tasks-axi as an argument, and a leading
# dash there is read as a flag rather than an id, so the shape is checked where
# the record is read rather than where the tool is called.
gate_item_id_ok() {  # <value>
  case "$1" in
    ''|-*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

gate_link_file() {  # <origin-id> <decision-key>
  validate_gate_slug origin-id "$1"
  validate_gate_slug decision-key "$2"
  printf '%s/gate-links/%s/%s\n' "$DATA" "$1" "$2"
}

record_value() {  # <file> <field>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Answers whether this origin's index directory can be listed, without ever
# letting a failure to look stand in for an answer. Absence is only trusted once
# every level above it could actually be searched for it, which is where a
# permissive default kept reappearing one level at a time.
#   0 listable        1 established absent        2 could not be established
gate_index_dir_state() {  # <index-dir>
  local dir=$1 level enclosing=${DATA%/*}
  [ -n "$enclosing" ] || enclosing=/
  # Every level answers the same question, rather than each restating the rule
  # and one of them getting it wrong: a level that is there has to be a directory
  # this process can search, and a level that is not there is only absent if the
  # level above it could be searched to find that out.
  for level in "$enclosing" "$DATA" "$DATA/gate-links"; do
    [ -e "$level" ] || [ -L "$level" ] || return 1
    [ -d "$level" ] && [ -x "$level" ] || return 2
  done
  [ -e "$dir" ] || [ -L "$dir" ] || return 1
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 2
  return 0
}

# Every command that asks "is a pairing recorded here?" asks it through this, so
# no command can reach its own conclusion of absence from a probe that never ran.
#   0 recorded        1 established absent        2 could not be established
gate_link_state() {  # <link-file>
  local file=$1 rc=0
  gate_index_dir_state "${file%/*}" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  return 0
}

# The index reader has no silent skip: anything it cannot fully recognise is an
# unreconciled link, not a file to pass over, and that holds for the directories
# it has to traverse as much as for the records inside them. Every earlier
# narrowing of a reader in this family was correct on its own and each one added
# another way to be skipped, because the default was permissive.
#
# Ordering is load-bearing. `[ -e ]` follows symlinks, so a dangling symlink would
# vanish before it could be reported; `[ -L ]` routes it onward while `[ -e ]`
# still guards an empty glob. The regular-file test then runs BEFORE any field is
# read, so a FIFO planted here cannot block a read and hang cleanup.
#
# Because there is no silent skip, a writer must never stage a partial record
# inside this directory: no name is exempt, so a staging file a crash leaves
# behind reports as an unreconciled link and blocks teardown until someone
# deletes it by hand. Writers stage under `$STATE` and rename into place.
#
# Emits one tab-separated verdict per directory entry, dotfiles included:
#   ok<TAB><file><TAB><key><TAB><item>
#   unrecognised<TAB><file><TAB><TAB>
origin_gate_records() {  # <origin-id>
  local origin=$1 dir file base item dotglob=off rc=0
  validate_gate_slug origin-id "$origin"
  dir="$DATA/gate-links/$origin"
  gate_index_dir_state "$dir" || rc=$?
  [ "$rc" -ne 1 ] || return 0
  if [ "$rc" -ne 0 ]; then
    printf 'unrecognised\t%s\t\t\n' "$dir"
    return 0
  fi
  shopt -q dotglob && dotglob=on
  shopt -s dotglob
  for file in "$dir"/*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base=${file##*/}
    if [ ! -f "$file" ] || [ ! -r "$file" ] || ! gate_slug_ok "$base"; then
      printf 'unrecognised\t%s\t\t\n' "$file"
      continue
    fi
    item=$(record_value "$file" item)
    if ! gate_item_id_ok "$item" || [ "$(record_value "$file" origin)" != "$origin" ] \
      || [ "$(record_value "$file" key)" != "$base" ]; then
      printf 'unrecognised\t%s\t\t\n' "$file"
      continue
    fi
    printf 'ok\t%s\t%s\t%s\n' "$file" "$base" "$item"
  done
  [ "$dotglob" = on ] || shopt -u dotglob
}

# Reads the item without ever deciding, on its own, that a failure means absence.
# The result lands in GATE_ITEM_SHOW and the verdict in the return code, so the
# caller raises any refusal from its own shell instead of inside a `$( )` where
# `fail` would only exit the subshell.
#   0 read           1 genuinely absent           2 could not be established
GATE_ITEM_SHOW=''
GATE_ITEM_ERROR=''

# tasks-axi answers NOT_FOUND both for an id absent from a readable store and for
# a store it could not open at all, so absence is only trusted once the store the
# active home is configured to read is itself a readable regular file.
gate_backlog_store() {
  local config="$FM_HOME/.tasks.toml" path=''
  if [ -e "$config" ]; then
    [ -f "$config" ] && [ -r "$config" ] || return 1
    # A `path` key the parser cannot read a value out of is a store this command
    # has not established, so it refuses rather than falling back to the default.
    path=$(awk '
      /^[[:space:]]*\[/ {
        section = $0
        sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
        sub(/[[:space:]]*\].*$/, "", section)
        next
      }
      section == "markdown" && /^[[:space:]]*path[[:space:]]*=/ {
        saw_path = 1
        value = $0
        sub(/^[^=]*=[[:space:]]*/, "", value)
        quote = substr(value, 1, 1)
        if (quote == "\"" || quote == "\047") {
          rest = substr(value, 2)
          close_at = index(rest, quote)
          if (close_at == 0) next
          value = substr(rest, 1, close_at - 1)
        } else {
          sub(/#.*$/, "", value)
          sub(/[[:space:]]+$/, "", value)
        }
        if (value != "") { printed = 1; print value; exit }
      }
      END { if (saw_path && !printed) exit 1 }
    ' "$config") || return 1
  fi
  # With no `path` key tasks-axi discovers its store against the working
  # directory this script runs it in rather than defaulting to a fixed one: it
  # reads backlog.md in that directory when one is there and data/backlog.md
  # otherwise. A guard naming a single path would answer about a file the tool
  # never opens, which reads as protection either way it is wrong: it would
  # refuse a genuine departure, or trust a not-found from a store nothing reads.
  if [ -z "$path" ]; then
    if [ -e "$FM_HOME/backlog.md" ] || [ -L "$FM_HOME/backlog.md" ]; then
      path="$FM_HOME/backlog.md"
    else
      path="$FM_HOME/data/backlog.md"
    fi
  fi
  case "$path" in
    /*) : ;;
    *) path="$FM_HOME/$path" ;;
  esac
  printf '%s\n' "$path"
}

gate_item_read() {  # <item-id>
  local out rc store shown_id
  GATE_ITEM_SHOW=''
  GATE_ITEM_ERROR=''
  if ! command -v tasks-axi >/dev/null 2>&1; then
    GATE_ITEM_ERROR='tasks-axi is not available in this home'
    return 2
  fi
  # `out=$(...)` under `set -e` exits the shell on a non-zero substitution before
  # the status can be read, which would end the command with no message at all.
  rc=0
  out=$( (cd "$FM_HOME" && tasks-axi show "$1" --full) 2>&1 ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    # An exit status of zero is not by itself a record for this id: tasks-axi
    # reads a flag-shaped argument as a flag and prints its usage successfully,
    # so the output has to name the id that was asked for. Exactly one pair of
    # surrounding quotes comes off, which is what the renderer puts around an id
    # that would otherwise read as a number or a boolean, so an id whose own
    # characters include a quote is compared as it is rather than normalised.
    shown_id=$(show_field "$out" id)
    shown_id=${shown_id#\"}
    shown_id=${shown_id%\"}
    if [ "$shown_id" != "$1" ]; then
      GATE_ITEM_ERROR="the backlog answered without naming $1, so no record for it was established"
      return 2
    fi
    GATE_ITEM_SHOW=$out
    return 0
  fi
  case "$out" in
    *'code: NOT_FOUND'*)
      store=''
      store=$(gate_backlog_store) || store=''
      if [ -z "$store" ]; then
        GATE_ITEM_ERROR="the backlog store configured in $FM_HOME/.tasks.toml could not be established, so a not-found reading cannot be trusted"
      elif [ -f "$store" ] && [ -r "$store" ]; then
        return 1
      else
        GATE_ITEM_ERROR="the configured backlog store $store is not a readable file, so a not-found reading cannot be trusted"
      fi
      return 2
      ;;
  esac
  GATE_ITEM_ERROR=$(printf '%s' "$out" | sed -n 's/^ *code: //p' | head -1)
  [ -n "$GATE_ITEM_ERROR" ] || GATE_ITEM_ERROR='unknown error'
  GATE_ITEM_ERROR="the backlog could not be read (tasks-axi $GATE_ITEM_ERROR)"
  return 2
}

# The settled definition of "the captain still owes an answer on this item".
# `kind` is deliberately absent: `tasks-axi update --kind` leaves these fields
# intact, and reading `kind` let a still-held item read as no longer captain-owned.
item_asserts_owed_decision() {  # <show-output>
  [ "$(show_field "$1" hold_kind)" = captain ] || return 1
  case "$(show_field "$1" hold_reason)" in
    ''|'"-"'|-) return 1 ;;
  esac
  [ "$(show_field "$1" state)" != "done" ] || return 1
  return 0
}

gate_answer_body() {  # <origin> <key> <decided-by> <answer>
  printf 'Answered through gate %s/%s.\nDecided by: %s\n\n%s\n' "$1" "$2" "$3" "$4"
}

# Clearing a staging file on the way to a refusal is best effort: the same
# condition that failed the write often fails the removal too, and under `set -e`
# that would end the command before the refusal it was meant to accompany.
discard_staging() {  # <staging-file>
  rm -f "$1" 2>/dev/null || true
}

drop_gate_link() {  # <link-file>
  rm -f "$1" || fail "could not remove the reconciled gate link $1"
}

command_gate_link() {
  local item=${1:-} origin=${2:-} key=${3:-} file rc linked
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  validate_slug item-id "$item"
  validate_gate_slug origin-id "$origin"
  validate_gate_slug decision-key "$key"
  file=$(gate_link_file "$origin" "$key")
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  # This command writes through tasks-axi in the active home, so a secondmate's
  # decision recorded here would sit in a home that does not own it.
  if [ -f "$STATE/$origin.meta" ] \
    && [ "$(meta_value "$STATE/$origin.meta" kind)" = secondmate ]; then
    fail "origin $origin is a secondmate; a captain decision it raises belongs in that secondmate's own home, not $FM_HOME"
  fi
  rc=0
  gate_item_read "$item" || rc=$?
  [ "$rc" -ne 2 ] || fail "captain-gated item $item could not be checked: $GATE_ITEM_ERROR"
  [ "$rc" -ne 1 ] || fail "captain-gated item $item is not in $FM_HOME/data/backlog.md"
  item_asserts_owed_decision "$GATE_ITEM_SHOW" \
    || fail "backlog item $item does not assert an owed captain decision"
  rc=0
  gate_link_state "$file" || rc=$?
  [ "$rc" -ne 2 ] \
    || fail "gate $origin/$key could not be checked: the link index at ${file%/*} could not be established"
  if [ "$rc" -eq 0 ]; then
    # Read through the one consumer that validates the whole pairing, so this
    # command never reports recorded what every other command would refuse.
    linked=$(linked_item_for "$origin" "$key" "$file")
    [ "$linked" = "$item" ] \
      || fail "gate $origin/$key is already linked to a different captain item"
    printf '%s\n' "$file"
    return 0
  fi
  mkdir -p "${file%/*}" || fail "could not create the gate link index for $origin"
  printf 'item=%s\norigin=%s\nkey=%s\n' "$item" "$origin" "$key" > "$STATE/.gate-link.$$" \
    || { discard_staging "$STATE/.gate-link.$$"; fail "could not stage the gate link for $origin/$key"; }
  mv "$STATE/.gate-link.$$" "$file" \
    || { discard_staging "$STATE/.gate-link.$$"; fail "could not record the gate link for $origin/$key"; }
  printf '%s\n' "$file"
}

linked_item_for() {  # <origin> <key> <link-file>
  local item
  [ -f "$3" ] || fail "gate $1/$2 has no recorded link at $3"
  [ -r "$3" ] || fail "gate link $3 could not be read"
  item=$(record_value "$3" item)
  gate_item_id_ok "$item" || fail "gate link $3 does not record a task-id shaped captain-gated item"
  [ "$(record_value "$3" origin)" = "$1" ] && [ "$(record_value "$3" key)" = "$2" ] \
    || fail "gate link $3 does not name the pairing it sits at"
  printf '%s\n' "$item"
}

command_gate_answered() {
  local origin=${1:-} key=${2:-} decided_by='' answer_file='' file item answer rc body note \
    item_body state
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answered-by) shift; decided_by=${1:-} ;;
      --answer-file) shift; answer_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    # A flag given last has already consumed the value shift, and shifting past
    # the end would end the command under `set -e` before its refusal printed.
    [ "$#" -gt 0 ] || break
    shift
  done
  validate_gate_slug origin-id "$origin"
  validate_gate_slug decision-key "$key"
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
  file=$(gate_link_file "$origin" "$key")
  rc=0
  gate_link_state "$file" || rc=$?
  [ "$rc" -ne 2 ] \
    || fail "gate $origin/$key could not be checked: the link index at ${file%/*} could not be established"
  if [ "$rc" -eq 1 ]; then
    printf 'gate-answered: %s/%s has no linked captain-gated item\n' "$origin" "$key"
    return 0
  fi
  item=$(linked_item_for "$origin" "$key" "$file")

  rc=0
  gate_item_read "$item" || rc=$?
  # A read that could not establish the item keeps the link, so cleanup keeps
  # refusing and a retry after repair still lands the write.
  [ "$rc" -ne 2 ] || fail "captain-gated item $item was not written: $GATE_ITEM_ERROR"
  if [ "$rc" -eq 1 ]; then
    drop_gate_link "$file"
    printf 'gate-answered: %s/%s answered by %s; %s is no longer in this backlog, nothing to reconcile\n' \
      "$origin" "$key" "$decided_by" "$item"
    return 0
  fi

  item_body=$(show_field "$GATE_ITEM_SHOW" body)
  # Every discriminator here has to be right about what else can match it, not
  # only about what it is meant to match. Four separate defects on this path were
  # each a correct description that was an incomplete specification: a note this
  # command writes that no arm named, a generic body pattern that also matched
  # that note, a key whose terminating period another key could continue, and an
  # arm placed where a predicate could stop it being consulted at all. So each
  # arm states its own boundary, and adding one means checking it against every
  # marker this command writes, against every key that shares a prefix with this
  # one, and against every state that can reach the code above it.
  #
  # `.` is a slug character, so a marker for `<key>` is accepted only where its
  # period ends the body or is followed by something that cannot continue a slug.
  # Without that, `scope` matches text written for `scope.v2`.
  #
  # This gate's own note on an item it found closed, which never owed a close.
  # It is read before the owed predicate rather than inside it, because `done`
  # leaves the hold fields alone and `reopen` restores the hold from them, so an
  # item this gate already noted can assert an owed decision again and take the
  # write path over the answer whoever settled it wrote.
  case "$item_body" in
    *"Also answered through gate $origin/$key."|*"Also answered through gate $origin/$key."[!A-Za-z0-9._-]*)
      drop_gate_link "$file"
      printf 'gate-answered: %s/%s already recorded on %s; link cleared\n' "$origin" "$key" "$item"
      return 0
      ;;
  esac

  # An item that no longer asserts an owed decision was settled by someone else,
  # so this gate never writes its answer over it: overwriting would displace
  # whoever actually decided and label the record with this caller.
  if ! item_asserts_owed_decision "$GATE_ITEM_SHOW"; then
    state=$(show_field "$GATE_ITEM_SHOW" state)
    case "$item_body" in
      *"through gate $origin/$key."|*"through gate $origin/$key."[!A-Za-z0-9._-]*)
        # The answer landed but the close did not, so the retry finishes the
        # sequence rather than clearing the link that is still holding it open.
        if [ "$state" != "done" ]; then
          tasks_axi "done" "$item" >/dev/null \
            || fail "could not close $item on the gate answer it already records"
          drop_gate_link "$file"
          printf 'gate-answered: %s/%s already recorded on %s -> %s closed; link cleared\n' \
            "$origin" "$key" "$item" "$item"
          return 0
        fi
        drop_gate_link "$file"
        printf 'gate-answered: %s/%s already recorded on %s; link cleared\n' "$origin" "$key" "$item"
        return 0
        ;;
    esac
    # A closed item and a still-open one do not share a body here. `done --note`
    # backfills a note without moving an item that is already done, and closes
    # one that is not. Every defect on this path so far came from a guard widened
    # to admit a new state while the body behind it stayed as written for the old
    # one, so these two stay apart even though one predicate brings both here.
    if [ "$state" = "done" ]; then
      note=$(printf 'Also answered through gate %s/%s. Decided by: %s.' "$origin" "$key" "$decided_by")
      tasks_axi "done" "$item" --note "$note" >/dev/null \
        || fail "could not note this gate's answer on closed $item"
      drop_gate_link "$file"
      printf 'gate-answered: %s/%s answered by %s; %s was already closed, this gate noted on it\n' \
        "$origin" "$key" "$decided_by" "$item"
      return 0
    fi
    # Whoever settled this left the item open, and this mechanism does not own
    # the lifecycle of the record it did not write. tasks-axi appends a note only
    # by closing an item, and closing one to reopen it rewrites the row's since
    # date, so the cross-reference would cost a false backlog row. The item
    # already carries the answer its own settler wrote, so a gap is not a lie.
    drop_gate_link "$file"
    printf 'gate-answered: %s/%s answered by %s; %s was settled without this gate and left open, nothing written to it\n' \
      "$origin" "$key" "$decided_by" "$item"
    return 0
  fi

  # The answer body lands before the hold is released, so a failure part way
  # through never leaves the item unheld and open, which by the owed predicate
  # would stop it claiming a decision is owed while none was recorded.
  body=$(gate_answer_body "$origin" "$key" "$decided_by" "$answer")
  printf '%s' "$body" > "$STATE/.gate-answer.$$" \
    || { discard_staging "$STATE/.gate-answer.$$"; fail "could not stage the gate answer for $origin/$key"; }
  tasks_axi update "$item" --body-file "$STATE/.gate-answer.$$" --archive-body >/dev/null \
    || { discard_staging "$STATE/.gate-answer.$$"; fail "could not record the gate answer on $item"; }
  rm -f "$STATE/.gate-answer.$$"
  if [ "$(show_field "$GATE_ITEM_SHOW" held)" = yes ]; then
    tasks_axi unhold "$item" >/dev/null || fail "could not release the captain hold on $item"
  fi
  tasks_axi "done" "$item" >/dev/null || fail "could not close answered captain item $item"
  # The link is removed only after the item write landed, so a surviving link
  # always means the write did not.
  drop_gate_link "$file"
  printf 'gate-answered: %s/%s answered by %s -> %s closed\n' "$origin" "$key" "$decided_by" "$item"
}

command_gate_not_raised() {
  local origin=${1:-} key=${2:-} file item rc
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  validate_gate_slug origin-id "$origin"
  validate_gate_slug decision-key "$key"
  file=$(gate_link_file "$origin" "$key")
  rc=0
  gate_link_state "$file" || rc=$?
  [ "$rc" -ne 2 ] \
    || fail "gate $origin/$key could not be checked: the link index at ${file%/*} could not be established"
  if [ "$rc" -eq 1 ]; then
    printf 'gate-not-raised: %s/%s has no linked captain-gated item\n' "$origin" "$key"
    return 0
  fi
  item=$(linked_item_for "$origin" "$key" "$file")
  # Nothing is written anywhere: this gate never asked the question, so the item
  # keeps whatever it already says and stays captain-owned.
  drop_gate_link "$file"
  printf 'gate-not-raised: %s/%s never raised the question; %s left as it stands\n' \
    "$origin" "$key" "$item"
}

command_gate_status() {
  local origin=${1:-} verdict file key item records rc
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_gate_slug origin-id "$origin"
  rc=0
  gate_index_dir_state "$DATA/gate-links/$origin" || rc=$?
  [ "$rc" -ne 2 ] \
    || fail "the link index at $DATA/gate-links/$origin could not be established"
  # The reader's own exit status is read here rather than inside the here-doc
  # substitution, where a failure would have read as an empty index.
  records=$(origin_gate_records "$origin") \
    || fail "the captain-gated link index for origin $origin could not be read"
  while IFS=$'\t' read -r verdict file key item; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = ok ]; then
      printf '%s\tlinked\t%s\n' "$key" "$item"
    else
      printf '%s\tunrecognised\t%s\n' "${file##*/}" "$file"
    fi
  done <<EOF
$records
EOF
}

# Reads only the index. It never looks at the linked item and never calls
# tasks-axi, which is what makes cleanup independent of the backlog backend and
# makes every way an item can depart irrelevant here rather than classified.
command_gate_verify() {
  local origin=${1:-} verdict file key item linked='' unrecognised='' problems='' records
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_gate_slug origin-id "$origin"
  records=$(origin_gate_records "$origin") \
    || fail "the captain-gated link index for origin $origin could not be read"
  while IFS=$'\t' read -r verdict file key item; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = ok ]; then
      linked="${linked}${linked:+ }$key ($file)"
    else
      unrecognised="${unrecognised}${unrecognised:+ }$file"
    fi
  done <<EOF
$records
EOF
  [ -z "$linked" ] || problems="captain-gated links never reconciled: $linked"
  [ -z "$unrecognised" ] \
    || problems="${problems}${problems:+; }unrecognised captain-gated link records: $unrecognised"
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
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
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
    previous=$(meta_value "$meta" decision_keys)
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
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
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
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
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
  gate-answered) shift; command_gate_answered "$@" ;;
  gate-not-raised) shift; command_gate_not_raised "$@" ;;
  gate-status) shift; command_gate_status "$@" ;;
  gate-verify) shift; command_gate_verify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
