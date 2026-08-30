#!/usr/bin/env bash
# guard-process-kill.sh — ask before a Bash command can terminate a process.
#
# A process can belong to another interactive session, agent, or user. There is
# no authoritative session-owned PID list in this hook contract, so ownership is
# never inferred. Only exact, non-terminating `kill -l` and `kill -0 <PID>...`
# segments are allowed without an explicit user decision. Expansion syntax is an
# approval boundary only for commands that already name a terminator token: it
# can hide a terminator's *form*, but a command with no terminator token
# anywhere cannot terminate a process through expansion this hook is willing to
# guess about, so such commands fall through to the parser below instead.
set -euo pipefail

emit_ask() {
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg reason "$1" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'
    else
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The process-termination rule requires approval because guard-process-kill cannot inspect commands without jq."}}'
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    emit_ask "guard-process-kill requires jq to inspect the Bash command safely."
    exit 0
fi

input="$(cat)"
if ! command="$(printf '%s' "$input" | jq -er '.tool_input.command // empty')"; then
    emit_ask "guard-process-kill could not inspect the Bash command safely."
    exit 0
fi
[[ -n "$command" ]] || exit 0

matched_command=""
if [[ "$command" =~ (^|[^[:alnum:]_])(kill|pkill|killall|xkill)($|[^[:alnum:]_]) ]]; then
    matched_command="${BASH_REMATCH[2]}"
fi

# A shell grammar is deliberately not reimplemented here. Expansion syntax can
# produce a command that is absent from the token stream, so once a terminator
# token is already present, expansion syntax anywhere in the command is an
# approval boundary rather than an input to guess about. A command that names
# no terminator token at all cannot terminate a process through expansion this
# hook is willing to guess about, so it falls through to the parser below.
if [[ -n "$matched_command" ]] && [[ "$command" == *'$'* || "$command" == *'`'* || "$command" == *$'\n'* || "$command" == *$'\r'* ||
    "$command" == *'['* || "$command" == *'?'* || "$command" == *'*'* ||
    "$command" == *'{'* || "$command" == *'}'* ||
    "$command" == *'@('* || "$command" == *'+('* || "$command" == *'!('* ]]; then
    decision="ask"
elif ! command -v python3 >/dev/null 2>&1; then
    emit_ask "guard-process-kill requires python3 to inspect the Bash command safely."
    exit 0
elif ! decision="$(
    python3 - "$command" <<'PY'
import os
import re
import shlex
import sys

TERMINATORS = {"kill", "pkill", "killall", "xkill"}
TERMINATOR_TEXT = re.compile(r"(?<![A-Za-z0-9_])(?:kill|pkill|killall|xkill)(?![A-Za-z0-9_])")
SHELLS = {"sh", "bash", "dash", "zsh", "fish"}
EVALUATORS = {"eval", "source", ".", "trap"}
EVALUATOR_CONTROLS = {"if", "then", "elif", "else", "while", "until", "do"}
WRAPPERS = {
    "chrt", "command", "builtin", "doas", "env", "exec", "flock", "ionice",
    "nice", "nohup", "setsid", "stdbuf", "sudo", "taskset", "time", "timeout", "xargs",
}
CONTROL = {"if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac"}
OPERATORS = {";", "&&", "||", "|", "&"}
REDIRECTS = {"<", ">", ">>", "<<", "<<<", "<>", ">&", "<&"}
PID = re.compile(r"[1-9][0-9]*")
ASSIGNMENT_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\+)?=.*")
ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
SUDO_SHORT_OPTIONS_WITH_ARGUMENT = {"a", "C", "D", "g", "h", "p", "R", "r", "t", "T", "U", "u"}
SUDO_SHORT_OPTIONS_WITHOUT_ARGUMENT = {"A", "b", "B", "E", "e", "H", "K", "k", "l", "n", "P", "S", "v", "V"}
SUDO_LONG_OPTIONS_WITH_ARGUMENT = {
    "--chdir", "--close-from", "--command-timeout", "--group", "--host", "--other-user", "--prompt",
    "--role", "--type", "--user",
}
SUDO_LONG_OPTIONS_WITHOUT_ARGUMENT = {
    "--askpass", "--background", "--bell", "--edit", "--help", "--list", "--non-interactive",
    "--preserve-groups", "--remove-timestamp", "--reset-timestamp", "--set-home", "--stdin", "--validate",
    "--version",
}


def name(token):
    return ascii_lower(os.path.basename(token))


def ascii_lower(value):
    return value.translate(ASCII_LOWER)


def safe_kill(args):
    # Equivalent spellings stay approval-gated rather than expanding a parser
    # that could mistake a terminating invocation for a probe.
    return args == ["-l"] or (
        len(args) >= 2 and args[0] == "-0" and all(PID.fullmatch(pid) for pid in args[1:])
    )


def env_uses_split_string(args):
    # GNU env accepts options before assignments and the command. Track only
    # that region so a command's own `-S...` argument is not mistaken for env.
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return False
        if token == "--split-string" or token.startswith("--split-string="):
            return True
        if token in {"--chdir", "--unset"}:
            index += 2
            continue
        if token.startswith("--"):
            index += 1
            continue
        if token == "-" or not token.startswith("-"):
            if "=" in token and not token.startswith("="):
                index += 1
                continue
            return False
        for position, option in enumerate(token[1:]):
            if option == "S":
                return True
            if option in {"C", "u"}:
                if position + 1 == len(token[1:]):
                    index += 1
                break
        index += 1
    return False


def timeout_is_active(args):
    # GNU timeout's help/version forms do not execute a child or send signals.
    # All other forms are approval-gated rather than reimplementing its grammar.
    return args not in (["--help"], ["--version"])


def sudo_uses_shell(args):
    # Stop at sudo's command. Unknown or incomplete option grammar is unsafe.
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return index + 1 >= len(args)
        if token in {"--shell", "--login"}:
            return True
        if token in SUDO_LONG_OPTIONS_WITH_ARGUMENT:
            if index + 1 >= len(args):
                return True
            index += 2
            continue
        option, separator, _ = token.partition("=")
        if separator and option in SUDO_LONG_OPTIONS_WITH_ARGUMENT:
            index += 1
            continue
        if token in SUDO_LONG_OPTIONS_WITHOUT_ARGUMENT:
            index += 1
            continue
        if token.startswith("--"):
            return True
        if token == "-" or not token.startswith("-"):
            return False
        for position, option in enumerate(token[1:]):
            if option in {"i", "s"}:
                return True
            if option in SUDO_SHORT_OPTIONS_WITH_ARGUMENT:
                if position + 1 == len(token[1:]):
                    if index + 1 >= len(args):
                        return True
                    index += 1
                break
            if option not in SUDO_SHORT_OPTIONS_WITHOUT_ARGUMENT:
                return True
        index += 1
    return True


def command_builtin_payload(command, args):
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return args[index + 1] if index + 1 < len(args) else None
        if command == "command" and token == "-p":
            index += 1
            continue
        if token.startswith("-"):
            options = token[1:]
            if "v" in options or "V" in options:
                return None
            if command == "command" and options and set(options) == {"p"}:
                index += 1
                continue
            return None
        return token
    return None


def assignment_width(tokens):
    if ASSIGNMENT_WORD.fullmatch(tokens[0]):
        return 1
    return 0


def effective_command(segment):
    tokens = segment
    while tokens:
        token, rest = tokens[0], tokens[1:]
        width = assignment_width(tokens)
        if width:
            tokens = tokens[width:]
            continue
        current = name(token)
        if current == "time":
            while rest and rest[0] in {"-p", "--"}:
                rest = rest[1:]
            tokens = rest
            continue
        if current == "!" or current in EVALUATOR_CONTROLS:
            tokens = rest
            continue
        if current == "coproc":
            # A simple coprocess starts with its command; named compound forms
            # contain `{` and are already rejected before token inspection.
            return rest
        return tokens
    return []


def inspect_segment(segment):
    if not segment:
        return "allow"
    effective = effective_command(segment)
    if not effective:
        return "allow"
    command, args = name(effective[0]), effective[1:]
    # Shells can read executable text from `-c` arguments or redirects, so ask
    # for every shell launcher before redirect handling.
    if command in SHELLS or command in EVALUATORS:
        return "ask"
    # GNU env's split-string options re-tokenize their payload as a command.
    if command == "env" and env_uses_split_string(args):
        return "ask"
    if command == "timeout" and timeout_is_active(args):
        return "ask"
    # Wrapper args can launch a shell through nested wrappers or option forms.
    if command in WRAPPERS and any(name(token) in SHELLS for token in args):
        return "ask"
    if command == "sudo" and sudo_uses_shell(args):
        return "ask"
    # command/builtin can dispatch evaluators without a shell binary.
    if command in {"command", "builtin"}:
        payload = command_builtin_payload(command, args)
        if payload is not None and name(payload) in EVALUATORS:
            return "ask"
    if any(token in REDIRECTS for token in effective):
        return "ask" if any(name(token) in TERMINATORS for token in effective) else "allow"

    if command == "kill":
        return "allow" if safe_kill(args) else "ask"
    if command in TERMINATORS:
        return "ask"
    if any(TERMINATOR_TEXT.search(ascii_lower(token)) for token in args):
        return "ask"
    # `find -exec*` can launch a shell or a terminating utility after arbitrary
    # substitutions. Its target is never a direct probe segment.
    if command == "find" and any(predicate in args for predicate in {"-exec", "-execdir", "-ok", "-okdir"}):
        return "ask"
    if command in CONTROL and any(name(token) in TERMINATORS for token in args):
        return "ask"
    # A wrapper makes a direct kill segment indirect, so it needs approval even
    # if its arguments otherwise resemble a probe.
    if command in WRAPPERS and any(name(token) in TERMINATORS for token in args):
        return "ask"
    return "allow"


def inspect_tokens(tokens):
    segment = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in {"(", "{"}:
            close = ")" if token == "(" else "}"
            depth, end = 1, index + 1
            while end < len(tokens) and depth:
                depth += (tokens[end] == token) - (tokens[end] == close)
                end += 1
            if depth or inspect_tokens(tokens[index + 1:end - 1]) == "ask":
                return "ask"
            index = end
            continue
        if token in {")", "}"}:
            return "ask"
        if token in OPERATORS:
            if inspect_segment(segment) == "ask":
                return "ask"
            segment = []
        else:
            segment.append(token)
        index += 1
    return inspect_segment(segment)


def inspect_command(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    # Preserve assignment operators within adjacent words. Whitespace still
    # separates `printf + =value`, so it cannot be mistaken for `NAME+=value`.
    lexer.wordchars += "+="
    # Bash starts a comment only when `#` begins a word. Python shlex treats an
    # in-word hash as a comment too, which could hide a later command segment.
    lexer.commenters = ""
    return inspect_tokens(list(lexer))


try:
    print(inspect_command(sys.argv[1]))
except (OSError, ValueError):
    print("ask")
PY
)"; then
    decision="ask"
fi

if [ "$decision" != "allow" ]; then
    if [ -n "$matched_command" ]; then
        emit_ask "Command '$matched_command' matches the process-termination rule and requires explicit user approval; only direct kill -l and kill -0 PID probes are exempt."
    else
        emit_ask "The process-termination rule requires explicit user approval for this indirect command; only direct kill -l and kill -0 PID probes are exempt."
    fi
fi
