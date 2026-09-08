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


# The stale reading this suite must reproduce before it can prove the fix: a
# captain-kind item filed mid-flight for the same question a live worker's gate
# raises. Answering the gate under standing autonomy leaves the item untouched,
# so the backlog keeps asserting the captain owes an answer firstmate already
# gave. Privacy-safe synthetic names stand in for the observed incident.
stale_captain_item_fixture() {  # <home>
  local home=$1
  tasks_in "$home" add sample-hosted-boot "Fix the hosted boot loop" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create the live worker fixture"
  write_origin_meta "$home" sample-hosted-boot ship
  printf 'working: implementing the hosted boot fix\n' > "$home/state/sample-hosted-boot.status"
  tasks_in "$home" add sample-scenario-choice "Choose the unresolvable hosted scenario behaviour" \
    --kind captain --repo sample \
    --body "Captain decision pending as of 2026-07-14. Boot loops when no scenario validates." >/dev/null \
    || fail "could not create the captain-gated item fixture"
  tasks_in "$home" hold sample-scenario-choice --reason "captain scenario choice pending" --kind captain >/dev/null \
    || fail "could not activate the captain-gated fixture"
  printf 'Fall back to the seat default scenario and log the rejection.\n' > "$home/gate-answer.txt"
}

assert_still_claims_captain_owes() {  # <home> <label>
  local home=$1 label=$2 show
  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "state: queued" "$label: item is not queued"
  assert_contains "$show" "held: yes" "$label: item is not held"
  assert_contains "$show" "kind: captain" "$label: item is not kind captain"
  assert_contains "$show" "Captain decision pending" "$label: item no longer claims the captain owes an answer"
}

test_unlinked_captain_item_goes_stale_when_the_gate_answers_it() {
  local home out
  home=$(make_home stale-captain-item)
  stale_captain_item_fixture "$home"

  assert_still_claims_captain_owes "$home" "before"

  out=$(run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "reconciling an unlinked gate must succeed so the call can be unconditional"
  assert_contains "$out" "has no linked captain-gated item" \
    "an unlinked gate must say so rather than guess a pairing"

  assert_still_claims_captain_owes "$home" "after an unlinked gate answer"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "an origin with no recorded link must verify clean"
  pass "an unlinked captain-gated item survives its own gate's answer still claiming the captain owes it"
}

test_linked_captain_item_is_reconciled_when_the_gate_answers_it() {
  local home show out
  home=$(make_home linked-captain-item)
  stale_captain_item_fixture "$home"

  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "could not record the gate link"
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "recording the same gate link twice must be idempotent"
  assert_still_claims_captain_owes "$home" "after linking"
  if run_decisions "$home" gate-verify sample-hosted-boot > "$home/gv.out" 2> "$home/gv.err"; then
    fail "an unreconciled captain-gated link must not verify clean"
  fi
  assert_grep "unreconciled captain-gated links" "$home/gv.err" "verification must name the defect"

  out=$(run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "could not reconcile the linked captain-gated item"
  assert_contains "$out" "answered by firstmate -> sample-scenario-choice closed" \
    "reconciliation must name the decider and the closed item"

  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "state: done" "answered captain-gated item did not close"
  assert_contains "$show" "held: no" "answered captain-gated item is still held"
  assert_contains "$show" "Answered through gate sample-hosted-boot/scenario-validation" \
    "closed item lost the recorded gate identity"
  assert_contains "$show" "Decided by: firstmate" \
    "closed item does not record who actually decided"
  case "$show" in
    *"Captain decision pending"*) fail "closed item still asserts the captain owes an answer" ;;
  esac
  assert_grep "Captain decision pending" "$home/data/note-archive.md" \
    "the superseded captain-gated body was not archived"

  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "a reconciled link must verify clean"
  run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "an identical reconciliation retry must be idempotent"
  printf 'Refuse to boot and surface the rejection instead.\n' > "$home/changed-answer.txt"
  if run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/changed-answer.txt" \
    > "$home/drift.out" 2> "$home/drift.err"; then
    fail "reconciliation retry accepted a different answer"
  fi
  if run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by captain --answer-file "$home/gate-answer.txt" \
    > "$home/decider.out" 2> "$home/decider.err"; then
    fail "reconciliation retry accepted a different decider"
  fi
  if run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation --not-raised \
    > "$home/retire.out" 2> "$home/retire.err"; then
    fail "an answered gate was retired as never raised"
  fi
  pass "a recorded gate link reconciles the captain-gated item in the same step as the answer"
}

test_gate_that_never_raised_the_question_leaves_the_item_captain_owned() {
  local home out
  home=$(make_home unraised-gate)
  stale_captain_item_fixture "$home"
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "could not record the gate link"
  out=$(run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation --not-raised) \
    || fail "could not retire a gate that never raised the question"
  assert_contains "$out" "not raised" "retiring a link must say the gate never raised the question"
  assert_still_claims_captain_owes "$home" "after retiring an unraised gate"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "a retired link must verify clean"
  if run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" \
    > "$home/late.out" 2> "$home/late.err"; then
    fail "a retired link accepted a later gate answer"
  fi

  tasks_in "$home" unhold sample-scenario-choice >/dev/null \
    || fail "could not release the captain hold for the ordinary captain close"
  tasks_in "$home" "done" sample-scenario-choice \
    --note "Captain answered this in the standup: fall back to the seat default." >/dev/null \
    || fail "could not close the item through the ordinary captain path"
  out=$(run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation --not-raised) \
    || fail "retrying a retired link must stay idempotent after the item closes"
  assert_not_contains "$out" "left open" \
    "a retired link must not claim the item is left open once the item is closed"
  pass "a gate that never raised the question leaves the captain-gated item open and captain-owned"
}

# The captain closes the linked item through the ordinary captain path while the
# link is still open. The gate is then answered, so the only honest reconciliation
# is one that records this gate's answer without claiming it closed the item and
# without pretending the gate never raised the question.
test_gate_answer_reconciles_an_item_closed_by_another_authority() {
  local home id link show out
  home=$(make_home externally-closed-item)
  id=sample-external-close
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample scenario" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample scenario review\n\nNo captain choice remains in this report.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "could not pass the unresolved-decision completion gate"
  tasks_in "$home" add sample-external-choice "Choose the sample scenario behaviour" \
    --kind captain --repo sample --body "Captain decision pending as of 2026-07-14." >/dev/null
  tasks_in "$home" hold sample-external-choice --reason "captain scenario choice pending" --kind captain >/dev/null
  printf 'Fall back to the seat default scenario and log the rejection.\n' > "$home/gate-answer.txt"
  run_decisions "$home" gate-link sample-external-choice "$id" scenario-validation >/dev/null \
    || fail "could not record the gate link"

  tasks_in "$home" unhold sample-external-choice >/dev/null \
    || fail "could not release the captain hold for the ordinary captain close"
  tasks_in "$home" "done" sample-external-choice \
    --note "Captain answered this in the standup: fall back to the seat default." >/dev/null \
    || fail "could not close the item through the ordinary captain path"

  assert_contains "$(cat "$home/data/gate-links/$id/scenario-validation")" "state=open" \
    "closing the item outside this mechanism must not change the recorded link state"

  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "--answered-by must reconcile a link whose item another authority closed"
  assert_contains "$out" "was already closed by external" \
    "reconciliation must say this command did not close the item"

  link="$home/data/gate-links/$id/scenario-validation"
  assert_grep "state=answered" "$link" "an externally closed item must leave the link answered"
  assert_grep "closed_by=external" "$link" "the link must record who closed the item"
  assert_grep "decided_by=firstmate" "$link" "the link must record the actual decider"

  show=$(tasks_in "$home" show sample-external-choice --full)
  assert_contains "$show" "Captain answered this in the standup" \
    "reconciliation overwrote the record of who actually closed the item"
  assert_contains "$show" "Also answered through gate $id/scenario-validation. Decided by: firstmate." \
    "the closed item did not gain this gate's truthful outcome note"

  run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "reconciling an externally closed item must be idempotent"
  show=$(tasks_in "$home" show sample-external-choice --full)
  [ "$(printf '%s' "$show" | grep -o "Also answered through gate $id/scenario-validation" | wc -l)" -eq 1 ] \
    || fail "an idempotent retry duplicated the gate outcome note"

  run_decisions "$home" gate-verify "$id" >/dev/null \
    || fail "a reconciled link must verify clean"
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown stayed blocked after an honest reconciliation: $(cat "$home/teardown.err")"
  pass "a question settled by another authority reconciles without a false record"
}

# Two live workers raise the same captain question, so both gates are linked to
# one item. The second gate must record the first gate as the closing authority
# instead of overwriting the first gate's record or blocking teardown forever.
test_second_linked_gate_records_the_first_as_the_closing_authority() {
  local home link show out
  home=$(make_home double-linked-gate)
  stale_captain_item_fixture "$home"
  tasks_in "$home" add sample-hosted-retry "Fix the hosted retry loop" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create the second live worker fixture"
  write_origin_meta "$home" sample-hosted-retry ship

  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "could not record the first gate link"
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-retry scenario-validation >/dev/null \
    || fail "could not record the second gate link on the same item"
  run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "could not reconcile the first gate"

  out=$(run_decisions "$home" gate-resolve sample-hosted-retry scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "the second gate must still reconcile after the first gate closed the item"
  assert_contains "$out" "was already closed by sample-hosted-boot/scenario-validation" \
    "the second gate must name the gate that actually closed the item"

  link="$home/data/gate-links/sample-hosted-retry/scenario-validation"
  assert_grep "closed_by=sample-hosted-boot/scenario-validation" "$link" \
    "the second link must record the first gate as the closing authority"

  show=$(tasks_in "$home" show sample-scenario-choice --full)
  assert_contains "$show" "Answered through gate sample-hosted-boot/scenario-validation." \
    "the first gate's record of who answered was destroyed"
  assert_contains "$show" "Also answered through gate sample-hosted-retry/scenario-validation. Decided by: firstmate." \
    "the item did not gain the second gate's outcome note"

  run_decisions "$home" gate-verify sample-hosted-retry >/dev/null \
    || fail "the second reconciled link must verify clean"
  if run_decisions "$home" gate-resolve sample-hosted-retry scenario-validation --not-raised \
    > "$home/second-nr.out" 2> "$home/second-nr.err"; then
    fail "an answered second gate was retired as never raised"
  fi
  assert_not_contains "$(cat "$home/second-nr.out")" "not raised" \
    "no supported path may print a not-raised reading while the linked item is closed"
  pass "a second gate linked to one item records the first gate as the closing authority"
}

# A recorded link's gate never raised the question, and the item was closed by
# another authority before the link was retired. Retiring it must stay possible
# and must not claim the item was left open or that this gate answered anything.
test_unraised_link_retires_after_another_authority_closed_the_item() {
  local home id link before after out
  home=$(make_home unraised-after-close)
  id=sample-unraised-close
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample scenario" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample scenario review\n\nNo captain choice remains in this report.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "could not pass the unresolved-decision completion gate"
  tasks_in "$home" add sample-unraised-choice "Choose the sample scenario behaviour" \
    --kind captain --repo sample --body "Captain decision pending as of 2026-07-14." >/dev/null
  tasks_in "$home" hold sample-unraised-choice --reason "captain scenario choice pending" --kind captain >/dev/null
  run_decisions "$home" gate-link sample-unraised-choice "$id" scenario-validation >/dev/null \
    || fail "could not record the gate link"

  tasks_in "$home" unhold sample-unraised-choice >/dev/null \
    || fail "could not release the captain hold for the ordinary captain close"
  tasks_in "$home" "done" sample-unraised-choice \
    --note "Captain answered this in the standup: fall back to the seat default." >/dev/null \
    || fail "could not close the item through the ordinary captain path"
  before=$(tasks_in "$home" show sample-unraised-choice --full)

  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised) \
    || fail "a gate that never raised the question must still retire after the item closed"
  assert_contains "$out" "not raised; sample-unraised-choice was already closed by external" \
    "retiring the link must name the authority that actually closed the item"
  assert_not_contains "$out" "left open" \
    "no supported path may claim the item is left open once it is closed"

  link="$home/data/gate-links/$id/scenario-validation"
  assert_grep "state=not-raised" "$link" "the retired link must record that the gate never raised the question"
  assert_grep "closed_by=external" "$link" "the retired link must record who closed the item"
  after=$(tasks_in "$home" show sample-unraised-choice --full)
  [ "$before" = "$after" ] \
    || fail "retiring an unraised link modified the captain item it never answered"

  run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised >/dev/null \
    || fail "retiring an already retired link must be idempotent"
  run_decisions "$home" gate-verify "$id" >/dev/null \
    || fail "a retired link must verify clean"
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown stayed blocked after an honest retirement: $(cat "$home/teardown.err")"
  pass "an unraised link retires honestly after another authority closed the item"
}

# The index reader has no silent skip, so every record shape it cannot fully
# recognise blocks verification and names the file, and gate-status shows it.
# A reader that opens an index entry before checking its type blocks forever and
# takes teardown with it. These run the reader under a bound and return 124 on a
# block, so the caller can fail loudly instead of stalling the suite.
fm_bounded_decisions() {  # <home> <command args...>
  local home=$1
  shift
  if ! command -v timeout >/dev/null 2>&1; then
    run_decisions "$home" "$@"
    return
  fi
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    timeout 30 "$ROOT/bin/fm-decision-hold.sh" "$@"
}

test_gate_index_refuses_every_unrecognised_record_shape() {
  local home dir row name category shape body file status rc
  home=$(make_home gate-index-shapes)
  stale_captain_item_fixture "$home"
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "could not record the gate link"
  run_decisions "$home" gate-resolve sample-hosted-boot scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "could not reconcile the baseline link"
  dir="$home/data/gate-links/sample-hosted-boot"
  run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
    || fail "the baseline index must verify clean before planting record shapes"

  # <file name>|<open or unrecognised>|<record|symlink|fifo>|<payload>
  local -a shapes=(
    'still-open|open|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=still-open\nstate=open\n'
    '.hidden-key|unrecognised|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=.hidden-key\nstate=open\n'
    'absent-state|unrecognised|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=absent-state\n'
    'unknown-state|unrecognised|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=unknown-state\nstate=retired\n'
    'absent-origin|unrecognised|record|item=sample-scenario-choice\nkey=absent-origin\nstate=open\n'
    'absent-key|unrecognised|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nstate=open\n'
    'mismatched-key|unrecognised|record|item=sample-scenario-choice\norigin=sample-hosted-boot\nkey=other-key\nstate=open\n'
    'empty-record|unrecognised|record|'
    'dangling-link|unrecognised|symlink|no-such-target'
    'blocking-fifo|unrecognised|fifo|'
  )
  for row in "${shapes[@]}"; do
    name=${row%%|*}
    body=${row#*|}
    category=${body%%|*}
    body=${body#*|}
    shape=${body%%|*}
    body=${body#*|}
    file="$dir/$name"
    case "$shape" in
      record) printf '%b' "$body" > "$file" ;;
      symlink) ln -s "$dir/$body" "$file" ;;
      fifo)
        if ! command -v mkfifo >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
          echo "skip: mkfifo or timeout not found, FIFO index row not exercised"
          continue
        fi
        mkfifo "$file"
        ;;
    esac
    rc=0
    fm_bounded_decisions "$home" gate-verify sample-hosted-boot \
      > "$home/shape.out" 2> "$home/shape.err" || rc=$?
    [ "$rc" -ne 124 ] \
      || fail "gate-verify blocked on record shape $name instead of refusing"
    [ "$rc" -ne 0 ] || fail "gate-verify passed an index holding record shape $name"
    if [ "$category" = unrecognised ]; then
      assert_grep "unrecognised captain-gated link records" "$home/shape.err" \
        "record shape $name must refuse as unrecognised"
      assert_grep "$file" "$home/shape.err" \
        "the refusal for record shape $name must name the offending file"
      rc=0
      fm_bounded_decisions "$home" gate-status sample-hosted-boot \
        > "$home/shape-status.out" 2>/dev/null || rc=$?
      [ "$rc" -ne 124 ] \
        || fail "gate-status blocked on record shape $name instead of reporting it"
      status=$(cat "$home/shape-status.out")
      assert_contains "$status" "unrecognised" "gate-status hid record shape $name"
      assert_contains "$status" "$file" \
        "gate-status must name the file gate-verify refuses on for record shape $name"
    else
      assert_grep "unreconciled captain-gated links: $name ($file)" "$home/shape.err" \
        "record shape $name must refuse as an open link and name its path"
    fi
    rm -f "$file"
    run_decisions "$home" gate-verify sample-hosted-boot >/dev/null \
      || fail "removing record shape $name did not restore a clean index"
  done

  [ "$(find "$dir" -mindepth 1 | wc -l)" -eq 1 ] \
    || fail "a completed write left a staged file inside the per-origin index directory"
  pass "every index record the reader cannot recognise blocks verification and is named"
}

# Retiring a link is a statement about the link, never about the item, so every
# way the item can leave this home must still leave the link retirable and the
# origin tearable down. The alternative is a link no verb can clear and a
# teardown that only --force can complete.
unreadable_item_home() {  # <name> <origin-id> <item-id>
  local home=$1 id=$2 item=$3
  home=$(make_home "$home")
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample scenario" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample scenario review\n\nNo captain choice remains in this report.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "could not pass the unresolved-decision completion gate"
  tasks_in "$home" add "$item" "Choose the sample scenario behaviour" \
    --kind captain --repo sample --body "Captain decision pending as of 2026-07-14." >/dev/null
  tasks_in "$home" hold "$item" --reason "captain scenario choice pending" --kind captain >/dev/null
  run_decisions "$home" gate-link "$item" "$id" scenario-validation >/dev/null \
    || fail "could not record the gate link"
  printf '%s\n' "$home"
}

test_unraised_link_retires_whatever_became_of_the_item() {
  local home id item link out shape observed tail row rest

  id=sample-item-shape
  item=sample-shape-choice

  # <shape>|<expected item_observed>|<expected outcome tail after the item id>
  local -a shapes=(
    'removed|absent-here|is absent from this home'
    'handed-off|absent-here|is absent from this home'
    're-kinded|present-other-kind|is no longer a captain item and is still open'
    'backend-unavailable|backend-unusable|could not be read because the backlog backend is unusable'
    'hold-flag-missing|present-captain|left open'
  )
  for row in "${shapes[@]}"; do
    shape=${row%%|*}
    rest=${row#*|}
    observed=${rest%%|*}
    tail=${rest#*|}
    home=$(unreadable_item_home "item-shape-$shape" "$id" "$item")
    case "$shape" in
      removed)
        tasks_in "$home" unhold "$item" >/dev/null
        tasks_in "$home" rm "$item" >/dev/null \
          || fail "could not remove the linked item"
        ;;
      handed-off)
        printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/secondmate-backlog.md"
        tasks_in "$home" mv "$item" --to data/secondmate-backlog.md >/dev/null \
          || fail "could not hand the linked item to another backlog"
        ;;
      re-kinded)
        tasks_in "$home" unhold "$item" >/dev/null
        tasks_in "$home" update "$item" --kind ship >/dev/null \
          || fail "could not change the linked item's kind"
        ;;
      backend-unavailable)
        cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi: backend unavailable" >&2
exit 1
SH
        chmod +x "$home/fakebin/tasks-axi"
        ;;
      hold-flag-missing)
        # A tasks-axi that still reads the item but no longer advertises the
        # captain-hold flag says nothing about whether the item is readable.
        cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  echo "usage: tasks-axi hold <id> [flags]"
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
SH
        chmod +x "$home/fakebin/tasks-axi"
        ;;
    esac

    link="$home/data/gate-links/$id/scenario-validation"
    out=$(run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised) \
      || fail "--not-raised must retire a link whose item is $shape"
    assert_contains "$out" "not raised; $item $tail" \
      "the outcome for a $shape item must say what was actually observed"
    assert_grep "state=not-raised" "$link" "the $shape item left the link unretired"
    assert_grep "item_observed=$observed" "$link" \
      "the $shape item must record its own observation, never another situation's"
    assert_no_grep "closed_by=" "$link" \
      "an item not observed closed must record no closing authority at all"

    rm -f "$home/fakebin/tasks-axi"
    run_decisions "$home" gate-verify "$id" >/dev/null \
      || fail "a link retired against a $shape item must verify clean"
    run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
      || fail "teardown stayed blocked after retiring against a $shape item: $(cat "$home/teardown.err")"
  done

  # external must stay reachable under both present observations, which is the
  # value a single unreadable token used to swallow.
  for shape in present-captain present-other-kind; do
    home=$(unreadable_item_home "item-closed-$shape" "$id" "$item")
    link="$home/data/gate-links/$id/scenario-validation"
    tasks_in "$home" unhold "$item" >/dev/null
    [ "$shape" = present-captain ] \
      || tasks_in "$home" update "$item" --kind ship >/dev/null
    tasks_in "$home" "done" "$item" --note "Captain answered this in the standup." >/dev/null
    out=$(run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised) \
      || fail "--not-raised must retire a link whose $shape item is closed"
    assert_contains "$out" "was already closed by external" \
      "a closed $shape item with no marker must be reported as external"
    assert_grep "item_observed=$shape" "$link" \
      "a closed $shape item must record its own observation"
    assert_grep "closed_by=external" "$link" \
      "a closed $shape item with no marker must record external"
  done

  # The printed line and the durable record come from the same values, so a
  # record that once knew a closing authority cannot keep claiming one while the
  # outcome says the item is no longer observable.
  home=$(unreadable_item_home item-shape-mixed "$id" "$item")
  link="$home/data/gate-links/$id/scenario-validation"
  tasks_in "$home" unhold "$item" >/dev/null
  tasks_in "$home" "done" "$item" --note "Captain answered this in the standup." >/dev/null
  run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised >/dev/null \
    || fail "could not record the first observation"
  assert_grep "closed_by=external" "$link" "the first observation must record external"
  tasks_in "$home" rm "$item" >/dev/null || fail "could not remove the closed item"
  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised) \
    || fail "a retry must not be rejected merely because the item became unobservable"
  assert_contains "$out" "$item is absent from this home" \
    "the retry outcome must state the current observation"
  assert_grep "item_observed=absent-here" "$link" \
    "the retry record must state the current observation, not a stale one"
  assert_no_grep "closed_by=" "$link" \
    "the record must not keep a closing authority the outcome line no longer claims"
  pass "an unraised link records what it observed about the item, never a placeholder"
}

# A situation the classifier cannot name must refuse rather than absorb into the
# nearest token, so a future precondition forces a new named observation. The
# named four are exhaustive today, so the seam is the classifier itself.
test_unnamed_item_observation_refuses_rather_than_defaulting() {
  local home link out
  home=$(make_home unnamed-observation)
  stale_captain_item_fixture "$home"
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null \
    || fail "could not record the gate link"
  link="$home/data/gate-links/sample-hosted-boot/scenario-validation"
  if out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$0" --help >/dev/null
      observe_gate_item() { GATE_ITEM_OBSERVED=speculative; GATE_ITEM_STATE=; GATE_ITEM_BODY=; }
      retire_gate_link "$1" sample-scenario-choice sample-hosted-boot scenario-validation
    ' "$ROOT/bin/fm-decision-hold.sh" "$link" 2>&1); then
    fail "an unnamed observation was absorbed instead of refused: $out"
  fi
  assert_contains "$out" "could not classify what this home observes" \
    "the refusal must name the situation it could not classify"
  assert_contains "$out" "speculative" "the refusal must quote the unnamed observation"
  assert_grep "state=open" "$link" "a refused classification must not retire the link"
  pass "an observation the classifier cannot name refuses rather than defaulting"
}

# A gate that raised and was answered must record that, whatever became of the
# item. Pushing the operator onto --not-raised because it is the verb that still
# runs is how a false "never asked" record gets written.
test_answered_gate_records_the_answer_when_the_item_cannot_be_written() {
  local home id item link out shape observed tail row rest before

  id=sample-answered-shape
  item=sample-answered-choice

  # <shape>|<expected item_observed>|<expected outcome tail>
  local -a shapes=(
    're-kinded|present-other-kind|is no longer a captain item and was not written'
    'removed|absent-here|is absent from this home and was not written'
  )
  for row in "${shapes[@]}"; do
    shape=${row%%|*}
    rest=${row#*|}
    observed=${rest%%|*}
    tail=${rest#*|}
    home=$(unreadable_item_home "answered-shape-$shape" "$id" "$item")
    printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"
    tasks_in "$home" unhold "$item" >/dev/null
    case "$shape" in
      re-kinded)
        tasks_in "$home" update "$item" --kind ship >/dev/null \
          || fail "could not change the linked item's kind"
        before=$(tasks_in "$home" show "$item" --full)
        ;;
      removed)
        tasks_in "$home" rm "$item" >/dev/null || fail "could not remove the linked item"
        before=''
        ;;
    esac

    link="$home/data/gate-links/$id/scenario-validation"
    out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
      --answered-by firstmate --answer-file "$home/gate-answer.txt") \
      || fail "--answered-by must record the answer when the $shape item cannot be written"
    assert_contains "$out" "answered by firstmate; recorded against the link only because $item $tail" \
      "the outcome must say the answer was recorded against the link alone"
    assert_grep "state=answered" "$link" \
      "a gate that answered the question must never be recorded as not raised"
    assert_no_grep "state=not-raised" "$link" \
      "the false never-asked record must stay unreachable for an answered gate"
    assert_grep "item_observed=$observed" "$link" "the $shape item must record its own observation"
    assert_grep "decided_by=firstmate" "$link" "the actual decider must still be recorded"
    assert_grep "answer_digest=" "$link" "the answer digest must still be recorded"
    if [ -n "$before" ]; then
      [ "$before" = "$(tasks_in "$home" show "$item" --full)" ] \
        || fail "the $shape item was written even though it is not a captain item"
    fi

    run_decisions "$home" gate-resolve "$id" scenario-validation \
      --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
      || fail "an identical retry must stay idempotent for a $shape item"
    run_decisions "$home" gate-verify "$id" >/dev/null \
      || fail "a link answered against a $shape item must verify clean"
    run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
      || fail "teardown stayed blocked after answering against a $shape item: $(cat "$home/teardown.err")"
  done
  pass "an answered gate records the answer against the link when the item cannot be written"
}

# A backlog that could not be READ is not an item that is not THERE, and the
# difference is exactly what tasks-axi's error code reports.
test_unreadable_backlog_refuses_instead_of_claiming_the_item_is_absent() {
  local home id item link before out
  id=sample-unreadable-backlog
  item=sample-unreadable-choice
  home=$(unreadable_item_home unreadable-backlog "$id" "$item")
  link="$home/data/gate-links/$id/scenario-validation"
  before=$(cat "$link")

  mv "$home/data/backlog.md" "$home/data/backlog.saved"
  mkdir -p "$home/data/backlog.md"
  if run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised \
    > "$home/unreadable.out" 2> "$home/unreadable.err"; then
    fail "an unreadable backlog was recorded as an absent item"
  fi
  assert_grep "could not read $home/data/backlog.md" "$home/unreadable.err" \
    "the refusal must name the backlog it could not read"
  [ "$before" = "$(cat "$link")" ] \
    || fail "a refused reconciliation wrote to the link record"
  if run_teardown "$home" "$id" > "$home/unreadable-teardown.out" 2> "$home/unreadable-teardown.err"; then
    fail "teardown proceeded while the backlog was unreadable"
  fi
  assert_grep "REFUSED" "$home/unreadable-teardown.err" \
    "teardown must stay blocked while the backlog is unreadable"

  rmdir "$home/data/backlog.md"
  mv "$home/data/backlog.saved" "$home/data/backlog.md"
  tasks_in "$home" unhold "$item" >/dev/null
  tasks_in "$home" rm "$item" >/dev/null || fail "could not remove the linked item"
  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised) \
    || fail "a genuinely missing item must still reconcile"
  assert_contains "$out" "$item is absent from this home" \
    "a genuinely missing item must still be observed as absent"
  assert_grep "item_observed=absent-here" "$link" \
    "a genuinely missing item must still record absent-here"
  pass "an unreadable backlog refuses by name while a genuinely missing item still reconciles"
}

# Both present observations share one closing-authority derivation, so neither
# can drift into letting this gate name itself as the other authority.
test_retiring_refuses_when_this_gate_itself_closed_the_item() {
  local home id item link shape out
  id=sample-self-closed
  item=sample-self-closed-choice
  for shape in present-captain present-other-kind; do
    home=$(unreadable_item_home "self-closed-$shape" "$id" "$item")
    link="$home/data/gate-links/$id/scenario-validation"
    printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"
    run_decisions "$home" gate-resolve "$id" scenario-validation \
      --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
      || fail "could not answer the gate"
    # Reproduce a resolve interrupted between closing the item and writing the
    # link, which is the only way a closed item meets an open link record.
    sed 's/^state=answered$/state=open/' "$link" > "$link.rewritten"
    mv "$link.rewritten" "$link"
    [ "$shape" = present-captain ] \
      || tasks_in "$home" update "$item" --kind ship >/dev/null

    if run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised \
      > "$home/self.out" 2> "$home/self.err"; then
      fail "a $shape item closed through this very gate was retired as never raised"
    fi
    assert_grep "was closed through gate $id/scenario-validation" "$home/self.err" \
      "the refusal must name the gate that actually closed the $shape item"
    assert_no_grep "closed_by=$id/scenario-validation" "$link" \
      "this gate must never record itself as the other authority that closed the item"
  done
  pass "retiring refuses when this gate's own marker shows it closed the item"
}

# A deferred item write is not a reconciled link. This is the ticket's original
# stale reading reachable through the best-effort write path: the answer is
# recorded, the backend comes back, and the captain item is still queued, still
# held, and still claiming the captain owes an answer while cleanup passes.
test_a_deferred_item_write_keeps_the_link_unreconciled_until_it_lands() {
  local home id item link out show
  id=sample-deferred-write
  item=sample-deferred-choice
  home=$(unreadable_item_home deferred-write "$id" "$item")
  link="$home/data/gate-links/$id/scenario-validation"
  printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"

  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi: backend unavailable" >&2
exit 1
SH
  chmod +x "$home/fakebin/tasks-axi"
  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "--answered-by must record the answer while the backend is unusable"
  assert_contains "$out" "could not be written while the backlog backend is unusable" \
    "the outcome must say the item write was deferred"
  assert_grep "item_observed=backend-unusable" "$link" "the deferral must be recorded"
  rm -f "$home/fakebin/tasks-axi"

  if run_decisions "$home" gate-verify "$id" > "$home/dv.out" 2> "$home/dv.err"; then
    fail "a deferred item write was reported as a reconciled link"
  fi
  assert_grep "$link" "$home/dv.err" "the refusal must name the link whose write is outstanding"
  if run_teardown "$home" "$id" > "$home/dt.out" 2> "$home/dt.err"; then
    fail "teardown erased a task whose answered item write never landed"
  fi
  assert_grep "REFUSED" "$home/dt.err" "teardown must refuse while the write is outstanding"
  show=$(tasks_in "$home" show "$item" --full)
  assert_contains "$show" "Captain decision pending" \
    "the reproduction must leave the stale reading in place before the retry"

  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "the retry must complete the write the first run deferred"
  assert_contains "$out" "already answered by firstmate -> $item closed" \
    "the retry outcome must report the write it just completed"
  assert_grep "item_observed=present-captain" "$link" \
    "the completed retry must record that the item was written"
  assert_grep "closed_by=self" "$link" "the completed retry must record this gate as the closer"
  show=$(tasks_in "$home" show "$item" --full)
  assert_contains "$show" "state: done" "the repaired item did not close"
  assert_contains "$show" "Answered through gate $id/scenario-validation" \
    "the repaired item did not gain the recorded answer"
  case "$show" in
    *"Captain decision pending"*) fail "the repaired item still claims the captain owes an answer" ;;
  esac

  run_decisions "$home" gate-verify "$id" >/dev/null \
    || fail "a completed write must leave the link reconciled"
  run_teardown "$home" "$id" >/dev/null 2> "$home/dt2.err" \
    || fail "teardown stayed blocked after the write landed: $(cat "$home/dt2.err")"
  pass "a deferred item write keeps the link unreconciled until the retry lands it"
}

# A backend that reads the item but cannot perform the captain-hold write must
# not push the operator onto the one verb that still runs.
test_answered_gate_defers_rather_than_refusing_on_an_unwritable_backend() {
  local home id item link out
  id=sample-unwritable-backend
  item=sample-unwritable-choice
  home=$(unreadable_item_home unwritable-backend "$id" "$item")
  link="$home/data/gate-links/$id/scenario-validation"
  printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  echo "usage: tasks-axi hold <id> [flags]"
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt") \
    || fail "--answered-by must not refuse on a backend that cannot perform the item write"
  assert_contains "$out" "could not be written while the backlog backend is unusable" \
    "the outcome must say the item write was deferred"
  assert_grep "state=answered" "$link" "the answer must be recorded against the link"
  assert_no_grep "state=open" "$link" "an unwritable backend must not leave the link open"
  assert_no_grep "state=not-raised" "$link" \
    "--not-raised must never be the only verb that works here"
  if run_decisions "$home" gate-verify "$id" >/dev/null 2>&1; then
    fail "a write deferred by an unwritable backend was reported as reconciled"
  fi

  rm -f "$home/fakebin/tasks-axi"
  run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "the retry must land the write once the backend can perform it"
  run_decisions "$home" gate-verify "$id" >/dev/null \
    || fail "a completed write must leave the link reconciled"
  pass "an unwritable backend defers the item write instead of refusing the verb"
}

# The retry line is built from the recorded observation and closing authority,
# so it can never claim an item is closed while the record says otherwise.
test_answered_retry_line_agrees_with_the_recorded_observation() {
  local home id item link out shape observed tail row rest
  id=sample-retry-line
  item=sample-retry-choice

  # <shape>|<expected item_observed>|<expected outcome tail>
  local -a shapes=(
    'written|present-captain|-> sample-retry-choice closed'
    're-kinded|present-other-kind|is no longer a captain item and was not written'
    'removed|absent-here|is absent from this home and was not written'
  )
  for row in "${shapes[@]}"; do
    shape=${row%%|*}
    rest=${row#*|}
    observed=${rest%%|*}
    tail=${rest#*|}
    home=$(unreadable_item_home "retry-line-$shape" "$id" "$item")
    link="$home/data/gate-links/$id/scenario-validation"
    printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"
    case "$shape" in
      re-kinded)
        tasks_in "$home" unhold "$item" >/dev/null
        tasks_in "$home" update "$item" --kind ship >/dev/null
        ;;
      removed)
        tasks_in "$home" unhold "$item" >/dev/null
        tasks_in "$home" rm "$item" >/dev/null
        ;;
    esac
    run_decisions "$home" gate-resolve "$id" scenario-validation \
      --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
      || fail "could not record the answer for the $shape item"
    out=$(run_decisions "$home" gate-resolve "$id" scenario-validation \
      --answered-by firstmate --answer-file "$home/gate-answer.txt") \
      || fail "the retry must stay idempotent for the $shape item"
    assert_contains "$out" "already answered by firstmate" \
      "the retry must say it is a retry for the $shape item"
    assert_contains "$out" "$tail" \
      "the retry line must agree with the record for the $shape item"
    assert_grep "item_observed=$observed" "$link" \
      "the $shape item must keep its own recorded observation"
    if [ "$shape" != written ]; then
      case "$out" in
        *"closed"*) fail "the retry line claimed the $shape item is closed while it is not" ;;
      esac
      assert_no_grep "closed_by=" "$link" \
        "an item that was never observed closed must record no closing authority"
    fi
    run_decisions "$home" gate-verify "$id" >/dev/null \
      || fail "a $shape item leaves nothing outstanding and must verify clean"
    run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
      || fail "teardown stayed blocked for a $shape item: $(cat "$home/teardown.err")"
  done
  pass "the retry line agrees with the recorded observation and closing authority"
}

# An answered record whose observation matches no named value must refuse rather
# than being sorted onto either side of the outstanding-write distinction.
test_unclassified_answered_observation_refuses_in_verification() {
  local home id item link
  id=sample-unclassified
  item=sample-unclassified-choice
  home=$(unreadable_item_home unclassified-observation "$id" "$item")
  link="$home/data/gate-links/$id/scenario-validation"
  printf 'Fall back to the seat default scenario.\n' > "$home/gate-answer.txt"
  run_decisions "$home" gate-resolve "$id" scenario-validation \
    --answered-by firstmate --answer-file "$home/gate-answer.txt" >/dev/null \
    || fail "could not record the answer"
  sed 's/^item_observed=.*$/item_observed=speculative/' "$link" > "$link.rewritten"
  mv "$link.rewritten" "$link"

  if run_decisions "$home" gate-verify "$id" > "$home/uc.out" 2> "$home/uc.err"; then
    fail "an unclassified observation was sorted onto a side instead of refusing"
  fi
  assert_grep "records an observation this home cannot classify" "$home/uc.err" \
    "the refusal must name what it could not classify"
  assert_grep "speculative" "$home/uc.err" "the refusal must quote the unclassified observation"
  if run_teardown "$home" "$id" > "$home/uct.out" 2> "$home/uct.err"; then
    fail "teardown proceeded on a link whose observation cannot be classified"
  fi
  pass "an unclassified answered observation refuses in verification"
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
  tasks_in "$home" add sample-linked-choice "Choose the sample scenario behaviour" \
    --kind captain --repo sample --body "Captain decision pending as of 2026-07-14." >/dev/null
  tasks_in "$home" hold sample-linked-choice --reason "captain scenario choice pending" --kind captain >/dev/null
  run_decisions "$home" gate-link sample-linked-choice "$id" scenario-validation >/dev/null \
    || fail "could not record the gate link"

  if run_teardown "$home" "$id" > "$home/gate-teardown.out" 2> "$home/gate-teardown.err"; then
    fail "teardown erased a task whose captain-gated link was never reconciled"
  fi
  assert_grep "REFUSED" "$home/gate-teardown.err" "gate-link teardown refusal must be explicit"
  assert_grep "captain-gated" "$home/gate-teardown.err" "refusal must name the captain-gated link"
  assert_present "$home/state/$id.meta" "refused teardown removed task metadata"

  run_decisions "$home" gate-resolve "$id" scenario-validation --not-raised >/dev/null \
    || fail "could not reconcile the link before teardown"

  printf 'item=sample-linked-choice\norigin=%s\n' "$id" > "$home/data/gate-links/$id/truncated-write"
  if run_teardown "$home" "$id" > "$home/gate-teardown3.out" 2> "$home/gate-teardown3.err"; then
    fail "teardown erased a task whose index holds a record it cannot recognise"
  fi
  assert_grep "REFUSED" "$home/gate-teardown3.err" "unrecognised-record teardown refusal must be explicit"
  assert_grep "$home/data/gate-links/$id/truncated-write" "$home/gate-teardown3.err" \
    "the refusal must name the offending index file"
  assert_grep "remove the file reported above" "$home/gate-teardown3.err" \
    "the refusal must name the recovery that actually clears an unrecognised record"
  assert_present "$home/state/$id.meta" "refused teardown removed task metadata"
  rm -f "$home/data/gate-links/$id/truncated-write"

  run_teardown "$home" "$id" >/dev/null 2> "$home/gate-teardown2.err" \
    || fail "teardown failed after link reconciliation: $(cat "$home/gate-teardown2.err")"
  pass "teardown refuses until every recorded captain-gated link is reconciled"
}

test_gate_link_validates_identities_before_touching_state() {
  local home escaped bad
  home=$(make_home gate-link-validation)
  escaped="$home/escaped-gate"
  printf 'sentinel=unchanged\n' > "$escaped"
  # A bare dot component carries no slash, so it escapes the index directory
  # without tripping any slash check.
  for bad in ../escaped-gate .. . .hidden-origin; do
    if run_decisions "$home" gate-status "$bad" > "$home/gs.out" 2> "$home/gs.err"; then
      fail "gate status accepted an origin outside the index directory: $bad"
    fi
    if run_decisions "$home" gate-verify "$bad" > "$home/gvv.out" 2> "$home/gvv.err"; then
      fail "gate verification accepted an origin outside the index directory: $bad"
    fi
    if run_decisions "$home" gate-resolve "$bad" key --not-raised \
      > "$home/gr.out" 2> "$home/gr.err"; then
      fail "gate reconciliation accepted an origin outside the index directory: $bad"
    fi
    if run_decisions "$home" gate-resolve sample-hosted-boot "$bad" --not-raised \
      > "$home/grk.out" 2> "$home/grk.err"; then
      fail "gate reconciliation accepted a decision key outside the index directory: $bad"
    fi
  done
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "an invalid origin changed state outside the data directory"

  stale_captain_item_fixture "$home"
  if run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot .hidden-key \
    > "$home/dot.out" 2> "$home/dot.err"; then
    fail "gate link accepted a decision key that begins with a dot"
  fi
  [ ! -e "$home/data/gate-links/sample-hosted-boot/.hidden-key" ] \
    || fail "a rejected decision key still created an index record"
  tasks_in "$home" add sample-plain-item "A plain ship item" --kind ship --repo sample >/dev/null
  if run_decisions "$home" gate-link sample-plain-item sample-hosted-boot scenario-validation \
    > "$home/kind.out" 2> "$home/kind.err"; then
    fail "gate link accepted a backlog item that is not kind captain"
  fi
  if run_decisions "$home" gate-link sample-scenario-choice sample-missing-origin scenario-validation \
    > "$home/origin.out" 2> "$home/origin.err"; then
    fail "gate link accepted an origin this home does not own"
  fi
  run_decisions "$home" gate-link sample-scenario-choice sample-hosted-boot scenario-validation >/dev/null
  tasks_in "$home" add sample-other-choice "Another captain question" --kind captain --repo sample >/dev/null
  if run_decisions "$home" gate-link sample-other-choice sample-hosted-boot scenario-validation \
    > "$home/dup.out" 2> "$home/dup.err"; then
    fail "gate link silently repointed an existing gate identity at another item"
  fi
  pass "gate links validate identity, ownership, and item kind before recording a pairing"
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
test_linked_captain_item_is_reconciled_when_the_gate_answers_it
test_gate_that_never_raised_the_question_leaves_the_item_captain_owned
test_gate_answer_reconciles_an_item_closed_by_another_authority
test_second_linked_gate_records_the_first_as_the_closing_authority
test_unraised_link_retires_after_another_authority_closed_the_item
test_unraised_link_retires_whatever_became_of_the_item
test_unnamed_item_observation_refuses_rather_than_defaulting
test_answered_gate_records_the_answer_when_the_item_cannot_be_written
test_a_deferred_item_write_keeps_the_link_unreconciled_until_it_lands
test_answered_gate_defers_rather_than_refusing_on_an_unwritable_backend
test_answered_retry_line_agrees_with_the_recorded_observation
test_unclassified_answered_observation_refuses_in_verification
test_unreadable_backlog_refuses_instead_of_claiming_the_item_is_absent
test_retiring_refuses_when_this_gate_itself_closed_the_item
test_gate_index_refuses_every_unrecognised_record_shape
test_teardown_refuses_an_unreconciled_captain_gated_link
test_gate_link_validates_identities_before_touching_state
