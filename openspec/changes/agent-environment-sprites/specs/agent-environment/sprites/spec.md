## Purpose

Defines the opt-in Fly.io Sprites lane environment: one Firecracker microVM
per implementer lane running the repository's own bot devcontainer, created,
attached, steered, harvested, and retired from Herdr, with the same
fail-closed bot bootstrap, a narrower credential set than the local bot
container, explicit egress, and cost controls that stop a forgotten lane
from billing.

## ADDED Requirements

### Requirement: The option is a default-off Copier answer that discloses its cost
The template SHALL offer a boolean Copier answer `use_fly_sprites`, asked only
when `devcontainer` is on, defaulting to **no**. Its help text SHALL state,
next to the question, that Fly.io Sprites requires a Fly.io account with
billing enabled, that billing is usage-based (CPU-hours, memory GB-hours, and
storage GB-hours, with no charge while a sprite sleeps), that only a one-time
trial credit is free, and that a private repository needs the bot PAT the lane
already carries plus a read token for any private GHCR package. Turning the
answer off SHALL render no sprite tooling and add no account, token, or
network dependency to the generated repository.

#### Scenario: default render carries no Sprites dependency
- **WHEN** `copier copy --defaults` renders the template
- **THEN** `use_fly_sprites` resolves to `no`, no `taskfiles/sprites.yml`,
  `scripts/sprite-lane.sh`, or `docs/guides/sprites.md` is rendered, the
  rendered `Taskfile.yml` has no `sprite:*` task, and nothing rendered
  references a Fly.io account or the `sprite` CLI

#### Scenario: the question discloses account and pricing terms
- **WHEN** the `use_fly_sprites` question is read in `copier.yml`
- **THEN** its help text names the Fly.io account requirement, the
  usage-based billing model, the trial-only free allowance, and the
  private-repository caveat, and `docs/copier-options.md` carries the same
  row

#### Scenario: opting in renders the lane tooling in both layers
- **WHEN** the template is rendered with `use_fly_sprites: yes`
- **THEN** `taskfiles/sprites.yml`, `scripts/sprite-lane.sh`, and
  `docs/guides/sprites.md` are rendered and `task --list-all` shows the
  `sprite:*` tasks, and this repository's own root layer — with
  `use_fly_sprites: true` recorded in `.dogfood-answers.yml` — carries the
  same files so `test:dogfood-parity` and `test:dogfood-structure` cover
  them

### Requirement: A lane runs the bot devcontainer nested inside the sprite
A lane SHALL run the repository's bot devcontainer — the container built from
`.devcontainer/devcontainer.json` (bot profile) over the pinned shared
`harmon-devcontainer` image — inside the sprite, because Sprites boot a fixed
Ubuntu base and cannot start from a custom OCI image. The sprite SHALL act as
the outer host: `dockerd` runs as a sprite Service so it survives warm and
cold wakes, and the devcontainers CLI brings the container up with the bot
profile's own lifecycle. The bot profile's `post-create.sh` and
`post-start.sh` SHALL run unchanged inside that container, so
`bot-autonomy.sh apply` runs at creation and `bot-autonomy.sh verify` runs at
creation and on every start; a non-zero exit from either SHALL fail lane
creation (or the lane's restart) visibly rather than leaving an agent running
against an unverified policy. The lane SHALL NOT build or maintain a second
toolchain in the sprite's own filesystem: the sprite carries only what the
outer host needs (Docker, the devcontainers CLI, an SSH server, and the lane
helper).

#### Scenario: lane creation brings up the bot profile from the pinned image
- **WHEN** `task sprite:lane:new -- <lane> --issue <n>` runs against a pool
  sprite
- **THEN** the devcontainers CLI builds and starts the bot profile from the
  `FROM` line pinned in `.devcontainer/Dockerfile` (never a floating tag),
  `post-create.sh` runs to completion inside the container, and the lane
  reports the container's `manifest.json` revision matching the pin

#### Scenario: a bot-autonomy verify failure fails the lane
- **WHEN** `bot-autonomy.sh verify` exits non-zero during lane creation or
  on a lane restart
- **THEN** the lane task exits non-zero naming the harness `verify` named,
  starts no agent in the lane, and leaves the sprite in a state the
  operator can inspect (`sprite console`) rather than destroying it

#### Scenario: the sprite's own filesystem holds no agent toolchain
- **WHEN** the golden checkpoint of a pool sprite is inspected
- **THEN** it contains Docker, the devcontainers CLI, an SSH server, the
  lane helper, and the pulled image layers — and no `claude`, `codex`,
  `task`, or other agent-toolchain binary installed on the sprite's own
  Ubuntu filesystem outside the image

### Requirement: Lanes start from a pool sprite's golden checkpoint
Because a checkpoint cannot seed a new sprite, lane creation SHALL draw from
an operator-owned **pool** of sprites, each prepared once by
`task sprite:pool:init`: install the outer-host tooling, pull the pinned
image, bring the bot profile up once so the image layers are on the sprite's
disk, tear the container down, and take a named **golden** checkpoint. The
golden checkpoint SHALL be taken before any credential enters the sprite.
Every lane SHALL begin by restoring its pool sprite's golden checkpoint, so a
lane never inherits a previous lane's checkout, files, or credentials. A pool
sprite whose golden checkpoint predates the current image pin SHALL be
re-initialised before use, never patched in place.

#### Scenario: a lane restores the golden checkpoint before anything else
- **WHEN** a lane is created on a pool sprite that previously hosted another
  lane
- **THEN** the lane restores the golden checkpoint first, and the previous
  lane's `/workspaces` checkout, env-file, and agent state directories are
  absent before the new lane's clone begins

#### Scenario: the golden checkpoint holds no credential
- **WHEN** the golden checkpoint is restored and the inner container is
  started without the lane's credential step
- **THEN** `gh auth status` reports no credential, `~/.codex/auth.json` is
  absent, and `CLAUDE_CODE_OAUTH_TOKEN` is unset inside the container

#### Scenario: a stale golden checkpoint is refused
- **WHEN** the image pin in `.devcontainer/Dockerfile` differs from the pin
  recorded with a pool sprite's golden checkpoint
- **THEN** `task sprite:lane:new` refuses that sprite with a message naming
  `task sprite:pool:init` as the remedy

### Requirement: A lane is one branch cloned from GitHub, never the operator's tree
A lane SHALL check the repository out by cloning from GitHub over HTTPS into
`/workspaces/<repo>` inside the inner container and checking out the lane's
branch; one sprite is one lane is one branch, and the lane creates no linked
worktrees. The lane SHALL NOT copy or sync the operator's working tree,
`.worktrees/`, gitignored files, `.env` files, or local fixtures into the
sprite: anything the lane needs must be committed and pushed first. The
operator MAY keep a local worktree on the same branch for review; it is not
the lane's source.

#### Scenario: the lane clones the pushed branch, not the local checkout
- **WHEN** a lane is created for a branch that exists on the remote and the
  operator's local checkout of that branch has uncommitted or gitignored
  files
- **THEN** the lane's `/workspaces/<repo>` matches the remote branch head
  exactly and none of the uncommitted or gitignored files are present

#### Scenario: an unpushed branch is refused
- **WHEN** `task sprite:lane:new` is asked for a branch that exists locally
  but not on the remote
- **THEN** it refuses before creating anything, naming the push the operator
  owes

### Requirement: Credentials are the bot profile's allow-list, injected per lane, and never the Sprites token
A lane SHALL receive credentials only through the inner container's existing
env-file allow-list (`init-env.sh`), populated by the lane task at creation
from the orchestrator's environment: `GH_TOKEN` (the bot's scoped
fine-grained PAT — write to selected repositories, no workflow or
administration permission, so it can push branches and open draft PRs but
cannot merge `main` or edit workflows), `CLAUDE_CODE_OAUTH_TOKEN`, the Codex
CLI login (`~/.codex/auth.json` copied into the inner container's Codex
state), and, only when the repository opted in, the alternative-provider API
keys. A lane SHALL NOT receive: any 1Password credential or the `op` CLI, an
operator `gh` login, `TS_AUTHKEY`, `ANTHROPIC_API_KEY` (stripped by
`init-env.sh` as today), or the **Sprites API token** — the token is
org-scoped and would let one lane exec into every sibling lane, so it exists
only on the orchestrator's side. Credentials SHALL be injected after the
golden checkpoint is restored and after the egress policy is set, never
baked into a checkpoint, and SHALL be removed by `task sprite:lane:rm`.

#### Scenario: the lane holds the bot PAT and nothing broader
- **WHEN** a lane is created and `gh auth status` and `env` are read inside
  the inner container
- **THEN** `gh` is authenticated as the bot account through `GH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN` is set, and `SPRITES_TOKEN`, `SPRITE_TOKEN`,
  `TS_AUTHKEY`, `ANTHROPIC_API_KEY`, and every `OP_*` variable are unset
  in the container and absent from the sprite's own environment and files

#### Scenario: the Sprites token never enters a sprite
- **WHEN** the lane helper is audited (unit test against the stubbed CLI)
- **THEN** no code path passes the orchestrator's Sprites token, its token
  file, or its keyring into `sprite exec --env`, `sprite exec --file`, the
  env-file, or any file written inside the sprite

#### Scenario: the Codex CLI is logged in without a browser
- **WHEN** a lane is created on an orchestrator whose Codex CLI is logged in
- **THEN** `codex login status` inside the inner container reports the same
  login, so `task challenge` and `task review` run without an interactive
  device-code step

#### Scenario: credential injection happens after checkpoint restore and policy
- **WHEN** the lane creation steps are traced
- **THEN** the order is: restore golden checkpoint, set the egress policy,
  start the inner container, inject credentials, start agents — and no
  credential is written before the policy is in force

### Requirement: Egress is an explicit DNS allowlist the sprite cannot change
Before any credential enters a lane, the lane task SHALL set the sprite's
network policy — through the Sprites API, from the orchestrator's side — to a
DNS allowlist naming: the GitHub hosts git, `gh`, and the shared-image pull
need (`github.com`, `api.github.com`, `ghcr.io`, and the GitHub content and
package hosts those redirect to); the package registries the repository's
`task verify` pulls from (npm, PyPI, the uv/Python index, Homebrew where the
repository uses it); the Anthropic API host; the OpenAI and ChatGPT backend
hosts the Codex CLI uses; and, where the repository uses Convex's anonymous
local mode, the host its local backend binary downloads from. The sprite
SHALL NOT be able to widen the policy from inside (the platform exposes it
read-only there). Any host a lane genuinely needs beyond the list is added to
the list in this repository, reviewed, not opened ad hoc from inside a lane.

#### Scenario: a lane can reach what the dev loop needs and nothing else
- **WHEN** a lane runs `task verify`, `task challenge`, `task review`,
  `task security`, `gh pr create --draft`, and the Convex local backend
  download
- **THEN** each succeeds, and a probe to a host outside the allowlist from
  inside the lane fails to resolve

#### Scenario: the policy is set before credentials and is read-only inside
- **WHEN** a lane is created and the policy file under `/.sprite/policy/`
  is read from inside the sprite
- **THEN** it shows the allowlist the lane task set, it was set before the
  credential step in the lane's own log, and an attempt to write it from
  inside the sprite fails

### Requirement: The full dev loop runs inside the lane
A lane SHALL be able to run every stage the Dev Loop expects of an
implementer up to and including the shepherd stage from inside the inner
container: `task verify`, `task challenge` and `task review` (the Codex CLI
in the bot profile's `danger-full-access`/`never` posture, with the reviewer
runs backgrounded per the gauntlet skill), `task security`, the round commits
and pushes, `gh pr create --draft`, and the shepherd's `gh pr checks`,
`@codex review` trigger, and per-thread replies. Checks the repository's own
`ci` reserves for CI-only infrastructure (a Docker daemon, a browser) stay
CI's job exactly as they do in the local bot container. Codex cloud review
is a GitHub-side action on the PR head and SHALL need nothing from the lane
beyond the PR existing.

#### Scenario: a lane carries a change from implementation to draft PR
- **WHEN** an agent in a lane implements a change and follows the Dev Loop
- **THEN** `task verify`, `task challenge`, `task review`, and
  `task security` each run to completion inside the lane, the round commits
  are pushed by the bot identity, and `gh pr create --draft` opens a draft
  PR whose head is the lane's branch

#### Scenario: Docker-gated checks are not attempted in the lane
- **WHEN** `task ci` is invoked inside a lane
- **THEN** the checks the repository documents as CI-only are skipped or
  refused with the same message they give in the local bot container, and
  `task verify` and `task security` still pass

### Requirement: A lane is created, attached, steered, harvested, and retired from Herdr
The lane tasks SHALL fit the Herdr pane-worker loop without changing it. The
orchestrator's Herdr session (on the laptop or in a Coder devcontainer) SHALL
host **one pane per lane whose foreground process is the lane's sprite
session** — a TTY exec into the inner container that launches the worker's
harness — so that Herdr's terminal-based state detection (`working`,
`blocked`, `idle`, `done`, `unknown`) applies to the remote agent through
that pane, `herdr pane run` delivers the brief, and `herdr pane wait-output`
waits on the per-attempt sentinel. The brief SHALL end with a file-based
report at a path inside the lane and a sentinel line unique per attempt;
`task sprite:lane:harvest` SHALL copy that report out of the lane. Where
Herdr classifies the remote agent as `unknown`, the report and sentinel are
the success signal, as the Herdr guide already states for weak detection.
The sprite session SHALL be detachable: if the orchestrator's pane dies, the
worker keeps running and the operator reattaches with
`task sprite:lane:attach -- <lane>` (the platform's session attach) or, for
a full Herdr UI inside the lane, with `herdr --remote` over the lane's SSH
server. Retirement (`task sprite:lane:rm -- <lane>`) SHALL stop the inner
container, remove injected credentials, restore the golden checkpoint, and
return the sprite to the pool (or destroy it with `--destroy`), and SHALL
refuse while the lane's branch has unpushed commits unless `--force` is
given.

#### Scenario: a lane pane shows the remote agent's state
- **WHEN** the orchestrator runs `herdr pane run <id> "task sprite:lane:exec
  -- <lane> claude --model <m> ..."` and then `herdr agent explain <id>`
- **THEN** the pane's agent is classified by Herdr from the terminal stream
  (`working`/`blocked`/`idle`/`done`), or, where it is `unknown`, the lane's
  report file and sentinel are documented as the success signal and
  `pane wait-output --match <sentinel>` still returns when the worker prints
  it

#### Scenario: the worker survives the orchestrator's pane
- **WHEN** the orchestrator's pane hosting a lane session is closed while
  the remote agent is `working`
- **THEN** the remote agent keeps running, `task sprite:lane:attach --
  <lane>` reattaches to the same session, and the report file still lands

#### Scenario: harvest copies the report out and verifies nothing
- **WHEN** `task sprite:lane:harvest -- <lane> --report <path>` runs after
  the sentinel appears
- **THEN** the report file is copied to the orchestrator's scratch directory
  and the task prints where; verifying the lane's claims (the diff, the PR,
  the labels) remains the orchestrator's step, as the Herdr guide requires

#### Scenario: the operator takes a lane over with a full Herdr UI
- **WHEN** the operator runs `herdr --remote <lane-ssh-alias>` where the
  alias's `ProxyCommand` is the platform's port proxy to the lane's SSH
  Service
- **THEN** a Herdr thin client attaches to a Herdr server running inside the
  inner container, and detaching leaves the agents running

#### Scenario: retirement refuses to drop unpushed work
- **WHEN** `task sprite:lane:rm -- <lane>` runs while the lane's branch has
  commits not on the remote
- **THEN** it refuses, names the unpushed commits, and does nothing unless
  `--force` is given

### Requirement: Sleep is free, work holds the lane awake, and nothing bills unnoticed
The lane helper SHALL hold the sprite awake with the platform's Tasks API
only while at least one agent in the lane is `working` or a gate is running,
renewing the hold on a heartbeat and releasing it when every agent is idle,
so an idle lane sleeps and stops compute billing. A lane SHALL carry a TTL
(default 12 hours, set per lane) after which `task sprite:audit` reports it
as expired and `task sprite:lane:rm` is the expected action; the helper SHALL
NOT destroy a lane on its own. `task sprite:audit` SHALL list every pool
sprite and lane with its state, age, TTL, and the issue it was created for,
using the platform's labels, so a forgotten lane is visible in one command.
The pool size SHALL be capped by a configured ceiling no higher than the
operator's Fly plan concurrency limit, and `task sprite:pool:init` SHALL
refuse to exceed it.

#### Scenario: an idle lane sleeps
- **WHEN** every agent in a lane has been idle for longer than the platform's
  idle window and no gate is running
- **THEN** no Tasks-API hold is live, the sprite reports `warm` or `cold`,
  and the next `sprite:lane:attach` or `sprite:lane:exec` wakes it with the
  checkout and container state intact

#### Scenario: a running gate is not paused mid-run
- **WHEN** `task verify` is running inside a lane and the orchestrator's
  pane disconnects
- **THEN** the lane's hold keeps the sprite active until the gate exits, and
  the gate's output file is complete when the orchestrator reattaches

#### Scenario: audit lists every lane with its age
- **WHEN** `task sprite:audit` runs
- **THEN** it prints one row per pool sprite and lane with name, state, age,
  TTL, issue, and golden-checkpoint pin, flags expired lanes, and exits
  non-zero when any lane is past its TTL

#### Scenario: the pool refuses to exceed its ceiling
- **WHEN** `task sprite:pool:init` would create more pool sprites than the
  configured ceiling
- **THEN** it refuses, naming the ceiling and the plan limit it mirrors

### Requirement: Dispatch selects the environment explicitly
The interactive dispatch recipe SHALL select a sprite lane only by an
explicit `--env sprite` (or the equivalent environment argument) on the lane
task; a local pane worker in a worktree remains the default and nothing
about a `rigor:*` or `strategy:*` label, a `.devflow.toml` value, or the
issue text selects a sprite. For Foreman, `.foreman.toml`'s `runner` key is
the selector: this change documents that `runner = "sprite"` names the
nested-devcontainer lane described here, does not change the configured
value, and records that Foreman's isolated runner remains Foreman-side work.

#### Scenario: no label or config value selects a sprite on its own
- **WHEN** an issue carries any `rigor:*`, `strategy:*`, or `tier:*` label
  and the dispatch recipe is followed without `--env sprite`
- **THEN** the worker is a local pane worker and no sprite is created

#### Scenario: Foreman's runner value is documented, not flipped
- **WHEN** `.foreman.toml` is read after this change is implemented
- **THEN** `runner` still reads `"local"`, and the comment above it explains
  what `"sprite"` will mean and that dispatch under it stays refused until
  Foreman ships the runner

### Requirement: The lane helper is unit-tested offline against a stubbed CLI
`scripts/sprite-lane.sh` SHALL be covered by an offline unit test
(`task test:sprite-lane`, part of `task verify` in the root) that runs it
against a stubbed `sprite` binary and a stubbed devcontainers CLI and
asserts the ordering and refusal rules above: restore before policy before
credentials before agents; refusal of unpushed branches, stale golden
checkpoints, pool overflow, and unpushed-work retirement; and that the
Sprites token never appears in any argument or file the helper writes.

#### Scenario: the offline test enforces the lane ordering
- **WHEN** `task test:sprite-lane` runs with the stubbed CLIs recording every
  invocation
- **THEN** it fails if the recorded order ever places credential injection
  before the checkpoint restore or the network-policy call, and passes on
  the shipped helper

#### Scenario: the offline test enforces every refusal
- **WHEN** `task test:sprite-lane` drives the helper through an unpushed
  branch, a stale golden checkpoint, a full pool, and a retirement with
  unpushed commits
- **THEN** each case exits non-zero with the documented message and the
  stubs record no create, restore, or destroy call for it
