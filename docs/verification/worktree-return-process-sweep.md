# Worktree return process sweep verification

Active empirical evidence for the guarantee that returning a finished task's worktree never terminates a service shared with other work.
Measured 2026-09-15 on treehouse v2.3.0 unless stated otherwise.

## Two sweeps terminate by working directory

The first is `treehouse return`, whose own help states its scope:

```
$ treehouse --version
treehouse version v2.3.0
$ treehouse return --help
Terminate lingering processes and return a worktree

Usage:
  treehouse return [path] [flags]

Flags:
      --force                    Clean, reset, and return without prompting
  -h, --help                     help for return
      --if-lease-holder string   Return only if the current lease has this holder
      --if-lease-id string       Return only if the current lease has this identity
```

There is no exclusion flag, so the only place firstmate can act is before the call.

The second is `bin/fm-teardown.sh`'s own leaked-process reap (Fix 2 in its header), which ends every process whose working directory is the task's worktree or per-task temp root, before the return runs.
`tests/fm-teardown.test.sh` covers it (`test_leaked_worktree_process_is_reaped` and its neighbours).
The adopted-process scan runs above both, so either one only ever reaches a directory the scan has already cleared.

## The sweep terminates by working directory alone

A pool worktree was leased, an unrelated process was started with its working directory inside it, and the worktree was returned:

```
$ treehouse get --lease --no-fetch
/home/nik/.treehouse/repo-13d81d/1/repo
$ setsid bash -c "cd /home/nik/.treehouse/repo-13d81d/1/repo && exec sleep 600" &
$ treehouse return --force /home/nik/.treehouse/repo-13d81d/1/repo
🌳 Terminated lingering processes: sleep (1395151)
🌳 Worktree returned to pool.
VICTIM KILLED
```

The process was never started by the returned worktree's task and was terminated anyway.

## A detached service is distinguishable from a task's own tree

The ownership test in `bin/fm-adopted-process-lib.sh` reads session membership.
The shared validation daemon leads its own session, and its worker inherits that session from it:

```
$ ps -o pid=,ppid=,sid=,comm= -p 806462,806529,1390074,1390456
 806462     329  806462 no-mistakes
 806529  806462  806462 no-mistakes
1390074 1389975 1389317 bash
1390456 1390074 1389317 claude
```

A task's own agent tree (`bash`, `claude`) carries session `1389317`, led from outside the worktree by the shell that launched it.
The daemon's session leader is itself, with its working directory inside the worktree, which is what the test reads.

Residency alone is not enough, because a window opened in the directory being given up leads a session from inside it too: a multiplexer gives every pane a session and a pty of its own, and a secondmate's window is opened in the home itself.
Measured on herdr 0.8.2, with a real pane and a stand-in detached service sharing one directory:

```
$ herdr workspace create --cwd /tmp/fm-evidence-home --label evid-ws --no-focus --session <lab>
$ setsid bash -c "cd /tmp/fm-evidence-home && exec sleep 300" &
$ ps -o pid=,ppid=,sid=,tty=,comm= -p 857212,858012
 857212  857146  857212 pts/10   bash
 858012     329  858012 ?        sleep
$ fm_adopted_processes /tmp/fm-evidence-home
858012	sleep
exit=0
```

Both lead their own session from inside the directory; only the pane still holds a terminal, because detaching is what gives one up, and only the detached service is reported.
The same two processes through the scan as it read before the terminal fact reported `857212 bash` as well, which is what stopped every retirement of a home whose window was still open.

## Cleanup refuses instead of letting the sweep run

Two stand-in services were started detached inside a third lane's worktree, and that lane was cleaned up with the real `treehouse` on `PATH`:

```
$ bin/fm-teardown.sh lane-c
teardown: worktree return refused: /home/nik/.treehouse/repo-13d81d/1/repo still holds processes that detached from whatever started them, and returning the worktree would terminate them along with this task's own:
teardown:   sleep (1465755)
teardown:   sleep (1465761)
teardown: a detached process may be serving other work, so nothing here will kill one. Establish what it is; end it deliberately if it is this task's leftover, and run the same cleanup again.
error: treehouse return failed for worktree /home/nik/.treehouse/repo-13d81d/1/repo; teardown aborted
teardown exit=1
lane-a run: ALIVE
lane-b run: ALIVE
```

The same two processes died in the unguarded run above and survive here.

This transcript predates two changes to the refusal and is left as it was measured.
The scan now runs above the steps that drop the task branch and remove the turn-end hook files, so a refused lane is left exactly as it was found.
And the trailing `error: treehouse return failed` line no longer prints, because the return tool was never reached.

## A retiring home's own process-event runners

A secondmate home's process-event runners detach into a process group of their own but keep the session of whatever launched them, and their working directory is the home.
Once the launcher's window is gone, their session leader is gone too, so the scan alone would read them as limit (c) below and refuse every retirement of a dead secondmate with a live source.
The home's removal already retires them through `bin/fm-procevent.sh sweep-home`, so the home scans in `bin/fm-teardown.sh` exempt the sessions that the home's own claims name (`firstmate_home_process_event_sessions`).
The exemption covers a session, never a detached service, because detaching gives a process a session of its own.
`tests/fm-adopted-process-lib.test.sh` covers the exemption against real processes: the exempt orphan is left out while a detached service beside it is still reported.
No retirement of a dead secondmate with a live process-event source has been measured end to end.

## Regression coverage

`tests/fm-adopted-process-lib.test.sh` covers the ownership test against real processes, including a process whose session leader has died, which reads as unknown rather than as clear, and a window's own shell on a real pty, which leads its session from inside the directory and is not adopted.
`tests/fm-teardown.test.sh` covers the refusal, its behaviour under `--force`, the absence of a false refusal for a crewmate's own process, and the two-other-lanes case above.
It also covers the four paths a refusal stops on: a refused task worktree keeps its task branch and its turn-end hook files, a forced secondmate retirement stops at a child worktree hosting a detached service rather than removing it, it stops at a child's own secondmate home the same way, and the retiring secondmate's own home stops before anything is touched.
Every one of those scans runs above the `fm_backend_kill` that closes that lane's window, and the retirement cases prove the ordering with a backend mock that really kills a real session leader, so a genuine post-kill orphan is exercised rather than assumed.
Because the scan runs while that window is still open, one case retires a home holding its own window on a real pty and must complete.
The home cases keep the registry entry and the state records that are the only way to name a home that survived.
Both start real detached and attached processes rather than mocking the scan, because the whole guarantee rests on what a real process's session says about who owns it.

## What is not covered

Three limits, the same three the `bin/fm-adopted-process-lib.sh` header states, plus the platform the guard does not run on at all.

(a) A shared service that never gave up a terminal is indistinguishable from the crew work that terminal belongs to by any process fact, and is not caught: an ordinary child of a crewmate's own terminal session, or a service left running in a window of its own inside the directory.
No such service has been measured; the shared validation daemon detaches, as the session table above shows.

(b) A task's own deliberately detached leftover, such as a background server a crewmate started with `setsid`, is refused even though killing it would have been fine.
The operator resolves that by ending that process and running the same cleanup again.

(c) A process living in the directory whose session leader has already exited cannot be attributed either way, so it refuses.
The double-forked daemon has that shape, but the ordinary one is a lane's own leftover orphaned when its window died, which refuses every teardown of that lane until someone ends it.
Teardown's own leaked-process reap does not end it either, because the scan refuses first.
The operator resolves that the same way as (b), by ending the named process and running the same cleanup again.

The per-task temp root that teardown's own reap also covers is never scanned: it is created for one task alone, so no service is started there on another lane's behalf.

Orca lanes are not covered at all.
Both Orca arms remove a worktree through `orca worktree rm --force` without scanning, the task's own and an Orca child's inside the retirement sweep, so an Orca worktree hosting a detached service loses its directory with no refusal and no message.
Whether that removal also terminates the processes living there is unestablished; the directory removal is the verifiable part, and nothing here asserts more than that.

The guard itself runs only where `/proc` is readable, which is where every fact the ownership test reads comes from.
BSD `ps` reports a session as a kernel address rather than a numeric id, and there is no macOS machine to verify a Darwin implementation against, so none was written: an unverifiable guess in the one place that decides whether a live shared service survives would be worse than this stated limit.
On a machine without `/proc` the scan reports that it could not run, teardown prints one warning line saying so, and cleanup proceeds unguarded exactly as it did before this guard existed.
That is the only case that proceeds; a scan that ran and could not attribute a resident process still refuses, which is limit (c).
