# Three postures: dev, bot, and agent

Date: 2026-09-29

## Status

Proposed — awaiting the operator's ratification
([harmon-init#1408](https://github.com/evanharmon1/harmon-init/issues/1408),
criterion 1). The permission-model ADR
([#1264](https://github.com/evanharmon1/harmon-init/issues/1264)) is to link
this record once it is written; until then this record is the three-posture
model's only statement.

## Context

The platform named two postures, each a bundle of identity, permissions,
secrets, network, and environment:

- **dev** — a human at the keyboard, in `.devcontainer/dev/`: the operator's
  own `gh auth login`, the 1Password feature, Tailscale.
- **bot** — a headless agent on infrastructure the operator controls, in
  `.devcontainer/`: the bot's fine-grained PAT, blanket `Bash(git:*)` /
  `Bash(gh:*)`, bypass mode, Codex `danger-full-access`, Docker-in-Docker,
  and a bot-autonomy module per harness.

Neither fits an agent that runs **unattended somewhere the operator neither
watches nor controls** — a third-party cloud VM (Claude Code on the web, Codex
cloud, Sprites) or work on untrusted input. Bot is too permissive there; dev
assumes a human. Left alone, each remote environment would improvise its own
posture, which is the drift #1264 exists to stop.

Untrusted input enters this posture as **data** — issue text, diffs, pull
request content — never as the environment's own definition. The agent
devcontainer must be opened from a trusted checkout (the default branch or a
reviewed ref): `initializeCommand` runs the checkout's code on the host for
every profile, before any control below exists, so opening the agent
devcontainer on an untrusted branch hands that branch the host.

The operator decided on 2026-09-27 (recorded on #1408, with the 2026-09-27
amendment on PAT expiry) to add a third, first-class posture. The priority
order behind every choice below is the operator's: **autonomy first, then
least privilege — nothing may add a human step to an unattended run.**

## Decision

Add the **agent** posture. **Invariant: agent is a named, checked-in posture
that is never looser than bot on any axis**, defined once and installed
unchanged into its own devcontainer (`.devcontainer/agent/`) and into every
remote environment (the remote half is #1404).

| Axis | dev | bot | agent |
|---|---|---|---|
| **Marker** (`FOREMAN_DEVCONTAINER`) | unset | `bot` | `agent` |
| **Identity** | operator's `gh auth login` | bot fine-grained PAT (`GH_TOKEN`) | agent fine-grained PAT on the bot account (`AGENT_GH_TOKEN`), one per resource owner, ≤180 days, own repository list (remote-lane repos only); commits as the bot |
| **Permissions** | Claude prompts (managed allow list, no default mode) | blanket `Bash(git:*)`/`Bash(gh:*)` + gate tools, bypass mode | explicit dev-loop allow list; deny (not ask) for merge, release, repo admin, secrets, variables, workflow runs, `gh api` writes, force-push, pushes to `main`, `task release/secret`, disabling the Codex gate, `op`, `.env*` reads, and the egress-tamper commands (`sudo`, `iptables`, `nft`, `ipset`); **no `ask` rules**; only managed rules apply |
| **Harness autonomy** | per-harness defaults; Codex `workspace-write` + `on-request` | every installed harness fully autonomous (`bot-autonomy.sh`); Codex `danger-full-access` + `never` | Claude Code **auto mode** with `disableBypassPermissionsMode: "disable"`; Codex `workspace-write` + `never` (network on inside the sandbox); **every other harness refused** |
| **Secrets** | 1Password feature, `TS_AUTHKEY`, operator login, opt-in provider keys | bot `GH_TOKEN`, `FOREMAN_AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, opt-in provider keys; no `TS_AUTHKEY`, no 1Password | only `AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, where persisted the environment's own Codex login (#1406), and the disclosed opt-in provider keys; `ANTHROPIC_API_KEY` never; **the env guard fails closed on anything else** |
| **Network** | open; tailnet | open | **default-deny egress allowlist, enforced at every start** from a root-owned snapshot taken at create; one shared list (#286) plus per-repo additions; refused destinations recorded for the lane report |
| **Docker** | Docker-in-Docker | Docker-in-Docker | **none by default**; a per-repo, disclosed Docker-in-Docker opt-in; never the host socket |

Mechanically:

1. **One source.** The agent Claude managed settings and Codex managed config
   live only in `.devcontainer/config/agent/`. The agent devcontainer installs
   them over the image's managed files at create (`agent-autonomy.sh apply`)
   and re-verifies them at every start; `scripts/test-agent-profile.sh` fails
   if any other file carries a copy. The remote bootstrap installs from the
   same directory in #1404.
2. **Auto mode, not bypass.** Auto mode never prompts headless, and with
   bypass disabled the classifier stays a second layer behind the deny rules.
   `allowManagedPermissionRulesOnly` keeps a repository's own settings from
   adding rules — including the `ask` rules a repository keeps for its
   interactive users, which would stall an unattended run.
3. **Refusal, not neglect.** A harness runs under the agent marker only
   through a configuration that makes it agent-capable, and the criterion
   differs per harness (the operator's Harnesses decision on #1408):
   - **Claude Code** — its managed allow and deny rules
     (`claude-managed-settings.json`): the explicit allow list, the deny
     rules in the table, no `ask` rule, and managed rules only.
   - **Codex** — its sandbox: `workspace-write`, never `danger-full-access`,
     with approval `never` (`codex-managed-config.toml`). Codex carries **no
     command-level deny list**; inside the sandbox it may run any command. For
     Codex the GitHub-write boundary is therefore the agent PAT's scopes plus
     the repository rulesets (see Consequences), never a rule.

   Every other harness is refused: its executable is made non-executable at
   create, and a start fails if one is runnable again. Every
   `agent-registry.json` harness is classified supported, aliased, or refused.
   Refusal is a **launcher control, not a sandbox**: it stops an orchestrator
   or operator from starting a refused harness under the agent marker, not an
   agent that deliberately runs one through an interpreter or a fresh
   install. It also rests on a file mode that root can restore;
   [#1432](https://github.com/evanharmon1/harmon-init/issues/1432) tracks
   making it independent of one.
4. **The env guard fails closed.** `init-env.sh --profile agent` stops the
   build — naming the variable, never its value — when the allow-list or the
   env-file holds anything the posture does not admit. Bot and dev quietly
   evict instead; agent refuses, because nobody is watching to notice a
   repaired misconfiguration. The agent PAT has a host-side name distinct
   from the bot's `GH_TOKEN`, so a host exporting the bot token cannot leak it
   into the agent env-file by name.
5. **Egress is default-deny, and fails closed.** The container gets
   `NET_ADMIN`; `egress-allowlist.sh` resolves the list and installs the
   filter first thing in both lifecycle scripts, before any harness can start,
   and a failure to install it fails the container. "Fails closed" means
   exactly this: every path that is meant to establish the filter — `apply`,
   post-create's `establish` (snapshot, then apply the snapshot), and
   post-start's apply of that snapshot — when it does not complete, whether
   it stopped at the iptables install, a refused list, a failed rule, a
   failed verify, a signal, or a missing snapshot, flushes the filter
   chain's allow rules and sets the OUTPUT and FORWARD policies to DROP for
   every address family the container has (IPv4 always, IPv6 when it has a
   global address). It reports egress left at DROP only when every one of
   those steps succeeded; otherwise — iptables itself failing to install, or
   any DROP or flush step failing — the step prints a CRITICAL line instead
   and fails. In every case the create or
   start fails, and **a container whose create or start failed must not be
   used**. The same filter hooks
   Docker's `DOCKER-USER` chain, so a Docker-in-Docker opt-in cannot route
   around it. Post-create copies the applier and both lists out of the
   writable checkout into a root-owned snapshot
   (`/usr/local/share/harmon-egress/`), and every start applies that
   snapshot, never the checkout — so a plain file edit cannot widen egress at
   the next start. A list line that is `0.0.0.0` in any form, or a CIDR wider
   than `/16`, fails `apply` closed, naming the line; so does such a range in
   the `@github-meta` response, naming the source and the range, since a
   fetched range becomes a rule unreviewed.
6. **Foreman stays out.** Its D2 tripwire refuses to run anywhere the marker is
   not `bot`, so it refuses the agent posture by design. Making agent the
   Foreman dispatch default is #1264's call once this exists.

**Not:**

- **A GitHub App installation token (#362) for this posture.** Minting one
  needs either the App's private key inside the environment or a broker the
  environment must reach; both cost autonomy for little gain.
- **Reusing the bot's `GH_TOKEN`.** The agent token must rotate and revoke
  independently, with a shorter life and a narrower repository list.
- **Bypass mode with a deny list.** It works, but it drops the classifier's
  second look; auto mode keeps both layers and still never prompts.
- **`ask` rules for the dangerous operations.** An `ask` prompts even in
  bypass and auto mode and stalls an unattended run; deny is the only
  unattended-safe answer.
- **Codex `danger-full-access`.** That is the bot's setting and relies on the
  container alone; agent keeps the Codex sandbox as a second boundary.
- **Forking the Dockerfile.** Agent builds from the same shared image and the
  same profile-invariant `.devcontainer/Dockerfile` as bot and dev; only its
  config and lifecycle scripts differ.
- **An HTTP proxy for egress.** It would need every tool to honor proxy
  settings and a daemon to supervise; an address filter needs neither.
- **A Copier question for Docker.** The opt-in is a deliberate, reviewed edit
  to the repository's agent `devcontainer.json`, documented in
  `docs/guides/devcontainers.md` and marked by `HARMON_AGENT_DOCKER=dind`.

## Consequences

- "What may an unattended agent do" has one answer, and the tests make
  loosening it a visible failure: the agent allow list must stay inside bot's
  allow list and outside any bot deny rule.
- **Residuals, stated plainly: where the boundaries are.** The posture has
  one first layer and two boundaries, and only the boundaries are claimed as
  such.
  - **Command-level denies are a best-effort first layer for a cooperating
    harness.** Claude Code's deny rules (Codex has none — item 3) match the
    command a harness is about to run. They are not transitive through
    repository code: an agent allowed `task` and commits runs Taskfile
    targets and git hooks, and no deny rule follows a command into either.
    Pattern matching can also miss another spelling of the same flags —
    bundled short flags, for one. The `gh api` denies are this layer: the
    method, input, and every form-field flag (`-f`, `-F`, `--field`,
    `--raw-field`) are denied in any position, which also denies GraphQL
    queries sent through `-f query=` (REST is the documented read path). They
    keep a cooperating harness to reads; they do not make `gh api` read-only.
  - **The boundary for GitHub writes is the agent PAT's scopes plus the
    repository rulesets.** The PAT has no administration, secrets, or workflow
    permission, so no route reaches those. The rulesets refuse a direct or
    force push to `main` for every actor, and a merge to `main` needs
    code-owner approval and green required checks. A bare `git push` while on
    `main` is not expressible as a rule; the ruleset and the no-commit-to-main
    hook bound it. Disclosed plainly: the rulesets do not stop the PAT from
    merging — once a human has approved and the checks pass, its
    `pull_requests: write` can perform that merge; and its `contents: write`
    lets it create releases and push to any branch no ruleset protects, by any
    route, because a fine-grained PAT cannot separate releases from contents.
  - **The boundary for the network is the egress filter**, with one residual.
    The filter lives inside the container and needs `NET_ADMIN`; the container
    user keeps passwordless `sudo` (the shared lifecycle scripts use it). So
    the filter — and the root-owned snapshot it applies from — holds against a
    harness's own tools, where Claude Code's deny rules cover `sudo` and the
    filter commands, but not against repository code run with root: a Taskfile
    target or git hook can call `sudo`. That root residual is tracked in
    [#1432](https://github.com/evanharmon1/harmon-init/issues/1432). DNS is
    allowed to the configured resolvers, so DNS remains a narrow channel.
    Addresses are resolved at start, so a CDN rotating addresses mid-run can
    refuse a listed host until the next `apply`. On a user-defined Docker
    network or a compose setup, `resolv.conf` points at Docker's embedded
    resolver (`127.0.0.11`), whose upstream queries are not in the allow set,
    so DNS resolution fails once the filter installs; the supported setup is
    the default bridge network.
- The operator mints the agent PATs (one per owner, ≤180 days, on the bot
  account) and ratifies this record; an unattended agent-devcontainer lane
  returning its work to the orchestrator with no human step after launch is
  the posture's acceptance test (#1408, criteria 1 and 7).
- #1404 installs this posture into each remote platform; #1407 documents the
  hosted platforms' network levels from the same shared list.
