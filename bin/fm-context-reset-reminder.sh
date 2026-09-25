#!/usr/bin/env bash
# Claude Stop hook that suggests resetting a long-running primary session once,
# when its context grows past a threshold. Durable records rather than
# conversation memory are authoritative, so a reset only returns the session to
# its fixed startup cost; the stow skill's "Session reset" section owns the
# procedure this reminder points at.
#
# Usage: fm-context-reset-reminder.sh   (the Claude Stop payload arrives on stdin)
#
# Measure: the context size is the latest main-thread assistant call's input
# tokens (input_tokens + cache_read_input_tokens + cache_creation_input_tokens)
# read from the transcript the payload's transcript_path names. That is the
# harness's own count, so transcript bytes, which vary widely per token, are
# never used as a proxy.
#
# Once: the reminder fires on the Stop that ends the turn crossing the
# threshold, that is, when the last call before this turn's prompt was below
# FM_CONTEXT_RESET_TOKENS (default 250000) and the latest call is at or above
# it. The transcript is the only state: /clear opens a fresh transcript and
# compaction drops the count, so either re-arms the reminder without a marker.
# The transcript is read backwards and only as far as this turn's prompt, so
# the cost does not grow with the session.
#
# Channel: a JSON systemMessage on stdout, shown to the operator, because only
# the operator can run /clear. The turn is never blocked.
#
# There is deliberately no PreCompact hook: a compacted session already re-reads
# its digest through the SessionStart compact source (docs/sessionstart-nudge.md),
# and this reminder exists so a reset happens before auto-compaction does.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
THRESHOLD=${FM_CONTEXT_RESET_TOKENS:-250000}
case "$THRESHOLD" in ''|*[!0-9]*|0) THRESHOLD=250000 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null || true)
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

reverse_lines() {
  if command -v tac >/dev/null 2>&1; then
    tac "$1"
  else
    tail -r "$1"
  fi
}
command -v tac >/dev/null 2>&1 || tail -r /dev/null >/dev/null 2>&1 || exit 0

# A prompt is a main-thread user entry that is neither injected metadata nor a
# tool result; tool results arrive as user entries in the middle of a turn.
TOKENS=$(reverse_lines "$TRANSCRIPT" 2>/dev/null | jq -Rn --argjson threshold "$THRESHOLD" '
  def usage_tokens:
    [.message.usage | .input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens | numbers] | add // 0;
  def is_prompt:
    .type == "user" and .isMeta != true
    and ([.message.content | if type == "array" then .[] else empty end | select(type == "object" and .type == "tool_result")] | length) == 0;
  first(
    foreach ((inputs | fromjson? | select(type == "object" and .isSidechain != true)), null) as $e
      ({latest: null, in_turn_prompt_seen: false, result: null};
       if $e == null then .result = {before: 0, latest: (.latest // 0)}
       elif $e.type == "assistant" and ($e.message.usage | type) == "object" then
         if .latest == null then .latest = ($e | usage_tokens)
         elif .in_turn_prompt_seen then .result = {before: ($e | usage_tokens), latest: .latest}
         else . end
       elif .latest != null and ($e | is_prompt) then .in_turn_prompt_seen = true
       else . end;
       .result // empty)
  )
  | select(.before < $threshold and .latest >= $threshold)
  | .latest
' 2>/dev/null || true)
[ -n "$TOKENS" ] || exit 0

jq -cn --arg tokens "$((TOKENS / 1000))" '{systemMessage: ("Firstmate: this session has reached about \($tokens)k tokens of context. Resetting is safe because durable records, not this conversation, carry the work: run /stow, then /clear once it reports the session is safe to reset.")}'
exit 0
