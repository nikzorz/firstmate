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
# The guarantee is squash-only by construction: a merge-commit or rebase merge
# replays the branch commits onto the default branch untouched, so it carries
# whatever trailers they carry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-attribution-lib.sh
. "$SCRIPT_DIR/fm-attribution-lib.sh"

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

# A caller who writes the squash message owns it, including its trailers.
# Long spellings are the whole set: gh-axi's pr merge allowlist accepts only
# --subject, --body, and --body-file, and rejects any short form before gh runs.
caller_writes_squash_message() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --subject|--subject=*|--body|--body=*|--body-file|--body-file=*) return 0 ;;
    esac
  done
  return 1
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

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
  squashing=1
elif caller_selects_squash "$@"; then
  squashing=1
else
  squashing=0
fi

if [ "$squashing" = 1 ] && ! caller_writes_squash_message "$@"; then
  # shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
  DEFAULT_MESSAGE_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){viewerMergeHeadlineText(mergeType:SQUASH) viewerMergeBodyText(mergeType:SQUASH)}}}'
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: the forge CLI needed to read the default squash message is unavailable" >&2
    exit 1
  fi
  # A pull request the query cannot resolve, and a merge text the forge declines
  # to compute, both come back as a JSON null, which gh renders as the literal
  # token "null" on stdout with a zero exit. That token is an unreadable default,
  # never a message, on either field.
  if ! SQUASH_SUBJECT=$(gh api graphql -f query="$DEFAULT_MESSAGE_QUERY" \
    -F owner="$PR_OWNER" -F repo="$PR_REPO" -F number="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.viewerMergeHeadlineText' 2>/dev/null) \
    || [ -z "$SQUASH_SUBJECT" ] || [ "$SQUASH_SUBJECT" = null ]; then
    echo "error: the default squash message could not be read" >&2
    exit 1
  fi
  # An empty body is a legitimate default for a single-commit pull request with
  # no commit body, so emptiness alone is not an error here.
  if ! SQUASH_BODY=$(gh api graphql -f query="$DEFAULT_MESSAGE_QUERY" \
    -F owner="$PR_OWNER" -F repo="$PR_REPO" -F number="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.viewerMergeBodyText' 2>/dev/null) \
    || [ "$SQUASH_BODY" = null ]; then
    echo "error: the default squash message could not be read" >&2
    exit 1
  fi
  SQUASH_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-body.XXXXXX")
  trap 'rm -f "$SQUASH_BODY_FILE"' EXIT
  printf '%s\n' "$SQUASH_BODY" | fm_attribution_strip > "$SQUASH_BODY_FILE"
  merge_args+=(--subject "$SQUASH_SUBJECT" --body-file "$SQUASH_BODY_FILE")
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
