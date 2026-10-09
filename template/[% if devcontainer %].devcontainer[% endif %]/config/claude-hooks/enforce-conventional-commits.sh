#!/usr/bin/env bash
# enforce-conventional-commits.sh — PreToolUse hook for Bash.
#
# Enforces Conventional Commits at the AI boundary. Lefthook's commit-msg
# hook already enforces this for human commits, but Claude Code can bypass
# git hooks via --no-verify (which is separately blocked by block-no-verify.sh).
# Belt-and-suspenders: refuse non-conforming `git commit -m` messages here too.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Python is required for safe shell tokenization. If parsing is unavailable or
# fails, let lefthook validate the actual commit message instead.
command -v python3 >/dev/null 2>&1 || exit 0
msg="$(python3 -c '
import os
import re
import shlex
import sys

try:
    command = sys.argv[1].replace(chr(92) + "\n", "")
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    # Keep newlines as command boundaries, rather than ordinary whitespace.
    lexer.whitespace = " \t\r"
    segments = []
    segment = []
    heredocs = []
    for token in lexer:
        if token == "\n":
            segments.append(segment)
            segment = []
            # Heredoc bodies are data, never shell command segments. Consume
            # them directly so their quotes and command-like text stay inert.
            for delimiter, strip_tabs in heredocs:
                for line in lexer.instream:
                    if (line.lstrip("\t") if strip_tabs else line).rstrip("\n") == delimiter:
                        break
            heredocs = []
        elif token in (";", "&&", "||", "|", "&"):
            segments.append(segment)
            segment = []
        else:
            if segment and segment[-1] == "<<":
                strip_tabs = token.startswith("-")
                heredocs.append((token[1:] if strip_tabs else token, strip_tabs))
            segment.append(token)
    segments.append(segment)
except ValueError:
    sys.exit(0)

for segment in segments:
    # Locate the executable after shell assignments, wrappers and control words.
    index = 0
    while index < len(segment):
        word = segment[index]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            index += 1
        elif word in ("command", "builtin", "exec", "nohup", "time", "-p",
                      "(", "{", "!", "if", "then", "do", "else", "elif", "while", "until"):
            index += 1
        elif word == "env":
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                index += 1
                if option in ("-u", "--unset", "-C", "--chdir"):
                    index += 1
                elif option == "--":
                    break
        else:
            break
    if index >= len(segment) or os.path.basename(segment[index]) != "git":
        continue
    index += 1
    # All leading Git options precede the subcommand; only these consume a
    # separate value. Bare --exec-path consumes none; = forms are one token.
    while index < len(segment) and segment[index].startswith("-"):
        option = segment[index]
        index += 1
        if option in ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                      "--super-prefix", "--config-env"):
            index += 1
    if index >= len(segment) or segment[index] != "commit":
        continue
    args = segment[index + 1:]
    messages = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            break
        name, equals, value = arg.partition("=")
        is_file = len(name) >= 5 and "--file".startswith(name)
        is_message = len(name) >= 5 and "--message".startswith(name)
        if arg.startswith("--"):
            if is_file:
                messages = []
                break
            if is_message:
                if equals:
                    messages.append(value)
                elif index + 1 < len(args):
                    index += 1
                    messages.append(args[index])
        elif arg.startswith("-"):
            # In short clusters, m/F own the remaining characters or next arg.
            for offset, letter in enumerate(arg[1:], start=1):
                if letter == "F":
                    messages = []
                    break
                if letter == "m":
                    if offset + 1 < len(arg):
                        messages.append(arg[offset + 1:])
                    elif index + 1 < len(args):
                        index += 1
                        messages.append(args[index])
                    break
            else:
                letter = ""
            if letter == "F":
                break
        index += 1
    parsed = []
    for message in messages:
        if message.startswith("$("):
            # Recognize only a literal cat heredoc owned by this -m argument.
            # Never evaluate shell substitutions or search the whole command.
            match = re.fullmatch(
                r"\$\(cat\s+<<([\"\x27]?)([A-Za-z0-9_]+)\1[ \t]*\n(.*?)\n\2\n?\)",
                message, re.DOTALL,
            )
            if not match:
                sys.exit(0)
            message = match[3]
        parsed.append(message)
    if parsed:
        print("\n\n".join(parsed))
        sys.exit(0)
' "$command")"

# If we couldn't parse a message, don't block — let git itself error out.
[[ -n "$msg" ]] || exit 0

# Allow merge / revert / fixup commits that git itself generates.
case "$msg" in
"Merge "* | "Revert "* | "fixup!"* | "squash!"*) exit 0 ;;
esac

# Delegate validation to commitlint via the Taskfile — the single source of
# truth for the allowed type list and rules (commitlint.config.mjs). Pipe the
# message via stdin so it is never re-quoted or evaluated as a shell/template
# expression by go-task.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Fail open if the toolchain is unavailable or the target doesn't exist in the local Taskfile.
command -v task >/dev/null 2>&1 || exit 0
task lint:commit-msg:text --summary >/dev/null 2>&1 || exit 0

if ! output="$(printf '%s' "$msg" | task lint:commit-msg:text 2>&1)"; then
    {
        echo "enforce-conventional-commits: commit message does not match Conventional Commits."
        echo "  got: $msg"
        echo "$output"
    } >&2
    exit 2
fi

exit 0
