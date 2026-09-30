#!/usr/bin/env python3
"""PreToolUse(Bash) hook: ask before any git merge/pull that is not a
recognized merge into a feature branch.

Replaces the `Bash(git merge)` / `Bash(git merge:*)` permissions.ask rules,
which prompt on every merge (including routine catch-up merges of main into
a lane branch) yet miss `git -C <dir> merge` entirely, because permission
rules match literal command prefixes.

Invariant: the hook returns "ask" for every command that MIGHT run a git
merge or pull, unless the whole command is exactly one allowlisted shape run
in a verified feature-branch checkout. "Might run" is deliberately coarse:

  * after shell unquoting, the command's words include `git` (any case, any
    path) and `merge` or `pull` anywhere (so newlines, `if`, `command`,
    `g''it`, and compound lines are all covered); or
  * a git call's subcommand word is not a literal (an expansion, quote,
    escape or glob such as `git $'\x6d...'` or `git m*rge`); or
  * the command cannot be tokenized, or uses indirection (`$`, backticks,
    backslashes, eval, xargs, a nested shell), and mentions merge/pull.

The only silent (normal permission flow) shape is one fully literal command
-- no quotes, escapes, expansions, globs, operators, newlines, `cd` or `-C`:

    git merge [--no-edit|--no-ff|--ff|--ff-only] <ref>
    git merge (--continue|--quit)
    git pull (--ff-only|--no-rebase) [--no-edit] [<remote> [<ref>]]

run in the working directory Claude Code reports in the hook payload (a lane
merges from its own worktree), where that checkout is on a named branch that
is not main/master and
differs from every remote's resolved default branch -- at least one remote
default must resolve (`git remote set-head <remote> --auto`), or it asks.

The parser only decides when to stay SILENT; any gap in it costs a prompt,
never a silent merge. (The decision to remove guard-process-kill,
https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-02-remove-guard-process-kill-hook.md,
explains why an open-ended "is this safe?" classifier was rejected.)

Known limits, shared with or no worse than the rules it replaces: it does
not see through git aliases, scripts, or shell functions and aliases from the
user's profile (an alias that checks out main and pulls, one that runs
`gh pr merge --auto`, one that pushes the current branch) -- a bare
`./scripts/merge-main.sh` is silent, while `sh ./scripts/merge-main.sh` asks
(the `.sh` extension is not indirection, a shell name is) -- nor through
deliberate obfuscation that hides the `git` word itself (a variable, brace
expansion such as `{git,merge} feat`, or a glob such as `gi[t]`);
it is a backstop against mistakes, not an adversarial boundary.
It gates only git merge/pull: `git reset --hard`, `git restore` and
`git checkout -- .` discard the same conflict resolutions `git merge --abort`
would, and this hook does not see them. Nor does it see the commands that
advance main without a merge or pull: `git fetch . feat:main`,
`git push . HEAD:main`, `git branch -f main feat` and
`git update-ref refs/heads/main`. `git pull --rebase` is not silent,
because it can rewrite already-pushed feature-branch commits; neither is a
`git pull` that names no mode, because `pull.rebase` can make it a rebase. In unattended
runs (`claude -p`, lanes) an "ask" is effectively a denial, so a conflicted
merge there is recovered by a human, not by the agent. It trusts the local
`refs/remotes/<remote>/HEAD` cache -- after a remote renames its default
branch, run `git remote set-head <remote> --auto` (main/master stay
protected regardless). A
hook "allow" cannot override a permissions.ask rule, so this hook only ever
adds prompts.

Quoted text that holds the words `git` and `merge`/`pull` asks, whatever
wraps it (`git commit -m "docs: how git pull works"`, `grep 'git merge'`),
because the guard cannot tell a quoted command string from quoted prose; an
unquoted message already did the same. So does any command holding a `$`
and either word, such as a heredoc commit message or PR body
(`git commit -m "$(cat <<'EOF' ... catch-up merge ... EOF)"`). Unattended
runs ALWAYS pass commit messages and PR bodies by file, written with the Write
tool rather than a Bash heredoc, whether or not the text names both words:
`git commit -F <file>`, `gh pr create --body-file <file>`. `git.exe`,
`git -c alias.x=merge x` and the dashed `git-merge`/`git-pull`
executables are recognised by name, the last two in any position, so
`grep -rn git-merge` asks too. Three more prompts come
from the same inability to tell a command from text about one: a real bash
comment is read as text (`git log -1 # check the merge commit` asks); a
quoted string where `git` is followed by an expansion, backtick, quote,
glob or brace asks even with neither word (`--body "git $(git rev-parse
HEAD) is the head"`, a commit message saying "git `worktree`"); and any
`git` command whose text holds `alias.` asks (`git config --get alias.st`).

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
Design and rationale: evanharmon1/harmon-init#1435.
"""

import json
import os
import re
import shlex
import subprocess
import sys

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
# A mention is `merge`/`pull` as a whole word, or the dashed executable
# `git-merge`/`git-pull`. The read-only plumbing `merge-base` and `merge-tree`
# and prose like `pull-requests` are not mentions; `merge-ours`,
# `merge-recursive` and the other index-writing plumbing still are, spelled
# with a space or dashed (`git-merge-ours`); only this guard's own name is
# excluded from the dashed form.
MENTION = re.compile(
    r"(?<![\w-])merge(?!-(?:base|tree)(?![\w-]))(?!\w)"
    r"|(?<![\w-])pull(?![\w-])"
    r"|(?<![\w-])git-(?:merge|pull)(?!-guard\b)(?!\w)",
    re.I,
)
GIT_WORD = re.compile(r"\bgit\b", re.I)
INDIRECTION = re.compile(r"[$`\\]|\beval\b|\bxargs\b|(?<![\w.])(?:ba|z|da|k|c)?sh\b")
EXPANSION = re.compile(r"[$`\\*?\[{'\"]")
GIT_VALUE_OPTIONS = (
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--attr-source",
    "--shallow-file",
)
# Words are split on whitespace and these shell operators when a command
# cannot be tokenized.
WORD_SPLIT = re.compile(r"[\s;&|()]+")


def tokenize(command, commenters=""):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()")
    lexer.whitespace_split = True
    lexer.commenters = commenters
    try:
        return list(lexer)
    except ValueError:
        # An unbalanced quote (an apostrophe in a heredoc body): close it at
        # the end so the tail becomes one quoted token the ordinary rules can
        # read, rather than skipping those rules.
        for quote in ("'", '"'):
            lexer = shlex.shlex(
                command + quote, posix=True, punctuation_chars=";&|<>()"
            )
            lexer.whitespace_split = True
            lexer.commenters = commenters
            try:
                return list(lexer)
            except ValueError:
                continue
        raise


# shlex starts a comment at a `#` anywhere in a word; bash only at the start
# of one. Neither reading alone matches bash: with comments off, a quote or a
# trailing `\` inside a real comment changes how the next line tokenizes; with
# comments on, `echo a#b; git merge feat` loses its second half. So a command
# is read both ways and asks if EITHER reading might merge. The bash-like
# reading keeps `#` as a commenter after neutralising every `#` that does not
# start a word.
# `)` ends a word in bash, so `(true)# x` starts a comment there.
MIDWORD_HASH = re.compile(r"(?<=[^\s;&|()])#")


def readings(command):
    return ((command, ""), (MIDWORD_HASH.sub("_", command), "#"))


def raw_subcommand_not_literal(raw):
    """True when some git call's subcommand slot could become `merge` at run
    time: an expansion, quote, escape or glob in a still-quoted token."""
    for i, tok in enumerate(raw):
        # A `\`-newline continuation leaves the newline on the next token. Strip
        # only newlines: other whitespace inside a quoted word is part of it.
        if os.path.basename(re.sub(r"[\"'\\]", "", tok).strip("\n")).lower() != "git":
            continue
        j = i + 1
        while j < len(raw) and raw[j].startswith("-"):
            j += 2 if raw[j] in GIT_VALUE_OPTIONS else 1
        if j < len(raw) and EXPANSION.search(raw[j]):
            return True
    return False


def git_subcommand_not_literal(command, commenters=""):
    lexer = shlex.shlex(command, posix=False, punctuation_chars=";&|<>()")
    lexer.whitespace_split = True
    lexer.commenters = commenters
    try:
        raw = list(lexer)
    except ValueError:
        # Untokenizable (an apostrophe in a heredoc): fall back to words split
        # on whitespace and `;&|()`, so `git mer''ge feat # don't`, `true&&git`
        # and `(git` still show their spliced slot.
        raw = [w for w in WORD_SPLIT.split(command) if w]
    return raw_subcommand_not_literal(raw)


def might_merge(command):
    """True when the command could run a git merge/pull (coarse on purpose)."""
    return any(reading_might_merge(text, c) for text, c in readings(command))


def reading_might_merge(command, commenters):
    try:
        tokens = tokenize(command, commenters)
    except ValueError:  # unbalanced quotes, e.g. an apostrophe in a heredoc
        return bool(MENTION.search(command)) or git_subcommand_not_literal(command)
    # `git.exe` is git.
    words = {
        re.sub(r"\.exe$", "", os.path.basename(t.strip("\n")).lower()) for t in tokens
    }
    if "git" in words and (
        words & MERGE_WORDS or git_subcommand_not_literal(command, commenters)
    ):
        return True
    if words & DASHED:
        return True
    # A one-off alias (`git -c alias.m=merge m feat`) renames the subcommand;
    # git folds the section name's case.
    if "git" in words and re.search(r"\balias\.", command, re.I):
        return True
    # A quoted command string handed to any interpreter (`fish -c 'git merge x'`,
    # `pwsh -Command ...`): one token that holds both words. No interpreter list.
    if any(
        re.search(r"\s", t)
        and GIT_WORD.search(t)
        and (MENTION.search(t) or git_subcommand_not_literal(t))
        for t in tokens
    ):
        return True
    return bool(INDIRECTION.search(command) and MENTION.search(command))


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
