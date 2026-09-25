#!/usr/bin/env bash
# Opt-in credentialed live regression for bin/fm-context-reset-reminder.sh
# against the installed Claude Code. The reminder's verdict comes from Claude's
# own transcript records (the Stop payload's transcript_path, main-thread
# assistant usage, and which user entries are prompts rather than tool results),
# so this proves that shape end to end: with a one-token threshold, a first turn
# that runs a tool reminds exactly once, and a resumed second turn stays silent.
# A few Haiku turns are submitted in an isolated primary-shaped folder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CONTEXT_RESET_LIVE_E2E claude jq

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-context-reset-live)
HOME_DIR="$LAB/home"
LOG="$LAB/reminders.log"
fm_git_identity fmtest fmtest@example.invalid

mkdir -p "$HOME_DIR/state" "$HOME_DIR/bin"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp "$ROOT/bin/fm-context-reset-reminder.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-hook-host-lib.sh" "$HOME_DIR/bin/"
cat > "$HOME_DIR/bin/stop-hook.sh" <<EOF
#!/usr/bin/env bash
FM_CONTEXT_RESET_TOKENS=1 '$HOME_DIR/bin/fm-context-reset-reminder.sh' | tee -a '$LOG'
EOF
chmod +x "$HOME_DIR/bin/stop-hook.sh" "$HOME_DIR/bin/fm-context-reset-reminder.sh"
: > "$LOG"
SETTINGS=$(jq -cn --arg cmd "$HOME_DIR/bin/stop-hook.sh" '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}')

# Claude Code refuses to nest inside another Claude session, so the inherited
# session markers are dropped from each run's environment.
run_claude() {
  local -a unset_args=()
  local name
  while IFS= read -r name; do
    unset_args+=(-u "$name")
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
  (cd "$HOME_DIR" && fm_test_timeout 300 env ${unset_args[@]+"${unset_args[@]}"} claude -p --model haiku \
    --dangerously-skip-permissions --output-format json --settings "$SETTINGS" "$@" </dev/null)
}

OUT=$(run_claude "Run the shell command 'echo hi' with the Bash tool, then reply with exactly DONE.") \
  || fail "$CLAUDE_VERSION: first turn failed: $OUT"
SESSION=$(printf '%s' "$OUT" | jq -r '.session_id // empty')
[ -n "$SESSION" ] || fail "$CLAUDE_VERSION: first turn reported no session id: $OUT"
FIRST=$(grep -c systemMessage "$LOG")
[ "$FIRST" -eq 1 ] || fail "$CLAUDE_VERSION: expected one reminder after the crossing turn, saw $FIRST: $(cat "$LOG")"
jq -e '.systemMessage | contains("/stow, then /clear")' "$LOG" >/dev/null \
  || fail "$CLAUDE_VERSION: reminder is not the reset systemMessage: $(cat "$LOG")"

OUT=$(run_claude --resume "$SESSION" "Reply with exactly AGAIN.") \
  || fail "$CLAUDE_VERSION: resumed turn failed: $OUT"
SECOND=$(grep -c systemMessage "$LOG")
[ "$SECOND" -eq 1 ] || fail "$CLAUDE_VERSION: a later turn past the threshold reminded again: $(cat "$LOG")"

pass "$CLAUDE_VERSION: the reset reminder fires once on the crossing turn and stays silent on the next"
