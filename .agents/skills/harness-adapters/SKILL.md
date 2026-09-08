---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Routes to one verified per-harness reference file for claude, codex, opencode, pi, grok, and kimi, and carries the cross-harness contract, verified-harness list, effort precedence, and launch-profile axes directly.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
The captain may override that file at session start or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and any enabled crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`'s shared composer classifier (the one fleet-wide owner of the empty/dead-shell/pending decision, so a new harness's own idle composer is not misread as a dead shell), the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge in a new `references/<harness>.md` plus its row in the per-harness reference table below, registered in `docs/documentation-audiences.json` so `bin/fm-doc-audience-check.sh` keeps it classified.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Primary turn-end guard

The primary integrations for `claude`, `codex`, `opencode`, `pi`, and `grok` have empirically validated hook paths for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `grok` expose passive lifecycle callbacks for this purpose, so their tracked primary adapters force one bounded follow-up or resume when the shared predicate blocks.
Kimi is outside the primary turn-end guard scope, while `docs/turnend-guard.md` owns its separate guarded global hook for crew wake signals.
The exact hook files, commands, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
`docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc, the concise fact in the turn-end guard section of this router, and the relevant fact in that harness's reference file.

## Primary pre-arm (PreToolUse) seatbelt

The primary integrations for `claude`, `codex`, `opencode`, `pi`, and `grok` also have wired PreToolUse-equivalent hooks that deny a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly through PreToolUse hooks; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode` and `pi` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
The exact hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any watcher-arm PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.
## Primary delegation-shape guard

Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a primary-home PreToolUse guard that denies a delegation-SHAPED tool name.
Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.
`docs/subagent-guard.md` owns the full contract, the local deny-list recommendation, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.

Two verified facts worth pinning here.
The subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control.
`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

## Primary session-start nudge

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters invoke `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
The wrapper prints one canonically typed `session-start` instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
Full mechanics, scoping, and fail-open behavior live in `docs/sessionstart-nudge.md`.
`docs/verification/supervision.md` "Native session-start delivery" owns active dated commands, payloads, and evidence.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.
- `codex`: verified on 0.144.4; `.codex/hooks.json` receives `source=startup`, and wrapper stdout reaches model context.
- `opencode`: verified on 1.17.18; `session.created` plus `client.session.promptAsync` starts the nudge turn in the TUI, while `opencode run` remains fail-open headless.
- `pi`: verified native `session_start`; the existing primary extension handles `startup`, `new`, and `resume` and uses `pi.sendMessage` to inject context without racing a positional launch prompt.
- `grok`: the 0.2.103 project `SessionStart` event fires with `source=new`, but stdout does not reach model context; the tracked project hook remains fail-open, and a global token-guarded fallback requires a captain decision.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi uses the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions Pi auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, the concise fact in the watcher-supervision section of this router, and the relevant fact in that harness's reference file.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake.
Do not make the shell scripts parse or match natural-language dispatch rules.

Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback below.
Never replace an effort value supplied by either higher-precedence source.
Use the fallback only when neither the captain nor applicable standing configuration specifies effort.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
When a verified adapter lacks `xhigh`, cap the choice at its highest supported non-`max` level rather than omitting the intended effort silently.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

The supported launch-profile flags below are verified locally; each row records its evidence.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias, but firstmate's profile axis is reasoning effort. As of 0.2.99 the ceiling is `high`; both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-13 on Pi 0.80.6. `pi --help` advertises `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; `pi --print --model openai-codex/gpt-5.6-sol --thinking max 'Reply with exactly OK.'` completed successfully. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| kimi | `--model <model>` | none | Verified 2026-07-25 on Kimi Code CLI 0.29.1. |

### Model support discovery

Treat model and provider knowledge as current source-of-truth discovery, not as a permanent namespace or provider mapping.
Use the discovery surface in the current authenticated environment because supported and available models can change by version, account, and configuration.

| Harness | Authoritative discovery surface |
|---|---|
| claude | Open the current interactive session's `/model` picker; `claude --help` documents the accepted alias or full-model-name input shape. |
| codex | Open the current interactive session's `/model` picker. |
| opencode | Run `opencode models [provider]`, which lists available provider/model identifiers. |
| pi | Run `pi --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |
| grok | Run `grok models`, which lists the models available to the current Grok installation and account. |
| kimi | Run `kimi provider list --json`, which lists the current provider and model configuration. |

For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing from a name or prefix.
If those sources do not establish the relationship needed for dispatch, fail loudly and report the unresolved candidate.

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see [`references/grok.md`](references/grok.md) for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) handles this through the structural composer reader; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.
- kimi: `/<skill>`, for example `/no-mistakes`.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition that is specific to its TUI.

## Per-harness references

This router carries everything that is true across harnesses: harness resolution, the verified-harness list, effort precedence and the fallback, the launch-profile axes, model-support discovery, skill-invocation form, and the primary-session guard, nudge, and watcher contracts.
Everything specific to one harness lives in one file per harness, read only when that harness is actually in play.
Read the file named by the target's `harness=` value, or by `bin/fm-harness.sh` for firstmate's own session.
The table below is also the verified-adapter list: a harness with a row here is verified and dispatchable, and a harness with no row is not verified and must never be dispatched.

Every per-harness file carries the same core fact set for its harness: the verification date in its heading, the busy-pane signature, the exit command, the interrupt, the trust or startup dialog, and the harness's own turn-end guard fact.
So a question of the form "how do I interrupt X, exit X, accept the trust dialog for X, or recognize a busy X pane" is always answered by X's own file, with no need to know in advance which file holds it.
Two categories have an owner outside the reference files: a harness's env marker is owned by `bin/fm-harness.sh` and its launch and autonomy shape by `bin/fm-spawn.sh`, so read those owners when a reference file does not repeat the fact.
Coverage of the rest varies by harness: resume behavior, composer and submission quirks, and any stall or incident procedure appear only where they were verified empirically.
When one of those three is absent from a harness's file it means no fact was verified in that file, not that no verified fact exists anywhere, since a shared owner named elsewhere in this router may still hold one.
The reference file alone is therefore never the whole answer: check the shared owner this router names for that concern first, and where neither holds the fact, treat it as unverified rather than improvising a procedure.

| Harness | Reference | Harness-specific procedures it owns beyond the common fact set |
|---|---|---|
| claude | [`references/claude.md`](references/claude.md) | Usage-limit stall recovery (the only verified harness that presents a blocking usage-limit prompt), predicted-prompt ghost-text suppression, empty-composer blank-character handling, Stop-owned primary auto-arm. |
| codex | [`references/codex.md`](references/codex.md) | `$`-autocomplete popup settle, directory trust dialog, `codex resume`, bounded foreground watcher checkpoints. |
| opencode | [`references/opencode.md`](references/opencode.md) | Background self-upgrade and `--continue` relaunch, busy-queued Enter classification, passive `session.idle` guard. |
| pi | [`references/pi.md`](references/pi.md) | Project trust dialog, single-positional-argument brief rule, `turn_end` extension placement, `agent_settled` follow-up delivery. |
| grok | [`references/grok.md`](references/grok.md) | Slash-popup double-Enter requirement and its 2026-07-03 incident, TRUECOLOR placeholder styling, project-picker conditions, session resume via `--resume` or `-c`/`--continue`, global turn-end hook and trust model. |
| kimi | [`references/kimi.md`](references/kimi.md) | Launch-then-send readiness gating, silent pre-readiness drop, moon-phase spinner matching, guarded global turn-end hook. |

A fact that appears in exactly one harness's file is specific to that harness.
The per-harness facts this router does carry, including the ones in the turn-end guard, session-start nudge, and watcher-supervision sections, are deliberately concise rather than the full procedure, so never act on a per-harness procedure without opening its file.
