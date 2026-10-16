#!/usr/bin/env bash
# One-off live probe: drives the worktree's real bin/fm-pr-merge.sh in a
# disposable lab home against a disposable no-mistakes state database built
# from no-mistakes' real schema (real-nm-schema.sql), with only the GitLab
# forge (glab) stubbed. Usage: probe.sh <scenario-name> <shape.json> [status-line...]
set -u
WT=/home/nik/.no-mistakes/worktrees/50866b63a668/01M524PNXVATFM6T2B206PFGAM
EV=/home/nik/.no-mistakes/evidence/01M524PNXVATFM6T2B206PFGAM
name=$1 shape=$2; shift 2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
mkdir -p "$LAB/project" "$LAB/nm" "$LAB/fakebin" "$LAB/user-home"
git init -q "$LAB/wt" && git -C "$LAB/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
cat > "$LAB/state/task-x1.meta" <<EOF
window=fm-task-x1
worktree=$LAB/wt
project=$LAB/project
kind=ship
mode=no-mistakes
branch=fm/task-x1
EOF
: > "$LAB/state/task-x1.status"
for line in "$@"; do printf '%s\n' "$line" >> "$LAB/state/task-x1.status"; done
python3 -I - "$LAB/nm/state.sqlite" "$LAB/project" "$EV/real-nm-schema.sql" "$shape" <<'PY' || exit 9
import json, os, sqlite3, sys
db_path, project, schema, shape = sys.argv[1:]
shape = json.loads(open(shape).read())
logs = os.path.join(os.path.dirname(db_path), "logs"); os.makedirs(logs)
db = sqlite3.connect(db_path); db.executescript(open(schema).read())
db.execute("INSERT INTO repos (id, working_path, upstream_url, created_at) VALUES ('r1', ?, 'x', 1)", (project,))
db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, created_at, updated_at)"
           " VALUES (?, 'r1', 'fm/task-x1', 'h', 'b', 1, 1)", (shape["run"],))
for s, step in enumerate(shape["steps"]):
    log_path = os.path.join(logs, "%s.log" % step["name"])
    with open(log_path, "w") as log:
        for rnd in step["rounds"]:
            if step["name"] == "review":
                log.write("reviewing changes...\nreview agent finished\n")
                if rnd.get("coverage"):
                    log.write("review coverage is incomplete; parking for approval with 1 reviewable"
                              " file(s) unverified: bin/x.sh\n")
    db.execute("INSERT INTO step_results (id, run_id, step_name, step_order, status, log_path,"
               " approval_reason, skip_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               ("s%d" % s, shape["run"], step["name"], step["order"], step.get("status", "completed"),
                log_path, step.get("approval"), step.get("skip")))
    for r, rnd in enumerate(step["rounds"]):
        found = json.dumps({"verdict": rnd.get("verdict"), "findings": [
            {"id": i, "action": a, "severity": "warning", "description": d} for i, a, d in rnd.get("findings", [])]})
        db.execute("INSERT INTO step_rounds (id, step_result_id, round, trigger_type, findings_json,"
                   " selected_finding_ids, selection_source, duration_ms, created_at)"
                   " VALUES (?, ?, ?, 'initial', ?, ?, ?, 0, 0)",
                   ("s%dr%d" % (s, r), "s%d" % s, rnd["round"], found,
                    json.dumps(rnd.get("selected", [])), rnd.get("source")))
db.commit()
PY
printf '{"iid":7,"state":"opened","detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","head_pipeline":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"success"},"merge_when_pipeline_succeeds":false,"merge_after":null}\n' > "$LAB/mr.json"
sed 's/"opened"/"merged"/' "$LAB/mr.json" > "$LAB/mr-post.json"
cat > "$LAB/fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/glab.log"
case "\${1:-} \${2:-}" in
  "mr view") if [ -e "$LAB/merged" ]; then cat "$LAB/mr-post.json"; else cat "$LAB/mr.json"; fi ;;
  "mr merge") : > "$LAB/merged" ;;
esac
SH
chmod +x "$LAB/fakebin/glab"; : > "$LAB/glab.log"
out="$EV/live-$name.txt"
{
  echo "\$ fm-pr-merge.sh task-x1 https://gitlab.example/group/project/-/merge_requests/7   # scenario: $name"
  echo "-- status log:"; cat "$LAB/state/task-x1.status"
  echo "-- fm-pr-merge stderr/stdout:"
  ( cd "$WT" && env -u NO_MISTAKES_GATE FM_HOME="$LAB" NM_HOME="$LAB/nm" HOME="$LAB/user-home" \
      PATH="$LAB/fakebin:$PATH" bin/fm-pr-merge.sh task-x1 https://gitlab.example/group/project/-/merge_requests/7 2>&1 )
  echo "-- exit code: $?"
  echo "-- forge merge invoked: $(grep -c '^mr merge' "$LAB/glab.log")"
} > "$out" 2>&1
cat "$out"
rm -rf "$LAB"
