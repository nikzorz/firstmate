#!/usr/bin/env bash
# Drives the real firstmate startup scripts against a throwaway FM_HOME that holds
# both always-loaded notes and per-project split notes, to show the AGENTS.md
# claim ("not printed at session start") matches the product.
set -u
REPO=${1:?worktree path}
W=$(mktemp -d /tmp/fm-note-split.XXXXXX)
root="$W/root"; home="$W/home"; fakebin="$W/fakebin"
mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
git init -q -b main "$root"
cp "$REPO/AGENTS.md" "$root/AGENTS.md"
git -C "$root" -c user.name=t -c user.email=t@x add AGENTS.md
git -C "$root" -c user.name=t -c user.email=t@x commit -q -m init
for t in tmux node chrome-devtools-axi gh gh-axi treehouse no-mistakes lavish-axi tasks-axi herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"
done
printf '# learnings\nMARKER-BASE-LEARNINGS always-loaded fact\n' > "$home/data/learnings.md"
printf '# captain\nMARKER-BASE-CAPTAIN always-loaded preference\n' > "$home/data/captain.md"
printf '# learnings for oracle\nMARKER-PROJECT-LEARNINGS oracle-only fact\n' > "$home/data/learnings-oracle.md"
printf '# captain for oracle\nMARKER-PROJECT-CAPTAIN oracle-only preference\n' > "$home/data/captain-oracle.md"
echo "== throwaway home: $home"; ls -1 "$home/data"
echo
echo "== 1. fm-session-start.sh digest (real script, throwaway home)"
out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
  timeout 120 "$REPO/bin/fm-session-start.sh" 2>&1); rc=$?
echo "exit=$rc"
echo "--- CONTEXT section of the digest:"
printf '%s\n' "$out" | sed -n '/^=* *CONTEXT/,/NEXT STEP/p' | head -60
echo "--- marker presence anywhere in digest:"
for m in MARKER-BASE-LEARNINGS MARKER-BASE-CAPTAIN MARKER-PROJECT-LEARNINGS MARKER-PROJECT-CAPTAIN; do
  if printf '%s\n' "$out" | grep -q "$m"; then echo "$m: PRINTED"; else echo "$m: not printed"; fi
done
printf '%s\n' "$out" | grep -c 'learnings-oracle\|captain-oracle' | sed 's/^/per-project filename mentions in digest: /'
echo
echo "== 2. fm-context-cost.sh (session cost accounting)"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$REPO" PATH="$fakebin:/usr/bin:/bin" "$REPO/bin/fm-context-cost.sh" 2>&1 \
  | sed -n '/[Cc]urated\|captain\|learnings\|Conditional/p'
echo
echo "== 3. fm-startup-memory-budget.sh report"
printf '12000\n' > "$home/config/startup-memory-budget"
env FM_HOME="$home" "$REPO/bin/fm-startup-memory-budget.sh" report 2>&1
echo
echo "== 4. AGENTS.md as delivered (CLAUDE.md imports @AGENTS.md): section 2 layout + section 6 routing"
grep -n 'captain-<project>.md\|learnings-<project>.md\|^## ' "$REPO/AGENTS.md" | sed -n '1,40p'
rm -rf "$W"
