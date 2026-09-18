# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# One rendered field out of `tasks-axi show --full`, which indents every field
# by two spaces.
fm_backlog_show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# Reads a backlog item without ever deciding, on its own, that a failure means
# absence. The result lands in FM_BACKLOG_ITEM_SHOW and the verdict in the return
# code, so a caller raises any refusal from its own shell instead of inside a
# `$( )` where a fatal helper would only exit the subshell.
#   0 read     1 genuinely absent     2 could not be established     3 no tool
# 3 is separate because a home without tasks-axi is a supported fallback state
# here, not an unknown answer, and a caller may want to continue rather than stop.
FM_BACKLOG_ITEM_SHOW=''
FM_BACKLOG_ITEM_ERROR=''

# tasks-axi answers NOT_FOUND both for an id absent from a readable store and for
# a store it could not open at all, so absence is only trusted once the store the
# active home is configured to read is itself a readable regular file.
fm_backlog_store() {
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

fm_backlog_item_read() {  # <item-id>
  local out rc store shown_id
  FM_BACKLOG_ITEM_SHOW=''
  FM_BACKLOG_ITEM_ERROR=''
  if ! command -v tasks-axi >/dev/null 2>&1; then
    FM_BACKLOG_ITEM_ERROR='tasks-axi is not available in this home'
    return 3
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
    shown_id=$(fm_backlog_show_field "$out" id)
    shown_id=${shown_id#\"}
    shown_id=${shown_id%\"}
    if [ "$shown_id" != "$1" ]; then
      FM_BACKLOG_ITEM_ERROR="the backlog answered without naming $1, so no record for it was established"
      return 2
    fi
    # Read by the sourcing script, which is where the verdict is acted on.
    # shellcheck disable=SC2034
    FM_BACKLOG_ITEM_SHOW=$out
    return 0
  fi
  case "$out" in
    *'code: NOT_FOUND'*)
      store=''
      store=$(fm_backlog_store) || store=''
      if [ -z "$store" ]; then
        FM_BACKLOG_ITEM_ERROR="the backlog store configured in $FM_HOME/.tasks.toml could not be established, so a not-found reading cannot be trusted"
      elif [ -f "$store" ] && [ -r "$store" ]; then
        return 1
      else
        FM_BACKLOG_ITEM_ERROR="the configured backlog store $store is not a readable file, so a not-found reading cannot be trusted"
      fi
      return 2
      ;;
  esac
  FM_BACKLOG_ITEM_ERROR=$(printf '%s' "$out" | sed -n 's/^ *code: //p' | head -1)
  [ -n "$FM_BACKLOG_ITEM_ERROR" ] || FM_BACKLOG_ITEM_ERROR='unknown error'
  FM_BACKLOG_ITEM_ERROR="the backlog could not be read (tasks-axi $FM_BACKLOG_ITEM_ERROR)"
  return 2
}
