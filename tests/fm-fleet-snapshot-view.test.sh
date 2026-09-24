#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .paths.status_log.last_event
    | has("age_seconds") and .age_seconds == null
  ' >/dev/null || fail "legacy event must have an explicit unknown age"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"

  local line expected_age before after emitted epoch observed
  printf 'secondmate-task\n' > "$home/secondmate-home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" \
    > "$home/secondmate-home/.fm-secondmate-parent"
  before=$(date +%s)
  FM_HOME="$home/secondmate-home" "$ROOT/bin/fm-secondmate-report.sh" \
    'done' 0123456789abcdef 'audit complete' || fail "parent report failed"
  after=$(date +%s)
  emitted=$(tail -1 "$home/state/secondmate-task.status")
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  epoch=$(status_line_at_epoch "$emitted") || fail "new parent report has unknown time"
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] \
    || fail "parent report did not record emission time"
  for line in "$emitted" 'working: legacy' 'working [at=1700000000]: timed' \
    'working [at=1700000200]: future' 'working [at=oops]: malformed'; do
    printf '%s\n\n' "$line" > "$home/state/secondmate-task.status"
    # Deliberately unrelated file age must never substitute for event age.
    touch -t 202001010000 "$home/state/secondmate-task.status"
    expected_age=null; observed=1700000100
    case "$line" in
      "$emitted") expected_age=100; observed=$((epoch + 100)) ;;
      *1700000000*) expected_age=100 ;;
    esac
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH=$observed "$SNAPSHOT" --json)
    printf '%s' "$out" | jq -e --argjson age "$expected_age" '
      .tasks[] | select(.id == "secondmate-task")
      | .paths.status_log.last_event
      | has("age_seconds") and .age_seconds == $age
        and (has("emitted_at_epoch") | not)
    ' >/dev/null || fail "event age came from something other than the record: $line"
    # parent_event age is the emission age; freshness is how old this snapshot's
    # own observation of the file is, so the 2020 mtime must show up there and
    # only there.
    printf '%s' "$out" | jq -e --argjson age "$expected_age" '
      .secondmate_current.records[] | select(.id == "secondmate-task")
      | .current.state == "unknown"
        and .parent_event.age_seconds == $age
        and (.parent_event | has("emitted_at_epoch") | not)
        and (.freshness.age_seconds | type) == "number"
        and .freshness.age_seconds > 100000000
    ' >/dev/null || fail "fallback confused event age, observation freshness, and current state: $line"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '$ touch -t 202001010000 %s\n' "$home/state/secondmate-task.status"
      printf '$ FM_HOME=%s FM_SNAPSHOT_NOW_EPOCH=%s bin/fm-fleet-snapshot.sh --json\n' "$home" "$observed"
      printf '%s' "$out" | jq '{
        last_event: (.tasks[] | select(.id == "secondmate-task") | .paths.status_log.last_event),
        secondmate: (.secondmate_current.records[] | select(.id == "secondmate-task")
          | {current, parent_event, freshness})
      }'
    fi
  done
  pass "fixture snapshot covers task rows, backlog rows, pointers, stable ordering, and emission-time event age"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_hold_buckets_are_total_and_text_blind() {
  local home fakebin out
  home=$(make_home hold-buckets)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Queued
- [ ] blocked-hold - Blocked call blocked-by: upstream-work (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] opposite-word - Opposite wording (repo: sample) (kind: captain) (hold: non-deferred release choice) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] marker-prose - Marker prose (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
  SUPERSEDED - kept only to prove prose never classifies.
- [ ] upstream-work - Land the upstream change (repo: sample) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"     FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.structured and .hold_kind == "captain")]
    | length == 7
      and all(.hold_bucket as $bucket
              | ["live", "blocked", "dated", "aged"] | index($bucket) != null)
  ' >/dev/null || fail "every captain hold must land in exactly one structured bucket: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "blocked-hold")][0].hold_bucket == "blocked")
      and ([.backlog.records[] | select(.id == "dated-hold")][0].hold_bucket == "dated")
      and ([.backlog.records[] | select(.id == "aged-hold")][0].hold_bucket == "aged")
      and ([.backlog.records[] | select(.id == "live-hold")][0].hold_bucket == "live")
  ' >/dev/null || fail "structured fields did not drive the bucket assignment: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "opposite-word")][0]) as $opposite
    | ([.backlog.records[] | select(.id == "marker-prose")][0]) as $prose
    | $opposite.hold_bucket == "live" and $opposite.captain_actionable == true
      and $prose.hold_bucket == "live" and $prose.captain_actionable == true
  ' >/dev/null || fail "hold reason or body prose must never reclassify a live decision: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "working-held")][0])
    | .hold_bucket == "live" and .captain_actionable == true
  ' >/dev/null || fail "a captain hold on a working task must still be bucketed: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "upstream-work")][0].hold_bucket) == null
  ' >/dev/null || fail "a row that is not a captain hold must carry no bucket: $out"
  pass "captain-hold buckets are total, mutually exclusive, and never decided by prose"
}

test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)
- [ ] dated-route - Deferred sample route (repo: sample) (kind: ship) (hold: captain sent this to later) (hold-kind: captain) (hold-until: 2026-09-01)
- [ ] captain-gated-work - Captain-gated ship work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] parked-prose - Parked captain call (repo: sample) (kind: ship) (hold: DEFERRED by captain) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" \
    FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
      and .captain_actionable == true
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "dated-route")
    | .title == "Deferred sample route"
      and .hold_until == "2026-09-01"
      and .captain_actionable == false
      and .hold_bucket == "dated"
  ' >/dev/null || fail "a dated captain hold did not defer or strip its hold-until from the title"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-gated-work")
    | .kind == "ship" and .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "captain actionability must not depend on the row kind"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parked-prose")
    | .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "hold prose must never classify a captain hold"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_undated_captain_hold_phrasing_and_aging() {
  local home fakebin out
  home=$(make_home undated-aging)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] parked-hold - Parked style call (repo: sample) (kind: ship) (hold: parked) (hold-kind: captain)
- [ ] awaiting-go - Awaiting go call (repo: sample) (kind: ship) (hold: awaiting captain go) (hold-kind: captain)
- [ ] no-dispatch - No dispatch call (repo: sample) (kind: ship) (hold: do not dispatch) (hold-kind: captain)
- [ ] no-auto - No auto-dispatch call (repo: sample) (kind: ship) (hold: do not auto-dispatch) (hold-kind: captain)
- [ ] not-urgent - Not urgent call (repo: sample) (kind: ship) (hold: not urgent) (hold-kind: captain)
- [ ] deprior - Deprioritized call (repo: sample) (kind: ship) (hold: de-prioritized) (hold-kind: captain)
- [ ] queued-opp - Queued opportunity call (repo: sample) (kind: ship) (hold: queued opportunity) (hold-kind: captain)
- [ ] gated-hold - Captain-gated phrasing (repo: sample) (kind: ship) (hold: captain-gated) (hold-kind: captain)
- [ ] aged-call - Aged genuine call (repo: sample) (kind: captain) (since 2026-07-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-01T00:00:00Z
- [ ] recent-call - Recent genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] legacy-old-hold - Legacy unstamped hold (repo: sample) (kind: ship) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Historical notes remain ordinary task content.
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] boundary-call - Almost aged genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-11T00:01:00Z
- [ ] live-gated - Live captain-gated work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] unparked-call - Newly unparked decision (repo: sample) (kind: captain) (hold: unparked; choose a sample route) (hold-kind: captain)
- [ ] contextual-call - Context is not a deferral (repo: sample) (kind: captain) (hold: choose whether to pursue this queued opportunity) (hold-kind: captain)
  This is not urgent context, but the captain decision is current.
- [ ] contextual-not-urgent - Leading context is not a deferral (repo: sample) (kind: captain) (hold: not urgent but choose the route now) (hold-kind: captain)
- [ ] contextual-comma - Comma context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, choose the launch route now) (hold-kind: captain)
- [ ] metadata-context - Metadata-like context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain)
- [ ] contextual-opportunity - Leading opportunity is not a deferral (repo: sample) (kind: captain) (hold: queued opportunity: choose whether to proceed) (hold-kind: captain)
- [ ] contextual-gated - Leading gate is not a deferral (repo: sample) (kind: captain) (hold: captain-gated decision needs current approval) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "parked-hold" or .id == "awaiting-go" or .id == "no-dispatch"
        or .id == "no-auto" or .id == "not-urgent" or .id == "deprior" or .id == "queued-opp"
        or .id == "gated-hold")]
     | all(.captain_actionable == true and .hold_bucket == "live"))
  ' >/dev/null || fail "parked-style wording must never classify a fresh undated hold: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .captain_actionable == false
      and .hold_bucket == "aged"
      and .hold_age_days == 24
  ' >/dev/null || fail "an undated captain hold older than the default 14-day threshold must age: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "recent-call")][0]) as $recent
    | ([.backlog.records[] | select(.id == "legacy-old-hold")][0]) as $legacy
    | $recent.captain_actionable == true
      and $recent.hold_bucket == "live"
      and $recent.hold_age_days == 5
      and $legacy.captain_actionable == false
      and $legacy.hold_set == null
      and $legacy.hold_bucket == "aged"
      and $legacy.hold_age_days == 54
  ' >/dev/null || fail "recent stamped and legacy unstamped hold ages are wrong: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "boundary-call")
    | .hold_set == "2026-07-11T00:01:00Z"
      and .hold_age_days == 13 and .hold_bucket == "live"
  ' >/dev/null || fail "a hold one minute short of 14 days must not age early: $out"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.id == "live-gated" or .id == "unparked-call" or .id == "contextual-call"
        or .id == "contextual-not-urgent" or .id == "contextual-comma" or .id == "metadata-context"
        or .id == "contextual-opportunity" or .id == "contextual-gated")]
    | length == 8
      and all(.captain_actionable == true and .hold_bucket == "live")
      and (map(select(.id == "contextual-comma" and .hold_reason == "not urgent, choose the launch route now")) | length == 1)
      and (map(select(.id == "metadata-context" and .hold_reason == "not urgent, priority: decide P1 or P2")) | length == 1)
  ' >/dev/null || fail "contextual parked-style wording must not hide current decisions: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=30 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .hold_bucket == "live" and .hold_age_days == 24
  ' >/dev/null || fail "raising the age threshold must leave a 24-day hold unaged: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=5 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "recent-call")
    | .hold_bucket == "aged" and .hold_age_days == 5
  ' >/dev/null || fail "lowering the age threshold to 5 must age a 5-day hold: $out"
  pass "undated captain holds age after a configurable threshold, decided only from structured fields"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out kind terminal id phase single mate single_state mate_state
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"

  # Same terminal-supersession contract across ship/scout/secondmate, both snapshot
  # modes, and reopen/resolve after cleanup.
  home=$(make_home terminal-cleanup)
  mkdir -p "$home/projects/task"
  fakebin=$(make_fakebin "$home")
  for kind in ship scout secondmate; do
    for terminal in 'done' failed; do
      id="$kind-$terminal"
      fm_write_meta "$home/state/$id.meta" \
        "window=firstmate:fm-$id" "worktree=$home/projects/task" \
        "kind=$kind" "harness=claude"
      record_claude_idle "$home/state" "$id"
      printf 'blocked [key=access]: waiting\nneeds-decision [key=choice]: choose a route\n%s: final outcome\nnote: cleanup complete\n' \
        "$terminal" > "$home/state/$id.status"
    done
  done
  for phase in terminal reopened resolved; do
    case "$phase" in
      terminal) single='[]'; mate='["access","choice"]'; single_state=unknown; mate_state=parked ;;
      reopened) single='["access","new-choice"]'; mate='["access","choice","new-choice"]'; single_state=parked; mate_state=parked ;;
      resolved) single='[]'; mate='["choice"]'; single_state=unknown; mate_state=parked ;;
    esac
    for kind in ship scout secondmate; do
      for terminal in 'done' failed; do
        id="$kind-$terminal"
        case "$phase" in
          reopened) printf 'blocked [key=access]: reopened access\nneeds-decision [key=new-choice]: a new choice\nnote: more cleanup\n' >> "$home/state/$id.status" ;;
          resolved) printf 'resolved [key=access]: access granted\nresolved [key=new-choice]: answered\nnote: final cleanup\n' >> "$home/state/$id.status" ;;
        esac
      done
    done
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
    printf '%s' "$out" | jq -e --argjson single "$single" --argjson mate "$mate" \
      --arg single_state "$single_state" --arg mate_state "$mate_state" '
      .tasks | length == 6 and all(.[];
        (.kind == "secondmate") as $persistent
        | (.hints.open_decisions | map(.key) | sort) == (if $persistent then $mate else $single end)
          and .current_state.state == (if $persistent then $mate_state else $single_state end)
          and .hints.blocked_event == (if $persistent then $mate else $single end | index("access") != null)
          and .hints.pending_decision == (if $persistent then $mate else $single end | any(. != "access")))
    ' >/dev/null || fail "$phase snapshot revived a completed decision or lost a current one: $out"
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
    printf '%s' "$out" | jq -e --argjson single "$single" --argjson mate "$mate" '
      (.decisions_open | map({id,key}) | sort_by(.id,.key)) ==
        (([ ("ship-done","ship-failed","scout-done","scout-failed") as $id | $single[] | {id:$id,key:.} ]
          + [ ("secondmate-done","secondmate-failed") as $id | $mate[] | {id:$id,key:.} ]) | sort_by(.id,.key))
    ' >/dev/null || fail "$phase home summary revived a completed decision or lost a current one: $out"
  done
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# Home-summary validity treats persistent secondmates as registered homes, not
# in-flight children. They have no backlog rows, so they must not produce
# unowned_current or terminal_in_flight. Ordinary crew/ship metas still do.
test_home_summary_excludes_secondmate_from_child_inventory() {
  local home fakebin out
  home=$(make_home summary-secondmate-only)
  mkdir -p "$home/secondmate-home" "$home/projects/unowned" "$home/projects/terminal"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/mate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .schema == "fm-secondmate-home-summary.v1"
      and .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "unowned_current")
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "secondmate-only home with a clean backlog must be VALID: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Registered secondmate home (repo: alpha) (kind: secondmate) (since 2026-07-11)

## Queued

## Done
EOF
  printf 'done: delegated scope complete\n' > "$home/state/mate.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "terminal secondmate with a matching in-flight row must not produce terminal_in_flight: $out"

  fm_write_meta "$home/state/unowned-ship.meta" \
    "window=firstmate:fm-unowned-ship" \
    "worktree=$home/projects/unowned" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" unowned-ship
  printf 'needs-decision [key=unowned-ship]: choose a route\n' > "$home/state/unowned-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"unowned_current",ids:["unowned-ship"]}
      and (.reason | contains("unowned-ship=parked"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary unowned ship must still produce unowned_current without listing the secondmate: $out"

  rm -f "$home/state/unowned-ship.meta" "$home/state/unowned-ship.status"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] terminal-ship - Done child still in flight (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$home/state/terminal-ship.meta" \
    "window=firstmate:fm-terminal-ship" \
    "worktree=$home/projects/terminal" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" terminal-ship
  printf 'done: complete\n' > "$home/state/terminal-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"terminal_in_flight",ids:["terminal-ship"]}
      and (.reason | contains("terminal-ship=done"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary terminal in-flight ship must still produce terminal_in_flight without listing the secondmate: $out"
  pass "home-summary excludes kind=secondmate from unowned_current and terminal_in_flight"
}

make_limit_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane)
    # The prompt exactly as Claude Code draws it: it REPLACES the composer, so
    # nothing is rendered below the confirm row.
    case "$target" in
      *limit-task*) cat <<'EOF'
● Pushed the branch and opened the pull request.

Claude usage limit reached. Your limit will reset at 6:40pm.

   What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Upgrade your plan

   Enter to confirm · Esc to cancel
EOF
        ;;
      *) printf 'all quiet\n> \n' ;;
    esac ;;
esac
exit 0
SH
  # quota-axi is firstmate's quota authority; serving it from the fakebin keeps
  # these cases hermetic and off the real account.
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<EOF
{ "schemaVersion": 5, "providers": [ { "provider": "claude",
    "state": { "status": "fresh", "stale": false },
    "quotaSemantics": { "status": "known",
      "effectiveAvailability": [
        { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0,
          "runway": { "status": "exhausted_now" } } ] } } ] }
EOF
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/quota-axi"
  printf '%s\n' "$fb"
}

make_stalled_fakebin() {  # <dir> <branch>
  local fb head
  fb=$(fm_fakebin "$1")
  head=$(git -C "$1/projects/stalled-wt" rev-parse HEAD)
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-} \${2:-}" in
  "axi status"|"axi ")
    cat <<'TOON'
run:
  id: "01RUN"
  branch: $2
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,20h53m,"quiet 20h52m ago: log: reviewing","424242",round 1
TOON
    ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_terminal_run_fakebin() {  # <home> <worktree> <branch>
  local fb head
  fb=$(fm_fakebin "$1")
  head=$(git -C "$2" rev-parse HEAD)
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-} \${2:-}" in
  "axi status"|"axi ")
    cat <<'TOON'
run:
  id: "01RUN"
  branch: $3
  status: completed
  outcome: checks-passed
  head: "$head"
  pr: "https://github.com/o/r/pull/9"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    ci,completed,0,0
TOON
    ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

setup_terminal_run_task() {  # <home-name> <task-id> -> prints "<home> <fakebin>"
  local home wt
  home=$(make_home "$1")
  wt="$home/projects/$2-wt"
  mkdir -p "$wt"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "fm/$2"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $2 - Terminal Run Task (repo: alpha) (kind: ship) (since 2026-09-07)
EOF
  fm_write_meta "$home/state/$2.meta" \
    "window=firstmate:fm-$2" \
    "worktree=$wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s %s\n' "$home" "$(make_terminal_run_fakebin "$home" "$wt" "fm/$2")"
}

# Injects a jq failure at the one call site whose argument vector carries a
# value this fixture chose, so what gets asserted is the snapshot's own handling
# of a payload its producer never delivered.
make_failing_jq() {  # <fakebin> <argv-glob>
  local fakebin=$1 pattern=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    $pattern) exit 1 ;;
  esac
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

# A pane read normally proves the crew moved past its gate, so it CLEARS the
# keyed decision fold. The usage-limit pane read proves the opposite - the crew
# stopped, with the prompt drawn over whatever it was doing - so its open
# decision must keep surfacing instead of being cleared by the sighting.
test_usage_limited_crew_keeps_its_open_decision() {
  local home fakebin out view
  home=$(make_home usage-limited-decision)
  mkdir -p "$home/projects/limit-wt"
  fm_write_meta "$home/state/limit-task.meta" \
    "window=firstmate:fm-limit-task" \
    "worktree=$home/projects/limit-wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision [key=api]: choose an API shape\n' > "$home/state/limit-task.status"
  fakebin=$(make_limit_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "limit-task")
    | .current_state.state == "usage-limited"
      and .current_state.source == "pane"
      and (.current_state.detail | test("limit-window: exhausted"))
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "api"
  ' >/dev/null || fail "a usage-limited crew's open decision must keep surfacing: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "usage-limited / pane" \
    "the fleet view must name the usage-limited state in the crew's row"
  pass "a crew on the claude usage-limit prompt keeps its open decision and is named in the view"
}

# The home-summary fold's other direction: a usage-limited child is neither
# `working` (so it is not active child work) nor a backlog hold, so without the
# new state in the child-state hold fold the home would summarise as having NO
# active work at all - the stalled crew rendered invisible exactly as it was in
# the incident.
test_usage_limited_child_is_an_external_hold_not_no_active_work() {
  local home fakebin out
  home=$(make_home usage-limited-home-summary)
  mkdir -p "$home/projects/limit-wt2"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] limit-task - Limit Task (repo: alpha) (kind: ship) (since 2026-07-29)
EOF
  fm_write_meta "$home/state/limit-task.meta" \
    "window=firstmate:fm-limit-task" \
    "worktree=$home/projects/limit-wt2" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  printf 'working: implementing\n' > "$home/state/limit-task.status"
  fakebin=$(make_limit_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true
      and .state == "externally_held"
      and ((.holds // []) | any(.id == "limit-task" and (.reason | test("usage-limit"))))
      and (.active_children | length) == 0
  ' >/dev/null || fail "a usage-limited child must read as an external hold, not no active work: $out"
  pass "a home summary with a usage-limited child reads as externally held, not no-active-work"
}

test_stalled_child_is_active_work_not_no_active_work() {
  local home fakebin out
  home=$(make_home stalled-home-summary)
  mkdir -p "$home/projects/stalled-wt"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$home/projects/stalled-wt" init -q
  git -C "$home/projects/stalled-wt" commit -q --allow-empty -m init
  git -C "$home/projects/stalled-wt" checkout -q -b fm/stalled-task
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] stalled-task - Stalled Task (repo: alpha) (kind: ship) (since 2026-08-20)
EOF
  fm_write_meta "$home/state/stalled-task.meta" \
    "window=firstmate:fm-stalled-task" \
    "worktree=$home/projects/stalled-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: implementing\n' > "$home/state/stalled-task.status"
  fakebin=$(make_stalled_fakebin "$home" fm/stalled-task)
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "stalled-task") | .current_state.state == "stalled"
  ' >/dev/null || fail "the fixture must produce a stalled child: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .state == "active_child_work"
      and ((.active_children // []) | any(.id == "stalled-task" and .state == "stalled"))
  ' >/dev/null || fail "a stalled child must stay active child work: $out"
  pass "a home summary with a stalled child reads as active child work, not no-active-work"
}

test_unreadable_only_home_does_not_claim_no_active_work() {
  local home fakebin out
  home=$(make_home unreadable-only-home)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] gone-task - Gone Task (repo: alpha) (kind: ship) (since 2026-07-29)
EOF
  fm_write_meta "$home/state/gone-task.meta" \
    "window=firstmate:fm-gone-task" \
    "worktree=$home/projects/torn-down" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  fakebin=$(make_limit_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .state == "unknown"
      and (.reason | test("child current state unavailable: gone-task"))
      and (.active_children | length) == 0
      and (.holds | length) == 0
      and (.decisions_open | length) == 0
  ' >/dev/null || fail "a home holding only an unreadable child claimed no active work: $out"
  pass "a home whose only child is unreadable does not claim no active child work"
}

test_post_run_decision_survives_terminal_run() {
  local home fakebin out
  read -r home fakebin <<<"$(setup_terminal_run_task post-run-decision post-run)"
  # The crew validated, reported the green PR, and only THEN found the question.
  {
    printf 'working: implementing\n'
    printf 'done: PR https://github.com/o/r/pull/9 checks green\n'
    printf 'needs-decision [key=rollout]: stage the rollout or ship it whole\n'
  } > "$home/state/post-run.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "post-run")
    | .current_state.state == "done"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "rollout"
  ' >/dev/null || fail "a request raised after the run finished must survive: $out"
  pass "a decision request appended after a terminal run stays in the fleet view"
}

test_mid_run_decision_cleared_by_terminal_run() {
  local home fakebin out
  read -r home fakebin <<<"$(setup_terminal_run_task mid-run-decision mid-run)"
  # The same request, raised MID-run and answered by a steer that left no keyed
  # resolution behind - the crew simply reported on and the run finished. The only
  # difference from the case above is the crew's later event.
  {
    printf 'working: implementing\n'
    printf 'needs-decision [key=rollout]: stage the rollout or ship it whole\n'
    printf 'working: applying the agreed rollout\n'
    printf 'done: PR https://github.com/o/r/pull/9 checks green\n'
  } > "$home/state/mid-run.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "mid-run")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "a request the crew reported on past must still clear: $out"
  pass "a mid-run request the crew reported on past is still cleared by the finished run"
}

test_answered_post_run_decision_keeps_its_unanswered_sibling() {
  local home fakebin out
  read -r home fakebin <<<"$(setup_terminal_run_task two-post-run-decisions two-post)"
  # Two questions after the finished run, one of them answered. A keyed
  # resolution speaks for its own key only, so the other stays pending.
  {
    printf 'done: PR https://github.com/o/r/pull/9 checks green\n'
    printf 'needs-decision [key=rollout]: stage the rollout or ship it whole\n'
    printf 'needs-decision [key=schema]: migrate the schema now or next release\n'
    printf 'resolved [key=rollout]: captain chose staged\n'
  } > "$home/state/two-post.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "two-post")
    | .current_state.state == "done"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "schema"
  ' >/dev/null || fail "resolving one post-run request must not clear the other: $out"
  pass "resolving one post-run request leaves its unanswered sibling pending"
}

# A done: crew-state reads back as blocked (here a direct-PR done naming no pull
# request) is the same finish as a done, so it narrows the open decisions the
# same way instead of resurfacing a request the crew reported on past beside the
# row asking for the delivery steer.
test_blocked_done_clears_the_request_it_reported_past() {
  local home fakebin out wt
  home=$(make_home blocked-done-no-pr)
  wt="$home/projects/handoff-wt"
  mkdir -p "$wt"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/handoff
  git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
  fm_write_meta "$home/state/handoff.meta" \
    "window=firstmate:fm-handoff" \
    "worktree=$wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR"
  record_claude_idle "$home/state" handoff
  {
    printf 'needs-decision [key=rollout]: stage the rollout or ship it whole\n'
    printf 'working: applying the agreed rollout\n'
    printf 'done: implemented and committed on the branch\n'
  } > "$home/state/handoff.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "handoff")
    | .current_state.state == "blocked"
      and (.current_state.detail | test("^steer it to "))
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "a blocked done must clear the request the crew reported on past: $out"

  # A request raised AFTER that done still surfaces.
  printf 'needs-decision [key=scope]: include the migration or not\n' >> "$home/state/handoff.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "handoff")
    | .hints.pending_decision == true
      and ([.hints.open_decisions[].key] == ["scope"])
  ' >/dev/null || fail "a request raised after the blocked done must survive: $out"
  pass "a done read back as blocked narrows its open decisions like any other finish"
}

# The reported defect: the whole backlog JSON rode jq's argument vector, and
# Linux caps a single argv entry at MAX_ARG_STRLEN (131072 bytes) regardless of
# the much larger total ARG_MAX. Every record must still be reported - a snapshot
# that shrinks its own output to fit would trade a loud failure for a quiet one.
test_oversized_backlog_still_reports_every_record() {
  local home rows i body out payload_bytes rc
  home=$(make_home oversized-backlog)
  rows=160
  body=$(head -c 1200 /dev/zero | tr '\0' 'x')
  {
    printf '## Queued\n'
    for ((i = 1; i <= rows; i++)); do
      printf -- '- [ ] bulk-%03d - Bulk item %03d (repo: alpha) (kind: ship) (since 2026-08-24)\n' "$i" "$i"
      printf '  %s\n' "$body"
    done
  } > "$home/data/backlog.md"

  out=$(FM_HOME="$home" "$SNAPSHOT" --json) || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "snapshot failed on an oversized backlog (rc=${rc:-0})"

  payload_bytes=$(printf '%s' "$out" | jq -c '.backlog' | LC_ALL=C wc -c | tr -d ' ')
  [ "$payload_bytes" -gt 131072 ] \
    || fail "fixture no longer exceeds the single-argument limit ($payload_bytes bytes); it cannot prove the regression"

  printf '%s' "$out" | jq -e --argjson rows "$rows" '
    .schema == "fm-fleet-snapshot.v1"
      and ([.backlog.records[] | select(.structured)] | length) == $rows
      and (.backlog.records[-1].id == "bulk-160")
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null || fail "oversized backlog lost records or inventory disclosure"

  # The contribution poll reads the same backlog through its own mode.
  rc=0
  out=$(FM_HOME="$home" "$SNAPSHOT" --contribution-input) || rc=$?
  [ "$rc" -eq 0 ] || fail "--contribution-input failed on an oversized backlog (rc=$rc)"
  printf '%s' "$out" | jq -e --argjson rows "$rows" '
    ([.backlog.records[] | select(.structured)] | length) == $rows
      and (.backlog.records[-1].id == "bulk-160")
      and (.tasks | type) == "array"
  ' >/dev/null || fail "--contribution-input lost backlog records: $(printf '%s' "$out" | head -c 300)"
  pass "a backlog past the single-argument limit is reported in full"
}

# The same per-argument ceiling applies to one externally written status-log
# line, which reaches jq as status_event_json's raw and note. Losing it degrades
# quietly: the event and the whole status_log pointer come back null while the
# snapshot still exits 0. The crew-state read of a line this long is bounded by
# the per-task read timeout, so its detail half is pinned by the next case.
test_oversized_status_line_still_reports_its_event() {
  local home fakebin note line out rc raw_len note_len
  home=$(make_home oversized-status)
  mkdir -p "$home/projects/bulk-worktree"
  fm_write_meta "$home/state/bulk-task.meta" \
    "window=firstmate:fm-bulk-task" \
    "worktree=$home/projects/bulk-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" bulk-task
  note=$(head -c 200000 /dev/zero | tr '\0' 'n')
  line="working: $note"
  printf '%s\n' "$line" > "$home/state/bulk-task.status"
  raw_len=${#line}
  note_len=${#note}
  [ "$raw_len" -gt 131072 ] \
    || fail "fixture status line no longer exceeds the single-argument limit ($raw_len bytes)"

  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 "$SNAPSHOT" --json) || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "snapshot failed on an oversized status line (rc=${rc:-0})"

  printf '%s' "$out" | jq -e --argjson raw_len "$raw_len" --argjson note_len "$note_len" '
    .tasks[] | select(.id == "bulk-task")
    | .paths.status_log.present == true
      and .paths.status_log.last_event.state == "working"
      and (.paths.status_log.last_event.raw | length) == $raw_len
      and (.paths.status_log.last_event.note | length) == $note_len
      and (.hints.last_event_text | length) == $raw_len
  ' >/dev/null || fail "oversized status line degraded instead of being reported in full"
  pass "a status line past the single-argument limit is reported in full"
}

# The crew-state line reaches jq as crew_state_json's raw and detail. A private
# copy of bin/ whose fm-crew-state.sh answers at once with an oversized detail
# isolates that half from how long a real read of such a line takes.
test_oversized_current_state_detail_is_reported_in_full() {
  local home bin fakebin out rc detail_len
  home=$(make_home oversized-current-state)
  bin="$home/bin-copy/bin"
  mkdir -p "$home/bin-copy" "$home/projects/detail-worktree"
  cp -R "$ROOT/bin" "$bin"
  cat > "$bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log · %s\n' "$(head -c 200000 /dev/zero | tr '\0' 'd')"
SH
  chmod +x "$bin/fm-crew-state.sh"
  detail_len=200000
  fm_write_meta "$home/state/detail-task.meta" \
    "window=firstmate:fm-detail-task" \
    "worktree=$home/projects/detail-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$bin/fm-fleet-snapshot.sh" --json) || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "snapshot failed on an oversized current-state detail (rc=${rc:-0})"
  printf '%s' "$out" | jq -e --argjson detail_len "$detail_len" '
    .tasks[] | select(.id == "detail-task")
    | .current_state.state == "working"
      and .current_state.source == "status-log"
      and (.current_state.detail | length) == $detail_len
  ' >/dev/null || fail "oversized current-state detail degraded instead of being reported in full"
  pass "a current-state detail past the single-argument limit is reported in full"
}

# first_pr_url_in_file greps the whole status log for a URL with no length cap,
# so the recorded PR pointer is externally written and can exceed the ceiling on
# its own, independently of the line that carries it.
test_oversized_pr_url_still_reports_the_task() {
  local home fakebin url out rc url_len
  home=$(make_home oversized-pr)
  mkdir -p "$home/projects/pr-worktree"
  fm_write_meta "$home/state/pr-task.meta" \
    "window=firstmate:fm-pr-task" \
    "worktree=$home/projects/pr-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  url="https://github.com/o/$(head -c 140000 /dev/zero | tr '\0' 'r')/pull/7"
  printf 'done: shipped %s\n' "$url" > "$home/state/pr-task.status"
  url_len=${#url}
  [ "$url_len" -gt 131072 ] \
    || fail "fixture PR URL no longer exceeds the single-argument limit ($url_len bytes)"

  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json) || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "snapshot failed on an oversized PR URL (rc=${rc:-0})"

  printf '%s' "$out" | jq -e --argjson url_len "$url_len" '
    .tasks[] | select(.id == "pr-task")
    | .pr.source == "status_event"
      and (.pr.url | length) == $url_len
  ' >/dev/null || fail "oversized PR URL degraded instead of being reported in full"
  pass "a PR URL past the single-argument limit is reported in full"
}

# An empty --slurpfile binds [], so an undelivered payload would otherwise read
# as a legitimate null and ship a task row with no status_log at all.
test_missing_status_log_payload_fails_loudly() {
  local home fakebin out rc err
  home=$(make_home missing-payload)
  mkdir -p "$home/projects/zzpoison-worktree"
  fm_write_meta "$home/state/zzpoisontask.meta" \
    "window=firstmate:fm-zzpoisontask" \
    "worktree=$home/projects/zzpoison-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: still going\n' > "$home/state/zzpoisontask.status"
  fakebin=$(make_fakebin "$home")
  make_failing_jq "$fakebin" '*zzpoisontask.status'

  err="$home/missing-payload.err"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>"$err") || rc=$?
  [ "${rc:-0}" -ne 0 ] \
    || fail "an undelivered status_log payload must fail the snapshot, got rc 0 and: $out"
  [ -z "$out" ] || fail "a failed task snapshot must not print a partial snapshot: $out"
  assert_contains "$(cat "$err")" "missing status_log payload" \
    "the diagnostic must name the payload that never arrived"
  assert_contains "$(cat "$err")" "task snapshot failed" \
    "the missing payload must reach the snapshot's own exit path"
  pass "a task payload that never arrived fails loudly instead of reading as null"
}

# The row loop's exit status is the LAST iteration's, so a lost payload on any
# earlier task would leave the pipeline reading clean and ship a snapshot that
# is simply missing a crew, at exit 0.
test_lost_payload_on_an_earlier_task_fails_loudly() {
  local home fakebin id out rc err
  home=$(make_home earlier-payload)
  for id in aaa-poisoned mmm-later zzz-last; do
    mkdir -p "$home/projects/$id-worktree"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id-worktree" \
      "project=alpha" \
      "harness=codex" \
      "kind=ship" \
      "mode=ship"
    printf 'working: still going\n' > "$home/state/$id.status"
  done
  fakebin=$(make_fakebin "$home")
  make_failing_jq "$fakebin" '*aaa-poisoned.status'

  err="$home/earlier-payload.err"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2>"$err") || rc=$?
  [ "${rc:-0}" -ne 0 ] \
    || fail "a lost payload on a non-final task must fail the snapshot, got rc 0 and: $out"
  [ -z "$out" ] || fail "a failed task snapshot must not print the surviving rows: $out"
  assert_contains "$(cat "$err")" "missing status_log payload" \
    "the diagnostic must name the payload that never arrived"
  assert_contains "$(cat "$err")" "task snapshot failed" \
    "an earlier row's failure must still reach the snapshot's own exit path"
  pass "a lost payload on a task the loop passes over early fails loudly"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_home_summary_excludes_secondmate_from_child_inventory
test_undated_captain_hold_phrasing_and_aging
test_hold_buckets_are_total_and_text_blind
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
test_usage_limited_crew_keeps_its_open_decision
test_usage_limited_child_is_an_external_hold_not_no_active_work
test_stalled_child_is_active_work_not_no_active_work
test_unreadable_only_home_does_not_claim_no_active_work
test_post_run_decision_survives_terminal_run
test_mid_run_decision_cleared_by_terminal_run
test_answered_post_run_decision_keeps_its_unanswered_sibling
test_blocked_done_clears_the_request_it_reported_past
test_oversized_backlog_still_reports_every_record
test_oversized_status_line_still_reports_its_event
test_oversized_current_state_detail_is_reported_in_full
test_oversized_pr_url_still_reports_the_task
test_missing_status_log_payload_fails_loudly
test_lost_payload_on_an_earlier_task_fails_loudly
