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
  (see [branch-protection.md](branch-protection.md)).

## Two identities: the bot vs the operator

- **AI bot** (`evanharmon1-bot`) — runs in the primary
  devcontainer with a scoped fine-grained PAT (Write, no admin) for its in-container
  git pushes. Cannot push to or merge `main`. (CI **workflows** authenticate
  separately as the `evanharmon1-ci` GitHub App — see below.)
- **Operator** (you) — full access from the human `dev/` devcontainer or host.

TODO: note the exact PAT scopes and any capabilities the bot is intentionally
denied (e.g. no Tailscale, no production credentials).

## CI automation identity (GitHub App)

CI workflows that act on the repo as a bot — release-please, the
`claude-*` workflows — authenticate as a
**GitHub App dedicated to this owner**, not a personal access token. **Each
GitHub org (and personal account) gets its own App**, named **`<owner>-ci`** —
for this repo, **`evanharmon1-ci`**. One App per org keeps a leaked key
contained to a single org (no cross-org reach).

Each job mints a short-lived (1h) installation token at runtime via
`actions/create-github-app-token`, reading:

- `CI_APP_ID` — Actions **variable** (this App's numeric id; not secret)
- `CI_APP_PRIVATE_KEY` — Actions **secret** (this App's PEM private key)

Set both once as **org-level** Actions variable + secret (every repo in the org
inherits them); for a personal-account repo, set them per-repo.

### Creating the `evanharmon1-ci` App (once per org)

The exact App config — name, the permissions below, webhook off, and
"Only on this account" — is checked in as
[`.github/github-app-manifest.json`](../../.github/github-app-manifest.json), so
you never set permissions by hand.

1. Run **`task setup:github-app`** (or open
   [`.github/create-github-app.html`](../../.github/create-github-app.html) directly)
   and click *Create the `evanharmon1-ci` app*. It POSTs the manifest to
   GitHub's app-manifest flow (org-owned for an org, account-owned for a personal
   account). *Manual alternative:* at **Settings → Developer settings → GitHub
   Apps → New GitHub App**, set the permissions from the table below by hand.
2. On GitHub's pre-filled page, review and click **Create GitHub App**.
3. **Generate a private key** (downloads a `.pem`) and note the **App ID**.
4. **Install App** → on this org, **Only select repositories** (not "All").
5. Set `CI_APP_ID` (Actions variable = the App ID) and `CI_APP_PRIVATE_KEY`
   (Actions secret = the `.pem` contents) — org-level for an org, per-repo for a
   personal account.

**Set the secrets by hand — don't script it.** Run the `gh variable set` /
`gh secret set` commands (or use the GitHub UI) deliberately; **key rotation is
manual too.** Do **not** automate org `selected`-visibility secret-setting: the
bulk `--repos` form *replaces* the secret's value and its repo allow-list, so
running it from a second repo silently evicts the first. (To add a repo to an
existing org secret non-destructively, grant it in the GitHub UI or
`PUT /orgs/{org}/actions/secrets/{name}/repositories/{repo_id}`.)

> **Manifest-flow note:** the launcher uses GitHub's app-manifest flow, which
> after creation redirects (to your Apps page) with a short-lived (~1h),
> single-use `?code=` that *can* be exchanged for an auto-generated App key. It
> stays on `github.com` (never sent to a third party) and expires unused — low
> risk when you're creating your own app on your own machine. For the strictest
> posture, use the **manual** path above (no `code` is generated), and/or rotate
> the App's keys after setup. Never paste a `?code=` URL anywhere.

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

Tokens minted at runtime are scoped to **one installation** and expire in ~1h.
Because **each org has its own App and key**, the App private key only ever
reaches **this** org — a key compromise cannot cross into another org. To keep
even the in-org radius small:

- **Install on selected repos**, not "All repositories", to bound what a key
  compromise can touch within the org.
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
