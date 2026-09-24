#!/usr/bin/env bash
# fm-spawn.sh must refuse a ship/scout brief that still carries the scaffold's
# standalone {TASK} placeholder line, before any worktree or backend side effect,
# while accepting filled briefs, including ones whose prose names the placeholder.
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

run_spawn() {  # <id> [extra args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

PLACEHOLDER='{TASK}'

test_refuses_unfilled_brief() {
  local kind id out status
  for kind in ship scout; do
    id=unfilled-$kind-u1
    make_case "unfilled-$kind" "$id" "$(printf '# Task\n%s\n\n# Rules\nnone\n' "$PLACEHOLDER")"
    if [ "$kind" = scout ]; then out=$(run_spawn "$id" --scout); else out=$(run_spawn "$id"); fi
    status=$?
    expect_code 1 "$status" "$kind spawn of an unfilled brief should be refused"
    assert_contains "$out" "$HOME_DIR/data/$id/brief.md" "refusal did not name the brief path"
    [ ! -s "$TMUX_LOG" ] || fail "$kind refusal happened after a backend call: $(cat "$TMUX_LOG")"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$kind refusal left task metadata behind"
  done
  pass "ship and scout spawns refuse a brief with the standalone placeholder line"
}

test_accepts_filled_brief() {
  local id=filled-f1 out status
  make_case filled "$id" "$(printf '# Task\nFix the widget.\n')"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "filled brief should spawn: $out"
  assert_contains "$out" "spawned $id" "filled brief did not spawn"
  pass "a filled brief spawns"
}

test_accepts_filled_brief_mentioning_placeholder() {
  local id=mention-m1 out status
  make_case mention "$id" "$(printf '# Task\nFix the widget.\n\n# Note\nThis scaffold cannot inspect the text that fills the %s placeholder.\n' "$PLACEHOLDER")"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "brief naming the placeholder in prose should spawn: $out"
  assert_contains "$out" "spawned $id" "prose mention was wrongly refused"
  pass "a filled brief whose prose names the placeholder spawns"
}

test_refuses_unfilled_brief
test_accepts_filled_brief
test_accepts_filled_brief_mentioning_placeholder

echo "# all fm-spawn-unfilled-brief tests passed"
