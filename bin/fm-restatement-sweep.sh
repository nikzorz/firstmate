#!/usr/bin/env bash
# fm-restatement-sweep.sh - list sentences elsewhere in a repository that may
# restate a rule the current branch changed, so its author finds a stale copy
# before review does.
#
# Usage: fm-restatement-sweep.sh [--base <rev>]
#
# Run it anywhere inside the repository's worktree. It compares HEAD with its
# merge-base against <base>; without --base that is origin's default branch
# (refs/remotes/origin/HEAD, else origin/main or origin/master), or the local
# main or master when the repository has no origin.
# It refuses while the worktree holds uncommitted or untracked changes,
# because only committed sentences are swept and a clean-looking report over
# an unswept edit would be false.
#
# A changed sentence is one the diff added (read at HEAD) or removed (read at
# the merge-base). Each is compared with every prose sentence tracked at
# HEAD, by the overlap of the uncommon words they share weighted by how rare
# each word is across the repository. A candidate is listed when it shares at
# least three such words and enough of their weight with a changed sentence;
# each changed sentence contributes at most its five closest candidates, and
# each candidate is listed once, under the changed sentence it resembles most,
# closest first. Sentences in the same file the diff also changed, and copies
# of a removed sentence the diff re-added elsewhere (a move), are not
# candidates; an added sentence resembling one added in another file is,
# because two new copies of one rule are a restatement too.
#
# Prose is every line of a Markdown or plain-text file outside code fences,
# and in a source file its comment lines and the bodies of here-documents fed
# to a command that is not an interpreter. Test and fixture paths, linter
# directives, code-shaped lines, binary files, and files over 512 KiB are left
# out.
#
# The similarity is lexical, so the list is a set of leads to read, not a
# verdict: a restatement worded with entirely different words is missed, and a
# listed sentence may be an unrelated neighbour on the same topic or a
# legitimate one-line pointer.
#
# Output: a summary line, then for each candidate
#   <path>:<line>: <candidate sentence>
#     resembles <+|-> <path>:<line>: <changed sentence>
# where + marks a sentence the diff added and - one it removed.
#
# Exit status: 0 when the sweep ran, whether or not it listed candidates; 2 on
# a usage error, a dirty worktree, an unresolvable revision, or a missing
# python3.
set -u

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

BASE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; BASE=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not inside a git worktree" >&2; exit 2; }
cd "$top" || exit 2
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required and was not found" >&2; exit 2; }

dirty=$(git status --porcelain --untracked-files=normal) || exit 2
if [ -n "$dirty" ]; then
  echo "error: the worktree has uncommitted or untracked changes, which the sweep cannot see; commit them first:" >&2
  printf '%s\n' "$dirty" >&2
  exit 2
fi

if [ -z "$BASE" ]; then
  if ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); then
    BASE=$ref
  else
    for candidate in origin/main origin/master main master; do
      if git rev-parse -q --verify "$candidate^{commit}" >/dev/null; then
        BASE=$candidate
        break
      fi
    done
  fi
  [ -n "$BASE" ] || { echo "error: cannot find a default branch to compare against; pass --base <rev>" >&2; exit 2; }
fi
git rev-parse -q --verify "$BASE^{commit}" >/dev/null || { echo "error: cannot resolve base revision $BASE" >&2; exit 2; }
HEAD_COMMIT=$(git rev-parse -q --verify 'HEAD^{commit}') || { echo "error: HEAD has no commit to sweep" >&2; exit 2; }
MERGE_BASE=$(git merge-base "$BASE" "$HEAD_COMMIT") || { echo "error: $BASE and HEAD share no history" >&2; exit 2; }

exec python3 -I - "$BASE" "$MERGE_BASE" "$HEAD_COMMIT" <<'PY'
import collections
import math
import re
import subprocess
import sys

BASE_NAME, MERGE_BASE, HEAD = sys.argv[1:4]

MIN_SHARED_WORDS = 3
MIN_SHARED_WEIGHT = 15.0
MIN_SCORE = 0.30
PER_PROBE = 5
MAX_BLOB_BYTES = 512 * 1024
# A word in more than this share of all sentences carries no rule of its own.
COMMON_SHARE = 0.05

STOP = set("""
a an the and or but if then else of to in on at by for with from as is are was were be been being it its this
that these those which who whom whose what when where why how not no nor so than too very can will would should
could may might must shall do does did done has have had having into onto over under only also any all each every
some such same other another more most less least own one two first via per there here their they them we you
your our he she his her up out off just even still yet both either neither whether while until unless because
since about above below after before again further once
""".split())

WORD = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
LEAD = re.compile(r"^\s*(?:#+|//+|/\*+|\*+|--|;+|>+)?\s*(?:[-*+]\s+|\d+[.)]\s+)?")
CODE_CHARS = re.compile(r"[(){}\[\]=<>$|&;\"\\]")
SENTENCE_END = re.compile(r"(?<=[.!?:;])\s+(?=[A-Z`(\[\"'*_])")
COMMENT = re.compile(r"^\s*(#|//|/\*|\*|--|;)")
HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
INTERPRETER = re.compile(
    r"\b(python[0-9.]*|node|perl|ruby|jq|awk|gawk|sed|sqlite3|bash|sh|zsh|osascript|deno|bun|tsx|psql|mysql)\b")
DIRECTIVE = re.compile(
    r"^(shellcheck|eslint|prettier|noqa|pylint|type:|@?ts-|biome-|istanbul|c8 |nolint|rubocop|fmt:|isort:|mypy:)",
    re.I)
TEST_PATH = re.compile(
    r"(^|/)(tests?|__tests__|specs?|fixtures?|testdata)(/|$)|(^|/)test_[^/]*$|[._-]test\.[^/]+$|_test\.[^/]+$")
SOURCE_EXT = {
    "sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "rs", "rb", "pl", "lua", "c", "h",
    "cc", "cpp", "java", "kt", "swift", "gd", "cs",
}
MARKDOWN_EXT = {"md", "markdown", "mdx"}


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, capture_output=True, check=True).stdout


def stem(word):
    for suffix in ("ing", "ed", "es", "s", "e"):
        if len(word) - len(suffix) >= 4 and word.endswith(suffix):
            word = word[: -len(suffix)]
            break
    if len(word) > 4 and word[-1] == word[-2] and word[-1] not in "aeiou":
        word = word[:-1]
    return word


def words_of(text):
    found = set()
    for match in WORD.finditer(text):
        word = match.group(0).lower()
        if len(word) >= 3 and word not in STOP:
            found.add(stem(word))
    return found


def prose_body(line):
    body = LEAD.sub("", line, count=1)
    if DIRECTIVE.match(body):
        return None
    words = WORD.findall(body)
    if sum(1 for w in words if len(w) > 1) < 5:
        return None
    visible = len(re.sub(r"\s", "", body))
    if visible == 0 or sum(len(w) for w in words) / visible < 0.6:
        return None
    if len(CODE_CHARS.findall(body)) / visible > 0.07:
        return None
    return body.strip()


def sentences(path, text):
    """Return (first_line, last_line, sentence) for every prose sentence."""
    name = path.rsplit("/", 1)[-1]
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    lines = text.split("\n")
    source = ext in SOURCE_EXT or bool(lines and lines[0].startswith("#!"))
    markdown = ext in MARKDOWN_EXT
    found, para = [], []
    fenced = False
    heredoc, heredoc_is_code = None, False

    def flush():
        if not para:
            return
        joined, starts = "", []
        for number, body in para:
            starts.append((len(joined), number))
            joined += body + " "
        pos = 0
        for piece in SENTENCE_END.split(joined):
            begin = joined.find(piece, pos)
            pos = begin + len(piece)
            first = last = para[0][0]
            for offset, number in starts:
                if offset <= begin:
                    first = number
                if offset < pos:
                    last = number
            piece = piece.strip()
            if len(WORD.findall(piece)) >= 5:
                found.append((first, last, piece))
        para.clear()

    for number, line in enumerate(lines, 1):
        if markdown and line.lstrip().startswith("```"):
            fenced = not fenced
            flush()
            continue
        if fenced:
            continue
        if source:
            if heredoc is not None:
                if line.strip() == heredoc:
                    heredoc = None
                    flush()
                    continue
                eligible = not heredoc_is_code
            else:
                is_comment = bool(COMMENT.match(line)) and not line.startswith("#!")
                opener = None if is_comment else HEREDOC.search(line)
                if opener:
                    heredoc = opener.group(2)
                    heredoc_is_code = bool(INTERPRETER.search(line[: opener.start()]))
                    flush()
                    continue
                eligible = is_comment
            if not eligible:
                flush()
                continue
        body = prose_body(line)
        if body is None:
            flush()
            continue
        para.append((number, body))
        if markdown:
            flush()
    flush()
    return found


C_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def header_path(field, prefix):
    """Return the path a ---/+++ header names under prefix, or None for /dev/null."""
    if field.startswith('"'):
        raw, i = bytearray(), 1
        while field[i] != '"':
            if field[i] != "\\":
                raw += field[i].encode("utf-8", "surrogateescape")
                i += 1
            elif field[i + 1] in C_ESCAPES:
                raw.append(C_ESCAPES[field[i + 1]])
                i += 2
            else:
                raw.append(int(field[i + 1: i + 4], 8))
                i += 4
        field = raw.decode("utf-8", "surrogateescape")
    else:
        field = field.rstrip("\t")
    return field[len(prefix):] if field.startswith(prefix) else None


def changed_lines(diff_text):
    removed, added = collections.defaultdict(set), collections.defaultdict(set)
    old = new = None
    for line in diff_text.split("\n"):
        if line.startswith("--- "):
            old = header_path(line[4:], "a/")
        elif line.startswith("+++ "):
            new = header_path(line[4:], "b/")
        elif line.startswith("@@"):
            hunk = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
            if not hunk:
                continue
            old_start, old_count = int(hunk[1]), int(hunk[2] or 1)
            new_start, new_count = int(hunk[3]), int(hunk[4] or 1)
            if old:
                removed[old].update(range(old_start, old_start + old_count))
            if new:
                added[new].update(range(new_start, new_start + new_count))
    return removed, added


def read_blobs(rev, paths):
    """Return {path: text} for the non-binary, small, non-test files at rev, all of them when paths is None."""
    if paths is not None and not paths:
        return {}
    scope = ["--", *paths] if paths is not None else []
    listing = git("--literal-pathspecs", "ls-tree", "-r", "-l", "-z", rev, *scope)
    wanted = []
    for entry in listing.decode("utf-8", "surrogateescape").split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        _, kind, oid, size = meta.split()
        if kind == "blob" and size != "-" and int(size) <= MAX_BLOB_BYTES and not TEST_PATH.search(path):
            wanted.append((path, oid))
    if not wanted:
        return {}
    out = git("cat-file", "--batch", data="".join(f"{oid}\n" for _, oid in wanted).encode())
    blobs, pos = {}, 0
    for path, _ in wanted:
        newline = out.index(b"\n", pos)
        size = int(out[pos:newline].split()[2])
        data = out[newline + 1: newline + 1 + size]
        pos = newline + 1 + size + 1
        if b"\0" not in data[:8000]:
            blobs[path] = data.decode("utf-8", "replace")
    return blobs


def main():
    sys.stdout.reconfigure(errors="backslashreplace")
    diff = git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative", "-M",
               "--src-prefix=a/", "--dst-prefix=b/", MERGE_BASE, HEAD).decode("utf-8", "surrogateescape")
    removed, added = changed_lines(diff)

    corpus = []  # (path, first, last, text, words, added_here)
    for path, text in read_blobs(HEAD, None).items():
        lines_added = added.get(path, ())
        for first, last, sentence in sentences(path, text):
            touched = any(n in lines_added for n in range(first, last + 1))
            corpus.append((path, first, last, sentence, words_of(sentence), touched))

    probes = [(c[0], c[1], c[3], c[4], "+") for c in corpus if c[5]]
    for path, text in read_blobs(MERGE_BASE, sorted(removed)).items():
        for first, last, sentence in sentences(path, text):
            if any(n in removed[path] for n in range(first, last + 1)):
                probes.append((path, first, sentence, words_of(sentence), "-"))

    total = len(corpus) or 1
    frequency = collections.Counter()
    by_word = collections.defaultdict(list)
    for index, entry in enumerate(corpus):
        frequency.update(entry[4])
        for word in entry[4]:
            by_word[word].append(index)
    rarity = {word: math.log(total / count) for word, count in frequency.items()}
    unseen = math.log(total)

    def weight(words):
        return sum(rarity.get(w, unseen) for w in words)

    best = {}  # corpus index -> (score, probe)
    for probe in probes:
        path, _, _, words, side = probe
        if len(words) < MIN_SHARED_WORDS:
            continue
        probe_weight = weight(words)
        overlap = collections.Counter()
        for word in words:
            if frequency.get(word, 0) <= total * COMMON_SHARE:
                for index in by_word.get(word, ()):
                    overlap[index] += 1
        scored = []
        for index, count in overlap.items():
            if count < MIN_SHARED_WORDS:
                continue
            c_path, _, _, _, c_words, c_added = corpus[index]
            if c_added and (c_path == path or side == "-"):
                continue
            shared_weight = weight(words & c_words)
            if shared_weight < MIN_SHARED_WEIGHT:
                continue
            score = shared_weight / math.sqrt(probe_weight * weight(c_words))
            if score >= MIN_SCORE:
                scored.append((score, index))
        scored.sort(reverse=True)
        for score, index in scored[:PER_PROBE]:
            if index not in best or best[index][0] < score:
                best[index] = (score, probe)

    changed_files = len(set(removed) | set(added))
    print(f"restatement sweep: {len(probes)} changed sentences in {changed_files} files since "
          f"{BASE_NAME} ({MERGE_BASE[:12]}); {len(best)} candidate restatements")
    for index, (score, probe) in sorted(best.items(), key=lambda item: (-item[1][0], item[0])):
        c_path, c_first, _, c_text, _, c_added = corpus[index]
        note = " (also added by this diff)" if c_added else ""
        print(f"{c_path}:{c_first}:{note} {c_text}")
        print(f"  resembles {probe[4]} {probe[0]}:{probe[1]}: {probe[2]}")


main()
PY
