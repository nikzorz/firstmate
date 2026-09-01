#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# pane busy-signature) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + busy pane                                        -> pane
#   (g) no run + idle pane falls to the status-log verb           -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
#   (l) claude usage-limit prompt: its own state, ahead of an active run-step,
#       with the quota window reported reset/exhausted/unknown - plus the
#       safety direction, that ordinary worker output discussing limits (and the
#       prompt's own text quoted in tool output) never triggers it. The
#       regression pair for the 2026-07-29 incident.
#   (m) gate ownership and park episode on a parked run: which run shapes publish
#       the two tokens the watcher's `deciding` absorb reads, plus that absorb
#       decided over the REAL helper for the majority `fix_review` park - both
#       the crew that announced the park it sits at and the one that did not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# Set <file>'s mtime <seconds> into the past. Both touch dialects accept the
# -t CCYYMMDDhhmm form, so only the epoch-rendering date flag differs; GNU date
# is probed first because BSD's -r would read that argument as a file name on a
# system where -d works.
age_file() {  # <file> <seconds-ago>
  local when stamp
  when=$(( $(date +%s) - $2 ))
  stamp=$(date -d "@$when" +%Y%m%d%H%M 2>/dev/null) || stamp=$(date -r "$when" +%Y%m%d%H%M)
  touch -t "$stamp" "$1"
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_NM_CALLS:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_NM_CALLS"
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    # FM_FAKE_PANE_FILE serves arbitrary pane text verbatim, for cases that need
    # a realistic multi-line capture rather than the busy/idle two-liners.
    if [ -n "${FM_FAKE_PANE_FILE:-}" ] && [ -f "${FM_FAKE_PANE_FILE:-}" ]; then cat "$FM_FAKE_PANE_FILE"
    elif [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  # quota-axi is firstmate's quota authority; the claude usage-limit path reads
  # it. Serving FM_FAKE_QUOTA_JSON verbatim keeps these cases hermetic and off
  # the real account.
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_QUOTA_FAILS:-0}" = 1 ] && exit 1
printf '%s\n' "${FM_FAKE_QUOTA_JSON:-}"
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  # The forge probe's only outward call. It is created for EVERY case, not only
  # the probe's own, so a fixture carrying a pull-request url can never reach
  # the real github.com from a test; serving nothing is the "forge had no
  # answer" shape, which must leave every other verdict exactly as it was.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_GH_CALLS:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_GH_CALLS"
[ "${FM_FAKE_GH_FAILS:-0}" = 1 ] && exit 1
printf '%s\n' "${FM_FAKE_GH_OUT:-}"
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/quota-axi" "$fb/gh"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_PANE_FILE=""
  FM_FAKE_QUOTA_JSON=""
  FM_FAKE_QUOTA_FAILS=0
  FM_FAKE_GH_OUT=""
  FM_FAKE_GH_FAILS=0
  FM_FAKE_GH_CALLS=""
  FM_FAKE_NM_CALLS=""
  FM_CREW_STATE_FORGE_PROBE=1
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_PANE_FILE FM_FAKE_QUOTA_JSON FM_FAKE_QUOTA_FAILS
  export FM_FAKE_GH_OUT FM_FAKE_GH_FAILS FM_FAKE_GH_CALLS FM_FAKE_NM_CALLS FM_CREW_STATE_FORGE_PROBE
}

# --- claude usage-limit fixtures --------------------------------------------

# The prompt exactly as Claude Code drew it in the 2026-07-29 incident, under a
# few lines of ordinary turn output, with nothing below it (the prompt replaces
# the composer).
write_limit_prompt_pane() {  # <file>
  cat > "$1" <<'EOF'
● Pushed the branch and opened the pull request.

Claude usage limit reached. Your limit will reset at 6:40pm.

   What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Upgrade your plan

   Enter to confirm · Esc to cancel
EOF
}

# Realistic ORDINARY worker output that talks about limits in prose - including
# the words "limit", "wait for limit to reset", and even the prompt's own
# question - inside a healthy pane whose composer box is still drawn below it.
write_limit_prose_pane() {  # <file>
  cat > "$1" <<'EOF'
● Bash(git commit -m "fix(api): back off when the provider rate limit is hit")
  ⎿  [fm/api-retry 1a2b3c4] fix(api): back off when the provider rate limit is hit

● The commit note says we now wait for limit to reset rather than hammering the
  endpoint, and records that the limit resets on a five-hour window.
  What do you want to do?

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# The prompt's own text QUOTED inside tool output on a working pane - a crewmate
# reading this repo's own fixtures. Every text anchor is present and in order;
# only the composer box still drawn underneath separates it from the real thing.
write_limit_quoted_pane() {  # <file>
  cat > "$1" <<'EOF'
● Read(tests/fm-crew-state.test.sh)
  ⎿     What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Upgrade your plan
        Enter to confirm · Esc to cancel

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

quota_json() {  # <percent-remaining>
  cat <<EOF
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "plan": "max",
      "state": { "status": "fresh", "stale": false },
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "effectivePercentRemaining": $1 }
        ]
      }
    }
  ]
}
EOF
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

# A run object carrying the `active_steps` table `axi status` publishes for a
# running or fixing run. Captured verbatim from no-mistakes v1.45.4 against a
# real run record, including the quoted last_activity, the `quiet ` prefix the
# CLI adds past its own step_quiet_warning, and the bare `unknown` it emits when
# no activity has been recorded at all.
run_with_active_step() {  # <branch> <step> <last_activity-cell> [<status>]
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ${4-running}
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    $2,${4-running},0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    $2,${4-running},7h7m,$3,"424242",round 3
EOF
}

# The branch_sync block no-mistakes appends to `axi status` when the checked-out
# branch is bound to the reported run. Its local.head is read from the crew's
# own worktree, so it binds a run whose head is a commit only no-mistakes' own
# repo holds. submitted_head defaults to that same local head, which is where a
# healthy run's worktree sits; pass it explicitly to model a worktree that has
# moved on since the run was submitted.
branch_sync_block() {  # <branch> <local-head> [<run-id>] [<submitted-head>]
  cat <<EOF
branch_sync:
  state: behind
  changed: false
  local:
    branch: $1
    head: $2
    clean: true
  pipeline:
    run: "${3-01RUN}"
    status: running
    phase: ""
    submitted_head: ${4-$2}
    current_head: ${FM_FAKE_RUN_HEAD:-abc1234}
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

# A fix-review gate carrying an ask-user finding, the shape most real escalation
# parks take, together with the park clock no-mistakes publishes for the episode
# the run is currently sitting in.
run_parked_fix_review() {  # <branch> [<parked-duration>]
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked ${2:-2m10s}
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

# An approval gate whose findings header omits the `line` column, so the `action`
# column sits at a different index than every other fixture here.
run_parked_action_column_shifted() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,action,description}:
    r1,error,b.go,ask-user,changes product behavior
gate: review
EOF
}

# An approval gate whose only mention of the token is inside a description, plus
# the same token in unrelated prose outside the findings table.
run_parked_ask_user_only_in_prose() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  note: "reviewer left an ask-user comment on an earlier run"
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,auto-fix,rename this before anyone files it as ask-user
gate: review
EOF
}

# An approval gate whose status word is resolvable only from the steps table,
# the second of nm_gate_status's two probes.
run_parked_steps_row_approval() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,awaiting_approval,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

# The same ci-monitor run, plus the active_steps row that says how long the ci
# step has been quiet. An overnight wait on the captain reaches this shape.
run_ci_monitoring_quiet() {  # <branch> <last_activity-cell>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,20h53m,$2,"",round 1
EOF
}

# The 2026-08-29 shape: the ci step is monitoring, its activity is SECONDS old,
# and it is repeating one line because what it waits for cannot arrive. Every
# figure the inactivity budget reads calls this healthy.
run_ci_spinning() {  # <branch> <last_activity-cell>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/368"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,45m0s,$2,"",round 1
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (l) claude usage-limit prompt. The 2026-07-29 regression pair: the prompt is
# its own state and OUTRANKS an active run, and ordinary worker output that
# merely discusses limits never reaches it.
# --- arm B: a run that has stopped advancing is not a healthy run -----------
#
# Before this, no script in bin/ read `last_activity` at all, so a run that
# logged four seconds ago and one parked for 20h52m produced a byte-identical
# `working / run-step` verdict.

test_advancing_agent_step_stays_working() {
  reset_fakes
  local d; d=$(new_case advancing)
  make_repo_on_branch "$d/wt" fm/feat-adv
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-adv review '"5s ago: log: I will review the branch changes now."')"
  local out; out=$(run_crew_state "$d" adv)
  assert_contains "$out" "state: working" "an advancing review step is working"
  pass "an advancing agent step stays working"
}

test_hung_agent_step_reports_stalled() {
  reset_fakes
  local d; d=$(new_case hung-agent)
  make_repo_on_branch "$d/wt" fm/feat-hung
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/hung.meta" "window=fm:fm-hung" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-hung review '"quiet 20h52m ago: log: I will review the branch changes now."')"
  local out; out=$(run_crew_state "$d" hung)
  assert_contains "$out" "state: stalled" "a review step quiet for 20h52m is not working"
  assert_contains "$out" "review step quiet" "the stalled detail names the step"
  pass "a hung agent step reports stalled"
}

# A zero-padded duration component is an invalid octal constant in bash
# arithmetic, and that is a fatal expansion error rather than a bad term, so an
# unguarded parse would kill the elapsed read and drop the step from the budget
# with no verdict change to show for it. The installed formatter does not pad, so
# this pins the guard rather than a rendering anyone has seen.
test_zero_padded_duration_still_reaches_the_budget() {
  reset_fakes
  local d; d=$(new_case padded-duration)
  make_repo_on_branch "$d/wt" fm/feat-pad
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pad.meta" "window=fm:fm-pad" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-pad review '"quiet 3d09h ago: log: reviewing"')"
  local out err
  err="$d/pad.err"
  out=$(run_crew_state "$d" pad 2>"$err")
  assert_contains "$out" "state: stalled" "a padded 3d09h must still be measured against the budget"
  [ ! -s "$err" ] || fail "the padded duration left an arithmetic error on stderr: $(cat "$err")"

  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-pad review '"quiet 0h08m ago: log: reviewing"')"
  out=$(run_crew_state "$d" pad 2>"$err")
  assert_contains "$out" "state: working" "a padded 0h08m is inside the agent budget, not a parse failure"
  [ ! -s "$err" ] || fail "the padded minute component left an arithmetic error on stderr: $(cat "$err")"
  pass "a zero-padded duration component still reaches the inactivity budget"
}

# The same 45m silence is a breach on an agent-driven step and inside budget on
# a remote-check one, which is the whole reason the two budgets are separate.
test_quiet_remote_check_step_keeps_the_looser_budget() {
  reset_fakes
  local d; d=$(new_case quiet-ci)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/qci.meta" "window=fm:fm-qci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-ci ci '"quiet 45m0s ago: log: all CI checks passed"')"
  FM_FAKE_CI_LOGS="no CI checks reported yet, waiting for checks to register..."
  local out; out=$(run_crew_state "$d" qci)
  assert_contains "$out" "state: working" "45m of remote-check quiet is inside its budget"

  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-ci review '"quiet 45m0s ago: log: reviewing"')"
  out=$(run_crew_state "$d" qci)
  assert_contains "$out" "state: stalled" "45m of agent-step quiet is past its budget"
  pass "the remote-check step keeps its own looser budget"
}

test_hung_remote_check_step_reports_stalled() {
  reset_fakes
  local d; d=$(new_case hung-ci)
  make_repo_on_branch "$d/wt" fm/feat-hci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/hci.meta" "window=fm:fm-hci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-hci ci '"quiet 20h52m ago: log: all CI checks passed"')"
  FM_FAKE_CI_LOGS="no CI checks reported yet, waiting for checks to register..."
  local out; out=$(run_crew_state "$d" hci)
  assert_contains "$out" "state: stalled" "a ci step quiet for 20h52m is past even the looser budget"
  pass "a hung remote-check step reports stalled"
}

# The budget must not eat the one wait it was never about. A crew that appended
# `done: PR <url> checks green` and stopped is quiet BECAUSE it finished, and the
# captain owns how long the merge takes; the ci step goes quiet with it, easily
# past the remote budget overnight. The hard part is the ci log tail: when the
# bounded `axi logs` call times out or its tail carries no recognized marker
# there is no checks-green evidence from the run at all, and only the crew's own
# report says the PR is ready. That report must still win, or the exact wake the
# landing absorb exists to silence comes back on every new pane hash.
test_quiet_ci_monitor_with_checks_green_report_stays_done() {
  reset_fakes
  local d; d=$(new_case quiet-ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-cirq
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cirq.meta" "window=fm:fm-cirq" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/cirq.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring_quiet fm/feat-cirq '"quiet 20h52m ago: log: waiting"')"
  FM_FAKE_CI_LOGS=""
  local out; out=$(run_crew_state "$d" cirq)
  assert_contains "$out" "state: done" "an unreadable ci log tail must not turn the merge wait into a stall"
  assert_contains "$out" "source: status-log" "the crew's own checks-green report stays the source"
  assert_contains "$out" "run still monitoring PR" "the detail still names the monitoring run"
  assert_not_contains "$out" "state: stalled" "a crew waiting out the captain is never stalled"
  pass "a quiet ci monitor with a checks-green report stays done"
}

# The other direction, so the placement above cannot be mistaken for exempting
# the ci step from the budget: with the ci log tail reporting checks NOT green,
# the stale checks-green report no longer explains the silence and the same run
# is stalled.
test_quiet_ci_monitor_without_green_checks_still_stalls() {
  reset_fakes
  local d; d=$(new_case quiet-ci-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cirl
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cirl.meta" "window=fm:fm-cirl" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/cirl.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring_quiet fm/feat-cirl '"quiet 20h52m ago: log: waiting"')"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" cirl)
  assert_contains "$out" "state: stalled" "a stale checks-green report must not exempt a hung ci step"
  assert_contains "$out" "ci step quiet" "the stalled detail names the ci step"
  pass "a quiet ci monitor without green checks still stalls"
}

# An absent table and an `unknown` cell both carry no elapsed figure. Neither may
# invent a breach; this is the stated limit of the budget.
test_missing_activity_figure_leaves_the_verdict_alone() {
  reset_fakes
  local d; d=$(new_case no-activity)
  make_repo_on_branch "$d/wt" fm/feat-na
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/na.meta" "window=fm:fm-na" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-na review unknown)"
  local out; out=$(run_crew_state "$d" na)
  assert_contains "$out" "state: working" "an unknown last_activity does not manufacture a stall"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-na)"
  out=$(run_crew_state "$d" na)
  assert_contains "$out" "state: working" "a run with no active_steps table stays working"
  pass "a missing activity figure leaves the verdict alone"
}

# The same active_steps table under an arbitrary column layout, so the header is
# proved to be what locates the fields. A reader that counted positions instead
# would read the wrong cell - or none - the first time no-mistakes reorders the
# table or adds a column of its own, and would then report a hung run healthy
# again with nothing to show for it.
run_with_active_step_layout() {  # <branch> <header-columns> <row>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
  active_steps[1]{$2}:
    $3
EOF
}

test_active_step_columns_are_located_by_name() {
  reset_fakes
  local d; d=$(new_case column-layout)
  make_repo_on_branch "$d/wt" fm/feat-cols
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cols.meta" "window=fm:fm-cols" "worktree=$d/wt" "kind=ship"
  local quiet='"quiet 20h52m ago: log: I will review the branch changes now."' out

  FM_FAKE_AXI_STATUS="$(run_with_active_step_layout fm/feat-cols \
    'step,status,active_for,last_activity,agent_pid,round' \
    "review,running,20h53m,$quiet,\"424242\",round 1")"
  out=$(run_crew_state "$d" cols)
  assert_contains "$out" "review step quiet 20h52m" "the layout published today must reach the budget"

  FM_FAKE_AXI_STATUS="$(run_with_active_step_layout fm/feat-cols \
    'last_activity,status,active_for,agent_pid,round,step' \
    "$quiet,running,20h53m,\"424242\",round 1,review")"
  out=$(run_crew_state "$d" cols)
  assert_contains "$out" "review step quiet 20h52m" "a reordered table must still be read by column name"

  FM_FAKE_AXI_STATUS="$(run_with_active_step_layout fm/feat-cols \
    'worker,step,status,active_for,last_activity,agent_pid,round' \
    "worker-9,review,running,20h53m,$quiet,\"424242\",round 1")"
  out=$(run_crew_state "$d" cols)
  assert_contains "$out" "review step quiet 20h52m" "a new leading column must not shift the read"
  pass "active_steps columns are located by name, not by position"
}

# --- arm C: a step that keeps logging while nothing progresses -------------
#
# Observed 2026-08-29: the ci step appended one identical line every ten seconds
# for forty minutes while the pull request sat unmergeable behind two sibling
# branches that had landed, so the forge produced no checks for its head and the
# re-run the step asked for could never arrive. last_activity stayed seconds old
# the whole time, so both budgets above call this run healthy - it is not
# silence, it is repetition, and the discriminator is outside the run's own
# figures.

# What the ci step logged during that spin, newest last.
CI_LOG_AWAITING_RERUN='base branch advanced (680a001d..f5979b18), re-arming CI monitor timeout
fix already attempted for these issues, waiting for CI re-run...
fix already attempted for these issues, waiting for CI re-run...'

# The same conflict one round earlier, while no-mistakes is still fixing it
# itself and has not yet asked for a re-run of anything.
CI_LOG_CONFLICT_AUTOFIXING='base branch advanced (680a001d..f5979b18), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 1/3)...'

test_spinning_ci_step_on_a_conflicting_pr_reports_stalled() {
  reset_fakes
  local d; d=$(new_case spin-conflict)
  make_repo_on_branch "$d/wt" fm/feat-spin
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/spin.meta" "window=fm:fm-spin" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-spin '"5s ago: log: fix already attempted for these issues, waiting for CI re-run..."')"
  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"

  FM_FAKE_GH_OUT=$'MERGEABLE\t7'
  local out; out=$(run_crew_state "$d" spin)
  assert_contains "$out" "state: working" "a mergeable pull request with checks is still a working run"

  FM_FAKE_GH_OUT=$'CONFLICTING\t0'
  out=$(run_crew_state "$d" spin)
  assert_contains "$out" "state: stalled" "a run waiting on checks a conflicting pull request cannot get is not working"
  assert_contains "$out" "merge conflicts" "the detail names why the wait cannot end"
  pass "a spinning ci step on a conflicting pull request reports stalled"
}

# The conflict half of the probe is gated on the same re-run wait the empty-list
# half is. no-mistakes resolves its own merge conflicts, so a conflicting pull
# request it has not finished with is a non-event, and waking the captain on one
# spends an interruption on work already in hand.
test_a_conflict_the_pipeline_is_still_fixing_is_not_a_stall() {
  reset_fakes
  local d; d=$(new_case spin-autofix)
  make_repo_on_branch "$d/wt" fm/feat-afx
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/afx.meta" "window=fm:fm-afx" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-afx '"5s ago: log: issues detected: merge conflict - auto-fixing (attempt 1/3)..."')"
  FM_FAKE_GH_OUT=$'CONFLICTING\t0'
  FM_FAKE_GH_CALLS="$d/gh.calls"

  FM_FAKE_CI_LOGS="$CI_LOG_CONFLICT_AUTOFIXING"
  local out; out=$(run_crew_state "$d" afx)
  assert_contains "$out" "state: working" "a conflict no-mistakes is still auto-fixing is not a run that stopped advancing"
  [ ! -s "$FM_FAKE_GH_CALLS" ] || fail "the forge was asked about a conflict the pipeline had not finished with"

  # One round later the step has spent its fix attempts and is asking for a
  # re-run it can never get, and the same conflict now does escalate.
  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"
  out=$(run_crew_state "$d" afx)
  assert_contains "$out" "state: stalled" "the same conflict escalates once the step is waiting on a re-run"
  assert_contains "$out" "merge conflicts" "the detail names why the wait cannot end"
  pass "a conflict the pipeline is still fixing is not a stall"
}

# Three readers ask about the ci log tail and fetching it is a bounded
# subprocess call on the watcher's hot path, so one invocation may buy it once.
test_the_ci_log_tail_is_bought_once_per_invocation() {
  reset_fakes
  local d; d=$(new_case spin-onefetch)
  make_repo_on_branch "$d/wt" fm/feat-ofx
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/ofx.meta" "window=fm:fm-ofx" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-ofx '"5s ago: log: fix already attempted for these issues, waiting for CI re-run..."')"
  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"
  FM_FAKE_GH_OUT=$'MERGEABLE\t7'
  FM_FAKE_NM_CALLS="$d/nm.calls"

  local out; out=$(run_crew_state "$d" ofx)
  assert_contains "$out" "state: working" "the checks-green override and the forge probe both ran on this fixture"
  local fetches; fetches=$(grep -c 'axi logs' "$FM_FAKE_NM_CALLS" || true)
  [ "$fetches" = 1 ] || fail "the ci log tail was fetched $fetches time(s), expected exactly 1"
  pass "the ci log tail is bought once per invocation"
}

test_empty_check_list_only_counts_while_a_rerun_is_awaited() {
  reset_fakes
  local d; d=$(new_case spin-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-nck
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nck.meta" "window=fm:fm-nck" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-nck '"5s ago: log: fix already attempted for these issues, waiting for CI re-run..."')"
  FM_FAKE_GH_OUT=$'MERGEABLE\t0'

  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"
  local out; out=$(run_crew_state "$d" nck)
  assert_contains "$out" "state: stalled" "checks the step has already seen once cannot come back from an empty list"
  assert_contains "$out" "no checks for the pull request head" "the detail names the missing checks"

  # The same empty list on a repository whose checks have simply not registered
  # yet is not evidence of anything, and no-mistakes says so in its own words.
  FM_FAKE_CI_LOGS="no CI checks reported yet, waiting for checks to register..."
  out=$(run_crew_state "$d" nck)
  assert_contains "$out" "state: working" "an empty check list before any re-run was asked for is not a stall"
  pass "an empty check list only counts while a re-run is awaited"
}

# Every way the forge can fail to answer must leave the verdict exactly where it
# was. GitHub reports UNKNOWN mergeability while it is still computing one, so
# treating that as a conflict would wake the captain on ordinary latency.
test_an_absent_forge_answer_never_manufactures_a_stall() {
  reset_fakes
  local d; d=$(new_case spin-noanswer)
  make_repo_on_branch "$d/wt" fm/feat-na2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/na2.meta" "window=fm:fm-na2" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-na2 '"5s ago: log: fix already attempted for these issues, waiting for CI re-run..."')"
  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"
  local out

  FM_FAKE_GH_OUT=$'UNKNOWN\t7'
  out=$(run_crew_state "$d" na2)
  assert_contains "$out" "state: working" "an uncomputed mergeability is not a conflict"

  FM_FAKE_GH_OUT=$'CONFLICTING\t0'
  FM_FAKE_GH_FAILS=1
  out=$(run_crew_state "$d" na2)
  assert_contains "$out" "state: working" "a forge query that fails leaves the verdict alone"

  FM_FAKE_GH_FAILS=0
  FM_FAKE_GH_OUT=""
  out=$(run_crew_state "$d" na2)
  assert_contains "$out" "state: working" "an empty forge answer leaves the verdict alone"
  pass "an absent forge answer never manufactures a stall"
}

# The probe is the only outward call this reader makes, so it must be possible
# to switch off, and it must not be reached at all once a cheaper source has
# already settled the verdict.
test_the_forge_is_asked_nothing_it_need_not_answer() {
  reset_fakes
  local d; d=$(new_case spin-noask)
  make_repo_on_branch "$d/wt" fm/feat-nask
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nask.meta" "window=fm:fm-nask" "worktree=$d/wt" "kind=ship"
  FM_FAKE_GH_OUT=$'CONFLICTING\t0'
  FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_RERUN"
  FM_FAKE_GH_CALLS="$d/gh.calls"
  local out

  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-nask '"5s ago: log: fix already attempted for these issues, waiting for CI re-run..."')"
  FM_CREW_STATE_FORGE_PROBE=0
  out=$(run_crew_state "$d" nask)
  assert_contains "$out" "state: working" "the switched-off probe behaves as if it did not exist"
  [ ! -s "$FM_FAKE_GH_CALLS" ] || fail "the switched-off probe still called the forge"
  FM_CREW_STATE_FORGE_PROBE=1

  # A step already past its own inactivity budget keeps the direct detail and
  # buys no query with it.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring_quiet fm/feat-nask '"quiet 20h52m ago: log: waiting"')"
  out=$(run_crew_state "$d" nask)
  assert_contains "$out" "state: stalled" "the budget still settles a step that went quiet"
  assert_contains "$out" "ci step quiet" "the budget breach keeps its own detail"
  [ ! -s "$FM_FAKE_GH_CALLS" ] || fail "a run already stalled on its own figures still called the forge"

  # And a crew that reported checks green is waiting out the captain on a merge,
  # not stalled, however the forge feels about the branch by now.
  printf 'done: PR https://github.com/o/r/pull/368 checks green\n' > "$d/state/nask.status"
  FM_FAKE_AXI_STATUS="$(run_ci_spinning fm/feat-nask '"5s ago: log: still monitoring"')"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  out=$(run_crew_state "$d" nask)
  assert_contains "$out" "state: done" "a finished crew waiting on a merge is not stalled"
  [ ! -s "$FM_FAKE_GH_CALLS" ] || fail "a crew waiting out the captain on a merge was probed anyway"
  pass "the forge is asked nothing it need not answer"
}

# The budgets are tuning constants, changeable without editing logic.
test_inactivity_budgets_are_configurable() {
  reset_fakes
  local d; d=$(new_case budget-knob)
  make_repo_on_branch "$d/wt" fm/feat-knob
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/knob.meta" "window=fm:fm-knob" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-knob review '"quiet 40m0s ago: log: reviewing"')"
  local out
  out=$(FM_CREW_STATE_AGENT_QUIET_SECS=7200 run_crew_state "$d" knob)
  assert_contains "$out" "state: working" "a raised budget absorbs the same silence"
  out=$(FM_CREW_STATE_AGENT_QUIET_SECS=60 run_crew_state "$d" knob)
  assert_contains "$out" "state: stalled" "a lowered budget escalates the same silence"
  pass "the inactivity budgets are configurable without editing logic"
}

# --- arm B: an unknown run status is not a healthy run ----------------------

test_unrecognized_run_status_is_not_working() {
  reset_fakes
  local d; d=$(new_case weird-status)
  make_repo_on_branch "$d/wt" fm/feat-weird
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/weird.meta" "window=fm:fm-weird" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-weird review '"5s ago: log: x"' weirdstate)"
  local out; out=$(run_crew_state "$d" weird)
  assert_contains "$out" "state: unknown" "a future status word is not read as a healthy run"
  assert_contains "$out" "unrecognized run status: weirdstate" "the unknown word is named"
  pass "an unrecognized run status is not working"
}

test_empty_run_status_is_not_working() {
  reset_fakes
  local d; d=$(new_case empty-status)
  make_repo_on_branch "$d/wt" fm/feat-empty
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/empty.meta" "window=fm:fm-empty" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="run:
  id: \"01RUN\"
  branch: fm/feat-empty
  head: \"${FM_FAKE_RUN_HEAD:-abc1234}\"
  pr: \"\"
  findings: none"
  local out; out=$(run_crew_state "$d" empty)
  assert_contains "$out" "state: unknown" "an empty run status is not read as a healthy run"
  assert_contains "$out" "run reported no status" "the empty status is named"
  pass "an empty run status is not working"
}

# The absorb classifier must not treat either as positive evidence of health.
test_stalled_and_unknown_are_not_provably_working() {
  reset_fakes
  local d; d=$(new_case stalled-absorb)
  make_repo_on_branch "$d/wt" fm/feat-sa
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/sa.meta" "window=fm:fm-sa" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-sa review '"quiet 20h52m ago: log: reviewing"')"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_BIN="$CREW_STATE" \
    crew_is_provably_working sa \
    && fail "a stalled run was treated as provably working"
  FM_FAKE_AXI_STATUS="$(run_with_active_step fm/feat-sa review '"5s ago: log: reviewing"')"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_BIN="$CREW_STATE" \
    crew_is_provably_working sa \
    || fail "an advancing run was not treated as provably working"
  pass "a stalled run is not provably working, an advancing one still is"
}

test_usage_limit_prompt_outranks_active_run() {
  reset_fakes
  local d; d=$(new_case usage-limit-active-run)
  make_repo_on_branch "$d/wt" fm/feat-limit
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-limit.meta" \
    "window=fm:fm-feat-limit" "worktree=$d/wt" "kind=ship" "harness=claude"
  write_limit_prompt_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  # The exact false-healthy shape from the incident: the pipeline run is still
  # `running`, so without the pane check this reported plain `working`.
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-limit)"
  local out; out=$(run_crew_state "$d" feat-limit)
  assert_contains "$out" "state: usage-limited" "usage-limit prompt did not report its own state"
  assert_contains "$out" "source: pane" "usage-limit prompt did not report a pane source"
  assert_contains "$out" "limit-window: reset" "a reset account window was not reported"
  assert_not_contains "$out" "state: working" "an active run masked the usage-limit prompt"
  pass "a crew on the claude usage-limit prompt outranks its own active run"
}

test_usage_limit_prompt_exhausted_window() {
  reset_fakes
  local d; d=$(new_case usage-limit-exhausted)
  make_repo_on_branch "$d/wt" fm/feat-exh
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-exh.meta" \
    "window=fm:fm-feat-exh" "worktree=$d/wt" "kind=ship" "harness=claude"
  write_limit_prompt_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_QUOTA_JSON="$(quota_json 0)"
  local out; out=$(run_crew_state "$d" feat-exh)
  assert_contains "$out" "state: usage-limited" "exhausted window lost the usage-limited state"
  assert_contains "$out" "limit-window: exhausted" "an exhausted account window was not reported"
  pass "a still-exhausted account window is reported as such, not as reset"
}

test_usage_limit_unreadable_quota_is_unknown() {
  reset_fakes
  local d; d=$(new_case usage-limit-unknown-quota)
  make_repo_on_branch "$d/wt" fm/feat-uq
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-uq.meta" \
    "window=fm:fm-feat-uq" "worktree=$d/wt" "kind=ship" "harness=claude"
  write_limit_prompt_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_QUOTA_FAILS=1
  local out; out=$(run_crew_state "$d" feat-uq)
  assert_contains "$out" "state: usage-limited" "an unreadable quota lost the usage-limited state"
  assert_contains "$out" "limit-window: unknown" "an unreadable quota window was not reported unknown"
  assert_not_contains "$out" "limit-window: reset" "an unreadable quota window was guessed as reset"
  pass "an unreadable quota window reports unknown rather than guessing a reset"
}

# The safety property: detection must not fire on ordinary worker output.
test_usage_limit_ignores_ordinary_limit_prose() {
  reset_fakes
  local d; d=$(new_case usage-limit-prose)
  make_repo_on_branch "$d/wt" fm/feat-prose
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-prose.meta" \
    "window=fm:fm-feat-prose" "worktree=$d/wt" "kind=ship" "harness=claude"
  write_limit_prose_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-prose)"
  local out; out=$(run_crew_state "$d" feat-prose)
  assert_not_contains "$out" "usage-limited" "prose about rate limits triggered usage-limit detection"
  assert_contains "$out" "state: working" "a working crew discussing limits lost its run-step state"

  # Same pane, but with the prompt's own text quoted verbatim in tool output.
  write_limit_quoted_pane "$d/pane.txt"
  out=$(run_crew_state "$d" feat-prose)
  assert_not_contains "$out" "usage-limited" "quoted prompt text in tool output triggered detection"
  assert_contains "$out" "state: working" "a working crew displaying the prompt text lost its run-step state"
  pass "usage-limit detection ignores ordinary worker output, quoted prompt text included"
}

# Scope discipline: the signature is claude-specific and is never applied to a
# harness where the shape has not been observed.
test_usage_limit_only_for_recorded_claude() {
  reset_fakes
  local d; d=$(new_case usage-limit-other-harness)
  make_repo_on_branch "$d/wt" fm/feat-other
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-other.meta" \
    "window=fm:fm-feat-other" "worktree=$d/wt" "kind=ship" "harness=codex"
  write_limit_prompt_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  printf 'working: implementing\n' > "$d/state/feat-other.status"
  local out; out=$(run_crew_state "$d" feat-other)
  assert_not_contains "$out" "usage-limited" "a non-claude harness was classified by the claude signature"
  pass "the claude usage-limit signature is never applied to another harness"
}

# An unreadable pane must fall through unchanged, never be guessed either way.
test_usage_limit_unreadable_pane_falls_through() {
  reset_fakes
  local d; d=$(new_case usage-limit-unreadable-pane)
  make_repo_on_branch "$d/wt" fm/feat-blind
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-blind.meta" \
    "window=fm:fm-feat-blind" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-blind)"
  local out; out=$(run_crew_state "$d" feat-blind)
  assert_not_contains "$out" "usage-limited" "an unreadable pane was classified usage-limited"
  assert_contains "$out" "source: run-step" "an unreadable pane did not fall through to the run-step path"
  pass "an unreadable pane falls through instead of being guessed"
}

# The shared triage reading both supervisors use, over the REAL helper.
test_usage_limit_classifier_over_real_helper() {
  reset_fakes
  local d; d=$(new_case usage-limit-classifier)
  make_repo_on_branch "$d/wt" fm/feat-cls
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cls.meta" \
    "window=fm:fm-feat-cls" "worktree=$d/wt" "kind=ship" "harness=claude"
  write_limit_prompt_pane "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-cls)"

  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  [ "$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_usage_limit_class feat-cls)" = ready ] \
    || fail "a reset window was not classed ready"
  # A stalled crew must never read as provably working, or the watcher absorbs it.
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-cls \
    && fail "a crew on the usage-limit prompt was treated as provably working"

  FM_FAKE_QUOTA_JSON="$(quota_json 0)"
  [ "$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_usage_limit_class feat-cls)" = waiting ] \
    || fail "an exhausted window was not classed waiting"

  FM_FAKE_QUOTA_FAILS=1
  [ "$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_usage_limit_class feat-cls)" = unknown ] \
    || fail "an unreadable quota window was not classed unknown"
  FM_FAKE_QUOTA_FAILS=0

  write_limit_prose_pane "$d/pane.txt"
  FM_FAKE_QUOTA_JSON="$(quota_json 97)"
  [ "$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_usage_limit_class feat-cls)" = none ] \
    || fail "an ordinary working crew was classed as usage-limited"
  pass "crew_usage_limit_class reads ready/waiting/unknown/none from the real current-state line"
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  # The literal, not the bare token: bin/fm-classify-lib.sh owns the spelling and
  # the watcher's `deciding` absorb matches on it, so a producer reword that this
  # suite did not notice would silently turn every such absorb back into a wake.
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" "an approval gate on an ask-user finding publishes the authority-gate marker"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

# --- gate ownership: who the park is actually waiting on ---------------------
#
# The marker means the gate is one the crew may NOT answer itself, which is the
# whole basis of the watcher's `deciding` absorb. These pin the rule as a fact
# about the gate rather than as a search for a token anywhere in the run output,
# which is what it used to be: the token in prose used to publish it.
#
# Ownership turns on the ask-user row and on the status word being READABLE, not
# on which of the two readable words it is. A `fix_review` park carrying an
# ask-user row is waiting on the same answer an `awaiting_approval` one is, and
# it is the shape most real escalation parks take, so an approval-only rule
# published nothing for the majority of them.
test_fix_review_gate_with_an_ask_user_row_publishes_the_authority_marker() {
  reset_fakes
  local d; d=$(new_case gate-owner-fix-review)
  make_repo_on_branch "$d/wt" fm/feat-go1
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go1.meta" "window=fm:fm-feat-go1" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go1.status"
  FM_FAKE_AXI_STATUS="$(run_parked_fix_review fm/feat-go1)"
  local out; out=$(run_crew_state "$d" feat-go1)
  assert_contains "$out" "state: parked" "a fix-review gate still reports parked"
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "a fix-review gate carrying an ask-user row published no authority-gate marker"
  # The crew wrote its decision at this park, so the second token is published
  # too - the pair is what the absorb reads.
  assert_contains "$out" "$FM_CLASSIFY_PARK_CURRENT_STATUS_MARKER" \
    "a crew that wrote its status at this park published no park-current marker"
  assert_not_contains "$out" "[ask-user finding, authority gate unconfirmed]" \
    "a confirmed authority gate also carried the unconfirmed-owner operator note"
  pass "a fix-review gate carrying an ask-user row publishes the authority-gate marker"
}

test_authority_marker_reads_the_action_column_by_name() {
  reset_fakes
  local d; d=$(new_case gate-owner-column)
  make_repo_on_branch "$d/wt" fm/feat-go2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go2.meta" "window=fm:fm-feat-go2" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go2.status"
  FM_FAKE_AXI_STATUS="$(run_parked_action_column_shifted fm/feat-go2)"
  local out; out=$(run_crew_state "$d" feat-go2)
  assert_contains "$out" "state: parked" "a shifted-column approval gate still reports parked"
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "the action column was not located by name in the findings header"
  pass "the authority-gate marker locates the action column by header name"
}

test_steps_row_approval_gate_publishes_the_authority_marker() {
  reset_fakes
  local d; d=$(new_case gate-owner-steps-row)
  make_repo_on_branch "$d/wt" fm/feat-go4
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go4.meta" "window=fm:fm-feat-go4" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go4.status"
  FM_FAKE_AXI_STATUS="$(run_parked_steps_row_approval fm/feat-go4)"
  local out; out=$(run_crew_state "$d" feat-go4)
  assert_contains "$out" "state: parked" "a steps-row approval gate still reports parked"
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "an approval gate resolved from the steps table did not publish the authority-gate marker"
  pass "an approval gate resolved from the steps table publishes the authority-gate marker"
}

# A park whose gate status word neither probe can read. It cannot earn the token,
# because nothing here says a real gate was seen at all, so it keeps surfacing.
# What it does keep is the operator note, which reports what the findings table
# shows and claims no ownership. The two strings must stay disjoint: were the note to
# contain the token, this park would read as authority-owned in the classifier
# and be absorbed - see test_the_operator_note_is_inert_to_the_absorb_classifier
# in tests/fm-watch-triage.test.sh for the other half of that guard.
test_unreadable_gate_status_keeps_the_note_without_the_marker() {
  reset_fakes
  local d; d=$(new_case gate-owner-no-status)
  make_repo_on_branch "$d/wt" fm/feat-go5
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go5.meta" "window=fm:fm-feat-go5" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go5.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-go5)"
  local out; out=$(run_crew_state "$d" feat-go5)
  assert_contains "$out" "state: parked" "an unreadable-status gate still reports parked"
  assert_not_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "a park whose gate status word cannot be read published the authority-gate marker"
  # The finding is still real and still worth reporting to an operator, so the
  # note stays - naming no owner, because this reader established none.
  assert_contains "$out" "[ask-user finding, authority gate unconfirmed]" \
    "an unreadable-status park lost or reworded its operator note"
  case "$out" in
    *"$FM_CLASSIFY_AUTHORITY_GATE_MARKER"*)
      fail "the operator note contains the ownership token, so this park reads as authority-owned" ;;
  esac
  pass "a park with an unreadable gate status keeps the operator note but not the ownership token"
}

test_ask_user_in_prose_does_not_publish_the_authority_marker() {
  reset_fakes
  local d; d=$(new_case gate-owner-prose)
  make_repo_on_branch "$d/wt" fm/feat-go3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go3.meta" "window=fm:fm-feat-go3" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go3.status"
  FM_FAKE_AXI_STATUS="$(run_parked_ask_user_only_in_prose fm/feat-go3)"
  local out; out=$(run_crew_state "$d" feat-go3)
  assert_contains "$out" "state: parked" "an approval gate with no ask-user action still reports parked"
  assert_not_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "a description and a note mentioning ask-user published the authority-gate marker"
  pass "only an ask-user action column publishes the authority-gate marker"
}

# --- which park episode the crew's record belongs to --------------------------
#
# The ownership token says who owns the gate; it cannot say whether the decision
# the status fold still reports open is about THIS park. The shape that makes
# the difference matter: firstmate answers, the worker responds to the gate, the
# pipeline fixes, the run parks again, and the worker wedges before writing
# anything about the new gate. Its old `needs-decision:` line stands over a park
# it never announced, and absorbing that would silence it with no timer and no
# other wake owner left. The park clock restarts with each episode, so a status
# record older than the episode is a record about a previous one.
test_a_park_the_crew_never_wrote_about_publishes_no_park_marker() {
  reset_fakes
  local d; d=$(new_case gate-park-stale-status)
  make_repo_on_branch "$d/wt" fm/feat-go6
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go6.meta" "window=fm:fm-feat-go6" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go6.status"
  touch -t 200001010000 "$d/state/feat-go6.status"
  FM_FAKE_AXI_STATUS="$(run_parked_fix_review fm/feat-go6 5m0s)"
  local out; out=$(run_crew_state "$d" feat-go6)
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "the gate ownership token depends on the crew's status age"
  assert_not_contains "$out" "$FM_CLASSIFY_PARK_CURRENT_STATUS_MARKER" \
    "a decision written long before this park episode published the park-current marker"
  pass "a park the crew never wrote about publishes no park-current marker"
}

# No published clock is no evidence, not a fresh park: the field is omitted
# unless the run is parked for the agent, and a response shape that stopped
# rendering it must move parks into the never-absorbed side rather than the
# absorbed one.
test_a_park_with_no_published_clock_publishes_no_park_marker() {
  reset_fakes
  local d; d=$(new_case gate-park-no-clock)
  make_repo_on_branch "$d/wt" fm/feat-go7
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go7.meta" "window=fm:fm-feat-go7" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go7.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-go7)"
  local out; out=$(run_crew_state "$d" feat-go7)
  assert_contains "$out" "$FM_CLASSIFY_AUTHORITY_GATE_MARKER" \
    "a fix-review gate resolved from a gate block published no authority-gate marker"
  assert_not_contains "$out" "$FM_CLASSIFY_PARK_CURRENT_STATUS_MARKER" \
    "a park publishing no clock at all published the park-current marker"
  pass "a park with no published clock publishes no park-current marker"
}

# A token that does not parse is the same absence, and must not be read as a
# zero-length park - which would make every stale status record look current.
test_an_unparseable_park_clock_publishes_no_park_marker() {
  reset_fakes
  local d; d=$(new_case gate-park-bad-clock)
  make_repo_on_branch "$d/wt" fm/feat-go8
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go8.meta" "window=fm:fm-feat-go8" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go8.status"
  FM_FAKE_AXI_STATUS="$(run_parked_fix_review fm/feat-go8 "a while")"
  local out; out=$(run_crew_state "$d" feat-go8)
  assert_contains "$out" "state: parked" "an unparseable park clock stopped the park read"
  assert_not_contains "$out" "$FM_CLASSIFY_PARK_CURRENT_STATUS_MARKER" \
    "an unparseable park clock published the park-current marker"
  pass "an unparseable park clock publishes no park-current marker"
}

# The published clock is TRUNCATED, and coarsely so once a wait passes a day:
# `parked 3d11h` covers anything up to 3d11h59m59s. The comparison is lenient by
# exactly one rendered unit for that reason, because the overnight waits this
# absorb exists for are the ones the render rounds hardest, and a strict bound
# would refuse the ordinary shape - a crew that wrote its decision moments after
# arriving at the gate.
test_a_coarse_park_clock_does_not_refuse_a_decision_written_at_it() {
  reset_fakes
  local d; d=$(new_case gate-park-coarse-clock)
  make_repo_on_branch "$d/wt" fm/feat-go9
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-go9.meta" "window=fm:fm-feat-go9" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-go9.status"
  # The run has been parked 3d11h30m and the crew wrote its decision at the top
  # of that episode; the render can only say `3d11h`.
  age_file "$d/state/feat-go9.status" $(( 3 * 86400 + 11 * 3600 + 30 * 60 ))
  FM_FAKE_AXI_STATUS="$(run_parked_fix_review fm/feat-go9 3d11h)"
  local out; out=$(run_crew_state "$d" feat-go9)
  assert_contains "$out" "$FM_CLASSIFY_PARK_CURRENT_STATUS_MARKER" \
    "the truncated park clock refused a decision written at the park it names"
  pass "a coarse park clock does not refuse a decision written at that park"
}

# The deciding absorb end to end over the REAL producer, not a canned verdict
# line: the majority park shape - `fix_review`, with an ask-user finding at the
# gate - reaching the classifier and being absorbed, and the same crew surfacing
# once its status record no longer belongs to the park in front of it. This is
# the pair the two-part chain above only implies; tests/fm-watch-triage.test.sh
# owns what the watcher then does with each verdict.
test_deciding_class_over_the_real_helper() {
  reset_fakes
  local d out; d=$(new_case deciding-real-helper)
  make_repo_on_branch "$d/wt" fm/feat-dr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dr.meta" "window=fm:fm-feat-dr" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision [key=review-2]: round 2 raised two ask-user findings\n' \
    > "$d/state/feat-dr.status"
  FM_FAKE_AXI_STATUS="$(run_parked_fix_review fm/feat-dr 41m22s)"

  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_absorb_class feat-dr)
  [ "$out" = deciding ] \
    || fail "a fix-review park on a decision firstmate already knows about was not absorbed: $out"

  # The compensating gate, over the real producer: the same run, the same open
  # decision, the same last line - but written before this park episode began, so
  # the crew never said a word about the gate it is sitting at now.
  touch -t 200001010000 "$d/state/feat-dr.status"
  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_absorb_class feat-dr)
  [ "$out" = none ] \
    || fail "a park the crew never wrote about was absorbed over the real helper: $out"
  pass "crew_absorb_class absorbs a fix-review park the crew announced and surfaces one it did not"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship"
  # No matching run anywhere.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy pane -> working"
  assert_contains "$out" "source: pane" "busy pane -> pane source"
  pass "no run + busy pane reads working from the pane"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" "backend=herdr"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=""
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr busy pane -> working"
  assert_contains "$out" "source: pane" "herdr busy pane -> pane source"
  pass "herdr unknown native state falls back to backend capture busy regex"
}

# Regression: herdr's agent.get reports generation state ("working" only while
# the model is actively streaming a turn - docs/herdr-backend.md "Busy state"),
# not "this crew's tool call is still in progress". A crew blocked on its own
# long-running foreground `no-mistakes axi run` (no --yes; blocks until a gate
# or outcome) is not generating for that whole span, so agent.get can read
# idle while the pane's own rendered text still shows the busy banner
# (BUSY_REGEX) for the entire call. `idle` must be corroborated with that text
# exactly like `unknown` already is, not trusted outright - the bug this
# regression pins: crew_pane_is_busy previously returned "not busy" on a bare
# `idle` verdict without ever looking at the pane.
test_no_run_herdr_idle_agent_status_corroborated_by_busy_pane() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-pane)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" "backend=herdr"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the pane fallback is
  # the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=1
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "herdr idle agent_status with a busy-banner pane -> working"
  assert_contains "$out" "source: pane" "herdr idle agent_status with a busy-banner pane -> pane source"
  pass "herdr idle agent_status is corroborated by the pane text, not trusted outright"
}

# The corroboration must not mask a genuinely idle/human-blocked agent: idle
# agent_status AND an idle-looking pane (no busy banner) still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_pane_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-pane skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-pane)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" "backend=herdr"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "herdr idle agent_status with an idle pane must not read as busy from the pane"
  assert_contains "$out" "source: status-log" "herdr idle agent_status with an idle pane falls to the status log"
  pass "herdr idle agent_status with a genuinely idle pane stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship"
  FM_FAKE_BUSY=1
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads pane busy-signature"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

# Head-binding: the production shape the local-fixture case above cannot reach.
# A pipeline auto-fix commit lives only in no-mistakes' own repo, so the run head
# never resolves in the crew's worktree and the ancestry rule cannot bind it;
# branch_sync binds it instead.
test_pipeline_fix_head_in_foreign_repo_binds_via_branch_sync() {
  reset_fakes
  local d base_head foreign_head out
  d=$(new_case pipeline-foreign-head)
  make_repo_on_branch "$d/wt" fm/feat-foreign
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  # The pipeline's fix commit, made where no-mistakes actually makes it.
  mkdir -p "$d/pipeline"
  git -C "$d/pipeline" init -q
  git -C "$d/pipeline" commit -q --allow-empty -m 'pipeline fix commit'
  foreign_head=$(git -C "$d/pipeline" rev-parse HEAD)
  ! git -C "$d/wt" rev-parse --verify --quiet "${foreign_head}^{commit}" >/dev/null \
    || fail "fixture invalid: pipeline fix commit resolves in the crew worktree"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/foreign.meta" "window=fm:fm-foreign" "worktree=$d/wt" "kind=ship"
  printf 'working: implementation handed to the pipeline\n' > "$d/state/foreign.status"
  FM_FAKE_RUN_HEAD="$foreign_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-foreign; branch_sync_block fm/feat-foreign "$base_head")"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" foreign)
  assert_contains "$out" "source: run-step" "branch_sync binds a run whose head is not local"
  assert_contains "$out" "state: working" "bound fixing run reports working"
  pass "unresolvable pipeline fix head still binds via branch_sync"
}

# branch_sync must never widen attribution: a block naming another branch, or
# carrying no run id, is not a binding for this crew.
test_branch_sync_for_other_branch_does_not_attribute() {
  reset_fakes
  local d base_head out
  d=$(new_case branch-sync-other-branch)
  make_repo_on_branch "$d/wt" fm/feat-mine
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt" "kind=ship"
  printf 'working: current stage still in progress\n' > "$d/state/other.status"
  FM_FAKE_RUN_HEAD=0000000000000000000000000000000000000000
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-theirs; branch_sync_block fm/feat-theirs "$base_head")"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "source: run-step" "another branch's binding must not attribute"
  assert_contains "$out" "source: status-log" "falls back when branch_sync names another branch"
  pass "branch_sync naming another branch does not attribute"
}

test_branch_sync_for_a_different_run_does_not_attribute() {
  reset_fakes
  local d base_head out
  d=$(new_case branch-sync-other-run)
  make_repo_on_branch "$d/wt" fm/feat-otherrun
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/otherrun.meta" "window=fm:fm-otherrun" "worktree=$d/wt" "kind=ship"
  printf 'working: current stage still in progress\n' > "$d/state/otherrun.status"
  FM_FAKE_RUN_HEAD=0000000000000000000000000000000000000000
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-otherrun; branch_sync_block fm/feat-otherrun "$base_head" 01OTHER)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" otherrun)
  assert_not_contains "$out" "source: run-step" "a binding for another run must not attribute this one"
  assert_contains "$out" "source: status-log" "falls back when the reported run is not the bound run"
  pass "branch_sync binding another run does not attribute the reported run"
}

test_branch_sync_without_run_id_does_not_attribute() {
  reset_fakes
  local d base_head out
  d=$(new_case branch-sync-no-run)
  make_repo_on_branch "$d/wt" fm/feat-norun
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/norun.meta" "window=fm:fm-norun" "worktree=$d/wt" "kind=ship"
  printf 'working: current stage still in progress\n' > "$d/state/norun.status"
  FM_FAKE_RUN_HEAD=0000000000000000000000000000000000000000
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-norun; branch_sync_block fm/feat-norun "$base_head" "")"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" norun)
  assert_not_contains "$out" "source: run-step" "an unbound branch_sync must not attribute"
  assert_contains "$out" "source: status-log" "falls back when branch_sync carries no run"
  pass "branch_sync without a run id does not attribute"
}

# branch_sync outlives the run it binds, so local.head alone only proves the
# block was read just now. A crew that finished a run and kept working on the
# same branch must not have its live needs-decision masked by that finished run.
test_branch_sync_after_local_work_past_submitted_head_does_not_attribute() {
  reset_fakes
  local d submitted_head local_head out
  d=$(new_case branch-sync-local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-postrun
  submitted_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'follow-up work after the run passed'
  local_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$local_head" != "$submitted_head" ] || fail "fixture invalid: follow-up commit did not move HEAD"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/postrun.meta" "window=fm:fm-postrun" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: keep the deprecated flag or drop it in this slice?\n' > "$d/state/postrun.status"
  FM_FAKE_RUN_HEAD="$submitted_head"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-postrun; branch_sync_block fm/feat-postrun "$local_head" 01RUN "$submitted_head")"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" postrun)
  assert_not_contains "$out" "source: run-step" "a finished run must not be attributed after local work advanced"
  assert_not_contains "$out" "state: done" "the finished run must not report the crew as done"
  assert_not_contains "$out" "superseded" "a live needs-decision must not be marked superseded"
  assert_contains "$out" "state: parked" "the live needs-decision is the current state"
  assert_contains "$out" "source: status-log" "falls back to the status log after the binding is refused"
  assert_contains "$out" "keep the deprecated flag" "the decision prose still reaches firstmate"
  pass "branch_sync does not attribute a run the worktree has advanced past"
}

# Field scoping: branch_sync reuses the run object's `branch` and `head` keys, so
# emitting it first must not decide which run the head-match fallback reads. The
# run object still owns those fields, and this crew's own run stays attributed.
test_branch_sync_before_run_object_still_reads_run_fields() {
  reset_fakes
  local d head out
  d=$(new_case branch-sync-first-run-fields)
  make_repo_on_branch "$d/wt" fm/feat-order
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/order.meta" "window=fm:fm-order" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which retry budget belongs in this slice?\n' > "$d/state/order.status"
  FM_FAKE_RUN_HEAD="$head"
  FM_FAKE_AXI_STATUS="$(branch_sync_block fm/feat-theirs "$head"; run_fixing fm/feat-order)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" order)
  assert_contains "$out" "source: run-step" "the run object still binds when branch_sync is emitted first"
  assert_contains "$out" "state: working" "this crew's own fixing run remains working"
  pass "branch_sync emitted first still resolves run fields from the run object"
}

# Field scoping, refusal direction: a branch_sync naming this crew's branch and
# HEAD must not lend those values to a foreign run block reported alongside it.
test_branch_sync_before_run_object_does_not_attribute_foreign_run() {
  reset_fakes
  local d head out
  d=$(new_case branch-sync-first-foreign-run)
  make_repo_on_branch "$d/wt" fm/feat-anchored
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/anchored.meta" "window=fm:fm-anchored" "worktree=$d/wt" "kind=ship"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/anchored.status"
  FM_FAKE_RUN_HEAD=0000000000000000000000000000000000000000
  FM_FAKE_AXI_STATUS="$(branch_sync_block fm/feat-anchored "$head" 01OTHER; run_fixing fm/feat-theirs)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" anchored)
  assert_not_contains "$out" "source: run-step" "a foreign run must not borrow branch_sync's branch and head"
  assert_contains "$out" "source: status-log" "falls back when no run binds this worktree"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "branch_sync emitted first does not attribute a foreign run"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_corroborated_by_busy_pane
test_no_run_herdr_idle_agent_status_and_idle_pane_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_pipeline_fix_head_in_foreign_repo_binds_via_branch_sync
test_branch_sync_for_other_branch_does_not_attribute
test_branch_sync_for_a_different_run_does_not_attribute
test_branch_sync_without_run_id_does_not_attribute
test_branch_sync_after_local_work_past_submitted_head_does_not_attribute
test_branch_sync_before_run_object_still_reads_run_fields
test_branch_sync_before_run_object_does_not_attribute_foreign_run
test_missing_run_head_falls_back_to_current_state
test_advancing_agent_step_stays_working
test_hung_agent_step_reports_stalled
test_zero_padded_duration_still_reaches_the_budget
test_quiet_remote_check_step_keeps_the_looser_budget
test_hung_remote_check_step_reports_stalled
test_quiet_ci_monitor_with_checks_green_report_stays_done
test_quiet_ci_monitor_without_green_checks_still_stalls
test_missing_activity_figure_leaves_the_verdict_alone
test_spinning_ci_step_on_a_conflicting_pr_reports_stalled
test_a_conflict_the_pipeline_is_still_fixing_is_not_a_stall
test_the_ci_log_tail_is_bought_once_per_invocation
test_empty_check_list_only_counts_while_a_rerun_is_awaited
test_an_absent_forge_answer_never_manufactures_a_stall
test_the_forge_is_asked_nothing_it_need_not_answer
test_active_step_columns_are_located_by_name
test_inactivity_budgets_are_configurable
test_unrecognized_run_status_is_not_working
test_empty_run_status_is_not_working
test_stalled_and_unknown_are_not_provably_working
test_usage_limit_prompt_outranks_active_run
test_usage_limit_prompt_exhausted_window
test_usage_limit_unreadable_quota_is_unknown
test_usage_limit_ignores_ordinary_limit_prose
test_usage_limit_only_for_recorded_claude
test_usage_limit_unreadable_pane_falls_through
test_usage_limit_classifier_over_real_helper
test_fix_review_gate_with_an_ask_user_row_publishes_the_authority_marker
test_authority_marker_reads_the_action_column_by_name
test_steps_row_approval_gate_publishes_the_authority_marker
test_unreadable_gate_status_keeps_the_note_without_the_marker
test_ask_user_in_prose_does_not_publish_the_authority_marker
test_a_park_the_crew_never_wrote_about_publishes_no_park_marker
test_a_park_with_no_published_clock_publishes_no_park_marker
test_an_unparseable_park_clock_publishes_no_park_marker
test_a_coarse_park_clock_does_not_refuse_a_decision_written_at_it
test_deciding_class_over_the_real_helper

echo "all fm-crew-state tests passed"
