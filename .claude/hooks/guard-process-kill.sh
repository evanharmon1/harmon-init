#!/usr/bin/env bash
# guard-process-kill.sh — ask before a Bash command can terminate a process.
#
# A process can belong to another interactive session, agent, or user. There is
# no authoritative session-owned PID list in this hook contract, so ownership is
# never inferred. Only exact, non-terminating `kill -l` and `kill -0 <PID>...`
# segments are allowed without an explicit user decision.
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
# produce a command that is absent from the token stream, so it is an approval
# boundary rather than an input to guess about.
if [[ "$command" == *'$'* || "$command" == *'`'* || "$command" == *$'\n'* || "$command" == *$'\r'* ||
    "$command" == *'['* || "$command" == *'?'* || "$command" == *'*'* ||
    "$command" == *'{'* || "$command" == *'}'* ]]; then
    decision="ask"
elif ! decision="$(
    python3 - "$command" <<'PY'
import os
import re
import shlex
import sys

TERMINATORS = {"kill", "pkill", "killall", "xkill"}
TERMINATOR_TEXT = re.compile(r"(?<![A-Za-z0-9_])(?:kill|pkill|killall|xkill)(?![A-Za-z0-9_])")
SHELLS = {"sh", "bash", "dash", "zsh", "fish"}
WRAPPERS = {
    "chrt", "command", "builtin", "doas", "env", "exec", "flock", "ionice",
    "nice", "nohup", "setsid", "stdbuf", "sudo", "taskset", "time", "timeout", "xargs",
}
CONTROL = {"if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac"}
OPERATORS = {";", "&&", "||", "|", "&"}
REDIRECTS = {"<", ">", ">>", "<<", "<<<", "<>", ">&", "<&"}
PID = re.compile(r"[1-9][0-9]*")


def name(token):
    return os.path.basename(token)


def safe_kill(args):
    # Equivalent spellings stay approval-gated rather than expanding a parser
    # that could mistake a terminating invocation for a probe.
    return args == ["-l"] or (
        len(args) >= 2 and args[0] == "-0" and all(PID.fullmatch(pid) for pid in args[1:])
    )


def inspect_segment(segment):
    if not segment:
        return "allow"
    command, args = name(segment[0]), segment[1:]
    # Shells can read executable text from `-c` arguments or redirects, so ask
    # for every shell launcher before redirect handling.
    if command in SHELLS or command == "eval":
        return "ask"
    # Wrappers can launch a shell whose payload contains a terminating command.
    if command in WRAPPERS and any(name(token) in SHELLS or name(token) == "eval" for token in args):
        return "ask"
    if any(token in REDIRECTS for token in segment):
        return "ask" if any(name(token) in TERMINATORS for token in segment) else "allow"

    if command == "kill":
        return "allow" if safe_kill(args) else "ask"
    if command in TERMINATORS:
        return "ask"
    if any(TERMINATOR_TEXT.search(token) for token in args):
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
