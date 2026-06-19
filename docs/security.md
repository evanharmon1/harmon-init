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

## CI automation identity (GitHub App)

CI workflows that act on the repo as a bot — release-please, the
`claude-*` workflows — authenticate as a shared
**GitHub App**, not a personal access token. Each job mints a short-lived (1h)
installation token at runtime via `actions/create-github-app-token`, reading:

- `CI_APP_ID` — Actions **variable** (the App's numeric id; not secret)
- `CI_APP_PRIVATE_KEY` — Actions **secret** (the App's PEM private key)

For org repos, set these once as **org-level** variable + secret so every repo
inherits them; for personal repos, set them per-repo.

**Why an App, not a PAT:** tokens are short-lived (nothing to rotate yearly), the
App consumes no user seat, permissions are granular, and — unlike the built-in
`GITHUB_TOKEN` — App-token-authored PRs/pushes DO trigger CI (so a release PR's
required checks actually run). Commits the App pushes are attributed to
`<app-slug>[bot]`.

**Required App permissions** (grant nothing more):

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | commits, branches, tags, releases |
| Pull requests | Read and write | open/update the release PR and claude PRs |
| Issues | Read and write | claude comments/labels/updates issues |
| Workflows | Read and write | claude may edit files under `.github/workflows/` |
| Metadata | Read-only | required baseline |

### Blast radius & key protection

Installations are isolated: a token minted in a workflow is scoped to **one
installation** (this repo's owner) and expires in ~1h, so a leaked *token*
reaches only that org for an hour. The cross-org risk lives in the **App private
key** — it can mint a token for *every* org the App is installed on. So:

- **Install on selected repos**, not "All repositories", to bound what a key
  compromise can touch in each org.
- **Protect `CI_APP_PRIVATE_KEY`**: it lives only in Actions secrets. Never read
  it from workflows that untrusted code can influence (fork `pull_request`,
  `pull_request_target`, `workflow_run`) — the provided workflows gate on
  sender / same-repo checks.
- **Rotate the key** periodically; GitHub Apps allow multiple keys for
  zero-downtime rotation.

## Token & secret inventory

TODO: enumerate the tokens/secrets this repo depends on and where each lives:

| Secret / variable | Used by | Stored in | Rotation |
|---|---|---|---|
| `CI_APP_ID` (var) + `CI_APP_PRIVATE_KEY` (secret) | release-please, claude-* | repo or org Actions variable + secret | rotate App key per policy |
| `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | TODO |
| `SNYK_TOKEN` | `task security:sast`/`sca` | repo Actions secret | TODO |
| TODO | TODO | TODO | TODO |

## Rotation & incident notes

TODO: how and how often each secret rotates; what to do if one leaks (revoke,
re-scope, rotate, scrub history). Record notable past incidents here.
