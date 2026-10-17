#!/usr/bin/env bash
# Claude Stop hook that keeps a long-running primary session's context low by
# resetting it once it grows past a threshold. Durable records rather than
# conversation memory are authoritative, so a reset only returns the session to
# its fixed startup cost; the stow skill's "Session reset" section owns the
# procedure this hook drives.
#
# Usage:
#   fm-context-reset-reminder.sh                    Stop hook; the Claude Stop payload arrives on stdin
#   fm-context-reset-reminder.sh record reset-safe  a stow pass declared this session safe to reset
#   fm-context-reset-reminder.sh record curated     a full stow curation pass completed
#   fm-context-reset-reminder.sh deliver <token> <backend> <target> <text>
#                                                   the detached typist the hook launches
#
# Measure: the context size is the latest main-thread assistant call's input
# tokens (input_tokens + cache_read_input_tokens + cache_creation_input_tokens)
# read from the transcript the payload's transcript_path names. That is the
# harness's own count, so transcript bytes, which vary widely per token, are
# never used as a proxy. The threshold is FM_CONTEXT_RESET_TOKENS (default
# 150000). Synthetic placeholder entries (model "<synthetic>" or zero input
# usage) are not API calls, so they never count as a measurement. The
# transcript is read backwards and only as far as this turn's prompt, so the
# cost does not grow with the session.
#
# Automatic reset, in the main primary home only (FM_CONTEXT_RESET_AUTO=0 turns
# it off): every Stop at or past the threshold advances one record,
# state/.context-reset, kept per transcript, by the first rule that applies:
#   1. A reset-safe record written during the turn that just ended means that
#      turn was a stow pass that reported the session safe, so the typist types
#      /clear.
#   2. When the turn that just ended was the stow the typist typed and it
#      recorded no reset-safe verdict, the pass declined: the hook says so once
#      through a systemMessage and makes no further attempt in this transcript.
#   3. When the turn's final message asks a question (a "?" outside a URL), the
#      operator owes an answer, so the attempt waits for a later Stop.
#   4. Otherwise the typist types `/stow light`, or `/stow` when the last full
#      curation pass recorded here is absent or FM_STOW_CURATE_SECS (default
#      86400) old.
# The typist runs detached, so the turn is never held. It types only into the
# pane this Claude session runs in (bin/fm-supervisor-target-lib.sh discovery),
# and only after two consecutive reads FM_CONTEXT_RESET_SETTLE_SECS (default 3)
# apart show that pane idle: no turn running and a composer proven empty, which
# a dialog never is. A later turn supersedes a typist still waiting, because its
# verdict was formed before that turn. Idle that does not arrive within
# FM_CONTEXT_RESET_WAIT_SECS (default 60), or a submit the backend cannot
# confirm, leaves the attempt for the next Stop. Typing /clear rather than
# exiting keeps the session lock and live supervision with the same process,
# exactly as a clear by hand does.
#
# Reminder: with automation off, in a secondmate home, or where no tmux or Herdr
# pane can be found, the hook instead suggests the reset once through a
# systemMessage, on the Stop that ends the turn crossing the threshold, that is,
# when the last call before this turn's prompt was below the threshold and the
# latest call is at or above it.
#
# The transcript is the only per-session key: /clear opens a fresh transcript
# and compaction drops the count, so either re-arms both paths. There is
# deliberately no PreCompact hook: a compacted session already re-reads its
# digest through the SessionStart compact source (docs/sessionstart-nudge.md),
# and this hook exists so a reset happens before auto-compaction does.
#
# Silent no-op outside a genuine primary home, for a foreign-host duplicate
# payload, without jq or a line-reversing tool (tac or tail -r), and on any
# unreadable payload or transcript.
set -u

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  esac
fi

FM_CONTEXT_RESET_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

fm_context_reset_number() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

fm_context_reset_record_path() { printf '%s/.context-reset' "$STATE"; }
fm_context_reset_safe_path() { printf '%s/.context-reset-safe' "$STATE"; }
fm_context_reset_curated_path() { printf '%s/.stow-curated' "$STATE"; }

# One key=value per line; values never hold a newline.
fm_context_reset_get() {  # <key>
  local line
  while IFS= read -r line; do
    case "$line" in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done 2>/dev/null < "$(fm_context_reset_record_path)"
  return 1
}

fm_context_reset_put() {  # <key=value>...
  local path tmp
  path=$(fm_context_reset_record_path)
  tmp=$(mktemp "$path.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$@" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_context_reset_epoch_in() {  # <file>
  local value=''
  IFS= read -r value 2>/dev/null < "$1" || true
  case "$value" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$value" ;; esac
}

fm_context_reset_stow_command() {
  local curated age
  curated=$(fm_context_reset_epoch_in "$(fm_context_reset_curated_path)")
  age=$(fm_context_reset_number "${FM_STOW_CURATE_SECS:-}" 86400)
  if [ "$curated" -gt 0 ] && [ $(( $(date +%s) - curated )) -lt "$age" ]; then
    printf '/stow light'
  else
    printf '/stow'
  fi
}

fm_context_reset_message() {  # <text>
  jq -cn --arg m "Firstmate: $1" '{systemMessage: $m}'
}

fm_context_reset_reverse_lines() {
  if command -v tac >/dev/null 2>&1; then
    tac "$1"
  else
    tail -r "$1"
  fi
}

# Prints "<before> <latest> <prompt-epoch> <question>": the context before and
# at the end of this turn, when this turn's prompt was recorded (0 when the
# transcript carries no readable time), and 1 when the turn's final message
# asks a question.
# A prompt is a main-thread user entry that is neither injected metadata nor a
# tool result; tool results arrive as user entries in the middle of a turn.
fm_context_reset_measure() {  # <transcript>
  fm_context_reset_reverse_lines "$1" 2>/dev/null | jq -Rrn '
    def usage_tokens:
      [.message.usage | .input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens | numbers] | add // 0;
    def is_measurement:
      .type == "assistant" and (.message.usage | type) == "object"
      and .message.model != "<synthetic>" and usage_tokens > 0;
    def is_prompt:
      .type == "user" and .isMeta != true
      and ([.message.content | if type == "array" then .[] else empty end | select(type == "object" and .type == "tool_result")] | length) == 0;
    def text_of:
      [.message.content | if type == "string" then . elif type == "array" then (.[] | select(type == "object" and .type == "text") | .text | strings) else empty end] | join("\n");
    def epoch_of:
      (.timestamp | strings | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) // 0;
    def summary($before):
      {before: $before, latest: (.latest // $before), prompt_at, final_text};
    first(
      foreach ((inputs | fromjson? | select(type == "object" and .isSidechain != true)), null) as $e
        ({latest: null, final_text: null, prompt_at: 0, prompt_seen: false, result: null};
         if $e == null then .result = summary(0)
         elif .prompt_seen then
           if ($e | is_measurement) then .result = summary($e | usage_tokens) else . end
         elif ($e | is_measurement) then
           (if .latest == null then .latest = ($e | usage_tokens) else . end)
           | (if .final_text == null and ($e | text_of) != "" then .final_text = ($e | text_of) else . end)
         elif ($e | is_prompt) then .prompt_seen = true | .prompt_at = ($e | epoch_of)
         else . end;
         .result // empty)
    )
    | "\(.before) \(.latest) \(.prompt_at | floor) \(if (.final_text // "") | gsub("https?://[^[:space:]]+"; "") | test("\\?") then 1 else 0 end)"
  ' 2>/dev/null
}

# The typist is detached so the Stop hook returns at once; its own session
# keeps Claude from waiting on it or signalling it with the hook.
fm_context_reset_launch() {  # <token> <backend> <target> <text>
  if command -v setsid >/dev/null 2>&1; then
    setsid "$FM_CONTEXT_RESET_SELF" deliver "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup "$FM_CONTEXT_RESET_SELF" deliver "$@" </dev/null >/dev/null 2>&1 &
  fi
}

fm_context_reset_start_typist() {  # <transcript> <turn> <backend> <target> <text>
  local token
  token="$(date +%s)-$$-$RANDOM"
  fm_context_reset_put "transcript=$1" phase=typing "turn=$2" "token=$token" "text=$5" "at=$(date +%s)" || return 0
  fm_context_reset_launch "$token" "$3" "$4" "$5"
}

# Automatic path for a Stop at or past the threshold. Returns 1 when no pane
# can be typed into, so the caller falls back to the reminder.
fm_context_reset_auto() {  # <transcript> <tokens> <prompt-at> <question>
  local transcript=$1 tokens=$2 prompt_at=$3 question=$4 backend target phase turn safe_at
  case "${FM_CONTEXT_RESET_AUTO:-1}" in 0|off|false|no) return 1 ;; esac
  fm_root_is_secondmate_home "$FM_ROOT" && return 1
  target=$(discover_supervisor_target) || return 1
  backend=$(discover_supervisor_backend) || return 1
  case "$backend" in tmux|herdr) ;; *) return 1 ;; esac

  phase=
  if [ "$(fm_context_reset_get transcript)" = "$transcript" ]; then
    phase=$(fm_context_reset_get phase)
    turn=$(fm_context_reset_get turn)
  fi
  [ "$phase" = declined ] && return 0
  [ "$phase" = typing ] && [ "$prompt_at" -gt 0 ] && [ "$turn" = "$prompt_at" ] && return 0

  safe_at=$(fm_context_reset_epoch_in "$(fm_context_reset_safe_path)")
  if [ "$prompt_at" -gt 0 ] && [ "$safe_at" -ge "$prompt_at" ]; then
    fm_context_reset_start_typist "$transcript" "$prompt_at" "$backend" "$target" /clear
    return 0
  fi
  if [ "$phase" = stow ]; then
    fm_context_reset_put "transcript=$transcript" phase=declined "at=$(date +%s)"
    fm_context_reset_message "the automatic reset stopped at about $((tokens / 1000))k tokens because the stow pass did not report this session safe to reset. Settle what it named, then run /stow light and /clear by hand."
    return 0
  fi
  if [ "$question" = 1 ]; then
    fm_context_reset_put "transcript=$transcript" phase=armed "at=$(date +%s)"
    return 0
  fi
  fm_context_reset_start_typist "$transcript" "$prompt_at" "$backend" "$target" "$(fm_context_reset_stow_command)"
}

fm_context_reset_stop_hook() {
  local payload transcript measured before latest prompt_at question threshold
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  fm_hook_payload_is_foreign_host "$payload" && return 0
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  command -v tac >/dev/null 2>&1 || tail -r /dev/null >/dev/null 2>&1 || return 0

  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty | strings' 2>/dev/null || true)
  [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || return 0
  measured=$(fm_context_reset_measure "$transcript") || return 0
  read -r before latest prompt_at question <<<"$measured"
  case "$before$latest$prompt_at$question" in ''|*[!0-9]*) return 0 ;; esac
  threshold=$(fm_context_reset_number "${FM_CONTEXT_RESET_TOKENS:-}" 150000)

  if [ "$latest" -lt "$threshold" ]; then
    [ "$(fm_context_reset_get transcript)" = "$transcript" ] && rm -f "$(fm_context_reset_record_path)"
    return 0
  fi
  fm_context_reset_auto "$transcript" "$latest" "$prompt_at" "$question" && return 0
  [ "$before" -lt "$threshold" ] || return 0
  fm_context_reset_message "this session has reached about $((latest / 1000))k tokens of context. Resetting is safe because durable records, not this conversation, carry the work: run $(fm_context_reset_stow_command), then /clear once it reports the session is safe to reset."
}

fm_context_reset_pane_idle() {  # <backend> <target>
  fm_backend_target_exists "$1" "$2" || return 1
  supervisor_pane_is_busy "$2" "$1" claude && return 1
  [ "$(fm_backend_composer_state "$1" "$2" 2>/dev/null)" = empty ]
}

# A typist acts and reports only while its token is still the record's own, so
# one superseded by a later turn neither types nor overwrites the newer record.
fm_context_reset_deliver() {  # <token> <backend> <target> <text>
  local token=$1 backend=$2 target=$3 text=$4 wait settle deadline idle=0 verdict next
  wait=$(fm_context_reset_number "${FM_CONTEXT_RESET_WAIT_SECS:-}" 60)
  settle=$(fm_context_reset_number "${FM_CONTEXT_RESET_SETTLE_SECS:-}" 3)
  deadline=$(( $(date +%s) + wait ))
  while [ "$idle" -lt 2 ]; do
    [ "$(fm_context_reset_get token)" = "$token" ] || return 0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fm_context_reset_put "transcript=$(fm_context_reset_get transcript)" phase=armed "at=$(date +%s)" "note=pane not idle within ${wait}s for $text"
      return 0
    fi
    if fm_context_reset_pane_idle "$backend" "$target"; then
      idle=$((idle + 1))
    else
      idle=0
    fi
    [ "$idle" -ge 2 ] || sleep "$settle"
  done
  [ "$(fm_context_reset_get token)" = "$token" ] || return 0
  # Every text typed here is a slash command, whose popup needs the longer
  # settle before the typed payload reads back.
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$text" 3 0.5 1.2 "" claude 2>/dev/null)
  [ "$(fm_context_reset_get token)" = "$token" ] || return 0
  if [ "$verdict" != empty ]; then
    fm_context_reset_put "transcript=$(fm_context_reset_get transcript)" phase=armed "at=$(date +%s)" "note=submit of $text unconfirmed (${verdict:-no verdict})"
    return 0
  fi
  case "$text" in /clear) next=cleared ;; *) next=stow ;; esac
  fm_context_reset_put "transcript=$(fm_context_reset_get transcript)" "phase=$next" "at=$(date +%s)"
}

fm_context_reset_record() {  # reset-safe|curated
  local path
  case "${1:-}" in
    reset-safe) path=$(fm_context_reset_safe_path) ;;
    curated) path=$(fm_context_reset_curated_path) ;;
    *) echo "usage: fm-context-reset-reminder.sh record reset-safe|curated" >&2; return 2 ;;
  esac
  [ -d "$STATE" ] || { echo "fm-context-reset-reminder: no state directory at $STATE" >&2; return 1; }
  date +%s > "$path"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    record) fm_context_reset_record "${2:-}"; exit $? ;;
    deliver)
      [ "$#" -eq 5 ] || exit 2
      # shellcheck source=bin/fm-backend.sh
      . "$SCRIPT_DIR/fm-backend.sh"
      fm_context_reset_deliver "$2" "$3" "$4" "$5"
      exit 0
      ;;
    '') fm_context_reset_stop_hook; exit 0 ;;
    *) echo "usage: fm-context-reset-reminder.sh [record reset-safe|curated]" >&2; exit 2 ;;
  esac
fi
