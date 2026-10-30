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

For interactive host and dev profiles, the repository's merge invariant has
two halves (see Consequences for `-p` denial and bot/agent stand-down):

1. Any `git merge` or `git pull` that would land on `main`, `master`, a
   resolved remote default branch, a detached `HEAD`, or a checkout whose
   branch cannot be verified must reach a human approval prompt, except a
   proven `--ff-only` sync from that branch's own remote-tracking ref (the
   remote-`HEAD` limits are under Consequences).
2. A plain catch-up merge of `main` into a verified feature branch must not
   be prompted by the guard; ordinary permission rules still decide.

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

The hook is the primary local merge gate (extended by #787). `gh api` asks
unless it proves a read or an explicitly safe write. A short safe-write
allowlist covers routine metadata/review operations and sanctioned PR-head
catch-ups. Unknown writes ask; there is no dangerous-write denylist to complete.
REST paths drop the host and optional Enterprise API prefix but stay undecoded,
so encoded separators cannot manufacture a safe route. GraphQL mutation writes
require every root field to be allowlisted. Operation-controlling inputs must
be literal; presentation values and non-controlling field values may be dynamic.
Pull-request reviews ask unless the event is proved `COMMENT` or
`REQUEST_CHANGES`: this applies to `gh pr review`, REST `pulls/N/reviews`, and
GraphQL `addPullRequestReview` and `submitPullRequestReview`. Missing, dynamic,
variable-fed or unreadable file/stdin events ask too. Review approvals can satisfy
the code-owner requirement on an already auto-merging PR, so they require the
maintainer's approval even though they do not themselves request a merge.
In approval proofs, an argument is proved to stay one argument only when it is
fully literal or literal text plus quoted command substitutions (including quoted
backticks), with no parameter expansion in the word. Any parameter expansion in
CLI review arguments or REST/GraphQL review fields asks, even when quoted: a
nameref can expand to several arguments. Parameters inside a command-substitution
body belong to that nested command, not its containing word. Attached option
values use the same proof as separated values. Other API operations retain their
existing treatment of quoted dynamic presentation values.

Help/version exemptions use the active gh subcommand's flag arities: merge's
`-s` is a boolean, while sync's `-s` takes a source value. Every local-sync source
must be literal, including attached values. Feeders still ask when global gh
selectors leave the subcommand to stdin. Typed GraphQL query fields (`-F` or
`--field`) ask while `{owner}`, `{repo}`, or `{branch}` placeholders remain:
gh expands these before sending the query, which can change its operation.
Evaluator lines using printf format conversions or `printf -v` also ask when
the literal read proof does not apply; fragments can assemble an operation word.
Ordinary printf output and quoted dynamic bodies on non-review API paths keep
their existing treatment.
Evaluated API/sync strings and append-mode API feeders ask without further
interpretation. The same hook gates `gh pr merge`, remote `gh repo sync` targets
and protected/mirror pushes. Every push form shares one invariant: silence
requires proof that the destination ref equals the current branch's own name
and that name is not the destination repository's default branch. Ref mappings
can invalidate the first proof, and repository redirections invalidate the
fetch-side default-branch proof even with an explicit source:destination.
Every configured value participates in the proof. gh at a command position
keeps its fail-closed classification. Outside command position, a gh word is
data unless a following word in the same simple command is nonliteral or
literally `pr`, `api` or `repo`; those cases receive the full classification.
This covers unlisted wrappers while keeping ordinary data words silent;
`echo gh pr merge 1` therefore still asks.
A push beside companions other than `true`, `false`, `git status` and a verified
`git fetch <remote>` (for example `git commit … && git push`) asks.
Compounds reuse the existing companion grammar. `permissions.ask` remains a prefix-matching backstop when
hooks do not run. The bot/agent boundary and merge/pull allowlist are unchanged.

1. **Replace the `git merge` ask rules with `.claude/hooks/git-merge-guard.py`.**
   Remove `Bash(git merge)` and `Bash(git merge:*)` from `permissions.ask` in
   `.claude/settings.json` and `template/.claude/settings.json.jinja`, and
   register `.claude/hooks/git-merge-guard.py` as a `PreToolUse` (`Bash`) hook
   with an `|| printf '<ask JSON>'` shell fallback so an interpreter failure
   still prompts. Register the hook in project settings only (not duplicated in
   `.devcontainer/config/claude-settings.json`, decided 2026-09-30 in
   [#1435](https://github.com/evanharmon1/harmon-init/issues/1435) and
   [#1456](https://github.com/evanharmon1/harmon-init/issues/1456)).
2. **Make the guard allowlist-shaped and fail-closed.** A payload with no
   base-test risk mention is already silent under the base word test. For a
   payload with a merge/pull mention, the closed literal-read proof can
   suppress that ask only for `bash`/`sh -c` with one quoted literal payload
   or a quoted-uppercase heredoc, and only when the complete payload satisfies
   the closed read allowlist and absence proof. Otherwise, the unchanged base
   word-test fallback applies. This is a complete absence proof, not an
   enumeration of input channels; the concrete grammar and options remain in
   the hook docstring and tests. See
   [#1844](https://github.com/evanharmon1/harmon-init/issues/1844).
   Target paths accept literal path characters only, with no shell
   metacharacters. It returns
   `permissionDecision: "ask"` for every other command it inspects that might
   run a `git merge` or `git pull`, and for internal errors. Parse errors ask
   only when the text mentions git, merge or pull. The exact silent/ask
   boundary lives in `.claude/hooks/git-merge-guard.py` and is pinned by
   `scripts/test-git-merge-guard.sh`; this record deliberately does not restate it, so the two cannot drift apart. What the hook does not
   inspect is listed under Consequences.
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
   commands stalled unattended workers. `git-merge-guard` also parses every
   Bash command, but only to answer a narrower question — might this run a
   merge or pull? — and that classifier has known blind spots (see
   Consequences). Its errors land on the safe side: a false positive costs one
   prompt on that command, and a command it flags runs silently only if it is
   exactly an allowlisted shape on a verified feature branch, or the one
   default-branch exception: a configured-upstream `--ff-only` sync with an
   unambiguous operand. A merge beside any other git segment must name the
   full `refs/remotes/<remote>/<branch>` because a fetch can import shadowing
   tags after inspection or concurrently in a pipeline. A pull source is
   omitted or fully qualified as `refs/heads/<branch>` to avoid remote tag
   shadowing. In the unattended `bot` and `agent` postures the hook stands
   down entirely (see Consequences), so it cannot stall unattended workers the
   way `guard-process-kill` did.

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

- For routine catch-up merges (`git merge origin/main --no-edit`,
  `git pull --ff-only`, `git pull --no-rebase`) in a verified feature-branch
  checkout on the host and in the `dev` devcontainer, the hook adds no prompt;
  whether one appears still depends on the session's ordinary permission rules
  (for example the devcontainer's `Bash(git:*)` allow).
- Merges and pulls targeting `main`, `master`, or a resolved remote default
  branch — including `git -C <dir> merge` — other than proven fast-forward
  syncs from their own configured upstream prompt in `default`, `auto`, and
  `bypassPermissions` modes, and fail closed as a permission denial in `-p`
  mode.
- The guard requires at least one remote `HEAD` to resolve and trusts the local
  `refs/remotes/<remote>/HEAD` cache: even with a single remote, a renamed
  remote default branch whose local `refs/remotes/<remote>/HEAD` cache is stale
  is not recognized as the default branch until
  `git remote set-head <remote> --auto` refreshes the cache, and with multiple
  remotes a branch that is the default of a remote whose `HEAD` is unset stays
  silent if another remote's `HEAD` resolves to a different branch (`main` and
  `master` remain protected regardless).
- In the `bot` and `agent` postures (`FOREMAN_DEVCONTAINER` set to `bot` or
  `agent`), the hook stands down and the GitHub "Protect Main" ruleset is the
  boundary
  ([2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md](2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md)).
- The hook is a client-side backstop against mistakes, not an adversarial
  boundary: it does not inspect scripts, external git aliases, commands that
  move `main` outside its guarded entry points (`git fetch . feat:main`, `git branch -f main feat`,
  `git update-ref refs/heads/main`), or sessions launched with `claude --bare`
  or `disableAllHooks`. Server-side enforcement remains the "Protect Main"
  ruleset.
- `.claude/hooks/git-merge-guard.py` and `scripts/test-git-merge-guard.sh` are
  maintained in lockstep with their `template/` twins and gated by
  `task test:dogfood-parity` and `task test:hooks`.
