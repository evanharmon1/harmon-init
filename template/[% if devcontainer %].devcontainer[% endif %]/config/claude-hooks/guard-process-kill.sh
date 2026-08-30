#!/usr/bin/env bash
# guard-process-kill.sh — ask before a Bash command can terminate a process.
#
# A process can belong to another interactive session, agent, or user. There is
# no authoritative session-owned PID list in this hook contract, so ownership is
# never inferred. Only exact, non-terminating `kill -l` and `kill -0 <PID>...`
# segments are allowed without an explicit user decision. Expansion syntax is an
# approval boundary in two places: alongside a terminator token anywhere in the
# command (the bash check below), and in a command-position word or a
# wrapper's (sudo/env/exec/...) candidate command word (the parser below) —
# either can resolve to a terminator absent from the token stream. Expansion
# syntax in an argument position elsewhere is not gated: it cannot supply the
# command word, so it is not a plausible way to invoke a terminator.
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

# A shell grammar is deliberately not reimplemented here. Once a terminator
# token is already present, expansion syntax anywhere in the command is an
# approval boundary rather than an input to guess about — it could be hiding
# the terminator's *form* (e.g. an obfuscated flag or PID). A command that
# names no terminator token at all falls through to the parser below, which
# still gates expansion in a command-position word or a wrapper's candidate
# command word (an expansion there could hide the terminator's *identity*,
# not just its form); expansion confined to an argument position is not
# gated, since it cannot supply the command word.
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
# A command-word or wrapper-argument token that still carries any of these
# characters could resolve to something absent from the token stream, so it
# is an approval boundary rather than an input to guess about. Argument-
# position expansion elsewhere is not: it cannot supply the command word.
EXPANSION = re.compile(r"[$`\[\]?*{}()]")
GLUE_CHARS = set("$@+!?*")
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


def has_expansion(token):
    # A lone "[" or "]" is the complete, literal `test` command word (or its
    # closing argument) — not a partial glob/character-class that could still
    # resolve to something else. Only a bracket combined with other characters
    # in the same token is a plausible obfuscation.
    if token in ("[", "]"):
        return False
    return bool(EXPANSION.search(token))


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
    # A command word built from expansion syntax can resolve to a name absent
    # from the token stream, so it is approval-gated the same way a terminator
    # token is, regardless of what it is.
    if has_expansion(effective[0]):
        return "ask"
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
    # A wrapper's candidate command word can be masked by expansion syntax the
    # same way a bare command word can; assignment prefixes and flags are not
    # candidate command words.
    if command in WRAPPERS and any(
        has_expansion(token)
        for token in args
        if not token.startswith("-") and not ASSIGNMENT_WORD.fullmatch(token)
    ):
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


def is_group_open(token):
    # A standalone "(" is a bare subshell/group open. A token merely ending in
    # "(" is a punctuation run shlex already glued together (process
    # substitution's "<(", or a synthetic marker glued below) and opens the
    # same way.
    return token == "{" or token.endswith("(")


def inspect_tokens(tokens):
    segment = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        # A bare "(" immediately after a word ending in one of these characters
        # is command/process substitution splitting the word from its "(" only
        # because "(" is a shlex punctuation char, not because the two are
        # unrelated. Glue it back onto the word so the word carries visible
        # expansion syntax wherever it is later inspected (command position or
        # a wrapper argument), instead of vanishing when the group below is
        # consumed.
        if token == "(" and segment and segment[-1] and segment[-1][-1] in GLUE_CHARS:
            segment[-1] += "("
            token = segment[-1]
        if is_group_open(token):
            close = "}" if token == "{" else ")"
            depth, end = 1, index + 1
            while end < len(tokens) and depth:
                nested = tokens[end]
                opens = (nested == "{") if close == "}" else nested.endswith("(")
                depth += opens - (nested == close)
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
    # Split on whitespace only, so an expansion-prefixed word ($killer,
    # /bin/ki[l]l, k{i..i}ll) stays one token instead of shlex's default
    # wordchars splitting it apart mid-word.
    lexer.whitespace_split = True
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
