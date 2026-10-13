#!/usr/bin/env bash
# Drives a targeted subset of tests/fm-supervision-host.test.sh from a given
# commit and, after every case returns, counts the live processes that still
# carry the run's fixture root in their environment or command line.
# usage: probe-driver.sh <worktree> <commit> <case>...
set -u
wt=$1 commit=$2; shift 2
gen="$wt/tests/.nm-probe-$$.sh"
trap 'rm -f "$gen"' EXIT
src=$(git -C "$wt" show "$commit:tests/fm-supervision-host.test.sh")
first=$(printf '%s\n' "$src" | grep -n -E '^(run_case )?test_[a-z0-9_]+$' | head -1 | cut -d: -f1)
wrapped=no
printf '%s\n' "$src" | sed -n "${first}p" | grep -q '^run_case ' && wrapped=yes
{
  printf '%s\n' "$src" | head -n "$((first - 1))"
  cat <<'PROBE'
nm_survivors() {  # prints live pids (not this shell) tied to the fixture root
  local list f pid
  list=$(grep -lasF -- "$TMP_ROOT" /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3 | sort -un)
  for pid in $list; do
    [ "$pid" = "$$" ] && continue
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = Z ] && continue
    printf '%s\n' "$pid"
  done
}
nm_probe() {  # <case> <start-seconds>
  local pids n
  sleep 2
  pids=$(nm_survivors); n=$(printf '%s' "$pids" | grep -c . || true)
  printf 'PROBE\tcase=%s\tseconds=%s\tlive_fixture_processes=%s\n' "$1" "$((SECONDS - $2))" "$n"
  for p in $pids; do printf '    survivor pid=%s %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | sed "s#$TMP_ROOT#<fixture>#g" | cut -c1-110)"; done
}
PROBE
  for c in "$@"; do
    printf 'nm_t=$SECONDS\n'
    if [ "$wrapped" = yes ]; then printf 'run_case %s\n' "$c"; else printf '%s\n' "$c"; fi
    printf 'nm_probe %s "$nm_t"\n' "$c"
  done
  printf 'sleep 8\nnm_quiet=$(nm_survivors)\nprintf "PROBE\\tafter-8s-quiet\\tlive_fixture_processes=%%s\\n" "$(printf "%%s" "$nm_quiet" | grep -c . || true)"\nfor p in $nm_quiet; do printf "    survivor pid=%%s %%s\\n" "$p" "$(tr "\\0" " " < "/proc/$p/cmdline" 2>/dev/null | cut -c1-140)"; done\nprintf "%%s\\n" "$TMP_ROOT" > "${NM_ROOT_OUT:-/dev/null}"\n'
} > "$gen"
rootout=$(mktemp)
echo "== commit $commit (cases wrapped by run_case: $wrapped) =="
NM_ROOT_OUT=$rootout bash "$gen"; rc=$?
echo "== test file exit code: $rc =="
root=$(cat "$rootout"); rm -f "$rootout"
sleep 2
if [ -n "$root" ]; then
  left=$(grep -lasF -- "$root" /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3 | sort -un | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done | grep -c . || true)
  echo "== live fixture processes after the file exited: $left =="
fi
exit $rc
