#!/usr/bin/env bash
# Probe: real bin/fm-watch.sh + bin/fm-afk-contract.sh on a disposable lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
watch_once() {  # prints watcher stdout or ABSORBED after timeout
  rm -f "$LAB/state/.heartbeat-streak"
  out=$(run FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 timeout 8 "$ROOT/bin/fm-watch.sh" 2>/dev/null); rc=$?
  if [ $rc -eq 124 ]; then echo "watcher still running after 8s (heartbeat absorbed), streak=$(cat "$LAB/state/.heartbeat-streak" 2>/dev/null)"; else echo "watcher exited rc=$rc stdout=[$out]"; fi
}
echo "## 1. No away record, empty fleet"; watch_once
echo "## 2. Enter away with the incident words, spend cap 2"
run "$ROOT/bin/fm-afk-contract.sh" enter --spend 2 --words "Yes you have permission to merge anything as it goes green. Restock the fleet with the correctness and dev-loop optimization work until that's all done. Then take up whatever arena work is available until I am back." >/dev/null && echo "entered; mode=$(run "$ROOT/bin/fm-afk-contract.sh" mode)"
echo "slots: $(run "$ROOT/bin/fm-afk-contract.sh" slots)"
echo "## 3. Away, empty fleet (0/2 slots)"; watch_once
echo "drained queue:"; run "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | cat -A | head -3 || true
echo "## 4. Away, one ship task + one secondmate (1/2 slots)"
printf 'kind=ship\n' > "$LAB/state/a.meta"; printf 'kind=secondmate\n' > "$LAB/state/m.meta"
echo "slots: $(run "$ROOT/bin/fm-afk-contract.sh" slots)"; watch_once
run "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
echo "## 5. Away, slots full (2/2)"
printf 'kind=scout\n' > "$LAB/state/b.meta"
echo "slots: $(run "$ROOT/bin/fm-afk-contract.sh" slots)"; watch_once
echo "## 6. Archive away record (captain back), empty fleet"
rm -f "$LAB"/state/*.meta; run "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
run "$ROOT/bin/fm-afk-contract.sh" slots; echo "slots exit=$?"; watch_once
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
