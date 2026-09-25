#!/usr/bin/env bash
# fm-extra-usage.sh - notice when Claude workers have flipped onto paid extra
# usage, and stop the fleet at a safe point once that is confirmed.
#
# Usage: FM_HOME=<firstmate home> bin/fm-extra-usage.sh check|scan|steer|arm|disarm
#
#   check   the watcher check: prints one line naming the next command when a
#           claude worker pane shows the extra-usage notice and this home has
#           not already stopped the fleet for it, and nothing otherwise.
#   scan    read-only: one `<task><TAB><class><TAB><spend>` line per claude
#           worker pane showing the notice right now.
#   steer   re-reads every claude worker pane, and only on a fresh match sends
#           each live worker one stop instruction, then prints the outcome to
#           relay, including the credit spend when a footer shows it.
#   arm     writes state/extra-usage.check.sh and binds it with
#           fm-check-register.sh, so the watcher runs `check` every
#           FM_CHECK_INTERVAL.
#   disarm  removes the check, its trust binding, and the episode record.
#
# Exit codes: 0 done (including a silent check); 1 refused or a step did not
# land, with the reason on stderr; 2 usage error.
#
# WHY: extra usage turns an emptied plan window into silent paid spend, and
# Claude Code shows that only on screen, so no worker can checkpoint on its own.
# bin/fm-claude-limit-lib.sh owns the footer signature.
#
# NEVER ON AN UNCERTAIN READ. Only a readable pane whose live footer carries the
# notice counts; an unreadable pane, a pane with no provable composer, or the
# words appearing anywhere else is no match. `steer` re-proves the match itself
# rather than trusting the earlier check. While extra usage is turned off the
# notice never renders, so every command here is a no-op.
#
# ONE STOP PER EPISODE. `steer` records state/.extra-usage-steered with the time
# and each worker it reached, so a rerun reaches only workers it has not
# reached, and `check` stays silent for FM_EXTRA_USAGE_EPISODE_SECS (default
# 18000, one five-hour window) instead of re-stopping workers restarted on
# purpose. Secondmates are not stopped from here: each home arms its own check.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-extra-usage refuses to guess a firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-claude-limit-lib.sh
. "$SCRIPT_DIR/fm-claude-limit-lib.sh"

CHECK_ID='extra-usage'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.extra-usage-steered"
RECORD_SCHEMA=fm-extra-usage-v1
EPISODE_SECS_DEFAULT=18000
EPISODE_SECS=${FM_EXTRA_USAGE_EPISODE_SECS:-$EPISODE_SECS_DEFAULT}
case "$EPISODE_SECS" in ''|*[!0-9]*) EPISODE_SECS=$EPISODE_SECS_DEFAULT ;; esac

STEER=${FM_EXTRA_USAGE_STEER:-"Claude extra usage is now in effect for this account, so further work is paid from usage credits. Reach a safe stopping point and stop: finish or commit the step in hand and start nothing new. If a validation run is in flight, let the round already running finish, then do not answer its next gate or start another round; do not abort it. Then append a paused status line saying you stopped for Claude extra usage, and wait for firstmate."}

# Prints `<task><TAB><class><TAB><spend>` per claude pane showing the notice;
# with `first`, stops at the first one, which is all `check` needs.
scan() {  # [first]
  local meta id target backend pane verdict lines
  lines=$(fm_claude_limit_scan_lines)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" harness)" = claude ] || continue
    id=$(basename "$meta" .meta)
    target=$(fm_backend_target_of_meta "$meta" || true)
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    pane=$(fm_backend_capture "$backend" "$target" "$lines" "fm-$id" 2>/dev/null) || continue
    [ -n "$pane" ] || continue
    verdict=$(printf '%s' "$pane" | fm_claude_extra_usage_read) || continue
    printf '%s\t%s\n' "$id" "$verdict"
    [ "${1:-}" != first ] || return 0
  done
  return 0
}

episode_active() {
  local schema epoch
  [ -f "$RECORD" ] || return 1
  read -r schema epoch _ < "$RECORD" || return 1
  [ "$schema" = "$RECORD_SCHEMA" ] || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - epoch )) -lt "$EPISODE_SECS" ]
}

action_check() {
  local hit id class
  episode_active && return 0
  hit=$(scan first)
  [ -n "$hit" ] || return 0
  id=${hit%%$'\t'*}
  class=${hit#*$'\t'}; class=${class%%$'\t'*}
  printf 'extra-usage %s on %s: claude workers are now on paid usage credits; run FM_HOME=%q %q steer to stop every worker at a safe point, then report it\n' \
    "$class" "$id" "$FM_HOME" "$SCRIPT_DIR/fm-extra-usage.sh"
}

action_steer() {
  local hits first seen class spend meta id target kind tmp sent='' failed='' skipped=''
  hits=$(scan)
  if [ -z "$hits" ]; then
    echo "refused: no claude worker pane shows the extra-usage notice right now; nothing sent" >&2
    return 1
  fi
  first=$(printf '%s\n' "$hits" | head -1)
  seen=${first%%$'\t'*}
  class=$(printf '%s\n' "$hits" | awk -F '\t' '$2 == "near-limit" { print $2; found = 1; exit } END { if (!found) print "using" }')
  spend=$(printf '%s\n' "$hits" | awk -F '\t' '$3 != "" { print $3; exit }')
  if ! episode_active; then
    tmp=$(umask 077; mktemp "$STATE/.fm-extra-usage.XXXXXX") || return 1
    if ! printf '%s %s %s %s\n' "$RECORD_SCHEMA" "$(date +%s)" "$class" "$seen" > "$tmp" \
      || ! mv -f -- "$tmp" "$RECORD"; then
      rm -f -- "$tmp"
      echo "refused: could not record the episode in $RECORD" >&2
      return 1
    fi
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" != secondmate ] || continue
    grep -qxF "steered $id" "$RECORD" && continue
    target=$(fm_backend_target_of_meta "$meta" || true)
    [ -n "$target" ] || continue
    if [ "$(fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$target")" = dead ]; then
      skipped="$skipped $id"
      continue
    fi
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$id" "$STEER" >/dev/null; then
      printf 'steered %s\n' "$id" >> "$RECORD"
      sent="$sent $id"
    else
      failed="$failed $id"
    fi
  done
  printf 'extra usage: %s, first seen on %s; credit spend: %s\n' "$class" "$seen" "${spend:-not shown on screen}"
  printf 'stop instruction sent to:%s\n' "${sent:- none}"
  [ -z "$skipped" ] || printf 'not sent, endpoint dead:%s\n' "$skipped"
  if [ -n "$failed" ]; then
    printf 'refused: the stop instruction did not land for:%s; rerun steer to retry only those\n' "$failed" >&2
    return 1
  fi
  return 0
}

action_arm() {
  local home tmp
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "error: cannot resolve FM_HOME $FM_HOME" >&2; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.fm-extra-usage.XXXXXX") || return 1
  if ! printf '%s\n' '#!/usr/bin/env bash' \
      '# Auto-generated by fm-extra-usage.sh - extra-usage detection shim.' \
      "export FM_HOME=$(printf '%q' "$home")" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-extra-usage.sh") check" > "$tmp" \
    || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    echo "error: could not write $CHECK_SHIM" >&2
    return 1
  fi
  # An unbound shim is rejected by the watcher on every sweep, so a failed
  # registration leaves no shim at all.
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    echo "error: could not register $CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  check) action_check ;;
  scan) scan ;;
  steer) action_steer ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  *) echo "usage: fm-extra-usage.sh check|scan|steer|arm|disarm" >&2; exit 2 ;;
esac
