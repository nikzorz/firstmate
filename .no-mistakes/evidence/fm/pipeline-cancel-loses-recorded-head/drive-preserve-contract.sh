#!/usr/bin/env bash
# Drives the preserve-before-abort contract rendered by bin/fm-brief.sh against a
# synthetic no-mistakes gate (bare store + detached pipeline worktree).
set -u
ROOT=$1; T=$(mktemp -d); export HOME=$T/home; mkdir -p $HOME/.no-mistakes/repos
git config --global user.email t@t >/dev/null 2>&1 || true
export GIT_CONFIG_GLOBAL=$T/gitconfig; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
echo "== 1. scaffold a real no-mistakes brief"
FM_HOME=$T/fm; mkdir -p $FM_HOME/data
FM_HOME=$FM_HOME "$ROOT/bin/fm-brief.sh" demo-t1 some-proj --mode no-mistakes >/dev/null 2>&1
B=$FM_HOME/data/demo-t1/brief.md
awk '/^Preserve before you end a run/,/never re-implement/' "$B" | tee $T/contract.txt
echo; echo "== ordering (line numbers in brief)"
grep -n 'HEAD:refs/heads/archive\|rev-parse refs/heads/archive\|Only then run `no-mistakes axi abort`' "$B"

echo; echo "== 2. build synthetic gate: store A (this project), store B (other), detached pipeline worktree"
STORE=$HOME/.no-mistakes/repos/aaaa.git; OTHER=$HOME/.no-mistakes/repos/bbbb.git
git init -q $T/work; cd $T/work; echo a>f; git add f; git commit -qm base; git checkout -qb fm/demo-t1; echo b>>f; git commit -qam "worker change"
git init -q --bare $STORE; git init -q --bare $OTHER
git remote add no-mistakes $STORE; git push -q no-mistakes fm/demo-t1
HEAD_SHA=$(git rev-parse HEAD)
RUN=01TESTRUNID; WT=$HOME/.no-mistakes/worktrees/aaaa/$RUN
git -C $STORE worktree add -q --detach $WT $HEAD_SHA
( cd $WT; echo fix>>f; git -c user.email=p@p -c user.name=pipeline commit -qam "no-mistakes(review): fix" )
CUR=$(git -C $WT rev-parse HEAD)
echo "head_sha=$HEAD_SHA  current_head(pipeline fix)=$CUR"
echo "refs containing current_head in store: [$(git -C $STORE for-each-ref --contains $CUR)]"

echo; echo "== 3. adversarial: bare-SHA fetch of current_head from the store"
git fetch no-mistakes $CUR:refs/heads/archive/bare 2>&1 | tail -2; echo "rc=${PIPESTATUS[0]}"

echo; echo "== 4. contract step 1: locate gate worktree via the brief's command, fetch HEAD"
git -C "$(git remote get-url no-mistakes)" worktree list | tee $T/wtl
WTP=$(awk -v c=${CUR:0:7} '$2==c{print $1}' $T/wtl); echo "worktree whose HEAD is run head: $WTP"
git fetch -q "$WTP" HEAD:refs/heads/archive/fm/demo-t1; echo "fetch rc=$?"
echo "== step 2: rev-parse archive ref = $(git rev-parse refs/heads/archive/fm/demo-t1)  (expected $CUR)"
[ "$(git rev-parse refs/heads/archive/fm/demo-t1)" = "$CUR" ] && echo "PRESERVED OK"

echo; echo "== 5. step 3 abort (simulated: gate worktree removed, as abort does)"
git -C $STORE worktree remove --force $WT; git -C $STORE worktree prune; git -C $STORE gc -q --prune=now 2>/dev/null
echo "store still has current_head? $(git -C $STORE cat-file -t $CUR 2>&1)"
echo "local archive still has it: $(git cat-file -t refs/heads/archive/fm/demo-t1) $(git log -1 --format='%h %s' refs/heads/archive/fm/demo-t1)"

echo; echo "== 6. missing-head search loop, extracted verbatim from the brief"
LOOP=$(grep -o 'for r in ~/.no-mistakes/repos/\*.git; do [^`]*done' "$B" | head -1); echo "loop: $LOOP"
# recovery ref only in store B
git push -q $OTHER HEAD:refs/no-mistakes/recover/01OTHERRUN
L=${LOOP//<run head>/$HEAD_SHA}; echo "-- search for head in recover ref:"; bash -c "$L"
echo "-- adversarial: search for a head no store holds:"
NOPE=$(git commit-tree -m x $(git write-tree)); OUT=$(bash -c "${LOOP//<run head>/$NOPE}"); echo "[${OUT}] (empty => loss is real, report blocked:)"
echo "-- fetch the match by its ref name from that store:"
git fetch -q $OTHER refs/no-mistakes/recover/01OTHERRUN:refs/heads/recovered && git log -1 --format='recovered %h %s' refs/heads/recovered
rm -rf $T
