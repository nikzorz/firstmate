#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
# Exported so the nesting fork fixture below can launch a second fake harness
# from inside the first; a per-invocation prefix assignment would be read by the
# inner shell only after the outer command word had already expanded.
export FAKE_CLAUDE="$FAKEBIN/claude"

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    delivered)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
printf 'watcher: delivered - cycle ended after queueing an actionable wake\n'
exit 0
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# --- registration contract ----------------------------------------------------

test_settings_registers_autoarm_with_multi_hour_timeout() {
  local settings
  settings="$ROOT/.claude/settings.json"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))]
      | length == 1
  ' "$settings" >/dev/null || fail "settings must register exactly one Stop auto-arm hook"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0]
      | .asyncRewake == true and .type == "command" and (.timeout | type == "number" and . >= 28800)
  ' "$settings" >/dev/null || fail "auto-arm must be asyncRewake with an explicit timeout of at least 28800s (the 600s default is forbidden)"
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh"))][0].command
      | contains("&") | not
  ' "$settings" >/dev/null || fail "auto-arm registration must not use shell fire-and-forget"
  grep -q '"$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm must foreground the arm wrapper inside the hook-owned process tree"
  grep -q 'asyncRewake' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    || fail "auto-arm header must document its asyncRewake registration contract"
  pass "settings.json registers the asyncRewake auto-arm with timeout >= 28800 and a foreground arm"
}

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

test_arms_for_forked_session_under_new_pid() {
  local dir out status parent_pid fork_pid owner_after
  dir=$(make_primary_dir "$TMP_ROOT/forked-session")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The recorded owner STAYS ALIVE while an inner fake harness - the forked
  # session running under a new pid, the shape Claude Code produces when a
  # session is forked, resumed, or moved to the background - fires the hook.
  # Both bodies keep a trailing statement so bash cannot exec the child into the
  # parent's pid and collapse the two sessions this case depends on.
  out=$(printf '%s\n' '{"session_id":"forked"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        RC=0
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "%s\n" "$$" > "$FM_HOME/state/parent-pid"
        "$FAKE_CLAUDE" -c '"'"'RC=0; printf "%s\n" "$$" > "$FM_HOME/state/fork-pid"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh" || RC=$?; exit "$RC"'"'"' || RC=$?
        exit "$RC"
      ' 2>&1); status=$?
  parent_pid=$(cat "$dir/state/parent-pid")
  fork_pid=$(cat "$dir/state/fork-pid")
  owner_after=$(cat "$dir/state/.lock")
  [ "$parent_pid" != "$fork_pid" ] || fail "fork fixture collapsed onto one pid ($parent_pid): the forked session must be a separate process for this case to mean anything"
  expect_code 2 "$status" "a forked session under a new pid must arm and rewake for its own home"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for a forked session that owns this home"
  assert_contains "$out" "stale: fixture-win actionable" "forked-session rewake must carry the arm's reason line"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "forked-session arm must record outcome=rewake"
  [ "$owner_after" = "$fork_pid" ] || fail "forked session armed without claiming the lock: expected $fork_pid, got $owner_after (the still-live $parent_pid would arm this home too)"
  pass "auto-arm: a forked session under a new pid claims its own home instead of deferring to its parent"
}

test_only_one_of_parent_and_fork_arms() {
  local dir out status parent_pid fork_pid arms owner_after
  dir=$(make_primary_dir "$TMP_ROOT/one-owner")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # Descent grants ownership without taking it away from the recorded owner, so
  # both sessions could answer "this home is mine" and both could supervise it.
  # An operator who found two watchers on one home would have no safe blunt
  # remedy: killing watchers broadly reaches sibling homes running the same
  # watcher. So the fork STAYS ALIVE here while its parent reaches Stop too,
  # and exactly one of the two may arm.
  out=$(printf '%s\n' '{"session_id":"one-owner"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        RC=0
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "%s\n" "$$" > "$FM_HOME/state/parent-pid"
        "$FAKE_CLAUDE" -c '"'"'
           printf "%s\n" "$$" > "$FM_HOME/state/fork-pid"
           "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
           printf "fork_rc=%s\n" "$?"
           touch "$FM_HOME/state/fork-done"
           i=0
           while [ ! -e "$FM_HOME/state/release-fork" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
           exit 0
        '"'"' &
        i=0
        while [ ! -e "$FM_HOME/state/fork-done" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
        printf "%s\n" "{}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
        printf "parent_rc=%s\n" "$?"
        touch "$FM_HOME/state/release-fork"
        wait
        exit "$RC"
      ' 2>&1); status=$?
  parent_pid=$(cat "$dir/state/parent-pid")
  fork_pid=$(cat "$dir/state/fork-pid")
  owner_after=$(cat "$dir/state/.lock")
  arms=$(wc -l < "$dir/state/arm-ran" 2>/dev/null | tr -d '[:space:]')
  [ "$parent_pid" != "$fork_pid" ] || fail "one-owner fixture collapsed onto one pid ($parent_pid): the two sessions must be separate processes for this case to mean anything"
  expect_code 0 "$status" "one-owner fixture did not run to completion"
  assert_contains "$out" "fork_rc=2" "the forked session must arm and rewake for the home it claimed"
  assert_contains "$out" "parent_rc=0" "the session the fork descends from must go inert once the fork owns the home"
  [ "${arms:-0}" = 1 ] || fail "two live sessions armed one home: ${arms:-0} arms (parent $parent_pid, fork $fork_pid)"
  [ "$owner_after" = "$fork_pid" ] || fail "home did not end up owned by exactly the session that armed it: lock names $owner_after, fork is $fork_pid"
  pass "auto-arm: a live parent and the fork that descends from it arm one home exactly once"
}

# The exclusivity case above counts arms, which is the hook's own observable.
# This one counts what an operator would actually find: real watcher cycles
# started for one home, through the REAL bin/fm-watch-arm.sh and bin/fm-watch.sh
# rather than an arm fixture. The watcher singleton already stops two watchers
# from running at the same instant, so the duplicate this proves absent is two
# sessions each starting and owning a cycle of their own, one after the other,
# for as long as both live.
make_real_supervision_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  cp -R "$ROOT/bin/." "$dir/bin/"
  # The watcher refuses to run any state check until the legacy PR-check
  # migration is recorded complete; these fixture homes have no checks at all.
  printf 'fm-pr-check-migration-scan-v1\n' > "$dir/state/.pr-check-migration-scan-v1"
  printf 'fm-pr-check-migration-v1\n' > "$dir/state/.pr-check-migration-v1"
  chmod 0600 "$dir/state/.pr-check-migration-scan-v1" "$dir/state/.pr-check-migration-v1"
  printf '%s\n' "$dir"
}

test_one_real_watcher_cycle_across_parent_and_fork() {
  local dir out status parent_pid fork_pid cycles owner_after
  dir=$(make_real_supervision_dir "$TMP_ROOT/one-watcher")
  printf 'window=w\n' > "$dir/state/task.meta"
  # A status append is the wake that lets each armed cycle close quickly.
  out=$(printf '%s\n' '{"session_id":"one-watcher"}' \
    | FM_HOME="$dir" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
      FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=15 "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "%s\n" "$$" > "$FM_HOME/state/parent-pid"
        "$FAKE_CLAUDE" -c '"'"'
           printf "%s\n" "$$" > "$FM_HOME/state/fork-pid"
           printf "blocked: fork round\n" >> "$FM_HOME/state/task.status"
           "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
           printf "fork_rc=%s\n" "$?"
           touch "$FM_HOME/state/fork-done"
           i=0
           while [ ! -e "$FM_HOME/state/release-fork" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
           exit 0
        '"'"' &
        i=0
        while [ ! -e "$FM_HOME/state/fork-done" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
        printf "blocked: parent round\n" >> "$FM_HOME/state/task.status"
        printf "%s\n" "{}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
        printf "parent_rc=%s\n" "$?"
        touch "$FM_HOME/state/release-fork"
        wait
        exit 0
      ' 2>&1); status=$?
  parent_pid=$(cat "$dir/state/parent-pid")
  fork_pid=$(cat "$dir/state/fork-pid")
  owner_after=$(cat "$dir/state/.lock")
  cycles=$(wc -l < "$dir/state/.watch-cycle-exits.log" 2>/dev/null | tr -d '[:space:]')
  [ "$parent_pid" != "$fork_pid" ] || fail "real-watcher fixture collapsed onto one pid ($parent_pid)"
  expect_code 0 "$status" "real-watcher fixture did not run to completion"
  assert_contains "$out" "fork_rc=2" "the forked session must arm a real watcher cycle and rewake"
  assert_contains "$out" "parent_rc=0" "the still-live parent session must arm no watcher once the fork owns the home"
  [ "${cycles:-0}" = 1 ] || fail "one home got ${cycles:-0} watcher cycles from two live sessions:"$'\n'"$(sed 's/\t/ /g' "$dir/state/.watch-cycle-exits.log" 2>/dev/null)"
  [ "$owner_after" = "$fork_pid" ] || fail "the session that owns the watcher must own the lock: lock names $owner_after, fork is $fork_pid"
  pass "auto-arm: two live sessions on one home start exactly one real watcher cycle"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "watcher cycle FAILED" "failure rewake must carry the failure banner"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_contains "$out" "repair supervision" "failure rewake must direct the manual repair"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: watcher: FAILED translates to an exit-2 alarm rewake"
}

test_delivered_close_rewakes_without_failure_banner() {
  # An arm attached to another cycle reports only the delivered close: the wake
  # itself waits in the durable queue, so this still needs a handling turn, and
  # it must not be dressed as a supervision failure.
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/delivered")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" delivered
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a delivered cycle close must exit 2 so the queued wake gets a handling turn"
  assert_contains "$out" "firstmate watcher wake" "delivered rewake must carry the wake banner"
  assert_contains "$out" "watcher: delivered" "delivered rewake must carry the arm's delivered close"
  assert_contains "$out" "bin/fm-wake-drain.sh" "delivered rewake must direct the drain-first protocol"
  case "$out" in
    *"watcher cycle FAILED"*) fail "delivered close must not raise the supervision-failure alarm" ;;
  esac
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: delivered close rewakes for the queued wake without a failure alarm"
}

test_clean_close_exits_silently() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a clean arm close with no actionable reason must not rewake"
  [ -z "$out" ] || fail "clean close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: clean close exits silently with a clean epoch"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

test_settings_registers_autoarm_with_multi_hour_timeout
test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_arms_for_forked_session_under_new_pid
test_only_one_of_parent_and_fork_arms
test_one_real_watcher_cycle_across_parent_and_fork
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_failed_close_rewakes_with_failure_banner
test_delivered_close_rewakes_without_failure_banner
test_clean_close_exits_silently
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib
