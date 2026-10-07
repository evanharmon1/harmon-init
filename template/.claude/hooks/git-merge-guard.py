#!/usr/bin/env python3
"""PreToolUse(Bash) hook: ask before any git merge/pull that is not a
recognized merge into a feature branch.

Replaces the `Bash(git merge)` / `Bash(git merge:*)` permissions.ask rules,
which prompt on every merge (including routine catch-up merges of main into
a lane branch) yet miss `git -C <dir> merge` entirely, because permission
rules match literal command prefixes.

Profile scope: the guard protects interactive, human-supervised sessions --
the host and the dev devcontainer. With `FOREMAN_DEVCONTAINER` set to `bot`
or `agent` it returns no decision for any command, real merges included:
unattended lanes catch up to main with `git merge` routinely, a prompt there
is effectively a denial, and the GitHub "Protect Main" ruleset is the
boundary (no direct or force push to main; a merge into it needs code-owner
approval and green required checks). The variable is read from the hook's own
environment, which a Bash command cannot change.

Invariant: the hook returns "ask" for every command that invokes, or could
invoke, a git merge or pull, unless the whole command is exactly one
allowlisted shape run in a verified feature-branch checkout. The command is
parsed the way bash reads it -- words, quotes, operators, comments, heredocs,
command substitutions -- and a merge is:

  * a `git` command (any path, any case, `git.exe`) whose subcommand slot,
    after git's global options (`-C <dir>`, `-c <kv>`, ...), is `merge` or
    `pull`, wherever it appears in a command's words (`command git merge`,
    `timeout 9 git pull`, `xargs git merge`, `ssh host git pull`);
  * a git call whose subcommand slot is not a literal (`git $x`, `git m*rge`,
    `git $'\\x6d...'`), could be filled in by `xargs`/`parallel` (a missing
    slot, a replacement string such as `xargs -I X git X`, `:::` arguments),
    or is a one-off alias whose expansion could merge (`git -c alias.m=merge m`,
    a `!` shell alias, or one whose `-c` value or source is not literal);
  * a command whose name is not a literal followed by `merge`/`pull`
    (`$G merge feat`);
  * the dashed `git-merge`/`git-pull` executables run as a command;
  * any of the above inside text that runs: `$(...)` (and `$((...))`, which
    bash also reads as one), backticks, `<(...)`, substitutions inside
    `${...}` or an unquoted heredoc, the string after a `-c` or `-Command`
    option of any program but a search tool, whose `-c` counts (`bash -c`,
    `csh -c`, `su -c`, `pwsh -Command`;
    `$'...'` strings decoded first), the arguments of `eval`, `ssh`,
    `watch` or `env -S`, or a heredoc or here-string fed to a shell
    (whatever its arguments); `${...}` operators are not modelled, so a
    `${...}` that mentions merge/pull asks; a `trap` action counts too;
  * any mention of merge/pull anywhere in a command line that also runs an
    evaluator (a shell, `eval`, `ssh`, `trap`, `watch`, `env -S`): their option and
    input shapes (`bash -C -c`, `env -S'...'`, a pipe into `if ...; then sh`)
    are open-ended, so the word test covers what the parser does not.

Everything else is data and stays silent: quoted text and heredoc bodies not
handed to an evaluator (`git commit -m "catch-up merge"`, report appends),
search patterns (`grep -n 'merge base'`), and other subcommands and flags that
merely hold the word (`git merge-base`, `merge-tree`, `mergetool`,
`--merge-base-policy`). A command the parser cannot read (an unbalanced quote)
asks if it mentions git, merge or pull at all -- bash may still run the lines
before the error -- so a parser gap costs a prompt, not a silent merge.

The only silent (normal permission flow) shape is one fully literal command
-- no quotes, escapes, expansions, globs, operators, newlines, `cd` or `-C`:

    git merge [--no-edit|--no-ff|--ff|--ff-only] <ref>
    git merge (--continue|--quit)
    git pull (--ff-only|--no-rebase) [--no-edit] [<remote> [<ref>]]

run in the working directory Claude Code reports in the hook payload (a lane
merges from its own worktree), where that checkout is on a named branch that
is not main/master and
differs from every remote's resolved default branch -- at least one remote
default must resolve (`git remote set-head <remote> --auto`), or it asks. With
several remotes, a branch that is the default of one remote whose HEAD is unset
stays silent unless another remote's HEAD names it.

(The decision to remove guard-process-kill,
https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-02-remove-guard-process-kill-hook.md,
explains why an open-ended "is this safe?" classifier was rejected.)

Known limits, shared with or no worse than the rules it replaces: it does
not see through git aliases, scripts (`./merge-main.sh` and `sh ./merge-main.sh`
alike), interpreters running git through their own APIs (`python3 -c` with
`subprocess`), or shell functions and aliases from the user's profile (an
alias that checks out main and pulls, one that runs `gh pr merge --auto`, one
that pushes the current branch) -- nor through deliberate obfuscation that
hides the `git` word itself (a variable as the whole command, brace expansion
such as `{git,merge} feat`, or a glob such as `gi[t]`); it is a backstop
against mistakes, not an adversarial boundary. A `case` pattern inside `$(...)`
can end the substitution early. An unquoted `git merge` in another command's
arguments (`echo git pull`) asks.
It gates only git merge/pull: `git reset --hard`, `git restore` and
`git checkout -- .` discard the same conflict resolutions `git merge --abort`
would, and this hook does not see them. Nor does it see the commands that
advance main without a merge or pull: `git fetch . feat:main`,
`git push . HEAD:main`, `git branch -f main feat` and
`git update-ref refs/heads/main`. Direct `git merge-recursive` and `git merge-file`
are silent too: they write the index or a file but create no commit and move
no ref, so nothing lands on main. `git pull --rebase` is not silent,
because it can rewrite already-pushed feature-branch commits; neither is a
`git pull` that names no mode, because `pull.rebase` can make it a rebase. It
trusts the local `refs/remotes/<remote>/HEAD` cache -- after a remote renames
its default branch, run `git remote set-head <remote> --auto` (main/master
stay protected regardless). A
hook "allow" cannot override a permissions.ask rule, so this hook only ever
adds prompts.

It runs only where Claude Code runs hooks. `claude --bare` and the
`disableAllHooks` setting skip it, and with the `git merge` ask rules removed
nothing prompts there; the devcontainer's settings allow every `git` command.
Nothing in this repository runs Claude that way. The enforcement that does
not depend on the client is the GitHub "Protect Main" ruleset, which refuses
the push (maintainer decision, challenge round 3).

It checks the branch before the command starts, not while it runs: another
pane that switches the same checkout in between is not seen. Lanes merge in
their own worktrees, which no other session checks out.

Tests: scripts/test-git-merge-guard.sh (run by `task test:hooks`).
Design and rationale: evanharmon1/harmon-init#1435, evanharmon1/harmon-dotfiles#123.
"""

import json
import os
import re
import subprocess
import sys

PROFILE_VAR = "FOREMAN_DEVCONTAINER"
UNGUARDED_PROFILES = {"bot", "agent"}
PROTECTED = {"main", "master"}
MERGE_WORDS = {"merge", "pull"}
# The dashed executables under `git --exec-path`, callable by full path.
DASHED = {"git-merge", "git-pull"}
MERGE_FLAGS = {"--no-edit", "--no-ff", "--ff", "--ff-only"}
PULL_FLAGS = {"--ff-only", "--no-edit", "--no-rebase"}
# A silent pull must name its mode: with `pull.rebase` or `branch.<name>.rebase`
# set, a bare `git pull` rebases and rewrites the branch.
# `git -c pull.rebase=true pull --ff-only` on a diverged feature branch aborts
# ("Not possible to fast-forward") and leaves the branch unchanged (verified
# 2026-09-30, git 2.55.0), so `--ff-only` is safe even with `pull.rebase` set.
PULL_NO_REWRITE = {"--ff-only", "--no-rebase"}
# `--abort` is deliberately absent: it resets the index and worktree and can
# discard in-progress conflict resolutions (same class as `git reset --hard`).
# `--quit` leaves the index and worktree alone (unlike `--abort`) and saves
# the autostash, which is why worktree-rm.sh asks for it after an interrupted
# merge.
SOLO_FLAGS = {"--continue", "--quit"}
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
LITERAL_UNSAFE = re.compile(r"[\"'`$\\\n;&|<>(){}*?\[\]~]")
# A mention of merge/pull as a word; used only where the parser cannot say
# what runs (an unreadable command, a shell reading a pipe). `merge-base` and
# `merge-tree` are read-only plumbing; prose like `pull-requests` is not a word.
MENTION = re.compile(
    r"(?<![\w-])merge(?!-(?:base|tree)(?![\w-]))(?!\w)"
    r"|(?<![\w-])pull(?![\w-])"
    r"|(?<![\w-])git-(?:merge|pull)(?!-guard\b)(?!\w)",
    re.I,
)
GIT_MENTION = re.compile(r"(?<![\w-])git(?![\w-])", re.I)
GIT_VALUE_OPTIONS = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--attr-source",
    "--shallow-file",
    "--config-env",
    "--super-prefix",
}
# Shells: they read a script from stdin, and their presence puts a command
# line under the word test. `busybox` is not one: it is a wrapper that runs
# the applet named next, and `busybox sh` is caught by `sh`. `.` and `source`
# run a file in the current shell (`. /dev/stdin <<< ...`), so they count.
SHELLS = {
    ".", "ash", "bash", "csh", "dash", "elvish", "fish", "ksh", "mksh",
    "nu", "oksh", "osh", "powershell", "pwsh", "script", "sh", "su", "tcsh",
    "source", "xonsh", "yash", "zsh",
}
# An option whose next word is read as a script, for any program. Case
# matters: `-C` is noclobber in bash and zsh, not a script.
SCRIPT_OPTION = re.compile(r"^(?:-[A-Za-z]*c[A-Za-z]*|(?i:-command|--command))$")
# Programs whose remaining arguments, joined, are run as a command line.
# `trap ACTION SIGNAL...` runs ACTION later; the signal names parse as harmless words.
JOINERS = {"eval", "ssh", "trap", "watch"}
# Programs that take a command in their arguments; what follows them is at
# command position for the dashed-executable and stdin-shell checks.
WRAPPERS = {
    "builtin", "busybox", "caffeinate", "chronic", "command", "doas", "env", "exec",
    "ionice", "nice", "nocorrect", "noglob", "nohup", "parallel", "setsid",
    "stdbuf", "sudo", "time", "timeout", "unbuffer", "xargs",
    "-exec", "-execdir", "-ok", "-okdir",
}
# Wrapper options that take a separate value, so the value is not the command.
WRAPPER_VALUE_OPTIONS = {
    "caffeinate": {"-t", "-w"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "exec": {"-a"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"},
    "nice": {"-n", "--adjustment"},
    "parallel": {"-j", "-S", "-I", "-a", "-C", "--jobs", "--sshlogin", "--replace",
                 "--joblog", "--results", "--delay", "--timeout", "--arg-file", "--colsep"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R",
             "--user", "--group", "--host", "--prompt", "--chdir", "--role",
             "--type", "--other-user", "--close-from", "--command-timeout", "--chroot"},
    "time": {"-f", "-o", "--format", "--output"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S",
              "--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-lines",
              "--max-chars", "--replace", "--eof", "--process-slot-var"},
}
SOURCE_BUILTINS = {".", "source"}
# Search tools whose `-c` means count: the pattern after it is data.
SEARCH_TOOLS = {"ack", "ag", "egrep", "fgrep", "grep", "rg", "zgrep"}
# Programs that feed stdin words to the command after them.
ARG_FEEDERS = {"parallel", "xargs"}
KEYWORDS = {"!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
WRAPPER_ARG = re.compile(r"^(?:-.*|\d+(?:\.\d+)?[smhd]?|[A-Za-z_][A-Za-z0-9_]*=.*)$")
MAX_DEPTH = 8
METACHARS = set(" \t\n;&|()<>")


class ParseError(Exception):
    pass


class Word:
    """One shell word: its text with quotes removed (expansions kept as
    written, so the text can be re-parsed when a shell runs it), and whether
    it is literal (no expansion, substitution or glob)."""

    def __init__(self):
        self.value = ""
        self.literal = True


class Command:
    """One simple command: its words, and the text fed to its stdin by
    heredocs and here-strings."""

    def __init__(self):
        self.words = []
        self.stdin = []


class Parser:
    """A reader for the subset of bash that decides what runs. Commands found
    inside substitutions are collected too: they run as well."""

    def __init__(self, text, commands=None, uncertain=None):
        self.s = text
        self.i = 0
        self.commands = [] if commands is None else commands
        self.cur = None
        self.heredocs = []
        # Expansion text the parser does not model; asks if it mentions merge/pull.
        self.uncertain = uncertain if uncertain is not None else []

    def command(self):
        if self.cur is None:
            self.cur = Command()
        return self.cur

    def end_command(self):
        if self.cur is not None and (self.cur.words or self.cur.stdin):
            self.commands.append(self.cur)
        self.cur = None

    def run(self, stop_at_paren=False):
        s = self.s
        depth = 0
        while self.i < len(s):
            c = s[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\n":
                self.end_command()
                self.i += 1
                self.read_heredocs()
            elif c == "#":
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif s.startswith("\\\n", self.i):
                self.i += 2
            elif s.startswith(("&>>", "&>"), self.i):
                self.i += 3 if s.startswith("&>>", self.i) else 2
                self.redirect_target()
            elif s.startswith(("&&", "||", ";;", "|&"), self.i) or c in ";&|":
                op = s[self.i : self.i + 2] if s[self.i : self.i + 2] in ("&&", "||", ";;", "|&") else c
                self.end_command()
                self.i += len(op)
            elif c == "(":
                self.end_command()
                depth += 1
                self.i += 1
            elif c == ")":
                self.end_command()
                self.i += 1
                if depth == 0:
                    if stop_at_paren:
                        return self.i
                    raise ParseError("unbalanced )")
                depth -= 1
            elif c in "<>":
                self.redirection()
            else:
                start = self.i
                word = self.read_word()
                # `2>&1`: a file-descriptor number belongs to the redirection.
                if word.value.isdigit() and self.i < len(s) and s[self.i] in "<>" and self.i > start:
                    continue
                cmd = self.command()
                if not cmd.words and word.literal and word.value in KEYWORDS:
                    continue
                cmd.words.append(word)
        if stop_at_paren:
            raise ParseError("unterminated $(")
        self.end_command()
        self.read_heredocs()
        return self.i

    def redirection(self):
        s = self.s
        if s.startswith("<<<", self.i):
            self.i += 3
            self.command().stdin.append(self.redirect_target().value)
        elif s.startswith("<<", self.i):
            strip = s.startswith("<<-", self.i)
            self.i += 3 if strip else 2
            start = self.skip_blanks()
            word = self.read_word()
            quoted = any(ch in s[start : self.i] for ch in "'\"\\")
            self.heredocs.append((self.command(), word.value, quoted, strip))
        elif s.startswith(("<(", ">("), self.i):
            self.i = Parser(s, self.commands, self.uncertain).nested(self.i + 2)
        else:
            self.i += 1
            while self.i < len(s) and s[self.i] in "<>&|":
                self.i += 1
            self.redirect_target()

    def skip_blanks(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1
        return self.i

    def redirect_target(self):
        self.skip_blanks()
        return self.read_word()

    def nested(self, i):
        """Parse a substitution body starting at i; return the index past `)`."""
        self.i = i
        return self.run(stop_at_paren=True)

    def read_heredocs(self):
        s = self.s
        for cmd, delim, quoted, strip in self.heredocs:
            lines = []
            while self.i < len(s):
                end = s.find("\n", self.i)
                end = len(s) if end < 0 else end
                line = s[self.i : end]
                self.i = end + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            body = "\n".join(lines)
            if not quoted:
                # An unquoted heredoc expands `$(...)` and backticks: they run.
                Parser(body, self.commands, self.uncertain).read_double_quoted(Word(), closing=None)
            cmd.stdin.append(body)
        self.heredocs = []

    def read_word(self):
        s = self.s
        word = Word()
        while self.i < len(s) and s[self.i] not in METACHARS:
            c = s[self.i]
            if c == "\\":
                if s.startswith("\\\n", self.i):
                    self.i += 2
                    continue
                word.value += s[self.i + 1 : self.i + 2]
                self.i += 2
            elif c == "'":
                end = s.find("'", self.i + 1)
                if end < 0:
                    raise ParseError("unterminated '")
                word.value += s[self.i + 1 : end]
                self.i = end + 1
            elif s.startswith("$'", self.i):
                j = self.i + 2
                while j < len(s) and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                if j >= len(s):
                    raise ParseError("unterminated $'")
                word.value += ansi_c(s[self.i + 2 : j])
                word.literal = False
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.read_double_quoted(word, closing='"')
            elif c in "$`":
                self.read_expansion(word)
            else:
                if c in "*?[{}" and not (c in "{}" and word.value == "" and self.at_word_end(self.i + 1)):
                    word.literal = False
                word.value += c
                self.i += 1
        return word

    def at_word_end(self, i):
        return i >= len(self.s) or self.s[i] in METACHARS

    def read_double_quoted(self, word, closing):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if closing and c == closing:
                self.i += 1
                return
            if c == "\\" and self.i + 1 < len(s):
                nxt = s[self.i + 1]
                if nxt == "\n":
                    self.i += 2
                    continue
                word.value += nxt if nxt in '$`"\\' else c + nxt
                self.i += 2
            elif c in "$`":
                self.read_expansion(word)
            else:
                word.value += c
                self.i += 1
        if closing:
            raise ParseError('unterminated "')

    def read_expansion(self, word):
        """Read a `$...` or backtick expansion at self.i into word."""
        s = self.s
        start = self.i
        if s[self.i] == "`":
            j = self.i + 1
            while j < len(s) and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            if j >= len(s):
                raise ParseError("unterminated `")
            body = re.sub(r"\\([`$\\])", r"\1", s[self.i + 1 : j])
            Parser(body, self.commands, self.uncertain).run()
            self.i = j + 1
        elif s.startswith("$(", self.i):
            # `$((...))` arithmetic is read as a substitution too: bash runs
            # `$((git merge feat) )` as one, and arithmetic text is harmless.
            self.i = Parser(s, self.commands, self.uncertain).nested(self.i + 2)
        elif s.startswith("${", self.i):
            self.i += 2
            self.read_double_quoted(Word(), closing="}")
            # Operators like `${x/merge/y}` are not modelled: the word test
            # covers anything they could spell.
            self.uncertain.append(s[start : self.i])
        elif self.i + 1 < len(s) and (s[self.i + 1].isalnum() or s[self.i + 1] in "_@*#?$!-"):
            self.i += 2
            while self.i < len(s) and (s[self.i].isalnum() or s[self.i] == "_"):
                self.i += 1
        else:
            word.value += "$"
            self.i += 1
            return
        word.value += s[start : self.i]
        word.literal = False


def ansi_c(body):
    """Decode a `$'...'` body the way bash does, near enough to read a word."""
    try:
        return body.encode("latin-1", "backslashreplace").decode("unicode_escape")
    except UnicodeDecodeError:
        return body


def parse(text):
    parser = Parser(text)
    parser.run()
    return parser.commands, parser.uncertain


def base(word):
    """A word's program name: basename, lowercased, without `.exe`."""
    return re.sub(r"\.exe$", "", os.path.basename(word.value.strip("\n")).lower())


def command_index(words):
    """Index of the word bash runs as the command, skipping assignments and
    wrappers with their options (`sudo -u evan`, `env -C dir`, `timeout 9`)."""
    i = 0
    while i < len(words):
        w = words[i]
        if w.literal and ASSIGNMENT.match(w.value):
            i += 1
        elif w.literal and base(w) in WRAPPERS:
            takes_value = WRAPPER_VALUE_OPTIONS.get(base(w), set())
            i += 1
            while i < len(words) and WRAPPER_ARG.match(words[i].value):
                i += 2 if words[i].value in takes_value else 1
        else:
            return i
    return i


def feeder_tokens(words, i):
    """Replacement strings that `xargs`/`parallel` before words[i] fill in
    at run time, or None when no feeder precedes it."""
    tokens = None
    for k, w in enumerate(words[:i]):
        name = base(w) if w.literal else ""
        if name not in ARG_FEEDERS:
            continue
        tokens = tokens or set()
        if name == "parallel":
            tokens.add("{")
        for j in range(k + 1, i):
            opt = words[j].value
            if opt in ("-I", "-J", "--replace") and j + 1 < i:
                tokens.add(words[j + 1].value)
            elif opt.startswith(("-I", "-J")):
                tokens.add(opt[2:])
            elif opt.startswith("--replace="):
                tokens.add(opt.split("=", 1)[1])
            elif opt.startswith("-i"):
                # GNU xargs `-i[R]`: replace R, `{}` by default.
                tokens.add(opt[2:] or "{}")
    return tokens


def git_might_merge(words, i, depth=0):
    """True when the git call at words[i] could be a merge or pull."""
    if depth > MAX_DEPTH:
        return True
    j = i + 1
    aliases = {}  # one-off alias name -> expansion (None: set from the environment)
    while j < len(words) and words[j].value.startswith("-"):
        opt = words[j].value
        if words[j].literal and opt in ("-h", "--help", "-v", "--version"):
            # `git --help merge` shows help; `git --version pull` prints the version.
            return False
        name, eq, val = opt.partition("=")
        if opt.startswith("-c") and len(opt) > 2:
            # The attached form `-calias.m=merge` is git's own spelling too.
            name, eq, val = "-c", "=", opt[2:]
        if name in ("-c", "--config-env"):
            word = words[j] if eq else (words[j + 1] if j + 1 < len(words) else Word())
            val = val if eq else word.value
            if not word.literal:
                # `git -c "$X" m`: the setting could define any alias.
                return True
            # Git folds the section and the alias name case.
            alias = re.match(r"\s*alias\.([^=]+)=?(.*)", val, re.I | re.S)
            if alias:
                aliases[alias.group(1).lower()] = alias.group(2) if name == "-c" else None
        j += 2 if opt in GIT_VALUE_OPTIONS else 1
    tokens = feeder_tokens(words, i)
    if tokens is not None:
        # `xargs git`, `xargs -I X git X`, `parallel git ::: merge`: a feeder
        # can fill the subcommand from stdin or its own arguments.
        if j >= len(words) or any(w.value.startswith(":::") for w in words):
            return True
        if any(t and t in words[j].value for t in tokens):
            return True
    if j >= len(words):
        return False
    slot = words[j]
    sub = slot.value.strip("\n").lower()
    if not slot.literal or sub in MERGE_WORDS:
        # Checked before aliases: git ignores an alias that hides a built-in.
        return True
    if sub in aliases:
        # Only the invoked alias matters (`git -c alias.x=log status` runs
        # status). Expand it the way git does, with the caller's arguments
        # appended, and check the result: a `!` alias is a shell script, any
        # other re-enters git, so chained aliases and expansions that are only
        # options (`alias.g='-c x=y'`) are followed too.
        expansion = aliases[sub]
        rest = words[j + 1 :]
        if expansion is None or MENTION.search(expansion):
            return True
        if expansion.lstrip().startswith("!"):
            script = " ".join([expansion.lstrip()[1:]] + [w.value for w in rest])
            return script_might_merge(script, depth + 1)
        try:
            expanded = parse(expansion)[0]
        except (ParseError, IndexError, RecursionError):
            return True
        if len(expanded) != 1:
            return True
        return git_might_merge(words[:j] + expanded[0].words + rest, i, depth + 1)
    return False


def is_evaluator(words, i):
    """True when words[i] runs text it is given as a script."""
    name = base(words[i])
    if name in SOURCE_BUILTINS:
        # As an argument (`rg -c x .`) a dot is a path, not the builtin.
        return i == command_index(words)
    if name in SHELLS or name in JOINERS:
        return True
    return name == "env" and any(
        w.value.startswith(("-S", "--split-string")) for w in words[i + 1 :]
    )


def command_might_merge(cmd, text, depth):
    words = cmd.words
    ci = command_index(words)
    if ci < len(words) and not words[ci].literal:
        if any(w.value.lower() in MERGE_WORDS for w in words[ci + 1 : ci + 2]):
            return True
    for i, w in enumerate(words):
        name = base(w)
        if name == "git" and git_might_merge(words, i):
            return True
        at_command = i == ci or (i > 0 and words[i - 1].literal and base(words[i - 1]) in WRAPPERS)
        if name in DASHED and at_command:
            return True
        # A non-literal word counts when its decoded text names an evaluator
        # (`$'bash'`); an expansion such as `$SHELL` decodes to itself and does not.
        # An evaluator's option and input shapes are open-ended (`bash -C -c`,
        # `env -S'...'`, a pipe into a compound command), so its presence puts
        # the whole script under the word test; the parse below still sees
        # what the word test cannot (`$'\x70ull'`, `git $x`).
        if is_evaluator(words, i) and MENTION.search(text):
            return True
        # A `-c` / `-Command` payload is read as a script whatever program
        # takes it, so an interpreter missing from SHELLS is still seen.
        searching = ci < len(words) and (
            base(words[ci]) in SEARCH_TOOLS
            or (base(words[ci]) == "git" and any(x.value == "grep" for x in words[ci + 1 :]))
        )
        if SCRIPT_OPTION.match(w.value) and i + 1 < len(words) and not searching:
            if script_might_merge(words[i + 1].value, depth + 1):
                return True
        if name in SHELLS and is_evaluator(words, i):
            # Without -c a shell may read its script from stdin (`bash -s x`).
            if any(script_might_merge(p, depth + 1) for p in cmd.stdin):
                return True
        elif name in JOINERS:
            if script_might_merge(" ".join(x.value for x in words[i + 1 :]), depth + 1):
                return True
        elif name == "env":
            for k in range(i + 1, len(words) - 1):
                if words[k].value in ("-S", "--split-string"):
                    if script_might_merge(words[k + 1].value, depth + 1):
                        return True
            for k in range(i + 1, len(words)):
                v = words[k].value
                attached = v.split("=", 1)[1] if v.startswith("--split-string=") else (
                    v[2:] if v.startswith("-S") and len(v) > 2 else None)
                if attached is not None and script_might_merge(attached, depth + 1):
                    return True
    return False


def script_might_merge(text, depth=0):
    if depth > MAX_DEPTH:
        return True
    try:
        commands, uncertain = parse(text)
    except (ParseError, IndexError, RecursionError):
        # Unreadable: bash may still run the lines before the error, so ask on
        # any mention of git, merge or pull.
        return bool(MENTION.search(text) or GIT_MENTION.search(text))
    if any(MENTION.search(t) for t in uncertain):
        return True
    # The word test reads decoded words and stdin too, so `printf $'git \x70ull'
    # | bash` shows `pull` where the raw text does not.
    decoded = "\n".join(
        [w.value for c in commands for w in c.words] + [t for c in commands for t in c.stdin]
    )
    return any(command_might_merge(c, text + "\n" + decoded, depth) for c in commands)


def might_merge(command):
    """True when the command invokes, or could invoke, a git merge/pull."""
    return script_might_merge(command)


def allowlisted_target(command, cwd):
    """Return cwd if the whole command is exactly the silent shape.

    The shape is one fully literal `git merge` / `git pull` with no path
    arguments: no quotes, escapes, expansions, globs, operators or newlines,
    and no `cd` / `-C`. The checkout the guard verifies is therefore the one
    git will use -- the working directory Claude Code reports in the payload.
    """
    if LITERAL_UNSAFE.search(command) or not os.path.isabs(cwd):
        return None
    tokens = command.split()
    if len(tokens) < 2 or tokens[0] != "git" or tokens[1] not in MERGE_WORDS:
        return None
    sub, rest = tokens[1], tokens[2:]
    refs = [a for a in rest if not a.startswith("-")]
    flags = set(a for a in rest if a.startswith("-"))
    if not all(REF.match(r) for r in refs):
        return None
    if sub == "merge":
        ok = (len(rest) == 1 and rest[0] in SOLO_FLAGS) or (
            len(refs) == 1 and flags <= MERGE_FLAGS
        )
    else:
        ok = len(refs) <= 2 and flags <= PULL_FLAGS and bool(flags & PULL_NO_REWRITE)
    return cwd if ok else None


def git(cwd, *args):
    out = subprocess.run(
        ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5
    )
    return out.stdout.strip() if out.returncode == 0 else None


def feature_branch(cwd):
    """Return the branch if cwd is provably on a non-default named branch.

    Compares full ref names, never `--short` output: git abbreviates
    ambiguously named refs (a tag `main` makes `refs/heads/main` print as
    `heads/main`), which would slip past a short-name comparison.
    """
    if not os.path.isdir(cwd):
        return None
    head = git(cwd, "symbolic-ref", "--quiet", "HEAD")
    if not head or not head.startswith("refs/heads/"):
        return None
    branch = head[len("refs/heads/") :]
    # refs are files on a case-insensitive filesystem (macOS APFS), so
    # `Main` is `main`: compare casefolded names.
    if branch.casefold() in PROTECTED:
        return None
    defaults = set()
    for remote in (git(cwd, "remote") or "").split():
        prefix = f"refs/remotes/{remote}/"
        ref = git(cwd, "symbolic-ref", "--quiet", f"{prefix}HEAD")
        if ref and ref.startswith(prefix):
            defaults.add(ref[len(prefix) :])
    if not defaults or branch.casefold() in {d.casefold() for d in defaults}:
        return None
    return branch


def decide(command, cwd):
    """Return None (no opinion) or the reason to ask."""
    if not might_merge(command):
        return None
    target = allowlisted_target(command, cwd)
    if target is None:
        return "git merge/pull in a form this guard does not allowlist"
    if feature_branch(target) is None:
        return (
            "git merge/pull would land on main/master or the remote default "
            "branch, or the target branch could not be verified "
            f"(detached HEAD, no resolvable remote HEAD, unreadable): {target}"
        )
    return None


def main():
    if os.environ.get(PROFILE_VAR, "").strip().lower() in UNGUARDED_PROFILES:
        return
    try:
        payload = json.load(sys.stdin)
        command = (payload.get("tool_input") or {}).get("command", "")
        if payload.get("tool_name") != "Bash" or not command:
            return
        reason = decide(command, payload.get("cwd") or os.getcwd())
    except Exception as exc:  # fail closed
        reason = f"guard could not analyse the command ({exc.__class__.__name__})"
    if reason:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": f"git-merge-guard: {reason}",
                }
            },
            sys.stdout,
        )


if __name__ == "__main__":
    main()
