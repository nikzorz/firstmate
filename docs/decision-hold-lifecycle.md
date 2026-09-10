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

A captain-gated backlog item filed mid-flight can ask the same question a live worker's own gate later raises under a different decision key.
Answering only the gate left that item claiming the captain still owes an answer, or recorded the captain as the owner of a decision firstmate made.
The normative trigger and procedure are owned by `.agents/skills/ask-user-authority/SKILL.md`.

The backlog item is the single record of whether a decision is owed.
The link record in `data/gate-links/<origin-id>/<decision-key>` holds only the origin-keyed pairing, as `item`, `origin` and `key`.
It exists because teardown asks whether an origin has an unreconciled pairing, and the backlog has no origin key to answer that with.
Nothing about the decision itself is duplicated there.

Two properties carry the design and are stated in `bin/fm-decision-hold.sh` rather than left to be inferred.
`gate-verify` never reads the linked item and never calls tasks-axi, so a surviving link is an unreconciled link and every way the item can depart or become unreadable is irrelevant by construction rather than classified.
The link record is frozen at those three fields, created once and deleted once, never rewritten; a proposal to add a field, including a decider, is this design's declared failure signal.

`gate-link` records the pairing after checking that the item asserts an owed captain decision.
It refuses a secondmate origin, because it writes through tasks-axi in the active home and a decision a secondmate raised belongs in that secondmate's own home rather than the one retiring it.
`gate-answered` performs the item write and only then removes the link, so a surviving link always means the write did not land, and a retry is idempotent against the item's own state rather than against anything recorded on the link.
It writes that answer only while the item still asserts an owed captain decision, which is the same claim `gate-link` required.
An item that stopped asserting one was settled by someone else, so this gate never writes its answer over it, which would displace the real decider and name this caller instead.
An item that is already closed is noted on and left closed, because a note backfilled onto a closed item does not move it.
An item that was settled and deliberately left open has nothing written to it and the link is simply dropped, because tasks-axi appends a note only by closing an item, and this mechanism does not own the lifecycle of a record it did not write.
Accepted limit, chosen rather than inherited: that item carries no cross-reference naming the gate that also settled the question.
Recording one would mean closing the item to append the note and reopening it, and closing a row drops or rewrites its `since` date, which `bin/fm-fleet-snapshot.sh` reads and surfaces.
This shape is defined by whoever settled it having already written their own answer into the item, so the item is not silent about the decision and the note would only have added the cross-reference.
Paying for that with a falsified `since` date would write a false backlog row to avoid a missing one, which is what this contract exists to remove, and a gap is not a lie.
An item that already carries this gate's answer but was never closed is closed as it stands, without a rewritten body and without a second note, because the only step the interrupted sequence still owes it is the close.
The note this gate leaves on an item it found closed never owed a close, so it is recognised ahead of that body and only clears the link, which keeps a reopened item from being closed again by a retry.
That note is read before the owed predicate rather than inside it, because `tasks-axi done` leaves the hold fields alone and `reopen` restores the hold from them, so an item this gate had already noted could assert an owed decision again and take the write path over the answer whoever settled it wrote.
Accepted residual of that ordering: a deliberate re-link of the same origin and key on that same reopened item is reported as already recorded and nothing is written, which is a missing record rather than a false one.
`gate-not-raised` removes the link and writes nothing anywhere.
An item read that could not be established refuses and keeps the link, so cleanup keeps refusing and a retry after repair still lands.
tasks-axi answers with the same not-found code for an id absent from a readable store and for a store it could not open at all, so `gate-link` and `gate-answered` trust absence only once the store the active home is configured to read is itself a readable regular file.
That store is the `[markdown] path` key of the home's `.tasks.toml`, resolved against the home.
With no key, tasks-axi discovers its store rather than defaulting to a fixed one, reading `backlog.md` in the home root when one is there and `data/backlog.md` otherwise, and the guard follows that same order.
Where a store exists the guard therefore names the file the tool opens; where neither candidate exists it names the last one it looked for, which is the one case the two can differ, and both refuse.
A store that is missing or unreadable refuses by naming the path it looked for.
Every firstmate home is cloned from this repo and inherits the tracked root config, so the keyless path is defence in depth rather than a live one, and a guard that named a different file would read as protection while refusing a genuine departure or trusting a not-found from a store nothing reads.

An item asserts an owed captain decision when `hold_kind` is captain, a `hold_reason` is present, and its state is not done.
`kind` is deliberately not part of that test, because `tasks-axi update --kind` leaves the hold fields intact and reading `kind` let a still-held item read as no longer captain-owned.
`bin/fm-fleet-snapshot.sh` reads the same fields for Bearings and deliberately does not share this code.

Accepted documented limit: a captain item that is renamed, or handed to another backlog, is indistinguishable from one that was removed, because the link's only handle on the item is its id.
Both read as no longer in this backlog, and the item keeps asserting an owed decision wherever it now lives.

The index reader has no silent skip: an entry it cannot fully recognise is an unreconciled link, refused by path.
`[ -e ]` follows symlinks, so a dangling symlink is routed on by `[ -L ]`, and the regular-file test runs before any field is read so a FIFO cannot block a read and hang cleanup.
The rule covers the directories the reader traverses as much as the records inside them, because a failure to look is not an answer at any level.
An index that cannot be established, whether the origin's own directory cannot be listed, something that is not a directory sits at its path, a parent above it cannot be searched, or a record cannot be read, is refused by the path it was reached through.
Every command that reads the index asks whether it can be established through that one boundary before it reaches any conclusion of its own, so none of them can read a probe that never ran as an absent pairing or an empty directory.
Teardown calls `gate-verify` for every non-secondmate task before destructive cleanup, so cleanup can now refuse where it previously passed, and the refusal names the file.
`--force` remains the captain-approved discard escape hatch, and it removes that origin's own index directory alongside the other per-task records it discards, so a later task reusing the id does not inherit a link belonging to the previous one.

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
Captain-gated backlog link verification date: 2026-09-10.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The captain-gated link regression reproduces an unlinked item going stale under its own gate's answer, then covers the settled and departure shapes, the index reader's refusals under a bounded timeout, and the teardown gate with and without `--force`.

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
ok - answering a linked gate closes the item and removes the link
ok - the owed predicate reads the captain hold, so a re-kinded item is still closed
ok - a gate that never raised the question writes nothing and leaves the item captain-owned
ok - every departure shape reports what it did and did what it reported, and the link goes
ok - an item read that could not be established refuses, keeps the link, and lands on retry
ok - the store guard follows tasks-axi's own discovery order in both directions
ok - a failed answer write leaves the item still asserting an owed captain decision
ok - each settled shape takes the branch written for it and repeats without changing the item further
ok - this gate's note on an item found closed never becomes an owed close on retry
ok - a marker is read only by the key that wrote it, not by a key it extends
ok - an item whose id renders quoted is established rather than refused
ok - an item the backlog answered about without naming is refused, not acted on
ok - a staging write that cannot land refuses by name and keeps the link
ok - a gate-answered flag given without its value refuses with its own message
ok - an interruption at any point in the answer sequence keeps the link until the item is closed
ok - a renamed or handed-off captain item is an accepted limit and still asserts its decision
ok - gate-link refuses a link record it cannot prove regular and readable
ok - gate-link refuses a secondmate origin and says where that decision belongs
ok - gate-link stages outside the scanned index directory and leaves nothing behind
ok - an index whose absence can be established reads as clean at every level
ok - every command that reads the link index refuses an index it cannot establish, by path
ok - every index record the reader cannot recognise blocks verification and is named
ok - gate-verify and gate-not-raised never call the backlog backend
ok - gate links validate identity, ownership, and the owed claim before recording a pairing
ok - teardown refuses until every recorded captain-gated link is reconciled
ok - a forced teardown discards only the torn-down origin's captain-gated link index

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
