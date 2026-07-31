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

# Seconds added to a reported window reset before the recheck is scheduled. The
# reset is a precise instant, and a recheck that lands a second early simply
# re-reads an exhausted window and re-parks the crew for another cadence, so the
# grace is what makes the scheduled recheck worth taking at all.
FM_CLAUDE_LIMIT_RESET_GRACE_SECS_DEFAULT=60

# Pane tail (lines) a caller should capture for the match. Large enough to hold
# the whole prompt plus the message above it, small enough to stay cheap.
FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT=40

# fm_claude_limit_scan_lines: the pane tail every capturing caller should ask
# for, with the operator override read and validated here rather than at each
# call site, so the value's guard stays with the default it protects.
fm_claude_limit_scan_lines() {  # -> positive integer
  local n=${FM_CLAUDE_LIMIT_SCAN_LINES:-$FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT}
  case "$n" in ''|*[!0-9]*) n=$FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT ;; esac
  printf '%s' "$n"
}

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

# fm_claude_limit_parse_iso8601: epoch seconds for one UTC-referenced ISO 8601
# timestamp, or empty for anything this cannot parse exactly.
#
# Deliberately arithmetic rather than a `date` call. `quota-axi` reports
# `2026-07-30T10:40:00.593064+00:00` - fractional seconds and a numeric offset -
# which GNU `date -d` accepts, BSD/macOS `date -j -f` does not, and jq's
# `fromdateiso8601` rejects outright. Firstmate supports macOS, so a parser whose
# answer depends on which platform ran it would be a silent per-platform
# scheduling difference. The civil-date conversion below is Howard Hinnant's
# days-from-civil, exact for every date this can be handed.
#
# Fails closed to empty, which every caller reads as "no reset time known":
# a malformed shape, an out-of-range field, or a pre-epoch year.
fm_claude_limit_parse_iso8601() {  # <timestamp> -> epoch seconds, or empty
  local ts=${1:-} re y mo d h mi s off sign oh om yy era yoe doy doe days epoch
  re='^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?([Zz]|[+-][0-9]{2}:?[0-9]{2})$'
  [[ $ts =~ $re ]] || return 0
  y=$((10#${BASH_REMATCH[1]}))
  mo=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  h=$((10#${BASH_REMATCH[4]}))
  mi=$((10#${BASH_REMATCH[5]}))
  s=$((10#${BASH_REMATCH[6]}))
  off=${BASH_REMATCH[8]}
  [ "$y" -ge 1970 ] || return 0
  [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] || return 0
  [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 0
  [ "$h" -le 23 ] && [ "$mi" -le 59 ] || return 0
  # A leap second (:60) is a real instant, not a malformed one; clamp it to :59
  # rather than discarding a whole reset time over one second.
  [ "$s" -le 60 ] || return 0
  [ "$s" -le 59 ] || s=59
  # January and February are counted as months 13 and 14 of the previous year,
  # which is what makes the leap day the last day of the cycle and the conversion
  # below branch-free. Written as an `if` rather than a bare `&&` statement: this
  # lib is sourced into `set -e` scripts, where a trailing false AND-list is a
  # silent-exit hazard nobody should have to re-derive.
  yy=$y
  if [ "$mo" -le 2 ]; then yy=$(( yy - 1 )); fi
  era=$(( yy / 400 ))
  yoe=$(( yy - era * 400 ))
  if [ "$mo" -gt 2 ]; then
    doy=$(( (153 * (mo - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (mo + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  epoch=$(( days * 86400 + h * 3600 + mi * 60 + s ))
  case "$off" in
    Z|z) ;;
    *)
      sign=${off:0:1}
      oh=$((10#${off:1:2}))
      om=${off#???}
      om=${om#:}
      om=$((10#$om))
      [ "$oh" -le 23 ] && [ "$om" -le 59 ] || return 0
      if [ "$sign" = - ]; then
        epoch=$(( epoch + oh * 3600 + om * 60 ))
      else
        epoch=$(( epoch - oh * 3600 - om * 60 ))
      fi
      ;;
  esac
  [ "$epoch" -ge 0 ] || return 0
  printf '%s' "$epoch"
  return 0
}

# fm_claude_limit_window_read: `<state><TAB><recheck-epoch>`, from ONE quota read.
# The state is `reset`, `exhausted`, or `unknown`; the second field is the epoch
# at which an exhausted window is worth rechecking, or empty when no such time
# can be established. Both come from the same read on purpose: a caller that
# wanted them separately would pay for the provider call twice, and the point of
# the scheduled recheck is one well-timed quota read, not more of them.
#
# `quota-axi` is firstmate's authority on quota windows (AGENTS.md section 4),
# so this asks it rather than inferring a reset from elapsed time. It reads the
# provider's own bounded effective availability for all models, which already
# accounts for a model window sitting inside a shorter account window, instead
# of picking one window and guessing which one bound the account.
#
# The recheck time is derived from the same bounding: effective availability is
# the MINIMUM across the windows that bound all models, so the account is short
# until every bounding window that is currently short has reset. Taking the
# LATEST of their resets is therefore the earliest instant the account can
# actually be usable again - the earliest one would just re-observe the next
# short window. Any short window whose reset or remaining percentage the provider
# does not report leaves that instant unknown rather than guessed.
#
# Fail-closed inputs, all of which report `unknown` with no recheck time: no
# `quota-axi`, no `jq`, a timed-out or unparseable read, quota data the provider
# itself marks stale, or a semantics/availability block the provider does not
# mark `known`. `unknown` never authorizes recovery, and never counts as a
# settled external wait either - it is a condition to surface. A readable window
# with an unreadable reset time is still a good `exhausted` verdict; only the
# scheduling refinement is lost, and the caller falls back to its own cadence.
fm_claude_limit_window_read() {  # -> "<reset|exhausted|unknown>\t<epoch|>"
  local min grace json parsed remaining line epoch best known
  min=${FM_CLAUDE_LIMIT_RESET_MIN_REMAINING:-$FM_CLAUDE_LIMIT_RESET_MIN_REMAINING_DEFAULT}
  case "$min" in ''|*[!0-9]*) min=$FM_CLAUDE_LIMIT_RESET_MIN_REMAINING_DEFAULT ;; esac
  grace=${FM_CLAUDE_LIMIT_RESET_GRACE_SECS:-$FM_CLAUDE_LIMIT_RESET_GRACE_SECS_DEFAULT}
  case "$grace" in ''|*[!0-9]*) grace=$FM_CLAUDE_LIMIT_RESET_GRACE_SECS_DEFAULT ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'unknown\t'; return 0; }
  json=$(fm_claude_limit_quota_json)
  [ -n "$json" ] || { printf 'unknown\t'; return 0; }
  # Every test is an explicit equality rather than jq's `//` alternative
  # operator: `//` treats a literal `false` the same as a missing field, so
  # `(.state.stale // true) == false` would have discarded the good case where
  # the provider explicitly reports `"stale": false`. Written this way, an absent
  # field compares against null, fails the test, and correctly yields `unknown`.
  # Output is the remaining percentage on the first line, then either nothing,
  # the literal `?` for a short window the provider did not fully describe, or
  # one reset timestamp per currently-short bounding window.
  parsed=$(printf '%s' "$json" | jq -r --argjson min "$min" '
      (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
      | select(.state.stale == false)
      | . as $p
      | ($p.quotaSemantics // {})
      | select(.status == "known")
      | (.effectiveAvailability // [])
      | map(select(.scope == "all_models"
                   and (.status == "known")
                   and (.effectivePercentRemaining != null)))
      | .[0] // empty
      | . as $eff
      | (($p.windows // [])
         | map(select((.id // "") as $i | (($eff.boundedBy // []) | index($i)) != null))) as $bounded
      | ($bounded | map(select((.percentRemaining == null) or (.percentRemaining < $min)))) as $short
      | [ ($eff.effectivePercentRemaining | floor | if . < 0 then 0 else . end | tostring) ]
        + (if ($short | length) == 0 then []
           elif ($short | map(select((.resetsAt == null) or (.percentRemaining == null))) | length) > 0 then ["?"]
           else ($short | map(.resetsAt)) end)
      | .[]
    ' 2>/dev/null) || parsed=
  remaining=$(printf '%s\n' "$parsed" | head -1)
  case "$remaining" in ''|*[!0-9]*) printf 'unknown\t'; return 0 ;; esac
  if [ "$remaining" -ge "$min" ]; then printf 'reset\t'; return 0; fi
  best=
  known=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    epoch=$(fm_claude_limit_parse_iso8601 "$line")
    if [ -z "$epoch" ]; then known=0; break; fi
    if [ -z "$best" ] || [ "$epoch" -gt "$best" ]; then best=$epoch; fi
  done < <(printf '%s\n' "$parsed" | tail -n +2)
  if [ "$known" = 1 ] && [ -n "$best" ]; then
    printf 'exhausted\t%s' "$(( best + grace ))"
  else
    printf 'exhausted\t'
  fi
  return 0
}

# fm_claude_limit_window_state: just the verdict, for the readers that never
# schedule anything (bin/fm-crew-state.sh). One owner, one quota read.
fm_claude_limit_window_state() {  # -> reset|exhausted|unknown
  local verdict
  verdict=$(fm_claude_limit_window_read)
  printf '%s' "${verdict%%$'\t'*}"
  return 0
}
