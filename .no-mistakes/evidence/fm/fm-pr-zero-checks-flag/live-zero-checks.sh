#!/usr/bin/env bash
# Live drive of bin/fm-crew-state.sh for the zero-checks flag.
# Real: the script under test, the real `gh` CLI reading real pull requests on
# github.com, and this repository's own .github/workflows as the task copy.
# Stubbed: only the `no-mistakes` run status and ci log (the test suite's own
# stub), because the test phase may not start a pipeline run of its own.
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-zero-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
eval "$(awk '/^make_fakebin\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$ROOT/tests/fm-crew-state.test.sh")"
make_fakebin "$T" >/dev/null
rm -f "$T/fakebin/gh"                       # the forge read is the real gh
echo "gh in use: $(PATH="$T/fakebin:$PATH" command -v gh)"

git init -q "$T/wt"
git -C "$T/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$T/wt" checkout -q -b fm/feat-live
mkdir -p "$T/wt/.github" "$T/state"
cp -r "$ROOT/.github/workflows" "$T/wt/.github/workflows"
HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
printf '%s\n' "window=fm-zero-live:fm-live" "worktree=$T/wt" "kind=ship" > "$T/state/live.meta"

status() {  # <pr-url> <active_for>
  cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat-live
  status: ci
  head: "$HEAD_SHA"
  pr: "$1"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,$2,"5s ago: log: no CI checks reported yet, waiting for checks to register...","",round 1
EOF
}
NO_CHECKS_YET='monitoring CI for PR (timeout: 168h0m0s)
no CI checks reported yet, waiting for checks to register...'

drive() {  # <label> <pr-url> <active_for> [ci-log]
  echo
  echo "### $1"
  echo "pr=$2 ci-step-active_for=$3"
  echo "forge now: $(gh pr view "$2" --json state,mergeable,baseRefName,createdAt,statusCheckRollup \
    -q '"state=\(.state) mergeable=\(.mergeable) base=\(.baseRefName) createdAt=\(.createdAt) checks=\(.statusCheckRollup|length)"')"
  FM_FAKE_AXI_STATUS=$(status "$2" "$3") FM_FAKE_CI_LOGS=${4-$NO_CHECKS_YET} \
    PATH="$T/fakebin:$PATH" FM_STATE_OVERRIDE="$T/state" "$ROOT/bin/fm-crew-state.sh" live
}
export FM_FAKE_AXI_STATUS FM_FAKE_CI_LOGS

ZERO=$2 HEALTHY=$3 OTHERBASE=$4
drive "S1 zero checks, mergeable, base main, ci step waiting 48m" "$ZERO" 48m0s
drive "S2 same pull request, ci step waiting only 40s (inside settle time)" "$ZERO" 40s
drive "S2b same pull request, ci step waiting 4m59s (one second short)" "$ZERO" 4m59s
drive "S2c same pull request, ci step waiting 5m0s (boundary)" "$ZERO" 5m0s
drive "S3 healthy pull request with registered checks, ci log still stale" "$HEALTHY" 48m0s
drive "S4 zero checks but base branch no workflow here names" "$OTHERBASE" 48m0s
drive "S5 zero-check pull request, but the ci step already saw checks running" "$ZERO" 48m0s "$NO_CHECKS_YET
CI checks running, waiting for results..."
echo; echo "### S6 forge probe disabled (FM_CREW_STATE_NO_FORGE=1)"
FM_CREW_STATE_NO_FORGE=1 drive "S6 zero checks, 48m, forge reads off" "$ZERO" 48m0s
rm -rf "$T/wt/.github/workflows"
drive "S7 zero checks, 48m, task copy has no workflows at all" "$ZERO" 48m0s
