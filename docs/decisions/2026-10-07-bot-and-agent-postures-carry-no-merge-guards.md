# Bot and agent postures carry no merge guards; the ruleset is the boundary

Date: 2026-10-07

## Status

Accepted — maintainer decision of 2026-10-07. Supersedes in part
[2026-09-29-agent-posture-three-posture-model.md](2026-09-29-agent-posture-three-posture-model.md):
the agent posture's deny for merge.

## Context

Three layers guarded `gh pr merge` and `git merge`:

- the project `.claude/settings.json` (root and generated) asked on
  `gh pr merge` in every profile and on the host;
- the agent posture's managed settings denied `Bash(gh pr merge *)`;
- the `git-merge-guard` hook asked before any `git merge`/`git pull` it could
  not verify lands on a feature branch.

The hook already makes no merge checks when `FOREMAN_DEVCONTAINER` is `bot` or
`agent`: an `ask` in an unattended profile has nobody to answer it, so it
either stalls the run or is ignored, and neither is a boundary. The bot and
agent profiles were left in an inconsistent state — the hook stood down while
the project `ask` rule and the agent `deny` still tried to stop the same
operation — and what actually bounds a merge to `main` in both profiles is
the GitHub "Protect Main" ruleset: code-owner approval plus the required
status checks, for every actor.

## Decision

1. **Bot and agent carry no merge guard.** Nothing in either profile asks on
   or denies a merge. The agent managed settings drop the
   `Bash(gh pr merge *)` deny and add both `Bash(gh pr merge)` and
   `Bash(gh pr merge *)` to the explicit allow list — the wildcard form needs
   an argument, so the bare `gh pr merge` on the current branch's PR needs its
   own rule — so auto mode never stalls an agent merge on a classifier
   judgement. This stays within the agent posture's "never looser than bot"
   invariant: bot already allows `Bash(gh:*)`. The "Protect Main" ruleset is
   the only boundary on what reaches `main` in these profiles.
2. **No project-level `gh pr merge` prompt anywhere.** The `gh pr merge` ask
   rules are removed from `.claude/settings.json` — here and in every
   generated repository, with or without a devcontainer. On a host, a
   `gh pr merge` prompt comes from the user's own Claude Code settings. The
   **dev** devcontainer keeps the prompt through a managed-settings drop-in,
   `.devcontainer/config/claude-settings-dev.json`, which
   `.devcontainer/dev/post-create.sh` installs as
   `/etc/claude-code/managed-settings.d/dev-gh-pr-merge-ask.json`. The bot
   and agent post-create scripts must never install it;
   `scripts/test-template.sh` and `scripts/devcontainer-assert.sh` fail if
   they do.

Unchanged: the project `ask` rules on pushes to `main` and force-pushes, the
agent denies on force-pushes and pushes to `main`, and the `git-merge-guard`
hook in the dev profile and on the host. Those guard pushes, not merges. The
policy itself is unchanged too — agents never merge to `main` without the
maintainer's explicit, per-merge approval. What changes is only which
mechanical backstops exist where.

## Not

- **Keep the agent deny "for defense in depth".** The 2026-09-29 record
  already classes command-level denies as a best-effort first layer, not a
  boundary — they do not follow a command into Taskfile targets or git hooks
  — and already discloses that the rulesets do not stop the agent PAT from
  merging an approved PR with green checks. The deny added a stall risk under
  auto mode without moving the boundary, and it disagreed with the bot
  profile, where the same operation was never denied.
- **Keep the project `ask` in generated repositories without devcontainers.**
  It prompted in every repository using the template, including ones whose
  owners already set their own merge policy, and in the unattended profiles
  it was a stall rather than a check. A user who wants the prompt on a host
  sets it in their own settings, where it covers every repository.
- **Put the dev prompt in the image's managed settings.** The image is shared
  by all three profiles; a dev-only rule there would ship to bot and agent.
  A drop-in installed by the dev post-create script reaches only dev.

## Consequences

- **Residual risk, stated plainly.** In the bot and agent profiles, a PAT
  with `pull_requests: write` can merge any approved pull request whose
  required checks are green — at any time, without a further human step,
  whether or not the human who approved it meant "merge now". The policy
  ("agents never merge") is then the only thing between an approval and a
  merge; no mechanism enforces it in those profiles. Whether an approval
  given to an earlier head still counts after a later push depends on the
  ruleset's stale-review settings, so that setting now matters more than it
  did.
- On a host without a user-level rule, nothing prompts on `gh pr merge`
  beyond Claude Code's ordinary handling of commands no rule allows.
- The dev drop-in relies on Claude Code reading `managed-settings.d/`
  alongside `managed-settings.json`. If a Claude Code version does not, the
  dev devcontainer silently loses its merge prompt; the tests check that the
  file is shipped and installed only by dev, not that a session honours it.
