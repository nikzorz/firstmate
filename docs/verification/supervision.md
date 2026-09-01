# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, wedge-alarm, and run-inactivity guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-captain-translation-contract.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.93 | Passive `Stop` plus bounded resume | Project hook ran under trust, resumed once without inherited bypass permissions, and the environment latch prevented recursion. |

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
A live session and a fork descending from it resolve to a single owner of one home: `tests/fm-session-lock.test.sh` pins the ownership classification and the claim that collapses it, and `tests/fm-claude-stop-autoarm.test.sh` measures the outcome through the real arm and watcher as exactly one watcher cycle started for the home while both sessions live.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-session-lock.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.

## Away-mode keep-awake

This record supports the mechanism choice in `bin/fm-keep-awake.sh`.
It was measured on 2026-07-28 on Windows 11 under WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2) with PowerToys installed per user, so `PowerToys.Awake.exe` sits in the `AppData\Local\PowerToys` directory of the Windows user profile and is reached from WSL through the mounted Windows drive.

PowerToys Awake cannot be driven as a standalone process on a machine whose PowerToys runner already owns the Awake module.
The running module reports:

```
PowerToys.Awake.exe --use-pt-config --pid 18952
```

A second standalone launch, from any working directory, exits immediately:

```sh
./PowerToys.Awake.exe --time-limit 6; echo "rc=$?"
```

Observed output: no stdout, `rc=1`.

Its `--pid` binding is also not usable from here: it takes a Windows process id, while the away-mode daemon has a Linux one, and the two namespaces are unrelated.
`--use-parent-pid` binds to the shared per-VM interop host rather than to anything away-mode-scoped, so it would outlive away mode:

```sh
powershell.exe -NoProfile -Command '(Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId'
```

Observed output: the same parent (`wslhost.exe`) for every separately launched Windows process.

The mechanism actually used is `kernel32!SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)` held by a `powershell.exe` process.
Running the shipped script, which prints its readiness marker and then idles re-asserting the request:

```sh
powershell.exe -NoProfile -NonInteractive -Command "$(bash -c '. bin/fm-keep-awake.sh; fm_keepawake_ps_script')"
```

Observed output: `FM_AWAKE_HELD`.

That the API returned a non-zero prior state, rather than the 0 that signals refusal, came from a SEPARATE ad-hoc probe run once by hand.
The shipped script only tests that return value and never prints it, so this probe is evidence about the API and not about the mechanism:

```sh
powershell.exe -NoProfile -NonInteractive -Command 'Add-Type -TypeDefinition "using System;using System.Runtime.InteropServices;public static class FmProbe{[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern uint SetThreadExecutionState(uint esFlags);}"; "prev={0}" -f [FmProbe]::SetThreadExecutionState([uint32]2147483649)'
```

Observed output: `prev=2147483648`.
A non-zero return is the documented success signal, and `2147483648` is `ES_CONTINUOUS` alone, which is the expected prior state of a fresh thread.
`powercfg /requests` cannot corroborate it here because it requires an elevated prompt.

Self-release rests on WSL propagating termination to the Windows process.
Killing the Linux-side process of a Windows program and then querying the Windows side:

```sh
kill -TERM "$linux_side_pid"
powershell.exe -NoProfile -Command "if (Get-Process -Id $windows_pid -ErrorAction SilentlyContinue) { 'WINDOWS_STILL_ALIVE' } else { 'WINDOWS_GONE' }"
```

Observed output: `WINDOWS_GONE`.

The opt-in gate, fail-open behavior, idempotence, release on stand-down, and release after the away-mode daemon dies are covered without any real power state by `tests/fm-afk-launch.test.sh`, which runs the whole lifecycle against a fake Windows shell.

## Claude usage-limit recovery

This record supports the quota half of the usage-limit stall detection in `bin/fm-claude-limit-lib.sh`.
The prompt half is a stable text signature covered without a real stall by `tests/fm-limit-resume.test.sh` and `tests/fm-crew-state.test.sh`, in both directions: the observed prompt matches, and ordinary worker output discussing rate limits does not.

Whether the account window has reset is read from the quota authority rather than inferred from elapsed time, and WHEN it will reset is read from the same place rather than guessed from a fixed cadence.
Measured on 2026-07-30 with the installed quota-axi 0.1.13 against a Claude Max account, alongside Claude Code 2.1.220.

```sh
quota-axi --provider claude --json \
  | jq '{schemaVersion,
         state: .providers[0].state | {status, stale},
         windows: .providers[0].windows | map({id, percentRemaining, resetsAt}),
         semantics: .providers[0].quotaSemantics
           | {status, all_models: (.effectiveAvailability[]
                                   | select(.scope == "all_models")
                                   | {status, effectivePercentRemaining, boundedBy, limitingWindowIds})}}'
```

Observed output:

```json
{
  "schemaVersion": 2,
  "state": { "status": "fresh", "stale": false },
  "windows": [
    { "id": "five_hour",   "percentRemaining": 36,  "resetsAt": "2026-07-30T10:40:00.397443+00:00" },
    { "id": "seven_day",   "percentRemaining": 53,  "resetsAt": "2026-08-04T06:00:00.397461+00:00" },
    { "id": "model:fable", "percentRemaining": 100, "resetsAt": null }
  ],
  "semantics": {
    "status": "known",
    "all_models": {
      "status": "known",
      "effectivePercentRemaining": 36,
      "boundedBy": ["five_hour", "seven_day"],
      "limitingWindowIds": ["five_hour"]
    }
  }
}
```

Every field the verdict depends on is present here: the provider's own freshness flag, its `known` semantics marker, and the bounded all-models headroom.
Reading `effectiveAvailability` rather than a chosen entry of `windows` is what keeps a model window sitting inside a shorter account window from being missed.
`stale` is a real boolean here, which is why the reader compares it with `== false` instead of jq's `//` alternative operator: `//` treats a literal `false` the same as an absent field and would have discarded exactly the good case.

The scheduled recheck adds four more fields to that dependency, all present above: `providers[].windows[].id`, `.percentRemaining`, `.resetsAt`, and `effectiveAvailability[].boundedBy`.
`boundedBy` is what joins the two arrays - it names the window ids that bound all-models availability, and the reader keeps exactly those `windows` entries, so the reset time can only ever come from a window that actually constrains the account.
Note that `boundedBy` is broader than `limitingWindowIds`: the recorded output bounds on both `five_hour` and `seven_day` while only `five_hour` is currently limiting.
That distinction is the point of reading it - the account stays short until every currently-short bounding window has rolled, so the reader schedules from the LATEST of their `resetsAt`, not the first.

`resetsAt` is a UTC ISO 8601 timestamp with microseconds and a numeric `+00:00` offset, which is the exact shape `fm_claude_limit_parse_iso8601` is written for.
`model:fable` is the useful counter-example in this capture: it reports `resetsAt: null`, and at 100 percent remaining it is not a currently-short window - it is not even listed in `boundedBy`, so it never enters the set the reset time is taken from.
A short bounding window whose `resetsAt` or `percentRemaining` the provider does not report makes the whole schedule unknown rather than optimistically early.

Every unreadable, unparseable, provider-stale, or not-`known` input reports `unknown` with no recheck time, which authorizes neither recovery nor a settled wait; `tests/fm-limit-resume.test.sh` covers each of those inputs without touching a real account.
A readable window whose reset time is absent or unparseable is still a good `exhausted` verdict - only the scheduling refinement is lost, and the supervisors fall back to `FM_PAUSE_RESURFACE_SECS` exactly as before.
If the provider ever renames any of the four fields, that fallback is what happens silently, so this record is the thing to re-run when a quota-axi upgrade lands.

## Run inactivity budget

This record supports the `active_steps` half of the stalled-run detection in `bin/fm-crew-state.sh`.
The budget arithmetic and the unrecognised-status arms are covered without a real run by `tests/fm-crew-state.test.sh`; what needs live evidence is the surface those figures are read from, because field presence in an external CLI is evidence rather than a contract.

Measured on 2026-08-21 against the installed no-mistakes v1.45.4, reading a run record through `NM_HOME` pointed at a copy of the state database so nothing live was touched.

```sh
NM_HOME=<copy> no-mistakes axi status --run <run-id>
```

The table and all three `last_activity` renderings it produces:

```
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,running,7h7m,"5s ago: log: I'll review the branch changes now.","424242",round 3
    ci,running,4h20m,"quiet 20h52m ago: log: all CI checks passed - still monitoring until merged or closed","",round 1
    ci,running,4h21m,unknown,"",round 1
```

Three facts the reader depends on are visible here.
The elapsed figure leads the `last_activity` value, so only the first whitespace-delimited token has to parse and the log prose after it is never scanned for digits.
The `quiet ` prefix no-mistakes adds past its own `step_quiet_warning` sits before that token rather than replacing it, so stripping the prefix is enough.
A step with no recorded activity renders the bare word `unknown`, which is the case that must not manufacture a stall.
Durations render as `30s`, `1h0m`, `20h52m`, and `3d11h`, all of which the token parser accepts.

Columns are located by name from the table header rather than by position, so this record pins the field names, not their order.

## Gate status word on a parked run

This record supports the gate-ownership half of the parked detail in `bin/fm-crew-state.sh`, which appends its ownership token only for a gate whose status word one of its two probes can read.
That rule is worth measuring because a parked run whose status word neither probe can read never earns the token and so is never absorbed, and whether that shape occurs in practice is evidence rather than a contract.
The measurement below is also what settles that the rule must not turn on which of the two words it reads: both are parks, and the `fix_review` word is the one most of them carry.
The rule itself, both probes, and every exclusion are covered without a real run by `tests/fm-crew-state.test.sh`.

Measured on 2026-08-30 against the installed no-mistakes v1.60.2 (eb4e379), over the three real parked gates captured from review rounds one through three of this branch's own validation run: one `awaiting_approval` and two `fix_review`.

The predicate checked against each captured `axi status` response was the pair of probes `nm_gate_status` uses, in its own order:

```sh
grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$'
grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,'
```

Every one of the three published a resolvable gate status word, and both probes matched on all three: each response carried the scalar `status:`/`state:` line form and the steps-table row form together.
So the unreadable shape drew no observation at all here, and it is modelled only by the defensive fixture `run_parked_scalar_gate_running` in `tests/fm-crew-state.test.sh`.
A later reader should re-run those two probes against a newer no-mistakes before relying on that, because a response shape that drops either form would move real parks into the never-absorbed exclusion without any test failing.

## Ask-user action row on a parked gate

This record supports the other half of that same gate-ownership rule, which appends the ownership token only when the gate's findings table carries a row whose `action` column is exactly `ask-user`.
That half is the structurally stricter of the two and the one that actually gates the absorb, because it depends on the table being present, on its header naming an `action` column, on the rows being indented under that header, and on the cell holding that exact value.
The rule itself and every way it can refuse are covered without a real run by `tests/fm-crew-state.test.sh`, but every fixture there hard-codes the table, so whether real output renders it that way is evidence rather than a contract.

Measured on 2026-08-30 against the installed no-mistakes v1.60.2 (eb4e379), built 2026-08-29.
The subject was five real `axi status` gate responses captured from this branch's own validation run, one per review round over review rounds one through five, covering one `awaiting_approval` gate and four `fix_review` gates.
The predicate checked was `nm_gate_has_ask_user_action` in `bin/fm-crew-state.sh`, its own awk run verbatim against each captured response rather than a copy here that would drift from it.

All five rendered their gate findings as a `findings[N]{id,severity,file,action,description}` table carrying a literal `action` column, with `ask-user` present as an exact cell value in that column, and the predicate returned its match token for all five.
The one-to-four split between the two gate words is the load-bearing figure here: an ownership rule admitting only `awaiting_approval` would have published its token for one of these five real parks and withheld it from the other four, so it could never have produced a `deciding` absorb for the shape those parks actually take.

This is evidence that this version renders the table this way, not proof that every version will.
A future response shape that drops the table, renames the column, or reports the finding count without a table would make the predicate return false, which moves a real park into the never-absorbed exclusion with no test failing, because every fixture in the suite hard-codes the table.
That failure runs in the same benign direction the record above states for the status word: the absorb simply does not fire, firstmate keeps getting the wake exactly as it does today, and nothing is silenced.
That benign direction is a property of the measured header shape rather than of the predicate.
`nm_gate_has_ask_user_action` locates the `action` column by name but reads its cell with a bare comma split that does not honour the quoting of the TOON table it is splitting, which is safe only while every column before `action` is comma-free, as it is in the measured `findings[N]{id,severity,file,action,description}` shape whose single free-text column is last.
A future header that places a quoted free-text column before `action` breaks that reading: a comma inside such a cell shifts the split, so a row carrying some other action can be read as `ask-user`, publishing the ownership token for a gate that has no ask-user row and absorbing a park that should have surfaced.
That is the one direction the safety asymmetry forbids, so a reader who meets such a header shape can no longer rely on the benign-direction claim above.

## Park clock on a parked run

This record supports the park-episode half of the parked detail in `bin/fm-crew-state.sh`: `nm_park_age_bounds` reads the `awaiting_agent: parked <duration>` line, and `nm_park_holds_current_status` compares it against the crew status file's mtime to decide whether the crew's record was written at the episode the run is sitting in now.
Three things about that line are evidence rather than contract - that it is rendered at all for a parked run, that its figure restarts per park episode, and how coarsely it is truncated - and the truncation is what the comparison's one-unit leniency is sized from.
The rule itself, both directions, and every way the line can be missing or unparseable are covered without a real run by `tests/fm-crew-state.test.sh`.

Measured on 2026-08-31 against the installed no-mistakes v1.60.2 (eb4e379), built 2026-08-29.
Nothing live was touched: `NM_HOME` pointed at a copy of the state database, and the copy's own `runs` row was moved into a parked state so the field would render.

```sh
no-mistakes axi status --run <run-id>
```

The row's `awaiting_agent_since` was set to a series of known offsets from the present, and every rendering the reader parses was produced:

```
      5 ->   awaiting_agent: parked 5s
     70 ->   awaiting_agent: parked 1m10s
   3725 ->   awaiting_agent: parked 1h2m
  45000 ->   awaiting_agent: parked 12h30m
  86399 ->   awaiting_agent: parked 23h59m
  90000 ->   awaiting_agent: parked 1d1h
 300000 ->   awaiting_agent: parked 3d11h
```

Four facts the reader depends on are visible here.
The figure is always TRUNCATED, never rounded: 300000 seconds is 3d11h20m and renders `3d11h`, so the true age is at least the published one and less than one further unit of the smallest rendered unit.
That smallest unit is named by the token's own trailing character, and it coarsens as the wait grows - seconds below an hour, minutes below a day, whole hours past a day - which is why the comparison is lenient by exactly one such unit and why the residual it leaves matters only past a day of waiting.
The field renders for both parked words, so it is available for the `fix_review` shape most escalation parks take and not only for the approval one:

```
awaiting_approval  ->   status: awaiting_approval   awaiting_agent: parked 12h30m
fix_review         ->   status: fix_review   awaiting_agent: parked 12h30m
```

Nothing else in the response carries the park's start: the API struct's own `awaiting_agent_since` field is not rendered by this surface, so the truncated duration is the only handle and its precision is the rule's precision.

Per-episode restart is not observable from a single response, so it is taken from the schema this version writes rather than from a rendering: the `runs` table's `awaiting_agent_since` column is set when a run stops for the agent and set back to `NULL` when the agent responds, with the elapsed time accumulated into a separate `parked_ms` column.
A run that has parked, been answered, and parked again therefore reports only the latest episode, which is exactly the property the comparison rests on.
A future version that kept the column across a response, or stopped rendering the line, would move real parks to the never-absorbed side rather than the absorbed one, because an unreadable clock reports no evidence.

## Forge probe for a monitoring ci step

This record supports the forge half of the stalled-run detection in `bin/fm-crew-state.sh`: the arm that settles a ci step which keeps logging while what it waits for cannot arrive.
Two external surfaces carry that arm, and field presence in an external CLI is evidence rather than a contract, so both are measured rather than assumed.
Every branch of the arm itself, including each way the forge can fail to answer, is covered without a network call by `tests/fm-crew-state.test.sh`.

### Step logs carry no timestamps

This is why the arm asks the forge rather than measuring repetition.
Measured 2026-08-30 against the installed no-mistakes v1.60.2.

The stored log is bare prose separated by blank lines:

```sh
head -c 200 ~/.no-mistakes/logs/<run-id>/ci.log | cat -A
```

```
monitoring CI for PR #368 (timeout: 168h0m0s)...$
$
issues detected: merge conflict - auto-fixing (attempt 1/3)...$
$
running agent to fix CI issues...$
```

The CLI's own view adds a header and quotes each line, and no time either:

```sh
no-mistakes axi logs --step ci --run <run-id>
```

```
step: ci
run: "<run-id>"
lines: 40 of 82 total (tail)
log[40]{line}:
  "fix already attempted for these issues, waiting for CI re-run..."
  ""
```

With no time attached to any line, "how long has this step been repeating itself" cannot be answered from the response the reader already pays for.
Answering it would mean comparing samples across polls, and every consumer calls `bin/fm-crew-state.sh` as a pure read.
The elapsed figure the budget uses lives in `active_steps`, recorded in the section above, and it measures silence only.

### The forge answers both questions in one query

Measured 2026-08-30 against gh 2.96.0.

```sh
gh pr view <pr-url> --json mergeable,statusCheckRollup \
  -q '((.mergeable // "UNKNOWN") + "\t" + ((.statusCheckRollup // []) | length | tostring))' | cat -A
```

```
UNKNOWN^I10$
```

Three facts the reader depends on are visible here.
Both fields are selectable on `gh pr view --json` (they appear in its own field list), so one query answers both questions and no second call is needed.
The projection returns exactly one tab-separated line, which is the whole parse.
And this capture is of a MERGED pull request, which reports `UNKNOWN` mergeability rather than a value: GitHub computes mergeability lazily and reports `UNKNOWN` whenever it has not, so `UNKNOWN` is a routine answer and never evidence of a conflict.
Only the definite `CONFLICTING` value escalates, and only while the step's own log is asking for a re-run of checks it has already seen: no-mistakes resolves its own merge conflicts, so a conflict it has not finished with is a non-event rather than a wake.
