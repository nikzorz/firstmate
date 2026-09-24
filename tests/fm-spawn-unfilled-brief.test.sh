#!/usr/bin/env bash
# fm-spawn.sh must refuse a ship/scout brief that still carries an unfilled task
# placeholder, before any worktree or backend side effect, while accepting filled
# briefs, including ones whose prose names the placeholder. A line that is only
# {TASK} anywhere in the brief is unfilled: a legacy # Task body scaffolded that
# way, and a leftover line under otherwise filled intent, refuse the same as a
# fully unfilled brief.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-unfilled-brief)

# The fake tmux logs every call so a refusal can be shown to precede any
# backend side effect; the pane reports the worktree so a launch can finish.
make_case() {  # <name> <id> <brief-body>
  local name=$1 id=$2 body=$3 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  TMUX_LOG="$case_dir/tmux.log"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
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

PLACEHOLDER='{TASK}'
SPEC_PLACEHOLDER='{FIRSTMATE_SPEC}'

# A brief in the current two-subsection shape, with the delivery line a local-only
# ship records; a scout ignores that line.
two_part_brief() {  # <intent-body> <spec-body>
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\n%s\n\n# Definition of done\nDelivery contract: mode=local-only\n' "$1" "$2"
}

expect_refused() {  # <label> <kind> <brief-body>
  local label=$1 kind=$2 body=$3 id out status
  id=$label-$kind
  make_case "$label-$kind" "$id" "$body"
  out=$(run_spawn "$id" "$kind")
  status=$?
  expect_code 1 "$status" "$label: $kind spawn of an unfilled brief should be refused: $out"
  assert_contains "$out" "$HOME_DIR/data/$id/brief.md" "$label: $kind refusal did not name the brief path"
  [ ! -s "$TMUX_LOG" ] || fail "$label: $kind refusal happened after a backend call: $(cat "$TMUX_LOG")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$label: $kind refusal left task metadata behind"
}

expect_spawned() {  # <label> <kind> <brief-body>
  local label=$1 kind=$2 body=$3 id out status
  id=$label-$kind
  make_case "$label-$kind" "$id" "$body"
  out=$(run_spawn "$id" "$kind")
  status=$?
  expect_code 0 "$status" "$label: filled $kind brief should spawn: $out"
  assert_contains "$out" "spawned $id" "$label: filled $kind brief did not spawn"
}

test_refuses_a_fully_unfilled_brief() {
  local kind
  for kind in ship scout; do
    expect_refused unfilled "$kind" "$(two_part_brief "$PLACEHOLDER" "$SPEC_PLACEHOLDER")"
  done
  pass "ship and scout spawns refuse a brief whose intent and spec are still placeholders"
}

test_refuses_a_legacy_task_body_that_is_only_the_placeholder() {
  local kind
  for kind in ship scout; do
    expect_refused legacy "$kind" "$(printf '# Task\n%s\n\n# Rules\nnone\n' "$PLACEHOLDER")"
  done
  pass "ship and scout spawns refuse a legacy brief whose Task body is only the placeholder line"
}

test_refuses_a_leftover_placeholder_line_under_filled_intent() {
  local kind
  for kind in ship scout; do
    expect_refused leftover "$kind" "$(two_part_brief "$(printf 'Fix the widget.\n%s' "$PLACEHOLDER")" 'Do it well.')"
  done
  pass "ship and scout spawns refuse a leftover standalone placeholder line under filled intent"
}

test_accepts_a_filled_brief() {
  local kind
  for kind in ship scout; do
    expect_spawned filled "$kind" "$(two_part_brief 'Fix the widget.' 'Do it well.')"
  done
  pass "a filled brief spawns"
}

test_accepts_a_filled_brief_whose_prose_names_the_placeholder() {
  expect_spawned mention ship "$(two_part_brief 'Fix the widget.' "Keep the $PLACEHOLDER placeholder out of the scaffold's safety gate.")"
  pass "a filled brief whose prose names the placeholder spawns"
}

test_refuses_a_fully_unfilled_brief
test_refuses_a_legacy_task_body_that_is_only_the_placeholder
test_refuses_a_leftover_placeholder_line_under_filled_intent
test_accepts_a_filled_brief
test_accepts_a_filled_brief_whose_prose_names_the_placeholder

echo "# all fm-spawn-unfilled-brief tests passed"
