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
import re
import shlex
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
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
    if not segment or segment[0] != "git":
        continue
    # Skip known global options without mistaking their values for commands.
    index = 1
    while index < len(segment):
        arg = segment[index]
        if arg in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            index += 2
        elif arg.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--config-env=", "-C", "-c")):
            index += 1
        else:
            break
    if index >= len(segment) or segment[index] != "commit":
        continue
    args = segment[index + 1:]
    messages = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            break
        # File messages belong to the real commit-msg hook, not this parser.
        if arg in ("-F", "--file") or arg.startswith(("--file=", "-F")):
            messages = []
            break
        if arg in ("-m", "--message") and index + 1 < len(args):
            index += 1
            messages.append(args[index])
        elif arg.startswith("--message="):
            messages.append(arg[10:])
        elif arg.startswith("-m") and len(arg) > 2:
            messages.append(arg[2:])
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
