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
| **REST since #1430** | A harmon-init script moved off GraphQL-backed `gh` subcommands onto the bounded REST helpers in `scripts/lib/gh-rest.sh`. Tested hermetically; not yet run in a cloud session |
| **expected, not yet observed** | Derived from the docs or from how a script is written. **Not** an observation |
| **pending** | A `[HUMAN]` acceptance criterion of #1407 that needs a live session run by the maintainer. Each has a marked place below and a row in [Pending observations](#pending-observations) |

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
- **`vX.Y.Z` must be the first release that carries the bootstrap.** The bootstrap
  landed in #1426; the latest tag when this guide was written is `v4.47.1`,
  which predates it, and the release PR
  ([#1398](https://github.com/evanharmon1/harmon-init/pull/1398), proposing
  `4.48.0`) is not merged. A proposal is not a tag: **replace `vX.Y.Z` with the
  tag the release publishes, and only then use the environment.** Until that
  happens this section is not runnable as written, and #1407's first acceptance
  criterion stays open for exactly that reason.
- **Do not append `|| true`.** The platform fails the session start when the
  script exits non-zero (*docs, 2026-09-29*). Here that is the wanted outcome: a
  session that starts without the pinned toolchain would run the dev loop
  against the platform's stock tools and pass or fail for the wrong reasons — the
  Python `yq` on the VM's `PATH` is the documented example.
- **Keep the download its own command.** Piping `curl` into a shell exits 0 when
  the download fails. `scripts/test-bootstrap-remote.sh` checks that shape in
  every copy of the recipe, and holds this one equal to the architecture
  document's line for line; the leading `#!/bin/bash` is the only difference it
  allows.
- **The default tiers only** (`core,agents`). The browsers tier is larger than
  everything else together and would put the five-minute cache budget at risk.
- **No `--tiers` flag, no other install lines.** Anything the loop needs belongs
  in the shared scripts, so the image and every other remote adapter get it too.

**Pending observation (criterion 11, and the caching claim):** the bootstrap has
been proven only in CI on a stock `ubuntu:24.04` container on a GitHub-hosted
runner. Whether it finishes inside the platform's cache budget **on the real VM**
has not been measured. Record it under
[Pending observations](#pending-observations).

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
| `api.openai.com`, `auth.openai.com`, `chatgpt.com` | the Codex CLI (#1406) | No | Ephemeral clouds never hold a Codex login (#1408 decision 4): the orchestrator reviews the lane's pushed branch from its own pane |
| `deb.nodesource.com`, `astral.sh`, `keybase.io`, `ppa.launchpadcontent.net`, `cli.github.com`, `dl.google.com` | installer hosts (#1403) | No | The bootstrap no longer contacts them; the denied table in the architecture document is guarded so they cannot return |
| `cafe.github.com` | `gh` telemetry | No | Harmless |
| `cdn.playwright.dev` | Playwright Chromium | No | Browsers tier only, off by default; not on the Trusted list |

The session that recorded these denials did not record which network level it
ran under; it is presumed to be the default, Trusted.

**Pending observation (criterion 8):** run the bootstrap and then `task verify`
under **Trusted** in a fresh environment, and write down every denial. Each
domain that must be added goes in the table above, with the denial that
justifies it. Two things the docs say the observation must check, because they
predict failures the 2026-09-27 probe did not show:

- *Release-asset scope.* The GitHub proxy limits "GitHub API and release-asset
  requests" to repositories attached to the session, and says a setup script
  downloading release assets from an unattached repository gets a 403 (*docs,
  2026-09-29*). The bootstrap downloads release assets from other repositories
  (go-task, gh, gitleaks and the rest). The 2026-09-27 probe recorded
  release-asset downloads as *allowed* without naming the repository. If the
  bootstrap 403s on these, the shared-script contract needs a decision, not a
  domain entry.
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
| `LANG` | `C.UTF-8` | The VM's locale is POSIX (observed 2026-09-27). The bootstrap fixes `/etc/environment` and login shells, but a process Claude Code launches may read neither, and a non-UTF-8 locale silently changes what Unicode checks accept | expected, not yet observed |
| `BASH_DEFAULT_TIMEOUT_MS` | `600000` | The Bash tool waits two minutes by default; the platform documents these two variables for raising it | expected, not yet observed |
| `BASH_MAX_TIMEOUT_MS` | `600000` | The documented ceiling is ten minutes; whether a larger value is honoured has not been tried, so this guide does not ask for one | expected, not yet observed |

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

Decided on 2026-09-27 (#1408): cloud sessions act as the bot account,
`evanharmon1-bot`, through **one classic personal access token** with the `repo`
scope and **no** `workflow` scope, handed to the platform by running `/web-setup`
with `gh` authenticated as the bot. It is one token because `/web-setup` holds a
single token across both owners (evanharmon1 and ponderousdev); what the bot may
touch is bounded by its per-repo collaborator grants, as in
[bot-account.md](bot-account.md). The operator's own token is the fallback if the
platform refuses a token whose GitHub user differs from the claude.ai account.

**Until that is done, the identity is whichever `gh` token `/web-setup` last
received (the operator's own, by default), or the Claude GitHub App if that was
the connection.** The comment replies the platform posts on your behalf are
posted under the connected account's username and labelled as coming from Claude
Code (*docs, 2026-09-29*).

**Pending observation (criterion 3):** re-run `/web-setup` as the bot, then start
a session and record, for one evanharmon1 repo and one ponderousdev repo: the
author of the session's commit, of the push, and of the PR it opens. If the
platform refuses the token, write that here and keep the operator's token.

Observed:  *pending*

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
| Repository scope | API and release-asset requests reach only repositories attached to the session | Release-asset downloads allowed; repository not named | Open question — see [Network](#network). Repos attached mid-session land at `/home/user/<repo>` |
| Search | not stated | `gh api search/issues` 403 `sessions are bound to their configured repositories` | Page through `repos/{o}/{r}/issues?state=all` |
| Pagination | not stated | `gh api --paginate` returns page 1, then fails on the next-page link with `Numeric-ID repository paths (repositories/{id}/...) are not supported` | Loop `&page=N` explicitly; the REST helpers in `scripts/lib/gh-rest.sh` do, and bound the walk |
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

### The `gh` call inventory

One row per call the dev-loop skills and scripts make, found by searching the
vendored `claim`, `implement`, `review`, `integrate`, `track-work`, `orchestrate`
and `dev-flow-support` skills (harmon-devkit `v0.47.0`) and their `assets/` for
`gh` subcommands. **Result** is the
evidence tag from [the table at the top](#how-to-read-the-evidence-in-this-guide),
never a guess. **Follow-up** names where a failure is tracked or the workaround
that exists today.

| Call | Made by | Result through the proxy | Follow-up / workaround |
| --- | --- | --- | --- |
| `gh pr list`, `gh pr view`, `gh pr checks`, `gh pr ready`, `gh issue view`, `gh issue edit`, `gh issue comment`, `gh label list` | any of the scripts below, or by hand | **fail, 403** — observed 2026-09-27 | `gh api repos/{o}/{r}/…` over REST; promotion through `POST …/ccr/ready_for_review`. The helper scripts: [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207) |
| `claim-transaction.sh` (`/claim`): `gh issue view/edit/comment`, `gh api user`, `gh api --paginate --slurp` | claim skill (vendored) | **fail** on the GraphQL issue calls — observed 2026-09-27 | harmon-devkit#1207. The 2026-09-27 session used a session-local `gh` shim mapping the subcommands to REST — a stopgap, not a fix |
| `tick-criteria-core.sh`: `gh issue view`, `gh issue edit`, `gh api user` | track-work skill (vendored) | **fail** — observed 2026-09-27 | harmon-devkit#1207. The write also gets the footer (above) |
| `check-closing-keywords.sh` (the vendored copy): `gh issue view`, `gh pr view`; `gh repo view` when no `--repo` or `GH_REPO` is given | track-work skill (vendored) | **fail** — observed 2026-09-27; the `gh repo view` fallback expected to fail, not yet observed (GraphQL-backed) | harmon-devkit#1207. Pass `--repo` so the fallback never runs |
| `gh pr create --draft`, then `gh pr view --json headRefOid,isDraft` to confirm it | implement skill (vendored), the draft-first step `AGENTS.md` requires; the orchestrate skill's lane brief | expected to fail, not yet observed — `gh pr create` is GraphQL-backed | The GitHub MCP create-PR tool, observed to work 2026-09-27 (whether it can open a *draft* was not recorded); GitHub's REST `POST repos/{o}/{r}/pulls` with `draft: true`, and a readback of `head.sha` and `draft` from `repos/{o}/{r}/pulls/{n}`, not yet tried through the proxy. harmon-devkit#1207. A cloud lane leaves this to the orchestrator ([What runs where](#what-runs-where)) |
| `gh pr edit --body-file` (ticking `## Deferred findings`, and `render-dev-flow.mjs publish`, which then re-reads the body with `gh pr view`) | integrate skill; dev-flow-support package (vendored) | expected to fail, not yet observed — GraphQL-backed | REST `PATCH repos/{o}/{r}/pulls/{n}` with `body`, not yet tried through the proxy. `publish` also compares the re-read body's fingerprint with what it wrote, which the footer (below) would break — expected, not yet observed. harmon-devkit#1207 |
| `gh repo view <remote-url> --json nameWithOwner` | implement and review skills (vendored), resolving the target repository; the claim skill's entry gate | expected to fail, not yet observed — GraphQL-backed | Derive `owner/repo` from `git remote get-url`, or read it from REST `repos/{o}/{r}` (plain REST works — observed 2026-09-27). harmon-devkit#1207 |
| `gh issue list`, `gh issue create`, `gh issue close` | track-work skill (duplicate search, filing and closing issues); integrate skill (filing follow-ups); claim skill (open-issue scan) | expected to fail, not yet observed — GraphQL-backed, like the `gh issue` calls in the first row | REST `repos/{o}/{r}/issues`: `GET` with `state=all`, paged (see Search, above); `POST` to create; `PATCH` with `state` and `state_reason` to close. harmon-devkit#1207 |
| `gh run list --commit`, `gh run view --log-failed`, `gh run rerun --failed` | integrate skill (vendored), CI remediation | expected, not yet observed — `gh run` uses the REST Actions API, not GraphQL | Run `gh run list` in the first live session and record it |
| `trusted-registry.sh`: `gh pr view --json baseRefOid`, `gh api repos/…/contents` | integrate skill (vendored), sourced by `check-codex-cloud-review.sh` and `gh-write-broker.sh` | expected to fail on `gh pr view`, not yet observed — GraphQL-backed; the `contents` read is plain REST | REST `repos/{o}/{r}/pulls/{n}` returns `base.sha`. harmon-devkit#1207 |
| `gh auth git-credential` (the forced credential-helper push in `AGENTS.md` and the integrate skill) | a push on an unprovisioned host | expected, not yet observed; not needed — a plain `git push` to the session's branch works (observed 2026-09-27), because the platform configures git itself | Push with plain `git push` in a cloud session |
| `release-claim.sh`, `check-issue-metadata.sh`: `gh issue edit/comment`, `gh label list`, `gh api --paginate --slurp` | track-work skill (vendored) | expected, not yet observed — the same GraphQL-backed subcommands as the first row | harmon-devkit#1207 |
| `set-issue-status.sh`: `gh api graphql` (Projects v2) | track-work skill (vendored) | expected to fail, not yet observed — Projects v2 is GraphQL-only and documented as unreachable | No REST route is known. The skills treat Project status as a non-authoritative view, so the loop does not need it. Tracked in [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207), which either finds a REST route or makes the helper refuse with its exit 2; until then it can only fail behind the proxy |
| `readiness-gate.sh`: `gh pr view`, `gh api graphql --paginate --slurp` (review threads), `gh api repos/…`, `gh api user`, `gh pr ready` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27 | Conditions were checked by hand over REST (`…/ccr/review_threads`, `…/ccr/ready_for_review`). harmon-devkit#1207; orchestrator-side, see [What runs where](#what-runs-where) |
| `check-codex-cloud-review.sh`: `gh pr view`, `gh api --paginate --slurp` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27; the pagination fails past page 1 — observed 2026-09-27 | The current-head cycle was checked by hand over REST. harmon-devkit#1207 |
| `gh-ro.sh`, `gh-write-broker.sh`: `gh api` with a pinned method | integrate skill (vendored) | plain REST reads and writes work — observed 2026-09-27 for `gh api repos/…`; these two wrappers themselves not yet observed | GET refuses `graphql` by design |
| `round-push.sh`: `gh api --hostname …` | review skill (vendored) | expected, not yet observed | — |
| `lane-watch.sh`: `gh pr list`, `gh api --paginate --slurp`, `gh pr ready --undo` | orchestrate skill (vendored) | expected to fail, not yet observed — GraphQL-backed subcommands | Orchestrator-side; not run in a cloud lane |
| `scripts/status.sh`, `scripts/check-closing-keywords.sh`, `scripts/guard-closing-keywords.sh`, `scripts/audit-session-artifacts.sh` | harmon-init's own | **REST since #1430**: `gh api` through the bounded `gh_rest_*` helpers, with a page ceiling. `status.sh` still calls `gh auth status` and `gh run list`, which are not on the helpers — expected, not yet observed | Run `task status` in the first live session and record it |
| `task foreman:plan`, `foreman:dispatch`, `foreman:watch` | the pinned Foreman CLI, run through `uvx` from a git URL | expected, not yet observed — the calls Foreman makes are in its own repository, not enumerated here. Dispatch refuses on the local runner for public repos by design | Orchestrator-side; not run in a cloud lane |
| `gh api repos/{o}/{r}/…` (REST), `gh api user` | anything | **works** — observed 2026-09-27 | — |
| `gh api search/issues` | ad hoc | **fail, 403** — observed 2026-09-27 | `repos/{o}/{r}/issues?state=all`, paged |
| `gh api --paginate` | ad hoc | **page 1 only**, then a hard error — observed 2026-09-27 | Explicit `&page=N` loop |
| GitHub MCP tools (issue and PR read, create PR, subscribe to PR activity) | the session's built-in tools | **work**, repository-scoped — observed 2026-09-27 | `issue_read` returns `closed_by_pull_requests` |
| Any comment or body write | any | **succeeds with a footer appended** — observed 2026-09-27 | Compare by containment, not equality |

**Pending observation (criterion 7):** the maintainer runs a live session, runs
each row's call, and replaces the tag in the **Result** column with what was
seen. A row that still fails after that needs a follow-up issue or a workaround
written in its last column; the criterion is not met while a failing row has
neither. The rows tagged *expected* are the ones this observation exists for.

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

**Pending observation (criterion 4):** from a local terminal, run
`claude --cloud "<task>"` for a task that ends in a pushed branch, and record
whether it ran to the end with no permission prompt and no human step, and which
permission mode it ran in. The docs say the mode is picked from the session's
mode dropdown at creation; they do not say what `--cloud` defaults to. The agent
posture (#1404) is what installs a deny-listed, prompt-free mode into cloud
sessions, and is not in this environment yet.

Observed:  *pending*

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
credential store unprompted, never terminate a process without approval, never
merge or cut a release without explicit approval, and the reply-style
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

   ```sh
   log=$(mktemp /tmp/verify.XXXXXX)
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
2. **Its component tasks**, each under the limit: `task check` (lint, the fast
   gate), then the individual `task test:*` targets `verify` is made of.
3. **Raise the ceiling** with `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`
   in the environment ([Environment variables](#environment-variables)). This
   only moves the limit to ten minutes; a gate longer than that still needs the
   first form.

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

## When per-checkout preparation runs

The setup script provisions the **VM**: the platform snapshots the filesystem
after it, and a session starts from that snapshot without running the script again
until the script or the network hosts change, or the cache expires after about
seven days (*docs, 2026-09-29*). The repository is a **fresh clone per session**
(*docs, 2026-09-29*), and the 2026-09-27 session, which had no setup script,
already had it at `/home/user/harmon-devkit` when it started.

What the docs do not say is whether that clone exists when the setup script runs.
A script served from the cache cannot depend on it either way, because the
snapshot was taken before this session's clone. So the rule that holds regardless:

- **Setup script**: machine-level, repository-independent — the bootstrap, and
  nothing that reads a checkout.
- **Per-checkout preparation** — installing the git hooks, and anything that reads
  the clone — runs when the session starts, not in the setup script: a
  `SessionStart` hook in the repository's `.claude/settings.json`, guarded on
  `CLAUDE_CODE_REMOTE=true` so it does nothing locally (*docs, 2026-09-29*). That
  hook runs only in a single-repository session.

There is no `task setup:remote` in this repository today (checked 2026-09-29),
so the preparation is either a `SessionStart` hook that calls existing tasks, or
a task added in a follow-up once the observation below says what it must do.

**Pending observation (criterion 11):** the guide records the answer here once a
live session has given it. Probe: in a *new* copy of the environment, add one
line to the setup script that writes what it can see,

```sh
ls -d /home/user/*/.git > /var/tmp/harmon-setup-clone-probe.txt 2>&1 || true
```

start a session, and ask it to `cat /var/tmp/harmon-setup-clone-probe.txt` (files
written by the setup script are kept in the snapshot). An empty or "No such
file" result means the script runs before the clone. Remove the line afterwards —
changing the script rebuilds the cache.

Observed:  *pending*

## Pending observations

Five acceptance criteria of
[#1407](https://github.com/evanharmon1/harmon-init/issues/1407) need a live
Claude Code on the web session run by the maintainer, and one further item comes
out of writing this guide. Each result goes in the section named, replacing the
`_pending_` line, with the date and the Claude Code version.

| # | What has to be seen | Where the result lands |
| --- | --- | --- |
| 1 | The `vX.Y.Z` of the first release that carries the bootstrap, and that the setup script completes on the real VM inside the cache budget | [Setup script](#setup-script) |
| 3 | Session commit, push and PR attributed to `evanharmon1-bot`, on an evanharmon1 repo and a ponderousdev repo; or the platform's refusal and the fallback | [Whose identity GitHub sees](#whose-identity-github-sees) |
| 4 | `claude --cloud "<task>"` runs prompt-free and returns a pushed branch with no human step | [Bridges between the terminal and the cloud](#bridges-between-the-terminal-and-the-cloud) |
| 7 | Each row of the `gh` inventory run through the proxy; every failing row gets a follow-up or workaround | [The `gh` call inventory](#the-gh-call-inventory) |
| 8 | The bootstrap and `task verify` under **Trusted**; every denial recorded; each added domain justified by one | [Network](#network) |
| 11 | Whether the setup script runs with the repository already cloned | [When per-checkout preparation runs](#when-per-checkout-preparation-runs) |
| — | Whether release-asset downloads from repositories *not* attached to the session succeed, given the docs say they 403 | [Network](#network) |

## Reusing this structure

The Codex cloud (#750) and Sprites (#1411) adapters need the same sections in the
same order, so the shape is the reusable part: **the environment** (name, setup
script at a pinned tag, network level and each added domain's reason, variables),
**identity and secrets**, **what the platform's GitHub path does to `gh`** with a
call inventory, **bridges** to and from a local terminal, **memory**, **long
gates**, **when per-checkout preparation runs**, and a **pending observations**
register that ties every unobserved fact to the criterion that will prove it.
The contract and the shared network tables stay in
[architecture/remote-environments.md](../architecture/remote-environments.md).
