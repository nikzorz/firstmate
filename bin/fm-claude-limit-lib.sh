#!/usr/bin/env bash
# fm-claude-limit-lib.sh - the ONE owner of Claude Code's usage-limit stall: the
# pane signature that identifies it, and the quota read that decides whether the
# account window has actually reset.
#
# WHY THIS EXISTS (incident 2026-07-29): three of four live crewmates exhausted
# the account usage limit mid-turn and stopped on Claude Code's interactive
# choice prompt ("Stop and wait for limit to reset" / "Upgrade your plan"). That
# prompt waits for a human indefinitely, including long after the window clears,
# and the pane it leaves behind is idle with no error - indistinguishable from a
# crew legitimately between turns. They sat for roughly 8.7 hours while the
# five-hour window had long since reset. Recovery was one Escape plus one steer.
#
# SCOPE: this is claude-specific on purpose. No other verified harness has been
# observed presenting a blocking usage-limit prompt, and `harness-adapters` is
# where per-harness knowledge belongs, so nothing here generalises to a "any
# harness dialog" abstraction. Callers gate on the recorded `harness=claude`.
#
# CONSUMERS: bin/fm-crew-state.sh (turns a match into the distinct
# `usage-limited` current state, ahead of its no-mistakes run lookup, because a
# pane parked on this prompt is not working no matter what the run says) and
# bin/fm-limit-resume.sh (re-proves the match immediately before it sends a key).
# bin/fm-classify-lib.sh owns the shared triage vocabulary over that state.
#
# EVERYTHING HERE FAILS CLOSED. An unreadable pane, an uncertain match, a
# missing tool, or unparseable quota output reports "no match" or "unknown"
# rather than a guess, because a false positive sends keystrokes into a live
# crewmate's pane - worse than the stall it would fix.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# --- dialog signature -------------------------------------------------------
#
# Three exact, ordered anchors from the observed prompt:
#
#      What do you want to do?
#
#    ❯ 1. Stop and wait for limit to reset
#      2. Upgrade your plan
#
#      Enter to confirm · Esc to cancel
#
# Deliberately NOT a loose "limit" substring: a crewmate writing a commit
# message about rate limits, or printing a file that discusses them, must never
# trigger this. The option anchor matches the whole option LABEL on its own
# numbered row, so prose that merely contains the words cannot satisfy it.
# The leading `[^0-9]*` absorbs indentation and whatever selection glyph the TUI
# draws (`❯`, `>`, `*`) without a multibyte bracket expression, which would
# degrade into individual bytes under LC_ALL=C.
FM_CLAUDE_LIMIT_PROMPT_RE_DEFAULT='^[[:space:]]*What do you want to do\?[[:space:]]*$'
FM_CLAUDE_LIMIT_OPTION_RE_DEFAULT='^[^0-9]*[0-9]+\.[[:space:]]+Stop and wait for limit to reset[[:space:]]*$'
FM_CLAUDE_LIMIT_FOOTER_RE_DEFAULT='^[[:space:]]*Enter to confirm[^[:alnum:]]+Esc to cancel[[:space:]]*$'

# How many non-blank lines may follow the footer and still count as "this prompt
# owns the bottom of the pane". The live prompt REPLACES the composer, so
# nothing is drawn under it; ordinary displayed content always has the bordered
# composer box (three rows) plus usually a hint row below it. A slack of 2
# therefore admits the real prompt and rejects the same text merely being
# printed inside a working pane - the one false-positive shape that the three
# text anchors alone cannot separate. Raising it weakens that separation.
FM_CLAUDE_LIMIT_FOOTER_TAIL_SLACK_DEFAULT=2

# Effective account headroom (percent remaining) at or above which the window
# counts as reset. A small margin rather than "anything above zero": resuming
# into 1% headroom would re-exhaust within seconds and re-present the prompt, so
# the margin is what keeps recovery from oscillating.
FM_CLAUDE_LIMIT_RESET_MIN_REMAINING_DEFAULT=5

# Seconds allowed for the bounded quota read.
FM_CLAUDE_LIMIT_QUOTA_TIMEOUT_DEFAULT=15

# Pane tail (lines) a caller should capture for the match. Large enough to hold
# the whole prompt plus the message above it, small enough to stay cheap.
# shellcheck disable=SC2034 # Read by the capturing callers (fm-crew-state.sh, fm-limit-resume.sh), not this lib.
FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT=40

# fm_claude_limit_dialog_match: 0 when the text on stdin is a pane parked on the
# usage-limit prompt, 1 otherwise (including empty or unreadable input).
# Requires all three anchors, in order, with the footer owning the bottom of the
# pane. Pure text classification: no pane, backend, or tool access.
fm_claude_limit_dialog_match() {  # stdin: plain pane capture
  local text nonblank total slack prompt option footer
  IFS= read -r -d '' text || true
  [ -n "$text" ] || return 1
  text=$(printf '%s\n' "$text" | fm_composer_strip_ansi)
  text=$(fm_composer_ws_normalize "$text")
  nonblank=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$') || return 1
  [ -n "$nonblank" ] || return 1
  total=$(printf '%s\n' "$nonblank" | grep -c '')
  prompt=$(printf '%s\n' "$nonblank" \
    | grep -nE "${FM_CLAUDE_LIMIT_PROMPT_RE:-$FM_CLAUDE_LIMIT_PROMPT_RE_DEFAULT}" | tail -1 | cut -d: -f1)
  option=$(printf '%s\n' "$nonblank" \
    | grep -nE "${FM_CLAUDE_LIMIT_OPTION_RE:-$FM_CLAUDE_LIMIT_OPTION_RE_DEFAULT}" | tail -1 | cut -d: -f1)
  footer=$(printf '%s\n' "$nonblank" \
    | grep -nE "${FM_CLAUDE_LIMIT_FOOTER_RE:-$FM_CLAUDE_LIMIT_FOOTER_RE_DEFAULT}" | tail -1 | cut -d: -f1)
  [ -n "$prompt" ] && [ -n "$option" ] && [ -n "$footer" ] || return 1
  slack=${FM_CLAUDE_LIMIT_FOOTER_TAIL_SLACK:-$FM_CLAUDE_LIMIT_FOOTER_TAIL_SLACK_DEFAULT}
  case "$slack" in ''|*[!0-9]*) slack=$FM_CLAUDE_LIMIT_FOOTER_TAIL_SLACK_DEFAULT ;; esac
  [ "$prompt" -lt "$option" ] || return 1
  [ "$option" -lt "$footer" ] || return 1
  [ "$(( total - footer ))" -le "$slack" ] || return 1
  return 0
}

# --- quota window -----------------------------------------------------------

# fm_claude_limit_quota_json: bounded, read-only `quota-axi` output, or empty.
# Never fails the caller; an absent tool or a timeout simply yields no output,
# which the reader below turns into `unknown`.
fm_claude_limit_quota_json() {
  local timeout_s=${FM_CLAUDE_LIMIT_QUOTA_TIMEOUT:-$FM_CLAUDE_LIMIT_QUOTA_TIMEOUT_DEFAULT}
  case "$timeout_s" in ''|*[!0-9]*) timeout_s=$FM_CLAUDE_LIMIT_QUOTA_TIMEOUT_DEFAULT ;; esac
  command -v quota-axi >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" quota-axi --provider claude --json 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" quota-axi --provider claude --json 2>/dev/null || true
  else
    quota-axi --provider claude --json 2>/dev/null || true
  fi
  return 0
}

# fm_claude_limit_window_state: `reset`, `exhausted`, or `unknown`.
#
# `quota-axi` is firstmate's authority on quota windows (AGENTS.md section 4),
# so this asks it rather than inferring a reset from elapsed time. It reads the
# provider's own bounded effective availability for all models, which already
# accounts for a model window sitting inside a shorter account window, instead
# of picking one window and guessing which one bound the account.
#
# Fail-closed inputs, all of which report `unknown`: no `quota-axi`, no `jq`, a
# timed-out or unparseable read, quota data the provider itself marks stale, or
# a semantics/availability block the provider does not mark `known`. `unknown`
# never authorizes recovery, and never counts as a settled external wait either
# - it is a condition to surface.
fm_claude_limit_window_state() {  # -> reset|exhausted|unknown
  local min json remaining
  min=${FM_CLAUDE_LIMIT_RESET_MIN_REMAINING:-$FM_CLAUDE_LIMIT_RESET_MIN_REMAINING_DEFAULT}
  case "$min" in ''|*[!0-9]*) min=$FM_CLAUDE_LIMIT_RESET_MIN_REMAINING_DEFAULT ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  json=$(fm_claude_limit_quota_json)
  [ -n "$json" ] || { printf 'unknown'; return 0; }
  # Every test is an explicit equality rather than jq's `//` alternative
  # operator: `//` treats a literal `false` the same as a missing field, so
  # `(.state.stale // true) == false` would have discarded the good case where
  # the provider explicitly reports `"stale": false`. Written this way, an absent
  # field compares against null, fails the test, and correctly yields `unknown`.
  remaining=$(printf '%s' "$json" | jq -r '
      (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
      | select(.state.stale == false)
      | (.quotaSemantics // {})
      | select(.status == "known")
      | (.effectiveAvailability // [])
      | map(select(.scope == "all_models"
                   and (.status == "known")
                   and (.effectivePercentRemaining != null)))
      | .[0] // empty
      | .effectivePercentRemaining | floor | if . < 0 then 0 else . end
    ' 2>/dev/null | head -1) || remaining=
  case "$remaining" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "$remaining" -ge "$min" ]; then printf 'reset'; else printf 'exhausted'; fi
  return 0
}
