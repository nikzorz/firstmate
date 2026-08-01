#!/usr/bin/env bash
# Behavior tests for the shared session-lock identity contract
# (bin/fm-session-lock-lib.sh) and the acquisition path that applies it
# (bin/fm-lock.sh).
#
# The contract has two halves that pull against each other, so both are pinned
# here:
#
#   - A session that moved to a NEW pid while the recorded owner is still alive
#     (Claude Code's forked, resumed, and backgrounded sessions run as a
#     descendant of the session that spawned them) still owns its own home.
#   - A GENUINELY DIFFERENT live session is still refused, so two sessions never
#     supervise one home. "Different live session refused" below is the load-
#     bearing case; the negative control right after it removes the liveness
#     protection from a copy and proves that refusal then stops happening, so
#     the refusal case cannot pass for an unrelated reason.
#
# Process shapes are built from a fake harness (a bash symlink named "claude",
# the same trick tests/fm-claude-stop-autoarm.test.sh uses) so no real harness,
# lock, or fleet state is touched. Every fake-harness body has two statements so
# bash cannot exec-optimize the wrapper away and collapse the process chain the
# test is asserting on.
# shellcheck disable=SC2016 # single quotes are deliberate: the fake harness child expands $$ and the fixture paths itself
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock)

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
# Exported once rather than re-assigned per invocation: the nesting fixtures run
# a fake harness inside a fake harness, and a "FAKE_CLAUDE=$FAKE_CLAUDE" prefix
# on the outer command would be read by the inner shell only after the command
# word had already expanded.
export FAKE_CLAUDE="$FAKEBIN/claude"

# A version-named harness binary: Claude Code's background and forked sessions
# exec <prefix>/share/claude/versions/<version>, so comm is a bare version
# string and only the executable path still carries the harness name.
VERSION_DIR="$TMP_ROOT/share/claude/versions"
mkdir -p "$VERSION_DIR"
ln -s /bin/bash "$VERSION_DIR/2.1.220"
FAKE_VERSIONED="$VERSION_DIR/2.1.220"

# A home whose bin/ holds the real lock scripts under test.
make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/bin"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-lock.sh"
  printf '%s\n' "$dir"
}

# Probe: sources the lib in the home under test and reports one answer on
# stdout. Run as a child of whatever process shape a test builds.
PROBE="$TMP_ROOT/probe.sh"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$FM_HOME/bin/fm-session-lock-lib.sh"
case "${1:-}" in
  owned)
    if fm_session_lock_owned_by_self "$FM_HOME/state"; then echo "owned=yes"; else echo "owned=no"; fi
    ;;
  harness-pid)
    fm_harness_ancestry_pid || echo NONE
    ;;
  *)
    echo "probe: unknown query '${1:-}'" >&2
    exit 2
    ;;
esac
SH
chmod +x "$PROBE"
export PROBE

# A fixture that nests one fake harness inside another only reproduces the bug
# while the two are SEPARATE processes. Bash exec-replaces itself with a
# trailing simple command, which silently collapses parent and child onto one
# pid and makes every ownership assertion vacuous - so every nesting fixture
# reports both pids and this guard refuses to let them be the same.
assert_distinct_fixture_pids() {
  local out=$1 parent fork
  parent=$(printf '%s\n' "$out" | sed -n 's/^parent=//p')
  fork=$(printf '%s\n' "$out" | sed -n 's/^fork=//p')
  [ -n "$parent" ] && [ -n "$fork" ] || fail "nesting fixture did not report both pids:"$'\n'"$out"
  [ "$parent" != "$fork" ] || fail "nesting fixture collapsed onto one pid ($parent): the child must be a separate process for this assertion to mean anything"
}

# --- 1. the recorded owner's own session still owns its lock ----------------

HOME_SELF=$(make_home "$TMP_ROOT/self")
out=$(FM_HOME="$HOME_SELF" "$FAKE_CLAUDE" -c '
  RC=0
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$PROBE" owned || RC=$?
  exit "$RC"
' 2>&1)
assert_contains "$out" "owned=yes" "the session whose own harness pid is recorded lost ownership of its lock"
pass "recorded owner's own session owns its lock"

# --- 2. a forked session under a new pid claims its own home ----------------
#
# The regression: the outer fake harness records its pid and STAYS ALIVE while
# an inner fake harness - the forked session - runs the probe. Before the fix,
# pid inequality plus a live recorded owner read this as a competing session.

HOME_FORK=$(make_home "$TMP_ROOT/fork")
out=$(FM_HOME="$HOME_FORK" "$FAKE_CLAUDE" -c '
  RC=0
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "parent=%s\n" "$$"
  "$FAKE_CLAUDE" -c '"'"'RC=0; printf "fork=%s\n" "$$"; "$PROBE" owned || RC=$?; exit "$RC"'"'"' || RC=$?
  exit "$RC"
' 2>&1)
assert_distinct_fixture_pids "$out"
assert_contains "$out" "owned=yes" "a forked session under a new pid was refused its own home's lock"
pass "forked session under a new pid claims its own home"

# --- 3. a forked session's claim re-points the lock at the live session ------

LOCK_FORK="$HOME_FORK/state/.lock"
rc=0
out=$(FM_HOME="$HOME_FORK" "$FAKE_CLAUDE" -c '
  RC=0
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "parent=%s\n" "$$"
  "$FAKE_CLAUDE" -c '"'"'RC=0; printf "fork=%s\n" "$$"; "$FM_HOME/bin/fm-lock.sh" || RC=$?; exit "$RC"'"'"' || RC=$?
  exit "$RC"
' 2>&1) || rc=$?
expect_code 0 "$rc" "fm-lock.sh refused a forked session claiming its own home"
assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh did not report an acquisition for the forked session"
assert_distinct_fixture_pids "$out"
fork_pid=$(printf '%s\n' "$out" | sed -n 's/^fork=//p')
parent_pid=$(printf '%s\n' "$out" | sed -n 's/^parent=//p')
written=$(cat "$LOCK_FORK")
[ "$written" = "$fork_pid" ] || fail "fm-lock.sh left the lock on '$written'; the forked session's own pid $fork_pid must own it (parent was $parent_pid)"
pass "forked session's claim re-points the lock at the session executing turns"

# --- 4. a genuinely different live session is still refused -----------------
#
# The other session is a SIBLING: alive, a verified harness, and not an ancestor
# of the probing session. This is the case that must never regress.

HOME_OTHER=$(make_home "$TMP_ROOT/other")
OTHER_PIDFILE="$TMP_ROOT/other.pid"
OTHER_KEEPALIVE="$TMP_ROOT/other.keepalive"
: > "$OTHER_KEEPALIVE"
# The keepalive loop (rather than a bare sleep) keeps this process reporting
# comm "claude": bash exec-replaces itself with a trailing simple command, and a
# fixture that turned into "sleep" would be judged not-a-harness and let the
# claim through for the wrong reason. The iteration cap bounds it if the test
# dies before its cleanup.
FM_HOME="$HOME_OTHER" OTHER_PIDFILE="$OTHER_PIDFILE" OTHER_KEEPALIVE="$OTHER_KEEPALIVE" \
  "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$OTHER_PIDFILE"
    i=0
    while [ -e "$OTHER_KEEPALIVE" ] && [ "$i" -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
    exit 0
  ' >/dev/null 2>&1 &
OTHER_WRAPPER=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$OTHER_PIDFILE" ] && break
  sleep 0.2
done
OTHER_PID=$(cat "$OTHER_PIDFILE" 2>/dev/null || true)
[ -n "$OTHER_PID" ] || fail "competing-session fixture never reported its pid"
printf '%s\n' "$OTHER_PID" > "$HOME_OTHER/state/.lock"

out=$(FM_HOME="$HOME_OTHER" "$FAKE_CLAUDE" -c '
  RC=0
  "$PROBE" owned || RC=$?
  exit "$RC"
' 2>&1)
assert_contains "$out" "owned=no" "a genuinely different live session was admitted as the lock owner"

rc=0
out=$(FM_HOME="$HOME_OTHER" "$FAKE_CLAUDE" -c '
  RC=0
  "$FM_HOME/bin/fm-lock.sh" || RC=$?
  exit "$RC"
' 2>&1) || rc=$?
expect_code 1 "$rc" "fm-lock.sh did not refuse a genuinely different live session"
assert_contains "$out" "another live firstmate session holds the lock" "fm-lock.sh refused without the competing-session diagnostic"
still=$(cat "$HOME_OTHER/state/.lock")
[ "$still" = "$OTHER_PID" ] || fail "refused claim still overwrote the lock: '$still' (expected $OTHER_PID)"
pass "genuinely different live session is refused and keeps the lock"

# --- 5. negative control: removing the liveness protection admits it ---------
#
# Same fixture, same competing live session, one difference: the copied lib
# answers "no live harness holds this" for every pid. If the refusal above ever
# passes without the liveness protection actually running, this control fails.

HOME_STRIPPED=$(make_home "$TMP_ROOT/stripped")
printf '%s\n' 'fm_harness_pid_alive() { return 1; }' >> "$HOME_STRIPPED/bin/fm-session-lock-lib.sh"
printf '%s\n' "$OTHER_PID" > "$HOME_STRIPPED/state/.lock"
rc=0
out=$(FM_HOME="$HOME_STRIPPED" "$FAKE_CLAUDE" -c '
  RC=0
  "$FM_HOME/bin/fm-lock.sh" || RC=$?
  exit "$RC"
' 2>&1) || rc=$?
expect_code 0 "$rc" "negative control: with liveness stripped, fm-lock.sh should have acquired (the refusal in case 4 is not load-bearing)"
assert_contains "$out" "lock acquired: harness pid" "negative control did not acquire with liveness stripped"
pass "negative control proves the refusal depends on the liveness protection"

rm -f "$OTHER_KEEPALIVE"
wait "$OTHER_WRAPPER" 2>/dev/null || true

# --- 6. a dead recorded owner is still reclaimable ---------------------------

HOME_STALE=$(make_home "$TMP_ROOT/stale")
DEAD_PID=$("$FAKE_CLAUDE" -c 'printf "%s\n" "$$"; :')
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$DEAD_PID" 2>/dev/null || break
  sleep 0.2
done
printf '%s\n' "$DEAD_PID" > "$HOME_STALE/state/.lock"
rc=0
out=$(FM_HOME="$HOME_STALE" "$FAKE_CLAUDE" -c '
  RC=0
  "$FM_HOME/bin/fm-lock.sh" || RC=$?
  exit "$RC"
' 2>&1) || rc=$?
expect_code 0 "$rc" "fm-lock.sh did not reclaim a lock whose recorded owner is dead"
assert_contains "$out" "lock acquired: harness pid" "stale reclaim did not report an acquisition"
pass "dead recorded owner is still reclaimable"

# --- 7. a recycled pid on a non-harness ancestor is not the owning session ---
#
# Descent alone must not confer ownership: if the recorded number is reused by
# an ordinary ancestor (a login shell, a multiplexer), it is not a session.

HOME_RECYCLED=$(make_home "$TMP_ROOT/recycled")
out=$(FM_HOME="$HOME_RECYCLED" "$FAKE_CLAUDE" -c '
  RC=0
  /bin/bash -c '"'"'RC=0; printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$PROBE" owned || RC=$?; exit "$RC"'"'"' || RC=$?
  exit "$RC"
' 2>&1)
assert_contains "$out" "owned=no" "a non-harness ancestor holding the recorded pid was accepted as the owning session"
pass "recycled pid on a non-harness ancestor is not the owning session"

# --- 8. a version-named harness binary resolves to its own session ----------
#
# Without this, the ancestry walk steps past a background or forked session
# (comm "2.1.220") and resolves to the long-lived daemon further up the tree,
# so the lock would name a process that outlives every session it hosts.

HOME_VERSIONED=$(make_home "$TMP_ROOT/versioned")
out=$(FM_HOME="$HOME_VERSIONED" FAKE_VERSIONED="$FAKE_VERSIONED" "$FAKE_CLAUDE" -c '
  RC=0
  printf "outer=%s\n" "$$"
  "$FAKE_VERSIONED" -c '"'"'RC=0; printf "inner=%s\n" "$$"; "$PROBE" harness-pid || RC=$?; exit "$RC"'"'"' || RC=$?
  exit "$RC"
' 2>&1)
outer_pid=$(printf '%s\n' "$out" | sed -n 's/^outer=//p')
inner_pid=$(printf '%s\n' "$out" | sed -n 's/^inner=//p')
resolved=$(printf '%s\n' "$out" | tail -n 1)
[ -n "$outer_pid" ] && [ -n "$inner_pid" ] || fail "version-named fixture did not report both pids:"$'\n'"$out"
[ "$outer_pid" != "$inner_pid" ] || fail "version-named fixture collapsed onto one pid ($outer_pid): the inner session must be a separate process for this assertion to mean anything"
[ "$resolved" = "$inner_pid" ] || fail "harness identity resolved to '$resolved'; the version-named session $inner_pid must win over the outer harness $outer_pid"
pass "version-named harness binary resolves to its own session process"
