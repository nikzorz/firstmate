#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}


# --- gate-linked captain items -------------------------------------------
#
# The design is one record: the backlog item says whether a decision is owed, and
# the link holds only the origin-keyed pairing so teardown can ask its question.
# gate-verify never reads the item and never calls tasks-axi.

gate_fixture() {  # <home> <origin> <item>
  local home=$1 origin=$2 item=$3
  tasks_in "$home" add "$origin" "worker $origin" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the worker fixture"
  write_origin_meta "$home" "$origin" ship
  printf 'working: implementing\n' > "$home/state/$origin.status"
  tasks_in "$home" add "$item" "captain decision pending" --kind captain --repo sample \
    --body "Captain decision pending as of 2026-07-14." >/dev/null \
    || fail "could not create the captain-gated fixture"
  tasks_in "$home" hold "$item" --reason "captain decision pending" --kind captain >/dev/null \
    || fail "could not activate the captain-gated fixture"
  printf 'Fall back to the seat default scenario.\n' > "$home/answer.txt"
}

assert_still_claims_captain_owes() {  # <home> <item> <label>
  local show
  show=$(tasks_in "$1" show "$2" --full)
  assert_contains "$show" "state: queued" "$3: item is not queued"
  assert_contains "$show" "held: yes" "$3: item is not held"
  assert_contains "$show" "hold_kind: captain" "$3: item is not held for the captain"
  assert_contains "$show" "Captain decision pending" "$3: item no longer claims the captain owes an answer"
}

# The defect this whole mechanism exists to remove, kept as the reproduction it
# was: an unlinked gate answer leaves the item asserting the captain still owes.
test_unlinked_captain_item_goes_stale_when_the_gate_answers_it() {
  local home out
  home=$(make_home stale-captain-item)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  assert_still_claims_captain_owes "$home" sample-scenario-choice "before"
  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "reconciling an unlinked gate must succeed so the call can be unconditional"
  assert_contains "$out" "has no linked captain-gated item" \
    "an unlinked gate must say so rather than guess a pairing"
  assert_still_claims_captain_owes "$home" sample-scenario-choice "after an unlinked gate answer"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "an origin with no recorded link must verify clean"
  pass "an unlinked captain-gated item survives its own gate's answer still claiming the captain owes it"
}

test_linked_captain_item_is_closed_and_the_link_disappears() {
  local home out show link
  home=$(make_home linked-captain-item)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation) \
    || fail "could not record the gate link"
  assert_present "$link" "the gate link record was not created"
  assert_still_claims_captain_owes "$home" sample-scenario-choice "after linking"
  if run_decisions "$home" gate-verify sample-hosted-boot > "$home/gv.out" 2> "$home/gv.err"; then
    fail "an unreconciled captain-gated link must not verify clean"
  fi
  assert_grep "never reconciled" "$home/gv.err" "verification must name the defect"
  assert_grep "$link" "$home/gv.err" "verification must name the link record"

  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "could not reconcile the linked captain-gated item"
  assert_contains "$out" "sample-scenario-choice closed" "reconciliation must name the closed item"
  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "state: done" "answered captain-gated item did not close"
  assert_contains "$show" "held: no" "answered captain-gated item is still held"
  assert_contains "$show" "Answered through gate sample-hosted-boot/scenario-validation" \
    "closed item lost the recorded gate identity"
  assert_contains "$show" "Decided by: firstmate" "closed item does not record who actually decided"
  case "$show" in
    *"Captain decision pending"*) fail "closed item still asserts the captain owes an answer" ;;
  esac
  [ ! -e "$link" ] || fail "the link record survived a landed item write"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "a reconciled origin must verify clean"
  pass "answering a linked gate closes the item and removes the link"
}

# The eighth route to the original defect, found on the superseded branch: a
# re-kinded item keeps hold_kind and hold_reason, so keying on kind let cleanup
# pass over an item that still asserts an owed decision.
test_owed_decision_is_keyed_on_the_hold_not_the_kind() {
  local home show
  home=$(make_home owed-predicate)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
  tasks_in "$home" update sample-scenario-choice --kind ship >/dev/null \
    || fail "could not re-kind the captain-gated fixture"
  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "hold_kind: captain" "the re-kind fixture lost the hold that carries the claim"
  assert_contains "$show" "kind: ship" "the re-kind fixture did not change kind"
  run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt" >/dev/null \
    || fail "a re-kinded item that still asserts an owed decision must still be closed"
  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "state: done" "a re-kinded item was left asserting an owed decision"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "the origin must verify clean once the re-kinded item was closed"
  pass "the owed predicate reads the captain hold, so a re-kinded item is still closed"
}

test_gate_that_never_raised_the_question_writes_nothing() {
  local home out link
  home=$(make_home unraised-gate)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
  out=$(run_decisions "$home" gate-not-raised sample-hosted-boot scenario-validation) \
    || fail "could not retire a gate that never raised the question"
  assert_contains "$out" "never raised the question" "retiring must say the gate never asked"
  assert_still_claims_captain_owes "$home" sample-scenario-choice "after retiring an unraised gate"
  [ ! -e "$link" ] || fail "the link record survived retirement"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "a retired link must verify clean"
  pass "a gate that never raised the question writes nothing and leaves the item captain-owned"
}

# Every way the linked item can depart or become unavailable. The point of the
# design is that these are not classified anywhere: the command either lands the
# write and drops the link, or refuses and keeps it.
test_gate_answer_handles_every_departure_shape() {
  local home shape link out
  for shape in closed-by-captain removed re-kinded unheld-but-open second-gate; do
    home=$(make_home "departure-$shape")
    gate_fixture "$home" sample-hosted-boot sample-scenario-choice
    link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
    case "$shape" in
      closed-by-captain)
        tasks_in "$home" unhold sample-scenario-choice >/dev/null
        tasks_in "$home" "done" sample-scenario-choice --note "captain answered in standup" >/dev/null
        ;;
      removed) tasks_in "$home" rm sample-scenario-choice >/dev/null 2>&1 ;;
      re-kinded) tasks_in "$home" update sample-scenario-choice --kind ship >/dev/null ;;
      unheld-but-open) tasks_in "$home" unhold sample-scenario-choice >/dev/null ;;
      second-gate)
        run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot other-key >/dev/null
        run_decisions "$home" gate-answered sample-hosted-boot other-key \
          --answered-by firstmate --answer-file "$home/answer.txt" >/dev/null
        ;;
    esac
    out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
      --answered-by firstmate --answer-file "$home/answer.txt") \
      || fail "$shape: gate-answered failed on a departure shape"
    [ ! -e "$link" ] || fail "$shape: the link survived a completed reconciliation"
    run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
      || fail "$shape: the origin did not verify clean"
    case "$shape" in
      removed) assert_contains "$out" "no longer in this backlog" "$shape: outcome did not say what was observed" ;;
      closed-by-captain|second-gate) assert_contains "$out" "already closed" "$shape: outcome did not say what was observed" ;;
      *) assert_contains "$out" "closed" "$shape: outcome did not say what was observed" ;;
    esac
  done
  pass "every departure shape either lands the write or reports what it saw, and the link goes"
}

# An unestablished read must never produce the same outcome as establishing that
# the item is fine, so it keeps the link and cleanup keeps refusing.
test_an_unestablished_read_refuses_and_keeps_the_link() {
  local home link shape out
  for shape in backend-missing unreadable-backlog missing-backlog-store; do
    home=$(make_home "unestablished-$shape")
    gate_fixture "$home" sample-hosted-boot sample-scenario-choice
    link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
    case "$shape" in
      backend-missing)
        cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 127
SH
        chmod +x "$home/fakebin/tasks-axi"
        ;;
      unreadable-backlog)
        mv "$home/data/backlog.md" "$home/data/backlog.saved"
        mkdir "$home/data/backlog.md"
        ;;
      # tasks-axi answers NOT_FOUND for an absent store exactly as it does for an
      # id absent from a readable one, so this shape must not read as departure.
      missing-backlog-store) mv "$home/data/backlog.md" "$home/data/backlog.saved" ;;
    esac
    if run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
      --answered-by firstmate --answer-file "$home/answer.txt" \
      > "$home/ur.out" 2> "$home/ur.err"; then
      fail "$shape: an unestablished item read reported success"
    fi
    assert_grep "was not written" "$home/ur.err" "$shape: refusal did not say the item was not written"
    assert_present "$link" "$shape: the link was dropped after an unestablished read"
    [ "$shape" != missing-backlog-store ] || assert_grep "$home/data/backlog.md" "$home/ur.err" \
      "$shape: the refusal did not name the backlog store it looked for"
    if run_decisions "$home" gate-verify sample-hosted-boot >/dev/null 2>&1; then
      fail "$shape: verification passed while the write had not landed"
    fi
    case "$shape" in
      backend-missing) rm -f "$home/fakebin/tasks-axi" ;;
      unreadable-backlog) rmdir "$home/data/backlog.md"; mv "$home/data/backlog.saved" "$home/data/backlog.md" ;;
      missing-backlog-store) mv "$home/data/backlog.saved" "$home/data/backlog.md" ;;
    esac
    run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
      --answered-by firstmate --answer-file "$home/answer.txt" >/dev/null \
      || fail "$shape: the retry after repair did not land the write"
    run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
      || fail "$shape: the origin did not verify clean after the retry landed"
  done

  # The same NOT_FOUND reading with the store present and readable is genuine
  # absence, so a missing store and a departed item are provably not conflated.
  home=$(make_home unestablished-store-present-item-gone)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
  tasks_in "$home" rm sample-scenario-choice >/dev/null 2>&1
  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "a genuinely absent id in a readable store must still reconcile"
  assert_contains "$out" "no longer in this backlog" \
    "a readable store with a genuinely absent id did not read as departure"
  [ ! -e "$link" ] || fail "a genuine departure left the link behind"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "the origin did not verify clean after a genuine departure"
  pass "an item read that could not be established refuses, keeps the link, and lands on retry"
}

# The answer body lands before the hold is released, so a failed write can never
# leave the item unheld and open: by the owed predicate that item would have
# stopped claiming a decision is owed while none was recorded anywhere.
test_a_failed_answer_write_never_leaves_the_item_unheld_and_open() {
  local home link
  home=$(make_home failed-answer-write)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = update ]; then
  echo 'error: "the body write failed"' >&2
  echo 'code: UNKNOWN' >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt" \
    > "$home/fw.out" 2> "$home/fw.err"; then
    fail "a failed answer write reported success"
  fi
  assert_grep "could not record the gate answer" "$home/fw.err" \
    "the refusal did not name the write that failed"
  assert_still_claims_captain_owes "$home" sample-scenario-choice "after a failed answer write"
  assert_present "$link" "the link was dropped after a failed answer write"
  if run_decisions "$home" gate-verify sample-hosted-boot >/dev/null 2>&1; then
    fail "verification passed while the answer write had not landed"
  fi
  rm -f "$home/fakebin/tasks-axi"
  run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt" >/dev/null \
    || fail "the retry after repair did not land the write"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "the origin did not verify clean after the retry landed"
  pass "a failed answer write leaves the item still asserting an owed captain decision"
}

# Idempotency comes from the item's own state, so the note this command writes
# must be recognised by the guard that decides whether to write it again.
test_the_already_closed_note_is_written_once() {
  local home link out show notes
  home=$(make_home already-closed-note)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
  tasks_in "$home" unhold sample-scenario-choice >/dev/null
  tasks_in "$home" "done" sample-scenario-choice --note "captain answered in standup" >/dev/null
  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "noting this gate on an already closed item failed"
  assert_contains "$out" "already closed" "the first pass did not report what it saw"
  # A link removal that did not land, so the retry re-enters the same branch.
  printf 'item=%s\norigin=%s\nkey=%s\n' sample-scenario-choice sample-hosted-boot scenario-validation > "$link"
  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "the retry against an already noted item failed"
  assert_contains "$out" "already recorded" "the retry did not recognise the note it had written"
  [ ! -e "$link" ] || fail "the retry did not clear the link"
  show=$(tasks_in "$home" show sample-scenario-choice --full)
  notes=$(printf '%s\n' "$show" | grep -oF "through gate sample-hosted-boot/scenario-validation." | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "this gate was noted $notes times on the already closed item"
  pass "the already closed note is idempotent against the item's own state"
}

test_a_missing_flag_value_refuses_with_its_own_message() {
  local home
  home=$(make_home gate-answered-flag-values)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
  if run_decisions "$home" gate-answered sample-hosted-boot scenario-validation --answered-by \
    > "$home/by.out" 2> "$home/by.err"; then
    fail "a trailing --answered-by must not succeed"
  fi
  assert_grep "must be captain or firstmate" "$home/by.err" \
    "a trailing --answered-by ended the command with no refusal"
  if run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file > "$home/file.out" 2> "$home/file.err"; then
    fail "a trailing --answer-file must not succeed"
  fi
  assert_grep "answer-file is required" "$home/file.err" \
    "a trailing --answer-file ended the command with no refusal"
  assert_still_claims_captain_owes "$home" sample-scenario-choice "after a refused invocation"
  pass "a gate-answered flag given without its value refuses with its own message"
}

# The write happens before the link is dropped, so a crash between them leaves a
# surviving link and the retry is idempotent against the item's own state.
test_a_surviving_link_always_means_the_write_did_not_land() {
  local home link out
  home=$(make_home write-then-drop)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  link=$(run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation)
  run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt" >/dev/null
  printf 'item=%s\norigin=%s\nkey=%s\n' sample-scenario-choice sample-hosted-boot scenario-validation > "$link"
  if run_decisions "$home" gate-verify sample-hosted-boot >/dev/null 2>&1; then
    fail "a surviving link after a landed write must still refuse"
  fi
  out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/answer.txt") \
    || fail "the idempotent retry failed"
  assert_contains "$out" "already recorded" "the retry did not recognise its own landed write"
  [ ! -e "$link" ] || fail "the idempotent retry did not clear the link"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "the origin did not verify clean after the idempotent retry"
  pass "the item write lands before the link is dropped, and the retry is idempotent"
}

# Documented limit, not desired behaviour: the link's only handle on the item is
# its id, so a renamed item and one handed to another backlog are indistinguishable
# from removal. Asserted as what it is so a future change has to face it.
test_renamed_and_handed_off_items_are_a_documented_limit() {
  local home shape out
  for shape in renamed handed-off; do
    home=$(make_home "limit-$shape")
    gate_fixture "$home" sample-hosted-boot sample-scenario-choice
    run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
    tasks_in "$home" add sample-scenario-choice-renamed "captain decision pending" \
      --kind captain --repo sample --body "Captain decision pending as of 2026-07-14." >/dev/null
    tasks_in "$home" hold sample-scenario-choice-renamed --reason "captain decision pending" --kind captain >/dev/null
    tasks_in "$home" rm sample-scenario-choice >/dev/null 2>&1
    out=$(run_decisions "$home" gate-answered sample-hosted-boot scenario-validation \
      --answered-by firstmate --answer-file "$home/answer.txt") \
      || fail "$shape: gate-answered failed"
    assert_contains "$out" "no longer in this backlog" \
      "$shape: the limit is that this reads as removal; the message changed"
    run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
      || fail "$shape: verification did not pass, so the documented limit changed"
    assert_still_claims_captain_owes "$home" sample-scenario-choice-renamed \
      "$shape: the surviving item"
  done
  pass "a renamed or handed-off captain item is an accepted limit and still asserts its decision"
}

# Ported unchanged: the index reader has no silent skip, and the ordering keeps a
# dangling symlink reportable and a FIFO from hanging cleanup.
test_gate_index_refuses_every_unrecognised_record_shape() {
  local home dir shape out rc timeout_bin
  timeout_bin=$(command -v timeout || true)
  home=$(make_home gate-index-shapes)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  dir="$home/data/gate-links/sample-hosted-boot"
  for shape in well-formed leading-dot origin-missing key-missing key-mismatch \
    item-missing empty dangling-symlink directory fifo unlistable-index-dir; do
    rm -rf "$dir"
    mkdir -p "$dir"
    case "$shape" in
      well-formed) printf 'item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=sv\n' > "$dir/sv" ;;
      leading-dot) printf 'item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=.sv\n' > "$dir/.sv" ;;
      origin-missing) printf 'item=sample-scenario-choice\nkey=sv\n' > "$dir/sv" ;;
      key-missing) printf 'item=sample-scenario-choice\norigin=sample-hosted-boot\n' > "$dir/sv" ;;
      key-mismatch) printf 'item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=other\n' > "$dir/sv" ;;
      item-missing) printf 'origin=sample-hosted-boot\nkey=sv\n' > "$dir/sv" ;;
      empty) : > "$dir/sv" ;;
      dangling-symlink) ln -s "$home/no-such-target" "$dir/sv" ;;
      directory) mkdir "$dir/sv" ;;
      fifo)
        [ -n "$timeout_bin" ] || continue
        mkfifo "$dir/sv"
        ;;
      # Left empty on purpose: a listable empty directory verifies clean, so only
      # the unlistable one can make this shape refuse.
      unlistable-index-dir)
        chmod 000 "$dir"
        if [ -r "$dir" ] && [ -x "$dir" ]; then
          chmod 755 "$dir"
          continue
        fi
        ;;
    esac
    rc=0
    if [ "$shape" = fifo ]; then
      # A reader that hangs takes teardown with it and nothing reports a hang, so
      # this must fail the suite rather than wedge it.
      out=$("$timeout_bin" 10 env PATH="$home/fakebin:$PATH" FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" \
        gate-verify sample-hosted-boot 2>&1) || rc=$?
      [ "$rc" -ne 124 ] || fail "the index reader hung on a FIFO entry"
    else
      out=$(run_decisions "$home" gate-verify sample-hosted-boot 2>&1) || rc=$?
    fi
    [ "$shape" != unlistable-index-dir ] || chmod 755 "$dir"
    [ "$rc" -ne 0 ] || fail "$shape: an entry the reader cannot recognise passed verification"
    case "$out" in
      *"$dir"*) : ;;
      *) fail "$shape: the refusal did not name the offending file: $out" ;;
    esac
  done
  rm -rf "$dir"
  pass "every index record the reader cannot recognise blocks verification and is named"
}

# The property that makes every departure shape irrelevant by construction.
test_gate_verify_never_calls_the_backlog_backend() {
  local home
  home=$(make_home backend-free-verify)
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi must not be called by gate-verify" >&2
exit 127
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" gate-verify sample-hosted-boot > "$home/bf.out" 2> "$home/bf.err"; then
    fail "verification passed with an unreconciled link"
  fi
  assert_no_grep "must not be called" "$home/bf.err" "gate-verify called the backlog backend"
  run_decisions "$home" gate-not-raised sample-hosted-boot scenario-validation >/dev/null \
    || fail "retiring a link must not need the backlog backend either"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "verification did not pass once the link was gone"
  pass "gate-verify and gate-not-raised never call the backlog backend"
}

test_gate_link_validates_identity_ownership_and_the_owed_claim() {
  local home escaped
  home=$(make_home gate-link-validation)
  escaped="$home/escaped-gate"
  printf 'sentinel=unchanged\n' > "$escaped"
  gate_fixture "$home" sample-hosted-boot sample-scenario-choice
  local bad
  for bad in ../escaped-gate .. . .hidden; do
    if run_decisions "$home" gate-status "$bad" > "$home/gs.out" 2> "$home/gs.err"; then
      fail "gate status accepted an unsafe origin component: $bad"
    fi
    if run_decisions "$home" gate-verify "$bad" > "$home/gv.out" 2> "$home/gv.err"; then
      fail "gate verification accepted an unsafe origin component: $bad"
    fi
    if run_decisions "$home" gate-not-raised "$bad" key > "$home/gr.out" 2> "$home/gr.err"; then
      fail "gate retirement accepted an unsafe origin component: $bad"
    fi
  done
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "an invalid origin changed state outside the data directory"
  if run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot .hidden-key \
    > "$home/dot.out" 2> "$home/dot.err"; then
    fail "gate link accepted a decision key that a plain glob would hide"
  fi

  tasks_in "$home" add sample-plain-item "A plain ship item" --kind ship --repo sample >/dev/null
  if run_decisions "$home" gate-link sample-plain-item sample-hosted-boot scenario-validation \
    > "$home/kind.out" 2> "$home/kind.err"; then
    fail "gate link accepted an item that asserts no owed captain decision"
  fi
  assert_grep "owed captain decision" "$home/kind.err" "the refusal did not name the owed claim"
  if run_decisions "$home" gate-link sample-scenario-choice sample-missing-origin scenario-validation \
    > "$home/origin.out" 2> "$home/origin.err"; then
    fail "gate link accepted an origin this home does not own"
  fi
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "recording the same gate link twice must be idempotent"
  tasks_in "$home" add sample-other-choice "captain decision pending" --kind captain --repo sample >/dev/null
  tasks_in "$home" hold sample-other-choice --reason "captain decision pending" --kind captain >/dev/null
  if run_decisions "$home" gate-link sample-other-choice sample-hosted-boot scenario-validation \
    > "$home/dup.out" 2> "$home/dup.err"; then
    fail "gate link silently repointed an existing gate identity at another item"
  fi
  pass "gate links validate identity, ownership, and the owed claim before recording a pairing"
}

test_teardown_refuses_an_unreconciled_captain_gated_link() {
  local home id
  home=$(make_home gate-link-teardown)
  id=sample-linked-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample scenario" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample scenario review\n\nNo captain choice remains in this report.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "could not pass the unresolved-decision completion gate"
  tasks_in "$home" add sample-linked-choice "captain decision pending" --kind captain --repo sample \
    --body "Captain decision pending as of 2026-07-14." >/dev/null
  tasks_in "$home" hold sample-linked-choice --reason "captain decision pending" --kind captain >/dev/null
  run_decisions "$home" gate-link sample-linked-choice "$id" scenario-validation >/dev/null \
    || fail "could not record the gate link"

  if run_teardown "$home" "$id" > "$home/gate-teardown.out" 2> "$home/gate-teardown.err"; then
    fail "teardown erased a task whose captain-gated link was never reconciled"
  fi
  assert_grep "REFUSED" "$home/gate-teardown.err" "gate-link teardown refusal must be explicit"
  assert_grep "never reconciled" "$home/gate-teardown.err" "the refusal must surface the link detail"
  assert_present "$home/state/$id.meta" "refused teardown removed task metadata"

  run_decisions "$home" gate-not-raised "$id" scenario-validation >/dev/null \
    || fail "could not reconcile the link before teardown"
  run_teardown "$home" "$id" >/dev/null 2> "$home/gate-teardown2.err" \
    || fail "teardown failed after link reconciliation: $(cat "$home/gate-teardown2.err")"
  pass "teardown refuses until every recorded captain-gated link is reconciled"
}


test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_unlinked_captain_item_goes_stale_when_the_gate_answers_it
test_linked_captain_item_is_closed_and_the_link_disappears
test_owed_decision_is_keyed_on_the_hold_not_the_kind
test_gate_that_never_raised_the_question_writes_nothing
test_gate_answer_handles_every_departure_shape
test_an_unestablished_read_refuses_and_keeps_the_link
test_a_failed_answer_write_never_leaves_the_item_unheld_and_open
test_the_already_closed_note_is_written_once
test_a_missing_flag_value_refuses_with_its_own_message
test_a_surviving_link_always_means_the_write_did_not_land
test_renamed_and_handed_off_items_are_a_documented_limit
test_gate_index_refuses_every_unrecognised_record_shape
test_gate_verify_never_calls_the_backlog_backend
test_gate_link_validates_identity_ownership_and_the_owed_claim
test_teardown_refuses_an_unreconciled_captain_gated_link
