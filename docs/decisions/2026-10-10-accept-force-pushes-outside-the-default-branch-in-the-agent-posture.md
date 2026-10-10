# Accept force pushes outside the default branch in the agent posture

Date: 2026-10-10

## Status

Accepted — maintainer decision of 2026-10-09, recorded on
[#1586](https://github.com/evanharmon1/harmon-init/issues/1586).
Amends [ADR 2026-09-29 (three postures)](2026-09-29-agent-posture-three-posture-model.md)
for the agent posture's force-push denies only.

## Context

The agent posture allows `Bash(git push *)` and denies force pushes with
argument patterns: `git push --force*`, `git push -f*` and `git push * +*`, each
also in an anywhere-after-a-word form. Like the `gh api` denies that
[#1549](https://github.com/evanharmon1/harmon-init/issues/1549) replaced with a
GET-only wrapper, these patterns match only a word that starts with them. Two
spellings get through:

- `git push -uf origin <branch>`, a bundled short flag. On 2026-10-09, against a
  local bare repository, this push reported a forced update.
- `git push --mirror`, which force-updates and can delete remote branches.

The "Protect Main" ruleset blocks non-fast-forward updates and deletion only on
the default branch (`main`). Tags have their own creation and immutability
rulesets. So a force push to any other branch is stopped only by the deny
patterns.

## Decision

Accept and document the gap. The agent posture keeps `Bash(git push *)` and its
force denies as defence in depth. Its documentation states that a force push
outside the default branch is bounded only by the bot's collaborator grants, the
agent PAT's scopes and the rulesets. That is the boundary ADR 2026-09-29 already
names for every write. The full statement is in
`docs/architecture/remote-environments.md` § The agent posture; other mentions
point to it.

A ruleset that blocks force pushes and deletion on every branch is the
structural fix. Adopting it is a separate maintainer decision, tracked as the
human criterion on #1586.

## Not

- **A push wrapper** like `gh-api-read`. Pushes are routine in the agent posture,
  and a wrapper would change every push the skills prescribe.
- **More deny patterns**, such as `git push -*f*`. They are spelling-based by the
  same argument, and they would also deny legitimate long flags that contain
  an `f`, such as `--follow-tags`.

## Consequences

- Agent-posture documentation and the project's prefix `ask` rules describe the
  force-push rules as a backstop, not a boundary.
- The protection for branches other than the default branch depends on the
  bot's grants and on whatever rulesets the maintainer adopts.
