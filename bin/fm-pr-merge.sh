#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
#
# On the squash path this supplies the commit message rather than letting the
# forge compose one, because a composed squash message carries every agent
# attribution trailer the branch commits carry and hoists them into its own
# co-author list. The message supplied is the forge's own default for this pull
# request, read back through gh's GraphQL fields so the wording, ordering, and
# human co-author list stay exactly what the forge would have written, with only
# the lines bin/fm-attribution-lib.sh recognises as agent attribution removed.
# Reading that default needs gh itself: gh-axi wraps its response in a display
# envelope, and this path needs the raw message bytes. The headline and body are
# asked for separately so each arrives as raw text with no delimiter to guess at.
# A default that cannot be read stops the merge rather than falling back to a
# composed message, which is the case this exists to prevent.
#
# Ownership of that message splits by half, because the trailers live in the
# body and never in the subject. A caller's --body or --body-file takes the body
# and the strip stands down with it; a caller's --subject takes only the subject,
# and the stripped body is still read and supplied underneath it.
#
# A pull request that is already merged has no message to supply: gh-axi reports
# it merged and runs no merge, so the read is skipped and re-running a merge that
# already landed no longer depends on a readable default message. A merged state
# that cannot be read is not taken for either answer; it falls through to the
# ordinary read, which still refuses when the default message is unavailable.
#
# --auto is refused wherever this path would supply the message, because the
# forge stores the headline and body when auto-merge is armed and lands them
# whenever the merge later fires. A message read at arm time cannot carry the
# commits pushed while auto-merge waits, and the forge offers no way to have it
# composed at merge time without also composing the trailers back in. A caller
# passing --body or --body-file owns the message already and is unaffected.
#
# Before merging, the closing-keyword check reads the PR body and says whether it
# closes the issues the task's record mentions. This is the last point at which
# nothing can rewrite that body again: the validation pipeline composes the body
# from its own step results, so a keyword written before a later push does not
# survive to here, and a merge without one leaves the issue open after its work
# landed.
#
# The check is ADVISORY and blocks nothing. Its only source is the links: entry
# tasks-axi derives from the URLs on the task's row, and that entry records every
# URL the row carries, not the issues the work owns: a follow-up mentioned for
# context reads exactly like an issue the task closes. Refusing on a signal that
# cannot tell those apart does not avoid the guess, it relocates it to whoever is
# told to satisfy the refusal, so this reports and merges. Every other guard in
# this file still refuses; only this one advises. The task id, the branch name,
# and the PR prose are never read for the issue either.
#
# The read has three answers and each says something different. A record naming
# no issue, and an id the backlog genuinely does not hold, are both determinate:
# nothing to check, so the merge runs with no PR-body read at all, silently, and
# that is the common firstmate-repo case. A body missing a well-formed keyword
# for an issue the record mentions gets one warning naming the issue and leaving
# the judgment to a reader. A backlog, a forge CLI, or a PR body that could not
# be read gets one warning saying the check did not run and why.
#
# The check is on the FORM, not on the presence of the number: GitHub acts only
# when a closing keyword immediately precedes the reference, so "Close issues
# #148 and #117" closes nothing while carrying both numbers, and "Closes #117x"
# names no issue at all. Keywords are matched case-insensitively, and "#N",
# "owner/repo#N", and the full issue URL all count as the reference.
#
# After the merge, every named issue is read back. One that did not read CLOSED
# is reported as not observed closed rather than as a defect, because the forge
# acts on a closing keyword in a background job that can land after this read
# returns. One the read could not answer for at all is reported as unknown,
# because a token that cannot see the issue has not established anything about
# it. That check is the only one no keyword form can fool, so it runs even when
# the body passed the pre-merge read. An armed --auto merge has not landed yet,
# so it has no post-merge state to read and the report is skipped there.
#
# The guarantee is squash-only by construction: a merge-commit or rebase merge
# replays the branch commits onto the default branch untouched, so it carries
# whatever trailers they carry.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-attribution-lib.sh
. "$SCRIPT_DIR/fm-attribution-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# Whether the effective merge method is squash, covering both the --method
# <value> and --method=<value> spellings gh accepts.
caller_selects_squash() {
  local arg method_expected=0
  for arg in "$@"; do
    if [ "$method_expected" = 1 ]; then
      [ "$arg" = squash ] && return 0
      return 1
    fi
    case "$arg" in
      --squash) return 0 ;;
      --merge|--rebase) return 1 ;;
      --method) method_expected=1 ;;
      --method=*) [ "${arg#--method=}" = squash ] && return 0 ; return 1 ;;
    esac
  done
  return 1
}

# A caller who writes the squash body owns it, including its trailers. Long
# spellings are the whole set: gh-axi's pr merge allowlist accepts only
# --subject, --body, and --body-file, and rejects any short form before gh runs.
caller_writes_squash_body() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --body|--body=*|--body-file|--body-file=*) return 0 ;;
    esac
  done
  return 1
}

caller_writes_squash_subject() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --subject|--subject=*) return 0 ;;
    esac
  done
  return 1
}

# Only the exact --auto token arms auto-merge: gh-axi takes it as a bare boolean
# and drops any other spelling before gh sees it, so nothing else can freeze a
# message.
caller_arms_auto_merge() {
  local arg
  for arg in "$@"; do
    [ "$arg" = --auto ] && return 0
  done
  return 1
}

# Not merged and not readable are deliberately the same answer here, so an
# unreadable state falls through to the ordinary read rather than skipping it.
# The state is read once and reused: the closing-keyword gate and the
# squash-message read both ask for it, and the merge is still ahead of both.
PR_MERGED_STATE=
pr_is_already_merged() {
  local state
  if [ -z "$PR_MERGED_STATE" ]; then
    state=$(gh pr view "$URL" --json state -q .state 2>"$GH_STDERR_FILE") || state=
    PR_MERGED_STATE=${state:-UNREADABLE}
  fi
  [ "$PR_MERGED_STATE" = MERGED ]
}

# The refusal stays fail-closed and fixed; only its cause comes from gh, which
# writes a one-line summary to stderr and the raw response to stdout.
refuse_unreadable_default_message() {
  echo "error: the default squash message could not be read" >&2
  if [ -s "$GH_STDERR_FILE" ]; then
    echo "error: the forge CLI reported:" >&2
    cat "$GH_STDERR_FILE" >&2
  fi
  exit 1
}

# GitHub's closing keywords, which it matches case-insensitively.
CLOSING_KEYWORD_RE='(close[sd]?|fix|fixe[sd]|resolve[sd]?)'
TASK_ISSUE_URLS=

# Owner and repository names admit "." and nothing else an ERE reads specially.
ere_escape() {  # <text>
  printf '%s' "$1" | sed 's/\./\\./g'
}

# Sets TASK_ISSUE_URLS to the issue URLs this task's own record names, one per
# line, and answers in the three states a backlog read really has. Collapsing
# them reports a missed check over an answer that was determinate: a task never
# filed as a backlog item names no issue just as plainly as a filed one whose row
# links none, or one whose record carries no links field at all, and that is the
# common firstmate-repo case.
# config/backlog-backend=manual routes routine backlog MUTATIONS to hand-editing
# and leaves this read unaffected.
#   0 the record names issues     1 determinate, it names none
#   2 indeterminate               3 no answer this check can read
read_task_issue_urls() {
  local rc=0
  TASK_ISSUE_URLS=
  fm_backlog_item_read "$ID" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  TASK_ISSUE_URLS=$(fm_backlog_show_field "$FM_BACKLOG_ITEM_SHOW" links |
    grep -Eo 'https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/issues/[1-9][0-9]*' |
    awk '!seen[$0]++' || true)
}

# A bare "#N" resolves against the PR's own repository, so it names this issue
# only when the issue lives there. Both the form check and the refusal turn on
# that, and they must turn on it identically or the gate names a spelling it
# would then reject. GitHub resolves owner and repository case-insensitively, so
# a hand-typed "Firstmate" in a backlog row is the same repository as "firstmate"
# in the PR URL and must not read as another one.
PR_REPO_PATH_LC=$(printf '%s' "$PR_OWNER/$PR_REPO" | LC_ALL=C tr '[:upper:]' '[:lower:]')
issue_is_in_pr_repo() {  # <owner> <repo>
  [ "$(printf '%s' "$1/$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')" = "$PR_REPO_PATH_LC" ]
}

# The reference a closing keyword must immediately precede, in the spelling this
# PR's own repository makes valid.
issue_reference() {  # <owner> <repo> <number>
  if issue_is_in_pr_repo "$1" "$2"; then
    printf '#%s\n' "$3"
  else
    printf '%s/%s#%s\n' "$1" "$2" "$3"
  fi
}

# Whether a closing keyword directly precedes a reference to this issue. The
# reference has to end on a word boundary the way GitHub's own parser ends it:
# that keeps "#1" from matching inside "#14", and keeps "#117x" from reading as
# a reference to 117, which GitHub parses as no reference at all.
body_closes_issue() {  # <body-file> <owner> <repo> <number>
  local body=$1 path number=$4 refs
  path=$(ere_escape "$2/$3")
  refs="$path#$number|https://github\.com/$path/issues/$number"
  if issue_is_in_pr_repo "$2" "$3"; then
    refs="#$number|$refs"
  fi
  grep -Eiq "(^|[^[:alnum:]_])${CLOSING_KEYWORD_RE}[[:space:]]+($refs)([^[:alnum:]_]|\$)" "$body"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# One cleanup for every scratch file this run can create, because a second trap
# later would replace this one and leak whatever it did not name.
GH_STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-gh-stderr.XXXXXX")
PR_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-pr-body.XXXXXX")
SQUASH_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-body.XXXXXX")
trap 'rm -f "$GH_STDERR_FILE" "$PR_BODY_FILE" "$SQUASH_BODY_FILE"' EXIT

check_could_not_run() {  # <why>
  echo "warning: the closing-keyword check did not run: $1" >&2
}

# Runs before any merge argument is composed, so a PR with nothing to check
# costs no forge round trip. Every answer it can reach is a report: the links:
# entry it reads cannot establish that this work owns an issue, and a refusal
# built on it would hand that same guess to whoever had to satisfy the refusal.
closing_keyword_gate() {
  local url owner repo number ref rc=0
  local -a issues=() missing=()

  read_task_issue_urls || rc=$?
  case "$rc" in
    0|1) : ;;
    *) check_could_not_run "$FM_BACKLOG_ITEM_ERROR" ; return 0 ;;
  esac
  [ -n "$TASK_ISSUE_URLS" ] || return 0

  while IFS= read -r url; do
    if [ -n "$url" ]; then
      issues+=("$url")
    fi
  done <<< "$TASK_ISSUE_URLS"

  if ! command -v gh >/dev/null 2>&1; then
    check_could_not_run "the forge CLI needed to read the PR body is unavailable"
    return 0
  fi
  # An already-merged PR has nothing left to advise on: the forge acted on
  # whatever body it had. The post-merge read is what reports that outcome.
  pr_is_already_merged && return 0
  if ! gh pr view "$URL" --json body -q .body > "$PR_BODY_FILE" 2>"$GH_STDERR_FILE"; then
    check_could_not_run "the PR body could not be read"
    if [ -s "$GH_STDERR_FILE" ]; then
      echo "warning: the forge CLI reported:" >&2
      cat "$GH_STDERR_FILE" >&2
    fi
    return 0
  fi

  for url in "${issues[@]}"; do
    owner=${url#https://github.com/}
    repo=${owner#*/}
    number=${repo##*/issues/}
    repo=${repo%%/issues/*}
    owner=${owner%%/*}
    if ! body_closes_issue "$PR_BODY_FILE" "$owner" "$repo" "$number"; then
      missing+=("$(issue_reference "$owner" "$repo" "$number") ($url)")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  for ref in "${missing[@]}"; do
    echo "warning: this PR's body does not close $ref, which task $ID's record mentions" >&2
  done
  # No edit is prescribed here on purpose. The record cannot establish that this
  # work owns the issue, so only a reader can tell which of these two it is.
  echo "warning: if this work owns that issue, its body needs a closing keyword directly before the reference; if the record only mentions it for context, nothing is wrong" >&2
}

# The one check no keyword form can fool, and the reason it runs after the merge
# rather than instead of the body read. Every outcome it reports is an
# observation rather than a verdict, because neither a state it read nor a state
# it failed to read establishes what the merge did.
report_unclosed_issues() {
  local url state
  [ -n "$TASK_ISSUE_URLS" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  while IFS= read -r url; do
    if [ -n "$url" ]; then
      state=$(gh issue view "$url" --json state -q .state 2>/dev/null) || state=
      case "$state" in
        CLOSED) : ;;
        '') echo "warning: $url could not be read, so whether this merge closed it is unknown" >&2 ;;
        # The forge acts on a closing keyword in a background job that can land
        # after this read returns, so a state of OPEN here is not yet a defect.
        *) echo "warning: $url was not observed closed immediately after this merge; the forge closes on a keyword in a background job that can finish after this read, so it may still close on its own" >&2 ;;
      esac
    fi
  done <<< "$TASK_ISSUE_URLS"
}

closing_keyword_gate

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
  squashing=1
elif caller_selects_squash "$@"; then
  squashing=1
else
  squashing=0
fi

if [ "$squashing" = 1 ] && ! caller_writes_squash_body "$@"; then
  # shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
  DEFAULT_MESSAGE_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){viewerMergeHeadlineText(mergeType:SQUASH) viewerMergeBodyText(mergeType:SQUASH)}}}'
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: the forge CLI needed to read the default squash message is unavailable" >&2
    exit 1
  fi
  if ! pr_is_already_merged; then
    if caller_arms_auto_merge "$@"; then
      echo "error: --auto would freeze this squash message: the forge stores the message when auto-merge is armed and lands it whenever the merge later fires, so commits pushed in between would be missing from it" >&2
      echo "error: merge without --auto, or pass --body or --body-file to own the message" >&2
      exit 1
    fi
    # Owner and repository are String! variables, so they go through gh's raw
    # field flag: the typed one converts an all-digit name to a JSON number,
    # which the server then refuses to coerce. Only the Int! number stays typed.
    #
    # A pull request the query cannot resolve, and a merge text the forge
    # declines to compute, both come back as a JSON null, which gh renders as
    # the literal token "null" on stdout with a zero exit. That token is an
    # unreadable default, never a message, on either field.
    if ! caller_writes_squash_subject "$@"; then
      if ! SQUASH_SUBJECT=$(gh api graphql -f query="$DEFAULT_MESSAGE_QUERY" \
        -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" \
        --jq '.data.repository.pullRequest.viewerMergeHeadlineText' 2>"$GH_STDERR_FILE") \
        || [ -z "$SQUASH_SUBJECT" ] || [ "$SQUASH_SUBJECT" = null ]; then
        refuse_unreadable_default_message
      fi
      merge_args+=(--subject "$SQUASH_SUBJECT")
    fi
    # An empty body is a legitimate default for a single-commit pull request
    # with no commit body, so emptiness alone is not an error here.
    if ! SQUASH_BODY=$(gh api graphql -f query="$DEFAULT_MESSAGE_QUERY" \
      -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.viewerMergeBodyText' 2>"$GH_STDERR_FILE") \
      || [ "$SQUASH_BODY" = null ]; then
      refuse_unreadable_default_message
    fi
    printf '%s\n' "$SQUASH_BODY" | fm_attribution_strip > "$SQUASH_BODY_FILE"
    merge_args+=(--body-file "$SQUASH_BODY_FILE")
  fi
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# --auto arms the merge for the forge to land later, so there is no post-merge
# state to read yet and an issue still open here says nothing.
caller_arms_auto_merge "$@" || report_unclosed_issues
