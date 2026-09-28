# Self-hosted Claude Code cloud environments

**Status:** research note for harmon-init#1410, sources read 2026-09-28.
**Question:** Claude Code can run a cloud session on a *self-hosted
environment* rather than on an Anthropic VM. Is routing the epic's remote
lanes there a better way to hold the epic's invariant — remote sessions run
the devcontainer's environment from one source of truth — than bootstrapping
a stock hosted VM (#1403)?
**Answer in three sentences:** on the documentation, yes and by a wide
margin — the runner image is one **you** build, so the published devcontainer
image can *be* the remote environment instead of being re-created in it (that
it works as a runner image is the load-bearing claim, and it is **unverified**
until the [trial](#trial-session--pending) runs), the
GraphQL/REST restriction that breaks `gh` on Claude Code on the web
disappears, and the agent posture (#1408) gains enforcement points that hosted
environments do not offer. Commercially it is gated: self-hosted environments
are a public beta **for Team and Enterprise organizations only**, off by
default, so adopting them means moving off an individual plan onto a Team
organization (minimum two seats) before a single session can run. The
recommendation is therefore **adopt later** — keep #1403 and the hosted
adapters exactly as planned, and file the self-hosted adapter as a fourth
adapter to be built when (and only when) the plan move happens.

Everything below that names a capability carries the URL it was read from
(see [Sources](#sources)); anything that could not be verified against a
primary source is marked **unverified**.

## What this note decides, and what it does not

The epic's architecture (#1402, decided 2026-09-27) already commits to a
bootstrap for hosted VMs. This note does **not** reopen that decision: it
asks only whether self-hosting is a better route to the same invariant, and
what would change downstream if it were adopted. #1403 is load-bearing for
Claude Code on the web (#1407) and Codex cloud (#750) whatever this note
concludes, because neither platform documents a way to supply an image — on
Claude Code on the web "replacing the base image entirely isn't supported yet"
([cloud environments][cloudenv], read 2026-09-28), and Codex cloud runs a
default `universal` image plus your setup script ([Codex cloud
environments][codexenv], read 2026-09-28).

The capability still exists in the installed CLI. `claude --version` reports
`2.1.270 (Claude Code)` in this devcontainer, and the issue's verify command
returns:

```text
  --environment <environment_id>        Create a new cloud session that runs on
                                        the given self-hosted environment
                                        (ccpool_...).
```

## How a self-hosted environment is created and registered, and what runs on the host

Three parts, in Anthropic's own words: an **environment** is "a named
destination that cloud sessions can be sent to"; a **runner** is "a program
running on hosts inside your network … the idea is the same as a self-hosted
CI runner"; a **session** is "one Claude Code task a developer started"
([self-hosted environments][shenv], read 2026-09-28).

Creation is an admin-UI action plus a process you start:

1. An **Owner** turns on **Allow self-hosted environments** on the
   **Cloud environments** admin page — "the **New** button doesn't appear
   until it is".
2. **New** → name → **Create**, then **Copy environment key** on the
   wizard's second step. "claude.ai shows the secret once, and you can't
   retrieve it later; it expires 365 days after creation." The environment's
   `ccpool_...` ID stays visible in its detail dialog
   ([quickstart][quickstart], read 2026-09-28).
3. On the host: write the secret to a file, then
   `claude self-hosted-runner --environment-secret-file '/etc/claude/environment-secret' --base-dir '<writable-dir>'`.
   The runner registers and begins polling; the environment's status moves
   from **No runners deployed** to **Healthy** within a few seconds.
4. A session is routed either by picking the environment in the start-session
   UI, or non-interactively with
   `claude -p "<prompt>" --environment <ccpool-id> --output-format json`
   ([testing][testing], read 2026-09-28).

There is also a guided `claude self-hosted-runner setup`, and the whole
create/delete path is available as an API
(`POST`/`DELETE https://api.anthropic.com/v1/code/runners/self-hosted/pools`,
header `anthropic-beta: ccr-byoc-2025-07-29`) so CI can make a throwaway
environment per run ([testing][testing]).

**What runs on the host** is the ordinary `claude` binary in a different
mode. The runner "polls `api.anthropic.com` for work", "clones the repository
into its working directory and spawns a child Claude Code process", and the
child "streams events back over HTTPS while the runner keeps polling; each
poll refreshes the lease and doubles as the heartbeat". If the runner stops
polling for about 60 seconds the server requeues the session. "Anthropic
never connects into your network" — every connection is outbound
([self-hosted environments][shenv]). Optionally a second process, the
autoscaling **orchestrator** (`claude self-hosted-runner orchestrator`), runs
elsewhere and boots one runner per queued session through a `spawn-runner`
hook ([configuration][config], read 2026-09-28).

Two lifecycle rules shape any fleet design. A runner "serves one owner at a
time" — the first session locks it to that session's owner — so "the minimum
fleet size is … the number of owners you expect to be active at once". And
at the default `--drain-grace-sec 0` "the runner exits as soon as its active
sessions finish", which means production deployments run it under something
that restarts it ([self-hosted environments][shenv]).

**Relevant to the question that started this spike** (#1402: could Herdr
reach the machine directly?): the host is yours, so Herdr, tmux and SSH run
on it exactly as on the Coder box. But the *session* is a child process the
runner spawns and supervises — not a pane you attach to — and its input
surface stays the Anthropic control plane (`claude -p "<message>" --cloud
<session-id>` or claude.ai). Herdr reaches the **host**, not the **session**:
a genuine narrowing of the hypothesis in the issue body.

## Can it use a custom container image — specifically the published devcontainer image?

**Yes.** A custom image is the documented container path: "Anthropic doesn't
publish a pre-built runner image. Build your own around the `claude` binary,
layering in whatever toolchain your repositories need: language runtimes,
compilers, package managers, and MCP sidecars" ([deploy][deploy], read
2026-09-28). It is not the only documented path — the host requirement is "a
Linux or macOS host or container" ([quickstart][quickstart]), so a bare host
running the binary is the documented alternative — but it is the one that
matters here. The documented minimal Dockerfile is `debian:bookworm-slim`
plus the `claude` binary — nothing about it prevents starting from the
published devcontainer image instead.

This is the finding that matters for the epic. On Claude Code on the web the
image cannot be supplied, which is precisely why #1403 exists; here the
**image is the interface**, so the devcontainer is not re-created remotely,
it *is* the remote environment. And the image already exists:
`.github/workflows/devcontainer-build.yml` builds
`.devcontainer/devcontainer.json` through `devcontainers/ci` and pushes
`ghcr.io/evanharmon1/harmon-init-devcontainer` on pushes to `main` that
change the devcontainer surface (`scripts/devcontainer-changed.sh` gates the
build job), with the pinned shared base, the repo's `.devcontainer/Dockerfile`
overlay, and the devcontainer **features'** install payload (`python:1` at
3.14, `docker-in-docker:2`, `github-cli:1`) applied. The runner image is a
Docker-free render of that build (the posture section says why) plus the
`claude` binary, and it must satisfy:

| Requirement | Source |
|---|---|
| Claude Code **2.1.224 or later** on the host or in the image | [deploy][deploy], [quickstart][quickstart] |
| Git **2.24+**; 2.32+ for the Anthropic git proxy, 2.34+ for `--configure-git` commit signing, 2.29+ for `--push-outcome-on-release` | [deploy][deploy] |
| A git identity set **system-wide** — "Without an identity, `git commit` fails with `Please tell me who you are` and sessions can't make progress" | [deploy][deploy] |
| `git config --system --add safe.directory '*'` when checkouts are owned by another uid | [deploy][deploy] |
| A writable `--base-dir` (default `/workspace`); for a non-root runner, "create the directory and give the runner's user ownership before starting the runner" | [deploy][deploy] |
| Linux or macOS. "Windows isn't supported as a runner host" | [quickstart][quickstart] |

Architecture is not a constraint: the documented download URL takes
`linux-x64`, `linux-arm64`, and musl variants, so an arm64 runner is a
supported build ([deploy][deploy]).

**A rendered image does not carry** what `devcontainer.json` does at
container start, and the runner runs no devcontainer tooling. The adapter must
reproduce each of these — by whatever means the follow-up issue's checks
verify, not by a recipe written here:

- the `containerEnv` markers (`FOREMAN_DEVCONTAINER=bot`,
  `HARMON_BOT_AUTONOMY_*`), so that Foreman's D2 tripwire and the bot-autonomy
  checks see the container they see locally;
- the features' runtime metadata (`privileged`, `init`, `entrypoint`,
  `mounts`, `containerEnv`, `capAdd`), which the devcontainer CLI applies at
  container creation and a plain container run does not;
- the `initializeCommand` env allowlist guard (`init-env.sh`), so that only
  allowlisted variables reach a session;
- the lifecycle hooks' effects (`post-create.sh`, `post-start.sh`:
  bot-autonomy apply and verify, the settings seed, the Herdr integrations),
  so that a session starts where a local one does;
- and, for every privileged step, a home that exists when it runs and that
  the session UID cannot alter.

Two image-shaped behaviours worth knowing:

- **Version pinning is free.** "Each session's child Claude Code process runs
  the runner's own binary, and the runner turns off auto-update inside the
  sessions it spawns" ([deploy][deploy]).
- **Cold clone can be pre-warmed.** At `--capacity 1` the runner keeps one
  canonical clone per repository at `<base-dir>/<repo-owner>/<repo>` and
  reuses it; you can bake that clone into the image ([deploy][deploy]).

## Which Claude Code on the web behaviours carry over

The short version: the *session* behaves like a cloud session, but every
piece of the **environment** that claude.ai configures for a hosted VM —
setup script, network level, environment variables, API credentials — is
replaced by your image, your process environment, and your network. The
`ccpool_` environment is a routing destination, not a configuration object.

| Behaviour | Anthropic-hosted | Self-hosted |
|---|---|---|
| **Setup script** (claude.ai field, cached ~7 days if it finishes in ~5 min) | Yes ([cloud environments][cloudenv]) | **No equivalent documented.** The image is built ahead of time; per-session work goes in a wrapper script, a `command` hook, or a `SessionStart` hook. The five-minute cache budget that shapes #1403 simply does not apply. |
| **Network levels** (None / Trusted / Full / Custom) | Yes ([cloud environments][cloudenv]) | **No.** "In a self-hosted environment, you restrict session egress at your own network boundary." Anthropic states a required-hosts table and tells you to default-deny the rest ([deploy][deploy]). |
| **API credentials** (proxy-attached, never in the VM) | Pro and Max only | **No.** "A self-hosted environment doesn't have API credentials, and Team and Enterprise plans don't have them yet" ([cloud environments][cloudenv]). |
| **GitHub proxy** | Always; credentials stay outside the VM | **Opt-in only** (`--use-anthropic-git-proxy`). Otherwise "sessions in a self-hosted environment authenticate git operations with credentials your deployment provides" ([cloud environments][cloudenv], [deploy][deploy]). |
| **The REST-only limit** | Yes — see below | **Avoidable.** It is a property of the proxy, so not using the proxy removes it. |
| **Repo `.claude/settings.json`, `CLAUDE.md`, `.claude/rules/`, `agents/`, `skills/`, `commands/`, `.mcp.json`** | Loaded from the clone (settings and `.mcp.json` in single-repository sessions) ([cloud environments][cloudenv]) | Same — plus the runner's own layer, below. |
| **Managed settings file in the image** | Not applicable (Anthropic VM) | **Yes** — "in a self-hosted environment, sessions also read the managed settings file in the runner image" ([cloud environments][cloudenv]). This is the hook the agent posture needs. |
| **User-level `~/.claude`** | Platform-populated (account skills, preferences); no user CLAUDE.md, no user plugins | **Operator-populated.** "The runner gives each session its own config directory, seeded from a snapshot of the host's `~/.claude/` … `settings.json`, `CLAUDE.md`, hooks, agents, commands, and skills in your runner image apply to every session as the user-level baseline" ([configuration][config]). |
| **Plugins** | A cloud session does not install a repository's `enabledPlugins` or its `extraKnownMarketplaces` ([cloud environments][cloudenv]) | The same session-side limitation is not restated for self-hosted, so treat repository-declared plugins as **still not installed** (**unverified** for self-hosted specifically). What *is* documented: marketplaces don't auto-update, `FORCE_AUTOUPDATE_PLUGINS=1` re-enables that, and `registry.npmjs.org` plus `downloads.claude.ai` are needed when a session installs one ([deploy][deploy]). |
| **MCP servers** | Repo `.mcp.json`; connectors delivered by Anthropic | Same, plus `claude mcp add --scope user` at image build time, `/etc/claude-code/managed-mcp.json`, and `managedMcpServers` in managed settings ([configuration][config]). |
| **Resource limits** | ~4 vCPU / 16 GB / 30 GB disk ([cloud environments][cloudenv]) | **Yours.** Anthropic's starting point is 4 GiB memory and 2–4 CPU per session, "treat them as a starting point rather than a requirement" ([deploy][deploy]). |
| **Command time limits** | Bash default 2 min, max 10 min; setup script ~5 min | The Bash-tool defaults are Claude Code's, not the platform's, and `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS` are ordinary environment variables the sessions inherit from the runner ([cloud environments][cloudenv], [configuration][config]). |

### The REST-only limit, precisely

The limit #1407 records is a property of the **Anthropic GitHub proxy**, not
of cloud sessions as such. Its documented restrictions are: `git push` "works
only against the session's current working branch"; GitHub API and
release-asset requests "reach only repositories attached to the session"; and

> **GraphQL restrictions**: the proxy serves only a pinned set of GraphQL
> operations for pull-request workflows. The proxy rejects everything else on
> the GraphQL endpoint with a 403 that says `This GraphQL query is not
> enabled for this session` and names the REST fallback,
> `gh api repos/{owner}/{repo}/...`. The restriction applies to every request
> through the proxy regardless of the credentials you supply, so a `GH_TOKEN`
> you set gets the same 403. Claude can't reach GitHub APIs that exist only
> in GraphQL, such as Projects v2, through the proxy.
>
> — [cloud environments][cloudenv]

On a self-hosted runner that proxy is **opt-in**. Run without
`--use-anthropic-git-proxy`, give the session a git credential, and `gh` talks
to `github.com` directly: `gh pr view`, `gh pr checks`, `gh issue edit`,
`gh label list`, `gh api --paginate`, sub-issue and Projects v2 writes — every
call the dev-loop skills make — behave as they do in the devcontainer. This
removes the largest documented source of skill breakage in the epic (and the
helper-script fallout tracked in harmon-devkit#1207).

The trade is credential hygiene: the proxy exists so no GitHub credential
enters the session VM. The security model below covers the alternatives.

## Security model: who holds which credential, and what the host can reach

**Model credentials are never yours to hold.** "The control plane delivers
the API endpoint to each session, and the session authenticates with an
Anthropic-issued, session-scoped OAuth token." A consequence worth recording:
"inference can't be routed through Amazon Bedrock, Google Cloud's Agent
Platform, Microsoft Foundry, or an LLM gateway in self-hosted environments"
([self-hosted environments][shenv]).

**GitHub credentials are yours**, in one of three shapes ([deploy][deploy]):

- **Per-session minted** (the recommended shape): the wrapper script verifies
  `CLAUDE_CODE_SESSION_ACCESS_TOKEN` against the JWKS endpoint and asks your
  own credential service for a short-lived token for the identity in the
  token's `act` claim.
- **In the image** (a deploy key, a `credential.helper`, `GIT_SSH_COMMAND`) —
  works, with a caveat Anthropic states plainly: "Don't bake long-lived or
  broadly-scoped push credentials into a shared runner image: a credential in
  the image is available to every session the image runs, whoever started it.
  Instead, mint a short-lived, least-scoped token per session from your
  wrapper script". Whatever you use "must work without a prompt": the runner
  sets `GIT_TERMINAL_PROMPT=0`, `BatchMode=yes`, `GCM_INTERACTIVE=never`, and
  clears `core.askPass`.
- **The Anthropic git proxy**: "the runner image needs no git credentials at
  all: no SSH keys, no credential helper, no `.netrc`." Requires
  `--capacity 1` and git 2.32+, and "your git host must be reachable from
  Anthropic infrastructure".

**What the host can reach is entirely your decision, and Anthropic says so
bluntly:** "The product can't verify or enforce this, so apply it at your own
network boundary on every environment. Session code is model-directed and can
attempt connections to arbitrary hosts" ([deploy][deploy]). The always-required
egress is `api.anthropic.com:443` plus your git host (the latter not needed
under the git proxy); conditionally `downloads.claude.ai`,
`storage.googleapis.com`, `code.claude.com`/`claude.com`,
`*.frame.claudeusercontent.com`, `registry.npmjs.org`, and two Datadog
intake hosts that are off by default. Corporate proxies are supported through
`HTTPS_PROXY`/`NO_PROXY` and a `Proxy-Authorization` injector.

**The exposure that needs stating plainly**, because it is the one that does
not exist locally:

- "A self-hosted runner executes arbitrary, model-directed code on your
  infrastructure on behalf of everyone who can dispatch a session to its
  environment."
- "**Dispatch has no per-environment access control**: any member of your
  Anthropic organization can dispatch a session to any of its environments."
  `--lock-to-account` bounds which account's sessions a host executes, "but
  it doesn't narrow who can dispatch into the environment."
- The **environment secret** "can register runners and pick up any session
  queued on the environment. On a fixed fleet it lives on every runner host,
  where any session's code can read the secret file." The documented fix is
  on-demand runners, which keep the secret on an orchestrator host "which
  never runs user code".
- Block the cloud metadata endpoint from sessions (IMDSv2 hop limit 1, or an
  explicit deny for `169.254.169.254` inside the container).
- Sessions share the runner's UID, so `--hooks-dir`, the wrapper, and
  `~/.claude/` must be read-only to the session.

All quotes from [deploy][deploy]. For a two-person organization the dispatch
exposure is small, but it is a property of the org, not of the host, and it
should be written down before any runner touches a machine that holds
anything else.

**What stays on your infrastructure:** "Repository checkouts, build
artifacts, secrets, and any files a session creates or modifies stay on the
machines you provision. The conversation itself, including prompts,
responses, and tool results, goes to `api.anthropic.com` for model
inference, and Anthropic stores the session transcript" ([self-hosted
environments][shenv]).

## What plan and cost it requires

This is the blocker, and it is not a technical one.

- **Plan:** "public beta for Team and Enterprise organizations. Self-hosted
  environments are off by default; an **Owner** turns on **Allow self-hosted
  environments** on the **Cloud environments** admin page, which requires
  cloud sessions to be enabled for the organization" ([self-hosted
  environments][shenv]). Pro and Max — the individual plans — are not on that
  list. (Cloud sessions themselves *are* available on Pro and Max; it is
  self-hosting that is not: [Claude Code in the cloud][web].)
- **Excluded:** organizations with Zero Data Retention enabled.
- **Not routed yet:** Claude Security and Code Review sessions "don't route
  to them yet"; Claude Tag sessions can run there but can't use Access
  bundles.
- **Cost, Anthropic side:** "sessions in a self-hosted environment consume
  your organization's Claude Code usage the same way sessions in
  Anthropic-hosted environments do" ([self-hosted environments][shenv]) —
  there is no separate charge for self-hosting, and equally no discount for
  bringing your own compute.
- **Cost, plan side:** Team is "$20 per seat / month if billed annually. $25
  if billed monthly" for a standard seat and "$100 per seat / month if billed
  annually" for a premium seat, with a stated range of **2 to 150 seats**;
  Enterprise is "US$20/seat/month, billed annually" plus usage at API rates
  ([pricing][pricing], read 2026-09-28). "Claude Code is included with every
  Team plan seat"; premium seats "offer more usage for team members with
  heavier workloads" ([Team/Enterprise support article][teamdoc], read
  2026-09-28).
- **Cost, compute side:** yours, entirely — and it is contention, not zero.
  The Coder box the platform already runs is the obvious host, and its
  measured constraint is on record: three lanes on the 32 GB Coder
  devcontainer had to be serialised behind a `flock`, each gate then took ~10
  minutes and the third lane waited 20–30 minutes per round
  ([remote-implementer-environments.md][refenv], from harmon-init#1120).
  Self-hosting makes every remote lane one more contender for that 32 GB, so
  the implication is a sizing decision: one runner per active owner at
  `--capacity 1` (the documented minimum fleet), gates serialised behind the
  same `flock` if capacity is ever raised, or a second host before a second
  lane runs concurrently.
- **An operational cost that is easy to overlook:** non-interactive dispatch
  (`claude -p … --environment`) authenticates with a claude.ai OAuth token,
  and "there is no long-lived CI token for this today. The scope that grants
  cloud-session control, `user:sessions:claude_code`, is capped server-side
  at 30 days" ([testing][testing]). An orchestrator that dispatches sessions
  therefore needs `claude auth login` re-run interactively **every 30 days**
  — for a workflow whose first design principle is "no human step", a
  recurring human step, small and monthly, that belongs in the decision.

Net: a single-operator platform would have to stand up a two-seat Team
organization (**$40/month** annually billed at standard seats, more for the
usage headroom a full dev loop wants) and move the Claude Code identity onto
it, before evaluating anything. That is the whole of the "adopt later".

### Remote Control does not change this

The self-hosted page names the alternative for "your own always-on machine":
Remote Control, "which is also available on Pro and Max plans"
([self-hosted environments][shenv]). But Remote Control lets other devices
drive a Claude Code session that is already "running on your machine"
([Remote Control][remotecontrol], read 2026-09-28). It is not a destination
an orchestrator can dispatch a new cloud lane to — there is no `--environment`
for it — so it leaves the plan gate untouched.

## How Coder and Fly.io Sprites fit as the host

### Coder

Two routes, and they are very different in maturity.

**Route 1 — a Coder workspace runs the runner.** Nothing special is needed:
the documented host requirement is "a Linux or macOS host or container with
outbound HTTPS to `api.anthropic.com`" plus the software floors above
([quickstart][quickstart]). A workspace built from the published devcontainer
image, running `claude self-hosted-runner` under its existing supervision,
is a runner. This is available today, needs no partner programme, and reuses
the box the platform already operates. Its shape is a **fixed fleet**, with
the documented caveats: the environment secret sits on a host that also runs
sessions, and one runner serves one owner at a time.

**Route 2 — Coder Agent Relay.** Coder has built a first-class integration
on exactly this mechanism: "Coder Agent Relay brokers the connection between
Claude Code's cloud session queue and your self-hosted Coder workspaces, then
manages each workspace's lifecycle for the life of the session"
([Coder + Anthropic][coderanthropic], read 2026-09-28). The 2026-09-15
announcement confirms it is "built on Claude Code's publicly available
self-hosted environments", that each workspace "starts a Claude Code runner
that opens an outbound connection to Anthropic's backend", and that
"workspaces are sandboxed, ephemeral, and scoped to a single Claude Code
session" — the per-session-container hardening Anthropic recommends, for free
([Coder blog][coderblog], read 2026-09-28).

Availability is the problem. The announcement says "Claude Code support in
Coder Agent Relay is in early access with select design partners"; Coder's
own v2.37 Agent Relay documentation states "Cursor is the first provider
Agent Relay supports" and "Agent Relay is in early access and is in closed
preview with select customers", adding "Configuring a relay requires a
provider credential and a compatible template, so talk to your account team
before you deploy it" ([Coder Agent Relay docs][coderrelay], read
2026-09-28). No licence tier or version floor for the Claude Code provider is
documented. Treat Route 2 as **not available** and **unverified**; Route 1 is
what an adoption would actually build.

### Fly.io Sprites

Sprites are a poor fit as a **runner host**, for three reasons that compound:

1. **No custom base image.** Fly staff, in the thread this platform already
   cited in the #1120 spike: "Right now you can't use a custom base image.
   But we're looking into the idea of forking from a sprite, so you'll be
   able to build up your base, then fork off of it"
   ([community.fly.io][spritesimage], re-read 2026-09-28 — no later reply in
   the thread says this has changed). A new sprite "runs Ubuntu 25.10 with
   common tools preinstalled", including a Claude CLI
   ([working with sprites][spritesdocs], read 2026-09-28). Whether that
   preinstalled CLI is ≥ 2.1.224, the runner's floor, is **unverified**.
2. **Idle sleep versus a polling heartbeat.** A sprite is "billable only
   while running"; warm and cold states incur no compute charges
   ([Sprites][spritespage], read 2026-09-28), and the whole economic
   argument for Sprites in the #1120 note is that they sleep. But the runner
   *is* a poll loop, and "if the runner stops polling for about 60 seconds,
   the server requeues the session for another runner" ([self-hosted
   environments][shenv]): a runner that sleeps loses its sessions. The
   orchestrator pattern above makes the *runners* short-lived
   ([configuration][config]), but the orchestrator itself must stay awake to
   see the queue, so something is billed continuously either way, and a
   sprite kept awake for that job throws away the reason to choose Sprites.
   This reason weakens the fit; reasons 1 and 3 are what decide it.
3. **The image problem returns one level down.** Because the sprite cannot
   *be* the devcontainer, running the devcontainer inside it needs the
   Docker-in-sprite arrangement the #1120 note flagged as its single biggest
   unverified risk — and a self-hosted runner would then need to spawn
   sessions inside that inner container, which no documented lifecycle hook
   does. (An `exec`-into-container wrapper built on the documented `checkout`
   and `command` hooks is *conceivable* and **unverified**, and it is a lot of
   machinery to get back to where a Coder workspace already is.)

Sprites remain interesting as a **direct lane host** — the #1120 note's
conclusion, driving a nested devcontainer from Herdr, is untouched by this
note. They are simply the wrong shape for *this* mechanism.

| Host | Runs the runner today? | Devcontainer image as the session environment? | Verdict |
|---|---|---|---|
| Coder workspace (direct) | Yes — documented host requirements only | Yes — a Docker-free render of it; **unverified** until the trial | **The route, if adopted** |
| Coder Agent Relay | Announced, early access / closed preview | Yes, via the mapped template | Watch; not available |
| Fly.io Sprite | Binary is present, floors **unverified** | No — no custom base image | Reject for this purpose |

## Enforcing the agent posture (#1408) on a self-hosted environment

Self-hosting is the **only** one of the epic's platforms where the posture is
enforced by the operator rather than requested of the platform. Axis by axis,
against #1408's decided positions:

Sessions read "the managed settings file in the runner image"
([cloud environments][cloudenv]) — the `/etc/claude-code/managed-settings.json`
that `install-repo-config.sh` already writes. It is an enforcement point only
under the **managed-settings preconditions**: the file is root-owned and
read-only to the session UID; that UID has no `sudo`; no Docker daemon is
reachable from the session (root inside a privileged container can mount the
host filesystem, which defeats every read-only-to-the-session defence at once
— the managed-settings file, the wrapper, `--hooks-dir`, `~/.claude/`); and
the organization deploys no server-managed settings keys, since "by default,
when your organization delivers any server-managed keys, sessions ignore the
runner image's file apart from the keys Claude Code reads from every admin
source" ([configuration][config]). The devcontainer passes the first
(`install-repo-config.sh`, run as root from the Dockerfile, installs the file
root-owned at mode 0644) and fails the second and third — `vscode` has
passwordless `sudo`
([devcontainer-image.md](../architecture/devcontainer-image.md)) and the bot
profile carries `docker-in-docker:2` — and the fourth is a standing
constraint on the Team organization, asserted rather than assumed. The
[trial](#trial-session--pending) checks the whole set.

| Posture axis (#1408) | Enforcement point on a self-hosted environment |
|---|---|
| **Permissions — allow list, deny rules, no `ask`** | The managed settings file in the runner image, under the managed-settings preconditions. Whatever the adapter layers on top is an adapter detail and must be read-only to the session, as Anthropic already requires of `--hooks-dir` and `~/.claude/` ([deploy][deploy]). |
| **Prompt-free operation** | Required, not merely desired: "A self-hosted session has no terminal attached, so an unanswered permission prompt stalls the turn until the user responds in the UI" ([configuration][config]). #1408's choice of auto mode with no `ask` rules is the only workable setting here. |
| **A repository cannot loosen the posture** | `--confine-repo-settings enforce` — the runner scans each repository's committed settings for a grant resolving outside the workspace, a non-empty `env` block, or "an operator-posture override such as `sandbox.enabled: false`", and `enforce` "refuses the session" ([deploy][deploy]). Also `--trust-workspace false` to "drop repo-committed permission grants" entirely, and "A `defaultMode` of `auto` is only honored from the image-wide or user-level settings file, so a checked-out repository can't grant itself auto mode" ([configuration][config]). Nothing equivalent exists on a hosted VM. |
| **Network — enforced egress allowlist** | Your own boundary, which is what #1408 and #286 want. Anthropic supplies the required-hosts table and states the product cannot enforce it ([deploy][deploy]). |
| **Identity — the agent PAT, no bot/operator token** | Image-level credential or per-session minted from the wrapper. The documented preference is per-session ("a credential in the image is available to every session the image runs"), which is *stronger* than the agent PAT model #1408 settled for. |
| **Secrets — no 1Password, no `op`, no Tailscale key** | Not carried by the image: the env allowlist guard (`init-env.sh`) is `initializeCommand`, and the adapter must replace it so that only allowlisted variables reach a session. The environment secret is itself a new secret to hold, readable by any session on a fixed fleet ([deploy][deploy]). |
| **Docker — per-repo opt-in, DinD only** | A repository's DinD opt-in is incompatible with the managed-settings preconditions: root inside a privileged container can mount the host filesystem, so a DinD-enabled runner image has no enforced managed-settings layer — and no read-only wrapper, `--hooks-dir`, or `~/.claude/` either. |
| **Marker** | Not carried by the image (`containerEnv`): the adapter must set `FOREMAN_DEVCONTAINER=bot` and the `HARMON_BOT_AUTONOMY_*` markers, or Foreman's D2 tripwire refuses to run. |

Two further posture-adjacent facts: session hooks supplied by the control
plane "enter the ordinary merged hook configuration, not the managed tier, so
your managed settings still apply", and `disableAllHooks` disables them
([configuration][config]) — consistent with the epic's "no Claude Code hooks
in this iteration". And `--push-outcome-on-release` needs a branch ruleset
before it is turned on: "on resume, the runner fetches the previously pushed
branch without verifying who pushed it, so anyone with push access to those
refs can place content into the resumed workspace" ([deploy][deploy]).

## Recommendation: adopt later

**Adopt later.** The mechanism is right and the fit with this platform is
better than any hosted adapter — the devcontainer image *is* the environment,
`gh` works unrestricted, and the agent posture gains enforcement it can get
nowhere else. It is blocked on one thing that no amount of engineering
changes: self-hosted environments are a Team/Enterprise public beta, and this
platform is on an individual plan. Revisit when a Team organization exists
for another reason (or Anthropic extends the beta) **and** either a
long-lived dispatch credential exists or the monthly `claude auth login` the
30-day cap on `user:sessions:claude_code` imposes ([testing][testing]) is
accepted as a standing human step — a recurring cost the plan move does not
remove.

### Effect on #1403

**No work removed; one thing changes.** #1403's bootstrap exists because on
Claude Code on the web "replacing the base image entirely isn't supported
yet" ([cloud environments][cloudenv]; that it also ignores `devcontainer.json`
is **unverified**), and Codex cloud (#750) documents only its default
`universal` image plus a setup script ([Codex cloud environments][codexenv]).
Both remain, so the bootstrap remains the single entrypoint for them. What
adoption would add is a platform that *bypasses* the bootstrap: the runner is
a published rendered image, so the pinned installs need to stay where they
are (`images/devcontainer/`), not to be reachable as a standalone script. What
the rendered image does not carry (the image section above) is adapter work,
not bootstrap work.

The one thing that changes is a constraint on #1403's tier/timing design.
"Core and agents tiers complete within 5 minutes", driven by the hosted
setup-script cache, is a hosted-platform constraint with no analogue here, so
that budget must stay a property of the *adapters* that need it rather than
of the bootstrap's structure; leaked into the structure, it hands the
self-hosted adapter a limit that means nothing on its platform.

### Effect on #1407

**No work removed.** The Claude Code on the web guide is still needed, and
its hardest content — the GitHub-proxy inventory of every `gh` call the
skills make — keeps its value: it is the record of what breaks under the
proxy, which self-hosting avoids *on that platform only*, and a self-hosted
runner that opts into `--use-anthropic-git-proxy` inherits the same 403s.

### Effect on #750

**None.** Codex cloud is a different vendor with its own environment; nothing
in this note touches it.

### Do hosted and self-hosted both remain supported?

**Yes, and that is the recommendation, not a compromise.** Hosted
environments stay the default — "Most teams are better served by
Anthropic-hosted environments, which need no infrastructure to run or
maintain" ([self-hosted environments][shenv]) — and they are the only option
on an individual plan. Self-hosted would become a **fourth adapter** under
the #1402 platform-neutral-core/thin-adapter shape, differing from the others
in that its "setup script" is an image build rather than a bootstrap call. The
epic's invariant is unchanged either way; self-hosting just satisfies it more
directly.

### Follow-up to file (not filed by this note)

One issue in harmon-init, blocked on the plan move: *"(remote-env):
Self-hosted Claude Code environment adapter"* — run the rendered image of a
Docker-free profile plus the `claude` binary as the runner on a Coder
workspace, and document the adapter section in
`docs/architecture/remote-environments.md` (the file #1403 creates). Not the
published `harmon-init-devcontainer` as it stands: that is the bot profile's
render, and its `docker-in-docker:2` fails the first check below. The
**agent** posture #1408 defines is Docker-off by default, so its rendered
image is the natural base once it exists; until then a Docker-free render is
required, and a repository that opts into DinD forgoes the enforced
managed-settings layer (the Docker row above). Its acceptance criteria are
checks against a running session:

- the managed-settings preconditions hold;
- `FOREMAN_DEVCONTAINER=bot` and the `HARMON_BOT_AUTONOMY_*` markers are set;
- an `init-env.sh` equivalent bounds the session's environment;
- the lifecycle hooks' effects hold: bot-autonomy applied and verified, the
  settings seed present, the Herdr integrations in place;
- every privileged setup step has a build-time or root-owned runtime home;
- the features come from the rendered image, not a hand re-add;
- the runner base is pinned by image digest, not by a mutable tag;
- egress is default-deny beyond Anthropic's required-hosts table;
- the runner runs with `--confine-repo-settings enforce`,
  `--trust-workspace false`, and `--capacity 1`;
- the trial below passes, as the issue's `[HUMAN]` criterion.

The issue has to choose its fleet shape deliberately: a Coder workspace at
`--capacity 1` is the opposite of the on-demand shape the security section
records as Anthropic's mitigation for the environment-secret exposure — a
fixed fleet, secret on the host that runs sessions. The **fixed fleet is
accepted here, for the two-person org and no further**, with its residual
named: the reader of the secret is model-directed session code, not an
identity, so any session's code on the fleet can read and use it. The
acceptance rests on the secret's bounded reach — registering runners and
picking up sessions on that one environment, not anything beyond it
([deploy][deploy]) — and on the second, always-on host the on-demand shape
needs for its orchestrator, the sizing problem from the cost section again.
A third seat reopens it in favour of the orchestrator shape, because more
dispatchers means more code that can read the secret; so does a runner host
that holds anything beyond the workspace.

## Trial session — pending

Issue #1410's third acceptance criterion is a `[HUMAN]` trial: one session on
a self-hosted environment built from the devcontainer image, running
`task verify` on harmon-init. **It is pending and was not attempted:** it is
conditional on the recommendation being "adopt", this note recommends "adopt
later", and no individual-plan account can create the environment at all. It
is the maintainer's to arrange when a Team organization exists.

When it is run, these are the things only a real session can settle:

- Does the rendered image, plus the `claude` binary and a system git
  identity, register and serve a session unmodified?
- Does `task verify` complete? It takes 10–12 minutes on a 4-core hosted VM
  (#1407) and the Bash tool's ceiling is 10 minutes, so
  `BASH_MAX_TIMEOUT_MS` on the runner is the likely fix — untested.
- Do the managed-settings preconditions hold, and does the image's
  `/etc/claude-code/managed-settings.json` then govern the session? A session
  that can `sudo` its way to the file has no enforcement layer at all.
- Does `--confine-repo-settings enforce` accept harmon-init's own committed
  `.claude/settings.json`, or refuse it — and does the session still work
  with `--trust-workspace false` dropping its grants?
- Does a session push a branch and open a draft PR under the agent identity,
  with full `gh` (GraphQL included) working?

## Verification status

| Claim | Status |
|---|---|
| `--environment` exists in the installed CLI | ✅ verified — `claude --version` 2.1.270, help text quoted above, 2026-09-28 |
| Environment creation, registration, runner lifecycle, network paths | ✅ primary docs, read 2026-09-28 |
| A custom image is the documented container path; a bare host is the documented alternative | ✅ [deploy][deploy] ("Build your own around the `claude` binary"), [quickstart][quickstart] ("a Linux or macOS host or container") |
| The rendered image is published with the overlay and the features' install payload applied | ✅ `.github/workflows/devcontainer-build.yml` builds `.devcontainer/devcontainer.json` through `devcontainers/ci` and pushes `ghcr.io/evanharmon1/harmon-init-devcontainer` on pushes to `main` that change the devcontainer surface (`scripts/devcontainer-changed.sh` gates the build job); feature runtime metadata is applied at container creation, not baked in |
| The rendered image works as a runner image | ❓ **unverified** — no trial session (see above) |
| Codex cloud documents no custom-image path | ✅ [Codex cloud environments][codexenv]: a default `universal` image plus a setup script, read 2026-09-28 |
| GraphQL/REST limit is a proxy property and opt-in when self-hosted | ✅ documented on both sides |
| Repository-declared plugins install in a self-hosted session | ❓ **unverified** — documented as not installed for cloud sessions generally; not restated for self-hosted |
| Team/Enterprise gating, ZDR exclusion, billing model | ✅ primary docs + pricing page, read 2026-09-28 |
| `user:sessions:claude_code` is capped server-side at 30 days — no long-lived CI token for dispatch | ✅ documented — [testing][testing], read 2026-09-28 |
| Coder workspace can host a runner | ✅ by the documented host requirements; ❓ **unverified** in practice |
| Coder Agent Relay supports Claude Code | ◐ announced 2026-09-15, "early access with select design partners"; Coder's own docs list Cursor as the first supported provider |
| Sprites cannot take a custom base image | ✅ Fly staff statement, thread re-read 2026-09-28 with no later contradiction |
| Preinstalled Claude CLI on a sprite meets the 2.1.224 runner floor | ❓ **unverified** |
| A sprite can host a long-lived polling runner economically | ❌ reasoned from documented sleep behaviour + the 60-second requeue; not measured — weakens the fit, reasons 1 and 3 decide it |
| Sessions read the runner image's managed settings file | ✅ documented — [cloud environments][cloudenv], read 2026-09-28 |
| The four managed-settings preconditions hold on a Docker-free render | ❓ **unverified** — pending the trial session (see above) |
| The devcontainer passes precondition 1 (root-owned, mode 0644, via `install-repo-config.sh`) and fails 2 (passwordless `sudo`) and 3 (`docker-in-docker:2`) | ✅ verified against this repository, 2026-09-28 |
| No server-managed settings keys are deployed on the Team organization | ◐ asserted as a standing constraint, not assumed; checked in the trial |

## Sources

All read 2026-09-28.

- [Self-hosted environments][shenv] — `https://code.claude.com/docs/en/self-hosted-environments`
- [Self-hosted environments quickstart][quickstart] — `https://code.claude.com/docs/en/self-hosted-environments-quickstart`
- [Deploy self-hosted environments to production][deploy] — `https://code.claude.com/docs/en/self-hosted-environments-deploy`
- [Customize sessions in self-hosted environments][config] — `https://code.claude.com/docs/en/self-hosted-environments-configuration`
- [Test self-hosted environments end to end][testing] — `https://code.claude.com/docs/en/self-hosted-environments-testing`
- [Self-hosted environments reference][reference] — `https://code.claude.com/docs/en/self-hosted-environments-reference`
- [Use Claude Code in the cloud][web] — `https://code.claude.com/docs/en/claude-code-on-the-web`
- [Configure cloud environments][cloudenv] — `https://code.claude.com/docs/en/cloud-environments`
- [Remote Control][remotecontrol] — `https://code.claude.com/docs/en/remote-control`
- [Claude pricing][pricing] — `https://claude.com/pricing`
- [Use Claude Code with your Team or Enterprise plan][teamdoc] — `https://support.claude.com/en/articles/11845131-use-claude-code-with-your-team-or-enterprise-plan`
- [Coder + Anthropic][coderanthropic] — `https://coder.com/partners/anthropic`
- [Coder Agent Relay documentation (v2.37)][coderrelay] — `https://coder.com/docs/ai-coder/agent-relay`
- [Coder blog: Agent Relay + Claude Code, 2026-09-15][coderblog] — `https://coder.com/blog/agent-relay-claude-code-agentic-development`
- [Fly.io Sprites documentation][spritesfly] — `https://docs.fly.io/sprites/`
- [Working with sprites][spritesdocs] — `https://docs.fly.io/sprites/working-with-sprites/`
- [Sprites product page and pricing][spritespage] — `https://fly.io/sprites/`
- [community.fly.io: Sprites base image][spritesimage] — `https://community.fly.io/t/sprites-base-image/26789`
- [Codex cloud environments][codexenv] — `https://learn.chatgpt.com/docs/environments/cloud-environment` (`developers.openai.com/codex/cloud/environments` redirects here)
- Installed CLI: `claude --version` (2.1.270) and `claude --help` in this devcontainer

[shenv]: https://code.claude.com/docs/en/self-hosted-environments
[quickstart]: https://code.claude.com/docs/en/self-hosted-environments-quickstart
[deploy]: https://code.claude.com/docs/en/self-hosted-environments-deploy
[config]: https://code.claude.com/docs/en/self-hosted-environments-configuration
[testing]: https://code.claude.com/docs/en/self-hosted-environments-testing
[reference]: https://code.claude.com/docs/en/self-hosted-environments-reference
[web]: https://code.claude.com/docs/en/claude-code-on-the-web
[cloudenv]: https://code.claude.com/docs/en/cloud-environments
[remotecontrol]: https://code.claude.com/docs/en/remote-control
[pricing]: https://claude.com/pricing
[teamdoc]: https://support.claude.com/en/articles/11845131-use-claude-code-with-your-team-or-enterprise-plan
[coderanthropic]: https://coder.com/partners/anthropic
[coderrelay]: https://coder.com/docs/ai-coder/agent-relay
[coderblog]: https://coder.com/blog/agent-relay-claude-code-agentic-development
[spritesfly]: https://docs.fly.io/sprites/
[spritesdocs]: https://docs.fly.io/sprites/working-with-sprites/
[spritespage]: https://fly.io/sprites/
[spritesimage]: https://community.fly.io/t/sprites-base-image/26789
[codexenv]: https://learn.chatgpt.com/docs/environments/cloud-environment
[refenv]: remote-implementer-environments.md
