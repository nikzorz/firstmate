#!/usr/bin/env python3
"""Find the agent session that wrote a piece of code, and show what it had in front of it.

  find <needle> [--at <commit time>]   sessions that wrote or mention the needle, oldest first
  show <transcript> [--before <time>]  what one session loaded, invoked, read, edited and ran

Reads Claude Code transcripts under --root (default ~/.claude/projects) and changes nothing.
Run it as `python3 -I sessions.py -h`.
"""
import argparse
import io
import json
import os
import re
import shlex
import sys
from datetime import datetime, timedelta, timezone

ROOT = os.path.expanduser("~/.claude/projects")
WRITE_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
# A no-mistakes run works in <data dir>/worktrees/<repo>/<run id>, so its agents'
# sessions sit beside worker sessions and are the reviewer side's trace.
PIPELINE_CWD = re.compile(r"/\.no-mistakes/worktrees/[^/]+/([^/]+)")
PIPELINE_DIR = re.compile(r"-no-mistakes-worktrees-[0-9a-f]+-([0-9A-Z]+)")
PIPELINE_PHASE = re.compile(r"You are the (\w+) phase inside an already active no-mistakes run")
WRITE_VERBS = {"mv", "cp", "rm", "tee", "touch", "truncate", "install", "patch"}
GIT_WRITES = {"mv", "rm", "apply"}
REDIRECTS = {">", ">>", ">|", "&>", "&>>"}
SHELL_PUNCTUATION = "();<>|&\n"
HEREDOC = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)(\w+)\2")
# An inline script (python3 - <<EOF, python3 -c, node -e) that writes a file.
SCRIPT = re.compile(r"(?:python|perl|node|ruby)[\d.]*")
SCRIPT_WRITE = re.compile(
    r"open\([^)]*['\"][wax]b?\+?['\"]|\.write_text\(|\.write_bytes\(|writeFileSync|appendFileSync|File\.write")


def transcripts(root):
    # os.walk, because folder names start with "-" (grep reads them as flags) and
    # subagent transcripts sit one level down, in <session>/subagents/
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".jsonl"):
                yield os.path.join(dirpath, f)


def records(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(r, dict):
                yield r


def parse_time(text):
    t = datetime.fromisoformat(text.strip().replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def when(r):
    t = r.get("timestamp")
    if not isinstance(t, str):
        return None
    try:
        return parse_time(t)
    except ValueError:
        return None


def strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings(v)


def contains(obj, needle):
    return any(needle in s for s in strings(obj))


def without_old_text(obj):
    if isinstance(obj, dict):
        return {k: without_old_text(v) for k, v in obj.items() if k != "old_string"}
    if isinstance(obj, list):
        return [without_old_text(v) for v in obj]
    return obj


def tool_uses(r):
    if r.get("type") != "assistant":
        return []
    content = (r.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    return [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]


def lift_heredocs(command):
    """Split a command into its shell text and (opener line, body) pairs, each body ending at its terminator."""
    lines, text, bodies, i = command.split("\n"), [], [], 0
    while i < len(lines):
        line = lines[i]
        text.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            strip, word, body = m.group(1) == "-", m.group(3), []
            while i < len(lines):
                body_line = lines[i]
                i += 1
                if (body_line.lstrip("\t") if strip else body_line) == word:
                    break
                body.append(body_line)
            bodies.append((line, "\n".join(body)))
    return "\n".join(text), bodies


class CommentKeepsNewline(io.StringIO):
    """Leaves the newline that ends a comment in the stream, so it still ends the statement."""

    def readline(self, size=-1):
        line = super().readline(size)
        if line.endswith("\n"):
            self.seek(self.tell() - 1)
        return line


def statements(text):
    """The shell text's statements as word lists, split at unquoted ;, &, |, parentheses and newlines."""
    lex = shlex.shlex(CommentKeepsNewline(text), posix=True, punctuation_chars=SHELL_PUNCTUATION)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        tokens = re.findall(r"[^\s();<>|&]+|[();<>|&\n]+", text)
    result, words = [], []
    for t in tokens:
        if t and set(t) <= set(SHELL_PUNCTUATION) and not set(t) & set("<>"):
            result.append(words)
            words = []
        else:
            words.append(t)
    return [w for w in result + [words] if w]


def verb_writes(words):
    words = [w for w in words if not re.match(r"\w+=", w)] or [""]
    verb, args = os.path.basename(words[0]), words[1:]
    if verb in WRITE_VERBS:
        return True
    if verb in ("sed", "perl"):
        return any(re.match(r"-[a-zA-Z]*i|--in-place", a) for a in args)
    if verb == "git":
        sub = [a for n, a in enumerate(args) if not a.startswith("-") and (n == 0 or args[n - 1] not in ("-C", "-c"))]
        return bool(sub) and (sub[0] in GIT_WRITES or sub[0] == "checkout" and "--" in args)
    return False


def written(words):
    """What one statement writes: its redirect targets, and all its words when its command writes files."""
    out = [words[n + 1] for n, w in enumerate(words[:-1]) if w in REDIRECTS and words[n + 1] != "/dev/null"]
    return out + [" ".join(words)] if verb_writes(words) else out


def script(words, body=""):
    """The source of an inline script when the statement runs one that writes files, else None."""
    words = [w for w in words if not re.match(r"\w+=", w)]
    source = " ".join(words) + "\n" + body
    if words and SCRIPT.fullmatch(os.path.basename(words[0])) and SCRIPT_WRITE.search(source):
        return source
    return None


def command_writes(command):
    """Each text a shell command writes: redirect targets, write-verb statements, written-out heredoc bodies, and writing inline scripts."""
    text, bodies = lift_heredocs(command)
    out = []
    for words in statements(text):
        out += written(words) + [s for s in [script(words)] if s]
    for opener, body in bodies:
        for words in statements(opener):
            if written(words):
                out.append(body)
            out += [s for s in [script(words, body)] if s]
    return out


def write_shaped(command):
    """True when a shell command changes files."""
    return bool(command_writes(command))


def bash_writes(command, needle):
    """True when what a shell command writes contains the needle."""
    return any(needle in w for w in command_writes(command))


def wrote(block, needle):
    name, i = block.get("name"), block.get("input") or {}
    if name in WRITE_TOOLS:
        return contains(without_old_text(i), needle)
    if name == "Bash":
        return bash_writes(str(i.get("command", "")), needle)
    return False


def kind(path, cwd):
    m = PIPELINE_CWD.search(cwd or "") or PIPELINE_DIR.search(path)
    if m:
        phase = PIPELINE_PHASE.search(prompt_text(path))
        return f"pipeline {m.group(1)}" + (f" {phase.group(1)}" if phase else "")
    return "subagent" if f"{os.sep}subagents{os.sep}" in path else "session"


def prompt_text(path):
    for r in records(path):
        if r.get("type") == "user" and not r.get("isMeta"):
            c = (r.get("message") or {}).get("content")
            text = c if isinstance(c, str) else " ".join(
                b.get("text", "") for b in c or [] if isinstance(b, dict))
            if text.strip():
                return text
    return ""


def first_prompt(path):
    return " ".join(prompt_text(path).split())[:140]


def might_match(path, needle, at, slack):
    if at and os.path.getmtime(path) < (at - slack).timestamp():
        return False
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    escaped = json.dumps(needle)[1:-1], json.dumps(needle, ensure_ascii=False)[1:-1]
    return needle in text or any(e in text for e in escaped)


def scan(path, needle):
    start = end = cwd = None
    did_write = mentioned = False
    for r in records(path):
        t = when(r)
        if t:
            start, end = start or t, t
        cwd = cwd or r.get("cwd")
        for b in tool_uses(r):
            if wrote(b, needle):
                did_write = mentioned = True
        if not mentioned and contains(r, needle):
            mentioned = True
    return start, end, cwd, did_write, mentioned


def find(needle, at, slack, root):
    hits = []
    for path in transcripts(root):
        if not might_match(path, needle, at, slack):
            continue
        start, end, cwd, did_write, mentioned = scan(path, needle)
        if not mentioned or not start:
            continue
        if at and not (start - slack <= at <= end + slack):
            continue
        hits.append((start, end, did_write, kind(path, cwd), path))
    for start, end, did_write, label, path in sorted(hits):
        mark = "WROTE" if did_write else "mentions"
        if at and start <= at <= end:
            mark += " AT"
        until = f"{end:%H:%M}" if end.date() == start.date() else f"{end:%Y-%m-%d %H:%M}"
        print(f"{mark:11} {start:%Y-%m-%d %H:%M}-{until}Z  {label:40} {os.path.abspath(path)}")
        print(f"            {first_prompt(path)}")
    if not hits:
        sys.exit("No session matched." + (" Widen --slack, or drop --at." if at else ""))


def show(path, before):
    loaded, rules, skills, reads, edits, bash = [], [], [], [], [], []
    start = end = cwd = None
    for r in records(path):
        t = when(r)
        if before and t and t > before:
            break
        if t:
            start, end = start or t, t
        cwd = cwd or r.get("cwd")
        a = r.get("attachment") if isinstance(r.get("attachment"), dict) else {}
        if a.get("type") == "instructions":
            loaded += [f"{f.get('type', '?'):8} {f.get('path')}" for f in a.get("files", []) if isinstance(f, dict)]
        elif a.get("type") == "nested_memory":
            rules.append(f"{t:%H:%M:%S}Z {a.get('path')}" if t else str(a.get("path")))
        elif "memor" in str(a.get("type", "")):
            loaded.append(f"memory   {json.dumps(a)[:160]}")
        if r.get("type") == "user":
            c = (r.get("message") or {}).get("content")
            if isinstance(c, str):
                skills += [f"/{m}" for m in re.findall(r"<command-name>/?([^<]+)</command-name>", c)]
        for b in tool_uses(r):
            i = b.get("input") or {}
            name = b.get("name")
            if name == "Skill":
                skills.append(i.get("skill"))
            elif name == "Read":
                reads.append(i.get("file_path"))
            elif name in WRITE_TOOLS:
                edits.append(i.get("file_path") or i.get("notebook_path"))
            elif name == "Bash":
                command = str(i.get("command", ""))
                line = " ".join(command.split())[:160]
                bash.append(("WRITE " if write_shaped(command) else "      ") + line)
    span = f"{start:%Y-%m-%d %H:%M:%S}Z to {end:%Y-%m-%d %H:%M:%S}Z" if start else "no timestamps"
    print(f"== {kind(path, cwd)}, {span}, cwd {cwd or '?'}")
    print(f"   {first_prompt(path)}")
    for title, items in (("Loaded at start", loaded), ("Rules loaded on demand", rules),
                         ("Skills invoked", skills), ("Files read", reads),
                         ("Files edited", edits), ("Commands run", bash)):
        items = list(dict.fromkeys(items))
        print(f"== {title} ({len(items)})")
        for item in items:
            print(f"   {item}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", default=ROOT, help="transcript root (default ~/.claude/projects)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("find", help="sessions that wrote or mention the needle, oldest first")
    s.add_argument("needle", help="a file path, or text unique to the line")
    s.add_argument("--at", help="commit time (git show -s --format=%%aI <sha>); keeps sessions spanning it")
    s.add_argument("--slack", type=int, default=30, help="minutes either side of --at (default 30)")
    s = sub.add_parser("show", help="what one session loaded, read, invoked, edited and ran")
    s.add_argument("transcript", help="path from `find`, or one relative to the root (after `--` when it starts with -)")
    s.add_argument("--before", help="stop at this time, so only what the session had by then is listed")
    a = p.parse_args()
    try:
        if a.cmd == "find":
            at = parse_time(a.at) if a.at else None
            find(a.needle, at, timedelta(minutes=a.slack), a.root)
        else:
            path = a.transcript if os.path.isabs(a.transcript) else os.path.join(a.root, a.transcript)
            show(path, parse_time(a.before) if a.before else None)
    except ValueError as e:
        sys.exit(f"Bad time: {e}")
    except OSError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
