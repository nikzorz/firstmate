# Task
## Captain's intent
Postmortem heals the captain asked to have filed and queued: "the idea of the postmortem was ... to just call out what was broken as new issues that then could be queued up to be fixed later". The firstmate repo takes no issues, so each heal ships as a ship task.

Heal to ship, from the review of https://github.com/nikzorz/firstmate/pull/110: the merge guard in bin/fm-pr-merge.sh matches a decision request's named finding by run and id. no-mistakes reuses finding ids across rounds of one step (run 01M4YEVV4E9FV28D0PZ3ZCCN86 has review-1 in both round 1 and round 4), so an escalation of a round-1 finding can clear an approved later finding that only shares its id. A named finding counts only for the round it was raised in.

## Firstmate spec
- Load `firstmate-coding-guidelines` before editing.
- Owners: the worker's escalation sentence in `bin/fm-dod-lib.sh` (its `needs-decision` line gains the gate's round, in one place) and the guard in `bin/fm-pr-merge.sh` (match on run, step, round and id). Read rounds through the primitive `bin/fm-nm-findings.sh` uses.
- A `needs-decision` line written before this change, with no round, still matches as today, so in-flight lanes are not refused for an old line.
- Behaviour tests over fixture records (no source greps): a round-1 escalation does not clear a round-4 finding sharing its id; the same id named for round 4 passes; an old line with no round keeps today's match.
- Out of scope: any other guard rule.
- When the change is committed and the targeted tests pass, start validation yourself with `/no-mistakes`.
