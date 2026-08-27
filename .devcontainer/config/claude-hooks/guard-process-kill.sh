#!/usr/bin/env bash
# guard-process-kill.sh — ask before a Bash command can terminate a process.
#
# A process can belong to another interactive session, agent, or user. There is
# no authoritative session-owned PID list in this hook contract, so ownership is
# never inferred. Only exact, non-terminating `kill -l` and `kill -0 <PID>...`
# segments are allowed without an explicit user decision.
set -euo pipefail

emit_ask() {
    jq -n --arg reason "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}'
}

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
if [[ "$command" == *'$'* || "$command" == *'`'* || "$command" == *$'\n'* || "$command" == *$'\r'* ]]; then
    decision="ask"
elif ! decision="$(
    python3 - "$command" <<'PY'
import os
import re
import shlex
import sys

TERMINATORS = {"kill", "pkill", "killall", "xkill"}
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
    if any(token in REDIRECTS for token in segment):
        return "ask" if any(name(token) in TERMINATORS for token in segment) else "allow"

    command, args = name(segment[0]), segment[1:]
    if command == "kill":
        return "allow" if safe_kill(args) else "ask"
    if command in TERMINATORS:
        return "ask"
    if any(name(token) in TERMINATORS for token in args):
        return "ask"
    # `-c`, `-lc`, `-- -c`, and an implementation-specific equivalent all run
    # shell text. Asking for every shell launcher is intentionally broader than
    # necessary, but avoids treating an unrecognized option spelling as safe.
    if command in SHELLS or command == "eval":
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
    return inspect_tokens(list(shlex.shlex(command, posix=True, punctuation_chars=True)))


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
