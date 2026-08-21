#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# A worker idling between no-mistakes gates has a quiet pane, so an undeclared
# wait is aged into a repeating possible-wedge escalation. The instruction has to
# sit at the pipeline handoff itself; the passive definition in Rules is not enough.
test_no_mistakes_dod_requires_declared_pause_before_pipeline_handoff() {
  local home id brief
  home="$TMP_ROOT/pipeline-pause-home"
  mkdir -p "$home/data"
  id="brief-pipeline-pause-e1"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
    "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Whenever you hand control back to the pipeline for a long stretch - a fix round, a re-review, a long test step - first append \`awaiting: {what you are waiting on}\`" "$brief" \
    "no-mistakes DOD lost the declared pause at the pipeline handoff"
  assert_grep "keeps firstmate from reading your quiet pane as a possible wedge" "$brief" \
    "no-mistakes DOD lost the reason the pause declaration matters"
  # The lifecycle itself belongs to shared rule 4 so every mode inherits it; the
  # DOD only points at it. Restating it here would let the two copies drift.
  assert_grep "then open and close that wait exactly as rule 4 requires" "$brief" \
    "no-mistakes DOD lost the pointer to rule 4's pause lifecycle"
  assert_grep "a fix round, re-review, or long test step you handed back to the no-mistakes pipeline" "$brief" \
    "no-mistakes Rules did not name the pipeline wait as a pause case"

  # The faster paths run no pipeline, so their pause examples must not name one.
  write_registry "$home"
  id="brief-pipeline-pause-e2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "a long test or build run you are waiting out" "$brief" \
    "direct-PR brief lost a delivery-appropriate pause example"
  assert_no_grep "handed back to the no-mistakes pipeline" "$brief" \
    "direct-PR brief named a pipeline it never runs"
  pass "fm-brief.sh: no-mistakes briefs declare a pause before each pipeline handoff"
}

# The four crewmate variants - the three ship delivery modes plus scout - share
# most of one contract, and several tests need the whole set. Scaffold one brief
# per variant under <home> with the given id prefix and pause verb, and echo one
# `<id>:<proj>:<kind>:<brief-path>` line per variant for the caller to iterate.
scaffold_every_crewmate_variant() {
  local home=$1 prefix=$2 verb=$3
  local entry id proj kind
  write_registry "$home"
  for entry in "1:no-registry-proj:ship" "2:direct-proj:ship" "3:local-proj:ship" "4:scout-proj:scout"; do
    id="$prefix${entry%%:*}"
    proj=${entry#*:}
    proj=${proj%%:*}
    kind=${entry##*:}
    if [ "$kind" = scout ]; then
      FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB="$verb" \
        "$ROOT/bin/fm-brief.sh" "$id" "$proj" --scout >/dev/null 2>&1
    else
      FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB="$verb" \
        "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    fi
    printf '%s:%s:%s:%s\n' "$id" "$proj" "$kind" "$home/data/$id/brief.md"
  done
}

# A declared pause nobody closes stays the crew's last status event, so a worker
# that later genuinely stalls is read as still waiting and gets the hour-long
# recheck instead of the 240s wedge path. `working:` is what every consumer
# already treats as ending a pause (bin/fm-classify-lib.sh map_log_state and the
# open-activities fold). The lifecycle is one shared block rendered into rule 4 of
# EVERY crewmate brief - the faster paths are nudged toward a pause by their own
# "long test or build run" example and never see the pipeline DOD, and a scout is
# taught the pause verb too, so each of them needs the whole lifecycle.
test_every_crewmate_brief_carries_the_whole_pause_lifecycle() {
  local home variants id proj kind brief
  home="$TMP_ROOT/pause-lifecycle-home"
  variants=$(scaffold_every_crewmate_variant "$home" brief-pause-life-f awaiting)

  while IFS=: read -r id proj kind brief; do
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "A \`awaiting:\` line is nonterminal: do not end the turn after it" "$brief" \
      "$id: brief lost the nonterminal guard on the pause line"
    assert_no_grep "nonterminal too" "$brief" \
      "$id: shared pause block back-references a sentence its variant may not have"
    assert_grep "close the wait with" "$brief" \
      "$id: brief lost the instruction to close a declared pause"
    assert_grep "\`working: {what you are doing next}\` the moment it ends" "$brief" \
      "$id: brief lost the verb that actually ends a declared pause"
    assert_grep "not an FYI progress line" "$brief" \
      "$id: brief did not reconcile closing a pause with rule 4's no-FYI-lines bar"
    assert_grep "a \`awaiting:\` line left standing keeps firstmate on the" "$brief" \
      "$id: brief lost why a standing pause is dangerous"
    assert_grep "Use \`blocked:\` when you are stuck and need help." "$brief" \
      "$id: brief lost the paused-versus-blocked distinction"
    # A scout has no branch, no push, and no PR, so it inherits the lifecycle
    # without the handoff sentence, which would name an impossible wait.
    if [ "$kind" = scout ]; then
      assert_no_grep "hand control back to the pipeline" "$brief" \
        "$id: scout brief named a pipeline handoff it can never make"
      assert_no_grep "handed back to the no-mistakes pipeline" "$brief" \
        "$id: scout brief named a pipeline wait it can never have"
    fi
  done <<< "$variants"
  pass "fm-brief.sh: every crewmate brief carries the full pause lifecycle"
}

# The firstmate-codexapp skill does not excerpt this contract into a Codex Desktop
# thread; it hands the worker this brief's absolute path and tells it to read the
# whole file. Excerpting was tried and abandoned - every boundary left the brief's
# own cross-references dangling on the far side of it - so what matters now is that
# the file being pointed at is genuinely self-contained. A Desktop worker has no
# second source: whatever is missing here is missing from its whole task.
test_every_crewmate_brief_is_complete_for_a_pointed_worker() {
  local home variants id proj kind brief
  home="$TMP_ROOT/pointed-worker-home"
  variants=$(scaffold_every_crewmate_variant "$home" brief-pointed-g paused)

  while IFS=: read -r id proj kind brief; do
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "$home/state/$id.status" "$brief" \
      "$id: brief lacks the absolute status path a pointed worker cannot infer"
    assert_grep "4. Report status by appending one line:" "$brief" \
      "$id: brief lost the status protocol rule"
    assert_grep "States: working, needs-decision, blocked, paused, done, failed." "$brief" \
      "$id: brief lost the state list"
    assert_grep "close the wait with" "$brief" \
      "$id: brief lost the pause lifecycle rule 4 owns"
    assert_grep "5. If you hit the same obstacle twice" "$brief" \
      "$id: brief lost the repeated-obstacle rule"
    assert_grep "6. If a decision belongs" "$brief" \
      "$id: brief lost the escalation rule the definition of done refers to"
    # Rule 6 is the only place a worker is taught to CLOSE a decision or blocker
    # it opened; without it a standing needs-decision masks later events exactly
    # as a standing pause would.
    assert_grep "append \`resolved: {how it was decided or unblocked}\`" "$brief" \
      "$id: brief lost rule 6's closure for a decision or blocker it opens"
    assert_grep "[key=<slug>]" "$brief" \
      "$id: brief lost the correlation key that ties a closure to what it opened"
    assert_grep "7. Never stop, restart, or update the shared" "$brief" \
      "$id: brief lost the shared-daemon rule"
    assert_grep "# Definition of done" "$brief" \
      "$id: brief lost the done gate a pointed worker has no other source for"
    case "$proj" in
      direct-proj)
        assert_grep "This project ships **direct-PR**" "$brief" \
          "$id: brief lost the delivery mode its done gate belongs to"
        assert_grep "push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\`" "$brief" \
          "$id: a direct-PR worker would be left thinking it is finished at a local commit"
        ;;
      local-proj)
        assert_grep "Keep your branch a clean fast-forward onto the current default branch" "$brief" \
          "$id: brief lost the local-only fast-forward rebase requirement"
        assert_grep "append \`done: ready in branch fm/$id\`" "$brief" \
          "$id: brief lost the local-only ready-branch report"
        ;;
      scout-proj)
        assert_grep "$home/data/$id/report.md" "$brief" \
          "$id: brief lost the scout report deliverable"
        assert_no_grep "committed on your branch" "$brief" \
          "$id: a scout would be told to commit on a branch it never creates"
        ;;
      *)
        assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
          "$id: brief lost the no-mistakes pipeline handoff"
        ;;
    esac
  done <<< "$variants"
  pass "fm-brief.sh: every crewmate brief stands alone for a worker pointed at its path"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

# A project whose captain decision keeps CLAUDE.md as the real file must not be
# handled by dropping the default instruction: the scaffold has to ship the
# prohibition in its place, or the worker is still told to create an AGENTS.md.
# The registry marker is +keep-claude-md (bin/fm-project-mode.sh); data/projects.md
# is gitignored, so the unmarked default must stay exactly what it was.
test_keep_claude_md_project_gets_prohibition_not_omission() {
  local home id brief default_brief
  home="$TMP_ROOT/keep-claude-md-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- keeper [no-mistakes +keep-claude-md] - fixture keeping CLAUDE.md (added 2026-08-21)
- direct-keeper [direct-PR +yolo +keep-claude-md] - fixture with every flag (added 2026-08-21)
- plain-proj [no-mistakes] - fixture without the marker (added 2026-08-21)
EOF

  for id_proj in "brief-keep-claude-g1:keeper" "brief-keep-claude-g2:direct-keeper"; do
    id=${id_proj%%:*}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${id_proj##*:}" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "This project keeps its project memory in \`CLAUDE.md\` as the real file." "$brief" \
      "$id: keep-claude-md brief lost the project-memory prohibition"
    assert_grep "Do NOT create an \`AGENTS.md\` here" "$brief" \
      "$id: keep-claude-md brief did not forbid creating AGENTS.md"
    assert_no_grep "fm-ensure-agents-md.sh .\` in the worktree" "$brief" \
      "$id: keep-claude-md brief still instructs the worker to run the helper"
  done

  # The marker must not leak into the delivery mode or autonomy posture, and a
  # bracket holding only flags still resolves the default mode.
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" direct-keeper)" = "direct-PR on" ] \
    || fail "+keep-claude-md changed the resolved delivery mode or yolo posture"
  printf '%s\n' '- flags-only [+keep-claude-md] - fixture with no mode word (added 2026-08-21)' \
    >> "$home/data/projects.md"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" flags-only)" = "no-mistakes off" ] \
    || fail "a flags-only bracket was read as a delivery mode"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --project-memory flags-only)" = "keep-claude-md" ] \
    || fail "--project-memory did not read a flags-only bracket"

  # data/projects.md is gitignored, so every absent-registry path must answer with
  # the pre-existing behavior rather than a missing-value error.
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --project-memory plain-proj)" = "agents-md" ] \
    || fail "--project-memory did not default an unmarked project to agents-md"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --project-memory absent-proj 2>/dev/null)" = "agents-md" ] \
    || fail "--project-memory did not default an unregistered project to agents-md"
  [ "$(FM_HOME="$TMP_ROOT/no-registry-home" "$ROOT/bin/fm-project-mode.sh" --project-memory any 2>/dev/null)" = "agents-md" ] \
    || fail "--project-memory did not default a missing registry to agents-md"

  # Unmarked projects keep the pre-existing instruction verbatim.
  id="brief-keep-claude-g3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" plain-proj >/dev/null 2>&1
  default_brief="$home/data/$id/brief.md"
  assert_grep "run \`$ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree" "$default_brief" \
    "unmarked project lost the default ensure-agents-md instruction"
  assert_no_grep "Do NOT create an" "$default_brief" \
    "unmarked project inherited the keep-claude-md prohibition"
  pass "fm-brief.sh: +keep-claude-md replaces the ensure-agents-md instruction with its prohibition"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_dod_requires_declared_pause_before_pipeline_handoff
test_every_crewmate_brief_carries_the_whole_pause_lifecycle
test_every_crewmate_brief_is_complete_for_a_pointed_worker
test_ship_project_memory_wording
test_keep_claude_md_project_gets_prohibition_not_omission
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
