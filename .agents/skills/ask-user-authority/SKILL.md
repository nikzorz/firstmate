---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of the policy for deciding a finding that reaches firstmate: firstmate always applies judgment, files a finding that does not block the change as a follow-up issue instead of fixing it, decides blocking findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, files any finding that does not block the change as a follow-up issue, decides any blocking finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous or destructive findings.

Three actors apply finding policy, and a change to it covers all three.
Firstmate applies this skill to every finding a worker escalates.
The no-mistakes worker answers every other gate itself under the driving block `bin/fm-dod-lib.sh` owns, which escalates here only the cases that block names.
The away-posture supervision branch receives this skill verbatim from `bin/fm-branch-prompt.sh` and applies it under that prompt's role limits, which forbid posting outside the fleet.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide whether the finding blocks the change.
   It blocks when the change would be wrong without it: it breaks an accepted requirement, a test, or behavior the change promised, or it is security-sensitive.
   Judge "breaks a test" against the merge ref too: a finding a check on main, or on a PR firstmate holds green to merge, fails on blocks, even when the branch's own run is green.
   A finding that only improves the change does not block: a simplification, an edge case of a heuristic the change openly is (including a heuristic the brief or the captain's intent asks for), or a hardening or Fix that would materially expand the contract (a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture) the accepted intent did not include.
4. File a non-blocking finding instead of fixing it, without asking the captain.
   Open one follow-up issue in the project's repo with `gh-axi`, carrying the finding verbatim, the PR, and the smallest change that would address it; when the project takes no issues, add a backlog item instead.
   The gate answer leaves the finding unfixed with that issue as the reason, and the worker links the issue from the PR body before it reports the PR ready.
   While the captain is away, the away-posture supervision branch does not file: it records the follow-up text in its outcome for the return brief, answers the gate leaving the finding unfixed with that recorded follow-up as the reason, and firstmate files the issue on return.
5. Fix a blocking finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
   Neither restoring behavior a fix round broke nor completing an already-approved design covers a finding on a theme an earlier round of the same run already fixed; that follows the same-theme cutoff in `validation-supervision`, even when the finding completes a captain's ruling.
   A ruling whose fix would revert the change to its base or replace it with different work is never a Fix: it invalidates the work as `validation-supervision` describes.
   A Fix ruling never says change nothing else.
   It says: change nothing outside the property, except the smallest adjacent edits a named change needs to keep the project's checks green; name each in the fix summary; and if no green form exists, leave the finding unresolved and say why.
   When a Fix ruling's instructions scope a check, state the property the check must hold (the set its claim names, such as every script a power fight runs) and tell the fix round to derive the members from the code and name that derivation in the check.
   Never paste a list from a finding: a reviewer's survey says where it looked, not what the claim covers.
   A Fix ruling sent with `fm-send --resolve-key nm-*` carries that property on a line beginning `Property:`, and a list from the finding may follow it only as examples; `bin/fm-send.sh` refuses a Fix ruling without that line.
   A finding's remedy and its example are one case of the property, never the property.
   Before writing the ruling, read the run's earlier findings on the same code with `bin/fm-nm-findings.sh <run>`, which prints them whole where the gate cuts them short.
   Then state the invariant the finding's root breaks as a rule over every case, and name its mirror case, such as the other direction of the same comparison.
6. Escalate only a blocking finding that is genuinely ambiguous:
   - its only fix would materially expand the contract in one of the ways step 3 lists
   - a product or architecture call not settled by accepted intent
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
   - a second blocking finding on a theme an earlier round of the same run already fixed, as `validation-supervision` defines theme
7. A non-blocking finding on a theme already fixed in an earlier round of the same run follows the same-theme cutoff in `validation-supervision` instead of another fix round.
8. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task or to make it blocking.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof does not block and becomes a follow-up issue.
- A missed input case in a classifier the change documents as heuristic does not block and becomes a follow-up issue; a second such case in the same run triggers the same-theme cutoff.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
