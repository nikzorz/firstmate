#!/usr/bin/env bash
# One-off probe: an installed judge that stays busy, then fails.
cat >/dev/null; date +%s > "$(dirname "$0")/slow-judge.started"; sleep 120; date +%s > "$(dirname "$0")/slow-judge.ended"; exit 1
