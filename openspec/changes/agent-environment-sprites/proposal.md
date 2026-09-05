## Why

Implementer lanes run on the operator's laptop or on one shared Coder
devcontainer today, so the number of lanes an operator can run in parallel is
bounded by that machine's RAM rather than by budget and review bandwidth
(harmon-init#1120: four lanes exhausted a 32 GB laptop's swap; three lanes on a
32 GB Coder devcontainer had to be serialized behind a `flock` and still
OOM-killed gate runs). The research note
[docs/research/remote-implementer-environments.md](../../../docs/research/remote-implementer-environments.md)
evaluates the field against one rubric and recommends Fly.io Sprites — one
Firecracker microVM per lane, persistent disk, scale-to-zero billing,
checkpoint/restore — as the primary environment for interactive dispatch from
Herdr. This change specs that option as an **opt-in, default-off** Copier
answer, shaped so the lane is as close to the bot devcontainer as the platform
allows and drives from Herdr the same way a local pane worker does.

## What Changes

- Add a default-off Copier answer, `use_fly_sprites`, asked only when
  `devcontainer` is on, whose help text states the Fly.io account requirement
  and the usage-based pricing next to the question (AGENTS.md hard rule on
  paid SaaS), and that this version supports only a publicly pullable
  devcontainer base image (the shared image is public; a private base
  registry is a named follow-up). Turning it on renders the sprite lane
  tooling below; leaving it off renders nothing and changes nothing. The
  Codex stages inside a lane (`task challenge`/`task review`, the
  `@codex review` trigger) follow the repository's own `use_codex_review`
  and `use_codex_cloud_review` answers; the unconditional promise is
  verify → security → draft PR → shepherd CI, for changes outside
  `.github/workflows/**` (the bot PAT is denied the Workflows permission;
  a workflow-touching change is bundled out of the lane and pushed by the
  operator).
- Ship a **sprite lane** recipe, `scripts/sprite-lane.sh` behind a
  `taskfiles/sprites.yml` include (`task sprite:*`), that creates, attaches,
  steers, harvests, and retires one lane per sprite **from inside Herdr**,
  using the Herdr pane-worker contract already documented in
  `docs/guides/herdr.md` (one pane per unit, a self-contained brief, a
  file-based report, and a per-attempt sentinel line), reconciling a
  cold-woken lane on every entry and offering `herdr --remote` takeover
  through an SSH server inside the inner container.
- Define what a lane runs: **the bot devcontainer itself, nested inside the
  sprite**. Sprites cannot boot a custom OCI image (Fly.io staff,
  community.fly.io, 2026 — see design.md), so the sprite acts as the outer
  host the way a Coder workspace does: it runs `dockerd` as a sprite Service
  and brings the repository's own `.devcontainer/devcontainer.json` (bot
  profile) up with the devcontainers CLI from the pinned shared image. The
  bot profile's `post-create.sh` and `post-start.sh` — including the
  fail-closed `bot-autonomy.sh apply|verify` bootstrap from
  `bot-autonomy-bootstrap` — run unchanged inside that container; a `verify`
  failure fails lane creation.
- Define the **pool + golden checkpoint** model that makes lane creation
  fast: a small operator-owned pool of pre-bootstrapped sprites, each with a
  golden checkpoint taken after the image pull, defined by its content —
  no credential and no checkout remain in it, verified before it is taken,
  which is what lets a private repository's pool init clone with the bot
  PAT in memory; every lane claims a sprite with a lease, restores that checkpoint,
  and waits for the restore to complete before anything else, so two lanes
  never fight over one sprite and a lane never inherits a previous lane's
  files or tokens.
- Define the **credential contract**: a lane receives an explicit
  allow-list narrower than the bot profile's own (`GH_TOKEN` = the bot's scoped
  fine-grained PAT, `CLAUDE_CODE_OAUTH_TOKEN`, the Codex CLI login, optional
  provider keys), delivered the way Coder delivers them — present in the
  environment of the `devcontainer up` the lane runs, so the profile's own
  `init-env.sh` composes the env-file before the container exists; nothing from
  1Password, no operator `gh` login, no `TS_AUTHKEY`, and — new to this
  environment — **never the org-scoped Sprites API token**, which would let
  one lane exec into its siblings.
- Define the **checkout model**: one sprite is one lane is one branch, the
  remote branch head cloned from GitHub over HTTPS onto the sprite's
  workspace folder before the container comes up; the operator's working
  tree, gitignored files, and local fixtures never cross into the sprite,
  and a local branch ahead of the remote is refused.
- Define **egress**: an explicit DNS allowlist network policy (GitHub, GHCR,
  package registries, the Anthropic and OpenAI API hosts, and the Convex
  local-backend release host) set from the orchestrator side before any
  credential is injected, with the sprite unable to change it.
- Define **cost controls**: the sprite stays active exactly while a lane
  command runs (the mechanism lives inside the sprite, never on the
  orchestrator's machine) and sleeps otherwise; every command runs under an
  in-sprite duration bound; a per-lane TTL whose expiry stops new work,
  grants a grace period, and then stops running commands without
  destroying anything; a pool ceiling tied to the
  Fly plan's concurrency limit; and `task sprite:audit` listing every lane
  with its age and lease so nothing bills unnoticed.
- Define how the dev-loop dispatch recipe and Foreman **select** the
  environment: an explicit `--env sprite` on the lane task for interactive
  dispatch, and `.foreman.toml`'s existing `runner` key for Foreman — this
  change documents the value's meaning and does not flip it (Foreman's
  isolated runner is Foreman-side work; see design.md for why its written
  D5/D6 describe Fly Machines, which cannot boot this image either, and
  why the nested sprite lane is the recommended shared shape).
- Add an offline unit test for the lane script against a stubbed `sprite`
  CLI, and the docs: a `docs/guides/sprites.md` twin, a Herdr-guide section,
  and the `copier-options.md` row.

## Open design questions for the feasibility spike

Codex cloud review of this proposal stopped by maintainer decision on
2026-09-05; the spec goes to the maintainer's own review. Six findings from
the last review pass remain open. They are recorded here as questions for
the feasibility spike (tasks § 0) rather than folded into the requirements,
because each one is settled by observing the platform, not by more
specification text. None changes a requirement as written; a spike answer
that contradicts one is re-planned as its own change.

1. **Activity authority versus Tasks-API holds.** An agent launched through
   remote Herdr may exist on the platform only as a Tasks-API hold the
   supervisor owns, while retirement and reclaim consult the platform's
   session list only. Touches: the takeover invariant in the requirement
   "A lane is created, attached, steered, harvested, and retired from
   Herdr" (every agent process runs under the lane supervisor) and the
   activity authority in the lane-lock requirement. The spike must
   demonstrate what the platform reports for a supervisor-launched agent
   that is not an exec session — a listed session, a listed task, or
   nothing — and decide whether the activity authority is the session list
   alone or the session list plus the task list.
2. **Supervisor persistence across container recreation.** The supervisor
   wrappers under `~/.local/bin` and the lane-local TTL state live on the
   container's own filesystem, not on a named mount, while reconciliation
   after a recreated container reinstalls only the SSH server. Touches: the
   reconcile paragraph of the Herdr requirement and the TTL state in "The
   sprite stays active exactly while lane work runs". The spike must show
   what a `devcontainer up` that yields a new container identity keeps and
   drops, and decide whether reconciliation re-provisions the wrappers and
   the TTL state or whether both move onto a named volume.
3. **Cold-lane entry ordering.** The lane-lock requirement has command
   startup create the inner-container session under the lock, but on a
   cold lane the container is not running until reconciliation starts it.
   Touches: task 2.4 (lock, then reconcile, then session). The spike must
   demonstrate the cold-wake sequence end to end and decide how the lock
   spans reconcile plus session creation — one hold across both, or
   reconcile first and then the locked session step.
4. **Composing the lane supervisor with the bot-autonomy wrappers.** The
   bot-autonomy modules may occupy the same `~/.local/bin/<executable>`
   path (Antigravity's `agy` today) and `post-start.sh`'s `verify` checks
   them byte-exact. Touches: the supervisor-wrapper invariant in the Herdr
   requirement and the bot-autonomy capability's `verify`. The spike must
   show whether a supervisor wrapper can wrap a bot-autonomy wrapper (or
   sit ahead of it) without failing `verify`, and decide the layering — a
   supervisor that execs the bot-autonomy wrapper, or a bot-autonomy module
   that knows about the supervisor.
5. **Pool-init credential ordering.** During `pool init` the bot PAT
   reaches the sprite (in memory, for the clone) before any egress policy
   is applied, whereas `lane:new` applies the policy before credentials.
   Touches: the pool-init paragraph of "Lanes start from a pool sprite's
   golden checkpoint". The spike must decide whether pool init applies the
   allowlist before its clone (the same order as a lane) and demonstrate
   the clone succeeding under it.
6. **Provisioning-ready state.** A lease becomes `complete` when the
   restore completes, before `devcontainer up`, `bot-autonomy.sh verify`,
   the SSH server, and the supervisor wrappers have succeeded, so an entry
   command can find a half-provisioned lane. Touches: the restore state in
   "Lanes start from a pool sprite's golden checkpoint" and task 2.3. The
   spike must decide whether the lease gains a `ready` state set only after
   every provisioning step succeeds, and the same-owner retry or rollback
   rule for a lane that fails between `complete` and `ready`.

## Non-goals

- Does not implement anything: this change is planning artifacts only. The
  implementation PR that follows edits the root and `template/` layers in
  lockstep per AGENTS.md's dogfood-parity rule and carries a `feat:` title.
- Does not turn the option on for generated repos, and does not add a Fly.io
  account, token, or billing dependency to any default render.
- Does not build a native (non-nested) sprite image, a slimmed variant of the
  shared image, or a second maintained toolchain — the nested devcontainer is
  the one agent image, per ponderousdev/foreman's D6.
- Does not implement Foreman's `runner = "sprite"` or any other Foreman
  runner; it records the interface a runner would consume and files the
  Foreman-side work as follow-ups.
- Does not change the gauntlet, shepherd, readiness-gate, or Codex cloud
  review contracts, and does not move the Codex reviewer to a different
  account.
- Does not support the human `dev/` devcontainer profile in a sprite: lanes
  are bot-profile only, because the sprite is the bot's isolation boundary
  and a human-authenticated container inside it would put an operator
  credential beside a `bypassPermissions` agent.
- Does not cover Fly Machines, Claude Code cloud sessions, Codex cloud tasks,
  or GitHub Codespaces as lane environments; the research note scores them,
  and Fly Machines (after slimming the image under its 8 GB rootfs limit),
  Northflank, and Ona are named as the alternatives where Sprites cannot
  satisfy a requirement.
- Does not add GPU, multi-region placement, or a self-hosted sprite runtime.

## Capabilities

### New Capabilities

- `agent-environment/sprites`: the opt-in Fly.io Sprites lane environment —
  what a lane runs, how it is created, attached, steered, harvested, and
  retired from Herdr, how credentials and the checkout reach it, its egress
  and cost controls, and how dispatch selects it.

### Modified Capabilities

(none — the bot-autonomy and harness-image capabilities are consumed as
they are: this change runs the bot devcontainer unchanged inside the sprite
and adds no requirement to either spec.)

## Impact

- New (both layers, gated on `use_fly_sprites`): `taskfiles/sprites.yml`,
  `scripts/sprite-lane.sh`, `scripts/test-sprite-lane.sh` (offline, stubbed
  `sprite` binary; part of `task verify` in the root), `docs/guides/sprites.md`.
- Changed (both layers): `Taskfile.yml` (conditional include), `copier.yml`
  (the question), `docs/copier-options.md`, `docs/guides/herdr.md` (a
  "remote lanes" section), `docs/guides/devcontainers.md` (a pointer),
  `docs/architecture/security.md` (the sprite credential boundary),
  `.foreman.toml` (comment on `runner` values only), `.dogfood-answers.yml`
  (the root adopts the option so the parity gates cover the twins),
  `scripts/audit-dogfood.sh` (any intentional divergence, with reasons),
  `.devcontainer/devcontainer.json` and its jinja twin (one `containerEnv`
  line forwarding the lane marker `HARMON_LANE` from `localEnv`, task 3.3),
  and the lifecycle scripts that gain a skip-when-set guard on that marker
  (`bootstrap-related-repos.sh`, `fetch-related-repos.sh`,
  `post-create-conductor.sh`, `post-start-common.sh`, task 3.3) plus the
  lefthook `pre-push` hook and `Taskfile.yml` (`guard:lane-workflow-push`,
  task 3.5).
- Read-only: `post-create.sh`, `post-start.sh`, `init-env.sh`,
  `bot-autonomy.sh` — consumed unchanged inside the nested container. If
  the lane needs anything from them beyond the marker guards above it is a
  defect in this change's scripts, not a reason to edit the bootstrap.
- External: a Fly.io account with Sprites enabled (usage-based; one $30
  trial credit per user), the `sprite` CLI on the orchestrator's machine,
  and the devcontainers CLI + Docker inside each pool sprite.
- Cross-repo follow-ups (to be filed by task 5.1 of the implementation,
  not filed by this proposal): harmon-devkit (herdr skill and
  dispatch-recipe text for remote lanes), ponderousdev/foreman (the
  Sprites-vs-Fly-Machines naming of its isolated runner; D5/D6),
  harmon-infra (nothing to build; record that Coder stays the fallback),
  and a Fly.io feature request (sprite-scoped tokens, fork-from-sprite).
