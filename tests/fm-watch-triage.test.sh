#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class and its crew_absorb_verdict primitive: the single
# fm-crew-state.sh read that returns EVERY absorb reason - working (active run/busy
# pane), paused (declared external wait), unreliable (a verdict that is evidence of
# nothing either way), or none (surface it), each with the evidence source that
# produced it - so the watcher's stale path gets them all for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does, and
# neither treats `unreliable` as absorbable on its own: only a caller with its own
# independent reason to believe the crew is fine (the declared-pause path) may.
test_crew_absorb_class_classifier() {
  local dir fakebin STATE
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  # Pinned to this case's own state dir: the classes gated on a task file (a
  # landing route, an open decision) must read an empty fixture here, not
  # whatever the ambient home happens to hold.
  # shellcheck disable=SC2034 # Read by _fm_classify_state_dir in the callees below.
  STATE="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  # A failed RUN-STEP verdict describes a no-mistakes run, which executes in
  # no-mistakes' own bare repo - it is not evidence this crew stopped, and it is a
  # documented misread (a superseded earlier run answering for a live fresh one).
  # It is `unreliable`, distinct from a confidently not-working verdict, and it is
  # still absorbable by NOBODY on its own.
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_absorb_class a)" = unreliable ] || fail "a failed run-step verdict not classed unreliable"
  ! crew_is_provably_working a || fail "an unreliable verdict treated as provably working"
  ! crew_is_paused a || fail "an unreliable verdict treated as a declared pause"
  # The neighbouring verdicts stay confidently not-working: a failed STATUS LOG line
  # is the crew's own report, a parked run is waiting on the crew to answer a gate,
  # and a finished run means the work is done - all must still surface.
  FM_FAKE_CREW_STATE='state: failed · source: status-log · failed: the build broke'
  [ "$(crew_absorb_class a)" = none ] || fail "a crew's own failed: report classed unreliable"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)'
  [ "$(crew_absorb_class a)" = none ] || fail "a run parked at a gate classed unreliable"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  [ "$(crew_absorb_class a)" = none ] || fail "a finished run classed unreliable"
  # The verdict primitive also reports WHICH evidence produced the class, because
  # the two ways to be `working` are not equally strong: only the run-step one is
  # out-of-band. A line with no source: field must report `none`, never leak the
  # state word as if it were a source.
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_verdict a)" = "working run-step" ] || fail "run-step working verdict lost its source"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_verdict a)" = "working pane" ] || fail "pane working verdict lost its source"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_absorb_verdict a)" = "unreliable run-step" ] || fail "unreliable verdict lost its source"
  FM_FAKE_CREW_STATE='state: working'
  [ "$(crew_absorb_verdict a)" = "none none" ] || fail "a sourceless line leaked a bogus source"
  [ "$(crew_absorb_verdict "")" = "none none" ] || fail "empty id not classed none none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/unreliable/none from one read, and the verdict keeps its evidence source"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- landing route (a finished crew whose PR is waiting on the captain) -----
#
# Arms a REAL merge poll for <id> in the case's state dir through
# bin/fm-pr-check.sh, so the landing-route predicate is tested against the exact
# artifacts the watcher's own check dispatcher validates, not a hand-built
# lookalike. The fake gh serves the head lookup only; nothing reaches a network.
arm_landing_route() {  # <case-dir> <id> [<pr-url>]
  local dir=$1 id=$2 url=${3:-https://github.com/example/repo/pull/7}
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/gh"
  fm_write_meta "$dir/state/$id.meta" "window=test:fm-$id" "worktree=$dir/wt" "kind=ship"
  chmod 0600 "$dir/state/$id.meta"
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "$url" >/dev/null \
    || fail "could not arm a merge poll fixture for $id"
}

# A terminal `done` verdict absorbs ONLY when the work has somewhere to land and
# an armed merge poll will report it landing. Both directions, because absorbing
# a `done` with no landing route would hide a crew that stopped with nowhere to
# go - the one thing this class must never do.
test_landing_absorb_class_classifier() {
  local dir state STATE
  dir=$(make_case landing-class); state="$dir/state"
  # Dynamically scoped for the classifier under test: fm-classify-lib.sh resolves
  # its task-file reads against STATE first, exactly as the watcher sets it.
  # shellcheck disable=SC2034 # Read by _fm_classify_state_dir in the callees below.
  STATE=$state
  export FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: done · source: status-log · PR https://example.test/pr/7 checks green'

  # No landing route at all: not even a recorded pr=.
  fm_write_meta "$state/nowhere.meta" "window=test:fm-nowhere" "kind=ship"
  [ "$(crew_absorb_class nowhere)" = none ] \
    || fail "a done crew with no landing route was absorbed"

  # Recorded pr= and an armed merge poll: the poll owns the next wake.
  arm_landing_route "$dir" lands
  grep -q '^pr=' "$state/lands.meta" || fail "the fixture recorded no pr="
  [ -f "$state/lands.check.sh" ] || fail "the fixture armed no merge poll"
  [ "$(crew_absorb_class lands)" = landing ] \
    || fail "a finished crew with an armed merge poll was not classed landing"
  [ "$(crew_absorb_verdict lands)" = "landing status-log" ] \
    || fail "the landing verdict lost its evidence source"
  crew_is_provably_working lands \
    && fail "a landing crew was reported as provably working"
  crew_is_paused lands && fail "a landing crew was reported as a declared pause"

  # A recorded pr= whose poll is gone is a landing route with nothing left to
  # report it, so it must surface again rather than stay silent forever.
  rm -f "$state/lands.check.sh"
  [ "$(crew_absorb_class lands)" = none ] \
    || fail "a recorded pr= with no armed poll was still absorbed"

  # Only a terminal done qualifies; the other verdicts keep their own classes.
  arm_landing_route "$dir" other
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)'
  [ "$(crew_absorb_class other)" = none ] || fail "a parked run was classed landing"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_absorb_class other)" = unreliable ] || fail "a failed run-step verdict was classed landing"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class other)" = working ] || fail "an active run was classed landing"

  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: a terminal done is landing only with a recorded route and an armed merge poll"
}

# The armed-poll test is a READ, and it is taken while a caller may be holding
# the FM_PR_* globals for the very poll being classified. Sourced into the
# caller's own shell instead of a subshell, fm-pr-lib.sh's parse would overwrite
# that caller's record with the classified task's - so the poll it goes on to run
# would be a different PR from the one it validated.
test_landing_probe_does_not_clobber_a_callers_pr_globals() {
  local dir state STATE readings before after
  dir=$(make_case landing-globals); state="$dir/state"
  # shellcheck disable=SC2034 # Read by _fm_classify_state_dir in the callee.
  STATE=$state
  export FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: done · source: status-log · PR https://example.test/pr/7 checks green'
  # The probed task's own route is a different PR from the caller's below, so a
  # clobber cannot pass by looking identical.
  arm_landing_route "$dir" probed
  readings=$(
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_url_parse "https://github.com/example/other/pull/91" || exit 1
    printf '%s|%s|%s|%s\n' "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
    [ "$(crew_absorb_class probed)" = landing ] || exit 1
    printf '%s|%s|%s|%s\n' "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
  ) || fail "the landing-route probe fixture did not reach the landing class"
  before=$(printf '%s' "$readings" | sed -n 1p)
  after=$(printf '%s' "$readings" | sed -n 2p)
  [ "$before" = "$after" ] \
    || fail "the landing probe clobbered the caller's PR record: $before -> $after"
  unset FM_FAKE_CREW_STATE
  pass "the landing-route probe leaves a caller's own PR record untouched"
}

# --- outstanding decision (a crew parked on an answer only firstmate can give) ---
#
# A parked run absorbs ONLY while the decision it is parked on is still recorded
# as open, and both directions are asserted here because the gate is the whole
# safety property: absorbing a parked crew whose decision has already been
# answered would hide a worker that failed to act on the answer.
#
# The CLOSED-decision direction is only assertable at this level. In the watcher,
# a parked crew reaches the deciding arm only through the terminal-stale branch,
# whose own gate requires the crew's last line to be the `needs-decision` it is
# parked on - and a last line with that verb always leaves a decision open, so
# the answered case cannot be constructed there at all. The watcher tests below
# own the gates that ARE reachable there instead: a newer captain-relevant line,
# a park at a gate the worker itself must answer, and the run-less status-log
# `parked` fallback.
test_deciding_absorb_class_classifier() {
  local dir state STATE
  dir=$(make_case deciding-class); state="$dir/state"
  # Dynamically scoped for the classifier under test, exactly as the watcher sets
  # it; see test_landing_absorb_class_classifier.
  # shellcheck disable=SC2034 # Read by _fm_classify_state_dir in the callees below.
  STATE=$state
  export FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision) (status not from an earlier park)'

  # Parked with the decision still open: the answer owns the next wake.
  printf 'working: implementing\nneeds-decision [key=seat-scope]: per-tenant or per-seat billing\n' \
    > "$state/waiting.status"
  [ "$(crew_absorb_class waiting)" = deciding ] \
    || fail "a run parked on an open decision was not classed deciding"
  [ "$(crew_absorb_verdict waiting)" = "deciding run-step" ] \
    || fail "the deciding verdict lost its evidence source"
  crew_is_provably_working waiting && fail "a deciding crew was reported as provably working"
  crew_is_paused waiting && fail "a deciding crew was reported as a declared pause"

  # Answered: an idle pane past this point is a worker that failed to act.
  printf 'resolved [key=seat-scope]: captain chose per-tenant\n' >> "$state/waiting.status"
  [ "$(crew_absorb_class waiting)" = none ] \
    || fail "a parked crew whose decision was answered was still absorbed"

  # A verified captain-held backlog transfer closes it the same way.
  printf 'needs-decision [key=route]: which forge to target\n' > "$state/held.status"
  [ "$(crew_absorb_class held)" = deciding ] || fail "a keyed open decision was not classed deciding"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' >> "$state/held.status"
  [ "$(crew_absorb_class held)" = none ] \
    || fail "a decision transferred to the backlog was still absorbed as outstanding"

  # The historical unkeyed form folds on the default key, both ways.
  printf 'needs-decision: which forge to target\n' > "$state/bare.status"
  [ "$(crew_absorb_class bare)" = deciding ] || fail "an unkeyed open decision was not classed deciding"
  printf 'resolved: captain chose GitHub\n' >> "$state/bare.status"
  [ "$(crew_absorb_class bare)" = none ] || fail "an unkeyed resolved line did not close the decision"

  # Parked waiting for nothing: no decision was ever recorded, so firstmate does
  # not know what this crew is waiting for and must see it.
  printf 'working: implementing\n' > "$state/nothing.status"
  [ "$(crew_absorb_class nothing)" = none ] \
    || fail "a parked crew with no recorded decision was absorbed"
  [ "$(crew_absorb_class missing)" = none ] \
    || fail "a parked crew with no status file at all was absorbed"

  # Gate ownership. The fold records a decision for the whole TASK while the park
  # is a fact about ONE gate, so an open key on its own must not absorb: this crew
  # keeps its decision open throughout, and only the parked line changes.
  printf 'needs-decision [key=seat-scope]: per-tenant or per-seat billing\n' > "$state/correlate.status"
  [ "$(crew_absorb_class correlate)" = deciding ] || fail "the ownership fixture did not start absorbable"

  # A gate whose findings carry no ask-user row at all is one the worker answers,
  # so it earns no ownership token and nothing here says anyone else owes this
  # crew an answer. Which run shapes earn the token is bin/fm-crew-state.sh's
  # rule; tests/fm-crew-state.test.sh owns that half. The park-episode token is
  # spelled here deliberately - the producer never emits it alone, and this pins
  # that even if one did, it would earn nothing without the ownership token.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (status not from an earlier park)'
  [ "$(crew_absorb_class correlate)" = none ] \
    || fail "a park at a worker-owned gate was absorbed as an outstanding decision"

  # The park-episode gate, the one that keeps a widened ownership rule from
  # reopening the silence-forever path. Everything about the TASK is satisfied -
  # the run is parked, the gate is authority-owned, the decision is open - but
  # bin/fm-crew-state.sh withheld the park-episode token, which it does only when
  # the park clock PROVES the crew's record predates this episode: the open
  # decision belongs to an episode already answered and the crew never said a
  # word about the gate it is sitting at now. Absorbing that leaves no timer and
  # no other wake owner.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision)'
  [ "$(crew_absorb_class correlate)" = none ] \
    || fail "a park the crew never wrote about was absorbed as an outstanding decision"

  # A park whose gate ownership bin/fm-crew-state.sh could not establish carries
  # its operator note instead of the ownership token. The note reports what the
  # findings table shows and claims nothing about who answers, so it must leave
  # this verdict exactly where the bare line above left it.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) [ask-user finding, authority gate unconfirmed]'
  [ "$(crew_absorb_class correlate)" = none ] \
    || fail "the operator ask-user note was read as the gate-ownership token"

  # The run-less fallback derives `parked` from the very `needs-decision:` line
  # this fold reads, so it correlates nothing with nothing. Its detail is the
  # crew's own note, spelled here to repeat the ownership token verbatim: that is
  # exactly why the source is gated rather than the token alone.
  FM_FAKE_CREW_STATE='state: parked · source: status-log · review escalated an (ask-user: authority decision) finding'
  [ "$(crew_absorb_class correlate)" = none ] \
    || fail "a status-log parked fallback was absorbed as an outstanding decision"

  # An open decision does not make any OTHER verdict absorbable: the class is
  # a correlated `parked` plus the record, never the record alone.
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  [ "$(crew_absorb_class correlate)" = none ] || fail "an open decision made a done crew absorbable"
  FM_FAKE_CREW_STATE='state: stalled · source: run-step · review step quiet for 40m'
  [ "$(crew_absorb_class correlate)" = none ] || fail "an open decision made a stalled run absorbable"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  [ "$(crew_absorb_class correlate)" = unreliable ] || fail "an open decision reclassed a failed run-step verdict"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class correlate)" = working ] || fail "an open decision reclassed an active run"

  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: a parked run is deciding only while an authority decision it is parked on is open"
}

# --- stale pane, finished work awaiting merge: absorbed with NO wedge timer ---
# Observed live 2026-08-20: the crew appended `done: PR <url> checks green` and
# stopped, exactly as instructed. Its pane is therefore idle for as long as the
# captain takes over the PR, and the stale path raised a wake every escalation
# window - overnight included. The merge poll already covers this task, so the
# stale timer must not run at all here.
test_finished_awaiting_merge_absorbed_without_a_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case landing-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-landed"
  printf 'PR opened, checks green' > "$capture_file"
  arm_landing_route "$dir" landed
  printf 'done: PR https://github.com/example/repo/pull/7 checks green\n' > "$state/landed.status"
  sig=$(seen_sig "$state/landed.status"); printf '%s' "$sig" > "$state/.seen-landed_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "PR opened, checks green")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: status-log · PR https://github.com/example/repo/pull/7 checks green'

  # A one-second escalation threshold: were a wedge timer started at all, the
  # watcher would surface within a couple of polls.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 60; then
    reap "$pid"; fail "watcher surfaced a finished crew whose PR is waiting on the captain: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the finished-awaiting-merge absorb printed a wake reason"
  [ ! -s "$state/.wake-queue" ] || fail "the finished-awaiting-merge absorb enqueued a wake"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "stale suppressor not advanced on the landing absorb"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "a wedge timer was started for work that is only waiting on the captain"
  [ ! -e "$state/.hb-surfaced-landed" ] || fail "an absorbed wake marked the status line surfaced"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a finished crew whose PR is waiting on the captain is absorbed, with no wedge timer"
}

# The other direction, and the reason the class is gated: a crew that stopped on
# `done` with NO landing route recorded really has nowhere to go, and firstmate
# must see it. Same status line, same idle pane, no pr= and no armed poll.
test_finished_with_no_landing_route_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case landing-stale-none); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stranded"
  printf 'PR opened, checks green' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stranded.meta"
  printf 'done: PR https://github.com/example/repo/pull/7 checks green\n' > "$state/stranded.status"
  sig=$(seen_sig "$state/stranded.status"); printf '%s' "$sig" > "$state/.seen-stranded_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "PR opened, checks green")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: status-log · PR https://github.com/example/repo/pull/7 checks green'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a finished crew with nowhere to land was not surfaced"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the stranded crew"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stranded stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the stranded stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a finished crew with no landing route recorded still surfaces"
}

# The third direction: the RUN is done and the merge poll is armed, but the crew
# has since appended a captain-relevant line of its own. That crew is not waiting
# on the captain to merge, it is waiting on the captain to answer, and the merge
# poll it would hand the wake to fires only on `merged` - so a conflicted or
# closed PR would leave it silent forever. It must surface exactly as it did
# before the landing class existed.
test_post_run_decision_on_a_landing_route_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case landing-stale-blocked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-conflicted"
  printf 'PR opened, checks green' > "$capture_file"
  arm_landing_route "$dir" conflicted
  grep -q '^pr=' "$state/conflicted.meta" || fail "the fixture recorded no pr="
  [ -f "$state/conflicted.check.sh" ] || fail "the fixture armed no merge poll"
  printf 'blocked: PR has a merge conflict with main\n' > "$state/conflicted.status"
  sig=$(seen_sig "$state/conflicted.status"); printf '%s' "$sig" > "$state/.seen-conflicted_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "PR opened, checks green")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a post-run blocked line on a landing route was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the blocked crew"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the blocked stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the blocked stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain-relevant line appended after the run finished still surfaces on a landing route"
}

# --- stale pane, parked on an open decision: absorbed with NO wedge timer ---
# Observed live 2026-08-30: a crew parked at a review gate on an ask-user finding,
# escalated to the captain, correctly reported `parked` throughout. It cannot
# proceed until the answer comes back, so its pane is idle for exactly as long as
# that takes, and the stale path raised a wake every escalation window.
test_parked_on_open_decision_absorbed_without_a_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case deciding-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked.meta"
  printf 'needs-decision [key=seat-scope]: per-tenant or per-seat billing\n' > "$state/parked.status"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision) (status not from an earlier park)'

  # A one-second escalation threshold: were a wedge timer started at all, the
  # watcher would surface within a couple of polls.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 60; then
    reap "$pid"; fail "watcher surfaced a crew parked on an open decision: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the parked-on-a-decision absorb printed a wake reason"
  [ ! -s "$state/.wake-queue" ] || fail "the parked-on-a-decision absorb enqueued a wake"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "stale suppressor not advanced on the deciding absorb"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "a wedge timer was started for a crew that is only waiting on an answer"
  [ ! -e "$state/.hb-surfaced-parked" ] || fail "an absorbed wake marked the status line surfaced"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a crew parked on an open decision is absorbed, with no wedge timer"
}

# The other direction at the watcher's own gate: the run is still parked and a
# decision is still open, but the crew has since said something else
# captain-relevant. It is no longer waiting quietly on that answer, and absorbing
# it would silence the newer line, so it must surface exactly as before.
test_parked_crew_with_a_newer_captain_line_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case deciding-stale-newer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-moved-on"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/moved-on.meta"
  printf 'needs-decision [key=seat-scope]: per-tenant or per-seat billing\nfailed: the validation run was cancelled\n' \
    > "$state/moved-on.status"
  sig=$(seen_sig "$state/moved-on.status"); printf '%s' "$sig" > "$state/.seen-moved-on_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision) (status not from an earlier park)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a newer captain-relevant line on a parked crew was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the moved-on crew"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the moved-on stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the moved-on stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain-relevant line newer than the decision still surfaces on a parked crew"
}

# The gate-ownership gate end to end, and the regression for an absorb that could
# otherwise go silent for good: everything the deciding arm reads about the TASK
# is satisfied - the run is parked, a decision is open, and the crew's last line
# is that `needs-decision:` - but the gate the run stopped at carries no ask-user
# finding, so it is one the WORKER itself must answer, nobody else owes this crew
# anything, and a wedge here has no other wake owner. It must surface. Whether a
# given run shape earns the ownership token is bin/fm-crew-state.sh's rule and is
# asserted against the real producer in tests/fm-crew-state.test.sh; this pins
# what the watcher does without it.
test_parked_at_a_worker_owned_gate_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash pid
  dir=$(make_case deciding-stale-worker-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-worker-gate"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/worker-gate.meta"
  printf 'needs-decision [key=seat-scope]: per-tenant or per-seat billing\n' > "$state/worker-gate.status"
  printf '%s' "$(seen_sig "$state/worker-gate.status")" > "$state/.seen-worker-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a crew parked at a worker-owned gate was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the worker-owned gate"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the worker-gate stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the worker-gate stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a crew parked at a gate it must answer itself still surfaces"
}

# The park-episode gate end to end. The gate ownership rule admits both parked
# words, which is what makes the majority `fix_review` shape absorbable at all -
# and on its own it would also admit the shape that must never be absorbed:
# firstmate answers, the worker responds to the gate, the pipeline fixes, the run
# parks again, and the worker wedges before writing anything about the new gate.
# Its old `needs-decision:` line is still the last line and still open, so every
# other gate here passes; only the crew's status record being older than this
# park episode separates the two, and without that this crew goes silent for
# good. Which run shapes publish that token is bin/fm-crew-state.sh's rule,
# asserted against the real producer in tests/fm-crew-state.test.sh.
test_parked_on_a_decision_from_an_earlier_park_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash pid
  dir=$(make_case deciding-stale-earlier-park); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-earlier-park"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/earlier-park.meta"
  printf 'needs-decision [key=review-1]: bump the revision literal or amend in place\n' \
    > "$state/earlier-park.status"
  printf '%s' "$(seen_sig "$state/earlier-park.status")" > "$state/.seen-earlier-park_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a park the crew never wrote about was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the earlier-park decision"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the earlier-park stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the earlier-park stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a crew parked on a decision from an earlier park episode still surfaces"
}

# The guard on the operator note bin/fm-crew-state.sh puts on a park whose gate
# ownership it could not establish. That note and the ownership token must stay
# textually disjoint, because this verdict matches the token as a plain
# substring of the whole line: were the note ever to contain it, every park the
# producer deliberately refused to call authority-owned would absorb here
# instead. This drives the real watcher end to end so the guard is behavioural
# rather than a reading of the two literals.
test_the_operator_note_is_inert_to_the_absorb_classifier() {
  local dir state fakebin out drain_out capture_file window key pane_hash pid
  dir=$(make_case deciding-stale-operator-note); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-note-only"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/note-only.meta"
  printf 'needs-decision [key=seat-scope]: per-tenant or per-seat billing\n' > "$state/note-only.status"
  printf '%s' "$(seen_sig "$state/note-only.status")" > "$state/.seen-note-only_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) [ask-user finding, authority gate unconfirmed]'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a park carrying only the operator ask-user note was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the operator-note park"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the operator-note stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the operator-note stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "the operator ask-user note never earns the absorb the ownership token earns"
}

# The other half of the same gate: a crew with no run attributed at all, whose
# `parked` is read straight off the very `needs-decision:` line the fold then
# calls open. The verdict's detail is the crew's own note, spelled here to repeat
# the ownership token verbatim, so this case can only surface because the SOURCE
# is gated.
test_parked_from_the_status_log_fallback_still_surfaces() {
  local dir state fakebin out drain_out capture_file window key pane_hash pid
  dir=$(make_case deciding-stale-log-source); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-log-parked"
  printf 'awaiting a decision on 2 findings' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/log-parked.meta"
  printf 'needs-decision [key=seat-scope]: review escalated an (ask-user: authority decision) finding\n' \
    > "$state/log-parked.status"
  printf '%s' "$(seen_sig "$state/log-parked.status")" > "$state/.seen-log-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "awaiting a decision on 2 findings")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: status-log · review escalated an (ask-user: authority decision) finding'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a status-log parked fallback was absorbed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "no stale wake was printed for the status-log fallback"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the status-log stale failed"
  grep -F "$window" "$drain_out" >/dev/null || fail "the status-log fallback stale was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a crew whose parked verdict comes from its own status log still surfaces"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- an unreliable verdict WITHOUT a declared pause still surfaces at once ----
# The blast-radius boundary of the `unreliable` class. It exists so a crew's own
# declared wait is not overruled by a verdict that is evidence of nothing - it is
# NOT a general softening of the stopped-crew path. A crew that never declared a
# wait has offered no independent reason to believe it is fine, so a failed
# run-step verdict must class exactly as it always did and surface immediately
# rather than being absorbed onto the wedge timer. Without this, introducing the
# class would have quietly delayed every stopped no-mistakes crew by the wedge
# threshold - trading real detection for quiet on a path this change never
# intended to touch.
test_unreliable_verdict_without_declared_pause_surfaced() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case unreliable-no-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-unreliable-nopause"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/unreliable-nopause.meta"
  # A plain non-terminal status: the crew never declared a pause.
  printf 'working: implementing\n' > "$state/unreliable-nopause.status"
  sig=$(seen_sig "$state/unreliable-nopause.status")
  printf '%s' "$sig" > "$state/.seen-unreliable-nopause_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The same verdict the declared-pause path treats as unreliable, and a live
  # endpoint besides - so only the ABSENT pause declaration withholds the softening.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || { reap "$pid"; fail "an unreliable verdict with no declared pause was absorbed instead of surfaced: $(cat "$out")"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "no declared pause: unreliable verdict did not print the immediate stale wake: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "no declared pause: unreliable verdict was put on the wedge timer instead of surfacing"
  unset FM_FAKE_CREW_STATE
  pass "an unreliable run verdict with NO declared pause still surfaces immediately (the class does not leak)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# --- a pause that knows when its wait ends -----------------------------------
# The 2026-07-29/30 follow-on: crews parked on Claude Code's usage-limit prompt
# were paused correctly, but the account window rolled about forty minutes into
# the hour-long recheck cadence and they stayed parked until it came due. A pause
# whose end time is known (state/<id>.pause-recheck, written by fm-limit-resume.sh
# from the quota window's reported reset) is rechecked at that instant instead.
# It only ever fires EARLIER - here the fixed cadence is set far out of reach, so
# nothing but the deadline can produce the wake - and it is ONE-SHOT, cleared as
# it fires so an elapsed deadline cannot re-fire on every poll.
test_paused_stale_resurfaces_at_its_recorded_deadline() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid statusf
  dir=$(make_case paused-deadline); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-limited"
  printf 'idle, parked on the usage-limit prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/limited.meta"
  statusf="$state/limited.status"
  printf 'paused: claude usage limit reached; waiting for the account window to reset\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-limited_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, parked on the usage-limit prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · claude usage limit reached'

  # Phase A: the window has not rolled yet. The deadline is real but in the
  # future, so this must stay absorbed - a scheduled recheck is one well-timed
  # read, not a reason to poll.
  printf '%s\n' "$(( $(date +%s) + 3000 ))" > "$state/limited.pause-recheck"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a pause whose recheck is still ahead: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a pause whose recheck is still ahead produced a wake"
  [ -e "$state/limited.pause-recheck" ] || fail "a future recheck deadline was consumed early"
  reap "$pid"

  # Phase B: the window has rolled. The status file is untouched and the fixed
  # cadence is still unreachable, so only the deadline can fire this.
  printf '%s\n' "$(( $(date +%s) - 30 ))" > "$state/limited.pause-recheck"
  : > "$out"
  printf 'idle, parked on the usage-limit prompt (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "the watcher did not recheck a pause whose reported end time had arrived"
  grep -F "stale: $window" "$out" >/dev/null || fail "the deadline recheck did not print a stale wake"
  grep -F "reported end time has arrived" "$out" >/dev/null \
    || fail "the deadline recheck was not named as the wait's end time arriving"
  grep -F "possible wedge" "$out" >/dev/null && fail "a scheduled pause recheck was mislabeled a possible wedge"
  [ ! -e "$state/limited.pause-recheck" ] \
    || fail "the deadline was not consumed, so it would re-fire on every poll"
  [ ! -e "$state/.stale-since-$key" ] || fail "a scheduled pause recheck must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the deadline recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the deadline recheck was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a pause whose reported end time has arrived is rechecked immediately, once, without touching the wedge path"
}

# A deadline belongs to the ONE pause it was recorded for. Recovery does not have
# to run through fm-limit-resume.sh - a human can dismiss the prompt in the pane -
# so the deadline is dropped by clear_pause_tracking alongside every other pause
# artifact the moment the crew stops declaring the pause. Without that, a deadline
# from a usage-limit wait outlives it and makes the watcher tell the captain that
# some later, unrelated wait "reported an end time" it never reported.
test_resumed_pause_drops_its_recheck_deadline() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case paused-deadline-cleared); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-resumed"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/resumed.meta"
  statusf="$state/resumed.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # The crew was parked on the usage-limit prompt and the pause carried a recheck
  # deadline. A human dismissed the prompt, so the crew resumed on its own and
  # fm-limit-resume.sh - the deadline's only writer - never ran again.
  printf 'paused: claude usage limit reached; waiting for the account window to reset\nworking: resumed after the prompt was dismissed by hand\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-resumed_status"
  : > "$state/.paused-$key"
  printf 'crunching... (esc to interrupt)\n' > "$capture_file"
  printf '%s\n' "$(( $(date +%s) - 30 ))" > "$state/resumed.pause-recheck"
  export FM_FAKE_CREW_STATE='state: working · source: status-log · resumed'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a crew that simply resumed: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "pause tracking survived the resume"; }
  [ ! -e "$state/resumed.pause-recheck" ] \
    || { reap "$pid"; fail "the recheck deadline outlived the pause it was recorded for"; }
  reap "$pid"

  # Later, the same task declares an unrelated wait that reported no end time.
  # With the fixed cadence out of reach, nothing may fire - a surviving deadline
  # would surface it now, wrongly named as that wait's end time arriving.
  printf 'paused: waiting on review\n' >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-resumed_status"
  printf 'idle awaiting review\n' > "$capture_file"
  : > "$out"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on review'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a later unrelated pause was surfaced against a dead deadline: $(cat "$out")"
  fi
  reap "$pid"
  grep -F "reported end time has arrived" "$out" >/dev/null \
    && fail "a wait that reported no end time was rechecked as though it had"
  [ ! -s "$out" ] || fail "a later unrelated pause produced a wake with no deadline and no cadence due"
  unset FM_FAKE_CREW_STATE
  pass "a recheck deadline is dropped with the rest of its pause, so it cannot fire against a later unrelated wait"
}

# The other half of the same invariant: a deadline survives as long as its pause
# does. Turning AFK on mid-wait hands this pause to the daemon, and the watcher
# drops its own normal-mode pause tracking on the way - but the deadline is not
# watcher bookkeeping the next poll re-derives, it is the quota read's only
# record of when this wait ends. Taking it here would put away mode back on
# FM_PAUSE_RESURFACE_SECS, which is the exact latency this schedule removes and
# the mode where waiting out a quota window is most likely.
test_afk_handoff_keeps_a_live_pause_deadline() {
  local dir state fakebin out capture_file statusf window key sig pid back deadline
  dir=$(make_case afk-handoff-deadline); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-limited"
  printf 'idle, parked on the usage-limit prompt\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/afk-limited.meta"
  statusf="$state/afk-limited.status"
  printf 'paused: claude usage limit reached; waiting for the account window to reset\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-limited_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # The state a normal-mode watcher leaves behind: it already absorbed this pause
  # once (.paused-<key>), and the wait carries a reset still forty minutes out.
  : > "$state/.paused-$key"
  deadline=$(( $(date +%s) + 2400 ))
  printf '%s\n' "$deadline" > "$state/afk-limited.pause-recheck"

  # The captain then goes AFK. No seeded .hash-*, so the first poll takes the
  # changed-pane branch, where AFK alone routes past the pause handling into
  # clear_pause_tracking with the pause still fully declared.
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · claude usage limit reached' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK handoff of a paused pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "AFK handoff did not preserve the plain window identity: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher kept normal-mode pause tracking instead of handing off"
  [ -e "$state/afk-limited.pause-recheck" ] \
    || fail "the AFK handoff took a recheck deadline that still belongs to a declared pause"
  [ "$(cat "$state/afk-limited.pause-recheck")" = "$deadline" ] \
    || fail "the recheck deadline was rewritten during the AFK handoff"
  pass "handing a still-declared pause to the daemon leaves its recheck deadline intact"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 15; then reap "$pid"; else wait "$pid" || fail "dead-agent watcher round $round failed"; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "live external-decision gate did not surface immediately"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -eq 1 ] || fail "live external-decision gate should surface once, got $wakes wakes"
  [ "$bare" -eq 1 ] || fail "live external-decision gate lost its immediate bare stale surface"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "authoritative working state did not wedge-escalate past the threshold"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer and escalates"
}

# --- the declared pause is graded against the endpoint, not taken on faith -----
# THE case this whole reconciliation must never lose. A no-mistakes run executes in
# no-mistakes' own bare repo, so a run that keeps progressing says nothing about
# whether the crew that started it is still alive: on 2026-07-29 three crews sat
# stopped on Claude Code's usage-limit prompt for ~8.7 hours while their runs read
# `running`. A declared pause is a claim, and a stale pause line is exactly what a
# dead crew leaves behind, so pairing "the pipeline is moving" with a dead endpoint
# must STILL wedge-escalate. This test fails the moment that detection is traded
# away for quieter alarms.
test_paused_progressing_run_with_dead_endpoint_still_wedge_escalates() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case paused-dead-endpoint-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-dead"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/paused-dead.meta"
  printf 'paused: handed a fix round back to the pipeline\n' > "$state/paused-dead.status"
  sig=$(seen_sig "$state/paused-dead.status"); printf '%s' "$sig" > "$state/.seen-paused-dead_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  # A bare login shell in the pane is a CONFIDENTLY dead agent, while the run-step
  # verdict still reports an actively-running pipeline.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || { reap "$pid"; fail "a declared pause whose endpoint is dead did not wedge-escalate: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "dead-endpoint pause escalation omitted its possible-wedge reason: $(cat "$out")"
  grep -F "$(printf '\tstale\t')" "$state/.wake-queue" >/dev/null \
    || fail "dead-endpoint pause escalation was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause whose pipeline progresses behind a DEAD endpoint still wedge-escalates"
}

# --- the pipeline-handoff case the pause verb exists for ----------------------
# The disconfirming half of the test above, and the defect this change removes: the
# crew declared a wait, its endpoint is confirmed live, and its pipeline is
# demonstrably still moving. That is the strongest evidence of health this watcher
# can assemble, yet it used to be alarmed on four times harder (STALE_ESCALATE_SECS)
# than a declared pause with a DEAD endpoint, which already got the long cadence.
# It now takes the same bounded pause cadence - the residual wedge timer must be
# discarded, not fired, even when it is already well past the threshold.
test_paused_progressing_run_with_live_endpoint_uses_pause_cadence() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case paused-live-endpoint-cadence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-live"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/paused-live.meta"
  printf 'paused: handed a fix round back to the pipeline\n' > "$state/paused-live.status"
  sig=$(seen_sig "$state/paused-live.status"); printf '%s' "$sig" > "$state/.seen-paused-live_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "a declared pause with a live endpoint and a progressing run was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "live-endpoint pause printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "live-endpoint pause enqueued a wake"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live-endpoint pause lost its bounded-cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live-endpoint pause retained the wedge timer"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause with a live endpoint and a progressing pipeline takes the pause cadence, not the wedge timer"
}

# --- the bounded pause cadence stays cheap across polls -----------------------
# fm-crew-state.sh may shell out to a bounded no-mistakes call, so fm-classify-lib.sh's
# contract is that the absorb classification runs on first sighting of a stale hash,
# never on every wake. The handoff route above re-absorbs the SAME unchanged pane on
# every poll for as long as the wait holds, so it has to carry that contract itself:
# it memoizes the endpoint reading that earned the cadence in .paused-rechecked-<key>
# and, while that memo is young and the endpoint still reads alive, re-absorbs on the
# cheap liveness probe alone. The memo still expires after STALE_ESCALATE_SECS, so a
# crew whose run has since stopped supporting the handoff is re-read - and lands back
# on the wedge timer - within the ordinary threshold.
test_paused_handoff_cadence_memoizes_its_crew_state_read() {
  local dir state fakebin out capture_file window key pane_hash sig pid log calls i
  dir=$(make_case paused-handoff-memo); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-memo"
  log="$dir/crew-state-calls.log"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/paused-memo.meta"
  printf 'paused: handed a fix round back to the pipeline\n' > "$state/paused-memo.status"
  sig=$(seen_sig "$state/paused-memo.status"); printf '%s' "$sig" > "$state/.seen-paused-memo_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  : > "$log"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude FM_FAKE_CREW_STATE_LOG="$log" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ "$(cat "$state/.paused-rechecked-$key" 2>/dev/null || true)" = handoff ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.paused-rechecked-$key" 2>/dev/null || true)" = handoff ] \
    || { reap "$pid"; fail "the pipeline-handoff pause recorded no reusable recheck memo: $(cat "$out")"; }
  calls=$(wc -l < "$log" | tr -d '[:space:]')
  sleep 3
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a memoized handoff pause exited instead of absorbing: $(cat "$out")"; }
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = "$calls" ] \
    || { reap "$pid"; fail "repeat polls of an unchanged handoff pause re-read crew state"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "memoized handoff pause lost its bounded-cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "memoized handoff pause acquired a wedge timer"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "memoized handoff pause printed a wake reason: $(cat "$out")"; }
  reap "$pid"

  # An expired memo buys nothing: the verdict is read again, and one that no longer
  # supports the handoff goes straight back to the ordinary wedge timer.
  printf 'handoff' > "$state/.paused-rechecked-$key"
  touch -t 200001010000 "$state/.paused-rechecked-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$log"
  : > "$out"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude FM_FAKE_CREW_STATE_LOG="$log" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || { reap "$pid"; fail "an expired handoff memo kept absorbing a pause its verdict no longer supports: $(cat "$out")"; }
  [ -s "$log" ] || fail "an expired handoff memo was reused without re-reading crew state"
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "a re-read handoff pause that lost its run-step evidence omitted its possible-wedge reason: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a handoff pause memoizes its verdict across polls and re-reads it once the memo expires"
}

# --- a busy PANE cannot corroborate its own stale pane -----------------------
# The boundary of the test above, and the reason the pause cadence is granted on
# run-step evidence alone. A `working` verdict sourced from the PANE says only that
# the pane still matches its harness's busy signature - read from the very pane this
# wake already found unchanged. A frozen agent leaves exactly that: a live process,
# an unchanged pane, and a busy banner that never advances. Out-of-band evidence (a
# separate process's record that the run advanced) can override the wedge timer;
# the suspect pane cannot vouch for itself, so this combination keeps the ordinary
# threshold it has always had. Guarding the widest plausible reading of "the
# pipeline is progressing" is what stops this change from trading wedge detection
# for quiet.
test_paused_busy_pane_verdict_still_wedge_escalates() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case paused-busy-pane-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-pane"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/paused-pane.meta"
  printf 'paused: handed a fix round back to the pipeline\n' > "$state/paused-pane.status"
  sig=$(seen_sig "$state/paused-pane.status"); printf '%s' "$sig" > "$state/.seen-paused-pane_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  # A CONFIRMED-live endpoint, so liveness is not what withholds the long cadence
  # here - the pane-sourced evidence is.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || { reap "$pid"; fail "a declared pause corroborated only by a busy pane did not wedge-escalate: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "busy-pane pause escalation omitted its possible-wedge reason: $(cat "$out")"
  grep -F "$(printf '\tstale\t')" "$state/.wake-queue" >/dev/null \
    || fail "busy-pane pause escalation was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause whose only corroboration is its own busy pane still wedge-escalates"
}

# --- a verdict that is evidence of nothing may not un-declare a pause ---------
# The observed 2026-07-30 shape: a crew whose last status was `paused: fresh
# validation run started on recovered branch` had fm-crew-state report `state:
# failed - source: run-step - run failed` from the run a usage limit had killed,
# while the live run was healthy and mid-review. A failed run-step verdict is a
# statement about a RUN, and a documented misread besides, so it must not surface a
# declared pause as a stopped crew on every new stale hash. It buys no long cadence
# either: the pane goes on the ordinary wedge timer, so one that really is frozen
# still escalates on the ordinary threshold.
test_paused_unreliable_run_verdict_absorbed_then_wedge_escalates() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case paused-unreliable-verdict); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-superseded"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/paused-superseded.meta"
  printf 'paused: fresh validation run started on recovered branch\n' > "$state/paused-superseded.status"
  sig=$(seen_sig "$state/paused-superseded.status"); printf '%s' "$sig" > "$state/.seen-paused-superseded_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'

  # Phase A: a NEW stale hash - the exact path that used to surface a bare stale
  # wake every time this crew's pane changed and settled again.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 40 \
    || { reap "$pid"; fail "an unreliable verdict under a declared pause did not start the wedge timer: $(cat "$out")"; }
  kill -0 "$pid" 2>/dev/null \
    || { reap "$pid"; fail "an unreliable verdict surfaced a declared pause as a stopped crew: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "unreliable-verdict pause enqueued a wake on first sight"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "unreliable-verdict pause did not advance its stale suppressor"; }
  reap "$pid"

  # Phase B: the same pane, timer already past the threshold. Detection is intact -
  # a paused pane that really is frozen still escalates.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || { reap "$pid"; fail "a frozen paused pane with an unreliable verdict never escalated: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "unreliable-verdict escalation omitted its possible-wedge reason: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "an unreliable run verdict cannot un-declare a pause, but a frozen paused pane still wedge-escalates"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_landing_absorb_class_classifier
test_landing_probe_does_not_clobber_a_callers_pr_globals
test_deciding_absorb_class_classifier
test_signal_crew_provably_working_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_finished_awaiting_merge_absorbed_without_a_wedge_timer
test_finished_with_no_landing_route_still_surfaces
test_post_run_decision_on_a_landing_route_still_surfaces
test_parked_on_open_decision_absorbed_without_a_wedge_timer
test_parked_crew_with_a_newer_captain_line_still_surfaces
test_parked_at_a_worker_owned_gate_still_surfaces
test_parked_on_a_decision_from_an_earlier_park_still_surfaces
test_the_operator_note_is_inert_to_the_absorb_classifier
test_parked_from_the_status_log_fallback_still_surfaces
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_paused_stale_resurfaces_at_its_recorded_deadline
test_resumed_pause_drops_its_recheck_deadline
test_afk_handoff_keeps_a_live_pause_deadline
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_paused_progressing_run_with_dead_endpoint_still_wedge_escalates
test_paused_progressing_run_with_live_endpoint_uses_pause_cadence
test_paused_handoff_cadence_memoizes_its_crew_state_read
test_paused_busy_pane_verdict_still_wedge_escalates
test_paused_unreliable_run_verdict_absorbed_then_wedge_escalates
test_unreliable_verdict_without_declared_pause_surfaced
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
