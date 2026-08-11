# Security, Permissions & Secret Strategy

How **Harmon Init** handles identity, permissions, and secrets. Keep this
current — it is the reference for "where do secrets live and who can do what".

> TODO: fill in the project-specific details below as the threat model firms up.

## Core principles

- **Least privilege.** Every token, account, and workflow gets the narrowest
  scope that still works.
- **Secrets via 1Password.** Local env comes from **1Password Environments**
  (a virtual `.env` mounted over a UNIX pipe — never written to disk or git) or
  `op run`/`op inject`; CI reads from GitHub Actions secrets.
  Devcontainer secrets are `CLAUDE_CODE_OAUTH_TOKEN` and
  `AGENT_DECK_TELEGRAM_KEY` in both profiles, `GH_TOKEN` in the bot profile only,
  `TS_AUTHKEY` in the dev profile only, plus the
  alt-model provider keys (`KIMI_API_KEY`/`MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`,
  `ZAI_API_KEY`, `QWEN_API_KEY`) when opted in — see
  [../guides/devcontainers.md](../guides/devcontainers.md).
  TODO: list the 1Password vault/items this project uses.
- **Auditable changes.** `main` is protected; changes land via reviewed PRs
  (see [branch-protection.md](branch-protection.md)).

## Security scanning: SAST, SCA, secrets & audits

Harmon Init's scanner policy separates a free baseline from optional commercial
defense in depth. GitHub-hosted CodeQL is the preferred SAST engine where it is
free: every public repository with a supported first-party language. Semgrep
Community Edition (CE) is the free CI fallback for private repositories and for
profiles without a CodeQL workflow — including this root repo, whose only
first-party source is shell/config (foreman is a pinned external CLI, not
vendored Python), so it has no CodeQL workflow.

| Axis | Root status | Default for generated repos |
|---|---|---|
| **SAST** — flaws in first-party code | Semgrep CE in CI and via `task security:sast` (no CodeQL workflow — no first-party CodeQL-supported language) | Public Node/Python: CodeQL; free private Node/Python: Semgrep CE; other profiles: Semgrep CE |
| **SCA** — dependency CVEs | Dependabot alerts + `task security:audit` (no root manifests today) | Dependabot alerts + `pnpm audit` / `pip-audit` |
| **Secrets** | gitleaks in pre-push and CI | gitleaks in pre-push and CI |
| **IaC** | N/A at the root | checkov for Terraform profiles |
| **Freshness/remediation** | Renovate, including Dependabot-alert remediation | Renovate, including Dependabot-alert remediation |

The repository-class policy is:

| Repository class | Standard |
|---|---|
| Public, CodeQL-supported | CodeQL + Dependabot alerts/Renovate + gitleaks; no Snyk by default |
| Selected important public | Optionally add Snyk Free as a scheduled SAST/SCA second opinion; private-test quotas do not apply to public repositories |
| Private | Semgrep CE is the dependable free CI SAST baseline; keep Snyk Free manual/local by default because its Organization-wide quotas can stop scans mid-month |
| Important private | Consider paid GitHub Code Security/private CodeQL and/or paid Snyk, then decide whether per-PR scans should be merge-gating |
| Qualifying public OSS | Consider Snyk's [Secure Developer Program](https://snyk.io/open-source/) for full entitlements without usage limits |

`task security` is the portable free local baseline: Semgrep CE + gitleaks + the
package-manager dependency audit. `security:sca` is an alias for that free
audit. CI routes SAST by repository visibility instead of running two engines by
default:

- public repo + supported CodeQL workflow → CodeQL;
- private repo + no paid private CodeQL opt-in → Semgrep CE;
- profile without a CodeQL workflow → Semgrep CE at either visibility;
- private repo + GitHub Code Security + `FULL_SECURITY_SCAN=true` → CodeQL.

This avoids paying for the ordinary baseline or generating duplicate findings.
Semgrep CE is useful, open-source, and runs without a hosted account, but it is
not CodeQL-equivalent: its community analysis is principally intraprocedural
and typically has shallower data-flow coverage than CodeQL or commercial
engines. It is the private-repo floor, not a claim of full vulnerability
coverage.

### CodeQL eligibility

The root repo deliberately has no CodeQL workflow: with foreman extracted to
its own repository, harmon-init's first-party source is shell and config,
which CodeQL does not analyze — Semgrep CE in `build.yml` is its SAST engine
at both visibilities. CodeQL runs automatically for every generated public
Node/Python repository. GitHub code scanning and standard GitHub-hosted
Actions runners are free for public repositories. CodeQL is preferred over
Semgrep CE there because its supported-language queries include deeper
interprocedural and data-flow analysis and integrate directly with GitHub's
Security tab.

For private/internal repositories, CodeQL code scanning requires an organization
on GitHub Team or Enterprise with
[GitHub Code Security enabled](https://docs.github.com/en/code-security/reference/code-scanning/troubleshoot-analysis-errors/private-repository-enablement).
It is
[billed by active committer](https://docs.github.com/en/billing/concepts/product-billing/github-advanced-security),
and hosted Actions usage can also consume plan minutes.

`FULL_SECURITY_SCAN=true` is only a workflow run switch. It does not grant the
paid entitlement, create a missing workflow, or prove that analysis uploaded
successfully. Confirm a successful run and results in the Security tab before
counting private CodeQL as coverage. Leave it unset on free private repositories;
the build workflow then runs Semgrep CE automatically. Public CodeQL cannot be
disabled with this variable.

### Dependency monitoring and update ownership

Dependabot **alerts** are free for public and private repositories and are the
continuous GitHub advisory feed. Renovate owns both routine dependency update PRs
and alert-remediation PRs (`vulnerabilityAlerts.enabled=true`). Do not add a
`dependabot.yml`: enabling Dependabot version/security update PRs alongside
Renovate would create competing automation. Package-manager audits remain in CI
as an immediate, provider-independent check.

Detection runs on two feeds with **different reach**, and the difference decides
what each is good for:

- `vulnerabilityAlerts` reacts to GitHub's Dependabot alerts, which read the
  full resolved dependency graph and therefore cover **transitive** packages —
  where nearly every advisory that actually bites a lockfile lives. It produces
  nothing when Dependabot alerts are switched off for the repository, and being
  switched off is invisible from the config, which still reads `enabled=true`.
  Verify the feature itself, not the config: `gh api
  repos/<owner>/<repo>/vulnerability-alerts` returns `204` when enabled and
  `404` when not.
- `osvVulnerabilityAlerts=true` queries `osv.dev` independently of repository
  visibility and of any GitHub Advanced Security setting, but Renovate
  [surfaces OSV alerts for **direct dependencies only**](https://docs.renovatebot.com/configuration-options/#osvvulnerabilityalerts).
  It is a second feed for first-party dependencies, **not** a fallback for
  transitive ones.

So a repository with Dependabot alerts disabled has no continuous transitive
coverage at all, whatever `renovate.json` says. Its first signal is a red
package-manager audit in CI, which arrives when somebody next opens a PR rather
than when the advisory is published. Enabling the Dependabot alert feed is what
closes that gap; OSV narrows the direct-dependency window alongside it.

### Snyk second opinion and scheduling

Snyk is not installed by default and is not part of `task security` or required
PR CI. The explicit `task security:sast:snyk` and `task security:sca:snyk`
targets provide manual/local second-opinion scans. `security:sca:snyk` uses
`--all-projects`, so every detected manifest is scanned—and each manifest can
consume a separate Snyk Open Source test on a private repository.

The Copier answer `snyk_scan_schedule` controls the optional generated workflow:

- `off` (default) — no workflow; keep `SNYK_TOKEN` local;
- `weekly` — quota-aware advisory scans, appropriate for a selected repository;
- `daily` — intended for public repositories or an accepted unlimited OSS
  project, not the ordinary private Free-plan posture.

harmon-init itself is set to **weekly**, so this repository generates
`snyk-scheduled.yml` (Sunday 06:23 UTC). It is a public repository, so the
private-test allocation below does not apply to it; the scan stays advisory and
is never a required PR check.

When enabled, `snyk-scheduled.yml` installs a pinned CLI and runs Snyk Code
(SAST) plus Snyk Open Source (SCA) as separate matrix jobs. It triggers only on
its schedule or manual dispatch—not on pull requests or pushes—and is excluded
from branch protection. Add the `SNYK_TOKEN` Actions secret only for this
explicit scheduled opt-in. Run it manually once and watch the Snyk Organization
Usage page. The workflow passes the public Git remote explicitly; if Snyk still
debits private-test usage for a public repo, follow Snyk's
[documented remedy](https://docs.snyk.io/developer-tools/snyk-cli/getting-started-with-the-snyk-cli#running-out-of-tests):
run `snyk monitor` once and set the public Git remote URL in the Snyk Project.
Scheduled and local CLI tests draw from the same private-repository allocation.
Weekly is the conservative cadence. Daily Snyk Code alone is about 30 tests per
repository per month, before manual tests, and SCA multiplies by the number of
manifests.

The scheduled workflow is intended primarily for selected important public
repositories because Snyk's private-test limits do not apply there. A private
repository may deliberately choose weekly after estimating Organization-wide
usage, but the standard remains Semgrep CE in CI plus occasional local Snyk.
Dependabot already monitors dependency advisories continuously, so weekly Snyk
is normally enough for a second opinion.

No Snyk GitHub App is needed for local or scheduled CLI scans. Leave it off on
ordinary repositories. If installed, its PR checks are not required by the
branch ruleset; remove the repository from the integration to eliminate them.

### Paid escalation for a high-consequence product

For a high-consequence product, choose paid controls based on the missing
capability rather than enabling everything reflexively:

- **GitHub Code Security** supplies private-repository CodeQL and keeps results
  and remediation in GitHub.
- **Paid Snyk** can be an alternative or a second SAST/SCA opinion, especially
  when license policy, reachability prioritization, or vendor reporting matters.
- **GitHub Secret Protection** adds server-side secret scanning, push protection,
  and governance; gitleaks remains useful locally and in CI but does not block a
  secret before it reaches GitHub in every client/path.
- **DAST**, tenant-isolation tests, and container/image scanning are separate,
  application-specific controls. A deployed web application should evaluate
  them; a library or docs repository usually should not.

## Two identities: the bot vs the operator

- **AI bot** (`evanharmon1-bot`) — runs in the primary
  devcontainer with a scoped fine-grained PAT (Write, no admin) for its in-container
  git pushes. Cannot push to or merge `main`. (CI **workflows** authenticate
  separately as the `evanharmon1-ci` GitHub App — see below.)
- **Operator** (you) — the human `dev/` devcontainer and the host, authenticated
  by an ordinary `gh auth login` against your own account. The bot's PAT is
  **absent** from that profile.

Each profile authenticates as the identity it commits as, and neither carries the
other's credential.

### The operator's credential in the `dev/` profile

The `dev/` profile commits as the operator, so it authenticates as the operator.
It carries **no `GH_TOKEN`** — not as tidiness, but because there is no other way
to get this right. `gh` prefers `GH_TOKEN` over any stored credential
unconditionally and exposes no precedence knob, so a bot PAT sitting in a human
container silently wins every `gh` call and, through the credential helper, every
`git push`. Removing it *is* the mechanism. `init-env.sh` evicts a stale value
from the dev env-file on every rebuild, and `scripts/devcontainer-assert.sh`
asserts the absence in both the config and the running container.

Removing `GH_TOKEN` is necessary but not sufficient, and the shortfall is the
quiet kind. `gh` falls through to `GITHUB_TOKEN`, then the enterprise aliases,
then the stored login — so dropping only the first hands the container to
whichever alias happens to be present, still as the wrong identity and with
nothing to show for it. The profile therefore blanks all three aliases in
`containerEnv`, which outranks the env-file and which `gh` reads as unset.

Three consequences worth stating plainly:

- **The ceiling is your own access, not a curated repo list.** A fine-grained PAT
  has exactly one resource owner, so the previous arrangement capped the human
  container at that token's selected repositories — every other org was
  unreachable no matter what your account could see. An OAuth login has no such
  cap. That is the point, and also the cost: this container now reaches
  everything you do.
- **The credential is not persisted.** `~/.config/gh` is on no volume, so a
  rebuild ends the session and you log in again. Deliberate: the container has no
  keyring, so `gh` would store the token as plaintext `hosts.yml`, and persisting
  it would leave a broad, long-lived credential at rest on a docker volume. The
  trade is friction in exchange for nothing at rest. Steps:
  [guides/devcontainers.md](../guides/devcontainers.md).
- **Unattended agents belong in the bot profile.** A human-authed container gives
  any agent running in it your full reach, and an agent can read its own
  container's credentials. Attended work in `dev/`; headless and Foreman runs in
  the bot container, where the PAT's denials below still apply. Note what this
  removes: foreman builds each agent's environment as a strict allowlist that
  swaps `GH_TOKEN` for the read-only agent token, but `HOME` is in that
  allow-list — so a gh-stored login makes that least-privilege gate **vacuous**
  in `dev/`. The gate is real only in the profile it was written for.

### The bot's fine-grained PAT

Permissions live in
[branch-protection.md](branch-protection.md#bot-account-pat-permissions) — that
table is the source of truth. **Nothing beyond it.** The step-by-step for
creating one is [guides/bot-account.md](../guides/bot-account.md).

**Deliberately denied**, each load-bearing rather than incidental:

- **Workflows** — the bot cannot edit `.github/workflows/`. This is what stops
  the classic escalation: rewrite a workflow, let it run with Actions secrets,
  exfiltrate. It matters more than it looks, because any agent sharing the bot's
  devcontainer can read this token out of the environment — so this one
  restriction is much of what stands between a prompt-injected agent and every
  Actions secret. Assert it; do not assume it.
- **Administration** — no ruleset, settings, or bypass changes. Note the
  consequence: reading a ruleset's bypass actors needs a permission the bot does
  not have, so a preflight check that wants it must use a different identity or
  be dropped.
- **Tailscale and on-demand secret fetch** — the bot profile installs no
  1Password CLI, so there is **no path to pull arbitrary secrets on demand**, and
  no Tailscale, so no tailnet reach (see
  [guides/devcontainers.md](../guides/devcontainers.md)). Note what this does
  *not* say: the container is not secret-free. It holds whatever the env-file
  carries. That set is a **property of the 1Password Environment behind the
  env-file** — a convention you maintain, not a guarantee the profile enforces.
  Put a production credential in that Environment and it lands in the container,
  next to the agent.

### Effective access = min(collaborator grant, PAT permissions)

A fine-grained PAT is a **delegation of its owner's access** and can never exceed
it. Two independent layers must *both* allow an operation:

1. **The repo collaborator grant** on the bot account — *per repo*, and where
   granularity actually lives.
2. **The PAT's selected-repo list and permission set** — the permission set is
   **uniform across every selected repo**; there is no per-repo matrix.

So a repo where the bot is a `pull` collaborator stays read-only even though the
PAT carries `contents: write` — the grant caps the token. One PAT can therefore
back a mix of read-only and writable repos.

Two practical consequences:

- **Two levers, different jobs** — picking the wrong one is why this gets
  confusing. To change the *level* on a repo the bot still works (write → read),
  change the **collaborator grant**; a PAT cannot express per-repo levels. To stop
  *this token* reaching a repo while the bot keeps access, remove it from the PAT's
  **selected-repo list**. To revoke the bot entirely, drop the grant — and the list
  entry too, so the token stops carrying reach it cannot use.
- **Both layers, in order.** Adding a repo to the PAT's list does nothing if the
  bot has no access to it; granting access does nothing if the repo is not in the
  list.

### What a leaked bot PAT reaches

Write it down rather than re-derive it under pressure:

- **The selected repos** — at the level each collaborator grant allows, capped by
  the permission table. It can push branches, open PRs, and comment. It **cannot**
  merge `main` (ruleset + CODEOWNERS), edit workflows, or change settings.

**Read is cheap; write is the line.** Variables are read-only deliberately:
write could opt a private repository into paid CodeQL or mutate other
security/deployment switches without a PR diff. Public CodeQL does not depend on
`FULL_SECURITY_SCAN` and cannot be disabled through that variable. The read grant
is safe only because GitHub separates Secrets from Variables; if a variable ever
holds something sensitive, read becomes exfiltration. Check when adding a
variable, not forever.

## CI automation identity (GitHub App)

CI workflows that act on the repo as a bot — release-please, the
`claude-*` workflows, `sync-harmon-devkit.yml` — authenticate as a
**GitHub App dedicated to this owner**, not a personal access token. **Each
GitHub org (and personal account) gets its own App**, named **`<owner>-ci`** —
for this repo, **`evanharmon1-ci`**. One App per org keeps a leaked key
contained to a single org (no cross-org reach).

One deliberate exception inside the `claude-*` workflows: the claim-lifecycle
label writes (`claim:claude` on and off the target) use the built-in
`GITHUB_TOKEN` under the job's own `issues: write` permission, not the App
token — it stays valid for the whole job (an App token expires in an hour, and
the release runs at the very end) and its writes never trigger another workflow
run. Everything the model does, and every PR it opens, still uses the App token.

Each job mints a short-lived (1h) installation token at runtime via
`actions/create-github-app-token`, reading:

- `CI_APP_CLIENT_ID` — Actions **variable** (this App's **Client ID** — the `Iv…`-style
  string from the App's settings page, NOT the numeric App ID; not secret)
- `CI_APP_PRIVATE_KEY` — Actions **secret** (this App's PEM private key)

Set both once as **org-level** Actions variable + secret (every repo in the org
inherits them); for a personal-account repo, set them per-repo.

### Creating the `evanharmon1-ci` App (once per org)

Create the App **by hand.** GitHub's app-manifest ("one-click") flow only
finalizes an app through a server-side callback it redirects to, so a static page
can't complete it (it redirects, the one-time `?code=` expires unused, and no app
is created) — there is no working shortcut. The exact permission set is checked in
as [`.github/github-app-manifest.json`](../../.github/github-app-manifest.json) as
a machine-readable reference; mirror it in the form.

1. Open **New GitHub App** — for an org,
   `https://github.com/organizations/evanharmon1/settings/apps/new`; for a
   personal account, `https://github.com/settings/apps/new`
   (**Settings → Developer settings → GitHub Apps → New GitHub App**).
2. Set **GitHub App name** `evanharmon1-ci` (names are globally unique — if
   it's taken, add a suffix; the workflows reference the **Client ID**, not the
   name), **Description** = the `description` from the manifest (optional,
   cosmetic — documents what the App is for), **Homepage URL** = the owner's page
   `https://github.com/evanharmon1` (also required-but-cosmetic — it doesn't
   scope the App to any repo; the App is owner-wide), **uncheck the "Active"
   webhook**, leave **"Expire user authorization tokens"** checked (the default —
   CI uses installation tokens, not the user-to-server tokens this governs), grant
   the permissions in the table below, and choose **"Only on this account"**. Then
   scroll down and click **Create GitHub App**.
3. **Generate a private key** (downloads a `.pem`) and copy the **Client ID**
   (shown at the top of the App's settings page — not the numeric App ID).
4. **Install App** → on this org, **Only select repositories** (not "All").
5. Set `CI_APP_CLIENT_ID` (Actions variable = the App's Client ID) and `CI_APP_PRIVATE_KEY`
   (Actions secret = the `.pem` contents) — org-level for an org, per-repo for a
   personal account. **Set the private key by piping the `.pem` file in, never by
   pasting it** — redirecting the file preserves its newlines, whereas a copy-paste
   into the web UI (or a `gh secret set -b "…"` string) can flatten them and leave
   the key undecodable. `create-github-app-token` then fails at JWT-signing time
   with `error:1E08010C:DECODER routines::unsupported` (or `Invalid keyData`):

   ```bash
   # personal account / single repo:
   gh secret set CI_APP_PRIVATE_KEY --repo <owner>/<repo> < evanharmon1-ci.*.private-key.pem

   # org: set the value once, scoped to the repos that need it now (add the
   # variable the same way). Then finalize/audit repo access in the UI — see below.
   gh secret set CI_APP_PRIVATE_KEY --org evanharmon1 \
     --visibility selected --repos <repo>[,<repo2>] < evanharmon1-ci.*.private-key.pem
   ```

**Set the secrets by hand — don't script it.** Run the `gh variable set` /
`gh secret set` commands deliberately; **key rotation is manual too.**

**Recommended process — the CLI sets the value, the UI owns the repo list.** Set
the value once from the `.pem` file (above), scoped with `--visibility selected
--repos` to whatever repos make sense at the time (selecting them all is fine if
that's the reality). From then on, **finalize and maintain which repos can read
it in the GitHub UI** — org → *Settings → Secrets and variables → Actions* → the
secret → **Repository access**. Editing the list there changes scope **without**
re-entering the value, and the page doubles as a sanity check of exactly who has
access. Don't reach for `--visibility all` as a shortcut: it exposes the key to
every org repo until you narrow it.

Keep list-management in the UI because `gh secret set` is **declarative** — the
`--repos` form *replaces* the secret's value **and** its whole repo allow-list on
every run, so re-running it from a second repo silently evicts the first. The UI
(or `PUT /orgs/{org}/actions/secrets/{name}/repositories/{repo_id}`) is the
non-destructive way to add a repo.

**Why an App, not a PAT:** tokens are short-lived (nothing to rotate yearly), the
App consumes no user seat, permissions are granular, and — unlike the built-in
`GITHUB_TOKEN` — App-token-authored PRs/pushes DO trigger CI (so a release PR's
required checks actually run). Commits the App pushes are attributed to
`<app-slug>[bot]`.

**Required App permissions** — select each of these on the form (the form
pre-checks nothing, **Metadata included**, so set them all explicitly); grant
nothing more:

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
- **Never put `workflow_dispatch` on a workflow that mints an App token.** For
  that trigger GitHub runs the workflow definition from whichever ref the
  operator selects, so any branch — reviewed or not — could rewrite the
  token-minting step and use the credential. Pinning the *checkout* to `main`
  does not help: the token already exists. Every App-token workflow here is
  reachable only through triggers that pin the definition to the default
  branch — `push` (release), the issue/PR events (`claude-*`), and
  `repository_dispatch` (`sync-harmon-devkit`). Use `repository_dispatch` when
  a manual trigger is needed; it takes the same repository write access and
  always runs the default branch's definition.
- **Rotate the key** periodically; GitHub Apps allow multiple keys for
  zero-downtime rotation.

## Token & secret inventory

TODO: enumerate the tokens/secrets this repo depends on and where each lives:

| Secret / variable | Used by | Stored in | Rotation |
|---|---|---|---|
| `CI_APP_CLIENT_ID` (var) + `CI_APP_PRIVATE_KEY` (secret) | release-please, claude-*, sync-harmon-devkit | repo or org Actions variable + secret | rotate App key per policy |
| `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | TODO |
| `SNYK_TOKEN` | optional Snyk CLI scans; also the weekly `snyk-scheduled.yml` | local env / 1Password locally; repo Actions secret for the weekly schedule | manual |
| `GH_TOKEN` (the bot's PAT) | the **bot** devcontainer's `gh`/git operations — never the `dev/` profile | 1Password Environment → devcontainer `--env-file` | manual; re-issue before expiry ([guides/bot-account.md](../guides/bot-account.md)) |
| `FOREMAN_AGENT_GH_TOKEN` (read-only PAT) | handed by foreman to dispatched agents as their `GH_TOKEN`; bot profile only, required before any dispatch | 1Password Environment → devcontainer `--env-file` | manual; rotate with the bot PAT |
| TODO | TODO | TODO | TODO |

## Rotation & incident notes

TODO: how and how often each secret rotates; what to do if one leaks (revoke,
re-scope, rotate, scrub history). Record notable past incidents here.
