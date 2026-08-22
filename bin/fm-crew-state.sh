#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|stalled|parked|done|blocked|paused|usage-limited|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   1b. For a recorded claude crew ONLY: does the pane show Claude Code's
#      usage-limit prompt (bin/fm-claude-limit-lib.sh)? That prompt waits for a
#      human forever, so the crew is not working no matter what any run says -
#      hence this is checked BEFORE the run lookup below, not as a fallback, and
#      reports the distinct `usage-limited` state. The detail carries a
#      `limit-window: reset|exhausted|unknown` token from the quota authority so
#      a consumer can tell a recoverable stall from a bounded external wait
#      without reading the pane again. Unreadable pane or uncertain match: fall
#      through unchanged, never a guess.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when no-mistakes' own branch_sync block binds it to this
#      worktree's branch and HEAD and names that same HEAD as the head the run
#      was submitted at, or, failing that, when its head equals the worktree HEAD
#      or the worktree HEAD is an ancestor of the run head (a run tip this
#      worktree can still resolve, advanced past HEAD on the same history).
#      The head rule alone cannot bind a healthy run: the pipeline's auto-fix
#      commits live only in no-mistakes' own repo, so the head it reports stops
#      resolving here as soon as the first one is made. Only the pipeline's own
#      submitted head still carries code identity there, and it has to: the
#      binding stays published after a run goes terminal, so without it a
#      finished run would keep masking a crew that has since committed further
#      work. Local work that advanced past the run head, or diverged from it,
#      invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   2b. A non-terminal run reports WHETHER it is advancing, not only that it
#      exists. `axi status` publishes an `active_steps` table whose
#      `last_activity` names how long the active step has been quiet, so a run
#      parked for hours and one that logged four seconds ago are distinguishable
#      from the response already being read. Past the inactivity budget for that
#      step (FM_CREW_STATE_* below) the state is `stalled`, which no absorb class
#      treats as healthy, so it reaches firstmate instead of reading as working.
#      An `active_steps` table that is absent (an older no-mistakes) or whose
#      `last_activity` is `unknown` carries no elapsed figure, and the run stays
#      `working` - a stated limit of the budget, not a silent one.
#      docs/verification/supervision.md records the live evidence for that
#      table's field names and its three last_activity renderings.
#      Symmetrically, a run status word this reader does not recognize, and an
#      empty one, report `unknown` rather than `working`: an unrecognized future
#      status is not evidence of a healthy run.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-claude-limit-lib.sh
. "$SCRIPT_DIR/fm-claude-limit-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Inactivity budgets for an active run, in seconds, measured from the active
# step's own reported last activity. Past its budget a step is reported
# `stalled` rather than `working`.
#
# Two budgets, not one, because the two kinds of active step go quiet for
# different reasons: an agent-driven step (review, test, lint, document, and the
# fix rounds) logs as it works, so half an hour of silence is already unusual,
# while the ci step only monitors a remote forge, logs sparsely by design, and
# carries no native agent pid. Both figures are captain preferences chosen far
# tighter than the observed 20h52m failure and loose enough that an ordinary
# quiet stretch wakes nobody; they are tuning constants, not derived limits, and
# are meant to be revised on evidence of false wakes without editing any logic.
FM_CREW_STATE_AGENT_QUIET_SECS=${FM_CREW_STATE_AGENT_QUIET_SECS:-1800}
case "$FM_CREW_STATE_AGENT_QUIET_SECS" in ''|*[!0-9]*) FM_CREW_STATE_AGENT_QUIET_SECS=1800 ;; esac
FM_CREW_STATE_REMOTE_QUIET_SECS=${FM_CREW_STATE_REMOTE_QUIET_SECS:-7200}
case "$FM_CREW_STATE_REMOTE_QUIET_SECS" in ''|*[!0-9]*) FM_CREW_STATE_REMOTE_QUIET_SECS=7200 ;; esac
# The active-step names that only monitor a remote forge and therefore draw the
# looser budget above. One entry today; a space-delimited list so a future
# remote-only step needs no new branch.
FM_CREW_STATE_REMOTE_STEPS=${FM_CREW_STATE_REMOTE_STEPS:-ci}
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_pane_is_busy: the busy-signature fallback, backend-aware the same way -
# fm_backend_busy_state's native semantic state (herdr's agent.get) when
# available, else the shared harness-scoped pane-regex reader
# (fm_pane_is_busy, bin/fm-tmux-lib.sh).
#
# `busy` alone is trusted outright. Both `idle` and unknown/unparseable fall
# through to the shared tail-regex corroboration, NOT just unknown: herdr's
# agent.get reports generation state ("working" while the model is streaming
# a turn, "done"/"idle" once it is not - docs/herdr-backend.md "Busy state"),
# which is a narrower signal than "this crew's turn/tool call is still in
# progress". A crew blocked on its own long-running foreground tool call (e.g.
# `no-mistakes axi run` without --yes, which blocks synchronously until a gate
# or outcome - AGENTS.md section 7) is not generating for that whole span, so
# agent.get can read idle/blocked (bin/backends/herdr.sh maps both to `idle`)
# while the pane's own rendered text still shows that recorded harness's busy
# signature for the entire tool call, exactly like tmux's regex-only reader
# would correctly report. Trusting herdr's `idle`
# outright (skipping that corroboration) is what let a still-working crew read
# as not-busy here, and - combined with a no-mistakes run-step lookup that also
# missed attribution (see nm_runs_status_for_branch) - as not provably working in
# fm-classify-lib.sh, triggering an immediate (non-wedge) stale wake instead of
# the absorb-then-escalate path. A genuinely human-blocked agent (a permission
# dialog, not mid-tool-call) does not render the busy banner, so this
# corroboration does not mask that case: it stays correctly not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" "$HARNESS" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
            | fm_busy_lines_match "$HARNESS"
          ;;
      esac
      ;;
  esac
}

# --- claude usage-limit prompt (checked BEFORE the run lookup) --------------
#
# Root cause of the 2026-07-29 incident: a crew that exhausts the account usage
# limit mid-turn stops on Claude Code's interactive choice prompt. Its
# no-mistakes run is still `running`, so the run-step path below reported
# `working` and every consumer read the crew as healthy; the prompt itself never
# self-resumes, so three crews idled ~8.7 hours after the window had reset. A
# pane parked on that prompt is authoritative evidence the crew is NOT working,
# which is exactly why this outranks the run-step rather than sitting in the
# no-run fallback at the bottom of this file.
#
# Cost: one bounded pane capture, and only for a recorded claude crew - other
# harnesses pay nothing and are never classified by a claude signature. On a
# match it also SAVES the no-mistakes calls below. The quota read is bounded and
# read-only, and runs only on a match.
if [ "$HARNESS" = claude ] && [ -n "$BACKEND_TARGET" ]; then
  LIMIT_SCAN_LINES=$(fm_claude_limit_scan_lines)
  LIMIT_PANE=$(fm_backend_capture "$TASK_BACKEND" "$BACKEND_TARGET" "$LIMIT_SCAN_LINES" "$EXPECTED_LABEL" 2>/dev/null) || LIMIT_PANE=""
  if [ -n "$LIMIT_PANE" ] && printf '%s' "$LIMIT_PANE" | fm_claude_limit_dialog_match; then
    LIMIT_WINDOW=$(fm_claude_limit_window_state)
    emit "$FM_CLASSIFY_USAGE_LIMITED_STATE" pane \
      "claude usage-limit prompt is waiting for a human${SEP}${FM_CLASSIFY_LIMIT_WINDOW_PREFIX}${LIMIT_WINDOW}"
  fi
fi

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT), read from
# the reported run's own scope only: a top-level key, or a field of the run
# object. `axi status` renders sibling top-level blocks whose keys collide with
# the run object's own - branch_sync carries `branch`, `head` and `status` - so
# an unscoped read resolves whichever block is emitted first, and the emission
# order silently decides which run's identity the attribution rules below see.
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | awk -v pre="$1:" '
    /^[^ ]/ { top = $0; sub(/:.*$/, "", top) }
    /^ / && top != "run" { next }
    { line = $0; sub(/^ +/, "", line) }
    index(line, pre) == 1 {
      val = substr(line, length(pre) + 1)
      sub(/^ +/, "", val)
      print val
      exit
    }
  '
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# --- is the active run still advancing? -------------------------------------
#
# `axi status` publishes, for a running or fixing run, a table shaped
#
#   active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
#     review,running,7h7m,"5s ago: log: I'll review the branch changes now.","424242",round 3
#     ci,running,4h20m,"quiet 20h52m ago: log: all CI checks passed...","",round 1
#     ci,running,4h20m,unknown,"",round 1
#
# so the elapsed-since-last-activity figure firstmate needs is already inside the
# response it pays for. Columns are located by NAME from the table header rather
# than by position, so a no-mistakes that reorders or adds columns still parses,
# and `last_activity` is unquoted only in the third shape above, which reports no
# elapsed figure at all.
#
# Prints one "<step><TAB><last_activity>" line per active step; nothing when the
# table is absent.
nm_active_step_rows() {
  printf '%s\n' "$RUN_OUT" | awk '
    # Split a TOON table row on commas that are not inside a quoted field, and
    # drop the quotes. A quoted last_activity carries commas of its own.
    function splitrow(s, out,   i, c, cur, inq, n) {
      n = 0; cur = ""; inq = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == "\"") inq = 0; else cur = cur c }
        else if (c == "\"") inq = 1
        else if (c == ",") { out[++n] = cur; cur = "" }
        else cur = cur c
      }
      out[++n] = cur
      return n
    }
    /^ *active_steps\[[0-9]+\]\{/ {
      hdr = $0
      sub(/^[^{]*\{/, "", hdr)
      sub(/\}.*$/, "", hdr)
      n = split(hdr, cols, ",")
      si = 0; li = 0
      for (i = 1; i <= n; i++) {
        gsub(/^ +/, "", cols[i]); gsub(/ +$/, "", cols[i])
        if (cols[i] == "step") si = i
        if (cols[i] == "last_activity") li = i
      }
      intab = (si > 0 && li > 0)
      next
    }
    intab {
      # Rows are indented past the header; anything shallower ends the table.
      if ($0 !~ /^    /) { intab = 0; next }
      line = $0
      sub(/^ +/, "", line)
      if (line == "") { intab = 0; next }
      n = splitrow(line, f)
      if (n < si || n < li) next
      print f[si] "\t" f[li]
    }
  '
}

# Seconds named by a no-mistakes duration token (30s, 5m30s, 1h0m, 20h52m,
# 3d11h). Non-zero when the token is not a duration, which is how an `unknown`
# last_activity and any future rendering this reader does not understand stay
# out of the budget rather than being guessed at.
#
# Each component is forced to base ten. The installed formatter does not zero-pad
# (`1h0m`, `13h5m`, `3d11h`, never `1h05m`), so this guards a rendering nobody
# emits today rather than one observed - but a padded `08` or `09` is an INVALID
# OCTAL constant, and bash treats that as a fatal expansion error rather than a
# bad term. That would kill this function's subshell and drop the step from the
# budget silently, which is the one outcome the paragraph above forbids.
nm_duration_secs() {  # <token>
  local tok=$1 total=0 num='' ch i len
  case "$tok" in ''|*[!0-9dhms]*) return 1 ;; esac
  len=${#tok}
  i=0
  while [ "$i" -lt "$len" ]; do
    ch=${tok:$i:1}
    i=$((i + 1))
    case "$ch" in
      [0-9]) num="$num$ch"; continue ;;
    esac
    [ -n "$num" ] || return 1
    case "$ch" in
      d) total=$((total + 10#$num * 86400)) ;;
      h) total=$((total + 10#$num * 3600)) ;;
      m) total=$((total + 10#$num * 60)) ;;
      s) total=$((total + 10#$num)) ;;
    esac
    num=''
  done
  [ -z "$num" ] || return 1
  printf '%s' "$total"
}

# Seconds a `last_activity` value reports as elapsed, from its leading duration
# token: "5s ago: log: ..." and "quiet 20h52m ago: log: ..." both parse, and
# "unknown" does not. Reads only the leading token, so prose after it - which
# can legitimately contain digits and unit letters - is never mistaken for a
# duration.
nm_last_activity_secs() {  # <last_activity-value>
  local v=$1
  v=$(trim "$v")
  case "$v" in 'quiet '*) v=${v#quiet } ;; esac
  v=$(trim "$v")
  nm_duration_secs "${v%% *}"
}

# The inactivity budget for one active step: the looser remote-monitoring figure
# for a step that only watches a remote forge, the agent-driven figure otherwise.
nm_step_quiet_budget() {  # <step>
  local step=$1 remote
  for remote in $FM_CREW_STATE_REMOTE_STEPS; do
    if [ "$step" = "$remote" ]; then
      printf '%s' "$FM_CREW_STATE_REMOTE_QUIET_SECS"
      return
    fi
  done
  printf '%s' "$FM_CREW_STATE_AGENT_QUIET_SECS"
}

# Prints "<step> <quiet-secs> <budget-secs>" for the active step that has been
# quiet longest past its own budget; prints nothing when every active step is
# inside budget, when no elapsed figure was reported, or when the table is absent.
nm_stalled_step() {
  local step act secs budget worst_over=0 worst=''
  while IFS=$'\t' read -r step act; do
    [ -n "$step" ] || continue
    secs=$(nm_last_activity_secs "$act") || continue
    budget=$(nm_step_quiet_budget "$step")
    [ "$secs" -gt "$budget" ] || continue
    if [ $((secs - budget)) -ge "$worst_over" ]; then
      worst_over=$((secs - budget))
      worst="$step $secs $budget"
    fi
  done <<EOF
$(nm_active_step_rows)
EOF
  printf '%s' "$worst"
}

# Human-readable minutes/hours for a budget breach detail.
nm_secs_human() {  # <seconds>
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  elif [ "$s" -ge 60 ]; then printf '%dm' "$((s / 60))"
  else printf '%ds' "$s"; fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      if ! nm_coarse_head_matches_worktree "$sha"; then
        continue
      fi
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rules:
#   - missing/empty head field: cannot bind; reject the run
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (the run tip advanced past
#     HEAD on the same history and still resolves here; a pipeline auto-fix
#     commit does not, which is what nm_branch_sync_binds_worktree binds)
#   - run head is a strict ancestor of worktree HEAD: no match (local work
#     advanced outside the run)
#   - diverged / run head not in this worktree: no match (rewritten branch tip)
nm_run_head_matches_worktree() {
  local run_head local_full run_full
  run_head=$(strip_quotes "$(nm_field head)")
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# branch_sync is the run-to-worktree binding no-mistakes publishes itself: it is
# emitted only when the checked-out branch is bound to the reported run, and its
# local.head is read from THIS worktree, so binding needs no commit to be
# resolvable here. That is what nm_run_head_matches_worktree cannot do: a
# pipeline auto-fix commit lives only in no-mistakes' own repo, so the run head
# it reports stops resolving the moment a healthy run makes its first fix
# commit, and attribution is lost for the rest of the run.
#
# Scalar value of <key> inside branch_sync's <section> sub-block; empty when the
# block, the section, or the key is absent. TOON indents with plain spaces, so
# the indent tests stay plain-space too: POSIX bracket expressions are a silent
# no-match on one-true-awk builds old enough to predate them, and a silent empty
# read here is indistinguishable from an absent block.
nm_bs_field() {  # <section> <key>
  printf '%s\n' "$RUN_OUT" | awk -v sec="  $1:" -v key="    $2:" '
    /^branch_sync:$/ { in_bs = 1; next }
    !in_bs { next }
    /^[^ ]/ { exit }
    $0 == sec { in_sec = 1; next }
    in_sec && /^  [^ ]/ { exit }
    in_sec && index($0, key) == 1 { sub(/^[^:]*: */, "", $0); print; exit }
  '
}

# The commit a branch_sync field names, resolved here so an abbreviated sha still
# compares equal to a full one; non-zero when the field is absent or names no
# commit this worktree holds.
nm_bs_commit() {  # <section> <key>
  local raw
  raw=$(strip_quotes "$(nm_bs_field "$1" "$2")")
  [ -n "$raw" ] || return 1
  git -C "$WT" rev-parse --verify "${raw}^{commit}" 2>/dev/null
}

# 0 when no-mistakes itself asserts the reported run owns this worktree: a bound
# run id, this crew's branch, this worktree's exact HEAD, and that same HEAD as
# the head the run was submitted at. The triple keeps the refusal direction even
# if a future no-mistakes emits branch_sync unconditionally rather than only for
# a bound branch.
nm_branch_sync_binds_worktree() {
  local bs_run bs_branch bs_head bs_submitted run_id local_full
  bs_run=$(strip_quotes "$(nm_bs_field pipeline run)")
  [ -n "$bs_run" ] || return 1
  bs_branch=$(strip_quotes "$(nm_bs_field local branch)")
  [ -n "$bs_branch" ] && [ "$bs_branch" = "$CREW_BRANCH" ] || return 1
  # The binding authorizes exactly one run, so a reported run that is not that
  # run stays unattributed - the same cross-attribution guard the head rule was
  # reaching for. An output with no run id at all falls through to that rule.
  run_id=$(strip_quotes "$(nm_field id)")
  [ -z "$run_id" ] || [ "$run_id" = "$bs_run" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  # local.head only proves the block was read from this worktree just now; it is
  # the submitted head that carries code identity, and the binding outlives the
  # run, so both are required.
  bs_head=$(nm_bs_commit local head) || return 1
  [ "$bs_head" = "$local_full" ] || return 1
  bs_submitted=$(nm_bs_commit pipeline submitted_head) || return 1
  [ "$bs_submitted" = "$local_full" ]
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  local run_head=$1 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    # The head-match rule stays as a fallback: it still binds runs branch_sync
    # does not cover (an older no-mistakes that omits the block).
    if nm_branch_sync_binds_worktree \
       || { [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; }; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        # Neither default arm may report a healthy run. An empty status names
        # no step at all, and a status word this reader does not recognize is a
        # future no-mistakes state whose meaning is unknown here - reading
        # either as `working` is what let an unknown run read as a healthy one.
        "")             RUN_STATE=unknown; RUN_DETAIL="run reported no status" ;;
        *)              RUN_STATE=unknown; RUN_DETAIL="unrecognized run status: $status" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # A non-terminal run that has stopped advancing is not a working one. This is
  # the LAST of the working-state overrides, which is what the budget needs to
  # stay honest in both directions. Every route by which a PR whose checks are
  # already green has been reported `done` - the ci step's own log marker above,
  # and the crew's own checks-green status log - has already emitted by here, so
  # a crew waiting out the captain on a merge is never called stalled no matter
  # how long that wait runs or whether the ci log tail could be read at all.
  # What does reach here is a run still claiming to validate with no checks-green
  # evidence from either source, and that claim is exactly what the elapsed
  # figure is allowed to contradict. Only the full `axi status` path can answer
  # it: the coarse runs list publishes no per-step activity.
  if [ "$RUN_STATE" = working ] && [ "$RUN_SOURCE" = full ]; then
    STALLED=$(nm_stalled_step)
    if [ -n "$STALLED" ]; then
      STALL_STEP=${STALLED%% *}
      STALL_REST=${STALLED#* }
      STALL_SECS=${STALL_REST%% *}
      STALL_BUDGET=${STALL_REST##* }
      RUN_STATE=stalled
      RUN_DETAIL="run stopped advancing: $STALL_STEP step quiet $(nm_secs_human "$STALL_SECS"), past its $(nm_secs_human "$STALL_BUDGET") budget"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
