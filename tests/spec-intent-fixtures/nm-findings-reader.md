# Task
## Captain's intent
Postmortem heals the captain asked to have filed and queued: "the idea of the postmortem was ... to just call out what was broken as new issues that then could be queued up to be fixed later". The firstmate repo takes no issues, so each heal ships as a ship task.

Heal to ship, from the postmortem of merged PR https://github.com/nikzorz/arena/pull/1717: a no-mistakes gate truncates each finding's description at about 300 characters, and no axi command prints it whole. The worker answered round 1 from a truncated finding, with fix instructions that narrowed the reviewer's own proposed fix (which sat in the truncated part), and two more fix rounds plus a captain question went to arrive where round 1 started. Firstmate's round-2 ruling then stated the finding's narrow remedy as the property and missed its mirror case (the other direction of the same comparison).

What the heal delivers: a way to read every finding of a gate whole; workers read findings whole before answering a gate and never use fix instructions to change, narrow or replace a finding's proposed fix; and a ruling states the invariant a finding's root breaks, names its mirror case, and reads the run's earlier findings on the same code first.

## Firstmate spec
- Load `firstmate-coding-guidelines` before editing.
- New `bin/fm-nm-findings.sh <run-id> [--step <step>] [<finding-id>...]` prints each finding's id, severity, file, line, action and full description verbatim, read-only from `~/.no-mistakes/state.sqlite`. `bin/fm-pr-merge.sh` gained a per-round read of the same records in https://github.com/nikzorz/firstmate/pull/107: share one primitive rather than adding a second reader. It exits non-zero naming any requested id it cannot find.
- In `bin/fm-dod-lib.sh`'s no-mistakes driving block: before responding to any gate, read every finding in full with `bin/fm-nm-findings.sh <run> --step <step>` and write ask-user snapshots from its output; when answering fix on its own judgment, the worker passes `--instructions` only for scope (files, tests, what not to run), never to change, narrow or replace a finding's proposed fix, and escalates as `needs-decision` to change one.
- In `.agents/skills/ask-user-authority/SKILL.md` `## Decide`, beside the ruling-scope step: a finding's remedy and its example are one case of the property, never the property; state the invariant the finding's root breaks as a rule over every case, name its mirror case, and read the run's earlier findings on the same code with `bin/fm-nm-findings.sh` before writing it.
- Tests prove behaviour, never grep source text: a colocated `tests/fm-nm-findings.test.sh` over a fixture database with a 1,427-character description asserts it prints whole and that an unknown id fails; the brief test asserts the rendered no-mistakes brief carries the reader and the no-narrowing rule.
- Out of scope: the widening of the merge guard (its own task) and any change to no-mistakes itself.
- When the change is committed and the targeted tests pass, start validation yourself with `/no-mistakes`.
