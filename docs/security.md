# Security, Permissions & Secret Strategy

How **Harmon Init** handles identity, permissions, and secrets. Keep this
current — it is the reference for "where do secrets live and who can do what".

> TODO: fill in the project-specific details below as the threat model firms up.

## Core principles

- **Least privilege.** Every token, account, and workflow gets the narrowest
  scope that still works.
- **No secrets in git.** Secrets are provided at runtime, never committed.
  `gitleaks` (`task security:secrets`) guards this in CI and pre-push.
- **Secrets via 1Password.** Local env comes from 1Password (`op run` /
  `op inject`); CI reads from GitHub Actions secrets. TODO: list the 1Password
  vault/items this project uses.
- **Auditable changes.** `main` is protected; changes land via reviewed PRs
  (see [branchProtection.md](branchProtection.md)).

## Two identities: the bot vs the operator

- **AI bot** (`evanharmon1-bot`) — runs in the primary
  devcontainer with a scoped fine-grained PAT (Write, no admin). Cannot push to
  or merge `main`.
- **Operator** (you) — full access from the human `dev/` devcontainer or host.

TODO: note the exact PAT scopes and any capabilities the bot is intentionally
denied (e.g. no Tailscale, no production credentials).

## Token & secret inventory

TODO: enumerate the tokens/secrets this repo depends on and where each lives:

| Secret | Used by | Stored in | Rotation |
|---|---|---|---|
| `GH_WORKFLOW_PAT` | claude-* workflows | repo Actions secret | TODO |
| `ANTHROPIC` / `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | TODO |
| TODO | TODO | TODO | TODO |

## Rotation & incident notes

TODO: how and how often each secret rotates; what to do if one leaks (revoke,
re-scope, rotate, scrub history). Record notable past incidents here.
