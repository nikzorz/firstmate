# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Captain-gated backlog links

A separate defect shares this script: a captain-gated backlog item filed mid-flight can ask the same question a live worker's own gate later raises under a different decision key.
Answering only the gate left the item queued and kind `captain`, so the backlog either nagged for a settled question or recorded the captain as the owner of a decision firstmate made.
The normative trigger and procedure are owned by `.agents/skills/ask-user-authority/SKILL.md`.

The `gate-link` subcommand records the pairing in `data/gate-links/<origin-id>/<decision-key>` as `key=value` lines, one file per gate identity, and that index is the single authority for the pairing.
Nothing infers the pairing from title or body prose.
It refuses an item that is not kind `captain`, an item that is already closed, an origin the active home does not own, and an attempt to repoint an existing gate identity at a different item.

The `gate-resolve` subcommand is the reconciliation the answering path owes and is safe to run for every gate answered: an unlinked gate reports that and exits zero.
For a linked gate whose item is still open, `--answered-by` replaces the item's body with the recorded answer, the gate identity, and the actual decider, archives the superseded body through `tasks-axi update --archive-body`, releases the hold, and closes the item.
`--answered-by` is also the verb when the item was already closed by another authority, which happens when the captain closes it directly or when a second gate is linked to the same item.
That path never rewrites or archives the existing body, because that body records whoever actually closed the item; it appends this gate's outcome as a `tasks-axi done --note` line instead.
The link then carries `closed_by`, read only from this mechanism's own machine-written marker and never from free prose: `self` when this gate closed the item, the other gate's `<origin>/<key>` identity when the marker names one, and `external` otherwise.
`--not-raised` retires a link whose gate never asked the question, whether or not the item has since been closed.
While the item is open it stays open and captain-owned, which is the honest reading there, and the outcome line says so.
Once another authority has closed the item, the link records that authority in `closed_by`, the outcome line names it, and no note is appended, because this gate answered nothing.
A question this gate did settle uses `--answered-by` instead.
Retries are idempotent against the recorded decider, answer digest, and closing authority, and reject a changed answer, a changed decider, a changed closing authority, or a late reversal between the two outcomes.

The index reader has no silent skip.
Any entry in `data/gate-links/<origin-id>/` that is not a fully recognised link record is itself an unreconciled link.
A record is recognised only when it is a regular file whose basename is a valid gate slug, whose `item=` is non-empty, whose `origin=` equals the enumerated origin, whose `key=` equals its own basename, and whose `state=` is exactly one of `open`, `answered`, or `not-raised`.
Enumeration includes dotfiles, and writes stage one directory above the per-origin index, so an interrupted write leaves nothing the reader could quietly pass over.
Every earlier narrowing here was correct on its own and each one added another way to be skipped, because the reader's default was permissive; a file the reader cannot understand is now a reason to stop.

The read-only `gate-status` and `gate-verify` subcommands parse only that index and never call tasks-axi.
`gate-status` prints an unrecognised entry as such rather than omitting it, so what `gate-verify` refuses on is visible.
Teardown calls `gate-verify` for every non-secondmate task before any destructive cleanup, so a landed task cannot quietly leave a linked captain item still claiming the captain owes an answer.
Cleanup can therefore now refuse where it previously passed, on an unrecognised or hand-edited index entry as well as on an open link, and the refusal names the offending file.
The `--force` path remains the explicit captain-approved discard escape hatch and still bypasses this check.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Captain-gated backlog link verification date: 2026-09-08.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The captain-gated link regression reproduces the stale reading before proving the fix.
It files a synthetic captain-kind held item, answers the equivalent gate on a live worker with no link recorded, and asserts the item is still queued, still held, still kind `captain`, and still claims the captain owes an answer.
It then records the link, answers the same gate, and asserts the item closes with the gate identity and the actual decider in its body, the superseded body archived, and no surviving pending claim.
Two later cases cover the item being closed before the gate is reconciled, once by the captain directly and once by a second gate linked to the same item.
Each asserts that `--answered-by` succeeds, records the real closing authority, and leaves the existing record of who closed the item untouched.
A further case retires a link whose gate never raised the question after another authority closed the item, and asserts the outcome names that authority, never says the item was left open, and leaves the item's body byte-identical.
The last case plants each unrecognised record shape in the index directory in turn, including a dotted key, a missing `origin=`, a missing `key=`, an unknown `state=`, and an empty file, and asserts every one blocks verification, is named in the refusal, and is visible in `gate-status`.
An end-to-end case then plants a truncated record and asserts `bin/fm-teardown.sh` refuses, names that file, and preserves the task metadata.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - an unlinked captain-gated item survives its own gate's answer still claiming the captain owes it
ok - a recorded gate link reconciles the captain-gated item in the same step as the answer
ok - a gate that never raised the question leaves the captain-gated item open and captain-owned
ok - a question settled by another authority reconciles without a false record
ok - a second gate linked to one item records the first gate as the closing authority
ok - an unraised link retires honestly after another authority closed the item
ok - every index record the reader cannot recognise blocks verification and is named
ok - teardown refuses until every recorded captain-gated link is reconciled
ok - gate links validate identity, ownership, and item kind before recording a pairing

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
