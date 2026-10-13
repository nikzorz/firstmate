#!/usr/bin/env bash
# Behavioral coverage for the visible startup-memory budget, its safe parser,
# accounting command, primary-to-secondmate convergence, and exact reread bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-startup-memory-budget)
BUDGET="$ROOT/bin/fm-startup-memory-budget.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
CONFIG_PUSH="$ROOT/bin/fm-config-push.sh"

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
fi
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'quota-axi 0.1.51 (fake)'
fi
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.6' ;;
  update:--help) printf '%s\n' '--archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1' ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0 ;;
  *list-windows*) printf '%s\n' fm-sm ;;
  *capture-pane*) printf '❯\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

new_bootstrap_world() {
  local name=$1 world root home
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Firstmate test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  printf '%s|%s\n' "$root" "$home"
}

run_bootstrap() {
  local root=$1 home=$2 fakebin=$3
  PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$BOOTSTRAP"
}

test_primary_bootstrap_materializes_visible_default() {
  local rec root home fakebin out second
  rec=$(new_bootstrap_world materialize)
  root=${rec%%|*}
  home=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/materialize")

  out=$(run_bootstrap "$root" "$home" "$fakebin")
  [ -z "$out" ] || fail "default materialization should stay quiet, got: $out"
  [ "$(<"$home/config/startup-memory-budget")" = 7500 ] \
    || fail "bootstrap did not materialize the visible 7500 default"
  [ "$(FM_HOME="$home" "$BUDGET" read)" = 7500 ] \
    || fail "read command did not expose the generated default"

  printf '321\n' > "$home/config/startup-memory-budget"
  run_bootstrap "$root" "$home" "$fakebin" >/dev/null
  [ "$(<"$home/config/startup-memory-budget")" = 321 ] \
    || fail "bootstrap replaced a valid captain-selected budget"

  second="$TMP_ROOT/materialize/secondmate"
  mkdir -p "$second/config" "$second/data" "$second/state"
  printf '%s\n' sm > "$second/.fm-secondmate-home"
  run_bootstrap "$root" "$second" "$fakebin" >/dev/null
  [ ! -e "$second/config/startup-memory-budget" ] \
    || fail "secondmate bootstrap created an independent budget instead of awaiting inheritance"
  pass "primary bootstrap materializes only the visible default and preserves valid captain choices"
}

expect_rejected_read() {
  local home=$1 expected=$2 out rc
  set +e
  out=$(FM_HOME="$home" "$BUDGET" read 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe budget unexpectedly parsed: $expected"
  assert_contains "$out" "$expected" "unsafe budget rejection was not specific"
}

test_safe_parser_rejects_ambiguous_and_unsafe_values() {
  local home outside
  home="$TMP_ROOT/parser-home"
  mkdir -p "$home/config" "$home/data"
  printf '42\n' > "$home/config/startup-memory-budget"
  [ "$(FM_HOME="$home" "$BUDGET" read)" = 42 ] || fail "valid positive decimal budget was rejected"

  printf '0\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '42\nextra\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '+42\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'

  outside="$TMP_ROOT/parser-outside"
  printf '77\n' > "$outside"
  rm -f "$home/config/startup-memory-budget"
  ln -s "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is symlinked'
  [ "$(<"$outside")" = 77 ] || fail "symlink rejection changed its external target"

  rm -f "$home/config/startup-memory-budget"
  ln "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is hardlinked'
  [ "$(<"$outside")" = 77 ] || fail "hardlink rejection changed its external source"

  rm -f "$home/config/startup-memory-budget"
  rm -rf "$home/config"
  ln -s "$TMP_ROOT/parser-config-target" "$home/config"
  mkdir -p "$TMP_ROOT/parser-config-target"
  printf '88\n' > "$TMP_ROOT/parser-config-target/startup-memory-budget"
  expect_rejected_read "$home" 'config directory is symlinked'
  pass "budget parser accepts one exact positive value and rejects malformed or unsafe inputs"
}

test_budget_accounting_reports_all_three_files_and_safe_failure() {
  local home out rc outside
  home="$TMP_ROOT/accounting-home"
  mkdir -p "$home/config" "$home/data"
  printf '10\n' > "$home/config/startup-memory-budget"
  printf 'abc\n' > "$home/data/captain.md"
  printf 'abcdef\n' > "$home/data/captain-shared.md"

  out=$(FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    "report did not name the stable estimator"
  assert_contains "$out" 'file=data/captain.md bytes=4 estimated_tokens=2 status=present' \
    "report did not account for captain memory"
  assert_contains "$out" 'file=data/captain-shared.md bytes=7 estimated_tokens=3 status=present' \
    "report did not account for shared memory"
  assert_contains "$out" 'file=data/learnings.md bytes=0 estimated_tokens=0 status=absent' \
    "report did not account for absent learnings"
  assert_contains "$out" 'total_estimated_tokens=5' "report total was not the sum of all three files"
  assert_contains "$out" 'budget_status=within-budget' "report did not classify the initial total"

  printf 'abcdefabcdefabcdefabcdef\n' > "$home/data/learnings.md"
  out=$(FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'budget_status=over-budget' "report did not surface an over-budget total"

  outside="$TMP_ROOT/accounting-outside"
  printf 'outside\n' > "$outside"
  rm -f "$home/data/captain.md"
  ln -s "$outside" "$home/data/captain.md"
  set +e
  out=$(FM_HOME="$home" "$BUDGET" report 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unsafe memory input should fail the accounting command"
  assert_contains "$out" 'memory file is not an ordinary regular file' \
    "accounting failure did not identify the unsafe memory file"
  [ "$(<"$outside")" = outside ] || fail "accounting failure changed a symlink target"
  pass "budget accounting sums the three startup files and reports safe failures"
}

new_entry_home() {  # <name>: one long and two short learnings entries
  local home="$TMP_ROOT/$1" long
  mkdir -p "$home/config" "$home/data"
  printf '7500\n' > "$home/config/startup-memory-budget"
  long=$(printf 'x%.0s' $(seq 1 600))
  {
    printf '%s\n' '<!-- memory tiers: see the stow skill -->' '## Gotchas' \
      '- A short entry. <!--a:2026-08-03-->'
    printf -- '- %s\n  continued on a second line. <!--a:2026-08-03-->\n' "$long"
    printf '%s\n' '' '## Tools' '- Another short entry. <!--a:2026-08-03-->'
  } > "$home/data/learnings.md"
  printf '%s\n' "$home"
}

test_report_lists_only_entries_over_the_size_largest_first() {
  local home out err rc expected
  home=$(new_entry_home entry-report)

  set +e
  out=$(FM_HOME="$home" "$BUDGET" report)
  rc=$?
  set -e
  expect_code 0 "$rc" "report should succeed while an entry is merely over the size"
  expected=$(printf '%s\n' \
    'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    'role=primary' \
    'effective_budget_tokens=7500' \
    'file=data/captain.md bytes=0 estimated_tokens=0 status=absent' \
    'file=data/captain-shared.md bytes=0 estimated_tokens=0 status=absent' \
    'file=data/learnings.md bytes=796 estimated_tokens=266 status=present' \
    'total_estimated_tokens=266' \
    'budget_status=within-budget' \
    'entry_size_limit_tokens=150' \
    'oversized_entries=1' \
    'oversized_entry=data/learnings.md line=4 bytes=653 estimated_tokens=218 heading=Gotchas')
  [ "$out" = "$expected" ] \
    || fail "report should keep its accounting lines and append only the long entry, got: $out"

  # A second, larger entry in another file sorts ahead of the first.
  printf -- '- %s\n' "$(printf 'y%.0s' $(seq 1 900))" > "$home/data/captain.md"
  out=$(FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'oversized_entries=2' "report did not count both oversized entries"
  expected=$(printf '%s\n' \
    'oversized_entry=data/captain.md line=1 bytes=903 estimated_tokens=301 heading=(none)' \
    'oversized_entry=data/learnings.md line=4 bytes=653 estimated_tokens=218 heading=Gotchas')
  [ "$(printf '%s\n' "$out" | tail -n 2)" = "$expected" ] \
    || fail "oversized entries were not listed largest first, got: $out"

  printf '0300\n' > "$home/config/startup-memory-entry-size"
  err="$TMP_ROOT/entry-report.err"
  set +e
  out=$(FM_HOME="$home" "$BUDGET" report 2>"$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "report should reject a malformed entry size as invalid input"
  [ -z "$out" ] || fail "report printed accounting lines from a rejected run, got: $out"
  assert_contains "$(<"$err")" 'invalid config/startup-memory-entry-size' \
    "report's malformed entry size rejection was not specific"
  pass "report appends the entries over the size, largest first, with a count"
}

test_entry_bounds_and_heading_text_follow_markdown() {
  local home out long
  home="$TMP_ROOT/entry-bounds"
  mkdir -p "$home/config" "$home/data"
  printf '7500\n' > "$home/config/startup-memory-budget"
  long=$(printf 'x%.0s' $(seq 1 600))
  {
    printf '%s\n' '## C#' '- short item' '' '```' "$long" '```' '' '- another'
    printf '%s\n' '- adjacent' '~~~' "$long" '~~~'
    printf '%s\n' '## Closed ##' '- fenced item' '  ```' "  $long" '  ```'
    printf -- '## F# \n- %s\n' "$long"
  } > "$home/data/learnings.md"

  set +e
  out=$(FM_HOME="$home" "$BUDGET" check)
  set -e
  assert_contains "$out" 'oversized_entries=2' \
    "a top-level fenced block was counted into the list item above it, got: $out"
  assert_contains "$out" 'line=14 bytes=629 estimated_tokens=210 heading=Closed' \
    "an indented fence was not counted into its item under the closed heading, got: $out"
  assert_contains "$out" 'line=19 bytes=603 estimated_tokens=201 heading=F#' \
    "a heading ending in # lost its last character, got: $out"
  pass "entries end at a top-level fence and headings keep a trailing # that closes nothing"
}

test_check_mode_fails_only_while_an_entry_is_over_the_size() {
  local home out rc
  home=$(new_entry_home entry-check)

  set +e
  out=$(FM_HOME="$home" "$BUDGET" check)
  rc=$?
  set -e
  expect_code 1 "$rc" "check should fail while an entry is over the size"
  assert_contains "$out" 'heading=Gotchas' "check did not name the oversized entry"

  # The setting moves the size: the same fixture passes under a larger one.
  printf '300\n' > "$home/config/startup-memory-entry-size"
  out=$(FM_HOME="$home" "$BUDGET" check)
  assert_contains "$out" 'entry_size_limit_tokens=300' "check did not read the configured size"
  assert_contains "$out" 'oversized_entries=0' "check listed an entry within the configured size"

  printf '0300\n' > "$home/config/startup-memory-entry-size"
  set +e
  out=$(FM_HOME="$home" "$BUDGET" check 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a malformed entry size should be an error, not a default"
  assert_contains "$out" 'invalid config/startup-memory-entry-size' \
    "malformed entry size rejection was not specific"
  rm -f "$home/config/startup-memory-entry-size"

  printf '%s\n' '## Gotchas' '- A short entry.' '- The long entry, shortened.' \
    '## Tools' '- Another short entry.' > "$home/data/learnings.md"
  out=$(FM_HOME="$home" "$BUDGET" check)
  assert_contains "$out" 'oversized_entries=0' "check listed an entry after it was shortened"
  pass "check exits 1 on an oversized entry and 0 once it is shortened or the size is raised"
}

new_propagation_world() {
  local world=$1 root="$1/root" home="$1/home" sm="$1/sm" head
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Firstmate test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  head=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm" "$head"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  mkdir -p "$sm/config" "$sm/data" "$sm/state" "$sm/projects"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  printf '%s|%s|%s\n' "$root" "$home" "$sm"
}

latest_reread_instruction() {
  local home=$1 state path latest=
  state=$(cd "$home/state" && pwd -P) || return 1
  for path in "$state"/.fm-inherited-config-reread.*; do
    case "$path" in *.pending) continue ;; esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest=$path
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

inbox_record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

run_config_push() {
  local root=$1 home=$2 fakebin=$3 log=$4
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_LOG="$log" "$CONFIG_PUSH"
}

test_primary_budget_converges_with_exact_reread_and_safe_failures() {
  local world="$TMP_ROOT/propagation" rec root home sm fakebin log out rc instruction expected outside
  mkdir -p "$world"
  rec=$(new_propagation_world "$world")
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$world")
  log="$world/tmux.log"

  printf '321\n' > "$home/config/startup-memory-budget"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'startup-memory-budget: pushed' \
    "config push did not report the new budget as inherited"
  [ "$(<"$sm/config/startup-memory-budget")" = 321 ] \
    || fail "secondmate did not receive the primary budget bytes"
  instruction=$(latest_reread_instruction "$sm") || fail "budget propagation did not publish a reread instruction"
  expected=$(printf '%s\n\n%s\n%s\n321\n%s' \
    'These inherited config files changed. Re-read and apply their exact contents at every future intake. They are defaults/rules and do not remove your judgment to choose differently when warranted.' \
    'config/startup-memory-budget' \
    '-----BEGIN config/startup-memory-budget-----' \
    '-----END config/startup-memory-budget-----')
  [ "$(<"$instruction")" = "$expected" ] \
    || fail "budget reread payload was not the exact destination bytes"
  assert_contains "$(inbox_record_body "$home/state/sm.inbox/001.msg")" "CONFIG_REREAD: $instruction" \
    "budget propagation did not enqueue the pointer to its exact reread generation"
  assert_contains "$(<"$log")" "Firstmate instruction waiting: list " \
    "budget propagation did not ring the durable inbox doorbell"
  assert_contains "$(<"$log")" "'sm.inbox' steering inbox" \
    "budget propagation doorbell did not identify the durable inbox"

  outside="$world/unsafe-budget"
  printf '555\n' > "$outside"
  rm -f "$sm/config/startup-memory-budget"
  ln "$outside" "$sm/config/startup-memory-budget"
  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe inherited destination should stop propagation"
  assert_contains "$out" 'startup-memory-budget: error - unsafe or invalid destination: file is hardlinked' \
    "unsafe inherited destination did not produce a concrete propagation error"
  [ "$(<"$outside")" = 555 ] || fail "unsafe destination handling changed its hardlinked source"
  rm -f "$sm/config/startup-memory-budget"
  run_config_push "$root" "$home" "$fakebin" "$log" >/dev/null
  [ "$(<"$sm/config/startup-memory-budget")" = 321 ] \
    || fail "safe retry did not restore the converged primary budget"

  rm -f "$home/config/startup-memory-budget"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'startup-memory-budget: pushed - mirrored primary absence' \
    "primary absence was not reported as a converging removal"
  [ ! -e "$sm/config/startup-memory-budget" ] \
    || fail "primary absence did not remove the inherited budget"
  instruction=$(latest_reread_instruction "$sm") || fail "budget absence did not publish a reread instruction"
  assert_contains "$(<"$instruction")" $'-----BEGIN config/startup-memory-budget-----\nABSENT\n-----END config/startup-memory-budget-----' \
    "budget absence reread did not use the explicit ABSENT payload"

  rm -f "$sm/config/startup-memory-budget"
  printf '555\n' > "$outside"
  ln -s "$outside" "$home/config/startup-memory-budget"
  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe primary budget should stop propagation"
  assert_contains "$out" 'startup-memory-budget: error - unsafe or invalid primary source: file is symlinked' \
    "unsafe primary budget did not produce a concrete propagation error"
  [ ! -e "$sm/config/startup-memory-budget" ] \
    || fail "unsafe primary budget changed the converged secondmate copy"
  [ "$(<"$outside")" = 555 ] || fail "unsafe primary budget handling changed its symlink target"
  pass "budget propagation converges through config push with exact rereads, absence, and safe rejection"
}

test_primary_bootstrap_materializes_visible_default
test_safe_parser_rejects_ambiguous_and_unsafe_values
test_budget_accounting_reports_all_three_files_and_safe_failure
test_report_lists_only_entries_over_the_size_largest_first
test_entry_bounds_and_heading_text_follow_markdown
test_check_mode_fails_only_while_an_entry_is_over_the_size
test_primary_budget_converges_with_exact_reread_and_safe_failures

echo '# all fm-startup-memory-budget tests passed'
