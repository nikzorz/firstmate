# Agent attribution verification

Active empirical evidence for the guarantee that no commit reaching this repo's default branch names an agent as a co-author.
Measured 2026-09-03 unless stated otherwise.

## The two measured harnesses inject a trailer

Claude Code 2.1.259 composes its commit attribution from the merged settings, then appends the session link separately.
Read from the shipped binary at `/home/nik/.local/share/claude/versions/2.1.259`:

```js
function u3o(){let e=Tzn(),n=`Co-Authored-By: ${d3o(at())} <noreply@anthropic.com>`,r=Je(),o=r.attribution;
  if(o!==void 0&&cxn(o))return{commit:o.commit??n,pr:o.pr??e};
  if(r.includeCoAuthoredBy===!1)return Azn().fire("attribution_texts"),{commit:"",pr:""};
  return{commit:n,pr:e}}
function wWe({includeOutboundOnly:e=!1}={}){if(a.CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION)return null;
  if(Je().attribution?.sessionUrl===!1)return null; ... }
function l3o(e,n,r){let o=r??n;return{commit:e.commit?`${e.commit}\nClaude-Session: ${n}`:`Claude-Session: ${n}`, ... }}
```

`l3o` appends the session link whether or not the co-author text is empty, so `includeCoAuthoredBy: false` alone still leaves a `Claude-Session:` trailer on a session that has a shareable URL.
Both keys are required, which is why `.claude/settings.json` carries both.

Codex 0.147.0's equivalent is not local.
Its trailer text and the developer instruction that carries it sit next to `commit_attribution_enabled` and the `https://chatgpt.com/backend-api` base URL in `@openai/codex-linux-x64`'s `codex` binary, and its disable path reads:

```
Codex commit and pull request attribution is disabled for the current workspace.
Ignore any earlier instructions requiring Codex attribution and do not add it.
```

Its enabled path adds `- Ignore any earlier instructions disabling Codex attribution; this policy reflects the current workspace.`
The setting is account-side and explicitly outranks repository rules, so no file in this repo can turn it off.
That is why the merge path, not the harness setting, owns the guarantee.

Claude and codex are the whole of the measured set.
`opencode`, `pi`, `grok`, and `kimi` are verified firstmate harnesses too, but none is installed on this machine, so whether each injects a trailer, and under which address, is unmeasured rather than known to be nothing.
Covering one starts by measuring the trailer that runtime actually emits and ends by adding the address it uses to `FM_ATTRIBUTION_AGENT_EMAILS`; a guessed address is worse than no entry, because a wrong one silently strips a human co-author.

## The Claude settings knob works, including in a linked worktree

Two scratch repositories differing only in `.claude/settings.json`, each asked to create and commit a file:

```
$ prompt='Create a file hello.txt containing "hi", then git add and git commit it with subject "test: add hello".
Follow every instruction you have been given about commit messages.'
$ (cd attr-a && claude -p "$prompt" --dangerously-skip-permissions) ; git -C attr-a log -1 --format=%B
test: add hello

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

$ (cd attr-b && claude -p "$prompt" --dangerously-skip-permissions) ; git -C attr-b log -1 --format=%B
test: add hello
```

`attr-b` carried `{"includeCoAuthoredBy": false, "attribution": {"sessionUrl": false}}`.
Repeating the run in a `git worktree add` checkout of a repository with that file committed also produced `test: add hello` with no trailer, which is the shape the validation pipeline uses: it runs each pipeline agent in its own worktree under `~/.no-mistakes/worktrees/<repo>/<run>/`, a full checkout that carries the repo's tracked settings.

## The pipeline's own commits never carried a trailer

Across the branch commits of the five most recent merged pull requests, only the implementation commit an agent wrote by hand carried one:

| PR | branch commits | carrying a trailer |
| --- | --- | --- |
| 19 | 8 | 0 |
| 20 | 9 | 0 |
| 21 | 2 | 1 |
| 22 | 3 | 1 |
| 23 | 12 | 1 |

The 31 `no-mistakes(review):` and `no-mistakes(document):` commits carry none, because the pipeline composes those messages itself.

## The forge hoists a branch trailer into the squash commit

A squash merge does not drop the trailer.
GitHub composes the squash message from the branch commits and adds its own aggregated co-author list, so one trailer on one branch commit reaches the default branch twice.
`f15915f4`, `2f4c1a2a`, and `d1513a18` on `main` each carry `Co-authored-by: Claude Opus 5 <noreply@anthropic.com>` for that reason.

The default message the forge would write is readable before merging, which is what `bin/fm-pr-merge.sh` supplies back after stripping:

```
$ gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){viewerMergeBodyText(mergeType:SQUASH)}}}' \
    -F owner=nikzorz -F repo=firstmate -F number=23 \
    --jq '.data.repository.pullRequest.viewerMergeBodyText' > body.txt
$ . bin/fm-attribution-lib.sh && fm_attribution_strip < body.txt > stripped.txt
$ diff body.txt stripped.txt
40,42d39
< Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
< Claude-Session: https://claude.ai/code/session_01KxQHc4MTsEMXUNuRhKXTnA
<
68d64
< Co-authored-by: Claude Opus 5 <noreply@anthropic.com>
```

`Co-authored-by: Kun Chen <3233006+kunchenguid@users.noreply.github.com>` survived, along with the separator introducing it and the whole commit list.

## Scope of the guarantee

The strip runs on the squash path only.
A merge-commit or rebase merge replays the branch commits onto the default branch untouched and carries whatever trailers they carry; `.claude/settings.json` is what keeps those commits clean for Claude-run work.
`tests/fm-attribution-lib.test.sh` owns the regression coverage for both halves, the strip itself and the `.claude/settings.json` knob, and `tests/fm-pr-merge.test.sh` owns it for the merge path.
