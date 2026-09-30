# Codex cloud

One Codex cloud environment per repository, set up to run the repo's own gate
from the shared bootstrap — a task running the gate to completion there has not
been observed yet (criterion 2, pending) — and what is known, and not yet known,
about how OpenAI's two generations of Codex cloud behave.

Read this when creating or editing the environment in ChatGPT, when a Codex
cloud task or review reports a missing tool or a blocked download, or when
deciding what to send to Codex cloud. The contract the setup script honours
(every tool installed by the same script, from the same pin, as the shared
image) is
[architecture/remote-environments.md](../architecture/remote-environments.md);
this is the Codex-cloud-specific *procedure* and record. The Claude Code
counterpart, whose structure this follows, is
[claude-code-web.md](claude-code-web.md).

## How to read the evidence in this guide

Every platform fact carries where it came from, because the platform changes,
its documentation is moving, and some facts here have not been seen by a person
yet:

| Tag | Meaning |
| --- | --- |
| **docs (legacy), 2026-09-29** | Stated by the pages OpenAI titles **Codex Cloud (Legacy)**: [environment configuration](https://learn.chatgpt.com/docs/environments/cloud-environment) and [internet access](https://learn.chatgpt.com/docs/cloud/internet-access), re-read on that date |
| **docs (current), 2026-09-29** | Stated by the current [Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environments) page, re-read on that date |
| **docs (GitHub), 2026-09-29** | Stated by [Review GitHub pull requests with Codex](https://learn.chatgpt.com/docs/third-party/github), re-read on that date |
| **docs (CLI), 2026-09-29** | Stated by the [developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli) page, re-read on that date |
| **observed 2026-09-27** | Seen in a real Codex cloud task, recorded in the connector's own comments on [#1402](https://github.com/evanharmon1/harmon-init/issues/1402#issuecomment-5860661367) and [#1406](https://github.com/evanharmon1/harmon-init/issues/1406#issuecomment-5860668523) |
| **observed 2026-09-29 (local CLI)** | Printed by `codex --help` on `codex-cli 0.157.1` in the maintainer's devcontainer. That is the local client, not the cloud |
| **expected, not yet observed** | Derived from the docs or from how a script is written. **Not** an observation |
| **pending** | A `[HUMAN]` acceptance criterion of #750, or another observation, that needs a provisioned environment and live tasks run by the maintainer. Each has a marked place below and a row in [Pending observations](#pending-observations) |

The docs moved while this was written: the `developers.openai.com/codex/…`
addresses answer a permanent redirect to `learn.chatgpt.com/docs/…`. Where the
docs contradict the issue text or each other, the docs win as the *documented*
behaviour and this guide says so.

Nothing marked *expected* or *pending* should be relied on as fact.

## Two generations of Codex cloud

OpenAI documents two environment experiences, and which one a surface uses
decides which part of this guide applies.

| | **Codex Cloud (Legacy)** | **Codex Cloud (current)** |
| --- | --- | --- |
| Configuration | a **setup script**, an optional maintenance script, environment variables, and **secrets** (*docs (legacy), 2026-09-29*) | an **install script** and a **start skill**, environment variables, and **network secrets** (*docs (current), 2026-09-29*) |
| Secrets | encrypted, "only available to setup scripts", removed before the agent phase (*docs (legacy)*) | a network secret is a credential the proxy substitutes on HTTPS requests to allowed destinations, during setup **and** tasks (*docs (current)*) |
| Network | setup always has internet; the agent phase is **Off**, **On** (allowlist preset *None* or *Common dependencies*, optionally GET/HEAD/OPTIONS only) or **Unrestricted** (*docs (legacy)*) | **Restricted** (a package-manager preset), **Custom domains**, or **Unrestricted** (*docs (current)*) |
| Used by | **Code Review** and the **GitHub** and Linear integrations: "Codex Cloud (Legacy) continues to support Code Review and the Linear and GitHub integrations. We plan to deprecate this experience" (*docs (current)*); a mention that is not a review "starts a legacy cloud chat using your pull request as context" (*docs (GitHub)*) | tasks started from the web, desktop or mobile app (*docs (current)*) |
| `codex cloud exec --env <id>` | **not stated** by any page | **not stated** by any page |

Three consequences for this repository:

1. **Cloud reviews and the documented GitHub-integration surfaces —
   mention-started tasks — run in the legacy environment**, so the
   [environment](#the-environment) below is written for it. That is where a
   setup script, and the secrets model the issue cites, exist. Which generation
   the `codex cloud exec` lane targets is not stated (the next item), so
   criterion 4 may need the current-generation configuration as well.
2. **Which generation a task submitted with `codex cloud exec` runs in is
   unknown.** The docs describe the flag as the "target Codex cloud environment
   identifier" and say nothing more. It is a
   [pending observation](#pending-observations), because the answer decides
   whether the environment below or a current-generation one (an install script,
   not a setup script) has to be provisioned for the implementer lane.
3. **The legacy experience is announced for deprecation.** This guide is
   written against it because it is the one the surfaces above use today; when
   OpenAI moves Code Review and the GitHub integration, the environment moves
   with them and this guide has to follow.

## The environment

The setup script is the whole adapter. Create the environment for the
repository in ChatGPT's Codex settings; the docs name no other route
(*docs (legacy), 2026-09-29*). The recipe does not read the repository, so every
repository's environment carries the same script.

| Field | Value |
| --- | --- |
| **Setup script** | the block below |
| **Maintenance script** | none. The bootstrap is idempotent and pinned by tag, so there is nothing to refresh when a cached container resumes |
| **Agent internet access** | **Off** to start; see [Network](#network) |
| **Environment variables** | see [Environment variables](#environment-variables); none is a secret |
| **Secrets** | none |

### Setup script

The script is the entrypoint from
[architecture/remote-environments.md § The entrypoint](../architecture/remote-environments.md#the-entrypoint),
unchanged.

```bash
#!/bin/bash
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
  && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
    -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
  && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
```

Rules for this script, each with its reason:

- **The first line is a shebang.** The setup-script field is treated as a script
  file of its own, which is why the block opens with `#!/bin/bash`
  (*expected, not yet observed*). It is inert if the platform sources the field
  instead, where it reads as a comment. It is the only line this block adds to
  the architecture document's recipe.
- **Pin a release tag, never `main`.** The bootstrap refuses anything that is not
  `vX.Y.Z`. The tag is the trust root. Changing the script also resets the
  container cache (*docs (legacy), 2026-09-29*: cache invalidation happens when
  the setup or maintenance script, the variables or the secrets change), so the
  environment moves only when you edit the tag.
- **`vX.Y.Z` must be the first release that carries the bootstrap.** The
  bootstrap landed in #1426; the latest tag when this guide was written is
  `v4.47.1`, which predates it, and the release PR
  ([#1398](https://github.com/evanharmon1/harmon-init/pull/1398), proposing
  `4.48.0`) is not merged. A proposal is not a tag: **replace `vX.Y.Z` with the
  tag the release publishes, and only then use the environment.** Until that
  happens this section is not runnable as written, and #750's first acceptance
  criterion stays open for exactly that reason.
- **Do not append `|| true`.** A setup that leaves the pinned toolchain missing
  would run the gate against the platform's stock tools and pass or fail for the
  wrong reasons. Whether the platform fails a task's start on a non-zero exit is
  not stated in the docs read; treat that as a
  [pending observation](#pending-observations) and read the setup log.
- **Keep the download its own command.** Piping `curl` into a shell exits 0 when
  the download fails. `scripts/test-bootstrap-remote.sh` checks that shape in
  every copy of the recipe, and holds this one equal to the architecture
  document's line for line; the leading `#!/bin/bash` and the pinned tag are the
  only differences it allows.
- **The default tiers only** (`core,agents`), no `--tiers` flag, and no other
  install lines. Anything the gate needs belongs in the shared scripts, so the
  image and every other remote adapter get it too.
- **Do not export anything from it and expect the agent to see it.** The docs say
  the setup script runs "in a separate Bash session from the agent, so commands
  like `export` do not persist into the agent phase" (*docs (legacy),
  2026-09-29*). The bootstrap is written for that: its `PATH` and locale work is
  a `/etc/profile.d` drop-in and `/etc/environment`, which are files and so
  survive. Whether the agent's shell *reads* them is the open question in
  [the pending observations](#pending-observations).

**Not stated by the docs, and therefore pending:**

- *Root and `sudo`.* The recipe runs `sudo bash`, and the bootstrap accepts root
  or a user with `sudo`. The docs say neither which user the setup script runs as
  nor whether `sudo` exists. If the script runs as root in an image without
  `sudo`, the recipe fails at its last command; the remedy would then be a
  change to the shared recipe in the architecture document, checked in one place,
  not a Codex-only edit of this block.
- *The setup time limit.* The Claude Code on the web platform documents about
  five minutes for its cached setup. The Codex cloud pages read state a cache
  lifetime of up to 12 hours and no setup timeout. The bootstrap has been proven
  only in CI on a stock `ubuntu:24.04` container on a GitHub-hosted runner.
- *The base image.* The docs name a pre-installed `universal` image and point at
  [`openai/codex-universal`](https://github.com/openai/codex-universal), which
  its own README calls "a reference implementation" that is "not an identical
  environment". The bootstrap has not been run on it, and whether its Node,
  Python and Go tooling puts anything ahead of `/usr/local/bin` in the agent's
  `PATH` — the same class of trap as the Python `yq` on the Claude Code VM — is
  not known.

**Pending observation (criterion 1, the pinned tag and the caching claim):**
record the release tag, the setup log's exit, its duration, and which user it ran
as. Record it under [Pending observations](#pending-observations).

### Network

The bootstrap's downloads happen in the **setup phase**, and setup "still run[s]
with internet access so you can install dependencies" whatever the agent-phase
setting (*docs (legacy), 2026-09-29*). So the agent-phase level is not decided
by the bootstrap's host list. It is decided by what the gate does when it *runs*,
and it is the narrowest level that lets the gate finish. The 2026-09-27 failure
that motivated this (a Go Task install blocked by the egress policy, observed
2026-09-27) was an install attempted *by the agent*, in the agent phase; putting
the install in the setup script is the fix, not widening the agent's network.

| Level | Use it when | Why |
| --- | --- | --- |
| **Off** — the starting point | `task verify` and the checks that run entirely inside the checkout | expected, not yet observed: the gate renders the template from the local checkout and lints it, and the bootstrap has already installed every tool it needs. Off also removes the prompt-injection and exfiltration risks the docs list for agent internet access (*docs (legacy), 2026-09-29*) |
| **On**, preset **None**, plus named domains | a task needs a host the gate contacts, and a task has been *recorded* denied on it | a domain is added only after a recorded denial, with the denial written in the table below. Restrict methods to `GET`, `HEAD` and `OPTIONS` unless the denial is a write |
| **On**, preset **Common dependencies** | only as a fallback if named domains prove unworkable | the preset covers the bootstrap's own hosts by parent domain — `github.com`, `githubusercontent.com`, `nodejs.org`, `ubuntu.com`, `npmjs.org`, `pypi.org`, `pythonhosted.org`, `golang.org`, `hashicorp.com` (*docs (legacy)*, a 69-domain list) — but **not** `cdn.playwright.dev`, and the docs do not say that a listed domain admits its subdomains. Broader than the gate needs |
| **Unrestricted** | never | gives up the allowlist |

Domains that may be added, each with the reason and where the denial must be
recorded before it is added:

| Host | Needed for | Added? | Reason |
| --- | --- | --- | --- |
| `semgrep.dev` | `task security`'s Semgrep step | **No, until a task is recorded denied on it.** Expected, not yet observed for Codex cloud; observed 2026-09-27 for Claude Code on the web | `task security` must pass before a draft PR (`AGENTS.md`). A Codex cloud lane that returns a diff to the orchestrator leaves the gate to the machine that opens the PR — see [What Codex cloud is used for](#what-codex-cloud-is-used-for) — so the host is only needed if a task is asked to run the security gate itself |
| the bootstrap's [allowed hosts](../architecture/remote-environments.md#the-network-the-bootstrap-may-use) | setup phase | **Not an agent-phase entry** | setup has internet whatever the level. They matter to the agent phase only if a task re-runs the bootstrap |
| `api.openai.com`, `auth.openai.com`, `chatgpt.com` | the Codex CLI inside a session | **No** | Codex cloud *is* Codex; nothing inside the task logs in (#1408 decision 4) |
| `deb.nodesource.com`, `astral.sh`, `keybase.io`, `ppa.launchpadcontent.net`, `cli.github.com`, `dl.google.com` | installer hosts (#1403) | **No** | The bootstrap no longer contacts them; the denied table in the architecture document is guarded so they cannot return |

**Pending observation (criterion 2):** run `task verify` in the provisioned
environment at **Off**, and write down every denial. Each domain that must be
added goes in the table above with the denial that justifies it, and the level
becomes **On** with preset **None**.

### Environment variables

The environment needs none for the bootstrap. Variables "remain available
throughout the entire chat duration" (*docs (legacy), 2026-09-29*), so **none may
be a secret**: anything set here is visible to the agent.

| Variable | Value | Why | Status |
| --- | --- | --- | --- |
| `LANG` | `C.UTF-8` | The bootstrap fixes `/etc/environment` and login shells, but a process the agent phase starts may read neither, and a non-UTF-8 locale silently changes what Unicode checks accept (observed on the Claude Code VM, 2026-09-27; the Codex image has not been probed) | expected, not yet observed |

The docs' own way to keep a setup-time environment for the agent is to add it to
`~/.bashrc` or the environment settings. If the observation below shows the
agent's shell does not read the bootstrap's `/etc/profile.d` drop-in, a line in
the setup script sourcing `/etc/profile.d/harmon-remote-env.sh` from `~/.bashrc`
is the candidate remedy. It is **not** part of the script above: the script is
held equal to the entrypoint, so the remedy needs the observation first and then
a decision on where it lives.

## Identity and secrets

The policy, in order of precedence:

1. **No 1Password, and no other credential store.** The bootstrap never installs
   `op`, and a shared remote VM must not hold a credential-bearing tool. Nothing
   in a Codex cloud task writes to a password manager.
2. **The environment holds no secret.** The legacy secrets field is
   setup-script-only and removed before the agent phase (*docs (legacy),
   2026-09-29*), which is what makes *none* the right number for the gate: the
   agent phase could not use one anyway. The current generation's network
   secrets are different — a proxy substitutes them on HTTPS requests during
   tasks (*docs (current), 2026-09-29*) — and none is needed for the gate. The
   environment holds none, and adding a network secret is a change to the agent
   posture: it needs a decision recorded on
   [#1408](https://github.com/evanharmon1/harmon-init/issues/1408) first, with its
   scope stated, before it is added and recorded in the table above.
3. **GitHub access is whatever the Codex connector grants**, and nothing is
   configured here. Its comments arrive under the connector's bot identity
   (`chatgpt-codex-connector[bot]`, observed 2026-09-27). The lane is used on
   the basis that a Codex cloud task does not open a pull request: the
   orchestrator pushes the branch and owns the PR. That is a **decision recorded
   in #750 on 2026-09-27** about how the lane is used, not an observation of what
   the connector's write permissions allow. What they allow is *expected, not yet
   observed*, and is a row in [Pending observations](#pending-observations).
4. **No Codex login is ever needed *inside* the task.** Ephemeral clouds never
   hold a Codex login (#1408 decision 4, 2026-09-27); here the platform *is* the
   login. The local `codex` client that submits and applies tasks uses the
   maintainer's own ChatGPT login, from the orchestrator's pane, never from a
   cloud environment.

## What starts a Codex cloud task

**Whatever the platform does with a Codex mention — the at-sign followed by the
word `codex` — an agent writing GitHub text never writes the literal mention,
in a comment or a body, on an issue or a pull request, unless it means to start
a Codex cloud task or review.** That is a precaution, and it holds whether or not
every row below is confirmed. A task or review it starts runs in the environment
above.

What each surface is documented or observed to do, and what is only expected,
without making the guide something a mention could match:

| Where | What is known | Status |
| --- | --- | --- |
| A pull request comment | a mention with anything other than a review request "starts a legacy cloud chat using your pull request as context"; with a review request it runs a code review (*docs (GitHub), 2026-09-29*) | docs |
| An **issue** comment | mentions in comments on issues #1402 and #1406 started tasks, and the connector replied with a task link (observed 2026-09-27) | observed 2026-09-27. The docs read describe only pull requests |
| An issue or pull request **body** | the docs read say nothing. #750 records that a mention there also starts a task | expected, not yet observed. The precaution above does not depend on it |
| A quoted, fenced or code-spanned mention | the docs read say nothing about whether the connector ignores it | unknown. The precaution above covers every occurrence |

The rule costs nothing to follow: say "the at-sign followed by `codex`", or "a
Codex mention", in words, and never write the literal mention in a commit message
either. An accident costs a task, and the reviewer's usage limit (the reviewer
answered with a usage-limit notice on 2026-09-29). The one deliberate use — the
integration stage's review request on a draft PR — is specified in
[codex-review.md](codex-review.md) and `AGENTS.md`; this guide does not restate
its wording for the same reason.

## What Codex cloud is used for

Two roles, decided on 2026-09-27
([#1408, decision 5](https://github.com/evanharmon1/harmon-init/issues/1408#issuecomment-5862697420)):

- **A review environment first.** Cloud reviews and mention-started tasks run in
  the legacy environment above (*docs (current), 2026-09-29*; see
  [Two generations](#two-generations-of-codex-cloud)). Before it was provisioned they could reason
  about the code but not execute it, and reported gaps as an "environment
  limitation": `task`, copier and shellcheck unavailable, and a Go Task install
  blocked by the egress policy (observed 2026-09-27, on #1402 and #1406). After
  it, a review is expected to run at least one repo check; that is criterion 3.
- **An implementer lane**, run from the orchestrator. It submits a task with
  `codex cloud exec`, pulls the result into a local worktree, and hands it to its
  normal review and integration loop, which owns the PR. The orchestrator side
  belongs to the orchestrate skill
  ([harmon-devkit#1215](https://github.com/evanharmon1/harmon-devkit/issues/1215));
  this guide makes the *environment* able to run the gate for those tasks. A lane
  therefore completes its **role**, not the PR, as on the other remote platforms.
  See [the posture section](#the-agent-posture-as-far-as-codex-cloud-can-express-it)
  for what the lane waits on.

### The agent posture, as far as Codex cloud can express it

The agent posture ([#1408](https://github.com/evanharmon1/harmon-init/issues/1408),
in review at the time of writing) is decided as: no 1Password, no bot or operator
token, an enforced egress allowlist, a permission deny list for merge, release
and secrets, and Codex under `-a never -s workspace-write`. What each axis maps
to here:

| Axis | In Codex cloud | Status |
| --- | --- | --- |
| Secrets | none in the environment; legacy secrets are setup-only | docs (legacy), 2026-09-29 |
| Network | the agent-phase level and, under **On**, an allowlist and a method limit | docs (legacy), 2026-09-29. The list is per environment |
| Identity | the connector's bot; no token of ours | observed 2026-09-27 |
| Permissions | **cannot be expressed** as the deny list: no page read gives an environment a permission or approval configuration. The setup script's bootstrap installs the agent Codex configuration to `/etc/codex/managed_config.toml` ([architecture](../architecture/remote-environments.md#the-agent-posture)), which pins `workspace-write` and approval `never` but carries no deny list, because the Claude deny list has no Codex equivalent. Whether the cloud agent reads a managed config written in the setup phase is **unproven**; see the check below. A file the platform already put at that path is left in place and the posture reported as not applied for it, unless the setup script sets `HARMON_AGENT_POSTURE_REPLACE=1`. The bootstrap refuses no harness here: it never changes a harness executable's mode on a platform VM, and the platform runs Codex and nothing else. Its hook commands name the agent image's hook scripts, which the bootstrap does not install | delivery: expected, not yet observed — pending, #1404 criterion 3. A harness that cannot express the deny list is refused in the agent profile (#1408), so this needs the decision recorded there, not improvised here |
| Sandbox mode | **current generation:** "each new task gets its own isolated workspace from the published environment" (*docs (current), 2026-09-29*). **Legacy:** the page says only that Codex "creates a container and checks out your repo" for a chat (*docs (legacy), 2026-09-29*) and states no isolation property. Reviews and mention-started tasks run in the legacy environment, so its isolation, and that it is not the CLI's `workspace-write`, are expected, not yet observed | docs (current), 2026-09-29; legacy: expected, not yet observed |
| Docker | not needed by the gate; the bootstrap does not install it | [architecture](../architecture/remote-environments.md#tiers). Whether the cloud image has one is unknown |

**What holds for every use of the environment.** For every task that runs in it,
whatever started it, the environment's configuration adds no secret, no token of
ours and no permission of its own; it adds the installed tools and the agent-phase
network level. What a task may do on GitHub is whatever the platform's connector
grants, which is expected, not yet observed
([Pending observations](#pending-observations)). Both roles are decided uses
(#1408 decision 5), and cloud reviews and mention-started tasks already run on this
repository's pull requests through the platform's connector whether or not the
environment is provisioned (*docs (GitHub), 2026-09-29*; a connector task was
observed 2026-09-27 on issues), so provisioning is expected not to change what
the connector lets them write (expected, not yet observed); it changes what they
can execute. The consideration this raises:
once the environment is provisioned, a review is expected to execute repository
checks (expected, not yet observed; criterion 3), and for a pull request from an
untrusted author those checks are that pull request's repository code, run inside
the environment. What bounds it is the table
above (no secret, no token of ours, the configured agent-phase network level) plus
the platform's own per-task isolation, which for the legacy environment is
expected, not yet observed. The connector's write permissions are not a bound this
guide can state until they are observed. The permissions axis is the one axis not
yet decided (the Permissions row). Until that decision is recorded on
[#1408](https://github.com/evanharmon1/harmon-init/issues/1408):

- reviews and mention-started tasks continue as they already run;
- the implementer lane is not sent work;
- the guide provisions the environment and does not by itself authorize sending
  the lane work.

**Pending observation (#1404 criterion 3):** in a Codex cloud task in an
environment whose setup script ran the bootstrap, ask the task to run
`cat /etc/codex/managed_config.toml` and report its sandbox mode and approval
policy as the running agent sees them. Record whether the file is present in
the agent phase and whether the running agent's settings match it. Where they
do not, record which parts Codex cloud cannot express and what enforces them
instead (the platform's per-task isolation, the agent-phase network level, the
connector's permissions). Note the date and the `codex` version.

Observed:  *pending*

## Bridges between the terminal and Codex cloud

These need the local Codex client signed in with the maintainer's own ChatGPT
account, from a pane on a machine the maintainer controls.

| Step | Command | What it does |
| --- | --- | --- |
| Submit | `codex cloud exec --env <ENV_ID> [--branch <BRANCH>] [--attempts 1-4] "<prompt>"` | "Submit a new Codex Cloud task without launching the TUI". `--branch` "defaults to current branch", so **push first**: the task runs on the GitHub branch, not the local checkout (expected, not yet observed) |
| Find the environment | `codex cloud` | the interactive picker; `exec` says "see `codex cloud` to browse" |
| Poll | `codex cloud status <TASK_ID>`, `codex cloud list --json` | `list --json` returns `tasks` with `id`, `url`, `title`, `status`, `updated_at`, `environment_id` and `summary` (*docs (CLI), 2026-09-29*) |
| Read | `codex cloud diff <TASK_ID>` | prints the unified diff |
| Apply | `codex cloud apply <TASK_ID>` (also `codex apply <TASK_ID>`) | applies the task's latest diff to the local working tree as a `git apply`, so the result is **uncommitted changes**, not a commit |

The exact set of subcommands is what the local CLI printed on 2026-09-29
(`codex-cli 0.157.1`: `exec`, `status`, `list`, `apply`, `diff`, marked
`[EXPERIMENTAL]`). The docs read list only `exec` and `list`, plus a separate
`codex apply`, so #750's `codex cloud apply` is real in the client and simply
undocumented. Treat the help output of the pinned CLI, not either page, as the
contract, and re-read it when the pin moves.

**Pending observation (criterion 4):** from a local worktree, submit a task that
runs the gate, apply its diff to a second clean worktree, and record whether the
diff applied cleanly with **no human step** — no prompt in the client, no click in
the web app. Also record which environment generation the task ran in and which
`--env` id it took.

Observed:  *pending*

## Long-running gates

A full `task verify` takes about **10–15 minutes on this repository's devcontainer**
(measured locally; `docs/guides/claude-code-web.md` records 10–12 minutes on the
4-core Claude Code VM). The docs read give a Codex cloud task's VM as 4 vCPUs,
16 GiB and 32 GiB of disk on Pro, Business and Enterprise, and 2 vCPUs, 8 GiB and
8 GiB on Plus (*docs (current), 2026-09-29*, the current generation; the legacy
pages give no figure). They state no per-command or per-task time limit.

The shape that survives a lost foreground is the one this repository's lane
briefs use, unchanged:

```bash
log="$(mktemp -d)/verify.log"
nohup bash -c 'task verify; echo GATE-EXIT=$?' > "$log" 2>&1 & disown
echo "$log"
```

then read `$log` until it contains `GATE-EXIT=<code>`; that line, not the absence
of output, is the result. The log is per run (`mktemp -d`), so an older detached
run's exit line cannot satisfy this poll. The single quotes are load-bearing:
inside double quotes the calling shell expands `$?` first, and a failed verify
could print `GATE-EXIT=0`. Whether a Codex cloud task stops a detached process when it ends,
and whether it has a wall-clock limit that a 15-minute gate exceeds, is not
stated: a **pending observation** under criterion 2.

`task security` is owed before a draft PR whoever runs it; the lane shape above
leaves it to the machine that opens the PR.

## When per-checkout preparation runs

The setup script provisions the **container**; the docs say the repository is
checked out for the chat and that a cached container "checks out the branch
specified for the chat", running the maintenance script when setup ran on an
older commit (*docs (legacy), 2026-09-29*). They do not say whether the
repository exists when the *first* setup script runs. So the same rule as for the
other remote platforms holds: the setup script is machine-level and
repository-independent, and reads no checkout.

There is **no `task setup:remote`** in this repository today (checked
2026-09-29). #750 says the setup script is "followed by `task setup:remote`"; that
is a forward reference to
[#1405](https://github.com/evanharmon1/harmon-init/issues/1405), which is open.
Until it exists, run the gate directly: `task verify`, or its component tasks
(`task --summary verify` lists them). Nothing in this guide should be read as
assuming the task.

**Pending observation:** record whether the repository is present when the setup
script runs (a probe line in a *copy* of the environment: `ls -d /workspace/*/.git`
into a file under `/var/tmp`, read by the first task; remove it afterwards,
because changing the script resets the cache), and whether a task's checkout has
a merge base and the tags the release-title and dogfood checks read.

Observed:  *pending*

## Pending observations

Three acceptance criteria of
[#750](https://github.com/evanharmon1/harmon-init/issues/750) — 2, 3 and 4 — need
a provisioned environment and live tasks run by the maintainer, and criterion 1's
pinned-tag slot needs a release. Criterion 3 of
[#1404](https://github.com/evanharmon1/harmon-init/issues/1404) (the agent
posture) needs one too. The rest are questions this guide could not
answer from the docs. Each result goes in the section named, with the date and the
`codex` version, replacing the tag in the text.

| # | What has to be seen | Where the result lands |
| --- | --- | --- |
| 1 | The `vX.Y.Z` of the first release that carries the bootstrap, and that the setup script finishes, as which user and in how long | [Setup script](#setup-script) |
| 2 | A Codex cloud task on harmon-init runs `task verify` to completion; every network denial recorded; whether a detached run survives, and whether a 15-minute gate exceeds a wall-clock limit | [Network](#network), [Long-running gates](#long-running-gates) |
| 3 | A Codex cloud review on a harmon-init PR, run after provisioning, shows in its output that it executed at least one repo check | [What Codex cloud is used for](#what-codex-cloud-is-used-for) |
| 4 | A task submitted with `codex cloud exec` runs the gate, and its diff applies cleanly to a local worktree with `codex cloud apply` and no human step | [Bridges](#bridges-between-the-terminal-and-codex-cloud) |
| — | Which generation `codex cloud exec --env` runs in | [Two generations of Codex cloud](#two-generations-of-codex-cloud) |
| — | Whether setup runs as root or with `sudo`; whether a failing setup script fails the task; the base image and whether it puts anything ahead of `/usr/local/bin`; the setup time limit | [Setup script](#setup-script) |
| — | Whether the agent's shell reads the bootstrap's `/etc/profile.d` drop-in and resolves `task` and `yq` from `/usr/local/bin` | [Environment variables](#environment-variables) |
| — | Whether the agent phase's locale is UTF-8 without the `LANG` variable set | [Environment variables](#environment-variables) |
| — | Whether an issue or pull request body mention starts a task; whether a quoted mention does | [What starts a Codex cloud task](#what-starts-a-codex-cloud-task) |
| — | What the connector's write permissions on the repository allow, in particular whether a task can push a branch or open a pull request, since the implementer lane assumes it does not | [Identity and secrets](#identity-and-secrets) |
| #1404-3 | Whether the agent Codex configuration the bootstrap installs is in effect in a task, or which parts Codex cloud cannot express and what enforces them instead | [The agent posture](#the-agent-posture-as-far-as-codex-cloud-can-express-it) |
| — | Whether the legacy environment's image has Docker; the gate does not need it and the bootstrap does not install it | [The agent posture](#the-agent-posture-as-far-as-codex-cloud-can-express-it) |
| — | What isolation the legacy environment gives a review or a mention-started task | [The agent posture](#the-agent-posture-as-far-as-codex-cloud-can-express-it) |
| — | Whether a task submitted with `codex cloud exec` runs on the pushed GitHub branch rather than the local checkout | [Bridges](#bridges-between-the-terminal-and-codex-cloud) |
| — | Whether the repository is present when the setup script runs, and whether a task's checkout has a merge base and the tags the release-title and dogfood checks read | [When per-checkout preparation runs](#when-per-checkout-preparation-runs) |
| — | Whether the reviewer's usage limit (reached on 2026-09-29) has reset, which can block criteria 3 and 4 | [Pending observations](#pending-observations) |

Criteria 2, 3 and 4 are not met by this guide, and the guide does not claim
them. Neither does criterion 1's final tag: a release must exist first.
