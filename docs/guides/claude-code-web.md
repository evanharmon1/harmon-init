# Claude Code on the web

One cloud environment, for every repo, that runs the dev loop from the shared
bootstrap — and what is known, and not yet known, about how the loop's `gh`
calls behave behind the platform's GitHub proxy.

Read this when creating or editing the environment at
[claude.ai/code](https://claude.ai/code), when a cloud session fails in a way
that looks like an auth problem, or when deciding what to send to the cloud.
The contract the setup script honours (every tool installed by the same script,
from the same pin, as the shared image) is
[architecture/remote-environments.md](../architecture/remote-environments.md);
this is the Claude-Code-specific *procedure* and record.

## How to read the evidence in this guide

Every platform fact carries where it came from, because the platform changes and
some facts here have not been seen by a person yet:

| Tag | Meaning |
| --- | --- |
| **docs, 2026-09-29** | Stated by the platform docs ([cloud environments](https://code.claude.com/docs/en/cloud-environments), [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)), re-read on that date. Where they differ from what was observed, the docs win as the *documented* behaviour and this guide says so |
| **observed 2026-09-27** | Seen in a real Claude Code on the web session (a full dev loop on several harmon-devkit PRs), recorded in the [evidence comment on #1407](https://github.com/evanharmon1/harmon-init/issues/1407#issuecomment-5860625937) |
| **observed 2026-10-06** / **2026-10-07** | Seen by the maintainer in a live walkthrough of the `harmon-remote` environment (network **Trusted**; setup script the recipe at `v5.2.0`, with the interim `sudo env …` line from 23:19Z on 2026-10-06). Claude Code on the VM was 2.1.292; the local CLI used for `--cloud` was 2.1.284 |
| **REST since #1430** | A harmon-init script moved off GraphQL-backed `gh` subcommands onto the bounded REST helpers in `scripts/lib/gh-rest.sh`. Tested hermetically; not yet run in a cloud session |
| **expected, not yet observed** | Derived from the docs or from how a script is written. **Not** an observation |
| **pending** | A `[HUMAN]` observation that still needs a live session run by the maintainer. Each has a row marked open in [Pending observations](#pending-observations) |

Nothing marked *expected* or *pending* should be relied on as fact.

## The environment

Environments are personal to the claude.ai account (Team and Enterprise Owners
can share one — *docs, 2026-09-29*). Create it from the environment selector at
claude.ai/code → **Add cloud environment**. There is no settings page or URL for
it. One environment serves every repository, because nothing in it is per-repo.

| Field | Value |
| --- | --- |
| **Name** | `harmon-remote` |
| **Network access** | **Trusted**; **Custom** with `semgrep.dev` added if sessions open their own draft PRs — see [Network](#network) |
| **Environment variables** | see [Environment variables](#environment-variables); none is a secret |
| **Setup script** | the block below |

Select it for CLI-started sessions with `/remote-env` (saved as
`remote.defaultEnvironmentId` in user settings — *docs, 2026-09-29*), so
`claude --cloud` uses it without a flag.

### Setup script

The script is the entrypoint from
[architecture/remote-environments.md § The entrypoint](../architecture/remote-environments.md#the-entrypoint),
unchanged. It runs as root before Claude Code starts, and the platform snapshots
the filesystem when it finishes inside about five minutes (*docs, 2026-09-29*).

```bash
#!/bin/bash
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
  && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
    -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
  && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
```

Rules for this script, each with its reason:

- **Pin a release tag, never `main`.** The bootstrap refuses anything that is not
  `vX.Y.Z`. The tag is the trust root, and the environment moves only when you
  edit the tag — which also rebuilds the cache (*docs, 2026-09-29*: a changed
  setup script re-runs it).
- **`vX.Y.Z` is the release tag you want, `v4.48.0` or later.** `v4.48.0`
  (published 2026-10-03) is the first release that carries the bootstrap; the
  latest when this was written is `v5.2.0`. **A release older than the one that
  carries the trust-store fix fails behind the platform's TLS-intercepting
  proxy** — observed 2026-10-06, Claude Code 2.1.292, network **Trusted**: at
  `v5.2.0` the setup script exits 2 at `==> semgrep 1.178.0` with `invalid peer
  certificate: UnknownIssuer`, because the VM's proxy CA is seeded into the
  system trust store and `sudo` resets the environment that names it. Until you
  pin a release that carries the fix, run the recipe's last line with `env` after `sudo`
  — `sudo env UV_SYSTEM_CERTS=1 NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt bash`
  and then the same script path and `--ref` arguments as before. With that, the
  unchanged `v5.2.0` bootstrap completed with `tiers core,agents, 20 new
  install(s)` and exit 0. That line is verified at `v5.2.0` only: releases
  `v4.48.0` through `v5.2.0` all need it, and the release that carries the fix
  will not. Why the fix is in the bootstrap rather than in the
  recipe:
  [architecture/remote-environments.md § The network the bootstrap may use](../architecture/remote-environments.md#the-network-the-bootstrap-may-use).
- **Do not append `|| true`.** The platform fails the session start when the
  script exits non-zero (*docs, 2026-09-29*). Here that is the wanted outcome: a
  session that starts without the pinned toolchain would run the dev loop
  against the platform's stock tools and pass or fail for the wrong reasons — the
  Python `yq` on the VM's `PATH` is the documented example.
- **Keep the download its own command.** Piping `curl` into a shell exits 0 when
  the download fails. `scripts/test-bootstrap-remote.sh` checks that shape in
  every copy of the recipe, and holds this one equal to the architecture
  document's line for line; the leading `#!/bin/bash` and the pinned tag are the
  only differences it allows.
- **The default tiers only** (`core,agents`). The browsers tier is larger than
  everything else together and would put the five-minute cache budget at risk.
- **No `--tiers` flag, no other install lines.** Anything the loop needs belongs
  in the shared scripts, so the image and every other remote adapter get it too.

**Observed (criterion 1), 2026-10-06, Claude Code 2.1.292
on the VM:** with the trust store named as above, the bootstrap completed in 86
seconds, and in 48 seconds on a second fresh VM — well inside the
platform's five-minute cache budget. Without it, the same script fails at
`semgrep`, as the release-tag rule above describes. CI's `remote-bootstrap` job
cannot see that failure: its stock `ubuntu:24.04` container has a direct network
and no intercepting proxy (in the same image, a local run of this recipe
completed in 43 seconds), and it runs the checkout's own bootstrap rather than
the recipe's download at a tag. Both runs were the platform running the environment's setup script,
with the recipe's last line in the interim form; the recipe unchanged, at the
first release after `v5.2.0` (the one that carries the fix), is not yet observed.

**Caching was not observed to work, in two consecutive sessions.** The session
started at 23:28Z on 2026-10-06 (VM booted 23:28:14Z) ran the setup script
again (log 23:30:08Z to 23:30:56Z, 48 s), after an environment-variable edit.
The session started at 04:34:53Z on 2026-10-07 also ran it (log 04:35:09Z to
04:36:08Z, 59 s), with no edit to the environment's variables, script or
network level in between. The maintainer did change the account's GitHub
connection between those two sessions ([Whose identity GitHub
sees](#whose-identity-github-sees)). An uncached session took about three
minutes from VM boot to ready. Whether a GitHub-connection change invalidates
the snapshot, or the snapshot is simply not reused, is not established.

### Network

Choose **Trusted** (the platform default). The bootstrap's
[allowed hosts](../architecture/remote-environments.md#the-network-the-bootstrap-may-use)
were probed on 2026-09-27 and every one of them is on the platform's Trusted list
(*docs, 2026-09-29*) except `cdn.playwright.dev`, which only the opt-in browsers
tier contacts and which this guide does not enable. `ports.ubuntu.com` is the
arm64 archive; the cloud VM is x86-64, so it is never contacted, and `*.ubuntu.com`
is on the list anyway.

**Added domains: none**, for sessions that end at a pushed branch, which is what
a cloud lane does ([What runs where](#what-runs-where)). That list is
provisional, and it is empty on purpose: the rule is that a domain is added only
after a *recorded denial* under Trusted while the bootstrap, `task verify`, or —
in a session that opens its own draft PR — `task security` ran. The denials
recorded so far, and the one that a session opening its own draft PR needs:

| Host | Denied for | Added? | Reason |
| --- | --- | --- | --- |
| `semgrep.dev` | `task security`'s Semgrep step — observed 2026-09-27, under a network level presumed, but not recorded, to be Trusted | **Only where the session opens the draft PR itself**, which makes the level **Custom** | `task security` must pass before the draft PR (`AGENTS.md`), and this host is what its Semgrep step needs. A lane that stops at a pushed branch leaves the gate to the machine that opens the PR — see [Long-running gates](#long-running-gates). Never skip the gate instead |
| `api.openai.com`, `auth.openai.com`, `chatgpt.com` | the Codex CLI (#1406) | No | Ephemeral clouds never hold a Codex login (#1408 decision 4): the orchestrator reviews the lane's pushed branch from its own pane, and the lane's PR records it (`AGENTS.md` § Remote environments) |
| `deb.nodesource.com`, `astral.sh`, `keybase.io`, `ppa.launchpadcontent.net`, `cli.github.com`, `dl.google.com` | installer hosts (#1403) | No | The bootstrap no longer contacts them; the denied table in the architecture document is guarded so they cannot return |
| `cafe.github.com` | `gh` telemetry | No | Harmless |
| `cdn.playwright.dev` | Playwright Chromium | No | Browsers tier only, off by default; not on the Trusted list |

The session that recorded these denials did not record which network level it
ran under; it is presumed to be the default, Trusted.

**Observed (criterion 8), 2026-10-06, Claude Code 2.1.292, network Trusted:**
the bootstrap, with the interim `sudo env …` line, completed, and `task verify`
completed with `GATE-EXIT=0`, run detached in the form under [Long-running
gates](#long-running-gates). A case-insensitive scan of the verify log for
`403|denied|blocked|Could not resolve|Connection refused|CONNECT|proxy|certificate|UnknownIssuer|ENOTFOUND|ECONNREFUSED`
found no network denial; the only hits were test names. No domain had to be
added for the bootstrap and `task verify`, so the table above stands unchanged.
`task security` was not run in that session, so the `semgrep.dev` row still
rests on the 2026-09-27 observation. Two things the docs say could have
failed, and what was seen:

- *Release-asset scope.* The GitHub proxy limits "GitHub API and release-asset
  requests" to repositories attached to the session, and says a setup script
  downloading release assets from an unattached repository gets a 403 (*docs,
  2026-09-29*). **Observed 2026-10-06 under Trusted: the downloads from
  repositories not attached to the session succeeded** — go-task, cli/cli,
  gitleaks, lychee, shfmt, actionlint, hadolint, yq, lefthook and uv — and the
  bootstrap installed all of them. The documented 403 did not apply to the
  setup script, so the shared-script contract needs no decision.
- *Custom instead of Trusted.* The list is per environment and there is no
  organization-wide allowlist (*docs, 2026-09-29*); if a domain does have to be
  added, the level becomes **Custom** with **Also include default list of common
  package managers** checked.

Other levels: **None** breaks every install, and **Full** gives up the
allowlist the platform's proxy audit trail is meant to give you.

### Environment variables

The environment needs none for the bootstrap, and it holds no secret: every
variable, and the setup script, is readable by anyone who uses the environment
(*docs, 2026-09-29*).

| Variable | Value | Why | Status |
| --- | --- | --- | --- |
| `LANG` | `C.UTF-8` | The VM's locale is POSIX (observed 2026-09-27). The bootstrap fixes `/etc/environment` and login shells, but a process Claude Code launches may read neither, and a non-UTF-8 locale silently changes what Unicode checks accept | value observed present in the session, 2026-10-06 |
| `BASH_DEFAULT_TIMEOUT_MS` | `600000` | The Bash tool waits two minutes by default; the platform documents these two variables for raising it | value observed present, 2026-10-06; whether the ten-minute wait is honoured was not exercised (the long gate ran detached) |
| `BASH_MAX_TIMEOUT_MS` | `600000` | The documented ceiling is ten minutes; whether a larger value is honoured has not been tried, so this guide does not ask for one | value observed present, 2026-10-06; the ceiling was not exercised |

**Enter each variable on its own line, and check what the session saw.**
Observed 2026-10-06: on the first save, the three variables were entered on
separate lines, but the session saw `BASH_DEFAULT_TIMEOUT_MS` holding
`600000 BASH_MAX_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS` unset. After
deleting the variables and **retyping** them one per line, the session saw all
three exactly. Check in a new session:

```bash
env | grep -E '^(LANG|BASH_DEFAULT_TIMEOUT_MS|BASH_MAX_TIMEOUT_MS)=' | cat -A
```

Each line must end in `$` straight after its value, with nothing else on it.

Do **not** set `GH_TOKEN` or `GITHUB_TOKEN`. With neither set, both read as the
placeholder `proxy-injected` and the proxy substitutes the real credential on
GitHub requests; a token you set is passed through as a plain variable, is
visible to everyone who uses the environment, and does not lift the proxy's
GraphQL restriction (*docs, 2026-09-29*). A script that reads `GITHUB_TOKEN`
directly, rather than letting `gh` do it, gets the placeholder.

## Identity and secrets

The policy, in order of precedence:

1. **No 1Password, and no other credential store.** The bootstrap never installs
   `op`, and a shared remote VM must not hold a credential-bearing tool. Nothing
   in a cloud session writes to a password manager.
2. **GitHub goes through the platform's connection, and nothing else.** The
   credential stays encrypted on the platform's servers and never enters the VM;
   the git client holds a scoped credential the proxy swaps for the real token
   (*docs, 2026-09-29*).
3. **Any other credential an unattended run needs is an API credential where the
   platform has them, else an environment variable.** API credentials are Pro and
   Max only: an admin-role user adds a key and the list of hosts it applies to
   from an *existing* environment's editor, and the agent proxy attaches it to
   requests to those hosts after they leave the VM, so the key never reaches the
   session. The proxy never attaches one to GitHub, the Anthropic API, or the
   public package registries, or to setup-script requests (*docs, 2026-09-29*).
   On Team and Enterprise there is no API credential yet, so the only place is an
   environment variable, **which every user of the environment can read**. No
   step of the dev loop needs one today; add one only for a documented reason and
   say in the table above which visibility applies.
4. **The session itself needs no token from you.** It is authenticated by the
   platform. The agent-posture decisions ([#1408](https://github.com/evanharmon1/harmon-init/issues/1408))
   keep `ANTHROPIC_API_KEY` out and admit no Codex login to an ephemeral cloud.

### Whose identity GitHub sees

Cloud sessions act as the bot account, `evanharmon1-bot`, because **the Claude
GitHub App is authorized as the bot**. That is the working route, observed
2026-10-07; it amends the mechanism #1408 decided on 2026-09-27, which did not
work.

**What was decided on 2026-09-27 (#1408 decision 3).** Cloud sessions act as the
bot through **one classic personal access token** with the `repo` scope and
**no** `workflow` scope, handed to the platform by running `/web-setup` with
`gh` authenticated as the bot. It is one token because `/web-setup` holds a
single token across both owners (evanharmon1 and ponderousdev); what the bot may
touch is bounded by its per-repo collaborator grants, as in
[bot-account.md](bot-account.md). The operator's own token was the fallback if
the platform refused a token whose GitHub user differs from the claude.ai
account.

**What was observed on 2026-10-06 and 2026-10-07, Claude Code 2.1.292.** Before
the walkthrough, the account's GitHub connection was the Claude GitHub App (the
`/web-setup` prompt said "You're already connected via the GitHub App"), and
sessions acted as the operator: `gh api user` returned `evanharmon1`.

- **The classic-PAT route does not change the identity while an App
  authorization exists.** `gh auth login --with-token` refuses the bot's
  `repo`-only classic token (`error validating token: missing required scope
  'read:org'`), so it was handed to `/web-setup` by starting `claude` with
  `GH_TOKEN=<the bot's token> claude`. `/web-setup` showed both documented
  warnings verbatim — "You're already connected via the GitHub App. Continuing
  replaces your authentication credential for cloud sessions. …" and "Your
  GitHub CLI token doesn't have the workflow scope. Without it, GitHub rejects
  pushes that change GitHub Actions workflow files, and pushes to very large
  repositories can be rejected while GitHub checks for them." — and then printed
  `Connected as evanharmon1-bot`. A new session still reported `gh api user` →
  `evanharmon1` and `admin: true` on both `evanharmon1/harmon-init` and
  `ponderousdev/foreman`, and GitHub showed the token last used "within the last
  4 months", so it was not used that day. The claude.ai connectors page still
  showed GitHub connected.
- **Authorizing the Claude GitHub App as the bot works.** After the procedure
  below, new sessions reported `gh api user` → `evanharmon1-bot`, and the
  permissions on `evanharmon1/harmon-init` and, after attaching it to the
  session, `ponderousdev/foreman` were `push: true, admin: false, maintain:
  false` — exactly the bot's collaborator and member grants.

**Amendment, 2026-10-07, of #1408 decision 3:** the identity comes from
authorizing the Claude GitHub App as the bot, not from a classic PAT handed to
`/web-setup`. The PAT route stays documented above for the one case it still
serves: the App is not connected at all.

**The procedure:**

1. At [claude.ai/customize/connectors](https://claude.ai/customize/connectors),
   disconnect GitHub.
2. In the same browser, sign github.com in as `evanharmon1-bot`.
3. On the connectors page, connect GitHub again. The page reported "Connected to
   GitHub".
4. Start a new session and verify it, for one repository of each owner (attach
   the second to the session first): `gh api user` must return
   `evanharmon1-bot`, and `gh api repos/{owner}/{repo}` must show a
   `permissions` object of `push: true, admin: false, maintain: false`. Do not
   trust `gh auth status` for this: see [the `gh` call
   inventory](#the-gh-call-inventory).

**What it costs.** The first two costs are the platform's own statements on the
connectors page:

- Linking the organizations `sommerlawn`, `harmonops` and `ponderousdev` failed
  ("You need to be an owner of this organization on GitHub to link it"), because
  the bot is not an owner.
- "A few features, like automatic code review, aren't available for those
  repositories": Anthropic's automatic code review is unavailable on the
  `evanharmon1`-owned repositories, which the bot does not own.
- **Workflow files are no longer protected by the token.** Observed 2026-10-07,
  under this route the session pushed a commit that edits
  `.github/workflows/remote-bootstrap.yml`, and GitHub accepted it. The
  2026-09-27 property, "no `workflow` scope, so a cloud session cannot push
  workflow changes", holds only for the PAT route. **Maintainer decision,
  2026-10-07: accept and document.** A workflow change still needs code-owner
  review and the required checks before it reaches `main`; route deliberate
  workflow work to a local or bot-devcontainer lane as before.

**Authorship.** Observed 2026-10-07, on a probe branch since deleted: the VM's
git identity is `user.name = Claude` and `user.email = noreply@anthropic.com`,
which GitHub links to its `claude` user, so commits are authored and committed
as Claude. GitHub's activity log records the **branch creation and the push
actor as `evanharmon1-bot`**. The session opened no PR (see [The `gh` call
inventory](#the-gh-call-inventory)), so PR authorship through a session is not
observed. The comment replies the platform posts on your behalf are posted
under the connected account's username and labelled as coming from Claude Code
(*docs, 2026-09-29*).

**To revert**, reconnect GitHub at the same page while github.com is signed in
as the operator. That is the connection the account had before the walkthrough,
under which sessions acted as the operator.

## What the GitHub proxy does to the loop

Every GitHub operation from an Anthropic-hosted VM goes through a proxy,
whatever the network level (*docs, 2026-09-29*). It is the single biggest
difference from the devcontainer, and the docs and the 2026-09-27 session
disagree in places. Where they do, this is the guide's position:

| Topic | Docs, 2026-09-29 | Observed 2026-09-27 | Position |
| --- | --- | --- | --- |
| GraphQL | The proxy serves "a pinned set of GraphQL operations for pull-request workflows" and 403s everything else with `This GraphQL query is not enabled for this session`; a `GH_TOKEN` you set gets the same 403 | **Every** GraphQL request refused, with `GitHub GraphQL is not available from Claude Code sessions; use the REST API` | Treat every GraphQL-backed `gh` subcommand as failing until a live session shows otherwise. The pinned set may have changed since 2026-09-27, or the operations tried were outside it. Projects v2 is GraphQL-only and documented as unreachable |
| The failure looks like | a 403 naming the REST fallback `gh api repos/{owner}/{repo}/…` | a 403 that can read as an auth problem | A 403 from `gh pr …`, `gh issue …` or `gh label …` is the proxy, not a bad token; do not re-authenticate |
| Pushes | `git push` works only against "the session's current working branch" | The assigned branch, **and** four new `claude/*` branches pushed successfully | Plan on the session's branch. A `claude/`-prefixed branch is observed to work but is not documented; do not depend on it without re-checking |
| Repository scope | API and release-asset requests reach only repositories attached to the session | Release-asset downloads allowed; repository not named | API access is scoped per session: a read of a repository not attached returns `HTTP 403: GitHub access to this repository is not enabled for this session.` (observed 2026-10-06). Attaching it in the session (the agent's `add_repo`, access `push`) fixes that, and the platform then shallow-clones it to `/home/user/<repo>`. Release-asset downloads from unattached repositories succeeded for the setup script under Trusted (observed 2026-10-06; see [Network](#network)) |
| Search | not stated | `gh api search/issues` 403 `sessions are bound to their configured repositories` | Page through `repos/{o}/{r}/issues?state=all` |
| Pagination | not stated | `gh api --paginate` returns page 1, then fails on the next-page link with `Numeric-ID repository paths (repositories/{id}/...) are not supported`. Again 2026-10-06: GitHub's `Link: next` uses numeric-ID paths, which the proxy refuses | Loop `&page=N` explicitly; the REST helpers in `scripts/lib/gh-rest.sh` do, and bound the walk |
| Written text | PR bodies get the session URL on its own line; comment replies are labelled as Claude Code | **Every** comment and body write, including an issue-body edit, gets a `Generated by Claude Code` footer appended | Any exact-match check of a body or comment (a marker line, a tick-criteria round trip) can be broken by it. Compare by containment or prefix, not equality |
| REST routes the proxy adds | not stated | Named in the 403: `GET /repos/{o}/{r}/pulls/{n}/ccr/review_threads`, `POST …/ccr/comments/{id}/resolve` (and `/unresolve`), `PUT\|DELETE …/ccr/auto_merge`, `POST …/ccr/ready_for_review`, `POST …/ccr/convert_to_draft` | These are the REST substitutes for review-thread reads, thread resolution, auto-merge, ready-for-review and convert-to-draft |

Also observed 2026-09-27: `gh api repos/…` (plain REST) and `gh api user` work;
the GitHub MCP tools work and are repository-scoped, and `issue_read` also
returns `closed_by_pull_requests`, which is otherwise the one readiness
condition only GraphQL can read; and GitHub release-asset downloads,
`raw.githubusercontent.com`, npm, PyPI, `proxy.golang.org`, `nodejs.org`,
`archive.ubuntu.com` and `releases.hashicorp.com` were reachable.

### What runs where

A cloud lane completes its **role**, not the PR (#1408, 2026-09-27): a remote
implementer returns its work — a pushed branch — to the orchestrator, and the
orchestrator's normal review and integration loop, run from a machine that has
GraphQL, owns the PR. So the integration-side scripts in the inventory below
(the readiness gate, the Codex cloud-review checker, the lane watcher) are not
expected to run inside the VM at all. They are listed because the acceptance
criterion asks for every call the loop makes, and because a session that is
asked to integrate anyway will hit them.

**Under the agent posture, no `gh` route writes to GitHub** (observed
2026-10-07). The posture's managed settings deny every `gh api` write form
(`-X`, `--method`, `-f`, `-F`, `--field`, `--raw-field`, `--input`), and the
proxy refuses GraphQL, so `gh pr create`, `edit`, `ready` and `comment` fail and
their REST workarounds are denied. A cloud lane therefore ends at a pushed
branch. The PR is opened by the orchestrator, or with the platform's **Create
PR** button. The session's built-in GitHub tools were not tried under the
posture.

### The `gh` call inventory

One row per call the dev-loop skills and scripts make, found by searching the
vendored `claim`, `implement`, `review`, `integrate`, `track-work`, `orchestrate`
and `dev-flow-support` skills (harmon-devkit `v0.47.0`) and their `assets/` for
`gh` subcommands. **Result** is the
evidence tag from [the table at the top](#how-to-read-the-evidence-in-this-guide),
never a guess. **Follow-up** names where a failure is tracked or the workaround
that exists today.

Most vendored scripts abort at their first failing call, so their later calls
are not reached through the proxy until that one works; a few tolerate a failed
read and carry on (`release-claim.sh`'s paginated comments read, for one). The
live observation therefore records, for each script, every call the run
actually reached and its result — a GraphQL refusal, or a paginated REST read
that fails after page 1 — and marks a call unobserved only when an earlier
failure aborted the script before it. Making every helper reach its later calls
is harmon-devkit#1207's work, not a gap in this table. Where a script has more
than one row, each row's **Result** records the calls that row names.

The rows tagged *observed 2026-10-06* were run by hand in one session with the
bootstrap's posture. Every GraphQL-backed `gh` subcommand got the same 403,
quoted here once and referred to below as *the GraphQL 403*:

> `HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the
> REST API (gh api repos/{owner}/{repo}/...). For review threads, auto-merge,
> and draft/ready-for-review use the CCR routes on api.github.com: GET
> /repos/{owner}/{repo}/pulls/{n}/ccr/review_threads, POST
> /repos/{owner}/{repo}/pulls/{n}/ccr/comments/{comment_id}/resolve (or
> /unresolve), PUT or DELETE /repos/{owner}/{repo}/pulls/{n}/ccr/auto_merge,
> POST /repos/{owner}/{repo}/pulls/{n}/ccr/ready_for_review, POST
> /repos/{owner}/{repo}/pulls/{n}/ccr/convert_to_draft.`

| Call | Made by | Result through the proxy | Follow-up / workaround |
| --- | --- | --- | --- |
| `gh pr list`, `gh pr view`, `gh pr checks`, `gh pr ready`, `gh issue view`, `gh issue edit`, `gh issue comment`, `gh label list` | any of the scripts below, or by hand | **fail, 403** — observed 2026-09-27; `gh issue view`, `gh pr list`, `gh pr view`, `gh pr checks` and `gh label list` again 2026-10-06 (the GraphQL 403) | `gh api repos/{o}/{r}/…` over REST; promotion through `POST …/ccr/ready_for_review`. The helper scripts: [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207) |
| `claim-transaction.sh` (`/claim`): `gh issue view/edit/comment`, `gh api user`, `gh api --paginate --slurp` | claim skill (vendored) | **fail** on the GraphQL issue calls — observed 2026-09-27. The script aborts at its first `gh issue view`, so its paginated `comments` and `timeline` reads (page 1 expected to work, later pages to fail) are not reached | harmon-devkit#1207. The 2026-09-27 session used a session-local `gh` shim mapping the subcommands to REST — a stopgap, not a fix |
| `tick-criteria-core.sh`: `gh issue view`, `gh issue edit`, `gh api user` | track-work skill (vendored) | **fail** — observed 2026-09-27 | harmon-devkit#1207. The write also gets the footer (above) |
| `check-closing-keywords.sh` (the vendored copy): `gh issue view`, `gh pr view`; `gh repo view` when no `--repo` or `GH_REPO` is given | track-work skill (vendored) | **fail** — observed 2026-09-27; the `gh repo view` fallback expected to fail, not yet observed (GraphQL-backed) | harmon-devkit#1207. Pass `--repo` so the fallback never runs |
| `gh pr create --draft`, then `gh pr view --json headRefOid,isDraft` to confirm it | implement skill (vendored), the draft-first step `AGENTS.md` requires; the orchestrate skill's lane brief | **not reachable under the posture** — `gh pr create` is GraphQL-backed and fails, and the REST `POST …/pulls` was refused 2026-10-07: `Permission to use Bash with command … gh api -i -X POST repos/evanharmon1/harmon-init/pulls … has been denied.` | The GitHub MCP create-PR tool worked 2026-09-27 (whether it can open a *draft* was not recorded); it was not tried under the posture. harmon-devkit#1207. A cloud lane leaves this to the orchestrator, or to the platform's **Create PR** button ([What runs where](#what-runs-where)) |
| `gh pr edit --body-file` (ticking `## Deferred findings`, and `render-dev-flow.mjs publish`, which then re-reads the body with `gh pr view`) | integrate skill; dev-flow-support package (vendored) | expected to fail, not yet observed — GraphQL-backed; under the posture `gh pr edit` fails, and the REST `PATCH` is denied as a `gh api` write form (observed 2026-10-07 for the REST `POST …/pulls`) | REST `PATCH repos/{o}/{r}/pulls/{n}` with `body` is not reachable from a postured session; the orchestrator edits the body. `publish` also compares the re-read body's fingerprint with what it wrote, which the footer (below) would break — expected, not yet observed. harmon-devkit#1207 |
| `gh repo view <remote-url> --json nameWithOwner` | implement and review skills (vendored), resolving the target repository; the claim skill's entry gate | **fail, 403** (the GraphQL 403) — observed 2026-10-06 | Derive `owner/repo` from `git remote get-url`, or read it from REST `repos/{o}/{r}` (plain REST works — observed 2026-09-27). harmon-devkit#1207 |
| `gh issue list`, `gh issue create`, `gh issue close` | track-work skill (duplicate search, filing and closing issues); integrate skill (filing follow-ups); claim skill (open-issue scan) | `gh issue list`: **fail, 403** (the GraphQL 403) — observed 2026-10-06. `gh issue create` and `gh issue close`: expected to fail, not yet observed — GraphQL-backed, like the `gh issue` calls in the first row | REST `repos/{o}/{r}/issues`: `GET` with `state=all`, paged (see Search, above); `POST` to create; `PATCH` with `state` and `state_reason` to close. harmon-devkit#1207 |
| `gh run list --commit`, `gh run view --log-failed`, `gh run rerun --failed` | integrate skill (vendored), CI remediation | `gh run list`: **works** (REST Actions) — observed 2026-10-06. `gh run view --log-failed` and `gh run rerun --failed`: expected, not yet observed — they use the same REST Actions API | — |
| `trusted-registry.sh`: `gh pr view --json baseRefOid`, `gh api repos/…/contents` | integrate skill (vendored), sourced by `check-codex-cloud-review.sh` and `gh-write-broker.sh` | expected to fail on `gh pr view`, not yet observed — GraphQL-backed; the `contents` read is plain REST | REST `repos/{o}/{r}/pulls/{n}` returns `base.sha`. harmon-devkit#1207 |
| `gh auth git-credential` (the forced credential-helper push in `AGENTS.md` and the integrate skill) | a push on an unprovisioned host | expected, not yet observed; not needed — a plain `git push` to the session's branch works (observed 2026-09-27), because the platform configures git itself | Push with plain `git push` in a cloud session |
| `release-claim.sh`, `check-issue-metadata.sh`: `gh issue edit/comment`, `gh label list`, `gh api --paginate --slurp` | track-work skill (vendored) | expected, not yet observed — the same GraphQL-backed subcommands as the first row | harmon-devkit#1207 |
| `release-claim.sh`: `gh api repos/{o}/{r}/issues/{n}` (the issue, read twice), and `gh api --paginate --slurp` over the issue's `timeline` and `comments` | track-work skill (vendored) | expected to work for the plain issue reads, and for page 1 of the paginated reads, which then fail on the proxy's rejected next-page link; not yet observed. Record which read failed before the script reaches its GraphQL writes | harmon-devkit#1207 (explicit `page=N` pagination) |
| `check-issue-metadata.sh`: `gh api repos/{o}/{r}` (owner type) and, for an organization owner only, `gh api orgs/{owner}/issue-types` | track-work skill (vendored) | expected to work (plain REST), not yet observed; the organization call is skipped for a personal-account owner | — |
| `set-issue-status.sh`: `gh api graphql` (Projects v2) | track-work skill (vendored) | expected to fail, not yet observed — Projects v2 is GraphQL-only and documented as unreachable. A direct `gh api graphql …` probe was not reached 2026-10-06: the session's auto-mode classifier blocked it before it ran | No REST route is known. The skills treat Project status as a non-authoritative view, so the loop does not need it. Tracked in [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207), which either finds a REST route or makes the helper refuse with its exit 2; until then it can only fail behind the proxy |
| `readiness-gate.sh`: `gh pr view`, `gh api graphql --paginate --slurp` (review threads), `gh api repos/…`, `gh api user`, `gh pr ready` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27 | Conditions were checked by hand over REST (`…/ccr/review_threads`, `…/ccr/ready_for_review`). harmon-devkit#1207; orchestrator-side, see [What runs where](#what-runs-where) |
| `check-codex-cloud-review.sh`: `gh pr view`, `gh api --paginate --slurp` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27; the pagination fails past page 1 — observed 2026-09-27 | The current-head cycle was checked by hand over REST. harmon-devkit#1207 |
| `gh-ro.sh`, `gh-write-broker.sh`: `gh api` with a pinned method | integrate skill (vendored) | plain REST reads and writes work — observed 2026-09-27 for `gh api repos/…`; these two wrappers themselves not yet observed | GET refuses `graphql` by design |
| `round-push.sh`: `gh api --hostname …` | review skill (vendored) | expected, not yet observed | — |
| `lane-watch.sh`: `gh pr list`, `gh api --paginate --slurp`, `gh pr ready --undo` | orchestrate skill (vendored) | expected to fail, not yet observed — GraphQL-backed subcommands | Orchestrator-side; not run in a cloud lane |
| `scripts/status.sh`, `scripts/check-closing-keywords.sh`, `scripts/guard-closing-keywords.sh`, `scripts/audit-session-artifacts.sh` | harmon-init's own | **REST since #1430** for the calls that go through the bounded `gh_rest_*` helpers, with a page ceiling. `status.sh` also makes the calls in the next row, which do not | `task status` itself has not been run in a cloud session; the next row records its `gh` calls individually. A script that probes `gh auth status` reports `gh` as broken there |
| `status.sh` outside the `gh_rest_*` helpers: `gh auth status`, `gh run list`; raw `gh api` for `repos/{o}/{r}`, `…/rulesets`, `…/vulnerability-alerts`, `…/private-vulnerability-reporting`, the app installations (`orgs/{o}/installations` or `user/installations`) and the GHCR package; `gh secret list`, `gh variable list`, `gh variable get`; `gh auth token` | harmon-init's own (`task status`) | `gh auth status`: **exit 1** with `X Failed to log in to github.com using token (GH_TOKEN)` while `gh api` works — a **false negative** (`GH_TOKEN` is the placeholder `proxy-injected`; `GITHUB_TOKEN` is also set) — observed 2026-10-06. `gh run list`: works — observed 2026-10-06. `gh api repos/{o}/{r}`: works — observed 2026-10-06; the other raw `gh api` reads: expected to work (plain REST), not yet observed. `gh variable list`: **fail, 403** `Access to this GitHub Actions path is not permitted through this proxy.` (the Actions variables path is refused although runs are allowed) — observed 2026-10-06. `gh secret list`: not reached 2026-10-06, the auto-mode classifier blocked it; `gh variable get`: expected, not yet observed. `gh auth token`: local, no network call | Probe `gh` with `gh api user`, not `gh auth status`. `status.sh` does not abort on any of these — each call has a fallback. The latest-release read moved off the GraphQL-backed `gh release list` onto `gh_rest_api` (`repos/{o}/{r}/releases?per_page=1`, the row above) in #1437, and a failed read now renders the **Release published** line as unavailable instead of a false *no* with the `task release:init` remedy |
| `task foreman:plan`, `foreman:dispatch`, `foreman:watch` | the pinned Foreman CLI, run through `uvx` from a git URL | expected, not yet observed — the calls Foreman makes are in its own repository, not enumerated here. Dispatch refuses on the local runner for public repos by design | Orchestrator-side; not run in a cloud lane |
| `gh api repos/{o}/{r}/…` (REST), `gh api user`, an explicit `…?per_page=2&page=2` read | anything | **works** — observed 2026-09-27 and 2026-10-06. For a repository not attached to the session: **fail, 403** `GitHub access to this repository is not enabled for this session.` — observed 2026-10-06 | Attach the repository in the session (the agent's `add_repo`, access `push`) |
| `gh api search/issues` | ad hoc | **fail, 403** — observed 2026-09-27; not reached 2026-10-06, the auto-mode classifier blocked it before it ran | `repos/{o}/{r}/issues?state=all`, paged |
| `gh api --paginate` | ad hoc | **page 1 only**, then a hard error — observed 2026-09-27 and 2026-10-06: `HTTP 403: Numeric-ID repository paths (repositories/{id}/...) are not supported through this proxy. Use repos/{owner}/{repo}/... endpoints instead.` GitHub's `Link: next` uses numeric-ID paths, which the proxy refuses | Explicit `&page=N` loop |
| GitHub MCP tools (issue and PR read, create PR, subscribe to PR activity) | the session's built-in tools | **work**, repository-scoped — observed 2026-09-27. Not tried under the agent posture | `issue_read` returns `closed_by_pull_requests` |
| Any comment or body write | any | **succeeds with a footer appended** — observed 2026-09-27 | Compare by containment, not equality |

**Observed (criterion 7), 2026-10-06 and 2026-10-07:** the read half is run
through the proxy in a session with the bootstrap's posture, and the rows above
carry the result. Every failing row has a follow-up or a workaround in its last
column. The write half is resolved as *not reachable under the posture* ([What
runs where](#what-runs-where)). The rows still tagged *expected* were not run;
they stay unobserved rather than assumed.

## Bridges between the terminal and the cloud

These need the Claude Code CLI signed in with a **claude.ai account** — not an
API key, and not a Bedrock or Vertex configuration — and the organization's
`allow_remote_sessions` policy on (*docs, 2026-09-29*).

- **Terminal → cloud.** `claude --cloud "<task>"` creates a new cloud session for
  the current repository. It clones the GitHub remote at your **current branch**,
  never your local checkout, so **push first**. One repository at a time, in the
  environment chosen by `/remote-env`. The task then runs while you keep working.
  Each invocation is its own session, so several run in parallel, and they share
  your plan's rate limits — there is no separate compute charge.
- **Following up.** `claude -p "<message>" --cloud <session-id>` queues a message
  into a running session and exits without waiting; `--output-format json`
  returns `{ok, session_id, url}`. That is the scriptable steering path.
- **Cloud → terminal.** `claude --teleport [<session-id>]`, `/teleport` inside a
  session, or `/tasks` then `t`, pulls a cloud session's branch and transcript
  into a local checkout of the same repository (not a fork), with a clean
  working tree, authenticated as the same account. The local copy is its own
  session: work you do there does not appear in the cloud session. A local Herdr
  pane can run this command like any other; see
  [herdr.md](herdr.md).
- **Why Herdr cannot attach to the cloud VM.** Herdr attaches to a terminal
  session, and a cloud session does not expose one: "you don't get a shell into
  the session VM; Claude runs every command for you" (*docs, 2026-09-29*). Steering
  goes through the web UI or `claude -p … --cloud <id>`, and the result comes back
  as a pushed branch. Teleporting is the only way to *see* the work in a local pane,
  and it copies the session rather than attaching to it.
- **Not to be confused with** `--remote-control`, which steers a *local* session
  from claude.ai; and `--remote`, the deprecated spelling of `--cloud`.

**Observed (criterion 4), 2026-10-06 and 2026-10-07, local CLI 2.1.284:**
`claude --cloud "<task>"` ran to a pushed branch with no permission prompt and
no human step.

- **It needs a TTY.** With stdout piped it refuses: `Error: --cloud requires an
  interactive terminal. Non-interactive invocations (piped stdout, --init-only,
  --sdk-url) run locally and would silently ignore --cloud.` Run interactively,
  it returns at once, printing `Created cloud session: <title>`, a `View:` URL
  and `Resume with: claude --teleport <session-id>`. This version prints no live
  setup checklist.
- **The account is whichever one `claude auth status` reports.** The session is
  created in that account's environment and GitHub connection; a CLI signed in
  to a second account sent the task there, and the browser then reported the
  session "couldn't be found". Check `claude auth status` before using the
  bridge.
- **Following up works.** `claude -p "<message>" --cloud <session-id>` queued a
  follow-up (`Sent to cloud session.`).
- **The probe task ran unattended.** The session created at 04:34:53Z on
  2026-10-07 did environment reads, made a new branch, two commits and two
  pushes (`78d2be2`, `81acea1`, the second touching a workflow file — see
  [Whose identity GitHub sees](#whose-identity-github-sees)), with no
  permission prompt and no human step. It stopped where the posture denied the
  REST PR create ([What runs where](#what-runs-where)). Criterion 4 is met as
  "returns a pushed branch with no human step".
- **Branch names.** The platform assigns each session its own branch name
  (`claude/platform-probe-2026-10-07-<suffix>`), but pushing another branch name
  was allowed.
- **Not recorded:** the permission mode `--cloud` selected. The docs say the
  mode is picked from the session's mode dropdown at creation.
- **Git hooks were not installed** in that session, because no `task
  setup:remote` was run there — consistent with [When per-checkout preparation
  runs](#when-per-checkout-preparation-runs).

## The agent posture

The setup script's bootstrap installs the agent posture
([#1408](https://github.com/evanharmon1/harmon-init/issues/1408)) on the VM,
from the same release tag as the toolchain
([architecture](../architecture/remote-environments.md#the-agent-posture)).
What that does and does not establish here:

| Axis | In Claude Code on the web | Status |
| --- | --- | --- |
| Permissions | The bootstrap writes the agent Claude Code settings to `/etc/claude-code/managed-settings.json`, creating the directory, which did not exist on the VM. A session **honours** a managed file written by the setup script (below). The platform also supplies its own settings overlay (`CCR_SETTINGS_JSON_OVERLAY`), and a server-side auto-mode classifier approves or denies each action on top of whatever loads — a second refusal layer. If a later platform change ignores the file, the fallback is the repository's `.claude/settings.json`, which a session reads only in a single-repository session, or the platform overlay. Should the platform ever supply its own `/etc/claude-code/managed-settings.json`, the bootstrap leaves it in place and reports the posture as not applied for it, unless the environment's setup script sets `HARMON_AGENT_POSTURE_REPLACE=1` | VM: observed 2026-09-27. Delivery: observed 2026-10-06, Claude Code 2.1.292 (#1404 criterion 2, below) |
| Refused harnesses | Not refused. The bootstrap never changes a harness executable's mode on a platform VM; the platform starts Claude Code and nothing else, and its classifier sits above the session | expected, not yet observed |
| Hooks | Not delivered. The settings name the agent image's hook scripts under `/etc/claude-code/hooks/`, which the bootstrap does not install; it warns naming each one (observed 2026-10-06: it warned that the eight hook commands it names are not installed). A missing hook command is expected to surface as a non-blocking hook error each time the hook fires | warning observed 2026-10-06; the hook error expected, not yet observed |

**Observed (#1404 criterion 2), 2026-10-06, Claude Code 2.1.292**, in a session
in the environment whose setup script ran the bootstrap:

- The bootstrap installed and verified `/etc/claude-code/managed-settings.json`
  and `/etc/codex/managed_config.toml` on the VM (`==> agent-autonomy: verify
  passed`).
- **The managed deny rules are honoured.** `sudo …` was refused ("the session's
  permission settings blocked"). `gh pr merge 1` was refused **without a
  prompt**; the session attributed it to the repository's permission settings,
  and that repository's `.claude/settings.json` has an *ask* rule for `gh pr
  merge` while the managed file has a *deny* rule, so a refusal with no prompt is
  consistent with the deny. The `gh api` write forms were refused too ([What runs
  where](#what-runs-where)).
- **`/permissions` cannot be used on the web.** Typing it opens the session's
  permission-mode menu (Auto, Accept edits, Plan) instead of listing rules, so
  which source refused an action is established from behaviour, not from a
  listing.
- **The auto-mode classifier is a second, separate refusal layer, and it is not
  consistent across sessions.** It refused to print `$GH_TOKEN` and the proxy
  variables in one session, while an earlier session printed
  `GH_TOKEN=proxy-injected`. It refused reading the managed settings file
  together with environment variable names ("an attempt to get around auto
  mode's restrictions"). It refused `gh api search/issues`, `gh secret list` and
  `gh api graphql` before they ran.

## Memory

None of your local memory reaches a cloud session, and none of what the session
writes survives it.

- **Local auto-memory is not loaded.** There is no `~/.claude/CLAUDE.md` in the
  session (*docs, 2026-09-29*), and no auto-memory (observed 2026-09-27).
- **Anything the session writes to memory is lost with the VM.** A session that
  goes idle is reclaimed and reopened on a fresh VM with its conversation
  history, not its files (*docs, 2026-09-29*).
- **Durable lessons therefore belong in the repository**: `AGENTS.md`, or a doc it
  links. The repository's own `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`,
  `.claude/agents/` and `.claude/commands/` are part of the clone and do load
  (*docs, 2026-09-29*), which is why they are the right home. A rule that
  matters to the next session goes in a commit, not in memory.

## Account preferences, account skills, and what does not carry over

The session's `~/.claude` exists but the platform fills it (`plugins/`,
`launcher-settings.json`, `session-env/`), so what reaches a cloud session is:

| Source | In the session? | Note |
| --- | --- | --- |
| Repo `CLAUDE.md`, `.claude/rules/`, skills, agents, commands | yes | part of the clone |
| Repo `.claude/settings.json` (hooks, permissions) and `.mcp.json` | **only in a single-repository session** | a multi-repository session starts above the clones and reads neither (*docs, 2026-09-29*) |
| claude.ai **account skills** | yes | synced in automatically — `CLAUDE_CODE_SYNC_SKILLS` was observed 2026-09-27 |
| claude.ai **account preferences** | yes | injected into the session's instructions (observed 2026-09-27) |
| `~/.claude/CLAUDE.md`, user skills, agents, commands, user-scope MCP servers, user-scope plugins | **no** | they live on your machine (*docs, 2026-09-29*) |
| Plugins a repo enables in `.claude/settings.json` | **no** | a cloud session does not install `enabledPlugins` |
| Organization server-managed settings | yes | fetched at session start; MDM-deployed managed files do not apply |

Account preferences are the only channel for a rule that has to hold in **every**
repo a session might open, including one with no `AGENTS.md` of this shape. Put
there: the small set of cross-project rules that are safety or communication
rules rather than repository facts — never write to a password manager or
credential store unless that exact write was requested, and even then restate
what will be written and get confirmation before running it; never terminate a
process without approval; never merge or cut a release, because both are the
maintainer's decisions and an agent acts on one only with explicit, per-merge
(or per-release) approval; and the reply-style
preferences. Keep them short: they are injected into every session. Everything
that is true of a repository — commands, gates, the dev loop, conventions —
belongs in that repository's `AGENTS.md`, where it is versioned and reviewable.

Copying the rules into account preferences is a step only the operator can do;
nothing in this repository writes to the account.

## Long-running gates

A full `task verify` takes about **10–12 minutes on the 4-core VM** (observed
2026-09-27), which is over the Bash tool's ceiling: it waits two minutes by
default and can be asked for at most ten (*docs, 2026-09-29*). The platform does
not kill a command at that limit; Claude Code moves it to the background instead
(*docs, 2026-09-29*), so the risk is a session that treats "moved to the
background" as "finished". The supported ways to run it:

1. **Detached, then poll the log** — the form this repository's lane briefs use:

   ```bash
   log="$(mktemp -d)/verify.log"
   nohup bash -c 'task verify; echo GATE-EXIT=$?' > "$log" 2>&1 & disown
   echo "$log"
   ```

   then read `$log` (the path the last line printed) until it contains
   `GATE-EXIT=<code>`. The log is per run, so an older detached run's exit line
   cannot satisfy this poll. That line, not the absence of output, is the
   result. The single quotes are load-bearing:
   inside double quotes the *calling* shell expands `$?` before `bash -c` starts,
   so the line would report the status of whatever ran before — and a failed
   verify could print `GATE-EXIT=0`.
2. **Its component tasks**, each under the limit: every entry
   `task --summary verify` lists, in order — `check`, the `audit:*` guard, and
   each `test:*` target. Running a subset is not a verify.
3. **Raise the ceiling** with `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`
   in the environment ([Environment variables](#environment-variables)). This
   only moves the limit to ten minutes; a gate longer than that still needs the
   first form. The variables were observed present on 2026-10-06, but whether
   the ten-minute wait is honoured was not exercised: the long gate ran
   detached, as in the first form, and `task verify` completed with
   `GATE-EXIT=0`.

**`task security` is owed before the draft PR, in the cloud as anywhere else**
(`AGENTS.md`), and it is never skipped. Its Semgrep step contacts `semgrep.dev`,
which was denied on 2026-09-27 under a network level presumed, but not
recorded, to be Trusted (see [Network](#network)). Meet the gate one of two ways:

- **In the session:** add `semgrep.dev` under **Custom** network access, with the
  default package-manager list kept, so the full `task security` runs there.
- **Outside it**, where the environment cannot be changed: the session stops at
  a pushed branch, and the draft PR is opened only after `task security` has
  passed on a machine that can run it. That is already the shape of a cloud lane
  ([What runs where](#what-runs-where)): the orchestrator runs the gate before it
  opens the PR.

`task security:secrets` on its own is the per-push secret scan, not a substitute
for the pre-PR gate.

## Other behaviour worth knowing

- **The platform's Stop hook** (`stop-hook-git-check.sh`) blocks when any linked
  worktree has uncommitted changes, including a subagent's in-progress edits
  (observed 2026-09-27). Commit before finishing.
- **The session runs as root.** Git configuration is injected through
  `GIT_CONFIG_COUNT` (observed 2026-09-27), so do not assume a `~/.gitconfig`.
- **`/usr/bin/yq` is the Python yq.** The bootstrap puts the pinned mikefarah yq
  first on `PATH`; see
  [architecture/remote-environments.md](../architecture/remote-environments.md#what-the-environment-actually-is).
- **One repository per session** if the session should read the repo's
  `.claude/settings.json`, `.mcp.json` and hooks.
- **Resources:** about 4 vCPUs, 16 GB RAM and 30 GB disk (*docs, 2026-09-29*).
- **Session link:** commits carry a `Claude-Session:` trailer and PR bodies carry
  the session URL; `CLAUDE_CODE_REMOTE_SESSION_ID` holds the ID.
- **npm-installed tools resolve from the platform's prefix.** Observed
  2026-10-06: `markdownlint-cli2` and `codex`, which the bootstrap installs with
  npm, resolve from `/opt/node22/bin`, the platform's npm prefix. It precedes
  the bootstrap's prefix on `PATH`, while the bootstrap pinned Node 24.21.0.
  npm prefix handling is tracked by #1429.
- **The setup-script output panel truncates at varying points.** Observed
  2026-10-06: two failing runs appeared to stop at `lychee` and `actionlint`
  while the real failure was later. Debug a failing setup run from a
  timestamped log written with `tee`, not from the panel.

## When per-checkout preparation runs

The setup script provisions the **VM**: the platform snapshots the filesystem
after it, and a session starts from that snapshot without running the script again
until the script or the network hosts change, or the cache expires after about
seven days (*docs, 2026-09-29*). The repository is a **fresh clone per session**
(*docs, 2026-09-29*), and the 2026-09-27 session, which had no setup script,
already had it at `/home/user/harmon-devkit` when it started.

The docs do not say whether that clone exists when the setup script runs.
**Observed (criterion 11), 2026-10-06: the repository is cloned before the setup
script runs** — a probe line in the setup script wrote
`/home/user/harmon-init/.git`. A script served from the cache still cannot
depend on it, because the snapshot was taken before this session's clone, and
the cache applies to the machine only. So the rule that holds:

- **Setup script**: machine-level, repository-independent — the bootstrap, and
  nothing that reads a checkout.
- **Per-checkout preparation** — installing the git hooks, and anything that reads
  the clone — runs when the session starts, not in the setup script. The
  platform's mechanism for that is a `SessionStart` hook in the repository's
  `.claude/settings.json`, guarded on `CLAUDE_CODE_REMOTE=true` so it does nothing
  locally, and it runs only in a single-repository session (*docs, 2026-09-29*).
  This repository has deliberately **not** adopted that hook (its
  `.claude/settings.json` is unchanged), so nothing triggers the preparation by
  itself: the agent runs the task below once.

`task setup:remote` (`scripts/setup-remote.sh`,
[#1405](https://github.com/evanharmon1/harmon-init/issues/1405)) is that
preparation as one task, which the agent runs once on a fresh checkout —
`AGENTS.md` tells it to, because the repository ships no hook that would. It runs `lefthook install` (when
lefthook is on `PATH`), frozen `pnpm` / `uv` installs from the lockfiles that
exist, and the same sibling clones the devcontainer makes
(`.devcontainer/related-repos.txt`), into the checkout's **parent** directory:
the layout observed on 2026-09-27 (`/home/user/<repo>`), so the `../harmon-devkit`
entries in `additionalDirectories` and `sandbox.filesystem.allowRead` resolve. It
is idempotent, never prompts (git terminal prompts are disabled, ssh runs with
`BatchMode=yes` unless the caller already set `GIT_SSH_COMMAND`, in which case the
caller's value governs, and pnpm runs with `CI=true`), skips a missing tool with a note, warns and continues past a
repository it cannot clone, and exits non-zero only when a step that could run
failed. It prints where it cloned, because a platform that does not clone one
level below a writable directory would otherwise show only as a missing sibling.

Siblings are **reference context**: a session may push only to its own repository
and branch (the *Pushes* row above), so a change to a sibling cannot be pushed
from here. The pre-push hook that `lefthook install` sets up is not a substitute
for `task verify`, so run that yourself. Public siblings clone anonymously through the
session's git proxy; a private sibling, or one that needs GitHub API calls, must
be attached to the session (*observed 2026-09-27*,
[evidence on #1405](https://github.com/evanharmon1/harmon-init/issues/1405#issuecomment-5860625784)).
Attaching a repository in the session (the agent's `add_repo`, access `push`) is
a second path to a sibling: the platform itself **shallow-clones** it to
`/home/user/<repo>`, beside the full anonymous clones `task setup:remote` makes
(observed 2026-10-06).
The task's behaviour is tested in a fixture repository
(`scripts/test-setup-remote.sh`).

**Observed (#1405 criterion 6, siblings readable), 2026-10-06:** `task
setup:remote` on the VM exited 0. `lefthook install` synced `commit-msg`,
`pre-push` and `pre-commit`; the three related repositories cloned anonymously
into `/home/user` (`3 cloned, 0 skipped, 0 failed`); the dependency steps were
skipped because the repository has no lockfiles. This was observed on
`evanharmon1/harmon-init`; the criterion names `ponderousdev/omator`.

## Pending observations

The live walkthrough of 2026-10-06 and 2026-10-07 (Claude Code 2.1.292 on the
VM) settled criteria 1 (in part), 3, 4, 7, 8 and 11 of
[#1407](https://github.com/evanharmon1/harmon-init/issues/1407), criterion 2 of
[#1404](https://github.com/evanharmon1/harmon-init/issues/1404) (the agent
posture) and the unnumbered row. **Three items are still open**, marked *Open*
in the table: the unchanged recipe at the first release after `v5.2.0`, the
setup-script cache, and the session's built-in GitHub tools under the agent
posture. A settled row stays as the record of what was seen and where it landed.
Each result goes in the section named, with the date and the Claude Code
version.

| # | What has to be seen | Where the result lands |
| --- | --- | --- |
| 1 | *Open:* the unchanged recipe, with `sudo bash` and no interim `env`, at the first release after `v5.2.0`. Seen 2026-10-06: `v4.48.0` is the first release carrying the bootstrap; at `v5.2.0` the setup script fails at `semgrep`, and with the interim `sudo env …` line it completes in 86 s (48 s on a second VM) | [Setup script](#setup-script) |
| — | *Open:* whether a session starts from the cached snapshot. Not observed in two consecutive sessions (2026-10-06, 2026-10-07); whether a GitHub-connection change invalidates it, or it is simply not reused, is not established | [Setup script](#setup-script) |
| — | *Open:* the session's built-in GitHub tools under the agent posture. Not tried, so whether they can open a PR where `gh` cannot is unknown | [The `gh` call inventory](#the-gh-call-inventory) |
| 3 | Seen 2026-10-07: authorizing the Claude GitHub App as the bot gives `gh api user` → `evanharmon1-bot` and push-only permissions; the classic-PAT route does not change the identity; the push actor is the bot, the commit author Claude | [Whose identity GitHub sees](#whose-identity-github-sees) |
| 4 | Seen 2026-10-07: `claude --cloud "<task>"` needs a TTY, ran prompt-free and returned a pushed branch with no human step | [Bridges between the terminal and the cloud](#bridges-between-the-terminal-and-the-cloud) |
| 7 | Seen 2026-10-06/07: the read half is run and tagged per row; the write half is not reachable under the posture | [The `gh` call inventory](#the-gh-call-inventory) |
| 8 | Seen 2026-10-06: the bootstrap and `task verify` under **Trusted** completed with no network denial; no domain added | [Network](#network) |
| 11 | Seen 2026-10-06: the repository is cloned before the setup script runs | [When per-checkout preparation runs](#when-per-checkout-preparation-runs) |
| #1404-2 | Seen 2026-10-06: the managed deny rules are honoured and `gh pr merge` is refused without a prompt; `/permissions` cannot list them on the web | [The agent posture](#the-agent-posture) |
| — | Seen 2026-10-06: release-asset downloads from repositories not attached to the session succeed under **Trusted** | [Network](#network) |

## Reusing this structure

The [Codex cloud](codex-cloud.md) and [Fly.io Sprites](sprites.md) guides are
this guide's siblings: each opens by saying how to read its evidence and closes
with a pending-observations register. A new adapter guide should cover: **how to
read the evidence**, **the environment** (name, setup script at a pinned tag,
network level and each added domain's reason, variables), **identity and
secrets**, **what the platform's GitHub path does to `gh`** with a call
inventory, **bridges** to and from a local terminal, **the agent posture**,
**memory**, **long gates**, **when per-checkout preparation runs**, and a
**pending observations** register that ties every unobserved fact to the
criterion that will prove it.
The contract and the shared network tables stay in
[architecture/remote-environments.md](../architecture/remote-environments.md).
