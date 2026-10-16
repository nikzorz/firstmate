---
name: postmortem
description: Load when a ship PR has merged, before its cleanup, to postmortem every miss that PR had, and when asked to rehearse that postmortem as a dry run. A miss is a no-mistakes finding that held or was refuted, a red CI job the change caused, a firstmate ruling that rejected a worker's approach, or a captain correction of firstmate or a worker. Finds each miss's root cause in the setup that let it through and ships one heal where every future agent and reviewer meets it.
user-invocable: false
metadata:
  internal: true
---

# Postmortem

A **miss** is one observed mistake with its evidence: a finding and its verdict, a red job, a correction.
Each miss means some agent's setup (what it read, what steered it, what checked it) let a mistake through.
The postmortem finds where, and the **heal** fixes that setup so the mistake stops recurring.
Fixing the instance is separate work, already done or ruled on by the time the PR merges.

Keep it **blameless**: name the gap in the setup ("the rule never loaded for this path"), never a person or an agent's failing.
A heal that only says "be more careful" heals nothing.

## When and who

One postmortem runs per ship PR at merge, before cleanup, and covers every miss that PR had; each miss still gets its own side, cause, heal and log entry.

In a **dry run** (named by the request), stop after step 4: write the report, file nothing, and add no log entry.

Firstmate runs step 0 itself, in the landing turn.
A PR with no misses gets its one log entry and the postmortem stops there.
Firstmate finishes the rest itself when every miss traces from records already on disk: the status log, findings snapshots, brief, and the rule files the trace names.
When a trace needs session transcripts for more than one miss, or code reading beyond the lines a finding cites, dispatch a scout with this skill in dry-run form and its report as the deliverable, then run step 5 from that report; filing, captain questions and the log stay with firstmate.
Cleanup deletes the task's steering inbox and local copy, so before cleanup collect the miss list, the verbatim text of every steer and ruling, and any trace that needs the local copy; a scout's brief carries that steer and ruling text, because the scout cannot read the inbox after cleanup.

## 0. Collect the misses

Read every source, because each one holds misses the others miss:

- The task's status log, `state/<id>.status`, or `data/<id>/status.log` after cleanup: every keyed `needs-decision` and the `resolved` answer that ruled it.
- The findings snapshots the worker wrote at each escalated gate, `data/<id>/nm-<run>-*findings.txt`, verbatim.
- The PR body's pipeline section (`gh-axi pr view <PR url>`): each step's findings and fix rounds for the final run.
- Earlier runs, whose auto-fixed findings appear nowhere else: `no-mistakes runs`, then `no-mistakes axi status --run <id>` and `no-mistakes axi logs --run <id> --step <step>`, run read-only from the project's clone.
- Red CI jobs on the PR and the job logs that name the failing test.
- Firstmate's steers and rulings: the `resolved` lines and the handled messages in the task's steering inbox.
- Captain words added to the brief's `## Captain's intent` after dispatch, and captain answers recorded through `captain-hold-lifecycle`.

Classify each item:

- **Miss:** a finding that held (fixed, filed as a follow-up, or accepted as a known limitation because it is true), a finding that was refuted (ruled wrong, or a fix round that changed nothing because the claim did not hold), a red job the change caused, a firstmate ruling that rejected the worker's or a fix round's approach, or a captain correction.
- **Pipeline event, not a miss:** an item that makes no claim about the change, such as an agent's budget cut, a lost runner, a red job the change did not cause, the pipeline asking to confirm a change has no live surface, or a refusal over work an interrupted agent left.
  List each as a side finding.

A validation run that hit the same-theme cutoff in `validation-supervision`, or ran three or more fix rounds, is also one miss of its own, besides the misses its findings already are: the loop itself, traced like any other.

Done when every item has a class and each miss has an id: the finding id, `ci-<job>`, `ruling-<n>`, `captain-<n>`, or `loop-<run>`.

## 1. Side

Decide whose setup missed:

- **Author:** the finding held, the job failed because of the change, firstmate rejected the worker's or a fix round's approach, or the captain corrected the work.
  The author's setup is the ship worker's: its brief (`data/<id>/brief.md` and the home's shared bullet files it was filled from), the project's always-on and path-scoped rules, and the skills it loaded.
  Firstmate is the author when its brief, steer or ruling let the miss through, and when the captain corrected firstmate itself.
- **Reviewer:** the finding was refuted.
  The reviewer's setup is the no-mistakes pipeline's agents and the project's review instructions: the `review` block of the project's `.no-mistakes.yaml` on the default branch and every file it tells the reviewer to read (for arena, `docs/agents/review-standards.md`).
- **Rules:** the verdict split, or the finding became the owner's call because no convention decided it.

Done when the miss has a side and the verdict evidence behind it.

## 2. Trace

Reconstruct what the missing side had in front of it.
The cause is inferred from the trace, not guessed.

- **Author.**
  Find the commit that introduced the line: `git -C <task local copy> log --all -S '<text>' -- <path>` while the task's copy exists, otherwise the PR's commits through `gh-axi`, and the commit time with `git show -s --format=%aI <sha>`, the author date, because a rebase rewrites the committer date and the pipeline rebases.
  Then find the session that made it with `sessions.py` beside this file, run from the firstmate code root:

  ```
  python3 -I .agents/skills/postmortem/sessions.py find '<file name or unique text>' --at <commit time>
  python3 -I .agents/skills/postmortem/sessions.py show <transcript from find> --before <commit time>
  ```

  `find` lists the sessions near the commit time, oldest first.
  Pick the `WROTE` row marked `AT`, whose window contains the commit time; a later `WROTE` row is usually the session that fixed it.
  A `WROTE` row is a lead, not proof: confirm it with `show` and the commit's diff before the trace rests on it.
  A shell command's `WROTE` mark comes from a heuristic classifier with known gaps, so it can miss a write or flag a read.
  A row labelled `pipeline <run> <phase>` is a no-mistakes agent, so a line a fix round wrote traces to the pipeline, not the worker.
  `show` prints what that session loaded at start, the path-scoped rules it loaded on demand, the skills it invoked, the files it read and edited, and the commands it ran, marking the ones that write.
  Compare that against the rule that would have prevented the miss: was it loaded, read, or never reached?
  Did the brief name the gate or check that would have caught it?
  When firstmate is the author, read the brief, its bullet files, and the steer or ruling itself; firstmate's own session is also in reach of `find`.
  A worker on a harness without these transcripts, or a person, traces from the brief and the project's always-on files, and the report says the trace is partial.
- **Reviewer.**
  Read what the reviewer received: the project's review block and the files it points at, the run's intent (`data/<id>/intent.txt` when the worker kept it, otherwise the brief's `## Captain's intent`), and the diff at that run's head.
  The reviewing agent's session is a `pipeline <run> review` row from `find`, run with the finding's own text as the needle, and `show` lists what it read.
  Its finding usually names what it relied on: quote that.
- **Rules.**
  Find every place that states the convention: the project's `AGENTS.md` and rule files, its review standards, lint config and ADRs, and the captain's rulings in `data/captain.md`, `data/captain-<project>.md` and `data/captain-shared.md`.
  Two that disagree, or none at all, is the finding.

Done when you can say which relevant files the missing side read and which it did not, or have said why the trace is partial.

## 3. Cause

Name one root cause.
A useful test is "five whys": stop at the first cause a setup change can remove.
When several fit, the root is the one whose heal would have stopped the miss on its own; list the others as **contributing**.
Example: the rule never loaded, and the pre-push review that would have caught it never ran either; the rule is the root and the gate is contributing.

A rule counts as loaded only when its own text was in the session before the line was written.
A pointer to it was loaded but the file was never read: that is **Unloaded**, not **Ignored**.

| Side | Cause | The trace shows |
|---|---|---|
| Author | No rule | the convention exists only in a reviewer's head or config |
| Author | Unloaded rule | the rule exists, but the session never loaded it: a wrong `paths:` scope, a weak pointer, a bullet file the brief left out, or a file nothing points to |
| Author | Ignored rule | the rule was loaded but did not steer: buried, phrased as a negation, or vague |
| Author | Bad steering | a brief, steer, ruling, memory, skill or global instruction pushed the wrong way |
| Author | Unrun gate | a check that would have caught it exists, but nothing ran it before the push |
| Reviewer | Missing context | the reviewer did not get the rule, spec, ruling or plan that settles it |
| Reviewer | Stale rule | the reviewer applied a rule the project has since changed or narrowed |
| Reviewer | Overreach | the rule is broader than its intent, so correct code trips it |
| Reviewer | Misread | the reviewer had the right rule and context and misread the code |
| Either | Misleading code | the code itself reads as something it is not |
| Rules | Undecided | the convention was never decided |

Done when the miss has one root cause and its contributing causes.

## 4. Heal

Pick the home where the heal reaches every agent and reviewer that will meet this again.
Shared homes beat personal ones, and deterministic beats prose:

1. **Check:** a lint rule, a test, a CI job, a hook, in the project or in firstmate.
   Any mechanical cause (a banned API, an import shape, a file location) gets one.
   If the project marks rules as enforced or prose-only, a check flips the rule to enforced.
2. **Shared rule:** the rulebook both the author's agents and the reviewer read: the project's `AGENTS.md` and rule files, or firstmate's `AGENTS.md`, a skill, or the brief scaffold for a firstmate-side miss.
   Write it once, where both sides load it, so the two converge instead of each learning separately.
3. **Pointer:** make an existing rule load when it should: its `paths:` scope, a review `path_instructions` pointer, a skill description, or a bullet file a brief should include.
4. **Reviewer config:** the project's review block and the review-standards file it points at.
   A defect in the no-mistakes reviewer itself belongs to its maintainers.
5. **Personal:** firstmate's home-private memory: `data/learnings.md`, `data/learnings-<project>.md`, its playbooks, and its brief bullet files.
   Only for a lesson about this home: its preferences, its machine, its workflow.

A mechanical miss takes the check whatever its cause.
The rest heal by cause:

- **Unloaded rule** fixes the pointer, or moves the rule to where it loads.
- **Unrun gate** heals in the process that should have run it: the skill, brief, hook or CI job.
- **Ignored rule** heals by rewording, or by promoting it to a check.
- **Bad steering** heals the source that steered: the brief bullet, the skill, or the instruction.
- **Missing context** gives the reviewer the rule: a review-standards entry or a `path_instructions` pointer.
- **Stale rule** and **Overreach** narrow or update the rule.
- **Misread** goes to the reviewer's maintainers as a defect, with the evidence; add a worked example to the rule only if the same misread has happened before.
- **Misleading code** heals in the code: a clearer name or a one-line comment.
- **Undecided** is the owner's call: ask, then record the decision as a rule.

A mechanical rule that existing code already breaks in many places still gets a check, one that bans new instances only: lint with the existing ones recorded as debt (a suppressions or baseline file), or a check that runs only on the diff.
The breadth of the debt is a reason to ratchet, not to settle for prose.

Before proposing, look for a heal that already exists:

- the project's issues and PRs, open and closed, through `gh-axi search`; a closed one records a heal that was tried or turned down
- the rulebook, review block and lint config on the default branch
- this home's log of misses, `data/misses.md`
- `data/learnings*.md` and the home's playbooks
- the other heals in the current postmortem

A cause that has recurred gets a stronger heal than last time: search the log of misses for the same cause against the same rule, and prose that failed twice becomes a check.
An existing heal in a personal home does not count as healed when the lesson is shared: promote it to the shared home, and point the personal copy there.

Write firstmate edits by `firstmate-coding-guidelines`, and a project edit by that project's own guidance for writing rules.

A heal may be **none**, but only with a stated reason: a one-off taste nit, or a misread with no pattern yet.
It still gets logged.

Before shipping, check each heal against the captain's standing rulings: `data/captain.md`, `data/captain-<project>.md`, `data/captain-shared.md`, and any ruling the project records as its owner's (for arena, `docs/agents/review-standards.md`).
A heal that changes or contradicts one is a question for the captain first, not a filing.

Done when the miss has a heal with its home, its exact change, and how it ships, or **none** with its reason.

## 5. Ship

Heals ship outside the PR that surfaced them; by merge time that PR is closed, so misleading code also ships as a follow-up.

| Heal | Ships as | Who decides |
|---|---|---|
| A project check, shared rule, pointer, reviewer config, or misleading code | an issue in the project's repo, filed with `gh-axi` | firstmate files it |
| A firstmate check, skill, scaffold or supervision rule | a firstmate issue, or a firstmate ship task through this repo's normal path when its repo takes no issues | firstmate |
| A no-mistakes reviewer defect | an issue for the no-mistakes maintainers | the captain approves first, because that repo is not the captain's |
| Home-private memory | a direct inspect-then-update edit | firstmate |
| Any heal that changes or contradicts a captain ruling | a question to the captain, held through `bin/fm-captain-hold.sh` | the captain |

A shared heal ships as an issue and stops there: no branch or PR for it.
The issue then goes through the project's normal flow like any other work.
Follow the project's issue shape where it has one, and make the body self-contained:

- the miss, with links to the PR and the finding, run or job that surfaced it
- the evidence and the root cause
- the proposed change, exact enough to build from: the rule text, the lint selector, the file it goes in
- how to tell it worked, such as the check going red on the original line

Write the report to `data/<id>/postmortem.md`: one section per miss (the claim, the verdict, side, trace, cause, heal), then the side findings.
Something else broken that the trace turns up, outside a miss's cause, is a **side finding**: report it, and leave it unhealed here.
Tell the captain the filed heal issues by URL in the landing outcome, and ask separately for each held captain question.

### The log of misses

`data/misses.md` is this home's private log, one entry per miss, appended after the heal ships.
A PR with no misses gets one entry saying so, so a skipped postmortem is distinguishable from a clean PR.

```
## <YYYY-MM-DD> <project> <PR url> <miss id>
- Said: <the claim, the red job, or the correction>
- True: <what the verdict established>
- Side: <author | reviewer | rules>
- Cause: <root cause from the table>
- Contributing: <causes, or none>
- Heal: <home>: <the change> -> <issue url | edited file | held for the captain | none: reason>
```

```
## <YYYY-MM-DD> <project> <PR url> no misses
```

Done when every heal has shipped (an issue URL, the edited file, or a held captain question) and every miss has its log entry.
