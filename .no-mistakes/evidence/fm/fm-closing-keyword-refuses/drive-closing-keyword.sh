#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh in a disposable home and state directory.
# The forge CLIs (gh, gh-axi) are the test suite's stubs; tasks-axi and jq are real.
set -u
WT=$1
HELPERS=$(mktemp "${TMPDIR:-/tmp}/fm-ck-helpers.XXXXXX")
sed -e '/^test_[a-z0-9_]*$/d' \
    -e "s|\"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|\"$WT/tests/lib.sh\"|" \
    "$WT/tests/fm-pr-merge.test.sh" > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"
rm -f "$HELPERS"
I7=$ISSUE_7; I14=$ISSUE_14; N=0; FAILS=0

# Args: title expect-rc pr-body title-url-or-empty flags -- task-body-line...
scenario() {
  local title=$1 want=$2 body=$3 turl=$4 flags=$5 rc c; shift 5
  N=$((N+1)); c=$(make_issue_case "live-$N" "$(printf '%040d' "$N")" "$body")
  add_task_row_with_body "$c" "$turl" "$@"
  [ -z "${PRESEED:-}" ] || printf '%s\n' "$PRESEED" >> "$c/state/task-x1.meta"
  # shellcheck disable=SC2086
  run_pr_merge "$c" task-x1 "https://github.com/example/repo/pull/$((60+N))" $flags > "$c/stdout" 2> "$c/stderr"; rc=$?
  echo "=== $N. $title"
  echo "task row:"; sed -n '2,/^$/p' "$c/home/data/backlog.md" | sed '/^$/d; s/^/    /'
  echo "PR body: $body"
  echo "\$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/$((60+N)) $flags"
  echo "exit: $rc (expected $want)"
  echo "stderr:"; grep -i 'clos\|owned\|issue' "$c/stderr" | sed 's/^/    /'
  echo "stdout:"; sed 's/^/    /' "$c/stdout"
  echo "forge merge calls: $(grep -c '^pr merge' "$c/gh.log")"
  echo "override lines in task record:"; grep -n '^closing_keyword_override=\|^pr=' "$c/state/task-x1.meta" | sed 's/^/    /'
  [ "$rc" -eq "$want" ] || { FAILS=$((FAILS+1)); echo "!!! UNEXPECTED EXIT"; }
  LAST=$c; LAST_RC=$rc; echo
}
merged() { [ "$(grep -c '^pr merge' "$LAST/gh.log")" -eq "$1" ] || { FAILS=$((FAILS+1)); echo "!!! merge-call count is not $1 in scenario $N"; }; }
says() { grep -q -- "$1" "$LAST/stderr" || { FAILS=$((FAILS+1)); echo "!!! scenario $N stderr lacks: $1"; }; }
silent() { ! grep -q -- "$1" "$LAST/stderr" || { FAILS=$((FAILS+1)); echo "!!! scenario $N stderr has: $1"; }; }

scenario "owned issue, body has no closing keyword -> refused" 1 'Fixes the thing. Part of #7' '' '' 'Mode no-mistakes.' "Owns issue: $I7"
merged 0; says 'directly before the reference: Closes #7'; says 'pass --no-closing-keyword'; says 'nothing was merged'
NEEDED=$(sed -n 's/.*directly before the reference: //p' "$LAST/stderr")
scenario "round trip: the exact line the refusal printed, added to the body -> merges" 0 "Fixes the thing.
$NEEDED" '' '' 'Mode no-mistakes.' "Owns issue: $I7"
merged 1; silent 'does not close'
for b in 'closes #7' 'FIXED: #7' 'Resolves example/repo#7' "close $I7" 'This (fixes #7).'; do
  scenario "keyword directly before the owned issue ($b) -> merges" 0 "$b" '' '' "Owns issue: $I7"; merged 1; silent 'does not close'
done
for b in 'Close issues #8 and #7' 'Closes #70' 'Closes #7x' 'Closes other/repo#7' 'Closes # 7' 'Closes https://github.com/example/repo/issues/71' 'Closes https://github.com/example/repo/pull/7' 'Encloses #7' 'Closes #14' ''; do
  scenario "adversarial: near-miss body ($b) -> still refused" 1 "$b" '' '' "Owns issue: $I7"; merged 0; says 'Closes #7'
done
scenario "adversarial: owned issue in another repository, bare #7 does not count -> refused, line names owner/repo#7" 1 'Closes #7' '' '' 'Owns issue: https://github.com/other/thing/issues/7'
merged 0; says 'Closes other/thing#7'
scenario "adversarial: flag after -- is a forge argument, not the override -> still refused" 1 'Part of #7' '' '-- --no-closing-keyword' "Owns issue: $I7"; merged 0
scenario "--no-closing-keyword on a stage PR -> merges, override recorded with PR URL ahead of pr=" 0 'Part of #7' '' '--no-closing-keyword' "Owns issue: $I7"
merged 1; says 'merging anyway under --no-closing-keyword'
grep -qxF "closing_keyword_override=https://github.com/example/repo/pull/$((60+N)) $I7" "$LAST/state/task-x1.meta" || { FAILS=$((FAILS+1)); echo '!!! override not recorded'; }
PRESEED="closing_keyword_override=https://github.com/example/repo/pull/40 $I7"
scenario "final PR after a stage override, body closes the issue, no flag -> merges, earlier line kept, none added" 0 'Closes #7' '' '' "Owns issue: $I7"
merged 1; [ "$(grep -c '^closing_keyword_override=' "$LAST/state/task-x1.meta")" -eq 1 ] || { FAILS=$((FAILS+1)); echo '!!! override line count changed'; }
scenario "second stage override -> both override lines on record" 0 'Part of #7' '' '--no-closing-keyword' "Owns issue: $I7"
merged 1; [ "$(grep -c '^closing_keyword_override=' "$LAST/state/task-x1.meta")" -eq 2 ] || { FAILS=$((FAILS+1)); echo '!!! expected two override lines'; }
PRESEED=
scenario "no Owns issue line, issue only linked on the row -> hedged warning, merges" 0 'Part of #14' "$I14" '' 'Mode no-mistakes.'
merged 1; says 'nothing is wrong'; silent 'refused'
scenario "two Owns issue lines -> reported, treated as no marker, merges" 0 'no keyword' '' '' "Owns issue: $I7" "Owns issue: $I14"
merged 1; says 'marks more than one owned issue'; silent 'refused'
scenario "owned issue closed, a second linked issue not closed -> hedged warning for the linked one only, merges" 0 'Closes #7' "$I14" '' "Owns issue: $I7"
merged 1; says "does not close #14"; says 'nothing is wrong'; silent 'marks as owned'
scenario "owned issue unclosed and a linked issue unclosed -> refused, both reported" 1 'nothing' "$I14" '' "Owns issue: $I7"
merged 0; says 'marks as owned; nothing was merged'; says "does not close #14"
scenario "task names no issue at all -> silent, merges" 0 'nothing' '' '' 'Mode no-mistakes.'
merged 1; silent 'clos'
echo "driver checks failed: $FAILS"
exit "$((FAILS > 0))"
