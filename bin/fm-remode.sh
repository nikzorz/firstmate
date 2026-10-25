#!/usr/bin/env bash
# Switch a running direct-PR ship task to no-mistakes in place: the worker keeps
# its window, worktree, branch, and context; only the delivery contract changes.
# A plain-text steer to run /no-mistakes is not a mode switch, because every
# done gate (bin/fm-dod-lib.sh) reads the mode from state/<task-id>.meta when it
# decides, and only a no-mistakes record lets a pipeline-pushed PR head count as
# the named head.
# The switch rewrites mode= in that record and drops any pr_head= recorded under
# direct-PR, which names the worker's own push rather than the head the pipeline
# will push; bin/fm-pr-check.sh records the forge's head again at the ready report.
# It renders the no-mistakes first ship rule, ask-user escalation, and Definition
# of done from bin/fm-dod-lib.sh, the owner a briefed or promoted worker also gets,
# writes them to data/<task-id>/remode-instructions.md, appends the same
# superseding contract to data/<task-id>/brief.md so a relaunch keeps it, and
# prints the fm-send.sh command that delivers it to the current worker.
# The task's branch, base branch, forge, and upstream consent carry over from its
# record and brief unchanged. Switching to or from local-only and switching a
# scout are not this script's job: bin/fm-promote.sh decides a scout's mode.
# Usage: fm-remode.sh <task-id> --mode no-mistakes
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

MODE=
POS=()
want_mode=0
for a in "$@"; do
  if [ "$want_mode" = 1 ]; then
    MODE=$a
    want_mode=0
    continue
  fi
  case "$a" in
    --mode) want_mode=1 ;;
    --mode=*) MODE=${a#--mode=} ;;
    *) POS+=("$a") ;;
  esac
done
[ "$want_mode" = 0 ] || { echo "error: --mode requires a value" >&2; exit 1; }
[ "${#POS[@]}" -eq 1 ] || { echo "usage: fm-remode.sh <task-id> --mode no-mistakes" >&2; exit 1; }
[ "$MODE" = no-mistakes ] || {
  echo "error: fm-remode.sh switches a direct-PR ship to --mode no-mistakes only (got '${MODE:-none}'); a scout's mode is decided by bin/fm-promote.sh" >&2
  exit 1
}

ID=${POS[0]}
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
BRIEF=
BRIEF_REPLACEMENT=
BRIEF_ORIGINAL=
remode_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$BRIEF_REPLACEMENT" ] || rm -f -- "$BRIEF_REPLACEMENT" 2>/dev/null || true
  if [ -n "$BRIEF_ORIGINAL" ] && [ -e "$BRIEF_ORIGINAL" ]; then
    mv -f -- "$BRIEF_ORIGINAL" "$BRIEF" 2>/dev/null || true
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap remode_cleanup EXIT
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
KIND=$(fm_dod_meta_value "$META" kind)
OLD_MODE=$(fm_dod_meta_value "$META" mode)
[ "$KIND" = ship ] || { echo "error: task $ID is kind=${KIND:-none}, not a ship task; promote a scout with bin/fm-promote.sh" >&2; exit 1; }
[ "$OLD_MODE" = direct-PR ] || {
  echo "error: task $ID is mode=${OLD_MODE:-none}; only a direct-PR ship switches to no-mistakes here, and nothing was changed" >&2
  exit 1
}

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] && [ -r "$BRIEF" ] || { echo "error: brief not found: $BRIEF" >&2; exit 1; }
BRANCH=$(fm_dod_meta_value "$META" branch)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
BASE_BRANCH=$(fm_dod_meta_value "$META" base_branch)
CONSENT=$(fm_dod_meta_value "$META" upstream_consent)
# The forge is the brief's own choice, already checked against the registry at
# spawn; the last contract line is the current one after any earlier switch.
FORGE=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]forge=\([^ ]*\).*$/\1/p' "$BRIEF" | tail -n 1)
[ -n "$FORGE" ] || FORGE=none
fm_forge_valid_for_mode "$FORGE" "$MODE" fm-remode.sh || exit 1
fm_base_branch_valid "$BASE_BRANCH" "$MODE" "$FORGE" "fm-remode.sh $ID" || exit 1

if fm_brief_task_heading_present "$BRIEF" "## Captain's intent"; then
  INTENT_BODY=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
else
  INTENT_BODY=$(fm_brief_marked_captain_words "$(fm_brief_heading_body "$BRIEF" "# Task")")
fi
if [ -z "$(printf '%s' "$INTENT_BODY" | tr -d '[:space:]')" ]; then
  echo "error: $BRIEF has no provenance-marked Captain's intent, which a no-mistakes run needs as --intent; add the captain's actual words before switching" >&2
  exit 1
fi

remode_delivery_contract() {
  local forge_words='' consent_words=''
  [ "$FORGE" = none ] || forge_words=" forge=$FORGE"
  [ -z "$CONSENT" ] || consent_words=" upstream-consent=$CONSENT"
  cat <<EOF
# Current delivery mode contract
This task is now kind=ship with mode=$MODE$forge_words$consent_words.
This section supersedes every earlier brief instruction about delivery mode, including the direct-PR rule 1 and Definition of done.
Keep your \`$BRANCH\` branch and the commits on it; the no-mistakes run validates and pushes that branch from here on.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
EOF
  fm_ship_rule_one "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH"
  printf '\nThe no-mistakes ask-user escalation below adds to rule 6.\n'
  fm_ask_user_escalation_block "$DATA" "$ID" "$STATE"
  printf '\n'
  fm_dod_block "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH" "$CONSENT"
}

INSTRUCTIONS="$DATA/$ID/remode-instructions.md"
[ ! -d "$INSTRUCTIONS" ] || { echo "error: instructions path is a directory: $INSTRUCTIONS" >&2; exit 1; }
TMP="$DATA/$ID/.remode-instructions.md.${BASHPID:-$$}"
{
  printf 'Your task has switched from mode=direct-PR to mode=%s. Your window, worktree, branch, and context stay as they are; only the contract below changes.\n\n' "$MODE"
  remode_delivery_contract
  fm_brief_intent_overlay "$INTENT_BODY"
} > "$TMP" || { echo "error: could not render the no-mistakes contract for $ID" >&2; exit 1; }
mv "$TMP" "$INSTRUCTIONS"
TMP=

# bin/fm-spawn.sh adds the intent overlay itself on a no-mistakes relaunch, so
# the brief carries only the delivery contract.
BRIEF_REPLACEMENT="$DATA/$ID/.brief.md.remode.${BASHPID:-$$}"
{
  cat "$BRIEF"
  printf '\n\n'
  remode_delivery_contract
} > "$BRIEF_REPLACEMENT" || { echo "error: could not render the switched brief for $ID" >&2; exit 1; }

TMP="$STATE/.$ID.meta.remode.${BASHPID:-$$}"
grep -v -e '^mode=' -e '^pr_head=' "$META" > "$TMP" || true
echo "mode=$MODE" >> "$TMP"
# The brief is published before the record so a relaunch never pairs a
# no-mistakes record with a brief whose only contract is direct-PR; a refused
# record restores the original brief on exit.
BRIEF_ORIGINAL="$DATA/$ID/.brief.md.direct-pr.${BASHPID:-$$}"
cp -p -- "$BRIEF" "$BRIEF_ORIGINAL" || { echo "error: could not stage the brief for the switch: $BRIEF" >&2; exit 1; }
mv "$BRIEF_REPLACEMENT" "$BRIEF" || { echo "error: could not publish the switched brief: $BRIEF" >&2; exit 1; }
BRIEF_REPLACEMENT=
if ! fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR); nothing was changed" >&2
  exit 1
fi
TMP=
rm -f -- "$BRIEF_ORIGINAL" 2>/dev/null || true
BRIEF_ORIGINAL=

HOME_Q=$(printf '%q' "$FM_HOME")
INSTRUCTIONS_Q=$(printf '%q' "$INSTRUCTIONS")
echo "switched $ID from mode=direct-PR to mode=$MODE"
echo "wrote the no-mistakes contract: $INSTRUCTIONS"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID \"\$(cat $INSTRUCTIONS_Q)\""
