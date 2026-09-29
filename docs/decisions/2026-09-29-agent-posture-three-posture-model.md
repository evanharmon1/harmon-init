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
| **Permissions** | Claude prompts (managed allow list, no default mode) | blanket `Bash(git:*)`/`Bash(gh:*)` + gate tools, bypass mode | explicit dev-loop allow list; deny (not ask) for merge, release, repo admin, secrets, variables, workflow runs, force-push, pushes to `main`, `task release/secret`, disabling the Codex gate, `op`, `.env*` reads, and the egress-tamper commands (`sudo`, `iptables`, `nft`, `ipset`); **no `ask` rules**; only managed rules apply |
| **Harness autonomy** | per-harness defaults; Codex `workspace-write` + `on-request` | every installed harness fully autonomous (`bot-autonomy.sh`); Codex `danger-full-access` + `never` | Claude Code **auto mode** with `disableBypassPermissionsMode: "disable"`; Codex `workspace-write` + `never` (network on inside the sandbox); **every other harness refused** |
| **Secrets** | 1Password feature, `TS_AUTHKEY`, operator login, opt-in provider keys | bot `GH_TOKEN`, `FOREMAN_AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, opt-in provider keys; no `TS_AUTHKEY`, no 1Password | only `AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, where persisted the environment's own Codex login (#1406), and the disclosed opt-in provider keys; `ANTHROPIC_API_KEY` never; **the env guard fails closed on anything else** |
| **Network** | open; tailnet | open | **default-deny egress allowlist, enforced at every start**; one shared list (#286) plus per-repo additions; refused destinations recorded for the lane report |
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
3. **Refusal, not neglect.** A harness that cannot express the deny list is
   refused under the agent marker: its executable is made non-executable at
   create, and a start fails if one is runnable again. Every
   `agent-registry.json` harness is classified supported, aliased, or refused.
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
   and a failure to install it fails the container. The same filter hooks
   Docker's `DOCKER-USER` chain, so a Docker-in-Docker opt-in cannot route
   around it.
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
- **Residuals, stated plainly.** The egress filter lives inside the container
  and needs `NET_ADMIN`; the container user keeps passwordless `sudo` (the
  shared lifecycle scripts use it), so the filter bounds what the harnesses
  reach through their own permission layers — which deny `sudo` and the
  filter commands — and is not a boundary against root in the container.
  Narrowing `sudo` is follow-up work. DNS is allowed to the configured
  resolvers, so DNS remains a narrow channel. Addresses are resolved at start,
  so a CDN rotating addresses mid-run can refuse a listed host until the next
  `apply`. `gh api` writes that use form fields are not denied by rule (they
  share syntax with GraphQL reads); the agent PAT's own permissions bound
  them. A bare `git push` while on `main` is not expressible as a rule; the
  branch ruleset and the no-commit-to-main hook bound it.
- The operator mints the agent PATs (one per owner, ≤180 days, on the bot
  account) and ratifies this record; an unattended agent-devcontainer lane
  returning its work to the orchestrator with no human step after launch is
  the posture's acceptance test (#1408, criteria 1 and 7).
- #1404 installs this posture into each remote platform; #1407 documents the
  hosted platforms' network levels from the same shared list.
