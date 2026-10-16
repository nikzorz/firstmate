#!/usr/bin/env bash
# A fresh ship spawn runs bin/fm-spec-intent-check.sh on its brief and refuses,
# before any worktree or backend side effect, while a flagged spec bullet is
# neither cut nor justified or while an installed judge fails. A justified
# bullet launches, a host with no judge installed launches with a warning, and
# a scout brief is not checked.
# shellcheck disable=SC2016 # Backticks are literal Markdown in brief text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-spec-intent-check)

# The fake tmux logs every call so a refusal can be shown to precede any
# backend side effect; the pane reports the worktree so a launch can finish.
make_case() {  # <id> <brief-body>
  local id=$1 body=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$id"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  TMUX_LOG="$case_dir/tmux.log"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$id"
  printf '%s\n' "$body" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  FAKEBIN_DIR=$fakebin
}

run_spawn() {  # <id> <kind>
  local id=$1 kind=$2
  local -a kind_args=(--mode local-only --yolo off)
  [ "$kind" = scout ] && kind_args=(--scout)
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "${kind_args[@]}" 2>&1
}

brief() {  # <spec-body>
  printf '# Task\n## Captain'"'"'s intent\nFix the widget.\n\n## Firstmate spec\n%s\n\n# Definition of done\nDelivery contract: mode=local-only\n' "$1"
}

FALLBACK_SPEC=$(printf -- '- Edit `bin/widget.sh`.\n- Old widgets still work.')

expect_refused() {  # <id> <label> <expected-text>
  local id=$1 label=$2 expected=$3 out status
  out=$(run_spawn "$id" ship)
  status=$?
  expect_code 1 "$status" "$label should be refused: $out"
  assert_contains "$out" "$expected" "$label refusal does not explain itself"
  [ ! -s "$TMUX_LOG" ] || fail "$label refusal happened after a backend call: $(cat "$TMUX_LOG")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$label refusal left task metadata behind"
  [ -s "$HOME_DIR/data/$id/spec-intent-check.txt" ] || fail "$label left no check record"
}

expect_spawned() {  # <id> <kind> <label>
  local id=$1 kind=$2 label=$3 out status
  out=$(run_spawn "$id" "$kind")
  status=$?
  expect_code 0 "$status" "$label should spawn: $out"
  assert_contains "$out" "spawned $id" "$label did not spawn"
}

test_refuses_a_flagged_bullet() {
  make_case flagged "$(brief "$FALLBACK_SPEC")"
  FM_STUB_JUDGE_FLAG='Old widgets' expect_refused flagged "a flagged bullet" '[justified: <reason>]'
  pass "a ship whose spec carries an unjustified flagged bullet is refused before launch"
}

test_launches_a_justified_bullet() {
  make_case justified "$(brief "$FALLBACK_SPEC [justified: parked lanes use them]")"
  FM_STUB_JUDGE_FLAG='Old widgets' expect_spawned justified ship "a justified bullet"
  assert_contains "$(cat "$HOME_DIR/data/justified/spec-intent-check.txt")" '# Justified bullets' \
    "the record does not show the justified flag"
  pass "a ship whose flagged bullet is justified launches"
}

test_refuses_when_the_check_cannot_run() {
  make_case unjudged "$(brief "$FALLBACK_SPEC")"
  FM_STUB_JUDGE_EXIT=1 expect_refused unjudged "an unjudged spec" 'cannot launch until the spec-intent check'
  pass "a ship is refused when its spec cannot be judged"
}

test_launches_with_a_warning_when_no_judge_is_installed() {
  make_case nojudge "$(brief "$FALLBACK_SPEC")"
  local out status
  out=$(FM_SPEC_INTENT_CHECK_CLAUDE_BIN="$TMP_ROOT/no-such-claude" FM_STUB_JUDGE_FLAG='Old widgets' run_spawn nojudge ship)
  status=$?
  expect_code 0 "$status" "a host with no judge installed should still spawn: $out"
  assert_contains "$out" "spawned nojudge" "a host with no judge installed did not spawn"
  assert_contains "$out" 'warning: the spec-intent check of' "the spawn did not warn that the check was skipped"
  pass "a ship launches with a warning naming the skipped check when no judge is installed"
}

test_scout_is_not_checked() {
  make_case scout "$(brief "$FALLBACK_SPEC")"
  FM_STUB_JUDGE_FLAG='Old widgets' expect_spawned scout scout "a scout brief"
  [ ! -e "$HOME_DIR/data/scout/spec-intent-check.txt" ] || fail "a scout brief was checked"
  pass "a scout brief is not checked"
}

test_refuses_a_flagged_bullet
test_launches_a_justified_bullet
test_refuses_when_the_check_cannot_run
test_launches_with_a_warning_when_no_judge_is_installed
test_scout_is_not_checked

echo "# all fm-spawn-spec-intent-check tests passed"
