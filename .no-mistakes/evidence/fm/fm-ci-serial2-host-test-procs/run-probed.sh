#!/usr/bin/env bash
# usage: run-probed.sh <label> <test file>
E=$(cd "$(dirname "$0")" && pwd); label=$1; file=$2
rm -f "$E/$label".*
start=$(date +%s)
FM_PROBE_LOG="$E/$label.boundaries.tsv" BASH_ENV="$E/boundary-probe.sh" bash "$file" 2>&1 \
  | while IFS= read -r l; do printf '%s %s\n' "$(( $(date +%s) - start ))s" "$l"; done > "$E/$label.output.txt"
rc=${PIPESTATUS[0]}
root=$(cat "$E/$label.boundaries.tsv.root" 2>/dev/null)
sleep 1
left=$(grep -lFa -- "$root" /proc/[0-9]*/environ 2>/dev/null | wc -l)
printf 'exit=%s duration_s=%s live_after_file_exit=%s\n' "$rc" "$(( $(date +%s) - start ))" "$left" > "$E/$label.result.txt"
