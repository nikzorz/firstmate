#!/usr/bin/env bash
# Runs only the closing-keyword tests of tests/fm-pr-merge.test.sh.
set -u
WT=$1
H=$(mktemp "${TMPDIR:-/tmp}/fm-ck-tests.XXXXXX")
sed -e '/^test_[a-z0-9_]*$/d' -e "s|\"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|\"$WT/tests/lib.sh\"|" "$WT/tests/fm-pr-merge.test.sh" > "$H"
. "$H"; rm -f "$H"
test_task_without_an_issue_merges_silently
test_keyword_not_adjacent_to_reference_warns_and_merges
test_well_formed_closing_keywords_are_accepted
test_malformed_references_do_not_count
test_several_issues_each_named_and_only_closed_ones_read_back
test_unreadable_pr_body_warns_and_merges
test_owned_issue_missing_keyword_refuses
test_no_closing_keyword_overrides_and_is_recorded
test_no_closing_keyword_unused_records_nothing
test_no_closing_keyword_is_recorded_when_authority_persist_fails
test_owned_issue_closed_is_read_back_and_context_issue_stays_hedged
test_unusable_owned_issue_markers_mark_nothing
test_gitlab_merge_runs_no_closing_keyword_check
