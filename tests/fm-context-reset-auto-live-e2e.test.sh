#!/usr/bin/env bash
# Opt-in credentialed live regression for the automatic session reset in
# bin/fm-context-reset-reminder.sh against the installed Claude Code on Herdr.
# Whether the main pane is idle, whether a typed /stow light reaches the skill,
# and whether a typed /clear really clears all come from the vendor's TUI, so a
# stub cannot prove them. A real Claude runs in an isolated Herdr lab, in a
# primary-shaped scratch home whose stow skill only records the reset-safe
# verdict, with a one-token threshold; its first prompt takes the home's
# session lock, as a main session does:
#   1. A turn that ends with unsent text in the composer is never typed into,
#      and the attempt stays armed.
#   2. The next idle turn end gets /stow light typed, the skill records the
#      session reset-safe, and the Stop ending that turn gets /clear typed,
#      which Claude performs (its SessionStart clear source fires).
# It fails naming the harness and version rather than degrading quietly.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
#
# Run explicitly with FM_CONTEXT_RESET_AUTO_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Claude automatic context reset" entry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fm_live_gate opt-in FM_CONTEXT_RESET_AUTO_LIVE herdr jq claude git

[ -x "$LAB_HELPER" ] || fail "FM_CONTEXT_RESET_AUTO_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name ctx-reset-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-context-reset-auto-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

fm_git_identity fmtest fmtest@example.invalid
mkdir -p "$HOME_DIR/state" "$HOME_DIR/.claude/skills/stow"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp -R "$ROOT/bin" "$HOME_DIR/bin"
date +%s > "$HOME_DIR/state/.stow-curated"
cat > "$HOME_DIR/.claude/skills/stow/SKILL.md" <<EOF
---
name: stow
description: Lab stand-in for the stow pass. Use when /stow or /stow light is invoked.
---

Run the shell command \`$HOME_DIR/bin/fm-context-reset-reminder.sh record reset-safe\` with the Bash tool, then reply with exactly STOWED.
EOF

WS_JSON=$(lab workspace create --cwd "$HOME_DIR" --label fm-ctxreset --no-focus) \
  || fail "could not create the isolated workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"

cat > "$HOME_DIR/stop-hook.sh" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN':"\$PATH" FM_SUPERVISOR_TARGET='$TARGET' FM_SUPERVISOR_BACKEND=herdr
export FM_CONTEXT_RESET_TOKENS=1 FM_CONTEXT_RESET_WAIT_SECS=20
exec '$HOME_DIR/bin/fm-context-reset-reminder.sh'
EOF
chmod +x "$HOME_DIR/stop-hook.sh"
SETTINGS=$(jq -cn --arg stop "$HOME_DIR/stop-hook.sh" --arg cleared "touch '$HOME_DIR/cleared'" '{
  feedbackDrafts: "off",
  hooks: {
    Stop: [{hooks: [{type: "command", command: $stop}]}],
    SessionStart: [{matcher: "clear", hooks: [{type: "command", command: $cleared}]}]
  }
}')
printf '%s' "$SETTINGS" > "$HOME_DIR/lab-settings.json"

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 DISABLE_AUTOUPDATER=1 claude --model haiku --dangerously-skip-permissions --settings '$HOME_DIR/lab-settings.json'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"
trusted=0
ready=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*) ready=1; break ;;
    *'Yes, I trust this folder'*)
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered its composer"
sleep 3

record_field() { sed -n "s/^$1=//p" "$HOME_DIR/state/.context-reset" 2>/dev/null; }
wait_for() {  # <seconds> <command...>
  local limit=$1 n=0
  shift
  while [ "$n" -lt "$limit" ]; do
    "$@" && return 0
    n=$((n + 1))
    sleep 1
  done
  return 1
}
phase_is() { [ "$(record_field phase)" = "$1" ]; }
transcript_has() { grep -qF "$1" "$(record_field transcript)" 2>/dev/null; }

verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Run the shell command '$HOME_DIR/bin/fm-lock.sh && sleep 12' with the Bash tool, then reply with exactly SLEPT." 3 0.4 0.4)
[ "$verdict" = empty ] || fail "Claude Code ($VERSION) on $HERDR_VER: the first prompt did not submit ($verdict)"
wait_for 30 test -s "$HOME_DIR/state/.lock" || fail "Claude Code ($VERSION) on $HERDR_VER: the session never took the session lock the automatic reset requires"
sleep 4
lab pane send-text "$PANE" "an unsent draft" >/dev/null || fail "could not type the unsent draft"
wait_for 60 phase_is typing || fail "Claude Code ($VERSION) on $HERDR_VER: the turn end past the threshold launched no typist (phase '$(record_field phase)')"
wait_for 40 phase_is armed \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a composer holding an unsent draft did not keep the attempt armed (phase '$(record_field phase)')"
[ ! -e "$HOME_DIR/state/.context-reset-safe" ] || fail "Claude Code ($VERSION) on $HERDR_VER: the stow ran over an unsent draft"
case "$(record_field note)" in *'not idle'*) ;; *) fail "the timed-out attempt recorded no idle note: $(record_field note)" ;; esac
pass "$VERSION on $HERDR_VER: a turn ending with an unsent draft in the composer is never typed into"

fm_backend_herdr_composer_clear "$TARGET" "an unsent draft" || fail "could not clear the unsent draft"
sleep 2
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly AGAIN." 3 0.4 0.4)
[ "$verdict" = empty ] || fail "Claude Code ($VERSION) on $HERDR_VER: the second prompt did not submit ($verdict)"
wait_for 120 test -e "$HOME_DIR/state/.context-reset-safe" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the idle turn end never got a stow that recorded the session reset-safe (phase '$(record_field phase)', note '$(record_field note)')"
transcript_has '/stow' || fail "the reset-safe record did not come from the typed /stow"
wait_for 90 test -e "$HOME_DIR/cleared" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the reset-safe stow was never followed by a /clear Claude performed (phase '$(record_field phase)', note '$(record_field note)')"
pass "$VERSION on $HERDR_VER: an idle turn end past the threshold gets /stow light typed, and its reset-safe verdict gets /clear typed and performed"
