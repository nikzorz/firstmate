#!/usr/bin/env bash
# Sources the test harness helpers (no tests run), then drives the real
# bin/fm-crew-state.sh with the real gh CLI against real GitHub PRs.
set -u
cd "$WT_ROOT"
. "$HARNESS"
ZERO=https://github.com/r-lgbtq/conference2027/pull/3
HEALTHY=https://github.com/wei/socialify/pull/885
case_for() {  # <name> <id> <pr-url> <base> -> case dir with real gh
  local d; d=$(zero_checks_case "$1" "$2")
  rm -f "$d/fakebin/gh" "$d/fakebin/gh-axi"
  printf '%s\n' "$d"
}
spin() {  # <branch> <url> <activity> [active_for]
  run_ci_spinning "$1" "$3" "${4-45m0s}" | sed "s#https://github.com/o/r/pull/368#$2#"
}
show() { printf '\n### %s\n$ fm-crew-state.sh %s   (gh=%s)\n%s\n' "$1" "$2" "$(command -v gh)" "$3"; }
reset_fakes
ACT='"5s ago: log: no CI checks reported yet, waiting for checks to register..."'
FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_FIRST_CHECKS"

echo "real forge answer for $ZERO:"; gh pr view $ZERO --json mergeable,statusCheckRollup,createdAt,baseRefName -q '[.mergeable,(.statusCheckRollup|length|tostring),.createdAt,.baseRefName]|join(" ")'
echo "real forge answer for $HEALTHY:"; gh pr view $HEALTHY --json mergeable,statusCheckRollup,baseRefName -q '[.mergeable,(.statusCheckRollup|length|tostring),.baseRefName]|join(" ")'

d=$(case_for s1 za); printf 'on:\n  pull_request:\n    branches: [main]\njobs: {}\n' | write_workflow "$d/wt" ci.yml
FM_FAKE_AXI_STATUS="$(spin fm/feat-za $ZERO "$ACT")"; show "S1 zero checks, ci waited 45m" za "$(run_crew_state $d za)"

FM_FAKE_AXI_STATUS="$(spin fm/feat-za $ZERO "$ACT" 40s)"; show "S2 zero checks, ci waited 40s (inside settle)" za "$(run_crew_state $d za)"

FM_FAKE_AXI_STATUS="$(spin fm/feat-za $ZERO '"2h1m ago: log: no CI checks reported yet, waiting for checks to register..."' 3h0m0s)"; show "S3 zero checks, ci quiet past 2h budget" za "$(run_crew_state $d za)"

d2=$(case_for s4 zb); printf 'on:\n  pull_request:\n    branches: [main]\njobs: {}\n' | write_workflow "$d2/wt" ci.yml
FM_FAKE_AXI_STATUS="$(spin fm/feat-zb $HEALTHY "$ACT")"; show "S4 healthy PR with checks (base master; workflow on main)" zb "$(run_crew_state $d2 zb)"
printf 'on: [pull_request]\njobs: {}\n' | write_workflow "$d2/wt" ci.yml
show "S4b healthy PR with checks, unfiltered pull_request workflow" zb "$(run_crew_state $d2 zb)"

d3=$(case_for s5 zc); printf 'on:\n  push:\n    branches: [main]\njobs: {}\n' | write_workflow "$d3/wt" ci.yml
FM_FAKE_AXI_STATUS="$(spin fm/feat-zc $ZERO "$ACT")"; show "S5 zero checks, repo workflows start only on push" zc "$(run_crew_state $d3 zc)"

FM_FAKE_AXI_STATUS="$(spin fm/feat-za $ZERO '"5s ago: log: CI workflows are held awaiting maintainer approval - no jobs have run, waiting..."')"
FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_FIRST_CHECKS
CI workflows are held awaiting maintainer approval - no jobs have run, waiting..."
show "S6 zero checks, workflows held for maintainer approval" za "$(run_crew_state $d za)"

FM_FAKE_CI_LOGS="$CI_LOG_AWAITING_FIRST_CHECKS"; FM_FAKE_AXI_STATUS="$(spin fm/feat-za $ZERO "$ACT")"
show "S7 zero checks, FM_CREW_STATE_NO_FORGE=1" za "$(FM_CREW_STATE_NO_FORGE=1 run_crew_state $d za)"
