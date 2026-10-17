---
name: validation-supervision
description: Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change, finding, or red CI step, and before deciding or answering any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

For a no-mistakes ship, the worker starts validation itself right after its implementation commit; steer it to run /no-mistakes, using the harness invocation owned by `harness-adapters`, only when it sits idle after committing with no run started.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

A validation run fixes each theme once.
A theme is one root cause in one piece of code, such as the input cases of one heuristic, however many lines or files its findings name.
When a run returns a finding on a theme already fixed in an earlier round of that run, stop fixing that theme: file the theme as one follow-up issue naming every round's finding on it, have the worker record it as a stated limitation in the PR body, and answer the gate leaving those findings unfixed so the run continues.
A finding on that theme that blocks the change, as `ask-user-authority` defines blocking, escalates to the captain under that skill's step 6 instead of another fix round.
While the captain is away, the filing waits for the return as `ask-user-authority` step 4 says.
Apply the cutoff at every gate firstmate answers.
The worker stops at a same-theme repeat or a non-blocking finding in rounds it drives itself and escalates it as `needs-decision` under the contract `bin/fm-dod-lib.sh` owns, so firstmate applies this cutoff there too.
The postmortem traces such a run as a miss of its own.

Judge validation by the resolved state line from [`bin/fm-crew-state.sh`](../../../bin/fm-crew-state.sh), whose header owns outcome mappings and CI-monitor/daemon exceptions, never by shell liveness, the last status event, or a raw run record.
A `stalled` run has stopped advancing and needs attention rather than waiting out, and an empty or unrecognised run status reads `unknown`, which is never evidence of a healthy run.
Workers parked at approval or fix-review must follow the active gate help.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

A red CI step is ruled by the test that failed, not by the job that ran it.
When that test is known flaky on main, meaning the same test failed on a main-branch run whose change was unrelated to it, and this pull request changes neither that test nor the code it exercises, steer the worker to rerun only the failed jobs once with no code change, and neither escalate nor ask the captain.
A second failure of that test on the same head, or a failure that matches no known main flake, gets an ordinary ruling.
Every flake gets a backlog ticket naming the test and the failing run, whether it was rerun or ruled, unless an open ticket already covers that test.
