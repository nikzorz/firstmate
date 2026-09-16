#!/usr/bin/env bash
# fm-send-result-lib.sh - the one reader of bin/fm-send.sh's exit status.
#
# Every caller that runs fm-send asks this what happened instead of comparing the
# raw number, so the numbers have exactly one owner and a new caller cannot
# invent a fourth reading of them. What each number means is contracted in full
# in bin/fm-send.sh's header; nothing here restates it.
#
# Sourced by bin/fm-send.sh, which exits with the status below, and by every
# script that runs fm-send and acts on the outcome.
# No side effects on source. set -u / set -e safe.

# Submitted, but the backend could not confirm delivery. 3 is already the gate
# refusal (bin/fm-gate-refuse-lib.sh), which fires before a target is resolved or
# a keystroke is typed, so it must keep reading as a send that never happened.
FM_SEND_EXIT_UNCONFIRMED=4

# fm_send_result: what a finished fm-send run proves about the text.
#   delivered    the backend confirmed the submit.
#   unconfirmed  the text was typed and submitted, but nothing proves it landed.
#                It may have, so a resend delivers the same instruction twice.
#   failed       fm-send has no confirmed delivery to report. This also covers
#                the one path where the text WAS delivered but its pending-reply
#                commit failed; that run's own stderr says so and says not to
#                resend, so a caller that resends on failed must read it first.
fm_send_result() {  # <fm-send exit status>
  local status=${1:-1}
  if [ "$status" = 0 ]; then
    printf 'delivered'
  elif [ "$status" = "$FM_SEND_EXIT_UNCONFIRMED" ]; then
    printf 'unconfirmed'
  else
    printf 'failed'
  fi
}
