#!/usr/bin/env bash
# Drives the scaffolded worker brief's recovery playbook against disposable gate stores.
set -u
ROOT=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
home=$T/home; mkdir -p "$home/data"
echo "## 1. scaffold a real no-mistakes brief with bin/fm-brief.sh"
FM_HOME="$home" "$ROOT/bin/fm-brief.sh" live-b1 some-proj --mode no-mistakes >/dev/null 2>&1; echo "fm-brief rc=$?"
brief=$home/data/live-b1/brief.md
echo "--- brief lines carrying the recovery playbook:"
grep -n 'Read the run head from\|Before you conclude anything' "$brief"
echo "--- stale wording present? $(grep -c 'refuses a bare-SHA fetch' "$brief")"

echo; echo "## 2. disposable gate stores under a fake HOME"
src=$T/src; git init -q "$src"
echo a > "$src/f"; git -C "$src" add f; git -C "$src" commit -q -m base
echo b > "$src/f"; git -C "$src" commit -qam anchored; anchored=$(git -C "$src" rev-parse HEAD)
echo c > "$src/f"; git -C "$src" commit -qam unreferenced; unref=$(git -C "$src" rev-parse HEAD)
absent=$(git -C "$src" commit-tree -m absent "$unref^{tree}")
stores=$home/.no-mistakes/repos; mkdir -p "$stores"
git init -q --bare "$stores/held.git"; git init -q --bare "$stores/empty.git"
git -C "$stores/held.git" fetch -q "$src" "$anchored:refs/no-mistakes/recover/RUN1" "$unref:refs/scratch/u"
git -C "$stores/held.git" update-ref -d refs/scratch/u
echo "anchored=$anchored unreferenced=$unref absent=$absent"
echo "held.git refs:"; git -C "$stores/held.git" for-each-ref

line=$(grep -F 'Before you conclude anything, run `' "$brief"); line=${line#*run \`}; search=${line%%\`*}
echo; echo "## 3. the search exactly as the brief renders it:"; echo "$search"
for h in anchored unref absent; do
  echo "--- run head = $h (${!h})"
  HOME=$home bash -c "${search//<run head>/${!h}}"; echo "(rc=$?, end of output)"
done
echo "--- old search (for-each-ref --contains only) on the unreferenced head:"
HOME=$home bash -c 'for r in ~/.no-mistakes/repos/*.git; do git -C "$r" for-each-ref --format="$r %(refname)" --contains '"$unref"' 2>/dev/null; done'; echo "(end of output: old search prints nothing, head looks lost)"

echo; echo "## 4. fetch advice against the store"
wt=$T/wt; git init -q "$wt"
git -C "$wt" fetch "$stores/held.git" refs/no-mistakes/recover/RUN1:refs/heads/archive/by-ref 2>&1 | tail -1; echo "by recover ref name: rc=${PIPESTATUS[0]} -> $(git -C "$wt" rev-parse refs/heads/archive/by-ref)"
git -C "$wt" fetch "$stores/held.git" "$unref:refs/heads/archive/by-sha" 2>&1 | tail -1; echo "by full 40-char sha (no ref reaches it): rc=${PIPESTATUS[0]} -> $(git -C "$wt" rev-parse refs/heads/archive/by-sha)"
wt2=$T/wt2; git init -q "$wt2"
git -C "$wt2" fetch "$stores/held.git" "${anchored:0:7}:refs/heads/archive/by-abbrev" 2>&1; echo "by abbreviated sha ${anchored:0:7}: rc=$?"
git -C "$wt2" fetch "$stores/held.git" "${unref:0:12}" 2>&1; echo "by 12-char abbreviated sha: rc=$?"

echo; echo "## 5. SKILL.md checks: pre-upgrade bundle and equal-tree rewrite"
mkdir -p "$home/data/nm-update-20260101"
git -C "$src" update-ref refs/no-mistakes/recover/RUN9 "$absent"
git -C "$src" bundle create -q "$home/data/nm-update-20260101/some-proj.bundle" refs/no-mistakes/recover/RUN9
for b in "$home"/data/nm-update-*/*.bundle; do echo "$b:"; git bundle list-heads "$b"; done
echo "absent head in any store? $(HOME=$home bash -c "${search//<run head>/$absent}" | wc -l) lines; bundle holds it: $(git bundle list-heads "$home"/data/nm-update-*/*.bundle | grep -c "$absent")"
echo "equal-tree rewrite: unref^{tree}=$(git -C "$src" rev-parse "$unref^{tree}") absent^{tree}=$(git -C "$src" rev-parse "$absent^{tree}") descends=$(git -C "$src" merge-base --is-ancestor "$unref" "$absent" && echo yes || echo no)"
