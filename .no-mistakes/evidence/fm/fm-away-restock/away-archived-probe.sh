#!/usr/bin/env bash
# Probe: after the captain returns (record archived) the empty-fleet heartbeat is absorbed again.
set -u; ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"; "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
run "$ROOT/bin/fm-afk-contract.sh" enter --spend 2 --words "Restock the fleet until I am back." >/dev/null
run "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null; echo "mode after archive: [$(run "$ROOT/bin/fm-afk-contract.sh" mode 2>&1)]"
out=$(run FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 timeout 8 "$ROOT/bin/fm-watch.sh" 2>/dev/null); rc=$?
[ $rc -eq 124 ] && echo "archived record, empty fleet: watcher still running after 8s (absorbed), streak=$(cat "$LAB/state/.heartbeat-streak")" || echo "exited rc=$rc [$out]"
rm -rf "$LAB"
