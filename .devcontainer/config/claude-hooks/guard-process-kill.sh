#!/usr/bin/env bash
# guard-process-kill.sh — ask before a Bash command can terminate a process.
#
# A process can belong to another interactive session, agent, or user. There is
# no authoritative session-owned PID list in this hook contract, so ownership is
# never inferred. Only exact, non-terminating `kill -l` and `kill -0 <PID>...`
# segments are allowed without an explicit user decision. Expansion syntax is an
# approval boundary in two places: alongside a terminator token anywhere in the
# command (the bash check below), and in a command-position word or a known
# executor's (sudo/env/exec/ssh/docker/strace/...) candidate command word (the
# parser below) — either can resolve to a terminator absent from the token
# stream. Expansion syntax in an argument position elsewhere is not gated: it
# cannot supply the command word, so it is not a plausible way to invoke a
# terminator — except a command/process substitution kept inside a quoted
# argument word, which bash still runs regardless of where the word lands;
# the parser inspects every such substitution's body the same way it would a
# bare command. Known residual: an executor that runs a child process but is
# not in the parser's tracked list does not get this command-word check —
# only the literal-terminator-text scan still applies to it. A composite
# operator this parser does not recognize is also an approval boundary,
# rather than being silently misread as a redirect target or command word. A
# backslash-newline line continuation is removed before any of this runs, so
# it cannot split a terminator token in two; a quoted substitution whose body
# contains a quote, an escape, or "${" fails closed rather than trusting a
# character-only paren matcher to see through it; and case/select are not
# parsed at all — the whole construct is approval-gated (#1123 tracks proper
# support).
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

# Bash joins a backslash immediately followed by a newline (a line
# continuation) into one line before tokenizing, so `ki\<newline>ll` is the
# single word `kill` to bash but two separate tokens to the checks below.
# Remove every backslash-LF pair before either the token regex or the parser
# ever sees the command text. Only backslash-LF is a continuation: a
# backslash before CR-LF escapes the CR and the LF still ends the line, so
# stripping that pair would fold two commands into one (Codex #1122 r3) —
# it is left alone and the newline stays a separator. This is applied
# everywhere, including inside single quotes, where bash would NOT actually
# join the line — but that direction only ever creates a token that still
# gets asked about (more text can look like a terminator), never one that
# hides a real terminator, so over-applying it here is safe.
command="${command//$'\\\n'/}"

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
    # Known child-executing commands beyond the core wrapper set. An executor
    # NOT in this list that receives an expansion-built command word is not
    # gated by the expansion checks below — a known, residual limitation.
    "strace", "ltrace", "watch", "runuser", "su", "script", "unbuffer", "chroot",
    "unshare", "nsenter", "systemd-run", "ssh", "docker", "podman", "at", "batch",
    "caffeinate", "gdb", "valgrind", "perf", "hyperfine", "entr", "busybox", "toybox",
}
CONTROL = {"if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac"}
OPERATORS = {";", "&&", "||", "|", "&", "|&"}
REDIRECTS = {"<", ">", ">>", "<<", "<<<", "<>", ">&", "<&", "&>", "&>>", ">|", "<<-"}
PID = re.compile(r"[1-9][0-9]*")
ASSIGNMENT_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\+)?=.*")
# A command-word or wrapper-argument token that still carries any of these
# characters could resolve to something absent from the token stream, so it
# is an approval boundary rather than an input to guess about. Argument-
# position expansion elsewhere is not: it cannot supply the command word.
EXPANSION = re.compile(r"[$`\[\]?*{}()]")
GLUE_CHARS = set("$@+!?*")
# Only a punctuation-run token (every character in this set) that ends in
# "(" is genuine process-substitution/group syntax ("(", "<(", ">("); an
# ordinary word that happens to end in "(" after quote removal is not.
PUNCTUATION_CHARS = set("();<>|&\n")
# Tags a word fused with a "(" that followed it (see the glue step in
# inspect_tokens) so is_paren_open can tell it apart from an ordinary word
# that merely ends in "(". Never appears in real shell text.
GLUE_MARKER = "\x01"
# Every token this parser assigns a specific meaning to among
# punctuation-run tokens: real operators, real redirects, and the group
# delimiters (a bare "(" is also caught here; "<(" / ">(" are punctuation-
# only process-substitution openers, matched later by is_paren_open).
KNOWN_PUNCTUATION_TOKENS = OPERATORS | REDIRECTS | {"(", ")", "{", "}", "<(", ">("}
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


def find_matching_paren(text, open_index):
    # text[open_index] is the "(" itself. Returns the index of its matching
    # ")" within text, tracking nested "("/")" pairs, or -1 if it never closes
    # within this token.
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    return -1


def has_substitution_risk(token):
    # A quoted argument keeps a command/process substitution as one shlex
    # word — argument position does not make it safe the way plain expansion
    # syntax is, because bash still runs the substitution's body regardless
    # of where the resulting word lands. Every such body is approval-gated
    # exactly like a bare command would be. Backtick substitutions fail
    # closed outright rather than trying to find a matching backtick:
    # backticks are rare and their nesting/escaping rules are too messy to
    # reproduce here. The glue-marker synthetic word (e.g. "$(\x01") is
    # exempt: its "(...)" content was already fully inspected by the group
    # recursion in inspect_tokens that produced it, and the marker itself
    # looks like an unbalanced "$(" to naive scanning.
    if not token or GLUE_MARKER in token:
        return False
    if "`" in token:
        return True
    # Arithmetic expansion evaluates variable VALUES recursively, so
    # "$((x))" can run a substitution stored in x. Fail closed on any
    # arithmetic expansion rather than modelling that.
    if "$((" in token:
        return True
    has_opener = "$(" in token or "<(" in token or ">(" in token
    # ${...} parameter expansion, a quote, or an escape can each contain a
    # ")" the character-only matcher below cannot tell apart from the
    # substitution's own closing paren (e.g. "${x:-)}", a quoted ")", or an
    # escaped "\)"), letting the matcher stop early and miss a terminator
    # past the false close. Fail closed on the whole token rather than
    # reproducing that grammar; a token with none of these still gets the
    # precise recursive check below.
    if has_opener and ("${" in token or "'" in token or '"' in token or "\\" in token):
        return True
    index = 0
    while index < len(token):
        if token[index:index + 2] in ("$(", "<(", ">("):
            open_paren = index + 1
            close_paren = find_matching_paren(token, open_paren)
            if close_paren == -1:
                return True
            body = token[open_paren + 1:close_paren]
            if inspect_command(body) == "ask":
                return True
            index = close_paren + 1
            continue
        index += 1
    return False


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


def strip_redirects(tokens):
    # Drop each redirect operator, its target token, and an all-digit token
    # immediately preceding it (the fd number of `2>`), leaving only what the
    # segment would execute once every redirection is set up.
    drop = [False] * len(tokens)
    for index, token in enumerate(tokens):
        if token in REDIRECTS:
            drop[index] = True
            if index + 1 < len(tokens):
                drop[index + 1] = True
            if index - 1 >= 0 and tokens[index - 1].isdigit():
                drop[index - 1] = True
    return [token for index, token in enumerate(tokens) if not drop[index]]


def inspect_segment(segment):
    if not segment:
        return "allow"
    # Check every word of the segment — command word and arguments alike —
    # for a command/process substitution before anything else, including the
    # assignment-prefix stripping below: `x="$(/bin/ki[l]l -9 42)"` is a pure
    # assignment with no command word of its own, so it would otherwise never
    # reach a check that could see the substitution it still runs.
    if any(has_substitution_risk(token) for token in segment):
        return "ask"
    effective = effective_command(segment)
    if not effective:
        return "allow"
    command, args = name(effective[0]), effective[1:]
    # case/select arms are command boundaries this parser does not track: an
    # arm pattern like "(x)" is consumed as an ordinary group (its content
    # discarded once inspected), so the arm's actual command can end up
    # folded into case's own arguments instead of being seen as a command
    # word at all (e.g. a final arm with no ";;" before "esac"). Fail closed
    # on the whole construct rather than parsing case/esac properly; proper
    # support is tracked in #1123.
    if command in {"case", "select"}:
        return "ask"
    # Command-resolution builtins bind a name to a pathname or body that a
    # later segment invokes (`hash -p /bin/ki[l]l foo; foo -9 42`,
    # `alias foo=...`). The mapping is not carried between segments, so the
    # builtins that create one are approval-gated outright.
    if command in {"hash", "alias", "enable", "function"}:
        return "ask"
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
    # A tracked executor is fail-closed on expansion anywhere in its
    # arguments, not just a bare candidate command word: an option payload
    # (ssh -oProxyCommand=..., su --command=...) or an assignment value
    # (docker run -e FOO=$X) can itself be an executable payload, so there is
    # no flag or assignment shape that is safe to exempt here. Only an
    # executor outside WRAPPERS entirely (the header's documented residual)
    # escapes this check.
    if command in WRAPPERS and any(has_expansion(token) for token in args):
        return "ask"
    if command == "sudo" and sudo_uses_shell(args):
        return "ask"
    # command/builtin can dispatch evaluators without a shell binary.
    if command in {"command", "builtin"}:
        payload = command_builtin_payload(command, args)
        if payload is not None and name(payload) in EVALUATORS:
            return "ask"
    if any(token in REDIRECTS for token in effective):
        # A literal terminator anywhere in a redirect-bearing segment is
        # approval-gated outright, regardless of where the real command word
        # ends up.
        if any(name(token) in TERMINATORS for token in effective):
            return "ask"
        # A leading (or embedded) redirect makes its own operator/target the
        # segment's first token, hiding the real command word from every
        # check above. Strip every redirect operator, its target, and an fd
        # number immediately preceding it (`2>`), then re-run the checks
        # above on what is left.
        stripped = strip_redirects(effective)
        if stripped != effective:
            return inspect_segment(stripped)
        return "allow"

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


def is_paren_open(token):
    # A "("-family opener is either the synthetic glue marker below (an
    # expansion-char word fused with the "(" that followed it, e.g. "$(" or
    # "@(") or a token built entirely from punctuation_chars that itself ends
    # in "(" ("(", "<(", ">(" — shlex already glued these together because
    # every character in them is a punctuation char). An ordinary *word* that
    # merely happens to end in "(" after quote removal (`printf "foo("`) is
    # neither: it is quoted literal text, not expansion or process
    # substitution syntax, so it must never open a group.
    if not token:
        return False
    if GLUE_MARKER in token:
        return True
    return token.endswith("(") and all(ch in PUNCTUATION_CHARS for ch in token)


def is_group_open(token):
    return token == "{" or is_paren_open(token)


def inspect_tokens(tokens):
    segment = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        # A bare "(" immediately after a word ending in one of these characters
        # is command/process substitution splitting the word from its "(" only
        # because "(" is a shlex punctuation char, not because the two are
        # unrelated. Glue it back onto the word (tagged with GLUE_MARKER, so
        # is_paren_open recognizes it as an opener without mistaking an
        # ordinary quoted word for one) so the word carries visible expansion
        # syntax wherever it is later inspected (command position or a
        # wrapper argument), instead of vanishing when the group below is
        # consumed.
        if token == "(" and segment and segment[-1] and segment[-1][-1] in GLUE_CHARS:
            segment[-1] += "(" + GLUE_MARKER
            token = segment[-1]
        if is_group_open(token):
            close = "}" if token == "{" else ")"
            depth, end = 1, index + 1
            while end < len(tokens) and depth:
                nested = tokens[end]
                opens = (nested == "{") if close == "}" else is_paren_open(nested)
                depth += opens - (nested == close)
                end += 1
            if depth or inspect_tokens(tokens[index + 1:end - 1]) == "ask":
                return "ask"
            index = end
            continue
        if token in {")", "}"}:
            return "ask"
        # A token built entirely from punctuation_chars that is not a
        # recognized operator, redirect, or group opener is a composite this
        # parser does not know the meaning of (an unlisted Bash operator like
        # `;&`, or any other stray punctuation run) — an approval boundary
        # rather than a guess about what it does.
        if token and all(ch in PUNCTUATION_CHARS for ch in token) and token not in KNOWN_PUNCTUATION_TOKENS:
            return "ask"
        if token in OPERATORS:
            if inspect_segment(segment) == "ask":
                return "ask"
            segment = []
        else:
            segment.append(token)
        index += 1
    return inspect_segment(segment)


def split_newline_tokens(tokens):
    # A newline is bash's statement separator, but it is routed through
    # punctuation_chars below (not whitespace) so it never vanishes as
    # insignificant whitespace — otherwise a second line's command word lands
    # as an argument to the first line's command. It therefore surfaces inside
    # punctuation-run tokens ("\n", ";\n", "&&\n", "(\n"); split each such
    # token on its embedded newlines and splice in a ";" for each one, so a
    # new line always starts a new segment exactly like a real ";" would.
    result = []
    for token in tokens:
        if token and "\n" in token and all(ch in PUNCTUATION_CHARS for ch in token):
            pieces = token.split("\n")
            for index, piece in enumerate(pieces):
                if piece:
                    result.append(piece)
                if index != len(pieces) - 1:
                    result.append(";")
        else:
            result.append(token)
    return result


def inspect_command(command):
    # Newline is an explicit punctuation char (not True's implicit
    # '();<>|&') specifically so it can be routed away from whitespace next.
    lexer = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n")
    # A newline must separate segments like a shell's own statement
    # terminator, not be consumed as whitespace and disappear.
    lexer.whitespace = " \t\r"
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
    return inspect_tokens(split_newline_tokens(list(lexer)))


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
