# Populates a no-mistakes state DB created by the real no-mistakes binary
# (fresh NM_HOME) with the PR 1704 gate shape and a second run reusing ids.
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1]); proj = sys.argv[2]
db.execute("INSERT INTO repos (id, working_path, upstream_url, created_at) VALUES ('r1', ?, 'u', 0)", (proj,))
def run(rid, created):
    db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, created_at, updated_at) VALUES (?, 'r1', 'fm/task-x1', 'h', 'b', ?, ?)", (rid, created, created))
def step(sid, rid, name, order, approval=None):
    db.execute("INSERT INTO step_results (id, run_id, step_name, step_order, approval_reason) VALUES (?,?,?,?,?)", (sid, rid, name, order, approval))
def rnd(sid, n, source, findings, selected=()):
    db.execute("INSERT INTO step_rounds (id, step_result_id, round, trigger_type, findings_json, selected_finding_ids, selection_source, duration_ms, created_at) VALUES (?,?,?,'initial',?,?,?,0,0)",
      ("%sr%d" % (sid, n), sid, n, json.dumps({"findings": [{"id": i, "action": a, "severity": "warning", "description": "d"} for i, a in findings]}), json.dumps(list(selected)), source))
run("RUN1704", 1)
step("s1", "RUN1704", "review", 3)
rnd("s1", 1, "user", [("release-claim-narrowed", "ask-user"), ("verdict-assert-dropped", "ask-user"), ("second-story-loop", "ask-user")], ["verdict-assert-dropped", "second-story-loop"])
rnd("s1", 2, "user_declined", [("boot-teardown-copied", "auto-fix"), ("release-scan-misses-fight-dirs", "ask-user"), ("note", "no-op")])
step("s2", "RUN1704", "test", 4, "Test-only change with no live product surface.")
rnd("s2", 1, "user_declined", [("test-1", "ask-user")])
run("RUN2", 2)
step("s3", "RUN2", "review", 3)
rnd("s3", 1, "user_declined", [("review-1", "ask-user")])
step("s4", "RUN2", "test", 4, "")
rnd("s4", 1, "user_declined", [("test-1", "ask-user")])
db.commit()
