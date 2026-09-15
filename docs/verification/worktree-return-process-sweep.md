# Worktree return process sweep verification

Active empirical evidence for the guarantee that returning a finished task's worktree never terminates a service shared with other work.
Measured 2026-09-15 on treehouse v2.3.0 unless stated otherwise.

## The sweep belongs to the return tool, not to cleanup

`bin/fm-teardown.sh` does not sweep processes itself.
The line that reported the terminations comes from `treehouse return`, whose own help states its scope:

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

## Regression coverage

`tests/fm-adopted-process-lib.test.sh` covers the ownership test against real processes, including a process whose session leader has died, which reads as unknown rather than as clear.
`tests/fm-teardown.test.sh` covers the refusal, its behaviour under `--force`, the absence of a false refusal for a crewmate's own process, and the two-other-lanes case above.
It also covers the three ways a refusal has to stay cheap: a refused task worktree keeps its task branch and its turn-end hook files, a forced secondmate retirement stops at a child worktree hosting a detached service rather than removing it, and a secondmate home hosting one stops with its registry entry and state records intact rather than deleting the only records that can name a still-leased home.
Both start real detached and attached processes rather than mocking the scan, because the whole guarantee rests on what a real process's session says about who owns it.

## What is not covered

Two limits, the same two the `bin/fm-adopted-process-lib.sh` header states.

(a) A shared service started as an ordinary child of a crewmate's own terminal session, never detaching, is indistinguishable from that crewmate's work by any process fact and is not caught.
No such service has been measured; the shared validation daemon detaches, as the session table above shows.

(b) A task's own deliberately detached leftover, such as a background server a crewmate started with `setsid`, is refused even though killing it would have been fine.
The operator resolves that by ending that process and running the same cleanup again.
