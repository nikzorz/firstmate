#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory, or pipe the wake drain into
// another command?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. A wake drain piped into a filter can hide wake rows that the drain's
// printed acknowledgement then marks handled without their having been read.
// This policy blocks exactly those two classes of command, and lets through a
// `cd` that provably lands in the directory the session is already in; the
// environmental scoping to the real primary checkout lives in the
// bin/fm-cd-pretool-check.sh transport, not here. See docs/cd-guard.md for the
// full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions, and resolves a literal `cd` target
// against the filesystem.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...). Only a cd whose literal target resolves to the directory the session is already in passes.",
  "filtered-drain":
    "piping bin/fm-wake-drain.sh into another command is blocked; a filter can hide wake rows, and the acknowledgement the drain prints would then mark them handled without their having been read. Run the drain on its own and read all of its output; only a drain carrying --ack-through may be piped.",
};

const DRAIN_SCRIPT = "fm-wake-drain.sh";

// Interpreters that run a script named as their first operand.
const SCRIPT_INTERPRETERS = new Set(["sh", "bash", "zsh"]);

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// A drain that acknowledges prints no wake rows, so piping it hides nothing.
function isUnacknowledgedDrain(position) {
  if (!position.command) return false;
  let args = position.words.slice(position.index + 1);
  let name = basename(position.command.value);
  if (SCRIPT_INTERPRETERS.has(name)) {
    const script = args.findIndex((word) => !word.value.startsWith("-"));
    if (script < 0) return false;
    name = basename(args[script].value);
    args = args.slice(script + 1);
  }
  if (name !== DRAIN_SCRIPT) return false;
  return !args.some((word) => word.value === "--ack-through");
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

// The physical path, with no lexical `..` folding ahead of symlink resolution.
function physicalPath(path) {
  try {
    return realpathSync.native(path);
  } catch {
    return null;
  }
}

// The shell searches CDPATH for any other relative spelling, and the shell's
// CDPATH is not visible here.
function bypassesCdpath(target) {
  return isAbsolute(target) || /^\.\.?(\/|$)/.test(target);
}

function isLiteralPath(word) {
  return word.literal && word.subs.length === 0 && !word.unquotedExpansion && word.value !== "";
}

// True only when the cd provably leaves the shell where it already is. Every
// doubt - an expanded or missing target, an option, an unknown or unreadable
// session directory - is false, so the caller denies.
function staysInSessionDirectory(operands, sessionCwd) {
  if (!sessionCwd || !isAbsolute(sessionCwd)) return false;
  const targets = operands[0]?.value === "--" ? operands.slice(1) : operands;
  if (targets.length !== 1 || !isLiteralPath(targets[0])) return false;
  const target = targets[0].value;
  if (!bypassesCdpath(target)) return false;
  const home = physicalPath(sessionCwd);
  if (!home) return false;
  // A logical cd folds `..` before following symlinks and a physical cd after,
  // so a target that crosses a symlink can land in two places; both must be
  // the session directory.
  const followedThenFolded = physicalPath(isAbsolute(target) ? target : `${sessionCwd}/${target}`);
  const foldedThenFollowed = physicalPath(resolve(sessionCwd, target));
  return followedThenFolded === home && foldedThenFollowed === home;
}

function decision(command, sessionCwd = "") {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };

  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    if (isPipe(separators[index]) && isUnacknowledgedDrain(commandPosition(nodes[index]))) {
      return deny("filtered-drain");
    }
    if (!nodePersists(separators, index)) continue;
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(nodes[index]);
    if (hasPathQualifiedCommandPrefix(position)) continue;
    if (hasCommandQueryPrefix(position)) continue;
    let command = position.command;
    let wordIndex = position.index;
    while (command && (command.value === "builtin" || command.value === "command")) {
      wordIndex += 1;
      command = position.words[wordIndex];
    }
    if (!command) continue;
    if (!CD_BUILTINS.has(command.value)) continue;
    if (position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper))) continue;
    if (command.value === "cd" && staysInSessionDirectory(position.words.slice(wordIndex + 1), sessionCwd)) continue;
    return deny("persistent-cd");
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, cwd: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name === "--cwd") {
      if (i + 1 >= argv.length) throw new Error("--cwd requires a value");
      result.cwd = argv[i + 1];
      i += 1;
      continue;
    }
    if (name.startsWith("--cwd=")) {
      result.cwd = name.slice("--cwd=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.cwd);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
