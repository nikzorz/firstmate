#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the absorb classification that
# makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures) - with the one exception below, which keeps a record of its own.
#
# The one exception is the absorb classification: crew_absorb_verdict, the primitive
# that prints "<class> <source>", plus crew_absorb_class (the class alone), its
# working/paused wrappers, and crew_park_sighting_record. It is NOT a pure
# status-file read: it reuses bin/fm-crew-state.sh, which may make a bounded
# no-mistakes call, to decide whether a crew that just stopped its turn or went
# stale is working, deliberately paused, finished with a landing route, parked on a
# decision only firstmate or the captain can answer, unreliable (a verdict that is
# evidence of nothing either way), or none of those.
#
# It also WRITES durable per-task state, which a second consumer written against
# this contract has to know before it calls: a parked verdict records the park
# sighting in state/<id>.park-sighting (fm_classify_park_announced below), so the
# verdict is order-dependent and NOT idempotent. The hazard that carries is asking
# TWICE for one look: the second call answers against the baseline the first just
# wrote, so the wake absorbs and the first-sighting escalation is spent on nobody.
# Asking on MORE looks is the opposite of a hazard. Each extra sighting narrows the
# window in which a word the crew appends and a re-park cannot be told apart, and
# that window is the one that resolves toward absorbing a crew that should have
# surfaced - so a SLOWER cadence degrades the property the record exists for.
# Callers run it ONLY on no-verb signal handling, on a surfaced signal whose crew
# announced a decision, on first sighting of a stale hash, and at the wedge
# escalation threshold for a stale pane still absorbed as provably working, never
# on every wake, and that limit is about the bounded read below rather than about
# the record.
# A caller that keeps absorbing the same unchanged pane across polls re-reads no
# more often than FM_STALE_ESCALATE_SECS, which is what keeps "never on every wake"
# true for a crew that stays absorbed indefinitely: bin/fm-watch.sh's declared-pause
# cadence memoizes the verdict in its own marker state, and its wedge threshold is
# already spaced by the idle window it restarts on each absorb.
# bin/fm-supervise-daemon.sh's stale-persistence recheck buys no spacing from its
# own marker, because its absorb deliberately leaves that marker's epoch measuring
# true idle age, so it keeps to the same window through a throttle record it writes
# beside the marker.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# How many times ONE unchanged stale pane may be counted before the supervisor
# counting it escalates that pane as demanding a look closer than the run-step
# state alone. Three by default.
# The number lives here rather than in either supervisor because both weigh it
# against the same crew, and two literals could be edited apart. That is the
# whole of what one owner buys: neither can end up reading a different number for
# the same named knob. What each supervisor counts against it, and when, is that
# supervisor's own policy and is stated where it is enforced, so this definition
# stays true however either one reorders its internals.
# A consumer resolving this at load time makes the source order load-bearing: in
# a `set -u` script the constant must already be defined, or startup aborts
# rather than quietly falling back.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_WEDGE_DEMAND_INSPECT_COUNT_DEFAULT=3

# --- one-shot pause recheck deadline ----------------------------------------
#
# Some external waits announce when they end. The cadence above cannot use that:
# it is a fixed window, so a wait that clears in forty minutes is still rechecked
# an hour after it was declared. That is the observed cost - a crew parked on
# Claude Code's usage-limit prompt was recovered correctly but up to an hour
# after the account window had already rolled.
#
# So a pause may additionally carry ONE recheck epoch in `state/<id>.pause-recheck`,
# and both supervisors recheck at whichever comes first. Three properties keep
# this a scheduling refinement rather than a second cadence:
#
#   - It only ever fires EARLIER. It is OR-ed with the fixed window, never
#     replaces it, so an absent, malformed, or far-future deadline leaves today's
#     behaviour exactly as it was and a forgotten pause still cannot rot.
#   - It is ONE-SHOT. The consumer clears it as it fires, so a deadline already
#     in the past means recheck now, once, and then back to the fixed cadence -
#     never a tight loop against a stale timestamp.
#   - Only a FUTURE epoch is ever recorded (pause_deadline_set enforces it), so a
#     writer that recomputes the same elapsed deadline on every recheck cannot
#     schedule itself into a spin.
#
# The only writer today is the usage-limit pause in bin/fm-limit-resume.sh, which
# gets the epoch from bin/fm-claude-limit-lib.sh's quota read. This lib owns the
# file and the predicate because both supervisors already read the pause cadence
# from here, and neither should learn a second place to look.
#
# A deadline belongs to the ONE pause it was written for. Each supervisor's
# clear_pause_tracking drops it along with the rest of that pause's state as soon
# as the crew stops declaring the pause, so it cannot survive a recovery that
# never went through its writer and later mislabel an unrelated wait as having
# reported an end time.
FM_CLASSIFY_PAUSE_DEADLINE_SUFFIX='.pause-recheck'

pause_deadline_file() {  # <state-dir> <id>
  printf '%s/%s%s' "$1" "$2" "$FM_CLASSIFY_PAUSE_DEADLINE_SUFFIX"
}

# Record a scheduled recheck. A missing, malformed, or non-future epoch CLEARS
# the deadline instead of recording it: a deadline that is already due at the
# moment it is written carries no information the caller does not already have,
# and recording one would re-fire on every poll until the writer stopped.
pause_deadline_set() {  # <state-dir> <id> <epoch>
  local f epoch=${3:-}
  f=$(pause_deadline_file "$1" "$2")
  case "$epoch" in ''|*[!0-9]*) rm -f "$f" 2>/dev/null || true; return 0 ;; esac
  if [ "$epoch" -le "$(date +%s)" ]; then
    rm -f "$f" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$epoch" > "$f" 2>/dev/null || true
  return 0
}

pause_deadline_clear() {  # <state-dir> <id>
  rm -f "$(pause_deadline_file "$1" "$2")" 2>/dev/null || true
  return 0
}

# 0 when a recorded recheck deadline has arrived. An absent or malformed file is
# simply "no deadline", which leaves the caller on its fixed cadence.
# Called from the watcher's stale path, which runs on every poll for every paused
# crew and is documented as cheap, so the overwhelmingly common no-deadline case
# costs one file test and no subprocess at all.
pause_deadline_reached() {  # <state-dir> <id>
  local f epoch=
  f="$1/$2$FM_CLASSIFY_PAUSE_DEADLINE_SUFFIX"
  [ -f "$f" ] || return 1
  # `|| true`: a final line with no newline still populates `epoch` while read
  # reports failure, and an unreadable file simply leaves it empty for the
  # validation below.
  read -r epoch < "$f" 2>/dev/null || true
  epoch=${epoch%%[!0-9]*}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -ge "$epoch" ]
}

# The distinct current state bin/fm-crew-state.sh reports for a crew parked on
# Claude Code's usage-limit prompt, and the token its detail carries for the
# quota window. Both consumers of this library - the always-on watcher and the
# away-mode daemon - read the state through crew_usage_limit_class below rather
# than re-deriving it, so the vocabulary has one definition exactly like the
# pause verb above. There is deliberately no per-home override: unlike the status
# verbs a crew writes, this token is produced and consumed entirely inside
# firstmate's own scripts, so a configurable spelling would only let the producer
# and consumer drift.
FM_CLASSIFY_USAGE_LIMITED_STATE='usage-limited'
FM_CLASSIFY_LIMIT_WINDOW_PREFIX='limit-window: '

# The token bin/fm-crew-state.sh appends to a `parked` detail to publish WHO
# owns the gate the run stopped at: present means the answer belongs to
# firstmate or the captain rather than to the worker. nm_gate_needs_authority
# there owns the rule for when it is written and is the only place that rule is
# stated; this is only the literal both sides must spell the same way, and it
# carries no per-home override for the same reason the usage-limit tokens above
# carry none. The producer reads it from here rather than repeating the text.
FM_CLASSIFY_AUTHORITY_GATE_MARKER='(ask-user: authority decision)'

# The second token bin/fm-crew-state.sh appends to a `parked` detail, beside the
# one above: an opaque IDENTITY for the park episode the run is stopped at,
# written as this prefix, the identity, and a closing parenthesis.
# nm_park_identity there owns what goes into it and is the only place that rule
# is stated; this is only the literal both sides must spell the same way, and it
# carries no per-home override for the same reason the token above carries none.
#
# The identity is meaningless on its own - it is compared against the LAST one
# seen for the same task, recorded below, and only the comparison carries
# meaning. That is the whole point: a park has no readable start time, but two
# sightings of one task can say whether the run re-parked between them, and that
# is exactly the fact the absorb needs.
#
# It must stay textually DISJOINT from the ownership token and from that
# script's operator note - no one of the three a substring of another - because
# crew_absorb_verdict matches the ownership token as a plain substring of the
# same line it slices this one out of.
FM_CLASSIFY_PARK_IDENTITY_PREFIX='(park '

# Slice the park identity out of a current-state line. Refuses anything that is
# not the fixed alphabet nm_park_identity emits, so a crew's own prose cannot
# forge one; the run-step source check in crew_absorb_verdict is what keeps such
# prose off this path in the first place, and this is the second lock.
_fm_classify_park_identity() {  # <line>
  local v=$1
  case "$v" in *"$FM_CLASSIFY_PARK_IDENTITY_PREFIX"*) ;; *) return 1 ;; esac
  v=${v#*"$FM_CLASSIFY_PARK_IDENTITY_PREFIX"}
  v=${v%%)*}
  case "$v" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s' "$v"
}

# Per-task record of the last park sighting: one line, "<park-identity>
# <status-fingerprint>", meaning "when this task was last seen parked at
# <park-identity>, the crew's status file stood at <status-fingerprint>".
#
# This library owns it because bin/fm-crew-state.sh, which supplies the identity,
# is documented read-only and side-effect free, so the reader that supplies the
# identity must not be the one that remembers it - the same split that puts the
# pause deadline above here. Both supervisors write it, so a supervision path in
# either that sees a stale crew and does not record leaves a hole in the record
# that nothing else fills. bin/fm-watch.sh holds most of the call sites, and
# bin/fm-supervise-daemon.sh's stale-persistence recheck adds one more through
# crew_run_step_advancing: that resolves to crew_absorb_verdict, so the away-mode
# daemon takes a sighting on the same terms as the watcher and can write the very
# first baseline through the no-record arm below. bin/fm-teardown.sh removes it
# with the rest of a task's state, and AGENTS.md section 2 lists it.
FM_CLASSIFY_PARK_SIGHTING_SUFFIX='.park-sighting'

park_sighting_file() {  # <state-dir> <id>
  printf '%s/%s%s' "$1" "$2" "$FM_CLASSIFY_PARK_SIGHTING_SUFFIX"
}

# A fingerprint of everything the crew has said, so "has the crew spoken since
# the last sighting" is answered from the file's CONTENT rather than its mtime.
# The status file is append-only, so any new word changes this; a touch by
# something that appended nothing does not, which an mtime comparison could not
# tell apart.
_fm_classify_status_fingerprint() {  # <status-file>
  local sum
  [ -f "$1" ] || return 1
  sum=$(cksum < "$1" 2>/dev/null) || return 1
  sum=${sum%% *}
  case "$sum" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$sum"
}

# 0 when nothing shows the crew's open decision to belong to an EARLIER park than
# the one the run is stopped at now. Reads the record above, decides, and updates
# it - the one place the sighting is both consulted and written, because the
# verdict and the update are one step and splitting them would let a caller take
# the verdict without advancing the evidence behind it.
#
# The three cases, and why the update rule is what it is:
#
#   - NO RECORD. This task has never been seen parked, so nothing can be said
#     about which episode its open decision belongs to. Report 1 and escalate,
#     which is this home's standing answer that unknown is not unannounced, and
#     write the baseline so the NEXT sighting has something to compare against.
#     The cost is NOT one notification, and calling it that would understate it:
#     writing the current park as the baseline asserts the very thing this arm
#     could not establish, so a crew ALREADY in the re-parked-and-silent shape
#     when its first sighting lands escalates once and absorbs from every look
#     after. What keeps that rare is taking the sighting while the park behind
#     the crew's word is still the one it was written at, which bin/fm-watch.sh
#     does on the captain-verb signal path as well as on both stale paths - so
#     the ordinary announce-then-wait flow no longer arrives here at all.
#     What still does: a crash, a restart, a cleared state directory, a task
#     older than this rule, and a decision announced while its run was not yet
#     parked or could not be read.
#   - THE CREW HAS SPOKEN since the record was written. Write the new baseline,
#     but answer from the record as it stood, because a word appended somewhere
#     between two sightings cannot be placed on either side of a re-park that
#     happened in the same window. Name the cost of adopting that baseline plainly:
#     when the word and a re-park BOTH fell in one sighting gap, and the word was
#     not about the new park, this arm escalates once and every later sighting then
#     absorbs, so the residual is a permanent absorb rather than a dating
#     imprecision. Narrowing the gap is what keeps that rare, which is why every
#     path that sees a stale crew records a sighting - including the away-mode one,
#     through crew_park_sighting_record below, which classifies nothing.
#   - THE CREW HAS NOT SPOKEN. Do NOT write. This is the case the whole rule
#     turns on: if the identity also matches, the crew's last word was already
#     its last word when this same park was seen before, so the park it announced
#     is the park in front of it and the wait absorbs. If the identity has
#     CHANGED, the run re-parked and the crew has said nothing since - its open
#     decision belongs to an episode already answered, which is the silence-
#     forever shape. Leaving the record untouched is what makes that verdict
#     STICK: every later sighting re-derives it from the same unmoved evidence,
#     rather than adopting the new park as a baseline and absorbing on the next
#     look.
#
# An unreadable status file reports 1 for the same reason a missing record does.
fm_classify_park_announced() {  # <id> <park-identity>
  local id=$1 park=$2 state f word seen_park='' seen_word=''
  [ -n "$id" ] && [ -n "$park" ] || return 1
  state=$(_fm_classify_state_dir)
  [ -n "$state" ] || return 1
  word=$(_fm_classify_status_fingerprint "$state/$id.status") || return 1
  f=$(park_sighting_file "$state" "$id")
  # Tested before reading, and `|| true` on the read: an absent record is the
  # ordinary first-sighting case rather than an error, and a final line with no
  # newline still populates both fields while read reports failure. Both are
  # exactly what pause_deadline_reached above relies on.
  if [ -f "$f" ]; then
    read -r seen_park seen_word < "$f" 2>/dev/null || true
  fi
  case "$seen_park" in ''|*[!0-9a-f]*) seen_park='' ;; esac
  case "$seen_word" in ''|*[!0-9]*) seen_word='' ;; esac
  if [ -z "$seen_park" ] || [ -z "$seen_word" ]; then
    printf '%s %s\n' "$park" "$word" > "$f" 2>/dev/null || true
    return 1
  fi
  if [ "$word" != "$seen_word" ]; then
    printf '%s %s\n' "$park" "$word" > "$f" 2>/dev/null || true
    [ "$park" = "$seen_park" ]
    return
  fi
  [ "$park" = "$seen_park" ]
}

# The bin/fm-crew-state.sh current-state words that mean a crew is still holding
# its in-flight task OPEN. `working` is a task advancing; `stalled` is the same
# task with its run no longer advancing, which is work that needs attention
# rather than work that ended or work that was never there. Every reader asking
# "is this task live right now" must ask about the whole set, or a crew drops out
# of the fleet's active view at exactly the moment its run stops moving - the
# opposite of what reporting the distinct state is for. One definition here, for
# the same reason the usage-limit token above has one: the words are produced and
# consumed entirely inside firstmate's own scripts, so a second copy could only
# drift. fm_classify_active_states_json is the form the snapshot readers' jq
# projections take, so a new word is taught to every consumer by editing the list.
FM_CLASSIFY_ACTIVE_STATES='working stalled'
fm_classify_active_states_json() {
  local st out=''
  for st in $FM_CLASSIFY_ACTIVE_STATES; do out="$out,\"$st\""; done
  printf '[%s]' "${out#,}"
}

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# --- landing route -----------------------------------------------------------
#
# A crew that appended `done: PR <url> checks green` and stopped did exactly what
# its instructions ask. There is nothing left for it to do, so its endpoint goes
# idle, and until this class existed the stale path read that idle endpoint as a
# possible wedge and surfaced it every escalation window for as long as the
# captain took to answer the PR - overnight included. A terminal `done` is the
# strongest positive evidence available that the crew is not wedged: it is the
# crew's own declaration that it finished.
#
# It earns the absorb only when the work has somewhere to land AND something
# other than the stale timer will wake firstmate when it does. That is exactly a
# recorded `pr=` plus an armed merge poll, and the merge poll is then the only
# thing that wakes firstmate for the task. A `done` with no landing route
# recorded is a crew that stopped with nowhere to go, which firstmate must see,
# so it keeps surfacing.
#
# The armed test is bin/fm-pr-lib.sh's own fm_pr_poll_artifacts_valid, the same
# predicate the watcher's check dispatcher uses to decide the poll may run:
# absorbing on a weaker test could silence a task whose poll the dispatcher will
# then refuse, leaving nothing at all to wake firstmate. It runs in a SUBSHELL so
# this read-only probe can never clobber the FM_PR_* globals a caller is using
# for the very poll under test.

# The state directory this library's task-file reads resolve against, matching
# bin/fm-crew-state.sh's own resolution order.
_fm_classify_state_dir() {
  if [ -n "${STATE:-}" ]; then printf '%s' "$STATE"; return; fi
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf '%s' "$FM_STATE_OVERRIDE"; return; fi
  printf '%s/state' "${FM_HOME:-$_FM_CLASSIFY_LIB_DIR/..}"
}

fm_classify_landing_route_armed() {  # <id>
  local id=$1 state
  [ -n "$id" ] || return 1
  state=$(_fm_classify_state_dir)
  [ -n "$state" ] || return 1
  grep -q '^pr=..*' "$state/$id.meta" 2>/dev/null || return 1
  [ -f "$_FM_CLASSIFY_LIB_DIR/fm-pr-lib.sh" ] || return 1
  [ -f "$_FM_CLASSIFY_LIB_DIR/fm-pr-poll.sh" ] || return 1
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$_FM_CLASSIFY_LIB_DIR/fm-pr-lib.sh" \
      && fm_pr_poll_artifacts_valid "$state" "$id" "$_FM_CLASSIFY_LIB_DIR/fm-pr-poll.sh"
  ) >/dev/null 2>&1
}

# --- outstanding decision ----------------------------------------------------
#
# The landing route above is one instance of a wider shape: a crew is idle
# because it is correctly waiting on somebody else, and firstmate already knows
# what it is waiting for. A crew parked at a no-mistakes gate on an ask-user
# finding is the other instance. It did exactly what its instructions ask -
# appended `needs-decision:` and stopped - and the answer has to come from
# firstmate or the captain, so its endpoint stays idle for as long as that takes
# and the stale timer re-raised it every escalation window, overnight included.
#
# The asymmetry that makes this safe is the same one the landing route uses. A
# parked run absorbs only while the decision it is parked on is RECORDED as
# still open, and stops absorbing the moment that decision is closed - because an
# idle pane after the answer landed is a worker that failed to act on it, which
# firstmate must see. Never absorb a crew that is waiting for nothing.
#
# status_open_decisions above is that record and the only one consulted: it folds
# the whole append-only status stream, so a decision stays open across later
# unrelated events and is closed only by an explicit `resolved:` or a verified
# captain-held backlog transfer for its key. Note what that means for a crew's
# first `needs-decision:` line - it is captain-relevant, so it still surfaces
# once through the signal path exactly as before. This class only silences the
# repeat stale wakes that follow it.
#
# An open decision on its own is not enough. The fold is a record about the whole
# TASK while the park is a fact about ONE park episode, so an open key left
# behind by an EARLIER episode, plus a later park the crew never announced,
# would read as "correctly waiting on somebody else" for as long as that worker
# stayed wedged - an absorb with no timer and no other wake owner, which is
# strictly worse than the wake noise it replaces. So crew_absorb_verdict below
# requires two further facts on the parked line, and separately requires the
# source to be `run-step`.
#
# The source check is NOT redundant with the token matches, and deleting it as
# such is the mistake to avoid here. A status-log `parked` line's detail is the
# crew's own unconstrained prose, so a crew that writes `needs-decision: review
# escalated an (ask-user: authority decision) finding` produces a parked line
# carrying the literal verbatim, and the token means nothing on that path. Only
# a run-step line's detail comes from bin/fm-crew-state.sh's own gate reading.
# The fallback is worthless as evidence for a second reason too: it derives the
# park from the very needs-decision line being folded here, so it correlates
# nothing with nothing.
#
# The two tokens answer two different questions, and the class needs both:
#
#   - FM_CLASSIFY_AUTHORITY_GATE_MARKER says WHO OWNS the gate this run is
#     parked at - firstmate or the captain, not the worker. On its own it says
#     nothing about which episode the open key belongs to.
#   - FM_CLASSIFY_PARK_IDENTITY_PREFIX carries an identity for the park episode,
#     which fm_classify_park_announced above weighs against the last one recorded
#     for this task. That is what ties the fold's open key to the park in front
#     of it, because the alternative shape - firstmate answers, the worker
#     responds to the gate, the pipeline fixes, the run parks again, and the
#     worker wedges before saying anything about the new gate - leaves the old
#     decision open over a park it never announced. A run that re-parked while
#     the crew stayed silent is exactly what two sightings of one task can show.
#
# What this still does not prove, stated rather than hidden: that the open key
# names the FINDING at this gate. Nothing available here can, because the fold
# is keyed per task and the park names no key. What the pair DOES establish is
# narrower than it reads at a glance, and is worth stating exactly: that
# firstmate owes an answer at a gate of this kind, and that the run has not
# re-parked since the crew last spoke. The second fact is a comparison of two
# sightings, so it says nothing about WHAT the crew said - a crew that wrote
# `working: rerunning tests` and then sat at one unchanging park satisfies it
# just as a fresh `needs-decision:` would. Narrowing that to a decision line is
# a SEPARATE gate that does not live here: bin/fm-watch.sh additionally requires
# the crew's last status line to be the `needs-decision` it is parked on, and it
# is today's only consumer of this class. A second consumer would have to make
# that check for itself.
#
# A crew that opened a key, was answered in the pane rather than through a
# `resolved:` line, and then stayed silent through a whole further park episode
# is caught by the second token; one that opens a fresh key at each park it
# reaches, which is what its own status-reporting contract asks of it, is
# absorbed.
#
# The residuals the second fact leaves are stated where its rule lives, in
# fm_classify_park_announced above: a task with no recorded sighting yet cannot
# be judged and escalates once, so a crew already wedged in that shape when
# firstmate first records it is absorbed from the sighting after; and a word the
# crew appends in the same gap as a re-park cannot be placed on either side of
# it, which costs one escalation and then absorbs.
#
# The fold is verb-blind, so a key opened by `blocked:` counts as open here just
# as a `needs-decision:` one does. What keeps a crew asking firstmate to ACT
# from being absorbed is bin/fm-watch.sh's own gate on the crew's latest status
# line: `parked` is the run's report that it cannot proceed without an outside
# answer, while `blocked:` is a request for action, and a request nobody has
# acted on is worth repeating.
fm_classify_decision_outstanding() {  # <id>
  local id=$1 state
  [ -n "$id" ] || return 1
  state=$(_fm_classify_state_dir)
  [ -n "$state" ] || return 1
  [ -n "$(status_open_decisions "$state/$id.status")" ]
}

# 0 when <line> carries <token> as a plain substring. The parked absorb weighs two
# tokens and only ONE of them is matched this way - the ownership marker, whose
# whole content is the literal itself. The park identity beside it is not a plain
# substring test at all: _fm_classify_park_identity above slices a value out and
# validates its alphabet, which is why the two literals must stay textually
# disjoint.
_fm_classify_line_carries() {  # <line> <token>
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). crew_absorb_verdict is the primitive
# and prints "<class> <source>"; crew_absorb_class below projects out the class
# alone, which is all any consumer but one needs. The classes are:
#   working    - an actively-running no-mistakes step (running/fixing/ci) or a busy
#                pane; the crew is legitimately mid-work on a static-looking pane
#                (e.g. waiting on CI);
#   paused     - the crew's authoritative current state is a declared external-wait
#                pause (paused:), which is EXPECTED to idle. Whether a consumer may
#                act on it depends on the runtime backend: bin/fm-watch.sh's
#                declared-pause path additionally requires a confirmed-live
#                endpoint, which only tmux and herdr can report - see that
#                function and docs/configuration.md's "Runtime backend" section;
#   landing    - the crew's authoritative current state is a terminal `done` AND
#                the task carries a recorded landing route with an armed merge
#                poll (fm_classify_landing_route_armed above). The work is
#                finished and the merge poll owns the next wake, so the stale
#                timer must not keep raising the same idle pane while the
#                captain takes their time over the PR;
#   deciding   - the crew's authoritative current state is a `run-step` `parked`
#                whose detail carries FM_CLASSIFY_AUTHORITY_GATE_MARKER, so the
#                gate is one firstmate or the captain owns, AND
#                FM_CLASSIFY_PARK_IDENTITY_PREFIX naming a park episode that
#                fm_classify_park_announced weighs as the one the crew last spoke
#                at, AND the task's status stream still carries an open keyed
#                decision (fm_classify_decision_outstanding above). Those are
#                three separate facts, not one implying the others - see the
#                section above. A park whose gate ownership could not be read, a
#                park the crew never wrote about, a park seen for the first time,
#                and the run-less status-log `parked` fallback are all
#                deliberately left out;
#   unreliable - the verdict came back, but it is not evidence about THIS CREW
#                either way (see below). Consumers that have an independent reason
#                to believe the crew is fine - today only the watcher's declared-pause
#                path - may treat it as "no contrary evidence" instead of proof the
#                crew stopped; every other consumer treats it exactly like none;
#   none       - none of those, so the wake must surface (a stopped/parked/
#                torn-down/unknown crew, a run that has stopped advancing
#                (stalled), a `done` with no landing route recorded, a `parked`
#                run that fails any of the deciding gates above, or an
#                unreadable verdict). A crew parked on
#                Claude Code's usage-limit prompt lands here too, deliberately: it is
#                genuinely stopped, so it must reach firstmate once instead of being
#                absorbed. crew_usage_limit_class below distinguishes it, and once
#                firstmate records the wait as `paused:` the ordinary declared-pause
#                cadence takes over and it is never aged as a wedge.
#
# Why `unreliable` is its own token rather than more `none`: a run-step verdict
# describes a no-mistakes RUN, and no-mistakes executes its steps in its own bare
# repo under ~/.no-mistakes/repos/, not in the crew's worktree. A run that is
# progressing is therefore not proof the crew is alive (the 2026-07-29 usage-limit
# incident: three crews were stopped on an interactive prompt while their runs still
# read `running`), and symmetrically a run that FAILED is not proof the crew stopped
# - the crew's normal response to a failed run is to start another one. Worse, a
# `failed` run-step verdict is a known misread: `axi status` reports one run per
# branch, and it can answer with a SUPERSEDED earlier run after the crew has already
# started a fresh one on the same commit, which this side cannot distinguish because
# both runs share the branch and the head that nm_run_head_matches_worktree binds on.
# Folding that into `none` made a verdict that is evidence of nothing outrank a
# crew's own declared pause.
# Only `failed` from `run-step` qualifies for `unreliable`. `parked` is waiting on an
# answer, which the `deciding` class above weighs against its own record, and
# `done`/`unknown` cover genuinely finished and genuinely torn-down crews.
#
# The <source> field is fm-crew-state.sh's own source token (run-step, pane,
# status-log, or none) passed through verbatim, and `none` when the line could not
# be parsed. It exists because the two ways to be `working` are not equally strong
# evidence: a run-step verdict is OUT-OF-BAND, a separate process's record that the
# pipeline advanced, while a pane verdict is read from the very pane a stale wake
# has already found unchanged, so it cannot corroborate itself. Only bin/fm-watch.sh's
# declared-pause path needs that distinction; every other consumer asks the class alone.
#
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read, in two ways that both bind the caller. fm-crew-state.sh may make
# a bounded no-mistakes call, and the parked arm WRITES state/<id>.park-sighting
# through fm_classify_park_announced, so the verdict is order-dependent: the first
# call for a task consumes its first-sighting escalation, and a second call for the
# SAME look answers against the baseline the first one wrote. Taking it on more
# looks is safe and wanted, for the reason the header gives, so the once-per-stale-
# hash cadence callers keep is about the bounded read and not about the record.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_verdict() {  # <id>
  local id=$1 line state src park
  [ -n "$id" ] || { printf 'none none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  # A line with no source: field cannot name its evidence, so it reports `none`
  # rather than letting the prefix strip fall through to the state word itself.
  case "$line" in
    *"source: "*) src=${line#*source: }; src=${src%% *} ;;
    *)            src=none ;;
  esac
  if [ "$state" = paused ]; then printf 'paused %s' "$src"; return; fi
  if [ "$state" = working ]; then
    case "$src" in run-step|pane) printf 'working %s' "$src"; return ;; esac
  fi
  if [ "$state" = "done" ] && fm_classify_landing_route_armed "$id"; then
    printf 'landing %s' "$src"; return
  fi
  if [ "$state" = parked ] && [ "$src" = run-step ] \
     && _fm_classify_line_carries "$line" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
     && park=$(_fm_classify_park_identity "$line") \
     && fm_classify_park_announced "$id" "$park" \
     && fm_classify_decision_outstanding "$id"; then
    printf 'deciding %s' "$src"; return
  fi
  if [ "$state" = failed ] && [ "$src" = run-step ]; then printf 'unreliable %s' "$src"; return; fi
  printf 'none %s' "$src"
}

# The class alone, for the consumers that do not care which evidence produced it.
# Shares crew_absorb_verdict's single fm-crew-state.sh read, adding none of its own.
crew_absorb_class() {  # <id>
  local verdict
  verdict=$(crew_absorb_verdict "$1")
  printf '%s' "${verdict%% *}"
}

# Take the verdict for its RECORD alone and throw the class away, for a caller that
# surfaces a crew without asking the absorb anything. Both such callers live in
# bin/fm-watch.sh, which owns why each one records: the away-mode stale path, where
# the daemon owns triage and the watcher surfaces one-shot per distinct stale hash
# without classifying, and the wake that announces a decision, which the classifying
# path short-circuits past. Without the away-mode one, no park sighting would be
# recorded for the whole time firstmate is away, and the next sighting after a
# return would be weighed against evidence from before the away window, which is the
# one comparison the record must never make. Recording costs the same bounded
# fm-crew-state.sh read the classifying path already pays, on the same bounded
# occasions rather than every wake, and changes nothing about what either path does
# with the crew.
crew_park_sighting_record() {  # <id>
  crew_absorb_verdict "$1" >/dev/null 2>&1 || true
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact classification.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s current-code-matched no-mistakes run step is ACTIVELY
# ADVANCING, which is the `working` class from the `run-step` source and nothing
# else. This is deliberately narrower than crew_is_provably_working above, and
# the difference is the whole point: a `working` verdict from `pane` is read from
# the very pane a stale wake has already found unchanged, so it cannot
# corroborate itself, while a run step is a separate process's out-of-band record
# that the pipeline moved. What counts as advancing is not decided here -
# bin/fm-crew-state.sh owns it, and reports `stalled` (which falls to `none`
# above) for a run that has stopped moving, so a hung pipeline can never satisfy
# this and still escalates.
#
# It exists for one caller shape: a stale pane already absorbed as
# provably-working, whose idle timer has now reached the wedge threshold. The
# pane being unchanged says nothing there, because a long fix step is exactly a
# quiet pane over a moving run. Carries crew_absorb_verdict's bounded read and
# its park-sighting write, so a caller must ask at most once per escalation
# window rather than every poll.
crew_run_step_advancing() {  # <id>
  [ "$(crew_absorb_verdict "$1")" = "working run-step" ]
}

# Classify a crew against Claude Code's usage-limit stall, from the SAME single
# authoritative current-state line crew_absorb_class reads. Prints one token:
#   none    - the crew is not parked on the usage-limit prompt (the common case);
#   ready   - it is parked there AND the quota authority reports the account
#             window has reset, so bin/fm-limit-resume.sh can recover it;
#   waiting - it is parked there and the window is still exhausted, which is a
#             bounded external wait that clears on its own, NOT a wedge;
#   unknown - it is parked there but the quota window could not be read, so
#             neither recovery nor a settled wait is justified; surface it.
# Detection itself is owned by bin/fm-crew-state.sh (and the signature by
# bin/fm-claude-limit-lib.sh); this is only the shared triage reading of that one
# line, so the watcher and the away-mode daemon cannot drift on what the state
# means. NOT a pure read, for the same reason crew_absorb_class is not: callers
# run it at most once per distinct stale sighting.
crew_usage_limit_class() {  # <id>
  local id=$1 line state
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = "$FM_CLASSIFY_USAGE_LIMITED_STATE" ] || { printf 'none'; return; }
  case "$line" in
    *"${FM_CLASSIFY_LIMIT_WINDOW_PREFIX}reset"*)     printf 'ready' ;;
    *"${FM_CLASSIFY_LIMIT_WINDOW_PREFIX}exhausted"*) printf 'waiting' ;;
    *)                                               printf 'unknown' ;;
  esac
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
