#!/usr/bin/env bash
# Live guard for the extra-usage footer signature in bin/fm-claude-limit-lib.sh
# (live-harness-optin family). Per .agents/skills/firstmate-coding-guidelines
# "Harness-dependent checks", a classifier built on vendor-rendered text must be
# proven against the REAL installed harness, and that proof has two halves here:
#
#   1. the installed claude binary still carries the notice wording the
#      signature anchors on, so a release that renames it fails naming the
#      version instead of the detector going quietly blind;
#   2. a real idle claude pane, captured with the production shape
#      (`tmux capture-pane -p -S -40`), reads as no notice while extra usage is
#      off, and the same real capture with a notice placed in its own footer row
#      reads as one, so the composer-and-footer structure the signature needs is
#      the one the installed release actually draws.
#
# The notice itself cannot be produced on demand without paid credits, which is
# why half 2 places it into a real footer rather than waiting for one. No prompt
# is submitted and no dialog is answered, so no model tokens are spent. claude is
# launched with the repo root as cwd, which the operator's machine has normally
# already trusted; a trust dialog fails the guard as an unreadable composer.
#
# Run explicitly with FM_EXTRA_USAGE_LIVE=1. Refresh
# docs/verification/runtime-backends.md ("Claude extra-usage footer") from this
# guard's output after any claude upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_EXTRA_USAGE_LIVE claude tmux

SOCKET="fm-extra-usage-live-$$"
SESSION=eulive
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-extra-usage-live.XXXXXX")

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf -- "$SHIM_DIR"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-limit-lib.sh"

VERSION=$(claude --version 2>/dev/null | head -1)
BINARY=$(command -v claude)
BINARY=$(readlink -f "$BINARY" 2>/dev/null || printf '%s' "$BINARY")

# --- 1. the wording the signature anchors on --------------------------------
found=
for s in "Now using usage credits" "You're now using usage credits" "Now using extra usage" \
    "You're now using extra usage" "Extra usage is now covering your requests"; do
  LC_ALL=C grep -qaF -- "$s" "$BINARY" && found="$found|$s"
done
[ -n "$found" ] || fail "claude ${VERSION:-version-unknown}: no extra-usage notice wording the signature knows is in $BINARY"
# The credit-limit warning is assembled from a template, so its two fragments
# are what the binary carries.
for s in "You're close to your " "usage credit limit"; do
  LC_ALL=C grep -qaF -- "$s" "$BINARY" \
    || fail "claude ${VERSION:-version-unknown}: credit-limit warning fragment '$s' is gone from $BINARY"
done
pass "claude ${VERSION:-version-unknown}: binary carries notice wording${found}"

# --- 2. the real composer and footer ----------------------------------------
tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$ROOT" -- claude \
  || fail "claude ${VERSION:-version-unknown}: could not launch in the isolated tmux server"
i=0
verdict=
while [ "$i" -lt "${FM_EXTRA_USAGE_LIVE_POLLS:-45}" ]; do
  verdict=$(fm_tmux_composer_state "$SESSION")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  sleep 1
done
pane=$(tmux capture-pane -p -t "$SESSION" -S -40)
if [ "$verdict" != empty ]; then
  printf '%s\n' "$pane" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "claude ${VERSION:-version-unknown}: idle composer never classified empty (last verdict: ${verdict:-unreadable})"
fi
if live=$(printf '%s' "$pane" | fm_claude_extra_usage_read); then
  printf '# claude %s: the notice is showing live (%s); extra usage is on for this account\n' "$VERSION" "$live"
else
  pass "claude ${VERSION:-version-unknown}: a real idle pane with extra usage off reads as no notice"
fi
spliced=$(printf '%s\n' "$pane" | awk '
  { row[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
  END { for (i = 1; i <= NR; i++) print (i == last ? row[i] "      Now using usage credits" : row[i]) }')
got=$(printf '%s' "$spliced" | fm_claude_extra_usage_read) \
  || fail "claude ${VERSION:-version-unknown}: a notice in the real footer row did not match; the composer or footer shape changed"
[ "${got%%$'\t'*}" = using ] || fail "claude ${VERSION:-version-unknown}: unexpected verdict on the real footer: $got"
pass "claude ${VERSION:-version-unknown}: a notice in the real footer row matches"
