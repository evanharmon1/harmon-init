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
billing enabled, that billing is usage-based (CPU-hours and memory GB-hours
while a sprite is active, and storage GB-hours at all times — a sleeping
sprite stops compute charges but its stored bytes, image layers included,
keep billing), that only a one-time trial credit is free, that a private
repository is supported through the bot PAT the lane already carries, and
that this version supports only a **publicly pullable** devcontainer base
image (the shared `harmon-devcontainer` image is public) — a private base
registry needs a scoped read-credential path and is a named follow-up, not
a supported case. Turning the answer off SHALL render no sprite tooling
and add no account, token, or network dependency to the generated
repository.

#### Scenario: default render carries no Sprites dependency
- **WHEN** `copier copy --defaults` renders the template
- **THEN** `use_fly_sprites` resolves to `no`, no `taskfiles/sprites.yml`,
  `scripts/sprite-lane.sh`, or `docs/guides/sprites.md` is rendered, the
  rendered `Taskfile.yml` has no `sprite:*` task, and no rendered task,
  script, configuration file, or documentation page references the
  `sprite` CLI or a Fly.io account — the documentation sections that
  describe the option are rendered only when the answer is on

#### Scenario: the question discloses account and pricing terms
- **WHEN** the `use_fly_sprites` question is read in `copier.yml`
- **THEN** its help text names the Fly.io account requirement, the
  usage-based billing model including that storage bills while a sprite
  sleeps, the trial-only free allowance, the private-repository caveat,
  and the public-base-image-only limit, and `docs/copier-options.md`
  carries the same row

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
against an unverified policy. Pool initialisation and every lane SHALL run
the bot profile under one **lane marker**, `HARMON_LANE=1`: the helper sets
it in the environment of every `devcontainer up` and every lane command,
and the bot profile's `devcontainer.json` (root and template twins) SHALL
forward it into the container as `containerEnv.HARMON_LANE` from
`${localEnv:HARMON_LANE}`, so it reaches `postCreateCommand`,
`postStartCommand`, and every process in the container — an unset marker
arrives as the empty string, which every guard treats as unset. The
Agent Deck conductor lifecycle (`post-create-conductor.sh`, and the
conductor-start and Telegram-bridge blocks of `post-start-common.sh`) and
related-repository bootstrap (`bootstrap-related-repos.sh`,
`fetch-related-repos.sh`) SHALL skip themselves when the marker is set (a
lane also never carries `AGENT_DECK_TELEGRAM_KEY`, so no registration can
be created inside one). The golden checkpoint SHALL contain no conductor
registration (the `~/.agent-deck` volume it bakes in holds no conductor
entry, and `agent-deck conductor status <repo>` reports none), so
post-start in a lane never starts a background agent from the volume, and
any agent process in a lane SHALL start only through the supervised
`lane:exec` path. The lane
SHALL NOT build or maintain a second toolchain in the sprite's own
filesystem: the sprite carries only what the outer host needs (Docker, the
devcontainers CLI, and the lane helper); the SSH server the takeover path
needs runs inside the inner container, never on the outer host.

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

#### Scenario: the lane marker reaches the container's lifecycle scripts
- **WHEN** a lane's `devcontainer up` runs with `HARMON_LANE=1` in its
  environment
- **THEN** `postCreateCommand` and `postStartCommand` observe
  `HARMON_LANE=1` inside the container (forwarded by the twins'
  `containerEnv`), each guard they run reports the marker as set, and the
  offline test asserts both that the helper's `devcontainer up`
  environment carries the marker and that the rendered `devcontainer.json`
  twins forward it

#### Scenario: post-start in a lane starts no background agent
- **WHEN** the inner container of a lane (or of a pool sprite during
  initialisation) runs `post-start.sh`
- **THEN** `HARMON_LANE=1` is set in its environment, the conductor-start
  and Telegram-bridge blocks are skipped, no `agent-deck session start` or
  `bridge.py` process appears, the golden checkpoint's `~/.agent-deck`
  volume holds no conductor registration (asserted by the real-run check
  and by the offline test's inspection of the environment handed to
  `devcontainer up`), and the only agent processes in the lane are children
  of a supervised `lane:exec`

#### Scenario: the lane helper installs no agent toolchain on the outer host
- **WHEN** the golden checkpoint of a pool sprite is inspected and its
  package and binary inventory is diffed against a fresh, untouched sprite
  of the same platform base
- **THEN** the difference is exactly Docker, the devcontainers CLI, the
  lane helper, and the pulled image layers and volumes — no `task`,
  `herdr`, agent harness, or SSH server was installed or upgraded on the
  outer host by the helper; whatever the platform's fixed base already
  ships (it includes Claude and Codex CLIs today) is exempt, unused by
  the lane, and never relied on

### Requirement: Lanes start from a pool sprite's golden checkpoint, claimed and restored to completion
Because a checkpoint cannot seed a new sprite, lane creation SHALL draw from
an operator-owned **pool** of sprites, each prepared once by
`task sprite:pool:init`: install the outer-host tooling, clone the
repository's default branch onto the outer host (for a private repository,
with the bot PAT supplied to git's credential helper from the exec
environment only — never written to the sprite's filesystem), bring the bot
profile up once so the pinned image layers and the devcontainer's named
volumes exist on the sprite's disk, tear the containers down, remove the
checkout (its env-file with it), and only then take a named **golden**
checkpoint. The golden checkpoint is defined by its content: it SHALL
contain no credential and no repository checkout, whether the repository
is public or private. Every golden checkpoint SHALL be recorded with a
**golden stamp** covering everything the checkpoint bakes in that the
repository can change: the image pin from `.devcontainer/Dockerfile`, a
hash of `scripts/sprite-lane.sh` and of the in-sprite supervisor it
installs, and the pinned devcontainers CLI version. A pool sprite whose
recorded stamp differs from the stamp computed from the current tree — a
moved image pin, a changed helper or supervisor, or a bumped CLI pin,
alone or together — SHALL be re-initialised before use, never patched in
place.

Lane creation SHALL **claim** a pool sprite before touching it, under the
per-sprite lane lock of the lane-lock requirement below: a claim is a lease
recorded on the sprite's labels (owner, lane name, pool sprite name, issue,
expiry) — labels **record** the lease and never arbitrate it; the lock does
— and concurrent `lane:new` invocations on one orchestrator therefore never
select the same sprite. A leased sprite SHALL NOT be restored, retired, or
reclaimed by anyone but its owner or, once the lease has expired, the audit
owner. A lease SHALL be
**renewed** by the configured lease window on every authenticated lane
activity (`lane:exec`, `lane:attach`, `lane:harvest`) and by
`task sprite:lane:extend`, and its expiry SHALL never be earlier than the
lane's TTL, so a lane that is alive and within its TTL is never reported
reclaimable. **Reclaim is retirement:** `task sprite:audit --reclaim` is
`task sprite:lane:rm` invoked by the audit owner on an expired lease,
after the confirmation prompt — the same lane lock held for the same span,
the same activity evaluation, the same cleanliness gate (porcelain and
upstream), and the same `--force` required to discard work; it is written
once and reclaim references it, never a second procedure. An expired lease
is a bookkeeping fact, never a licence to terminate work or discard it.

Every lane SHALL begin by restoring its claimed sprite's golden checkpoint
**and waiting for that restore to complete** — the platform restores
asynchronously and terminates active sessions while it does — before any
later step (policy, credentials, clone, container start) runs, so a lane
never inherits a previous lane's checkout, files, or credentials and never
has its own setup erased by a restore still in flight. The lease SHALL
carry a **restore state** (`restoring`, `complete`, `failed`); every entry
command (`lane:exec`, `lane:attach`, `lane:harvest`, `lane:extend`)
requires the platform to report the lane's restore terminal and
successful and otherwise refuses naming the state; a `lane:new` that times
out waiting leaves the lease in `restoring` and prints how to resume
(re-running `task sprite:lane:new` for the same lane resumes at the
restore wait rather than restoring again).

#### Scenario: a lane restores the golden checkpoint and waits before anything else
- **WHEN** a lane is created on a pool sprite that previously hosted another
  lane
- **THEN** the helper restores the golden checkpoint, polls the platform
  until the restore reports complete, and only then proceeds; the previous
  lane's `/workspaces` checkout, env-file, and agent state directories are
  absent when the new lane's next step begins

#### Scenario: an incomplete restore blocks every later step
- **WHEN** the platform reports the restore still in progress (or fails to
  report completion within the helper's timeout)
- **THEN** the helper performs no policy, credential, clone, or container
  step, exits non-zero naming the restore state, leaves the lease in
  `restoring`, and prints the resume command

#### Scenario: entry during a pending restore refuses
- **WHEN** `lane:exec`, `lane:attach`, `lane:harvest`, or `lane:extend` is
  issued for a lane whose lease is in `restoring` (or whose restore the
  platform reports as not yet terminal)
- **THEN** it refuses naming the restore state before any session, policy,
  or container call, and the offline test records no such call

#### Scenario: two concurrent lane creations never claim the same sprite
- **WHEN** two `task sprite:lane:new` invocations start within the same
  second on one orchestrator against a pool with two idle sprites
- **THEN** each ends up owning a different sprite, and the offline test's
  stubbed CLI records exactly one lease write per sprite

#### Scenario: a claimed sprite is refused to a second owner
- **WHEN** a `lane:new` invocation reads back a lease naming another owner
  after its own lease write
- **THEN** it treats the sprite as taken, performs no restore on it, and
  retries with the next idle pool sprite or exits non-zero naming the
  contention when none remains

#### Scenario: an expired lease is reclaimed only by audit, and only when idle
- **WHEN** a pool sprite carries a lease past its expiry and no `lane:rm`
  has run
- **THEN** `task sprite:lane:new` skips it, `task sprite:audit` reports it
  as expired, and only `task sprite:audit --reclaim` (after confirmation)
  releases the lease — restoring the golden checkpoint on reclaim, so the
  next lane still starts clean

#### Scenario: reclaim refuses while a lane command is still running
- **WHEN** `task sprite:audit --reclaim` targets a sprite whose lease has
  expired but which still has a lane session recorded (or, failing the
  record, a live session on the platform)
- **THEN** it refuses, names the session, releases the lock with nothing
  changed, and leaves the lease in place — exactly as `lane:rm` would

#### Scenario: reclaim on an idle but unclean checkout refuses without --force
- **WHEN** `task sprite:audit --reclaim` targets a sprite whose lease has
  expired, with no live session on the platform, but whose checkout is not
  clean (modified, staged, untracked, or ignored files, or commits not on
  its upstream, in any checkout under `/workspaces`)
- **THEN** it refuses naming what is uncommitted or unpushed, releases the
  lock with nothing changed, and proceeds only when `--force` is given —
  the same cleanliness gate and the same `--force` as retirement, and the
  offline test records no restore call without it

#### Scenario: a long-lived valid lane is never reported reclaimable
- **WHEN** a lane runs for longer than the lease window with authenticated
  activity (`lane:exec`, `lane:attach`, `lane:harvest`) or `lane:extend`
  calls spread across that time, and its TTL has not expired
- **THEN** every such call renewed the lease, its expiry is never earlier
  than the TTL, `task sprite:audit` never reports the lease expired, and
  `audit --reclaim` refuses it as not reclaimable

#### Scenario: the golden checkpoint holds no credential and no checkout
- **WHEN** the golden checkpoint is restored and the inner container is
  started without the lane's credential step
- **THEN** `/workspaces` holds no repository checkout and no env-file, and
  once a checkout is restored `gh auth status` reports no credential,
  `~/.codex/auth.json` is absent, and `CLAUDE_CODE_OAUTH_TOKEN` is unset
  inside the container

#### Scenario: pool init on a private repository leaves no credential behind
- **WHEN** `task sprite:pool:init` prepares a sprite for a private
  repository, cloning with the bot PAT supplied through git's credential
  helper from the exec environment
- **THEN** the real-run check greps the restored golden checkpoint's
  filesystem (outer host and the devcontainer's volumes) for the PAT and
  finds nothing, and the offline test records no `sprite exec --file` or
  git config write carrying the token — the checkout's env-file, the one
  file `init-env.sh` writes it to during the pool's single `devcontainer
  up`, is removed with the checkout before the checkpoint is taken

#### Scenario: a stale golden checkpoint is refused
- **WHEN** any component of the golden stamp computed from the current
  tree — the image pin in `.devcontainer/Dockerfile`, the hash of
  `scripts/sprite-lane.sh` or its in-sprite supervisor, or the pinned
  devcontainers CLI version — differs from the stamp recorded with a pool
  sprite's golden checkpoint
- **THEN** `task sprite:lane:new` refuses that sprite, names the component
  that changed, and names `task sprite:pool:init` as the remedy

#### Scenario: a helper-only change stales the golden checkpoint
- **WHEN** `scripts/sprite-lane.sh` (or the supervisor it installs) changes
  on the current tree while the image pin and the devcontainers CLI pin are
  unchanged
- **THEN** `task sprite:lane:new` refuses every pool sprite whose recorded
  stamp predates that change, and the offline test drives this case with
  the stubbed CLI's canned label output and records no restore call

### Requirement: One orchestrator-side lane lock per sprite serialises every start and every end
**Precondition:** one pool is driven from exactly one orchestrator at a
time; sharing a pool across orchestrators is unsupported and is the named
follow-up. Under that precondition, for each pool sprite there SHALL be
exactly one **lane lock**: an orchestrator-side advisory `flock` on a
per-sprite lock file keyed by the pool sprite's platform name, held in the
orchestrator's lane state directory. `flock` is a prerequisite on the
orchestrator (util-linux on Linux; `brew install flock` on macOS), and the
helper SHALL check for it — and for the `sprite` CLI — at startup, refusing
with the install hint before any platform call; no home-grown lock is
substituted. Labels on the sprite record the lease; they never arbitrate
anything. There is no other lock, no persistent "closing" state, and no
registration of a session before the session exists. The platform's
session list is the **only authority on activity**: the identifiers the
helper records after creating a session are a cache, discarded on every
reconcile when the platform no longer lists them, and never by themselves
a reason to refuse. The following SHALL hold for every interleaving:

- Every lane-ending operation (`lane:rm`, and `audit --reclaim`, which is
  `lane:rm`) holds the lock from its first check until the golden restore
  has reported complete and the lease is released. A refused retirement
  releases the lock with nothing changed, and the lane is usable again at
  once. While an ending operation holds the lock, `lane:exec`,
  `lane:attach`, `lane:harvest`, and `lane:extend` do not block: they
  refuse immediately with `retiring <lane>` and exit non-zero.
- Command startup (`lane:exec`, `lane:attach`, `lane:harvest`) holds the
  lock only from its checks (restore state terminal and successful, TTL,
  lease ownership) through creating the platform session and recording
  that session's identifier in the lane's state, then releases it before
  the command's body runs. Nothing is recorded before the session exists,
  so a crash mid-startup leaves at worst a real platform session, which an
  ending operation's activity check sees on the platform.
- `lane:extend` takes the same lock, validates lease ownership, writes the
  new TTL to the lane-local state inside the sprite first (the file the
  in-sprite supervisor reads), then updates the lease's TTL and expiry.

The invariant is what the offline test asserts, by driving each
interleaving below deterministically with one side holding the stubbed
lock and the other refused.

#### Scenario: exec and retirement contend for the lock and only one proceeds
- **WHEN** `lane:rm` and `lane:exec` contend for the lane lock of one
  sprite at the same instant
- **THEN** exactly one acquires it; if `lane:exec` wins, its session is
  created under the lock and the `lane:rm` that follows sees it live on
  the platform and refuses; if `lane:rm` wins, the `lane:exec` is refused
  with `retiring <lane>` and no session is created; the stubbed lock
  records a single holder at any time and no restore ever runs while the
  platform reports a live session

#### Scenario: a refused retirement leaves the lane usable at once
- **WHEN** `lane:rm` takes the lock and refuses (a live platform session,
  or a non-clean checkout without `--force`)
- **THEN** it releases the lock having changed nothing — no lease change,
  no state file, no container stop — and a `lane:exec` issued immediately
  afterwards acquires the lock and runs

#### Scenario: extend during reclaim refuses
- **WHEN** `audit --reclaim` holds the lane lock on an expired-lease sprite
  and `lane:extend` is issued for that lane
- **THEN** `lane:extend` refuses with `retiring <lane>` and changes neither
  the TTL nor the lease; after the reclaim completes, the lease no longer
  belongs to that lane and `lane:extend` refuses on ownership

#### Scenario: a stale session record never blocks retirement
- **WHEN** a detached lane command has finished, the lane's cached session
  record still names it, and `lane:rm` runs
- **THEN** the activity check consults the platform's session list, finds
  no live session, discards the stale record, and the retirement proceeds
  to the cleanliness gate; the offline test drives it with a stubbed
  platform that lists no session against a cache that does

#### Scenario: a missing flock refuses before any platform call
- **WHEN** any lane command runs on an orchestrator without `flock` (or
  without the `sprite` CLI) on `PATH`
- **THEN** the helper exits non-zero naming the missing prerequisite and
  the install hint (util-linux; `brew install flock` on macOS), and the
  offline test records no `sprite` invocation at all

#### Scenario: a crash mid-startup leaves no phantom registration
- **WHEN** a `lane:exec` crashes after taking the lock and before recording
  a session (or after creating the platform session but before recording
  it)
- **THEN** the lock is released by the crash, the lane's state records no
  session that does not exist on the platform, and a subsequent `lane:rm`
  decides from the platform's own session list — refusing if the crashed
  startup left a live session, proceeding if it did not — with the offline
  test driving both crash points

### Requirement: A lane is one branch cloned from GitHub, never the operator's tree
A lane SHALL check the repository out by cloning from GitHub over HTTPS
onto the outer host at `/workspaces/<repo>` — the workspace folder the
devcontainers CLI reads `.devcontainer/` from and bind-mounts into the
inner container — before `devcontainer up`, with the bot PAT supplied to
git's credential helper from the exec environment and never written to
the outer host's filesystem; inside the container the same checkout is
`/workspaces/<repo>` and `post-create.sh`'s `gh auth setup-git` takes over
credentials from there. The lane's source of truth is the **remote branch
head**: one sprite is one lane is one branch, the lane creates no linked
worktrees, and creation SHALL refuse when the requested branch is absent
from the remote or when a local branch of that name on the orchestrator is
ahead of the fetched remote head, naming the push owed. The lane SHALL NOT
copy or sync the operator's working tree, `.worktrees/`, gitignored files,
`.env` files, or local fixtures into the sprite: anything the lane needs
must be committed and pushed first. The operator MAY keep a local worktree
on the same branch for review; it is not the lane's source.

#### Scenario: the lane clones the pushed branch, not the local checkout
- **WHEN** a lane is created for a branch that exists on the remote and the
  operator's local checkout of that branch has uncommitted or gitignored
  files
- **THEN** the lane's `/workspaces/<repo>` matches the remote branch head
  exactly and none of the uncommitted or gitignored files are present

#### Scenario: an unpushed or ahead branch is refused
- **WHEN** `task sprite:lane:new` is asked for a branch that is absent from
  the remote, or whose local branch on the orchestrator is ahead of the
  fetched remote head
- **THEN** it refuses before claiming or restoring anything, naming the
  push the operator owes and the commits not on the remote

#### Scenario: the clone precedes the container and lands in the workspace folder
- **WHEN** a lane is created
- **THEN** the offline test records the clone onto the outer host at
  `/workspaces/<repo>` before the `devcontainer up` call, and `devcontainer
  up` is invoked with that folder as its workspace

### Requirement: Credentials are an explicit lane allow-list, delivered through the devcontainer's own lifecycle, and never the Sprites token
A lane SHALL receive credentials only through the inner container's existing
env-file mechanism: the lane helper runs `devcontainer up` inside the sprite
with the lane's allow-listed variables present in that command's
environment, so the bot profile's own `initializeCommand` (`init-env.sh`)
captures them from the host environment exactly as it does on Coder, the
env-file exists before the container is created, and `post-create.sh` finds
`gh` authenticated when it runs. The lane's allow-list is **explicit and
narrower than the bot profile's own**: the helper passes exactly `GH_TOKEN`
(the bot's scoped fine-grained PAT — write to selected repositories, no
workflow or administration permission, so it can push branches and open
draft PRs but cannot merge `main` or edit workflows) and
`CLAUDE_CODE_OAUTH_TOKEN`, plus the alternative-provider API keys only when
the repository opted in — it SHALL NOT forward the bot profile's
`initializeCommand` list wholesale. Where the repository rendered
`use_codex_review` on, the Codex CLI login (`~/.codex/auth.json`) is copied
into the inner container's Codex state after the container is up and
before any agent starts; where it is off, nothing Codex-related enters the
lane. The env-file `init-env.sh` composes,
`.devcontainer/devcontainer.env` inside the checkout, is the one file the
PAT may be written to: it SHALL be mode `0600`, removed at retirement with
the checkout, and never present in a checkpoint. A lane SHALL NOT receive:
`FOREMAN_AGENT_GH_TOKEN` and `AGENT_DECK_TELEGRAM_KEY` (both on the bot
profile's allow-list, neither needed by a lane), any alternative-provider
key the repository did not opt into, any 1Password credential or the `op`
CLI, an operator `gh` login, `TS_AUTHKEY`, `ANTHROPIC_API_KEY` (stripped by
`init-env.sh` as today), or the **Sprites API token** — the token is
org-scoped and would let one lane exec into every sibling lane, so it
exists only on the orchestrator's side.
The lane's step order SHALL be: claim, restore-and-wait, egress policy,
clone onto the outer host (PAT through the credential helper only),
`devcontainer up` with the credentials in its environment (which populates
the env-file and runs post-create), Codex login copy, SSH key
provisioning, agents — credentials never precede the completed restore or
the policy, and are never baked into a checkpoint. `task sprite:lane:rm` SHALL remove them (env-file, Codex state,
and any process environment) before the golden checkpoint is restored.

#### Scenario: the lane holds the bot PAT and nothing broader
- **WHEN** a lane is created and `gh auth status` and `env` are read inside
  the inner container
- **THEN** `gh` is authenticated as the bot account through `GH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN` is set, and `FOREMAN_AGENT_GH_TOKEN`,
  `AGENT_DECK_TELEGRAM_KEY`, every alternative-provider key the repository
  did not opt into, `SPRITES_TOKEN`, `SPRITE_TOKEN`, `TS_AUTHKEY`,
  `ANTHROPIC_API_KEY`, and every `OP_*` variable are unset in the container
  and absent from the sprite's own environment and files

#### Scenario: the Sprites token never enters a sprite, and the allow-list is exact
- **WHEN** the lane helper is audited (unit test against the stubbed CLI)
  with `FOREMAN_AGENT_GH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`, an un-opted
  provider key, and the Sprites token all present in the orchestrator's
  environment
- **THEN** no code path passes the orchestrator's Sprites token, its token
  file, or its keyring into `sprite exec --env`, `sprite exec --file`, the
  env-file, or any file written inside the sprite, and the environment the
  helper hands to `sprite exec` and `devcontainer up` contains exactly
  `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and the opted-in provider keys —
  `FOREMAN_AGENT_GH_TOKEN` and `AGENT_DECK_TELEGRAM_KEY` never appear

#### Scenario: post-create finds gh authenticated
- **WHEN** `devcontainer up` runs for a lane and `post-create.sh` reaches its
  `gh auth status` check
- **THEN** the check succeeds and `gh auth setup-git` runs, because the
  env-file `init-env.sh` composed from the `devcontainer up` environment
  already carried `GH_TOKEN` when the container was created

#### Scenario: the Codex CLI is logged in without a browser
- **WHEN** the repository rendered `use_codex_review` on and a lane is
  created on an orchestrator whose Codex CLI is logged in
- **THEN** `codex login status` inside the inner container reports the same
  login, so `task challenge` and `task review` run without an interactive
  device-code step; with the option off, no Codex login is copied and no
  `~/.codex/auth.json` exists in the lane

#### Scenario: the env-file is the only file that carries the PAT
- **WHEN** a lane is created and the sprite's filesystem is searched for the
  PAT (real run), and the offline test inspects every file the helper
  writes
- **THEN** the PAT appears in exactly one file, the checkout's
  `.devcontainer/devcontainer.env` with mode `0600`, and in no file the
  helper itself writes; after `lane:rm` it appears in no file at all, and
  it is absent from every checkpoint

#### Scenario: credentials follow the completed restore and the policy
- **WHEN** the lane creation steps are traced
- **THEN** the order is: claim, restore reported complete, egress policy
  set, clone onto the outer host, `devcontainer up` with credentials in
  its environment, Codex login copy, SSH key provisioning, agents — and no
  credential is present in any `sprite exec` environment, file, or the
  env-file before the policy is in force

### Requirement: Egress is an explicit DNS allowlist the sprite cannot change
Before any credential enters a lane, the lane task SHALL set the sprite's
network policy — through the Sprites API, from the orchestrator's side — to
a DNS allowlist under which the **unconditional loop** passes and a host
outside the list fails to resolve: `task verify`, `task security`, the
round pushes, `gh pr create --draft`, `gh pr checks`, and, where the
repository opted in, `task challenge`/`task review` and the Convex local
backend download. The allowlist is a **feasibility-spike deliverable**,
not a hand-written enumeration: tasks § 0 runs that loop under a
deny-by-default policy, iterates until it passes, and records every host
it needed — Semgrep's rule registry and API included — as the list shipped
in `taskfiles/sprites.yml`; the design notes carry the known starting
points. The SSH provisioning step installs `openssh-server` into the inner
container with `apt`, so for exactly that step the policy SHALL
additionally name the base image's Ubuntu package hosts —
`archive.ubuntu.com` and `security.ubuntu.com`, the URIs in the shared
image's `ubuntu.sources` (the image is amd64 Ubuntu 24.04) — with
`apt-get update` restricted to the Ubuntu sources so the image's
third-party package lists are never fetched, and the steady-state policy
SHALL be restored on **every** exit path of that step, success or failure
(the policy reloads live, which is the phase mechanism). Baking
`openssh-server` into the shared image so those two hosts can be dropped
is a named follow-up. The sprite SHALL NOT be able to widen the policy
from inside (the platform exposes it read-only there). Any host a lane
genuinely needs beyond the list is added to the list in this repository,
reviewed, not opened ad hoc from inside a lane.

#### Scenario: the unconditional loop passes under the policy, proven by the spike
- **WHEN** the feasibility spike (tasks § 0) runs `task verify`,
  `task security`, a push, `gh pr create --draft`, `gh pr checks`, and the
  opted-in Codex and Convex steps inside a lane under the recorded
  allowlist
- **THEN** each succeeds, a probe to a host outside the list from inside
  the lane fails to resolve, and the recorded list is the one shipped —
  the spike's log is the proof, and a later change to the loop that
  needs a new host re-runs the spike rather than editing the list by hand

#### Scenario: SSH provisioning succeeds under the policy
- **WHEN** a lane's SSH provisioning step runs after the DNS allowlist is in
  force
- **THEN** the helper adds `archive.ubuntu.com` and `security.ubuntu.com`
  to the policy, `apt-get update` restricted to the Ubuntu sources and
  `apt-get install openssh-server` succeed inside the inner container, the
  helper restores the steady-state policy, and a probe to either host from
  the lane afterwards fails to resolve; the offline test records the two
  policy writes bracketing the install

#### Scenario: a failed provisioning leaves the narrow policy in place
- **WHEN** the `apt-get install` inside a lane's SSH provisioning step fails
  (or the helper is interrupted after widening the policy)
- **THEN** the steady-state policy is restored on that exit path before the
  helper exits non-zero, a probe to `archive.ubuntu.com` from the lane
  afterwards fails to resolve, and the offline test drives both the
  failure and the interruption and records the restoring policy write in
  each

#### Scenario: the policy is set before credentials and is read-only inside
- **WHEN** a lane is created and the policy file under `/.sprite/policy/`
  is read from inside the sprite
- **THEN** it shows the allowlist the lane task set, it was set before the
  credential step in the lane's own log, and an attempt to write it from
  inside the sprite fails

### Requirement: The full dev loop runs inside the lane
A lane SHALL be able to run every stage the Dev Loop expects of an
implementer up to and including the shepherd stage from inside the inner
container, for changes that touch nothing under `.github/workflows/**` —
the bot PAT a lane carries is deliberately denied the Workflows permission,
so GitHub rejects a push that adds or edits a workflow file. Unconditionally
— for every render with the option on — that is `task verify`,
`task security`, the round commits and pushes, `gh pr create --draft`, and
the shepherd's `gh pr checks` and per-thread replies. A change that does
touch `.github/workflows/**` SHALL be handed off: the lane commits locally
and never pushes, `task sprite:lane:harvest -- <lane> --bundle` exports the
lane branch as a git bundle to the orchestrator, and the operator applies
it in a local checkout and pushes with their own credential; the helper
SHALL detect a workflow-touching commit on the lane branch and name that
handoff instead of attempting the push — and the guard SHALL live on the
real push path, not only in the helper: a Taskfile-backed
`guard:lane-workflow-push`, run from the repository's lefthook `pre-push`
hook and active only when the lane marker `HARMON_LANE` is set, so a plain
`git push` typed inside the lane refuses before contacting GitHub. Where the repository also rendered `use_codex_review` on, it
includes `task challenge` and `task review` (the Codex CLI in the bot
profile's `danger-full-access`/`never` posture, with the reviewer runs
backgrounded per the gauntlet skill); where it additionally rendered
`use_codex_cloud_review` on and the repository is connected to Codex cloud,
it includes the shepherd's `@codex review` trigger. Checks the repository's
own `ci` reserves for CI-only infrastructure (a Docker daemon, a browser)
stay CI's job exactly as they do in the local bot container. Codex cloud
review, where connected, is a GitHub-side action on the PR head and SHALL
need nothing from the lane beyond the PR existing.

#### Scenario: a lane carries a change from implementation to draft PR
- **WHEN** an agent in a lane implements a change and follows the Dev Loop
  in a render with only `use_fly_sprites` on
- **THEN** `task verify` and `task security` each run to completion inside
  the lane, the round commits are pushed by the bot identity,
  `gh pr create --draft` opens a draft PR whose head is the lane's branch,
  and `gh pr checks` reads its CI from inside the lane

#### Scenario: with Codex review on, the gauntlet runs inside the lane
- **WHEN** the repository rendered `use_codex_review` on (and, for the cloud
  trigger, `use_codex_cloud_review` on with the repository connected) and
  an agent in a lane follows the Dev Loop
- **THEN** `task challenge` and `task review` run to completion inside the
  lane on the copied Codex login, and the shepherd's `@codex review`
  trigger posts from inside the lane and is answered on the PR head
  exactly as from the local bot container

#### Scenario: a workflow-touching change is handed off, never pushed from the lane
- **WHEN** an agent in a lane commits a change that adds or edits a file
  under `.github/workflows/**`
- **THEN** a plain `git push` inside the lane is refused by the
  `guard:lane-workflow-push` pre-push hook before contacting GitHub (the
  guard is inert outside a lane, where the marker is unset), the refusal
  names the operator handoff, `task sprite:lane:harvest -- <lane> --bundle`
  produces a git bundle of the branch on the orchestrator, and the
  operator's own push from a local checkout is what creates the remote
  branch — the bot PAT is never used for it; the offline test runs the
  hook itself against a stubbed remote

#### Scenario: Docker-gated checks are not attempted in the lane
- **WHEN** `task ci` is invoked inside a lane
- **THEN** the checks the repository documents as CI-only are skipped or
  refused with the same message they give in the local bot container, and
  `task verify` and `task security` still pass

### Requirement: A lane is created, attached, steered, harvested, and retired from Herdr
The lane tasks SHALL fit the Herdr pane-worker loop without changing it. The
orchestrator's Herdr session (on the laptop or in a Coder devcontainer) SHALL
host **one pane per lane whose foreground process is the lane's sprite
session** — a detachable TTY exec into the inner container that launches the
worker's harness — so that Herdr's terminal-based state detection
(`working`, `blocked`, `idle`, `done`, `unknown`) applies to the remote agent
through that pane, `herdr pane run` delivers the brief, and
`herdr pane wait-output` waits on the per-attempt sentinel. The brief SHALL
end with a file-based report at a path inside the lane and a sentinel line
unique per attempt; `task sprite:lane:harvest` SHALL copy that report out of
the lane. Where Herdr classifies the remote agent as `unknown`, the report
and sentinel are the success signal, as the Herdr guide already states for
weak detection.

Every entry into a lane (`lane:exec`, `lane:attach`, `lane:harvest`) SHALL
first **reconcile** the lane: if the sprite woke cold and the inner container
is not running, the helper brings it back with `devcontainer up` (which
reuses the existing container and reruns `post-start.sh`, so
`bot-autonomy.sh verify` gates the restart), restarts the in-container SSH
server and the in-container Herdr server where one was running, and only
then proceeds; a `verify` failure on that restart fails the entry non-zero
as it fails creation. Reconciliation SHALL be idempotent across container
identity: when `devcontainer up` yields a new container (rebuilt or
recreated rather than restarted), the helper reinstalls and configures the
SSH server, regenerates `authorized_keys` from the per-lane public key,
re-pins the container's host key through the same authenticated channel
used at creation — read out of the container over `sprite exec`, never
trusted on first use over SSH — and refreshes the alias, so the takeover
path after a recreation is the one that existed at creation. What "proceeds" means per entry: `lane:exec` runs the
requested command; `lane:harvest` copies the report; `lane:attach`
reattaches the lane's session when it still exists and otherwise — the
platform drops sessions on a cold pause — opens a new detachable shell
session in the inner container and says so, naming the lost session, so
the operator resumes the agent from inside (Herdr's snapshot restore or
the harness's own resume) rather than being told the lane is gone. The sprite session SHALL be detachable: if the orchestrator's pane
dies, the worker keeps running and the operator reattaches with
`task sprite:lane:attach -- <lane>` (the platform's session attach) or, for
a full Herdr UI inside the lane, with `herdr --remote` over an SSH server
that runs **inside the inner container**, reached through the platform's
port proxy to the container's address (`sprite proxy -s <pool-sprite> -W
<inner-address>:22`, where `<pool-sprite>` is the platform name of the
leased pool sprite recorded in the lease; the lane name is only the
helper-facing key and never appears in a platform-facing call) — the helper
installs that server into the container
after `devcontainer up`, configures it for public-key authentication only
(no passwords, bound to the container's address, host key generated in
the container), generates a per-lane keypair on the orchestrator whose
public half it installs into the container user's `authorized_keys`,
records the container's host key in the operator's SSH alias so the
connection is pinned rather than trusted on first use, refreshes the
address on every reconcile, and removes the keypair and alias at
retirement; the outer sprite runs no SSH server and the private key never
enters the sprite. Two invariants bound the takeover path. First, **every
agent process in a lane runs under the lane supervisor**, whatever
launched it: inside the lane, every registered harness executable
resolves on `PATH` to the supervisor wrapper (the image already puts
`~/.local/bin` first for exactly this kind of precedence), so an
`agent start` issued through remote Herdr — which the in-container Herdr
server executes by launching the harness in a pane shell — or a harness
name typed in a remote pane runs with `lane:exec` semantics: the duration
bound, the TTL and grace, and registration with the platform (a session
or a hold the supervisor owns), so it is visible to the activity authority;
takeover gives the operator Herdr's UI, never a way to start an
unsupervised process. Second, **the SSH alias reconciles before it
connects**: its `ProxyCommand` is a helper subcommand
(`task sprite:lane:ssh-proxy -- <lane>`) that runs the same reconcile as
every other entry — wake the sprite, bring the inner container back if it
is stopped, refresh the address, re-pin the host key if the container's
identity changed — under the same lane-lock refusals (retiring, pending
restore), and only then execs `sprite proxy -s <pool-sprite> -W
<inner-address>:22`; a cold lane is therefore taken over without a prior
lane command. Lanes run with related-repository bootstrap disabled
through the lane marker (see the nested-devcontainer requirement), so the
primary checkout is the only repository a lane clones. Retirement
(`task sprite:lane:rm -- <lane>`) SHALL hold the lane lock of the lane-lock
requirement above from its first check until the golden restore has
reported complete and the lease is released: under the lock it evaluates
activity — refusing only while the **platform** reports a live session or
command for the lane; the helper's cached session records are not an
authority and a stale one is discarded — and the cleanliness gate — enumerating **every** git checkout under
`/workspaces` before any restore and refusing while any of them is not
clean, where clean means all three of: `git status --porcelain
--untracked-files=all` is empty (no modified, staged, or untracked
files); `git ls-files --others --ignored --exclude-standard` is empty (no
ignored files such as a `.env`, the same guard `scripts/worktree-rm.sh`
applies, because a restore deletes them without a trace); and the branch
is fully on its remote — it has an upstream, that upstream exists on the
remote, and `git rev-list --count @{upstream}..HEAD` is zero, porcelain
alone cannot see an ahead-but-clean branch — unless `--force` is given; it then stops the inner container, removes injected
credentials, restores the golden checkpoint and waits for it, releases the
lease, and only then releases the lock and returns the sprite to the pool
(or destroys it with `--destroy`). `task sprite:audit --reclaim` is this
same operation invoked by the audit owner on an expired lease, after
confirmation.

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

#### Scenario: a cold-woken lane is reconciled before the command runs
- **WHEN** a sprite has gone cold (inner container stopped, sessions gone)
  and the orchestrator runs `task sprite:lane:exec` or `lane:harvest`
- **THEN** the helper brings the inner container back with `devcontainer
  up`, `post-start.sh` runs `bot-autonomy.sh verify` and passes, the
  in-container SSH server is running again and the SSH alias's address is
  refreshed, and the requested command (or the report copy) then runs
  inside the container — or, if `verify` fails, the entry exits non-zero
  naming the harness and runs nothing

#### Scenario: a recreated container is re-provisioned for SSH on reconcile
- **WHEN** reconciliation's `devcontainer up` yields a new container
  identity (a different container ID than the lane recorded)
- **THEN** the helper reinstalls the SSH server, regenerates
  `authorized_keys` from the lane's public key, re-pins the new host key
  read over `sprite exec`, refreshes the alias, and `herdr --remote` through
  the alias succeeds without any trust-on-first-use prompt; the offline test
  drives the identity change with the stubbed CLI and records the
  re-provisioning calls in that order

#### Scenario: attaching to a cold-woken lane opens a fresh session and says so
- **WHEN** a sprite has gone cold and the orchestrator runs
  `task sprite:lane:attach`
- **THEN** the helper reconciles as above, finds the lane's previous
  session gone, opens a new detachable shell session inside the inner
  container, and prints that the previous session was lost to a cold
  pause with the resume options — it neither fails silently nor reports
  the lane as gone

#### Scenario: harvest copies the report out and verifies nothing
- **WHEN** `task sprite:lane:harvest -- <lane> --report <path>` runs after
  the sentinel appears
- **THEN** the report file is copied to the orchestrator's scratch directory
  and the task prints where; verifying the lane's claims (the diff, the PR,
  the labels) remains the orchestrator's step, as the Herdr guide requires

#### Scenario: the operator takes a lane over with a full Herdr UI
- **WHEN** the operator runs `herdr --remote <lane-ssh-alias>` where the
  alias's `ProxyCommand` is `sprite proxy -s <pool-sprite> -W
  <inner-address>:22`, generated from the leased pool sprite's platform
  name, to the SSH server inside the inner container
- **THEN** a Herdr thin client attaches to a Herdr server running inside the
  inner container, and detaching leaves the agents running

#### Scenario: an agent started through remote Herdr runs under the supervisor
- **WHEN** the operator, attached with `herdr --remote`, runs
  `herdr agent start … --kind claude` in a lane pane (or types `claude` in
  a remote pane)
- **THEN** the harness resolves to the supervisor wrapper, the platform
  lists the resulting activity (the activity authority sees it exactly as
  a `lane:exec`-launched agent), `lane:rm` refuses while it runs, and it is
  stopped with its process group at the per-command bound and at TTL
  plus grace; the offline test asserts that the lane's `PATH` resolves
  every registered harness to the wrapper and that no launch path in the
  container reaches an unwrapped harness binary

#### Scenario: taking over a cold lane reconciles before connecting
- **WHEN** a lane has gone cold (sprite paused, inner container stopped, no
  lane command issued since) and the operator runs `herdr --remote
  <lane-ssh-alias>`
- **THEN** the alias's `ProxyCommand` reconciles first — the sprite wakes,
  `devcontainer up` brings the container back with `post-start.sh` and
  its `verify`, the address is refreshed and the host key re-pinned if
  the identity changed — and only then proxies to the container's SSH
  server, so the attach succeeds with no prior `lane:exec`; the offline
  test records the reconcile calls before the `sprite proxy` call and a
  refusal (no proxy call) while retiring or during a pending restore

#### Scenario: SSH into the lane is key-authenticated and pinned
- **WHEN** the lane's SSH alias is used
- **THEN** authentication succeeds only with the per-lane private key held
  on the orchestrator, password authentication is refused by the
  container's sshd, the host key matches the one recorded at lane
  creation (a mismatch fails the connection), and after `lane rm` the
  keypair and alias are gone from the orchestrator and the public key from
  the container

#### Scenario: retirement refuses to drop uncommitted or unpushed work
- **WHEN** `task sprite:lane:rm -- <lane>` runs while the lane's checkout has
  unpushed commits, or modified, staged, or untracked files
- **THEN** it refuses, names what is unpushed or uncommitted, and does
  nothing unless `--force` is given

#### Scenario: a gitignored file in the checkout refuses retirement and reclaim
- **WHEN** `task sprite:lane:rm -- <lane>` or `task sprite:audit --reclaim`
  runs while a lane checkout has an empty porcelain status but
  `git ls-files --others --ignored --exclude-standard` lists a file (a
  `.env` an agent wrote, say)
- **THEN** it refuses naming the ignored file, restores nothing, and
  proceeds only with `--force`; the offline test drives it with a stubbed
  checkout whose only dirt is an ignored file

#### Scenario: retirement refuses a clean tree that is ahead of its upstream
- **WHEN** `task sprite:lane:rm -- <lane>` runs while the lane's checkout has
  an empty porcelain status but its branch has commits not on its upstream
  (`git rev-list --count @{upstream}..HEAD` non-zero), has no upstream
  configured, or its upstream no longer exists on the remote
- **THEN** it refuses, names the commits or the missing upstream, and does
  nothing unless `--force` is given — an empty porcelain status alone is
  never taken as clean

#### Scenario: retirement refuses while a lane command is active
- **WHEN** `task sprite:lane:rm -- <lane>` runs while the platform lists a
  live session for the lane
- **THEN** it takes the lock, sees the live session on the platform,
  refuses the retirement naming it, releases the lock with nothing
  changed, and the offline test records the lock acquisition and the
  platform session query before any cleanliness check, stop, or restore
  call

#### Scenario: a dirty sibling checkout blocks retirement
- **WHEN** `task sprite:lane:rm -- <lane>` runs while the primary checkout
  is clean but a second git checkout under `/workspaces` (one a previous
  step or an agent created) has uncommitted, untracked, or unpushed work
- **THEN** the gate's enumeration finds it, the retirement refuses naming
  that checkout and what is dirty in it, restores nothing, and proceeds
  only with `--force`; the offline test drives it with a stubbed second
  checkout

### Requirement: The sprite stays active exactly while lane work runs, and a lane cannot bill unnoticed
For every lane, the following SHALL hold regardless of whether the
orchestrator's pane or any laptop-side process is alive: while any lane
command — a gate, an agent turn, a harvest — is running inside the sprite,
the sprite stays active and is never paused mid-run; once no lane command is
running, nothing keeps it awake and it sleeps on the platform's idle rule.
The mechanism SHALL live inside the sprite with the running command's own
lifetime (the platform counts a running exec session as activity, and any
Tasks-API hold the helper registers is owned by an in-sprite supervisor that
exits with the command), never a heartbeat on the orchestrator's machine.
No lane command SHALL run unbounded: every command launched through the
lane runs in its own process group (or cgroup) owned by the in-sprite
supervisor, under a per-command duration bound enforced inside the sprite
(default 2 hours, settable per command), after which the command and
every process it spawned — a backgrounded reviewer run included — are
stopped with the output file intact, and any hold is released only once
no descendant remains. A lane SHALL carry a TTL (default 12 hours, set
per lane) whose authoritative copy for enforcement is **lane-local state
inside the sprite** — a file the helper writes over `sprite exec` under the
lane lock — which the in-sprite supervisor reads to decide expiry and
grace; the lease's TTL is a mirror. At expiry the helper SHALL stop
registering holds and SHALL refuse to start new lane commands until the
operator extends the TTL (`task sprite:lane:extend`); a command already
running at expiry gets a grace period (default 30 minutes) and is then
stopped the same way. Because `lane:extend` writes the in-sprite state
before the lease, a command already running observes the extended TTL. The
lane's active compute is therefore bounded by its TTL plus one grace
period, and the helper never destroys a lane or discards stored work on
its own — stopping a command preserves the checkout, the container, and
the volumes. `task sprite:audit` SHALL list every
pool sprite and lane with its state, age, TTL, lease owner, and the issue it
was created for, using the platform's labels, so a forgotten lane is visible
in one command, and SHALL exit non-zero when any lane is past its TTL. The
pool size SHALL be capped by a configured ceiling no higher than the
operator's Fly plan concurrency limit, and `task sprite:pool:init` SHALL
refuse to exceed it.

#### Scenario: an idle lane sleeps
- **WHEN** every agent in a lane has been idle for longer than the platform's
  idle window and no lane command is running
- **THEN** no hold is live, the sprite reports `warm` or `cold`, and the next
  `sprite:lane:attach` or `sprite:lane:exec` wakes it with the checkout and
  container state intact

#### Scenario: a running gate is not paused when the orchestrator disconnects
- **WHEN** `task verify` is running inside a lane through `lane:exec` and the
  orchestrator's pane — and every process on the orchestrator's machine
  belonging to that lane — is killed
- **THEN** the sprite stays active until the gate exits, the gate's output
  file is complete when the orchestrator reattaches, and the offline test
  confirms no hold or heartbeat was owned by an orchestrator-side process

#### Scenario: an expired lane stops taking new work but keeps its data
- **WHEN** a lane passes its TTL while an agent is mid-command
- **THEN** the running command completes within the grace period or is
  stopped at its end, the helper registers no further hold,
  `task sprite:lane:exec` refuses new commands naming
  `task sprite:lane:extend`, the checkout and container state are intact,
  and nothing has been destroyed

#### Scenario: extend during an active command moves its deadline
- **WHEN** an agent command is running inside a lane a few minutes before
  the lane's TTL and the operator runs `task sprite:lane:extend`
- **THEN** the helper writes the new TTL into the sprite's lane-local
  state under the lane lock before updating the lease, the in-sprite
  supervisor of the running command reads it and neither stops the
  command at the old TTL nor starts the old grace period, and the offline
  test records the in-sprite write preceding the lease write

#### Scenario: a hung command cannot bill past its bound
- **WHEN** a lane command hangs (a stalled network operation, an agent that
  never returns)
- **THEN** the in-sprite bound stops it and every descendant it spawned
  (including a backgrounded reviewer run) at the per-command limit, the
  hold is released only after no descendant remains, the sprite is free to
  sleep afterwards, the command's output file records the stop, and the
  offline test shows the bound and the process-group ownership are applied
  inside the sprite rather than by an orchestrator-side timer

#### Scenario: audit lists every lane with its age
- **WHEN** `task sprite:audit` runs
- **THEN** it prints one row per pool sprite and lane with name, state, age,
  TTL, lease owner, issue, and golden-checkpoint pin, flags expired lanes
  and expired leases, and exits non-zero when any lane is past its TTL

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

### Requirement: The lane helper is unit-tested offline against a stubbed CLI, and the platform-dependent scenarios are exercised on the real platform
`scripts/sprite-lane.sh` SHALL be covered by an offline unit test
(`task test:sprite-lane`, part of `task verify` in the root) that runs it
against a stubbed `sprite` binary and a stubbed devcontainers CLI and
asserts the ordering and refusal rules above: claim before restore, restore
reported complete before policy, policy before credentials, the clone
before `devcontainer up`, credentials in the `devcontainer up` environment
before agents; refusal of absent or ahead branches, stale golden
checkpoints (including a helper-only change to the stamp), pool overflow,
contended or expired leases, entry during a pending restore, a missing
`flock` or `sprite` prerequisite (no platform call at all), and retirement
or reclaim over a live platform session or a non-clean checkout (including
a clean tree ahead of its upstream, a checkout whose only dirt is an
ignored file, a dirty sibling checkout under `/workspaces`, and an
idle-but-unclean reclaim without `--force`) — each recording no restore
call; that every registered harness resolves to the supervisor wrapper on
the lane's `PATH`; that the SSH alias's `ProxyCommand` reconciles before
proxying and refuses while retiring or during a pending restore; that a stale cached session record never blocks
retirement; the lane-lock interleavings (exec and retirement contending,
with exactly one holder; a refused retirement leaving the lane usable at
once; extend during reclaim refusing; a crash at each mid-startup point
leaving no phantom session record), each driven deterministically with one
side holding the stubbed `flock` and the other refused; lease renewal on
every authenticated activity and `lane:extend`, with expiry never earlier
than the TTL, and `lane:extend` writing the in-sprite TTL state before the
lease; the two policy writes bracketing SSH provisioning and the restoring
write on its failure and interruption paths; the `guard:lane-workflow-push`
hook refusing a real `git push` inside a lane and staying inert outside
one; the bundle handoff; the lane marker present in every
`devcontainer up` environment and forwarded by the rendered
`devcontainer.json` twins; SSH re-provisioning on a container identity
change; the incomplete-restore
case recording exactly one restore call and nothing after it; that no
hold, heartbeat, or command bound is owned by an orchestrator-side
process; that the environment handed to `sprite exec` and
`devcontainer up` is exactly the lane allow-list and never carries
`FOREMAN_AGENT_GH_TOKEN` or `AGENT_DECK_TELEGRAM_KEY`; that the Sprites
token appears in no file the helper writes; and that the bot PAT appears
in no file other than the checkout's `.devcontainer/devcontainer.env`
(mode `0600`, removed at retirement, never in a checkpoint — the PAT
reaches git only through the credential helper's environment). The
scenarios only the platform can settle — credentials absent from the
sprite's filesystem after retirement, the golden checkpoint holding none,
the restore actually removing a previous lane's state, the policy being
read-only inside and an outside host failing to resolve, cold-wake
reconciliation, and the detached session surviving the pane — SHALL be
executed and recorded in the first real lane run, not inferred from the
stubs.

#### Scenario: the offline test enforces the lane ordering
- **WHEN** `task test:sprite-lane` runs with the stubbed CLIs recording every
  invocation
- **THEN** it fails if the recorded order ever places a restore before the
  claim, any later step before the restore reports complete, credential
  injection before the network-policy call, or an agent start before
  `devcontainer up` — and passes on the shipped helper

#### Scenario: the offline test enforces every pre-restore refusal
- **WHEN** `task test:sprite-lane` drives the helper through an absent
  branch, a local branch ahead of the remote, a stale golden checkpoint
  (image pin, helper hash, and CLI pin each changed alone), a full pool, a
  contended lease, an expired lease, an entry during a pending restore, a
  missing `flock`, a retirement or reclaim over a live platform session, a
  reclaim over an idle-but-unclean checkout without `--force`, a retirement
  over a non-clean checkout, a retirement or reclaim over a checkout whose
  only dirt is an ignored file, a retirement over a dirty sibling checkout,
  a retirement over a clean tree ahead of its upstream, and an SSH proxy
  attempt while retiring or during a pending restore
- **THEN** each case exits non-zero with the documented message and the
  stubs record no create, restore, or destroy call for it

#### Scenario: the offline test enforces the incomplete-restore stop
- **WHEN** `task test:sprite-lane` drives the helper through a restore the
  stubbed platform never reports complete
- **THEN** the helper exits non-zero naming the restore state, and the
  stubs record exactly one restore call and no policy, clone, credential,
  `devcontainer up`, or agent call after it

#### Scenario: the real lane run records the platform-dependent scenarios
- **WHEN** the first real lane is run on the maintainer's Fly account
- **THEN** the run records, in the research note's verification section,
  the outcome of each platform-dependent scenario named above — pass, fail,
  or not exercised with the reason — and a failed one blocks marking the
  implementation change complete
