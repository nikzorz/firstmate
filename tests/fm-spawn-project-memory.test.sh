#!/usr/bin/env bash
# fm-spawn.sh must refuse a ship brief whose project-memory posture disagrees
# with the project's registered one (bin/fm-project-mode.sh --project-memory), in
# either direction, and must not check a brief that carries no project-memory
# section at all. The posture is the captain's decision about which file a
# project keeps its memory in, so a drifted brief would tell the worker to create
# the AGENTS.md the project forbids, or forbid the one it wants.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-memory)

# A home whose registry holds <registry-line>, and a project named keeper. The
# fake tmux fails, so a spawn that passes every agreement check stops at its
# first backend call without launching anything. Echoes "<home>|<project>|<fakebin>".
make_home() {  # <name> <registry-line>
  local name=$1 line=$2 home project fakebin
  home="$TMP_ROOT/$name/home"
  project="$TMP_ROOT/$name/projects/keeper"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$project" "$fakebin"
  git -C "$project" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$line" > "$home/data/projects.md"
  printf '%s\n' "$home|$project|$fakebin"
}

scaffold() {  # <home> <id> [<fm-brief args>...]
  local home=$1 id=$2 file content
  shift 2
  FM_HOME="$home" "$BRIEF" "$id" keeper --mode no-mistakes "$@" >/dev/null \
    || fail "$id: the brief did not scaffold"
  file="$home/data/$id/brief.md"
  content=$(cat "$file")
  content=${content//'{TASK}'/Keep the widget small.}
  content=${content//'{FIRSTMATE_SPEC}'/Ship it.}
  printf '%s\n' "$content" > "$file"
}

run_spawn() {  # <home> <project> <fakebin> <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$3:$PATH" \
    "$SPAWN" "$4" "$2" claude --mode no-mistakes --yolo off 2>&1
}

test_a_default_brief_on_a_keep_claude_md_project_is_refused() {
  local rec home project fakebin out status
  rec=$(make_home keeper-default "- keeper [no-mistakes +keep-claude-md] - fixture (added 2026-01-01)")
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  scaffold "$home" k1
  out=$(run_spawn "$home" "$project" "$fakebin" k1)
  status=$?
  [ "$status" -ne 0 ] || fail "a default-posture brief launched on a keep-claude-md project"
  assert_contains "$out" "project-memory mismatch for k1" "the refusal did not name the drift it caught"
  assert_contains "$out" "--project-memory keep-claude-md" "the refusal did not name the posture to re-scaffold with"
  assert_absent "$home/state/k1.meta" "the refused spawn still recorded a task"
  pass "a default-posture brief is refused on a keep-claude-md project"
}

test_an_agreeing_keep_claude_md_brief_passes_the_check() {
  local rec home project fakebin out
  rec=$(make_home keeper-agree "- keeper [no-mistakes +keep-claude-md] - fixture (added 2026-01-01)")
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  scaffold "$home" k2 --project-memory keep-claude-md
  assert_grep 'Project memory posture: keep-claude-md' "$home/data/k2/brief.md" \
    "the scaffold did not record the posture this check reads"
  out=$(run_spawn "$home" "$project" "$fakebin" k2)
  assert_not_contains "$out" "project-memory mismatch" "an agreeing brief and registry were reported as drift"
  pass "a keep-claude-md brief on a keep-claude-md project passes the agreement check"
}

test_a_keep_claude_md_brief_on_an_unmarked_project_is_refused() {
  local rec home project fakebin out status
  rec=$(make_home keeper-unmarked "- keeper [no-mistakes] - fixture (added 2026-01-01)")
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  scaffold "$home" k3 --project-memory keep-claude-md
  out=$(run_spawn "$home" "$project" "$fakebin" k3)
  status=$?
  [ "$status" -ne 0 ] || fail "a keep-claude-md brief launched on an unmarked project"
  assert_contains "$out" "project-memory mismatch for k3" "the refusal did not name the drift it caught"
  assert_absent "$home/state/k3.meta" "the refused spawn still recorded a task"
  pass "a keep-claude-md brief is refused on a project that keeps agents-md"
}

test_a_brief_without_a_project_memory_section_is_not_checked() {
  local rec home project fakebin out file
  rec=$(make_home keeper-promoted "- keeper [no-mistakes +keep-claude-md] - fixture (added 2026-01-01)")
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  scaffold "$home" k4
  file="$home/data/k4/brief.md"
  # A promoted scout's brief carries no project-memory section, and so no
  # instruction either way.
  awk '/^# Project memory$/ { skip = 1; next } skip && /^# / { skip = 0 } !skip' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  if grep -qx "# Project memory" "$file"; then fail "the fixture still carries a project-memory section"; fi
  out=$(run_spawn "$home" "$project" "$fakebin" k4)
  assert_not_contains "$out" "project-memory mismatch" "a brief with no project-memory section was checked"
  pass "a brief with no project-memory section is not checked"
}

test_a_default_brief_on_a_keep_claude_md_project_is_refused
test_an_agreeing_keep_claude_md_brief_passes_the_check
test_a_keep_claude_md_brief_on_an_unmarked_project_is_refused
test_a_brief_without_a_project_memory_section_is_not_checked

echo "# all fm-spawn-project-memory tests passed"
