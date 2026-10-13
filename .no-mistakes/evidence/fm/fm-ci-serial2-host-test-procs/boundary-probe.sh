# Loaded through BASH_ENV by the test file's own shell only. Before each
# top-level case command it counts every live process descended from this test
# run (identified by the run's temp root in its environment), which is the
# state the previous case left behind when it returned.
unset BASH_ENV
__fm_probe_n=0
__fm_probe_live() {
  local f p
  for f in $(grep -lFa -- "$TMP_ROOT" /proc/[0-9]*/environ 2>/dev/null); do
    p=${f#/proc/}; p=${p%/environ}
    [ "$p" != "$$" ] && [ "$p" != "$BASHPID" ] || continue
    kill -0 "$p" 2>/dev/null || continue
    printf '%s ' "$p"
  done
}
__fm_probe() {
  case $1 in run_case\ test_*|test_*) ;; *) return 0 ;; esac
  [ -n "${TMP_ROOT:-}" ] || return 0
  local now later='' p detail=''
  now=$(__fm_probe_live)
  if [ -n "$now" ]; then
    sleep 0.5
    later=$(__fm_probe_live)
    for p in $later; do detail="$detail [$p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-110)]"; done
  fi
  printf '%s\tbefore_case=%s\tnext=%s\tlive_at_return=%s\tlive_after_0.5s=%s\t%s\n' \
    "$(date +%s)" "$((__fm_probe_n += 1))" "${1#run_case }" "$(set -- $now; echo $#)" "$(set -- $later; echo $#)" "$detail" \
    >> "$FM_PROBE_LOG"
  [ -s "$FM_PROBE_LOG.root" ] || printf '%s\n' "$TMP_ROOT" > "$FM_PROBE_LOG.root"
}
trap '__fm_probe "$BASH_COMMAND"' DEBUG
