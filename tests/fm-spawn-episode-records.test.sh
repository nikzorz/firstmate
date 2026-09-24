#!/usr/bin/env bash
# Regression test for the claim-time clear in bin/fm-spawn.sh: a task that
# reuses a previous task's id lands on the same endpoint, so the watcher key and
# the id-keyed daemon markers it is about to occupy may still hold a dead task's
# suppression and escalation state. Spawn must start the new task with none of
# it, whether the previous occupant was torn down or simply vanished, and must
# leave a live neighbor's records alone. A relaunch continues the same task on
# its own recorded endpoint, so it claims nothing and is not exercised here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-episode-records)

make_spawn_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_reused_id_inherits_no_supervision_records() {
  local case_dir home proj wt fakebin id s out status f
  case_dir="$TMP_ROOT/reuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=reused-z1
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '# Task\n## Captain'"'"'s intent\nFix the widget.\n\n## Firstmate spec\nKeep it small.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' \
    > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-reuse"
  s="$home/state"
  touch "$s/.last-watcher-beat"

  # What the previous occupant of this id left behind: a wedge already escalated
  # twice, a stale suppressor, a declared pause and its throttles, an advancing
  # absorb count, the pane signature whose mtime is its idle clock, and the
  # daemon's id-keyed markers.
  for f in .wedge-escalations .stale .stale-since .churn-since .paused .paused-rechecked \
    .paused-resurfaced .waiting-resurfaced .writing-since .writing-resurfaced .dead-reported \
    .advancing-absorbs .advancing-resurfaced .hash .count .herdr-escalated; do
    printf '2\n' > "$s/$f-firstmate_fm-$id"
  done
  for f in .subsuper-stale .subsuper-paused .subsuper-pause-until-due .subsuper-advancing \
    .subsuper-seen-status .hb-surfaced; do
    printf '2\n' > "$s/$f-$id"
  done
  printf 'sig\n' > "$s/.seen-${id}_status"
  # A live neighbor whose key shares a hyphenated suffix.
  printf '2\n' > "$s/.wedge-escalations-firstmate_sub-fm-$id"
  printf '1\n' > "$s/.subsuper-stale-sub-$id"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$s" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn failed: $out"
  assert_grep "window=firstmate:fm-$id" "$s/$id.meta" "spawn claimed a different endpoint than the seeded key"

  for f in "$s"/.*"fm-$id" "$s"/.*"-$id" "$s/.seen-${id}_status"; do
    case "$f" in
      *sub-fm-"$id"|*sub-"$id") continue ;;
    esac
    [ -e "$f" ] && fail "the new task inherited ${f##*/} from the previous occupant of its id"
  done
  assert_present "$s/.wedge-escalations-firstmate_sub-fm-$id" \
    "a live neighbor's escalation count was cleared as collateral"
  assert_present "$s/.subsuper-stale-sub-$id" \
    "a live neighbor's daemon marker was cleared as collateral"
  assert_present "$s/.last-watcher-beat" "a home-scoped watcher record was cleared"
  pass "a task reusing an id starts with none of the previous occupant's supervision records"
}

test_reused_id_inherits_no_supervision_records

echo "# all fm-spawn-episode-records tests passed"
