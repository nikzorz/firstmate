#!/usr/bin/env bash
# Drives the real Claude Code permission layer against the allow-rule snippet
# shipped in docs/configuration.md "Primary session allow rules".
# Usage: drive-allow-rules.sh <worktree> <with-rules|no-rules|no-fmhome-rules>
set -u
wt=$1; variant=$2
home=$(mktemp -d /tmp/fmperm-XXXXXX)
mkdir -p "$home/bin" "$home/.claude" "$home/out"
for s in fm-send fm-peek fm-crew-state fm-control; do
  printf '#!/usr/bin/env bash\necho ran >> "%s/out/%s.$(basename "${FM_HOME:-none}")-$1"\necho OK-%s\n' "$home" "$s" "$s" > "$home/bin/$s.sh"
  chmod +x "$home/bin/$s.sh"
done
# Extract the JSON snippet from the doc section as the captain would copy it.
python3 - "$wt/docs/configuration.md" "$home" "$variant" > "$home/.claude/settings.local.json" <<'PY'
import sys, json, re
doc, home, variant = sys.argv[1:]
text = open(doc).read()
sec = text.split("## Primary session allow rules", 1)[1]
block = re.search(r"```json\n(.*?)```", sec, re.S).group(1)
cfg = json.loads(block.replace("/abs/firstmate", home))
if variant == "no-rules":
    cfg["permissions"]["allow"] = []
elif variant == "no-fmhome-rules":
    cfg["permissions"]["allow"] = [r for r in cfg["permissions"]["allow"] if not r.startswith("Bash(FM_HOME=")]
print(json.dumps(cfg, indent=2))
PY
echo "== home: $home  variant: $variant"
echo "== settings.local.json:"; cat "$home/.claude/settings.local.json"
cmds=(
  "bin/fm-send.sh rel"
  "$home/bin/fm-send.sh abs"
  "FM_HOME=$home bin/fm-send.sh envrel"
  "FM_HOME=$home $home/bin/fm-send.sh envabs"
  "bin/fm-peek.sh rel"
  "bin/fm-crew-state.sh rel"
  "FM_HOME=$home $home/bin/fm-control.sh envabs"
)
prompt="Run each of these shell commands with the Bash tool, one Bash call per command, exactly as written, in order, even if one is denied. Do not modify them. Afterwards reply with DONE."
for c in "${cmds[@]}"; do prompt+=$'\n'"$c"; done
cd "$home"
claude -p --model haiku --permission-mode dontAsk --setting-sources local \
  --output-format stream-json --verbose "$prompt" > "$home/transcript.jsonl" 2>&1
echo "== tool results (from transcript):"
python3 - "$home/transcript.jsonl" <<'PY'
import sys, json
for line in open(sys.argv[1]):
    try: m = json.loads(line)
    except Exception: continue
    msg = m.get("message") or {}
    for c in msg.get("content") or []:
        if isinstance(c, dict) and c.get("type") == "tool_use":
            print("CALL :", c["input"].get("command"))
        if isinstance(c, dict) and c.get("type") == "tool_result":
            body = c.get("content")
            if isinstance(body, list): body = " ".join(x.get("text","") if isinstance(x, dict) else str(x) for x in body)
            print("RESULT:", ("ERROR " if c.get("is_error") else "") + str(body).strip()[:160])
PY
echo "== scripts that actually executed (marker files):"
ls "$home/out" || true
