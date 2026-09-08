---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
  Also use before recording or reconciling a captain-gated backlog item against a live worker's gate.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
7. Examine the causal theme across prior findings and fix rounds.
   Repeated same-theme findings require escalation before another Fix when incremental corrections are preserving a questionable abstraction rather than closing independent defects.
8. Apply the existing stronger captain boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless of whether they also expand the contract.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Linked captain-gated backlog items

A captain-gated backlog item filed mid-flight can ask the same question a live worker's gate later raises under a different decision key.
Answering only the gate leaves that item claiming the captain still owes an answer, or recording the captain as the owner of a decision firstmate made.
The pairing is never inferred from prose; it is recorded once and read back.

1. When you file a captain-gated item for a question a live worker's gate will also raise, record the pairing immediately with `bin/fm-decision-hold.sh gate-link <item-id> <origin-id> <decision-key>`, using the decision key the gate itself will carry.
2. Before answering any ask-user finding, read `bin/fm-decision-hold.sh gate-status <origin-id>` so a recorded link is visible while you still hold the decision.
3. In the same step as answering the gate, run `bin/fm-decision-hold.sh gate-resolve <origin-id> <decision-key> --answered-by <captain|firstmate> --answer-file <path>`.
   Run it for every gate you answer: an unlinked gate reports that and succeeds.
   `--answered-by` records who actually decided, so a decision firstmate made under standing authority is never filed as the captain's.
   It is also the verb when the item was already closed by the captain directly or by another linked gate: it leaves that existing record intact and appends this gate's outcome.
4. When the origin's work ends and a recorded link's gate never raised the question, retire that link with `--not-raised`, which leaves the item open and captain-owned.
   Use it only while the linked item is still open; a question settled elsewhere is reconciled with `--answered-by`, which records who closed the item.
   Teardown refuses while any recorded link is unreconciled.

`bin/fm-decision-hold.sh --help` owns the command syntax, the link record's location, and retry behavior.
This is a separate trigger from `decision-hold-lifecycle`, which owns unresolved decisions discovered by an investigation or visual review.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
