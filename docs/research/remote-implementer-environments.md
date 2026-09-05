# Remote implementer environments

**Status:** research note for harmon-init#1120, sources read 2026-09-05.
**Question:** where should implementer agent lanes run so that the number of
lanes an operator can drive in parallel is bounded by budget and review
bandwidth, not by the RAM of the laptop or the shared Coder box?
**Answer in three sentences:** run each interactive lane in a **Fly.io
Sprite** that hosts the repository's own bot devcontainer nested inside it,
driven from Herdr exactly as a local pane worker is, with a small
pre-initialised pool so a lane never re-pulls the image; keep **Coder
workspaces**
as the fallback that works today. For **Foreman**, use the same nested
sprite lane as the isolated runner, because the alternative its spec
assumes — booting the image directly on Fly Machines — hits Fly's 8 GB
rootfs limit with this image, and every other hosted option either cannot
take the image as-is or gives up the persistence and cost profile Sprites
have. The OpenSpec change
[`agent-environment-sprites`](../../openspec/changes/agent-environment-sprites/)
specs the opt-in, default-off option; the `[HUMAN]` lane run on harmon-init#1120 is
the proof this note cannot supply.

Everything below that names a capability carries the URL it was read from
(see [Sources](#sources)); anything that could not be verified against a
primary source is marked **unverified**.

## The problem, restated as a target contract

The bot devcontainer is the reference environment, and "matches the
devcontainer" has a precise meaning here:

| Property | Reference (the bot devcontainer) | Where it comes from |
|---|---|---|
| Image | the pinned public `ghcr.io/evanharmon1/harmon-devcontainer:sha-…@sha256:…` plus the repo's thin overlay (`.devcontainer/Dockerfile`), features applied (Python, docker-in-docker, GitHub CLI) | [devcontainer-image.md](../architecture/devcontainer-image.md) |
| Size | 8.36 GB uncompressed base; **9.26 GB** uncompressed once the bot profile is built; 1.74 GiB compressed (amd64) | `docker images` in this checkout; the GHCR manifest |
| Bootstrap | `post-create.sh` (ownership, git identity, `gh auth setup-git`, Herdr integrations, Claude settings seed, `bot-autonomy.sh apply` then `verify`), `post-start.sh` (`verify` before the conductor block) — both fail closed | [devcontainers.md](../guides/devcontainers.md), [security.md](../architecture/security.md) |
| Secrets | the `init-env.sh` allow-list only: `GH_TOKEN` (bot PAT), `CLAUDE_CODE_OAUTH_TOKEN`, optional provider keys; no `op`, no `TS_AUTHKEY`, `ANTHROPIC_API_KEY` stripped | [devcontainers.md](../guides/devcontainers.md) |
| Session runtime | Herdr server in the container, `herdr --remote` thin client over SSH, pane workers driven by brief + sentinel + file report | [herdr.md](../guides/herdr.md) |
| Gates | `task verify` (peaks near 4 GB on one `shellcheck`, harmon-devkit#716), `task challenge` / `task review` (Codex CLI), `task security`, draft PR, shepherd (`@codex review` is GitHub-side) | AGENTS.md |
| Egress | GitHub, GHCR, npm/PyPI/uv, `api.anthropic.com`, the Codex CLI's ChatGPT backend, Convex's local-backend download | this note, § Rubric |

Two observed failures set the bar (harmon-init#1120 body and its second data point):
four lanes on a 32 GB laptop drove swap to 12.7 GB and a load average past
250; three lanes on a 32 GB Coder devcontainer had to be serialised behind
a `flock`, each gate then took ~10 minutes and the third lane waited 20–30
minutes per round, and seven tests flaked only under load.

## Rubric

Every candidate is scored on the issue's dimensions. A score is **✅** (meets
the reference), **◐** (meets it with a documented workaround), **❌** (cannot,
with the alternative named), or **?** (unverified — needs the real lane
run).

1. **Per-lane isolation and sizing** — isolation primitive; whether a lane
   gets its own CPU/RAM and how much.
2. **Cold start and cost per agent-hour** — time to a usable lane; the
   hourly rate for something like 4 vCPU / 16 GB; what idle costs.
3. **Image reuse** — can it run the bot devcontainer image *as-is* with the
   bot profile's post-create/post-start, so the environment matches the
   devcontainer?
4. **Secrets model** — no 1Password or production secrets inside; how `gh`
   and Codex auth are provisioned and scoped.
5. **Herdr attach** — how the operator attaches from Herdr, and whether the
   session survives disconnects.
6. **Gates inside** — `task verify`, `challenge`, `review`, `security`,
   draft PR, shepherd all run inside.
7. **Egress** — for Convex anonymous mode and Codex; can it be allow-listed.
8. **Data that must never enter** — can the boundary keep gitignored local
   fixtures, `.env` files, and operator credentials out by construction.
9. **Fit with the bot-autonomy contract (harmon-init#1137) and Foreman's runner.**

## Candidates in depth

### Fly.io Sprites

**What it is.** "Persistent Linux computers for agent workloads": one
Firecracker microVM per sprite with hardware-level isolation, a persistent
100 GB ext4 filesystem (NVMe cache over object storage), automatic sleep,
filesystem checkpoints, a per-sprite HTTPS URL, and a CLI/API/SDK
([docs.sprites.dev](https://docs.sprites.dev/),
[lifecycle](https://docs.sprites.dev/concepts/lifecycle/),
[Fly's launch post](https://fly.io/blog/code-and-let-live/), and the
[design post](https://fly.io/blog/design-and-implementation/)).

**The fact everything bends around: a sprite cannot boot a custom OCI
image.** Fly staff, on the community forum: "Right now you can't use a
custom base image. But we're looking into the idea of forking from a
sprite, so you'll be able to build up your base, then fork off of it"
([community.fly.io/t/sprites-base-image/26789](https://community.fly.io/t/sprites-base-image/26789)).
The design post explains why: every worker knows exactly what container the
next sprite starts with, which is what lets Fly keep pools of empty sprites
ready. New sprites run Ubuntu 25.10 with Node, Python, Go, Ruby, Rust,
Elixir, Java, Bun, Deno, git, and the Claude, Gemini, Codex, and Cursor CLIs
preinstalled
([working-with-sprites](https://docs.sprites.dev/working-with-sprites/),
[sprite-maintenance](https://docs.sprites.dev/sprite-maintenance/)). Our
image, our `post-create.sh`, and our `bot-autonomy` gate therefore cannot
run *as the sprite*.

**What does work: Docker inside the sprite.** A community thread installs
`docker-ce` from Docker's apt repository and starts `dockerd` by hand;
sprites have no systemd, so the daemon is registered as a sprite Service
([community.fly.io/t/how-to-get-docker-running-on-sprites/27168](https://community.fly.io/t/how-to-get-docker-running-on-sprites/27168)).
Fly staff confirmed running Docker in sprites in that thread. This is
community-verified, not a documented feature — the single biggest risk of
the recommendation below. With Docker present, the sprite is an **outer
host** exactly like a Coder workspace: the devcontainers CLI brings
`.devcontainer/devcontainer.json` (bot profile) up from the pinned image,
applies the features, mounts the named volumes as Docker volumes on the
sprite's persistent disk, and runs `post-create.sh` and `post-start.sh`
for real — `bot-autonomy.sh apply` and `verify` included. The 100 GB disk
takes the 9.26 GB built image with room to spare, and the layers persist
across sleep.

**Sizing.** The lifecycle doc states 8 vCPUs per sprite with memory
managed by the platform ("auto-scales under pressure"); the JS SDK exposes
`cpus`, `ramMB`, and `region` creation fields that the API reference does
not document ([sprites-js README](https://github.com/superfly/sprites-js);
[API reference](https://sprites.dev/api/sprites)). Whether a sprite
throttles or kills a 4 GB `shellcheck` peak is **unverified**; there is
also a "Resources Policy" API whose semantics are undocumented. Region
selection is **unverified** (the SDK accepts `region: 'ord'`; no region
list is published).

**Lifecycle and persistence.** After about 30 seconds idle a sprite goes
`warm` (VM suspended, memory frozen, 100–500 ms resume, processes continue
where they were) and later `cold` (memory dropped, 1–2 s wake, processes
start fresh); open TCP connections drop on any pause; files, packages, git
repos, and databases persist; `/tmp` is scratch
([lifecycle](https://docs.sprites.dev/concepts/lifecycle/)). A **Task**
holds a sprite active for up to one hour per registration, renewed by
heartbeat; **Services** auto-start on boot and survive warm wakes
([keeping-sprites-running](https://docs.sprites.dev/keeping-sprites-running/)).
The warm→cold window is **unverified** (not documented).

**Checkpoints** capture the whole writable filesystem (not memory or
processes), are copy-on-write, and restore asynchronously and
destructively — active sessions are terminated; the last five are mounted
read-only under `/.sprite/checkpoints/`
([checkpoints](https://docs.sprites.dev/concepts/checkpoints/)). The docs
describe no way to seed a *new* sprite from a checkpoint, which is why a
lane pool is needed (below).

**Attach.** `sprite exec --tty` and `sprite console` run over WebSockets;
every TTY session is detachable (`Ctrl+\`, `sprite sessions
list|attach|kill`) but does not survive hibernation. There is no SSH
server; the documented workaround installs `openssh-server` as a Service
and tunnels with `sprite proxy -s <name> -W 22` as an SSH `ProxyCommand`
([working-with-sprites](https://docs.sprites.dev/working-with-sprites/),
[CLI commands](https://docs.sprites.dev/cli/commands/)). That is the same
shape `herdr --remote coder.<ws>.devcontainer` already uses over Coder's
`--stdio` ProxyCommand, so `herdr --remote` against a sprite is structurally
sound but **unverified** end to end.

**Networking.** Outbound is unrestricted by default; a DNS-based allowlist
policy is set through the API, reloads live, blocks raw-IP connections not
resolved through an allowed domain, always blocks private IPs, and is
read-only inside the sprite ([networking](https://docs.sprites.dev/concepts/networking/)).
Inbound is the per-sprite URL (private to the org by default) and
`sprite proxy` port forwarding.

**Auth and secrets.** CLI and API tokens are **organisation-scoped**
(`SPRITES_TOKEN`, `sprite auth setup --token`, keyring or
`~/.sprites/sprites.json`); no sprite-scoped token exists
([authentication](https://docs.sprites.dev/cli/authentication/)). A sprite
holding that token could exec into every sibling, so the token must never
enter a lane. **Connectors** keep a GitHub OAuth or API-key credential in
Fly's gateway so the sprite never sees it — but the gateway proxies API
calls at `api.sprites.dev/v1/gateway/<provider>/…`, not `git push` over
HTTPS, so it does not replace `GH_TOKEN` for pushing
([connectors](https://docs.sprites.dev/concepts/connectors/)). Fly's own
advice for GitHub access from a sprite is `gh auth login` with the bundled
`gh` ([community.fly.io/t/sprite-console-ssh-agent/27024](https://community.fly.io/t/sprite-console-ssh-agent/27024)).

**Pricing** ([fly.io/sprites](https://fly.io/sprites)): $0.07 per CPU-hour
(measured from `cpu.stat`), $0.04375 per GB-hour of memory actually used,
$0.000683 per GB-hour hot storage and $0.000027 per GB-hour cold, nothing
per sprite, nothing while asleep. Fly's own worked example prices a 4-hour
Claude Code session at 46 cents. Each user can grant one $30 trial credit,
each org can receive at most one; a Fly.io account is required. Plans add
concurrency and creation rate: pay-as-you-go creates 10 sprites/minute,
Adventurer ($20/mo, 20 concurrent active sprites) 60/minute, up to Mythic
($2,000/mo) at 240/minute; Hero ($100/mo) includes 1,200 CPU-hours, 4,800
RAM GB-hours and 150 GB storage. The pay-as-you-go concurrency ceiling is
**unverified**. A nested lane's steady-state cost is dominated by memory:
a lane averaging 3 GB resident and one busy CPU is roughly $0.20 per
active hour, and a sleeping pool sprite holding ~15 GB of image layers in
cold storage costs about $0.30 per month.

**Claude Managed Agents integration.** Fly documents using sprites as the
sandbox for Anthropic's Managed Agents, with the Sprites API token and the
Anthropic key both kept on the worker side and only an environment key
entering the sprite ([integration doc](https://docs.sprites.dev/integrations/claude-managed-agents/)).
Not what this note needs (see Claude Code below), but it shows the
credential-outside pattern Fly expects.

**Scores.** Isolation ✅ (microVM; sizing ?). Cold start ? (the VM wakes in
1–2 s cold and under a second warm, but the rubric asks for time to a
*usable lane* — restore, clone, `devcontainer up`, post-create — which is
unmeasured until the feasibility spike; the pool exists to amortise the
image pull, not to make that path instant).
Cost ✅. Image reuse ◐ (nested via Docker, unofficial; not as the sprite
itself — alternative: Fly Machines after slimming under 8 GB). Secrets ◐
(same allow-list as today; org token stays outside; Connectors do not
cover `git push`). Herdr attach ◐ (`sprite exec --tty` in a local pane for
orchestration; `herdr --remote` over an sshd Service for takeover — both
unverified). Gates ? (all bash inside the nested container and Codex cloud
review is GitHub-side, but nothing has run `task verify` inside a nested
devcontainer in a sprite yet). Egress ✅ (DNS allowlist, read-only inside).
Data boundary ✅ (clone from GitHub only). Bot-autonomy ? (post-create/
post-start run unchanged by construction; unverified until the first lane).
Foreman ◐ (see Recommendation).

### Fly Machines (found during the research)

Fly's other primitive is what ponderousdev/foreman's spec actually
describes. Machines are Firecracker microVMs that boot **any OCI image**
from a public registry, with `config.env`, `config.files` (base64 or from a
secret), `config.guest` sizing (`cpu_kind`, `cpus`, `memory_mb`),
`auto_destroy`, `init.exec`, and stop/start/wait endpoints
([Machines API](https://fly.io/docs/machines/api/machines-resource/)).
`fly ssh console` reaches a Machine through a WireGuard tunnel to the
in-VM `hallpass` SSH server, no sshd in the image needed
([fly ssh](https://fly.io/docs/flyctl/ssh/),
[SSH and user-mode WireGuard](https://fly.io/blog/ssh-and-user-mode-ip-wireguard/)).
Sizing runs to `performance-16x`/128 GB; the US/EU rate for
`performance-4x` with 16 GB is $0.2278/hour, `shared-cpu-8x` with 16 GB
is $0.1189/hour, a stopped Machine's rootfs costs $0.15 per GB per 30
days, and volumes $0.15 per GB-month ([pricing](https://fly.io/docs/about/pricing/)).
The root filesystem is ephemeral across updates and destroy; there is no
filesystem checkpoint, no automatic sleep for a non-HTTP workload (stop it
yourself), and suspend preserves memory only up to 2 GB
([suspend-resume](https://fly.io/docs/reference/suspend-resume/)).

**The blocker: "Machines have an 8GB rootfs limit"**
([troubleshooting](https://fly.io/docs/getting-started/troubleshooting/)).
The shared image alone is 8.36 GB uncompressed and the built bot profile is
9.26 GB, so this image does not boot on a Machine today. foreman#33
already mandates "slim only after measurement"; a slim target under 8 GB
in the *same* Dockerfile (foreman D6 forbids a second image) would make
Machines viable, and they would then be the most literal match for the
maintainer's intent — same image, `post-create.sh` invoked by the Machine's
init, real SSH — at the cost of explicit sizing and no free idle.

**Scores.** Isolation ✅ (explicit sizing). Cold start ✅ ("well under a
second" from stopped). Cost ◐ (~$0.23/h while started, nothing free while
idle beyond stop). Image reuse ❌ today (8 GB rootfs; alternative: slim the
image). Secrets ✅ (per-Machine env/files; app secrets are app-scoped and
would leak across units unless one app per unit — foreman#30 already
notes this). Herdr attach ✅ structurally (hallpass SSH; unverified).
Gates ✅. Egress ◐ (Machine network policies are TCP/port rules, not DNS
allowlists). Data boundary ✅. Bot-autonomy ✅ once booted. Foreman ✅ by
design, ❌ by image size today.

### Claude Code remote sessions

Three distinct things carry this name
([claude-code-on-the-web](https://code.claude.com/docs/en/claude-code-on-the-web),
[cloud-environments](https://code.claude.com/docs/en/cloud-environments),
[cli-reference](https://code.claude.com/docs/en/cli-reference),
[self-hosted-environments](https://code.claude.com/docs/en/self-hosted-environments)):

- **Anthropic-hosted cloud sessions** (claude.ai/code, `claude --cloud`):
  an Ubuntu 24.04 VM with about 4 vCPUs, 16 GB RAM and 30 GB disk, the
  repository cloned from GitHub (never the local checkout), docker and
  dockerd preinstalled, four egress levels (none / trusted allowlist /
  full / custom) behind an Anthropic proxy with a DNS audit trail, and
  GitHub auth through the Claude GitHub App or a synced `gh` token with
  credentials held outside the sandbox (`GH_TOKEN` reads as
  `proxy-injected`). Customisation is a five-minute root **setup script**
  whose result is cached about seven days — no custom image, no
  devcontainer. There is **no terminal into the VM**: the operator steers
  through the web UI or `claude -p … --cloud <id>`, and `--teleport` pulls
  the branch and transcript to a local checkout. Sessions persist until an
  undocumented inactivity window reclaims the VM (history restored on a
  fresh VM). No separate compute charge; it shares the plan's rate limits;
  Pro/Max/Team/Enterprise.
- **Self-hosted environments** (`claude --environment ccpool_…`): a named
  queue in claude.ai admin settings plus **runner processes you deploy**
  on your own hosts ("the idea is the same as a self-hosted CI runner");
  you build the runner image, runners poll `api.anthropic.com` outbound
  and spawn a child Claude Code process. Dispatch is fire-and-forget: the
  CLI "creates the session, prints the session ID and a link to it, and
  exits". Public beta on **Team and Enterprise plans only**.
- **Managed Agents**: an API-driven agent harness; each session gets a
  fresh Linux container (Ubuntu 24.04, up to 8 GB RAM and 10 GB disk),
  packages from a list rather than a custom image, `gh` not preinstalled,
  egress `unrestricted` or `limited`, $0.08 per session-hour plus tokens,
  events over the API and no operator terminal
  ([overview](https://platform.claude.com/docs/en/managed-agents/overview),
  [cloud-sandboxes-reference](https://platform.claude.com/docs/en/managed-agents/cloud-sandboxes-reference),
  [pricing](https://platform.claude.com/docs/en/about-claude/pricing)).

**Assessment.** The hosted VM is the right size and free of compute charges,
but it fails the contract on three counts: no custom image (our
`bot-autonomy` gate cannot run as designed, only re-implemented in a setup
script), no terminal (Herdr has nothing to attach to; steering is the web
UI), and Codex is not in the box (the `task challenge`/`task review` stages
would need the Codex CLI installed by the setup script and logged in via a
copied `auth.json`, egress permitting). The self-hosted runner shape is the
interesting one — a sprite could *be* a runner — but it is Team/Enterprise
only and still gives no terminal. Managed Agents is a different product
for a different job.

**Scores.** Isolation ✅. Cold start ✅. Cost ✅ (included). Image reuse ❌
(setup script only). Secrets ✅ (proxy-injected; the best model in the
field). Herdr attach ❌ (no shell). Gates ◐ (Codex must be installed and
authenticated by script; unverified). Egress ✅. Data boundary ✅ (clones
from GitHub). Bot-autonomy ❌ (cannot run `post-create.sh`). Foreman ❌ (no
exec surface for a supervisor).

### OpenAI Codex cloud tasks, and the `@codex review` contract

**Cloud tasks** run in a container from the `universal` image (or your
setup script on top of it), never a custom image; internet is **blocked
during the agent phase by default** with an optional allowlist (none /
common dependencies / all); GitHub access is through the ChatGPT Codex
Connector App; there is no documented terminal into a running task; the
container cache lives up to 12 hours; tasks are included in ChatGPT
Plus/Pro/Business/Enterprise/Edu plans and can be submitted with
`codex cloud exec --env <id> "<task>"`
([cloud-environment](https://learn.chatgpt.com/docs/environments/cloud-environment),
[internet-access](https://learn.chatgpt.com/docs/cloud/internet-access),
[developer-commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli),
[pricing](https://learn.chatgpt.com/docs/pricing)). harmon-init#690 and
harmon-init#750 record the practical state of that environment for this repo: `task`
is unavailable and `git clone` of a pinned tag was rejected by the CONNECT
proxy — the environment has to be provisioned, and even then it cannot
host a Herdr session.

**Codex CLI inside a container** is the part that matters, because the
gauntlet runs `task challenge` and `task review` through it. Headless auth
is documented three ways: `codex login --device-auth` (beta; the account
must enable device-code login), `codex login --with-api-key` from stdin
(loses cloud features), or — explicitly supported — copying
`~/.codex/auth.json` into the container ("Treat `~/.codex/auth.json` like
a password"; the docs give the `docker cp` and `ssh … cat >` recipes)
([auth](https://learn.chatgpt.com/docs/auth)). The bot profile already runs
Codex in `danger-full-access`/`never`, so nothing about the sandbox mode
changes inside a nested devcontainer.

**Does the `@codex review` contract still hold?** Yes, and it is
independent of where the code was written. The review is triggered by an
`@codex review` comment on the PR (or Automatic reviews, which this repo
keeps off), is posted by `chatgpt-codex-connector[bot]`, requires "Codex
cloud set up for the repository", and "reviews the pull request diff" —
a GitHub-side action on the PR head keyed to the repository's Codex cloud
connection and the connected ChatGPT account
([third-party/github](https://learn.chatgpt.com/docs/third-party/github)).
Nothing in the docs ties it to the author's environment; whether the
review executes inside the repo's cloud environment container and who may
trigger it are **unverified**. The shepherd's current-head cycle,
`check-codex-cloud-review.sh`, and `settle` therefore work unchanged from
inside a lane.

**Scores.** Isolation ✅ (container; Firecracker not claimed). Cold start
✅. Cost ✅ (included). Image reuse ❌ (universal image + setup script).
Secrets ✅ (secrets are removed before the agent phase). Herdr attach ❌.
Gates ❌ as a lane (no `task`, no terminal); ✅ as the reviewer. Egress ◐
(off by default; allowlist). Data boundary ✅. Bot-autonomy ❌. Foreman ❌.

### The existing Coder instance

The repository already runs on Coder: the harmon-infra `devcontainer`
template clones the repo on an outer workspace, starts `dockerd` there,
brings the inner devcontainer up with the devcontainers CLI (profile
selected by an immutable parameter), passes secrets as workspace
parameters into `init-env.sh`'s allow-list, and exposes two agents,
`host` and `devcontainer`; `coder ssh <ws>.devcontainer` and
`herdr --remote coder.<ws>.devcontainer` are documented and verified
([devcontainers.md](../guides/devcontainers.md) § Bot-profile access from
Coder; harmon-infra `terraform/coder/devcontainer/main.tf`). Coder's own
docs confirm the sub-agent model (`coder ssh <workspace>.<agent>`, Coder ≥
2.24) and that SSH sessions and an AI agent's `working` status bump the
autostop timer ([devcontainers](https://coder.com/docs/user-guides/devcontainers),
[workspace-scheduling](https://coder.com/docs/user-guides/workspace-scheduling)).
Coder Tasks — the Claude Code wrapper — is being removed from new releases
from v2.37 (September 2026) in favour of "Coder Agents", which "is not a
wrapper around third-party agent tools like Claude Code or Codex"
([tasks.md at v2.36](https://raw.githubusercontent.com/coder/coder/v2.36.0/docs/ai-coder/tasks.md),
[agents](https://coder.com/docs/ai-coder/agents)); neither affects this
repo's SSH-and-Herdr use.

**Assessment.** A workspace per lane is the zero-new-infrastructure path
and it is the closest match to the reference in every way but one: every
workspace shares the Contraption host's RAM, so the second data point on
harmon-init#1120 (three lanes serialised behind a `flock` on one 32 GB box) is what
"a workspace per lane" produces once the host is full. Coder scales to the
host; the invariant asks for scaling to budget. It stays the fallback, and
the design of the sprite lane deliberately mirrors it (outer host with
Docker, inner devcontainer, attach to the inner agent) so the two are
interchangeable in the dispatch recipe.

**Scores.** Isolation ◐ (container on a shared host; sizing bounded by
Contraption). Cold start ◐ (workspace build minutes; rebuilds pull the
cache). Cost ✅ ($0 marginal). Image reuse ✅. Secrets ✅ (parameters →
allow-list). Herdr attach ✅ (verified). Gates ✅. Egress ❌ (homelab
network; no per-workspace allowlist). Data boundary ✅. Bot-autonomy ✅.
Foreman ◐ (foreman D4: local runner refuses untrusted-input on a public
repo; a Coder workspace is still "local" to foreman).

### Remote dev containers: devcontainers CLI on a VM, VS Code / SSH remote, GitHub Codespaces

**A VM you own** (devcontainers CLI + Docker on a Hetzner box, say) runs the
image as-is on either architecture with plain SSH and tmux/Herdr, and is
the only option besides Coder and a nested sprite that needs no re-baking.
Hetzner Cloud cannot run Firecracker or Kata ("nested virtualization … is
not possible on cloud server"), so isolation between lanes on one VM is
Docker or gVisor; a CX43 (8 shared vCPU / 16 GB) is €15.99/month, a CCX23
(4 dedicated vCPU / 16 GB) €85.99/month after Hetzner's June 2026
repricing, and a bare-metal AX42-1 for real microVMs €97.30/month
([Hetzner FAQ](https://docs.hetzner.com/cloud/servers/faq/),
[price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)).
That is one more host to patch and secure, and it re-creates the
shared-host contention the issue is about unless it is one VM per lane.

**GitHub Codespaces** is devcontainer-native: `devcontainer.json`,
Dockerfile or image, features, `postCreateCommand` at creation (prebuilds
stop at `updateContentCommand`) and `postStartCommand` on each start; GHCR
packages pull without credentials when the package grants the repo access;
sizes from 2 cores / 8 GB / 32 GB to 32 cores / 128 GB / 128 GB; each
codespace on its own VM. `gh codespace ssh` gives a real SSH session, and
closing the client does not stop the codespace — but the **idle timeout is
30 minutes by default and 4 hours at most**, terminal activity is what
resets it, stopped codespaces are deleted after at most 30 days
"irrespective of whether a codespace contains unpushed changes", secrets
are plain environment variables, and "there is no way to restrict
codespaces from accessing the public internet". Pricing: 2-core $0.18/h,
4-core $0.36/h, 8-core $0.72/h, storage $0.07 per GB-month; 120 free
core-hours and 15 GB-month on GitHub Free, 180 and 20 on Pro
([billing](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces),
[timeout](https://docs.github.com/en/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces),
[security](https://docs.github.com/en/codespaces/reference/security-in-github-codespaces),
[auto-deletion](https://docs.github.com/en/codespaces/setting-your-user-preferences/configuring-automatic-deletion-of-your-codespaces)).
`init-env.sh` already handles the Codespaces case (secrets from the host
environment), so the bot profile would come up unchanged.

**Scores (Codespaces).** Isolation ✅. Cold start ◐ (minutes without a
prebuild). Cost ◐ ($0.36–0.72/h, free tier covers ~30 hours of 4-core a
month). Image reuse ✅. Secrets ◐ (env vars; the bot allow-list applies).
Herdr attach ✅ (SSH) but ❌ across a 4-hour idle cap for a lane that waits
on review. Gates ✅. Egress ❌ (cannot be restricted). Data boundary ✅.
Bot-autonomy ✅. Foreman ❌ (no supervisor-facing exec/lifecycle API beyond
`gh codespace`).

## Scorecard

| Dimension | Sprites (nested) | Fly Machines | Claude Code cloud | Codex cloud | Coder (per lane) | Codespaces |
|---|---|---|---|---|---|---|
| Isolation and sizing | ✅ microVM · sizing ? | ✅ microVM, explicit | ✅ VM 4/16 | ✅ container | ◐ shared host | ✅ VM, 2–32 cores |
| Cold start (to a usable lane) | ? VM wake 1–2 s; restore + clone + `devcontainer up` + post-create unmeasured | ✅ <1 s to boot; post-create unmeasured | ✅ | ✅ | ◐ minutes | ◐ minutes |
| Cost per active agent-hour | ✅ ~$0.20, idle free | ◐ ~$0.23, stop to save | ✅ included | ✅ included | ✅ $0 marginal | ◐ $0.36–0.72 |
| Runs the bot image as-is | ◐ nested via Docker | ❌ 8 GB rootfs | ❌ setup script | ❌ setup script | ✅ | ✅ |
| post-create / bot-autonomy runs | ? nested, unverified until the first lane | ✅ (if it boots) | ❌ | ❌ | ✅ | ✅ |
| Secrets model | ◐ allow-list; org token outside | ✅ per-machine | ✅ proxy-injected | ✅ | ✅ | ◐ env vars |
| Herdr attach, survives disconnect | ◐ exec-TTY / sshd (unverified) | ✅ hallpass SSH (unverified) | ❌ no shell | ❌ | ✅ verified | ✅ SSH, 4 h idle cap |
| All gates + draft PR + shepherd inside | ? all bash, but nested `verify` unverified | ✅ | ◐ | ❌ | ✅ | ✅ |
| Egress allowlist | ✅ DNS | ◐ TCP rules | ✅ | ◐ off by default | ❌ | ❌ |
| Keeps local data out by construction | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Foreman runner fit | ◐ needs D5 revisited | ✅ design / ❌ size | ❌ | ❌ | ◐ "local" | ❌ |

## The wider field

One paragraph each, facts as fetched on 2026-09-05; the pricing column is a
4 vCPU / 16 GB lane derived from the cited rates.

**GitHub Codespaces** — scored above. Works today with the image and
`gh codespace ssh`; the 4-hour idle cap, unrestricted egress, and 30-day
deletion make it a short-lane box rather than a durable agent host.

**Daytona** — container isolation by default with a separate "Linux VM"
class; snapshots from any registry image (pinned, AMD64) with GHCR PAT
support; SSH via short-lived tokens, a web terminal, and a PTY that
survives client disconnect; secrets substituted by an outbound proxy so
plaintext never enters; egress restricted and not overridable on the two
lowest tiers; $0.0504 per vCPU-hour and $0.0162 per GiB-hour with $200
free credit. **Blocker:** "a maximum sandbox resource limit of 4 vCPUs,
8GB RAM, and 10GB disk" — the 9.26 GB image does not fit
([sandboxes](https://www.daytona.io/docs/en/sandboxes/),
[pricing](https://www.daytona.io/pricing)).

**E2B** — Firecracker microVMs with true pause/resume of memory and
processes, resume about 1 s, paused sandboxes kept indefinitely; templates
built from an image or Dockerfile rather than booted directly, 10 GiB build
disk on Hobby and "20+" on Pro, RAM capped at 8 GiB below Enterprise, 1 h
continuous runtime on Hobby / 24 h on Pro, PTY only (no SSH), egress on by
default with allow/deny lists; $0.0504 per vCPU-hour, $0.0162 per GiB-hour,
Pro $150/month ([persistence](https://docs.e2b.dev/sandbox/persistence),
[billing](https://docs.e2b.dev/billing), [pricing](https://e2b.dev/pricing)).
Strong isolation, wrong size and no SSH.

**Modal sandboxes** — gVisor; `Image.from_registry` boots the GHCR image
directly (amd64, python on `PATH`, exec-style entrypoint), disk to 3 TiB,
sub-second cold start; but a hard 24-hour sandbox lifetime with
snapshot-and-recreate beyond it, PTY exec only, no SSH; about $0.071 per
vCPU-hour and $0.024 per GiB-hour with a $30/month starter credit
([sandbox](https://modal.com/docs/guide/sandbox),
[snapshots](https://modal.com/docs/guide/sandbox-snapshots),
[pricing](https://modal.com/pricing)). A batch runner, not a lane host.

**Cloudflare Sandbox SDK / Containers** — each instance in its own VM,
Dockerfile pushed to Cloudflare's registry (GHCR not listed), linux/amd64,
disk **ephemeral and wiped on sleep**, ceiling 4 vCPU / 12 GiB / 20 GB,
`wrangler containers ssh` and a WebSocket PTY that survives disconnect,
deny-by-default `allowedHosts`; needs Workers Paid ($5/month) plus
$0.000020 per vCPU-second ([limits](https://developers.cloudflare.com/containers/platform-details/limits/),
[pricing](https://developers.cloudflare.com/containers/pricing/)). The
ephemeral disk alone rules it out.

**Docker agent sandboxes (`sbx`)** — a local KVM/Hypervisor.framework
microVM per sandbox on the operator's own machine, templates that must
extend `docker/sandbox-templates`, deny-by-default egress with
`sbx policy allow`, proxy-injected secrets, free; not hosted, so it moves
the RAM problem nowhere ([isolation](https://docs.docker.com/ai/sandboxes/security/isolation/),
[templates](https://docs.docker.com/ai/sandboxes/customize/templates/)).
Useful as a hardened *local* lane on a Linux host, not as the remote
environment this note is after.

**Northflank** — pulls any public or private image as-is (GHCR PAT
supported), persistent volumes, pause billed at storage only, interactive
TTY `exec`, 0.1–32 vCPU and up to 256 GB, cheapest hosted compute
($0.01667 per vCPU-hour, $0.00833 per GB-hour, about $0.20/h for 4/16);
microVM isolation (Kata/gVisor) is documented for BYOC and GPU while the
managed-cloud CPU runtime is **unverified**, and egress allowlists are BYOC
only ([sandboxes](https://northflank.com/docs/v1/application/sandboxes/sandboxes-on-northflank),
[pricing](https://northflank.com/pricing)). The strongest hosted runner-up:
if the Docker-in-sprite path fails and slimming for Fly Machines is
unwelcome, evaluate this first.

**Gitpod / Ona** — a VM per environment from `devcontainer.json` (image or
Dockerfile, private GHCR via a registry secret), everything on disk
persists across stop/start, `ona environment ssh`, timeouts up to 8 h or
never, about $0.25/h for 4 vCPU / 16 GB on Core plans from $20/month; no
egress allowlist documented for Ona Cloud, "Ona Agent is deprecated" in
favour of Codex, and free-tier terms are unverified
([runners](https://ona.com/docs/ona/runners/overview),
[persistent-storage](https://ona.com/docs/ona/environments/persistent-storage),
[pricing](https://ona.com/pricing)). Second runner-up.

**Vercel Sandbox** — Firecracker, persistent filesystem by default, sessions
capped at 45 min (Hobby) / 24 h (Pro), `sandbox connect` shell, credential
brokering so secrets never enter, egress allow-all by default with
allowlists; but images must be pushed to Vercel's registry with a **500 MB
compressed-layer cap** and 15 GB total, and 16 GB RAM needs 8 vCPU on Pro
(~$1.36/h) ([images](https://vercel.com/docs/sandbox/concepts/images),
[pricing](https://vercel.com/docs/vercel-sandbox/pricing)). Re-layering the
image is the blocker.

**A self-hosted Firecracker/Docker box** — scored above under remote dev
containers: the only option that runs the image untouched on either
architecture with plain SSH, at Hetzner Cloud prices from €15.99/month,
but Docker/gVisor isolation only on cloud VMs and one more host to run.

**Others worth naming.** **Runloop** (microVM + container, Dockerfile with
any `FROM`, real `rli devbox ssh`, account secrets and an agent gateway,
`allowed_hostnames` policies, ~$0.84/h for 4/16 with a 64 GiB disk cap) is
a close fit at four times the price
([sizes](https://docs.runloop.ai/docs/devboxes/configuration/sizes),
[pricing](https://www.runloop.ai/pricing)). **Morph Cloud** (full VMs with
memory+disk snapshots, wake-on-SSH, ~$0.20/h) has no documented way to boot
an OCI image as the rootfs — the devcontainer would run as a container
inside the VM, the same nested shape as Sprites without the auto-sleep
economics ([ssh](https://cloud.morph.so/docs/documentation/instances/ssh),
[subscribe](https://cloud.morph.so/web/subscribe)). **Blaxel** (microVMs,
standby snapshots that preserve processes, proprietary `bl connect`, image
rebuilt with its `sandbox-api`) trades the terminal we need for persistence
we can get elsewhere ([overview](https://docs.blaxel.ai/Sandboxes/Overview)).
**Coder** as a product (control plane, any image, `coder ssh`) is what we
run; its Claude-Code-native Tasks surface is retiring, which does not
touch our SSH-and-Herdr use.

## What Sprites cannot do today, and the alternative for each

| Requirement | Sprites today | Alternative |
|---|---|---|
| Boot the bot image as the VM | ❌ fixed Ubuntu base; forking is a roadmap idea | Nest the bot devcontainer via Docker in the sprite (recommended); or slim the image under 8 GB and boot it on Fly Machines |
| Officially supported Docker | ◐ community-verified, no systemd; `dockerd` as a Service | If Fly withdraws it: Fly Machines (after slimming) or Northflank |
| A checkpoint that seeds a new sprite | ❌ | A small pool of pre-initialised sprites, each with a golden checkpoint restored before every lane |
| Real SSH for `herdr --remote` | ❌ WebSocket console only | `openssh-server` inside the inner container + `sprite proxy -s <lane> -W <inner-address>:22` as `ProxyCommand` (the documented workaround, pointed at the container rather than the outer sprite so the session lands where Herdr runs) |
| Guaranteed RAM for a 4 GB gate peak | ? platform-managed memory | Measure in the first lane; SDK `ramMB`/`cpus` fields; Fly Machines with explicit sizing |
| Processes survive a cold pause | ❌ | Keep the sprite active exactly while a lane command runs (in-sprite activity, never a laptop heartbeat); `dockerd` as a Service; reconcile the inner container on every entry (`devcontainer up` reruns post-start `verify`); Herdr snapshot restore + `resume_agents_on_restore` |
| A sprite-scoped API token | ❌ org-scoped only | Keep the token on the orchestrator's side; never inject it; ask Fly (follow-up) |
| Connectors that carry `git push` | ❌ API gateway only | `GH_TOKEN` (the bot PAT) through the existing `init-env.sh` allow-list, as in every bot container today |
| Region choice | ? undocumented | SDK `region` field; measure latency in the first lane |
| Foreman's D5 ("Sprites do not run Docker") | ❌ nested shape needs Docker | Supersede D5 in foreman, or slim the image for Fly Machines and keep D5 |

## Recommendation

**Interactive dispatch from Herdr — primary: a Fly.io Sprite per lane,
running the bot devcontainer nested inside it.** The sprite is the outer
host (Docker as a Service, the devcontainers CLI), the inner container is
the repository's own bot profile from the pinned image with
`post-create.sh` and `post-start.sh` unchanged, so the `bot-autonomy`
apply/verify gate runs there exactly as it does locally and on Coder. A
small operator-owned pool of sprites is initialised once (image pulled,
golden checkpoint taken before any credential exists) and every lane
claims a sprite with a lease, restores that checkpoint and waits for it,
sets the egress allowlist, clones its pushed branch from GitHub onto the
sprite's workspace folder, runs `devcontainer up` on it with the bot
allow-list's secrets in its environment so `init-env.sh` composes the
env-file before the container exists, and is driven
from the orchestrator's Herdr as a pane whose process is `sprite exec
--tty` into the container — brief, per-attempt sentinel, file report,
harvest, retire, as the Herdr guide already prescribes; takeover with the
full Herdr UI goes through an SSH server inside the container. The
org-scoped Sprites token never enters a lane, the sprite stays active
exactly while a lane command runs (the mechanism is in-sprite, so a closed
pane cannot pause a running gate), a TTL stops new work without destroying
anything, and `task sprite:audit` lists every lane with its age and lease.
A throwaway feasibility spike (Docker as a Service, a nested
`devcontainer up`, `task verify` inside, a cold wake, the SSH attach) runs
before any of that is productised. The specification is
[`openspec/changes/agent-environment-sprites`](../../openspec/changes/agent-environment-sprites/);
the option defaults off and discloses Fly's account and pricing terms next
to the question. **Fallback:** a Coder workspace per lane — verified attach
path, same shape, bounded by the Contraption host. If the Docker-in-sprite
path fails in the first real lane, the next candidates in order are Fly
Machines after slimming the image under 8 GB (the most literal match),
then Northflank and Ona (take the image as-is; isolation and egress terms
to confirm).

**Foreman — primary: the same nested sprite lane, exposed as Foreman's
`runner = "sprite"`.** Foreman's written design (D5 "Sprites do not run
Docker", D6 "Fly boots OCI images as a microVM root filesystem") describes
Fly Machines, and Machines cannot boot this image: the built bot profile is
9.26 GB against an 8 GB rootfs limit. Two honest routes exist — supersede
D5 and run the nested lane under the Sprites API (exec over WebSocket,
Tasks holds, checkpoints, DNS network policy, all present), or slim the
image under 8 GB per foreman#33 and implement the runner against the
Machines API as foreman#30 literally describes. This note recommends the first,
because it gives Herdr dispatch and Foreman one lane recipe and one image,
and because the Sprites API already provides the egress defence foreman#31
wants without building it. Which route foreman takes is foreman's
decision; the follow-up below asks for it explicitly.

**Follow-up issues to file**, each in the repository that owns it:

- **harmon-init** — implement the `agent-environment-sprites` change
  (`feat:`; both layers; the offline `test:sprite-lane`); after the first
  real lane, record wall-clock, cost, Herdr detection, memory behaviour,
  and the literal egress hostnames in this note; a separate issue for
  shorter-lived lane credentials (per-lane GitHub App installation tokens
  and `billing = "api"` with a capped key, as foreman#30 weighs) once the
  lane exists to measure against.
- **harmon-devkit** — the vendored `herdr` skill and the dispatch-recipe
  text gain a "remote lane" variant: pane-process-is-the-session, the
  `unknown`-detection fallback, and `--env sprite` selection; the
  `standardize-repo` catalog lists the new Copier answer.
- **ponderousdev/foreman** — reconcile D5/D6 with what Sprites actually are
  (the runner named `sprite` boots no OCI image); choose between the nested
  sprite lane and a slimmed image on Fly Machines; note the 8 GB rootfs
  limit against foreman-devcontainer's own size; record that Sprites API
  network policy satisfies foreman#31's guest-level egress defence.
- **harmon-infra** — nothing to build: record in the Coder template README
  that per-lane Coder workspaces are the fallback and that the sprite lane
  reuses the same outer-host/inner-devcontainer shape; consider a
  `ghcr_read_token`-style parameter is *not* needed because the shared
  image is public.
- **Fly.io (feature request, not an issue here)** — sprite-scoped tokens
  and fork-from-sprite; both would simplify the design (no pool, no
  org-token exclusion).

## Verification status

Verified against primary sources on 2026-09-05: everything cited above.
**Unverified, and settled only by the `[HUMAN]` lane run on harmon-init#1120:** Docker
starting and staying up as a sprite Service across warm and cold wakes; the
inner devcontainer's `post-create.sh` completing (the docker-in-docker
feature inside a container inside a microVM); Herdr's classification of an
agent rendered through `sprite exec --tty`; `herdr --remote` over the sshd
Service; memory behaviour under `task verify`'s 4 GB peak; the warm→cold
window; region and latency; the literal hostnames the Codex CLI and the
Convex local backend need; the pay-as-you-go concurrency ceiling; and the
real wall-clock and cost of one lane end to end.

## Sources

Primary sources read for this note (all fetched 2026-09-05):

- Fly.io Sprites: https://fly.io/sprites (pricing, plans, trial credit);
  https://docs.sprites.dev/ ; https://docs.sprites.dev/quickstart/ ;
  https://docs.sprites.dev/working-with-sprites/ ;
  https://docs.sprites.dev/keeping-sprites-running/ ;
  https://docs.sprites.dev/sprite-maintenance/ ;
  https://docs.sprites.dev/concepts/lifecycle/ ;
  https://docs.sprites.dev/concepts/checkpoints/ ;
  https://docs.sprites.dev/concepts/networking/ ;
  https://docs.sprites.dev/concepts/connectors/ ;
  https://docs.sprites.dev/cli/commands/ ;
  https://docs.sprites.dev/cli/authentication/ ;
  https://docs.sprites.dev/integrations/claude-managed-agents/ ;
  https://sprites.dev/api/sprites ; https://github.com/superfly/sprites-js ;
  https://github.com/superfly/sprites-py ; https://github.com/superfly/sprites-go ;
  https://fly.io/blog/code-and-let-live/ ;
  https://fly.io/blog/design-and-implementation/ ;
  https://community.fly.io/t/sprites-base-image/26789 ;
  https://community.fly.io/t/how-to-get-docker-running-on-sprites/27168 ;
  https://community.fly.io/t/sprite-console-ssh-agent/27024
- Fly Machines: https://fly.io/docs/machines/api/machines-resource/ ;
  https://fly.io/docs/about/pricing/ ;
  https://fly.io/docs/getting-started/troubleshooting/ (8 GB rootfs limit);
  https://fly.io/docs/machines/guides-examples/machine-sizing/ ;
  https://fly.io/docs/flyctl/ssh/ ; https://fly.io/docs/flyctl/proxy/ ;
  https://fly.io/docs/reference/suspend-resume/ ;
  https://fly.io/blog/ssh-and-user-mode-ip-wireguard/
- Claude Code: https://code.claude.com/docs/en/claude-code-on-the-web ;
  https://code.claude.com/docs/en/cloud-environments ;
  https://code.claude.com/docs/en/cli-reference ;
  https://code.claude.com/docs/en/self-hosted-environments ;
  https://code.claude.com/docs/en/sandboxing ;
  https://platform.claude.com/docs/en/managed-agents/overview ;
  https://platform.claude.com/docs/en/managed-agents/cloud-sandboxes-reference ;
  https://platform.claude.com/docs/en/about-claude/pricing
- OpenAI Codex: https://learn.chatgpt.com/docs/environments/cloud-environment ;
  https://learn.chatgpt.com/docs/cloud/internet-access ;
  https://learn.chatgpt.com/docs/auth ;
  https://learn.chatgpt.com/docs/third-party/github ;
  https://learn.chatgpt.com/docs/developer-commands?surface=cli ;
  https://learn.chatgpt.com/docs/pricing ; https://learn.chatgpt.com/docs/sandboxing
- Coder: https://coder.com/docs/user-guides/devcontainers ;
  https://coder.com/docs/user-guides/workspace-scheduling ;
  https://coder.com/docs/ai-coder/agents ;
  https://raw.githubusercontent.com/coder/coder/v2.36.0/docs/ai-coder/tasks.md ;
  harmon-infra `terraform/coder/devcontainer/main.tf` (via the GitHub API)
- GitHub Codespaces: https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces ;
  https://docs.github.com/en/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces ;
  https://docs.github.com/en/codespaces/reference/security-in-github-codespaces ;
  https://docs.github.com/en/codespaces/setting-your-user-preferences/configuring-automatic-deletion-of-your-codespaces ;
  https://docs.github.com/en/codespaces/prebuilding-your-codespaces/about-github-codespaces-prebuilds
- Wider field: https://www.daytona.io/docs/en/sandboxes/ ; https://www.daytona.io/pricing ;
  https://docs.e2b.dev/sandbox/persistence ; https://docs.e2b.dev/billing ; https://e2b.dev/pricing ;
  https://modal.com/docs/guide/sandbox ; https://modal.com/docs/guide/sandbox-snapshots ; https://modal.com/pricing ;
  https://developers.cloudflare.com/containers/platform-details/limits/ ; https://developers.cloudflare.com/containers/pricing/ ;
  https://docs.docker.com/ai/sandboxes/security/isolation/ ; https://docs.docker.com/ai/sandboxes/customize/templates/ ;
  https://northflank.com/docs/v1/application/sandboxes/sandboxes-on-northflank ; https://northflank.com/pricing ;
  https://ona.com/docs/ona/runners/overview ; https://ona.com/docs/ona/environments/persistent-storage ; https://ona.com/pricing ;
  https://vercel.com/docs/sandbox/concepts/images ; https://vercel.com/docs/vercel-sandbox/pricing ;
  https://docs.hetzner.com/cloud/servers/faq/ ; https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ ;
  https://docs.runloop.ai/docs/devboxes/configuration/sizes ; https://www.runloop.ai/pricing ;
  https://cloud.morph.so/docs/documentation/instances/ssh ; https://cloud.morph.so/web/subscribe ;
  https://docs.blaxel.ai/Sandboxes/Overview
- This repository and its neighbours: AGENTS.md; docs/guides/herdr.md;
  docs/guides/devcontainers.md; docs/architecture/devcontainer-image.md;
  docs/architecture/security.md; `.foreman.toml`; `.devflow.toml`;
  openspec/changes/bot-autonomy-bootstrap and harness-matrix;
  ponderousdev/foreman `specs/foreman-v2.md` (D1–D14) and issues foreman#8, foreman#30;
  harmon-init#636, harmon-init#690, harmon-init#750, harmon-init#1120 and its comments.
