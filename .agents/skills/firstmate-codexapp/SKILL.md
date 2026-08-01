---
name: firstmate-codexapp
description: >-
  Agent-only playbook for coordinating visible Codex Desktop threads alongside Firstmate without pretending they are a selectable shell backend.
  Use before creating, reading, steering, archiving, debugging, or reviewing a Codex App visible thread for Firstmate work, and before responding to requests to make Codex App native to Firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-codexapp

## Overview

Use this playbook when Firstmate work needs a visible Codex Desktop thread.
The current supported shape is Desktop host-tool choreography plus an explicit status-file return-channel check, not a `codex-app` value in `FM_BACKEND`.

## Boundary

Codex Desktop visible threads are companion host-tool workflows, not a selectable Firstmate backend.
Read `docs/codex-app-backend.md` when it exists in this checkout; that document owns the acceptance contract, bridge requirement, status-return requirement, and staged rollout.

If local helper scripts exist for Codex App work, use only helpers explicitly provided by the operator or maintained by Firstmate.
For helpers outside `bin/`, inspect the source or header before running `--help`.

## Preflight

1. Confirm this session is running inside Codex Desktop and that the host tools are exposed.
   Search exact names when needed: `create_thread`, `list_threads`, `read_thread`, `send_message_to_thread`, `archive`, and `set_thread_archived`.
2. Confirm the target repository is already saved as a Codex Desktop project.
   No host tool currently creates Codex App projects for an agent, so the human must add the project in Desktop before a created thread can reliably land there.
3. Do not create projectless threads for repo work.
   If the project is absent, stop and ask for the project to be added or use a normal Firstmate backend instead.
4. Decide whether this is a real Firstmate-managed task or a visible companion thread.
   A real task needs a task id, an isolated worktree or Desktop-owned cwd, a branch plan, a readable `data/<id>/brief.md` path, and a writable `state/<id>.status` path.
   Those last two are siblings: the brief is the only place the worker learns its contract, and the status file is the only place firstmate learns the result.

## Create And Send

When creating a visible thread, use the Desktop host tool, not shell imitation.
Target the saved project and ask the worker to start by reporting:

```text
pwd
git rev-parse --show-toplevel
git branch --show-current
git log --oneline --max-count=3
```

For writable repo work, instruct the worker to use the Codex-created current directory.
Do not tell it to `cd` into the saved project checkout for edits, commits, no-mistakes, pushes, or PR work.

When sending follow-up instructions, use `send_message_to_thread`.
If the user types directly into the visible thread, treat that as authoritative and reconcile from `read_thread` instead of undoing it.

## Status Return Channel

A Desktop-owned Codex thread can read its brief and append to Firstmate status files only when the prompt gives absolute paths and the Desktop permission context can reach that checkout.
That makes both the brief read and the status write verified requirements, not facts to assume.

For a Firstmate-managed task, do not restate any part of the crewmate contract here.
`bin/fm-brief.sh` scaffolds a complete brief at `<absolute-firstmate-home>/data/<task-id>/brief.md`, and that file is the single owner of the whole contract: the task, the setup, every rule, the status protocol with its pause lifecycle, and the definition of done the project's delivery mode requires.
Excerpting part of it into the thread message was tried and kept failing the same way, because every excerpt boundary leaves the brief's own internal cross-references dangling on the far side of it.
So point at the brief instead of copying it, the same way this section already hands over an absolute status path rather than describing where status lives.

Scaffold the task's brief as usual, then send its absolute path with only the context the brief cannot know:

```text
Your brief is <absolute-firstmate-home>/data/<task-id>/brief.md.
Read it in full and follow it exactly; it is the authority on your task, your rules, your status protocol, and your definition of done.
Where the brief says "your pane", it means this visible thread, which firstmate reads with read_thread.
Its report-sparingly bar has exactly one named exception, and it comes first: before any substantive work, append "working: Codex Desktop thread started" to the status file the brief names, then reply here quoting your brief's definition of done.
```

That quoted reply is the read receipt, and it is checkable rather than taken on faith: a worker that never opened the file cannot produce the gate its own delivery mode carries.

Verify both channels before treating the thread as supervised:

- `read_thread` shows the worker quoted a definition of done that matches the one `bin/fm-brief.sh` generated for this task's delivery mode.
- `read_thread` shows the worker attempted the status write.
- The local `state/<task-id>.status` file contains the expected line.
- If available, the transcript includes a file-change entry for that status file.

If the thread cannot read its brief or cannot write the status file, keep it as a visible companion thread only.
Do not treat it as a Firstmate-managed task, and do not claim it is a complete Firstmate backend.
Never leave a thread running on a brief it could not read: without that file it has no task, no rules, no status protocol, and no definition of done at all.

## Observe And Reconcile

Use `read_thread` for thread truth.
Use `list_threads` only to find or recover a visible thread id, not as a replacement for reading the transcript.

For Firstmate reconciliation, prefer concrete evidence:

- thread id and project
- current Desktop-owned cwd
- branch name
- last meaningful thread state
- latest status file line
- PR URL when one exists

Avoid repeating long transcripts into Firstmate docs or PR bodies.
Summarize only the host-tool calls, the status-file result, and the archive result.
When reporting a Desktop-thread result to the captain, translate status prefixes and return-channel evidence through `AGENTS.md` section 9.

## Archive

Archive through the Desktop host tool: `archive` when that is the exposed primitive, or `set_thread_archived(threadId=<id>, archived=true)` when that is the exposed tool name.
Archiving can remove the thread from normal sidebar/project views, but it should not erase the transcript or landed work.

For companion threads, archive the thread and report where the durable work landed.
If there is a real Firstmate task record, leave teardown decisions to the normal Firstmate task flow instead of this skill.

## Failure Signals

- Missing Desktop project: ask the human to add the target project in Codex Desktop, or use a normal backend.
- Missing host tools: do not simulate them with shell files; use a terminal backend instead.
- Status file not updated: treat the thread as unsupervised until the return channel is proven.
- Worker editing the saved project checkout instead of its Desktop cwd: stop and decide whether to salvage the branch before continuing.
- Production `codex-app` backend request: read `docs/codex-app-backend.md` and do not invent a local adapter.
