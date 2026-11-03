#!/usr/bin/env bash
# fm-test-ref-check.sh - check that durable references to a test case point at
# the test file that defines it.
#
# Usage:
#   bin/fm-test-ref-check.sh [--root <repo>]
#
# Scans every git-tracked file under docs/ and tests/ for lines that carry both
# a tests/<file>.test.sh path and a test_<identifier> token. Each such token
# must be defined as a shell function in at least one test file the same line
# names; otherwise the line is reported as <path>:<line>: <identifier> and the
# check exits 1. Exit 0 prints "fm-test-ref-check: ok refs=<n>".
#
# This is a heuristic. A reference that names only the file, not the case,
# carries no identifier to verify and is never checked, so a case moved out of
# a file it is still credited to that way goes unnoticed. A token written as a
# shell variable ($test_x or ${test_x}) is not a case name and is skipped.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root)
      [ "$#" -ge 2 ] || { echo "fm-test-ref-check: --root needs a path" >&2; exit 2; }
      ROOT=$2; shift 2 ;;
    *) echo "fm-test-ref-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"
git ls-files -z -- docs tests | xargs -0 -r grep -nHE -I \
  'tests/[A-Za-z0-9_.-]+\.test\.sh' -- 2>/dev/null \
  | awk -v root="$ROOT" '
    function defines(file, id,    line, found) {
      key = file SUBSEP id
      if (key in cache) return cache[key]
      found = 0
      while ((getline line < file) > 0) {
        if (line ~ ("^[[:space:]]*(function[[:space:]]+)?" id "[[:space:]]*(\\(\\))?[[:space:]]*\\{?[[:space:]]*$") && \
            (line ~ /\(\)/ || line ~ /^[[:space:]]*function[[:space:]]/)) { found = 1; break }
      }
      close(file)
      cache[key] = found
      return found
    }
    {
      # grep -nH output is <path>:<line>:<text>; the text may contain colons.
      p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
      q = index(rest, ":"); lineno = substr(rest, 1, q - 1); text = substr(rest, q + 1)
      nfiles = 0; s = text
      while (match(s, /tests\/[A-Za-z0-9_.-]+\.test\.sh/)) {
        files[++nfiles] = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      }
      s = text; prev = ""
      while (match(s, /test_[A-Za-z0-9_]+/)) {
        before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : prev
        id = substr(s, RSTART, RLENGTH)
        prev = substr(s, RSTART + RLENGTH - 1, 1)
        s = substr(s, RSTART + RLENGTH)
        if (before ~ /[A-Za-z0-9_$\{.\/-]/) continue
        refs++
        ok = 0
        for (i = 1; i <= nfiles; i++) if (defines(files[i], id)) { ok = 1; break }
        if (!ok) { print path ":" lineno ": " id " is not defined in " files[1] (nfiles > 1 ? " or the other files named" : ""); bad++ }
      }
      delete files
    }
    END {
      if (bad) { printf "fm-test-ref-check: %d stale test reference(s)\n", bad; exit 1 }
      printf "fm-test-ref-check: ok refs=%d\n", refs + 0
    }
  '
