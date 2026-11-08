#!/usr/bin/env bash
# fm-nm-post-test-retest.sh - re-run the colocated tests for scripts that a
# no-mistakes Document, Lint, or gate fix round changed after the Test step ran.
#
# Usage:
#   bin/fm-nm-post-test-retest.sh [--list]
#
# Run from the repository root. Walks back from HEAD over the commits whose
# subject starts "no-mistakes(document):", "no-mistakes(lint):", or
# "no-mistakes(gate.<anchor>.<name>):", and stops at the first other commit.
# Document, Lint, and gates anchored after them are the only steps that commit
# after Test, so that tip run is exactly what Test never saw.
#
# Each touched bin/<name>.sh maps to tests/<name>.test.sh, and each touched
# tests/<name>.test.sh maps to itself; a mapped file absent from the current
# tree is reported and skipped. The selected tests run through the repository's own
# bin/fm-test-run.sh, and this script exits with its status. With nothing
# selected it prints "fm-nm-post-test-retest: no tests to re-run" and exits 0.
#
# --list prints the selected test paths, one per line, without running them.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

LIST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) LIST=1; shift ;;
    *) echo "fm-nm-post-test-retest: unknown argument: $1" >&2; exit 2 ;;
  esac
done

commits=()
while IFS=' ' read -r sha subject; do
  case "$subject" in
    'no-mistakes(document):'*|'no-mistakes(lint):'*|'no-mistakes(gate.'*) commits+=("$sha") ;;
    *) break ;;
  esac
done < <(git log --format='%H %s' HEAD)

tests=()
if [ "${#commits[@]}" -gt 0 ]; then
  while IFS= read -r path; do
    case "$path" in
      bin/*/*) continue ;;
      bin/*.sh) candidate="tests/$(basename "$path" .sh).test.sh" ;;
      tests/*/*) continue ;;
      tests/*.test.sh) candidate=$path ;;
      *) continue ;;
    esac
    if [ -f "$candidate" ]; then
      tests+=("$candidate")
    else
      echo "fm-nm-post-test-retest: no $candidate for $path; skipped" >&2
    fi
  done < <(printf '%s\n' "${commits[@]}" | git diff-tree --stdin --no-commit-id --name-only -r | sort -u)
fi

if [ "${#tests[@]}" -eq 0 ]; then
  [ "$LIST" -eq 1 ] || echo "fm-nm-post-test-retest: no tests to re-run"
  exit 0
fi

mapfile -t tests < <(printf '%s\n' "${tests[@]}" | sort -u)
if [ "$LIST" -eq 1 ]; then
  printf '%s\n' "${tests[@]}"
  exit 0
fi
echo "fm-nm-post-test-retest: re-running ${tests[*]} for ${#commits[@]} post-test fix commit(s)"
exec bin/fm-test-run.sh "${tests[@]}"
