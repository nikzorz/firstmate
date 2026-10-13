#!/usr/bin/env bash
# Same live drive as live-zero-checks.sh, one case: a real CONFLICTING pull
# request with zero checks and base main, ci step waiting 48m.
set -u
ROOT=$1 PR=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-zero-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
eval "$(awk '/^make_fakebin\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$ROOT/tests/fm-crew-state.test.sh")"
make_fakebin "$T" >/dev/null
rm -f "$T/fakebin/gh"
git init -q "$T/wt"
git -C "$T/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$T/wt" checkout -q -b fm/feat-live
mkdir -p "$T/wt/.github" "$T/state"
cp -r "$ROOT/.github/workflows" "$T/wt/.github/workflows"
printf '%s\n' "window=fm-zero-live:fm-live" "worktree=$T/wt" "kind=ship" > "$T/state/live.meta"
export FM_FAKE_CI_LOGS='monitoring CI for PR (timeout: 168h0m0s)
no CI checks reported yet, waiting for checks to register...'
export FM_FAKE_AXI_STATUS="run:
  id: \"01RUN\"
  branch: fm/feat-live
  status: ci
  head: \"$(git -C "$T/wt" rev-parse HEAD)\"
  pr: \"$PR\"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,48m0s,\"5s ago: log: no CI checks reported yet, waiting for checks to register...\",\"\",round 1"
echo "### S8 conflicting pull request with zero checks, ci step waiting 48m"
echo "forge now: $(gh pr view "$PR" --json state,mergeable,baseRefName,statusCheckRollup \
  -q '"state=\(.state) mergeable=\(.mergeable) base=\(.baseRefName) checks=\(.statusCheckRollup|length)"')"
PATH="$T/fakebin:$PATH" FM_STATE_OVERRIDE="$T/state" "$ROOT/bin/fm-crew-state.sh" live
