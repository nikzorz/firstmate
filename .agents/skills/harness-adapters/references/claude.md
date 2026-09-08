# claude (VERIFIED; busy signature re-verified 2026-07-25 on Claude Code 2.1.220)

Per-harness reference for the [`harness-adapters` router](../SKILL.md), which owns the cross-harness contract, the verified-harness list, effort precedence, and the launch-profile axes.

| Fact | Value |
|---|---|
| Busy-pane signature | Current turns match the harness-scoped `…[[:space:]]+\([0-9]+[smh]` shape after a rotating glyph and word, for example `✢ Pollinating… (16s · ...)`; legacy `esc to interrupt` remains accepted, while `Worked for 31s` is idle. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home; verify the brief started processing.

**Usage-limit stall (observed 2026-07-29).**
When the account usage limit is exhausted mid-turn, Claude Code stops on an interactive choice prompt: the question `What do you want to do?`, a numbered `Stop and wait for limit to reset` option, and an `Enter to confirm · Esc to cancel` row.
It waits for a human indefinitely, including long after the window resets, and the pane it leaves is idle with no error.
`bin/fm-crew-state.sh` reports that pane as the distinct `usage-limited` state with a `limit-window: reset|exhausted|unknown` verdict from `quota-axi`; `bin/fm-claude-limit-lib.sh` owns the signature and that read.
Recover with `FM_HOME=<this-firstmate-home> bin/fm-limit-resume.sh <id>`, which re-proves the live match, dismisses the prompt with one Escape, and resumes the crew with an instruction to re-read its own current state.
Add `--check` to get the verdict without sending anything.
It refuses rather than guessing whenever the pane, the match, or the quota window is uncertain, so treat a refusal as a stop-and-inspect result.
A still-exhausted window is not a wedge: the script records the wait with `paused:` and ordinary declared-pause handling takes over until the window clears.
That pause also carries when it ends, so the recheck lands shortly after the account window resets rather than up to `FM_PAUSE_RESURFACE_SECS` later; `docs/architecture.md` owns that scheduling mechanism, and a reset time the provider does not report simply leaves the fixed cadence in charge.
No other verified harness has been observed presenting a blocking usage-limit prompt, so nothing here applies to codex, opencode, pi, grok, or kimi.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on both ANSI-capable readers (tmux and herdr).
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md` "Composer and injection safety", with active captures in `docs/verification/runtime-backends.md`.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

Claude's idle, empty composer draws the prompt glyph followed by U+00A0, and the shared `fm_composer_ws_normalize` owner (`bin/fm-composer-lib.sh`) decides which characters count as blank on a composer row for every backend; regression coverage is `tests/fm-composer-ghost.test.sh` (`test_nbsp_padded_composer_is_empty`, `test_nbsp_padded_bare_shell_prompt_is_unknown`) and `tests/fm-composer-lib.test.sh` (`test_handled_unicode_space_set_reads_blank`, `test_zero_width_joiners_are_not_blank`).

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, Claude Code 2.1.219).**
This is separate from the per-task crewmate turn-end hook that `bin/fm-spawn.sh` enables (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.

