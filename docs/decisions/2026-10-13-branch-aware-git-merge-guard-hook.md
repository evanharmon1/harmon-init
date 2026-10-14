# Replace the git merge ask rules with a branch-aware merge guard hook

Date: 2026-10-13

## Status

Accepted — records the decision made when
[#1455](https://github.com/evanharmon1/harmon-init/pull/1455) (`c8903a00`)
merged on 2026-09-30 for
[#1435](https://github.com/evanharmon1/harmon-init/issues/1435). Profile scope
for unattended postures is recorded in
[2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md](2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md).

## Context

The repository's merge invariant has two halves:

1. Any `git merge` or `git pull` that would land on `main`, `master`, a
   remote's default branch, a detached `HEAD`, or a checkout whose branch
   cannot be verified must reach a human approval prompt.
2. A plain catch-up merge of `main` into a verified feature branch must run
   without a prompt.

Previously, `.claude/settings.json` (root and template) guarded local merges
with `Bash(git merge)` and `Bash(git merge:*)` in `permissions.ask`. Those
literal prefix rules failed both halves:

- **Too broad.** Every routine catch-up merge in a feature-branch worktree
  (such as `git merge origin/main --no-edit`) prompted, spending a maintainer
  approval per lane whenever `main` advanced.
- **Too narrow.** Claude Code permission rules match literal command prefixes,
  so `git -C /path merge main` did not match `Bash(git merge:*)` and ran
  without a prompt.

Before replacing those rules with a `PreToolUse` (`Bash`) hook, three hook
precedence facts were verified empirically on 2026-09-29 using real `claude -p`
runs in a scratch repository
([#1435](https://github.com/evanharmon1/harmon-init/issues/1435)):

- **A `PreToolUse` hook's `permissionDecision: "allow"` does not override a
  matching `permissions.ask` rule.** The hook fired and returned `"allow"`, and
  the `permissions.ask` rule still gated the command. Keeping the `git merge`
  ask rules alongside an allow-returning hook is therefore not viable; the ask
  rules had to be removed.
- **A `PreToolUse` hook's `permissionDecision: "ask"` holds against a matching
  `permissions.allow` rule (`Bash(git:*)`) in `default`, `auto`, and
  `bypassPermissions` modes.** In `-p` mode it surfaces as a permission denial,
  and the merge into `main` did not execute in any mode (Claude Code's
  documentation only promised `auto`; `bypassPermissions` was verified in those
  runs).
- With the `git merge` ask rules removed and the hook installed, a catch-up
  merge into a feature-branch worktree ran with no prompt.

## Decision

1. **Replace the `git merge` ask rules with `.claude/hooks/git-merge-guard.py`.**
   Remove `Bash(git merge)` and `Bash(git merge:*)` from `permissions.ask` in
   `.claude/settings.json` and `template/.claude/settings.json.jinja`, and
   register `.claude/hooks/git-merge-guard.py` as a `PreToolUse` (`Bash`) hook
   with an `|| printf '<ask JSON>'` shell fallback so an interpreter failure
   still prompts. Register the hook in project settings only (not duplicated in
   `.devcontainer/config/claude-settings.json`, decided 2026-09-30 in
   [#1435](https://github.com/evanharmon1/harmon-init/issues/1435) and
   [#1456](https://github.com/evanharmon1/harmon-init/issues/1456)).
2. **Make the guard allowlist-shaped and fail-closed.** The hook stays silent
   (deferring to normal permission evaluation) for **one narrow literal shape**
   run in the working directory reported in the hook payload, when that
   checkout is provably on a named branch other than `main`/`master` and
   distinct from every resolved remote default branch (with at least one
   remote `HEAD` resolved):
   - `git merge [--no-edit|--no-ff|--ff|--ff-only] <ref>`
   - `git merge (--continue|--quit)`
   - `git pull (--ff-only|--no-rebase) [--no-edit] [<remote> [<ref>]]`

   It returns `permissionDecision: "ask"` for every other command that invokes,
   or could invoke, a `git merge` or `git pull` — including `git -C <dir> merge`,
   non-literal subcommands, inline `-c alias.*` definitions, wrappers,
   evaluators, substitutions, `git pull` without `--ff-only` or `--no-rebase`,
   a detached `HEAD`, a checkout where no remote `HEAD` resolves, or any parse
   or internal error. Quoted text and heredoc bodies not handed to an evaluator
   (such as `git commit -m "catch-up merge"`), direct search patterns
   (`grep -n 'merge base'`), and subcommands or flags that merely contain the
   word (`git merge-base`, `git merge-tree`, `--merge-base-policy`) stay
   silent, whereas unquoted `git merge`/`git pull` tokens in another command's
   arguments (`echo git pull`) or `merge`/`pull` mentions on a line that runs
   an evaluator or matches `sudo`'s shell flags (`bash -c 'echo merge'`,
   `sudo grep -i 'git merge' README.md`) deliberately ask.
   ([#1455](https://github.com/evanharmon1/harmon-init/pull/1455) shipped the
   initial guard;
   [#1542](https://github.com/evanharmon1/harmon-init/pull/1542) and
   [#1559](https://github.com/evanharmon1/harmon-init/pull/1559) synced the
   bash-parser reader for
   [#1523](https://github.com/evanharmon1/harmon-init/issues/1523) under the
   same allowlist-shaped silent path.)
3. **Why this is not a repeat of `guard-process-kill`**
   ([2026-09-02-remove-guard-process-kill-hook.md](2026-09-02-remove-guard-process-kill-hook.md)).
   `guard-process-kill` had to classify arbitrary shell commands as safe or
   unsafe, so its parser never converged and false positives on unrelated
   commands stalled unattended workers. `git-merge-guard` instead recognizes
   one small allowlisted shape and asks on everything else that might run a
   merge or pull: parser gaps and conservative heuristics (such as
   `echo git pull`, `bash -c 'echo merge'`, or `sudo grep -i 'git merge'`) are
   narrow false positives confined to commands that mention `merge` or `pull`
   and always fail closed to a prompt rather than permitting a silent merge
   into `main`, while commands that do not mention `merge` or `pull` do not
   prompt.

## Not

- **Keep `Bash(git merge)` / `Bash(git merge:*)` in `permissions.ask` and return
  `"allow"` from the hook on feature branches.** Disproved by the empirical
  precedence check: a `PreToolUse` hook's `"allow"` does not override a
  matching `permissions.ask` rule.
- **Classify unsafe merges by denylist while allowing everything else.** A
  denylist over shell text has the same open-ended parser surface that caused
  [2026-09-02-remove-guard-process-kill-hook.md](2026-09-02-remove-guard-process-kill-hook.md)
  to be removed, with the failure mode inverted (a missed spelling would merge
  silently into `main`).
- **Duplicate the hook registration in `.devcontainer/config/claude-settings.json`.**
  Project settings already load inside the devcontainer, so a second
  registration would run the hook twice without adding coverage.

## Consequences

- Routine catch-up merges (`git merge origin/main --no-edit`,
  `git pull --ff-only`, `git pull --no-rebase`) in a verified feature-branch
  checkout run without a prompt on the host and in the `dev` devcontainer.
- Merges and pulls targeting `main`, `master`, or a resolved remote default
  branch — including `git -C <dir> merge` — prompt in `default`, `auto`, and
  `bypassPermissions` modes, and fail closed as a permission denial in `-p`
  mode.
- The guard requires at least one remote `HEAD` to resolve and trusts the local
  `refs/remotes/<remote>/HEAD` cache: with multiple remotes, a branch that is
  the default of a remote whose `HEAD` is unset (or whose cached
  `refs/remotes/<remote>/HEAD` is stale after a remote default-branch rename)
  stays silent if another remote's `HEAD` resolves to a different branch
  (`main` and `master` remain protected regardless;
  `git remote set-head <remote> --auto` refreshes the cache).
- In the `bot` and `agent` postures (`FOREMAN_DEVCONTAINER` set to `bot` or
  `agent`), the hook stands down and the GitHub "Protect Main" ruleset is the
  boundary
  ([2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md](2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md)).
- The hook is a client-side backstop against mistakes, not an adversarial
  boundary: it does not inspect scripts, external git aliases, commands that
  move `main` without `merge`/`pull` (`git push . HEAD:main`,
  `git fetch . feat:main`, `git branch -f main feat`,
  `git update-ref refs/heads/main`), or sessions launched with `claude --bare`
  or `disableAllHooks`. Server-side enforcement remains the "Protect Main"
  ruleset.
- `.claude/hooks/git-merge-guard.py` and `scripts/test-git-merge-guard.sh` are
  maintained in lockstep with their `template/` twins and gated by
  `task test:dogfood-parity` and `task test:hooks`.
