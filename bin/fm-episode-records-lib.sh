#!/usr/bin/env bash
# fm-episode-records-lib.sh - single owner of the supervision records a task
# must not INHERIT, and of the moment they are cleared.
# Call form: source it, then fm_episode_records_clear <state-dir> <target> <id>.
# No side effects on source. set -u / set -e safe.
#
# WHY THIS IS NOT A TEARDOWN LIST
# -------------------------------
# A home's state/ holds two namespaces. bin/fm-teardown.sh's sweep of
# state/<id>.* owns the first: records named for the TASK. The second is named
# for the watcher key - the endpoint a task occupies, folded ':/.' to '_' - plus
# a few task-named records that sit outside the <id>.<suffix> shape that sweep
# can see. bin/fm-watch.sh and bin/fm-supervise-daemon.sh write them, and every
# one is suppression, detection, or escalation state: a pane signature and its
# repeat count, a stale suppressor, a pause flag and its cadence throttles, a
# wedge timer, an escalation count, an absorb count, a surfaced-status signature.
#
# The harm they can do is exact: a LATER task that lands on the same key starts
# with a throttle or a count it never earned, so its first genuine wedge is
# absorbed, or its first recheck escalates early against an idle age measured
# from a pane that is gone. That harm happens when a key is CLAIMED, not when it
# is released, and the claim is where the clear belongs:
#   - Teardown cannot always compute the key. It reads the target from the
#     task's meta, and a missing or corrupt meta is exactly the stuck-crewmate
#     case these records outlive.
#   - Teardown is not the only way an endpoint ends. A crashed host, a pane
#     closed by hand, or a home abandoned without a teardown all leave the
#     records behind with no teardown to have run.
#   - A claim is unconditional and provably safe. bin/fm-spawn.sh holds the
#     per-id spawn lock and has already refused a still-live endpoint for the
#     id, so the key it is about to occupy is free and nothing live can lose
#     state to the clear.
# Teardown still calls this, because the release is where the key is known
# cheapest and prompt reclamation keeps state/ from growing a tail of dead keys.
# Nothing depends on that call: the guarantee is the claim.
#
# The one race, and its direction: a push-capable backend can write an
# escalation marker for a pane that exists before its meta does, so a claim-time
# clear can drop a marker written moments earlier. That marker only dedupes a
# wake, so dropping it costs one repeated wake and can never swallow one.
#
# DELIBERATELY RETAINED, with reasons:
#   state/.spawn-<id>.lock   the claim's own single-flight lock, held ACROSS
#                            this clear by the caller that takes it. Its
#                            lifecycle belongs to bin/fm-lock-lib.sh, and a
#                            leftover file is re-acquired, never obeyed.
#   home-scoped watcher and daemon records (.wake-queue, .last-*, .afk*,
#                            .heartbeat-streak, .subsuper-last-*) are keyed by
#                            neither task nor endpoint, so no task can inherit
#                            them.
#   state/<id>.*             bin/fm-teardown.sh's remove_task_state_records owns
#                            that namespace in full.

# The watcher key for a backend target. bin/fm-watch.sh, bin/fm-supervise-daemon.sh
# and bin/backends/herdr.sh each fold their own copies inline on hot paths; this
# is the spelling they all share, and the one a new record family must key on to
# be reachable by the clear below.
fm_episode_key() {  # <target>
  printf '%s' "${1-}" | tr ':/.' '___'
}

# Clear every suppression, detection, and escalation record a new occupant of
# <target>, or a new task reusing <id>, would otherwise inherit. Either argument
# may be empty: an endpoint whose target was never recorded still gets its
# task-named records cleared, and a target with no id still gets its key-named
# ones. Removing a record that is already absent is success.
fm_episode_records_clear() {  # <state-dir> <target> <id>
  local state=${1-} target=${2-} id=${3-} key idkey
  [ -n "$state" ] && [ -d "$state" ] || return 0
  if [ -n "$target" ]; then
    key=$(fm_episode_key "$target")
    # Pane detection state goes with the episode state here, unlike the
    # mid-episode resets in bin/fm-watch.sh that deliberately keep it: those
    # reset an episode on a pane that is still the same crew's, while this runs
    # only when the pane behind the key is gone or brand new. .hash-'s mtime is
    # the idle age a wedge escalation is triaged on, so leaving it is what makes
    # an inherited key escalate against a dead task's clock.
    rm -f -- \
      "$state/.hash-$key" \
      "$state/.count-$key" \
      "$state/.stale-$key" \
      "$state/.stale-since-$key" \
      "$state/.paused-$key" \
      "$state/.paused-rechecked-$key" \
      "$state/.paused-resurfaced-$key" \
      "$state/.wedge-escalations-$key" \
      "$state/.advancing-resurfaced-$key" \
      "$state/.advancing-absorbs-$key" \
      "$state/.herdr-escalated-$key" || return 1
  fi
  if [ -n "$id" ]; then
    idkey=$(fm_episode_key "$id")
    # Task-named, but outside the <id>.<suffix> shape state/<id>.* can reach.
    # The .seen-* pair is spelled from the status and turn-end file names, whose
    # dots fold the same way.
    rm -f -- \
      "$state/.subsuper-stale-$idkey" \
      "$state/.subsuper-paused-$idkey" \
      "$state/.subsuper-advancing-$idkey" \
      "$state/.subsuper-advancing-resurfaced-$idkey" \
      "$state/.subsuper-advancing-absorbs-$idkey" \
      "$state/.subsuper-seen-status-$idkey" \
      "$state/.hb-surfaced-$idkey" \
      "$state/.seen-${idkey}_status" \
      "$state/.seen-${idkey}_turn-ended" || return 1
  fi
  return 0
}
