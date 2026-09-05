# devcontainer/bot-autonomy Specification

## Purpose
Defines the bot-only, fail-closed contract that keeps every supported,
enabled agent harness installed in the bot devcontainer image running
non-interactively, keyed by the agent registry, so a declared no-prompt
policy can never silently diverge from the effective runtime policy the way
Codex's did in issue #1137.

## Requirements

### Requirement: Bootstrap entrypoint and module dispatch
The bot devcontainer SHALL provide a single entrypoint,
`.devcontainer/scripts/bot-autonomy.sh apply|verify`, that dispatches to
per-harness policy modules under `.devcontainer/config/bot-autonomy/<slug>.sh`
keyed by `agent-registry.json` harness slugs. Each module SHALL declare the
executable it governs, an idempotent `apply`, and a `verify` that reads the
harness's effective runtime configuration. A slug aliased to another slug's
module (see the registry-coverage requirement below) is governed by that
module and dispatches no separate one. A module MAY additionally declare
itself `always_dispatch`, in which case dispatch SHALL NOT skip it merely
because its declared executable is absent from the image — reserved for a
module whose own executable's presence is itself something apply/verify
manage (Antigravity's `agy`, removed by `ensure-antigravity-cli.sh` when
its option is disabled), where gating dispatch on that presence would skip
the module precisely when its cleanup path needs to run.

#### Scenario: apply dispatches every installed harness to its module
- **WHEN** `bot-autonomy.sh apply` runs in the bot devcontainer
- **THEN** it invokes the `apply` step of the module for every registry
  harness slug whose executable is present in the image, or whose module
  declares `always_dispatch` — resolving an aliased slug to its target
  module — and none other

#### Scenario: verify reads effective runtime state, not the source file
- **WHEN** `bot-autonomy.sh verify` runs after `apply`
- **THEN** each module's `verify` step re-reads the harness's live effective
  configuration (the same value a running instance of that harness would
  honor) rather than re-checking the file `apply` wrote for existence alone

#### Scenario: a registry harness without an installed executable is skipped
- **WHEN** `bot-autonomy.sh apply` or `verify` runs and a registry harness
  slug's executable is not present in the image, and its module does not
  declare `always_dispatch`
- **THEN** that harness's module (or, for an aliased slug, its target
  module) is skipped without failing the run

#### Scenario: an always_dispatch module runs regardless of its executable's presence
- **WHEN** `bot-autonomy.sh apply` or `verify` runs and a registry harness
  slug's module declares `always_dispatch`
- **THEN** that module's `apply` or `verify` step runs whether or not its
  declared executable is currently present in the image

### Requirement: Every registry harness slug resolves to one of three coverage buckets
Every `agent-registry.json` harness slug SHALL be covered by exactly one of:
a bot-autonomy module; an alias naming another slug's module, used only
where both slugs launch the same underlying executable under a different
provider configuration; or an entry in an explicit `unsupported` set
carrying a reason. A unit test SHALL enumerate the full registry and fail if
any slug falls into none of the three buckets, or into more than one.

An `unsupported` entry carries two fields: a `reason` (documentation only —
explains WHY a slug has no module today; never changes what `verify` does)
and an `executable`, either a binary name or the literal `null`. `verify`
checks a named `executable` for presence on `PATH` (via `command -v`) to
decide whether the slug's absent-only exemption still applies; an
`executable: null` entry has no standalone binary this image could ever
install, so its exemption cannot be defeated by installation and is not
re-checked. The instant a **named** `unsupported` executable is found
installed, that slug is treated exactly like an uncovered slug — `verify`
fails naming it — unless a real module (or an alias to one) now covers it.
There is deliberately no *reason*-based category whose exemption survives
installation: an entry that seems permanently out-of-scope today
(`qwen-code`, `goose`, `cline`) is just as capable of silently drifting
into scope tomorrow — a future image build installing one without anyone
updating this table — as `copilot-cli` and `pi` are today, and the
fail-closed guarantee this change exists to add must not depend on someone
remembering to update a table; that is the same failure mode issue #1137
itself was. `executable: null` is not a reason-based exception to that
rule — it is a structural one: `claude-code-action` runs as a GitHub
Actions workflow and has no CLI binary of its own to ever detect, so there
is nothing an installation check could observe in a devcontainer image in
the first place.

#### Scenario: registry completeness is unit-tested across all three buckets
- **WHEN** the bot-autonomy unit test runs
- **THEN** it fails if any `agent-registry.json` harness slug has no
  module, no alias to a moduled slug, and no `unsupported` entry; fails if
  any slug is covered by more than one bucket; and fails if an
  `unsupported` entry omits its `executable` field or sets it to something
  other than a binary name or `null`

#### Scenario: provider-rewired Claude Code variants alias to the claude-code module
- **WHEN** the bot-autonomy module directory and its alias table are
  inspected
- **THEN** `claude-code-deepseek`, `claude-code-glm`, `claude-code-kimi`,
  `claude-code-minimax`, `claude-code-qwen`, and `claude-code-qwen-local`
  each alias to the `claude-code` module rather than carrying their own —
  all six launch the same `claude` executable, provider-rewired by wrapper
  functions and environment variables (`claude-providers.sh`), and so share
  its `/etc/claude-code/managed-settings.json` boundary

#### Scenario: the unsupported set documents why and what to detect, for every remaining slug
- **WHEN** the bot-autonomy unsupported set is inspected
- **THEN** it contains exactly four entries: `qwen-code` carries
  `executable: "qwen"`, `goose` carries `executable: "goose"`, and `cline`
  carries `executable: "clite"` (its published `@cline/cli` package's
  binary name), each with a reason stating it is not installed in the
  shared devcontainer image; and `claude-code-action` carries
  `executable: null` with a reason stating it runs as a GitHub Actions
  workflow and has no devcontainer-installable binary. Every other
  registry slug — including `copilot-cli`, `pi`, and `oh-my-pi` — resolves
  to its own module, never to this set (the archived `bot-autonomy-bootstrap`
  change shipped `copilot-cli` and `pi` here as placeholders reasoned
  "registered but not yet installed" until the archived
  `bot-autonomy-new-harnesses` change replaced both with real modules; see
  the registry-coverage requirement below)

#### Scenario: an installed unsupported harness fails verify until it gets real coverage
- **WHEN** `bot-autonomy.sh verify` runs and finds a named `unsupported`
  executable installed — `qwen`, `goose`, or `clite`, hypothetically, if a
  future image ever installed one — while its slug still has no module and
  no alias
- **THEN** `verify` exits non-zero naming the harness — no `unsupported`
  reason grants a named executable's exemption that survives installation,
  so any rollout that lands an image with a newly-installed, still-uncovered
  harness fails CI loudly instead of silently reporting success

#### Scenario: a null-executable entry is never re-checked for installation
- **WHEN** `bot-autonomy.sh verify` runs and `claude-code-action` (the
  only `executable: null` entry) is inspected
- **THEN** `verify` performs no `command -v` check for it and does not
  fail on its account — there is no binary a devcontainer image could
  install for a GitHub Actions workflow to begin with

#### Scenario: an installed executable with no covering entry fails verify
- **WHEN** `bot-autonomy.sh verify` runs and finds an executable on `PATH`
  that corresponds to a registry harness slug with no module, no alias, and
  no `unsupported` entry at all
- **THEN** `verify` exits non-zero and names the uncovered harness

### Requirement: A Copier-gated harness's module always exists; only its effective policy is conditional
When a harness's autonomy policy is gated behind a Copier option (per
AGENTS.md's Hard Rule on paid or trial-only SaaS dependencies — the
Antigravity and GitHub Copilot CLI requirements below are both concrete
examples, keyed respectively to the `use_antigravity_cli` and
`use_copilot_cli` answers), the harness SHALL still resolve to a real module — never to the `unsupported`
bucket and never to no module at all — because the harness IS installed in
the image regardless of the Copier answer, and an installed, registered
harness with no module fails `verify` by the coverage requirement above.
What the Copier option gates is the module's **effective policy**, not its
existence: the module SHALL support exactly two policy states —
`autonomous` (the option is on: `apply` writes the harness's non-interactive
configuration, e.g. an allow-all environment variable and, if the harness
needs one for headless launches, a wrapper) and `disabled-by-option` (the
option is off, the default: `apply` ensures the harness is granted no
autonomous permission — normally by leaving its allow-all variable
**absent** and installing no wrapper, leaving the harness in its own
out-of-the-box, prompt-enabled posture rather than forcing any policy on
it. A module MAY instead render its allow-all variable to an explicit,
always-present disabled-state literal rather than omitting it, when that
module's own requirement documents a specific reason omission is unsafe
for that variable — GitHub Copilot CLI's `COPILOT_ALLOW_ALL` is the one
instance this repository currently ships, because the bot profile's
`--env-file` layer does not manage or evict that variable, so an absent
`containerEnv` key would let a stale, out-of-band `true` value already
present in that file survive a disabled render undisturbed (see the
Copilot CLI requirement above for the full mechanism). Either shape SHALL
leave the harness with zero autonomous permission in this state; only the
mechanism differs, and a module choosing the literal-value variant SHALL
state its own reason inline in its own requirement rather than deviating
silently). `verify` SHALL assert whichever state the
Copier answer selects, not unconditionally assert `autonomous` — a
`disabled-by-option` harness that still prompts is the **correct**,
verified state, not a failure to cover up. This is what makes "every
installed executable has a module" and "no generated output depends on
paid SaaS by default" simultaneously true instead of contradictory: the
coverage requirement is satisfied by the module's existence, and the
Hard Rule is satisfied by what that module's `apply` is allowed to write
by default. Because every bot-autonomy module is a **verbatim** template
twin (identical bytes in every generated repo), it cannot read a Copier
answer directly; it SHALL read a rendered `containerEnv` marker instead —
`HARMON_BOT_AUTONOMY_<HARNESS>` set from that harness's Copier answer by
the **rendered** `devcontainer.json` twins (see the Antigravity
requirement below for the concrete `HARMON_BOT_AUTONOMY_ANTIGRAVITY`
mechanism, which every future Copier-gated harness module follows).

#### Scenario: a Copier-gated harness resolves to a module, never to unsupported
- **WHEN** the bot-autonomy module directory is inspected for a harness
  whose autonomy policy is gated behind a Copier option — Antigravity,
  keyed to `use_antigravity_cli`, and GitHub Copilot CLI, keyed to
  `use_copilot_cli`, are both concrete examples in this spec (see their own
  requirements below)
- **THEN** that harness has its own module file — it does not appear in
  the `unsupported` set, and `verify` does not skip it merely because the
  option happens to be off

#### Scenario: the disabled-by-option state is verified, not merely defaulted
- **WHEN** the Copier option is off (the default) and `bot-autonomy.sh
  apply` runs the harness's module
- **THEN** `apply` ensures the harness grants no autonomous permission in
  this configuration — normally an unset allow-all variable and no
  autonomy wrapper installed, or, for a module whose own requirement
  documents the literal-value variant, its allow-all variable rendered to
  that module's own disabled-state literal instead — and `verify` asserts
  exactly that state; a prompt-enabled harness is the verified-correct
  outcome here, not an uncovered gap

#### Scenario: a module MAY render an explicit disabled-state literal instead of omitting its variable
- **WHEN** a Copier-gated module's own requirement documents that omitting
  its allow-all variable would leave a channel for stale, out-of-band state
  to survive a disabled render — GitHub Copilot CLI's `COPILOT_ALLOW_ALL`,
  which the bot profile's `--env-file` layer does not manage and therefore
  does not evict, is the one such module in this repository
- **THEN** that module's `apply` and `verify` treat an explicit,
  always-rendered disabled-state literal as this requirement's own
  `disabled-by-option` state, rather than the variable's absence — the
  general default in this requirement remains omission, and this is a
  documented, per-module exception to it, not a second default

#### Scenario: the autonomous state is verified when the option is on
- **WHEN** the Copier option is on and `bot-autonomy.sh apply` runs the
  harness's module
- **THEN** the harness's allow-all environment variable carries its
  autonomous-state value — established by `apply` itself for a module
  that owns the variable, or, for a module whose own requirement
  documents the literal-value variant (GitHub Copilot CLI's
  `COPILOT_ALLOW_ALL`), validated instead: the rendered `containerEnv`
  fixes the value before any lifecycle script runs, not writable by
  `apply` at runtime the way a settings file is, so `apply` treats it as
  an input to check rather than a value to produce. `apply` also installs
  a wrapper if the harness needs one for headless launches, the same
  reasoning as Antigravity's. `verify` asserts the resulting state either
  way — including confirming this repository's own `.dogfood-answers.yml`
  sets the Copilot option on, so this repository's own bot container runs
  Copilot autonomously, while a freshly generated repo defaults to
  `disabled-by-option`

### Requirement: Fail-closed enforcement at apply, both verify points, and CI
`apply` SHALL exit non-zero on any module failure so `postCreateCommand`
fails visibly. In bot `post-create.sh`, the order SHALL be: **(i)** the
shared `.devcontainer/scripts/post-create-common.sh` with its Agent-Deck
conductor-setup block extracted out (its ownership-fixing and Coder
persistent-volume symlink setup — the ordering-load-bearing prefix `apply`
depends on for both correct ownership and, on Coder, the correct
persisted target path — SHALL still run first, unconditionally, exactly
as today); **(ii)** `ensure-antigravity-cli.sh`; **(iii)** `apply`;
**(iv)** the extracted conductor-setup step (which spawns a `claude`
process on first registration), invoked only after `apply` has succeeded.
A fresh bot container's very first `claude` invocation SHALL already
reflect the bot policy, not whatever was in effect before `apply` ran.
`verify` SHALL run at the end of
post-create and again in post-start, failing each lifecycle step on
divergence. Bot `post-start.sh` SHALL unset `NODE_OPTIONS` — the same
sanitization `.devcontainer/scripts/post-start-common.sh` already performs
for the same reason, duplicated here because `verify` now runs before that
shared script — before calling `verify`, so a `verify` step that shells
out to a Node-based harness CLI is not itself broken by an inherited VS
Code JS debug `NODE_OPTIONS` value. `verify` SHALL then run **before** the
call to `.devcontainer/scripts/post-start-common.sh` — not after — so
that script's Agent-Deck conductor-start block (which launches an
autonomous `agent-deck session start` unconditionally once a conductor is
registered) never runs against a drifted policy: a `verify` failure
aborts `post-start.sh` under `set -euo pipefail` before that block is
reached. `.github/workflows/devcontainer-build.yml` SHALL run
`devcontainer-assert.sh container` against the built bot image and fail the
workflow if any supported installed harness is not at its declared bot
policy.

#### Scenario: apply failure aborts postCreateCommand visibly
- **WHEN** any bot-autonomy module's `apply` step fails
- **THEN** `bot-autonomy.sh apply` exits non-zero and `postCreateCommand`
  fails, rather than continuing past the failure

#### Scenario: apply runs after ownership/persistence setup but before any harness process starts
- **WHEN** bot `post-create.sh` runs on a fresh, root-owned volume mount
- **THEN** `post-create-common.sh`'s ownership-fixing loop and Coder
  persistent-volume symlink setup have already run by the time `apply`
  starts, so `apply` succeeds writing into correctly-owned, correctly
  (on Coder) persisted-target paths rather than failing on a permission
  error or writing into a container-local directory the persistence step
  would later disregard; `bot-autonomy.sh apply` completes successfully
  before the extracted conductor-setup step runs, and no `claude` process
  is observed to start before `apply` has completed — including the
  conductor-setup's own first-registration `claude` spawn

#### Scenario: on Coder, no container-local state is copied over persisted settings
- **WHEN** `CODER=true` and `/home/vscode/.persistent` exists, and bot
  `post-create.sh` runs in this corrected order
- **THEN** `post-create-common.sh`'s Coder persistence block has already
  replaced `~/.gemini`/`~/.config/opencode`/etc. with symlinks into
  `~/.persistent/` (migrating any pre-existing container-local content
  first) before `apply` writes anything, so `apply`'s writes land directly
  in the persisted volume through those symlinks — there is no
  container-local copy of Antigravity's or OpenCode's settings left behind
  for a later step to either clobber or silently discard

#### Scenario: post-create verify gates container creation
- **WHEN** post-create finishes applying every module
- **THEN** `bot-autonomy.sh verify` runs before post-create completes, and a
  divergence fails post-create

#### Scenario: post-start verify catches drift on every start
- **WHEN** the bot container starts (including a restart of an
  already-created container)
- **THEN** `bot-autonomy.sh verify` runs again in post-start, and a
  divergence fails post-start

#### Scenario: post-start sanitizes NODE_OPTIONS before verify runs
- **WHEN** bot `post-start.sh` runs
- **THEN** it unsets `NODE_OPTIONS` before calling `bot-autonomy.sh
  verify`, so a `verify` step that shells out to a Node-based harness CLI
  (Claude Code, Codex, OpenCode) is not broken by an inherited VS Code JS
  debug `NODE_OPTIONS` value

#### Scenario: a drifted policy prevents the Agent-Deck conductor from starting
- **WHEN** the bot container starts with a drifted policy (any harness not
  at its declared bot state) and a conductor session is already registered
  for this repository
- **THEN** `bot-autonomy.sh verify` fails before
  `post-start-common.sh`'s conductor-start block runs, and no
  `agent-deck session start` process is observed for this container's
  conductor — a drifted policy blocks the conductor from starting at all,
  rather than starting it and leaving it to run for the rest of its
  lifetime against a policy no later verify point can retroactively fix

#### Scenario: CI asserts the built bot image, not just its source files
- **WHEN** `.github/workflows/devcontainer-build.yml` builds the bot profile
  image
- **THEN** it runs `devcontainer-assert.sh container` against the running
  built image and fails the workflow if any supported installed harness is
  prompt-enabled or sandboxed below its declared bot policy

#### Scenario: the CI assertion covers every module, not a fixed subset
- **WHEN** `devcontainer-assert.sh container` runs against the bot profile
- **THEN** it re-checks Codex's `sandbox_mode`/`approval_policy` directly,
  and proves every other installed harness's effective policy — Claude
  Code, Antigravity, OpenCode, Copilot CLI, pi, and oh-my-pi — by invoking
  `bot-autonomy.sh verify` inside the running container (via `docker exec`)
  rather than by duplicating each boundary's check a second time in the
  assertion script

#### Scenario: the CI assertion runs from a clean, isolated volume state every time
- **WHEN** `devcontainer-build.yml`'s container-assertion job (or a
  repeated local `devcontainer-smoke.sh` run) starts the bot container
- **THEN** it mounts run-specific, uniquely-named volumes for all five
  persisted-state paths — `~/.gemini`, `~/.config/opencode`, `~/.copilot`,
  `~/.pi`, and `~/.omp` — created fresh for that run and removed
  afterward — rather than the same persistent volumes a real bot
  devcontainer reuses across rebuilds, so every run observes `apply`'s true
  first-run, absent-backup behavior instead of a stale backup or
  already-managed value left over from a previous run

### Requirement: Claude Code non-interactive boundary
The bot profile SHALL set `permissions.defaultMode` to `bypassPermissions` in
`/etc/claude-code/managed-settings.json`, and `verify` SHALL fail if the
effective value differs. This boundary governs `claude-code` and every
slug aliased to it.

#### Scenario: apply sets bypassPermissions in the managed settings
- **WHEN** the `claude-code` module's `apply` runs in the bot profile
- **THEN** `/etc/claude-code/managed-settings.json` has
  `permissions.defaultMode` set to `"bypassPermissions"`

#### Scenario: verify fails on a non-bypass effective mode
- **WHEN** `verify` reads `/etc/claude-code/managed-settings.json` and
  `permissions.defaultMode` is not `"bypassPermissions"`
- **THEN** `verify` exits non-zero naming Claude Code

### Requirement: Codex non-interactive boundary via checksum-verified managed config
The bot profile SHALL install a complete, shipped
`codex-managed-config.bot.toml` over `/etc/codex/managed_config.toml`
(`sandbox_mode = "danger-full-access"`, `approval_policy = "never"`), and
`verify` SHALL confirm the installed file's checksum matches the shipped bot
config rather than pattern-matching individual keys.

#### Scenario: apply installs the complete bot managed config
- **WHEN** the `codex-cli` module's `apply` runs in the bot profile
- **THEN** `/etc/codex/managed_config.toml` is replaced with the shipped
  `codex-managed-config.bot.toml` content in full, not a rewrite of the
  human-baseline file

#### Scenario: verify fails on a checksum mismatch
- **WHEN** `verify` computes the checksum of the installed
  `/etc/codex/managed_config.toml` and it does not match the shipped
  `codex-managed-config.bot.toml`
- **THEN** `verify` exits non-zero naming Codex, independent of which byte
  differs

#### Scenario: effective sandbox and approval policy are the bot values
- **WHEN** `verify` reads the installed Codex managed config in the bot
  profile
- **THEN** `sandbox_mode` reads `danger-full-access` and `approval_policy`
  reads `never`

### Requirement: Codex bot config stays structurally derived from the shared baseline
`codex-managed-config.bot.toml` SHALL match
`.devcontainer/config/codex-managed-config.toml` on every key except
`sandbox_mode` and `approval_policy`. A structural parity test SHALL fail
when the two files diverge on any other key, so an edit to the shared
baseline (model, reasoning effort, project-doc budget, hooks, status line)
cannot silently go stale in the bot file while checksum `verify` keeps
passing against the stale copy.

#### Scenario: a parity test catches baseline drift
- **WHEN** the structural parity test runs
- **THEN** it fails if `codex-managed-config.bot.toml` and
  `codex-managed-config.toml` differ on any key other than `sandbox_mode`
  or `approval_policy`

#### Scenario: the two intentional overrides are exempt
- **WHEN** the structural parity test runs and only `sandbox_mode` and
  `approval_policy` differ between the two files
- **THEN** the test passes

### Requirement: Antigravity's launcher is exactly one of three states, driven by a rendered Copier-answer marker
`~/.local/bin/agy` SHALL be exactly one of: **(a)** the flag-injecting
autonomy wrapper — present only in the bot profile when
`containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` — that
delegates to `~/.local/bin/agy-real` when present, else the system binary
at `/usr/local/bin/agy`; **(b)** a plain symlink to `agy-real`, present
only when `agy-real` itself exists; **(c)** absent. It SHALL NOT be a
dangling symlink (a symlink whose target does not exist).
`HARMON_BOT_AUTONOMY_ANTIGRAVITY` SHALL be set by the **rendered**
`devcontainer.json` (bot) and `dev/devcontainer.json` — both
`[% if devcontainer %]`-conditional jinja twins — from
`[[ 'enabled' if use_antigravity_cli else 'disabled' ]]` (this template's
own Jinja delimiters, per `copier.yml`'s `_envops` block — never the
standard `{{ }}`/`{% %}` pair), to the literal string `enabled` or
`disabled`; this repository's own root `.devcontainer/devcontainer.json`
(the rendered form, not a jinja twin) carries the literal value matching
`.dogfood-answers.yml`. No **verbatim** script —
`.devcontainer/config/ensure-antigravity-cli.sh`, `bot-autonomy.sh`, or
any `bot-autonomy` module — SHALL derive the Copier answer any other way
(no `copier.yml`/`.copier-answers.yml` read, no render-time file-tree
inspection): a verbatim twin ships identical bytes to every generated
repo regardless of that repo's answers, so the rendered `containerEnv`
marker is the only channel through which a verbatim script can know a
per-repo Copier answer at all.

`ensure-antigravity-cli.sh` SHALL own `agy-real` and states (b)/(c): in
**either** profile, WHEN the marker reads `enabled`, it downloads and
verifies the pinned binary at `agy-real` and (re)points a plain
`agy → agy-real` symlink — including on its early-return path where a
local `agy-real` copy already exists at the pinned version — with one
exception: WHEN the current on-`PATH` system binary at
`/usr/local/bin/agy` already matches the pinned version and no local
`agy-real` copy exists yet, it SHALL create neither, leaving `agy` in
state (c) when `agy` was already absent too — instead of installing an
unnecessary shadow copy, `agy` then resolves directly to the sufficient
system binary via `PATH`, which still satisfies the no-dangling-symlink
invariant above because nothing points at a missing target. This
branch's own precondition checks only `agy-real`'s absence, not `agy`'s:
a pre-existing `agy` (a dangling symlink or another leftover reachable
only through an out-of-band change to the persisted volume, not through
this capability's own apply/verify cycle) is left exactly as found here,
rather than reconciled — the bot profile self-heals regardless, because
the `antigravity` module's `apply` runs immediately after and
unconditionally overwrites `agy` with the wrapper, but the dev profile
has no such follow-on step. WHEN the marker reads anything other than `enabled`
(`disabled`, or absent on an image built before this marker existed), it
SHALL ensure **neither** `agy-real` nor `agy` exists, removing either if a
prior run (before a Copier-answer toggle) or a stale image left them
behind — reaching state (c) directly, never state (b) with nothing to
point at. The bot-autonomy `antigravity` module, bot-only, SHALL act only
on top of that: WHEN its own read of the marker is `enabled`, `apply`
overwrites `~/.local/bin/agy` — whatever `ensure-antigravity-cli.sh` left
there — with the wrapper (state a); WHEN the marker is not `enabled`,
`apply` SHALL NOT create, remove, or otherwise touch `agy` at all
(`ensure-antigravity-cli.sh`, which runs first, has already left it
absent — state (c) — and re-touching it would be redundant, not
corrective) and SHALL restore `~/.gemini/antigravity-cli/settings.json`
to its pre-managed state (via `apply-antigravity-settings.sh restore`).
`verify` SHALL assert whichever of the three states the marker's value
implies is correct, and SHALL fail on a dangling symlink regardless of the
marker's value — no valid state is ever a symlink with a missing target.

WHEN the wrapper is installed (state a), it SHALL prepend
`--dangerously-skip-permissions` to every **agent/headless execution**
launch that does not already carry it, and pass a fixed set of
subcommands and flags through unmodified without prepending the flag: a
bare `agy` (interactive, already covered by the settings-file policy),
`agent`/`agents`, `changelog`, `help`/`-h`/`--help`, `install`, `models`,
`plugin`/`plugins`, `update`, and `--version` — matching the passthrough
list already proven correct in `agy-autonomy.sh`, the shell-function
mechanism this wrapper replaces. Prepending the flag to any of these is
either rejected by `agy` or meaningless. `ensure-antigravity-cli.sh`'s own
version check reads `agy-real --version` directly — not through the
wrapper or the symlink — so its idempotency never depends on either being
correct. The wrapper's precedence over the system `agy` binary — when the
wrapper is installed at all — SHALL be established at the **container
level**: the bot `Dockerfile` prepends `/home/vscode/.local/bin` ahead of
`/usr/local/bin` onto `PATH` via a Docker `ENV` directive, not by a shell rc
file's `PATH` export and not by `devcontainer.json`'s `containerEnv` (a
`containerEnv.PATH` entry that self-references `${containerEnv:PATH}` does
not resolve at container-creation time — the devcontainers CLI passes it to
`docker run -e` literally, unresolved, which breaks the container's own
shell; a Docker `ENV` directive is Docker's own, working self-reference and
applies identically to any `docker exec`). This still closes the same gap a
shell function or an rc-dependent `PATH` prepend would leave open: a process
that never sources an interactive login shell (a `docker exec` without a
login/interactive shell, a Foreman-dispatched process, a cron job).

#### Scenario: the marker is rendered per repo, never derived by a verbatim script
- **WHEN** a repo is generated (or updated) with `use_antigravity_cli` at
  some value
- **THEN** the rendered bot `devcontainer.json` and `dev/devcontainer.json`
  both carry `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` set to the
  literal `"enabled"` or `"disabled"` matching that answer, and no
  verbatim script (`ensure-antigravity-cli.sh`, `bot-autonomy.sh`, the
  `antigravity` module) reads the answer any other way

#### Scenario: ensure-antigravity-cli.sh installs agy-real and the symlink when enabled, in either profile
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`,
  `ensure-antigravity-cli.sh` runs — in the bot profile or the dev profile
  — and either a local `agy-real` copy already exists or the current
  on-`PATH` system binary does not already satisfy the pinned version
- **THEN** it downloads/reconciles the pinned binary at
  `~/.local/bin/agy-real` and (re)points `~/.local/bin/agy` at it as a
  plain symlink

#### Scenario: ensure-antigravity-cli.sh leaves agy absent when the current system binary already satisfies the pin
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`,
  `ensure-antigravity-cli.sh` runs, the on-`PATH` system binary at
  `/usr/local/bin/agy` already matches the pinned version, no local
  `agy-real` copy exists yet, and `agy` is not already present either
- **THEN** it creates neither `agy-real` nor `agy` — avoiding an
  unnecessary shadow copy of a binary the image already ships — and `agy`
  resolves directly to the sufficient system binary via `PATH`, which is
  state (c) and not a dangling symlink

#### Scenario: a pre-existing agy is not reconciled by the system-binary-sufficient exit
- **WHEN** the on-`PATH` system binary at `/usr/local/bin/agy` already
  matches the pinned version, no local `agy-real` copy exists, and `agy`
  already exists — a dangling symlink, a wrapper, or any other leftover,
  reachable only through an out-of-band change to the persisted volume
- **THEN** `ensure-antigravity-cli.sh` exits without creating `agy-real`
  or otherwise touching `agy` — this branch's own precondition checks
  only `agy-real`'s absence, not `agy`'s. In the bot profile this
  self-heals: the `antigravity` module's `apply` runs immediately after
  and unconditionally overwrites `agy` with the wrapper regardless of
  what it finds. The dev profile has no such follow-on step, so a stale
  `agy` there survives until a full disable/re-enable cycle or a manual
  cleanup clears it

#### Scenario: ensure-antigravity-cli.sh leaves agy absent when disabled, in either profile
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and
  `ensure-antigravity-cli.sh` runs — in the bot profile or the dev profile
- **THEN** it does not download `agy-real`, and removes `agy-real` and
  `agy` if either exists from a prior run (before a Copier-answer toggle)
  or a stale image

#### Scenario: bot apply installs the wrapper when enabled, whatever ensure-antigravity-cli.sh left
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and the
  `antigravity` module's `apply` runs in the bot profile, after
  `ensure-antigravity-cli.sh` has already left either the plain symlink or
  — in the system-binary-sufficient early return above — `agy` absent
- **THEN** `apply` creates or overwrites `~/.local/bin/agy` with the
  flag-injecting wrapper script either way, since installing the wrapper
  does not depend on a symlink pre-existing there

#### Scenario: bot apply does not touch agy when disabled — it is already absent
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and the
  `antigravity` module's `apply` runs in the bot profile
- **THEN** `apply` restores `~/.gemini/antigravity-cli/settings.json` via
  `apply-antigravity-settings.sh restore`, and does not create, remove, or
  otherwise touch `~/.local/bin/agy` — `ensure-antigravity-cli.sh`, having
  already run, has already left it absent

#### Scenario: toggling the option off removes agy-real and agy entirely, not a symlink
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` was previously `enabled`
  (`agy-real`, the symlink, and then the wrapper all installed) and a
  later render/rebuild carries the marker as `disabled`
- **THEN** `ensure-antigravity-cli.sh` removes both `agy-real` and `agy`
  on its next run, reaching state (c) absence — not state (b), since a
  symlink with no download step left to populate its target would be a
  dangling link

#### Scenario: verify asserts the disabled state is absence, not a symlink
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and `verify`
  runs in the bot profile
- **THEN** `verify` asserts `~/.local/bin/agy` is absent — a default-off
  generated render never invokes the compatibility installer's download
  path in the first place, so there is no `agy-real` for any symlink to
  point at, and `verify` treats a symlink (dangling or not) in this state
  as a failure, not the correct disabled state

#### Scenario: the wrapper precedes the system binary on the container-wide PATH
- **WHEN** the bot `Dockerfile` is inspected
- **THEN** it prepends `/home/vscode/.local/bin` ahead of `/usr/local/bin`
  (where the system `agy` binary is installed) onto `PATH` via an `ENV`
  directive, so the ordering applies to every process the container runs —
  not only shells that source `.bashrc`/`.zshrc` — regardless of which of
  the three states `agy` is currently in

#### Scenario: a process with no shell rc still resolves the wrapper when enabled
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and
  `agy --version` is resolved by a process that has not sourced any shell
  rc file — a `docker exec` invocation that does not start a
  login/interactive shell, or an equivalent `env -i
  PATH=$CONTAINER_PATH agy --version` using the container's own PATH value
- **THEN** the resolved `agy` is `~/.local/bin/agy` (the wrapper), not the
  system binary at `/usr/local/bin/agy`

#### Scenario: a headless invocation off PATH still receives the flag when enabled
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and a
  programmatic launcher that never sources a login shell execs `agy -p …`
  by resolving it off `PATH` (not via the interactive shell function)
- **THEN** the resolved `~/.local/bin/agy` wrapper adds
  `--dangerously-skip-permissions` to the invocation

#### Scenario: the wrapper prefers the compatibility copy over a stale system binary
- **WHEN** the container's baked-in system binary at `/usr/local/bin/agy`
  predates the version `ensure-antigravity-cli.sh` pins (an older pinned
  image that has not yet picked up the latest shared-image release) and
  `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`
- **THEN** `ensure-antigravity-cli.sh` has already downloaded the pinned
  version to `~/.local/bin/agy-real`, and the wrapper at `~/.local/bin/agy`
  execs `agy-real` — not the stale `/usr/local/bin/agy` — so both the
  flag injection and the correct, freshest binary version hold at once

#### Scenario: the wrapper does not duplicate an explicit flag
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and a caller
  invokes `agy` already passing `--dangerously-skip-permissions`
- **THEN** the wrapper does not add the flag a second time

#### Scenario: passthrough subcommands and flags are not modified
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and the
  wrapper is invoked as a bare `agy`, or with `agent`, `agents`,
  `changelog`, `help`, `-h`, `--help`, `install`, `models`, `plugin`,
  `plugins`, `update`, or `--version`
- **THEN** it execs the resolved real `agy` binary (`agy-real` when
  present, else the system binary) unchanged, without prepending
  `--dangerously-skip-permissions`

#### Scenario: verify fails if the enabled state's boundary is missing, inert, or misdirected
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, and `~/.local/bin/agy` is missing, not executable,
  does not inject the flag, or — when `agy-real` exists — does not resolve
  to it
- **THEN** `verify` exits non-zero naming Antigravity

#### Scenario: verify fails when the wrapper's own resolved backend cannot run
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, the wrapper at `~/.local/bin/agy` matches its
  expected content exactly, and neither `agy-real` nor the system binary
  it falls back to is executable
- **THEN** `verify` exits non-zero naming Antigravity — matching wrapper
  bytes are not sufficient when every invocation would exit 127

#### Scenario: verify fails when the current workspace is missing from the settings' trust list
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, every scalar autonomy key matches the shipped
  defaults, and `~/.gemini/antigravity-cli/settings.json`'s
  `trustedWorkspaces` does not include the current workspace (the entry
  `apply-antigravity-settings.sh apply` itself writes)
- **THEN** `verify` exits non-zero naming Antigravity — a correct
  `toolPermission` value does not by itself bypass the workspace-trust gate

#### Scenario: verify fails on a dangling symlink regardless of the marker
- **WHEN** `verify` runs and `~/.local/bin/agy` is a symlink whose target
  (`agy-real`) does not exist, in either profile and regardless of the
  marker's value
- **THEN** `verify` exits non-zero naming Antigravity — none of the three
  valid states is a dangling link

### Requirement: OpenCode non-interactive boundary forces the managed permission key
The bot profile SHALL force `permission.*` to `"allow"` in
`~/.config/opencode/opencode.json` on every `apply`, overriding any existing
value for that key, while preserving every other key already present in the
file. `apply` SHALL create `~/.config/opencode` itself (`mkdir -p`,
matching `apply-antigravity-settings.sh`'s own pattern for its target
directory) rather than depending on any other script having created it
first, so the module has no ordering dependency on
`post-create-common.sh`'s directory-creation loop. `verify` SHALL fail if
the **fully resolved** effective permission
policy — global config layered with any workspace-level `opencode.json` the
current repository provides — is not allow-all, since OpenCode resolves a
workspace-level `permission` value over the global one and a global-only
check would recreate the effective-state gap this change exists to close.

#### Scenario: apply seeds permission allow-all on a fresh volume
- **WHEN** the `opencode` module's `apply` runs and
  `~/.config/opencode/opencode.json` does not yet exist
- **THEN** the file is created with `"permission": {"*": "allow"}`

#### Scenario: apply overrides a prior non-allow permission value
- **WHEN** `apply` runs and `~/.config/opencode/opencode.json` already
  exists with `permission.* = "ask"` or `"deny"` (from a human edit, a prior
  balanced policy, or an unmanaged default)
- **THEN** `permission.*` reads `"allow"` afterward — the prior value does
  not win — and every unrelated key in the file (for example `theme`) is
  unchanged

#### Scenario: verify fails on a non-allow-all effective policy
- **WHEN** `verify` reads the fully resolved OpenCode permission policy
  (via OpenCode's own config-resolution surface, run from the repository
  being worked in — not a raw read of the global file alone) and it is not
  allow-all
- **THEN** `verify` exits non-zero naming OpenCode

#### Scenario: a workspace-level override is not silently missed
- **WHEN** the current repository provides its own `opencode.json` (project
  or `.opencode/opencode.json`) whose `permission.*` is not `"allow"`,
  overriding the global default `apply` set
- **THEN** `verify` fails, naming the workspace-level file as the cause —
  forcing the global default alone is not sufficient when a workspace file
  can override it

### Requirement: OpenCode and Antigravity policy changes are individually reversible
Because `~/.config/opencode` and `~/.gemini` are named volumes that persist
across a container rebuild (and across a Coder workspace, via its own
persistence layer), `apply` SHALL record each managed key's prior value (or
its absence) before overriding it, in a form a `restore` operation can use
to put the prior value back — matching the pattern
`apply-antigravity-settings.sh` already implements for Antigravity.
Reverting the implementation PR alone does not undo a value already written
to a persisted volume; `restore` is what does.

#### Scenario: OpenCode apply records the prior permission value on the first run only
- **WHEN** the `opencode` module's `apply` runs, no backup exists yet, and
  `~/.config/opencode/opencode.json` already has a `permission` key
- **THEN** that pre-`apply` value is captured in a form a restore step can
  read back, before `apply` overrides it

#### Scenario: a second apply does not overwrite the first backup
- **WHEN** `apply` runs again after a backup already exists (from a prior
  `apply`)
- **THEN** the existing backup is left untouched — `apply` does not
  re-capture the current (already-managed, `"allow"`) value over it, which
  would otherwise silently replace the true pre-first-`apply` value (e.g.
  `"ask"`/`"deny"`) with the value `apply` itself wrote, making the original
  state unrecoverable

#### Scenario: OpenCode restore returns the value captured before the first apply
- **WHEN** an operator runs the `opencode` module's restore step after
  `apply` has run one or more times (an `apply → apply → restore`
  sequence, not only a single `apply → restore`)
- **THEN** `permission.*` returns to the value captured before the *first*
  `apply` in that sequence, and every key `apply` did not manage is
  untouched

#### Scenario: restore removes the permission key when it was absent before apply
- **WHEN** `opencode.json` had no `permission` key at all (or did not
  exist) immediately before the first `apply`, and an operator later runs
  `restore`
- **THEN** the `permission` key is removed from `opencode.json` entirely —
  not set to some default value — matching how
  `apply-antigravity-settings.sh`'s restore only re-adds keys that were
  actually present in the backup

#### Scenario: restore clears the backup so the next cycle starts fresh
- **WHEN** `restore` completes
- **THEN** the backup file itself is deleted (matching
  `apply-antigravity-settings.sh`'s `rm -f "$backup_path"` at the end of
  its own restore case), so a subsequent `apply` captures a fresh
  pre-`apply` value instead of reading a stale backup left over from the
  prior `apply`/`restore` cycle

#### Scenario: Antigravity's existing restore mechanism is reused, not reinvented
- **WHEN** the bot-autonomy `antigravity` module's restore path is invoked
- **THEN** it delegates to `apply-antigravity-settings.sh restore`, the
  existing mechanism that already backs up and restores the keys it
  manages, rather than a new parallel implementation

#### Scenario: rolling back the implementation requires restore before revert, not after
- **WHEN** an operator rolls back this change's implementation PR on a bot
  container that had already run `apply`
- **THEN** the operator runs each module's `restore` **before** reverting
  the PR. For OpenCode this is required, not merely tidy: its restore
  logic (`.devcontainer/config/bot-autonomy/opencode.sh`) is introduced by
  this change, so a reverted checkout no longer contains it, and
  attempting `restore` after reverting cannot recover the pre-`apply`
  `permission` value. Antigravity's recovery does not share this
  constraint — `apply-antigravity-settings.sh` predates this change
  (introduced by PR #701) and survives a revert intact, so its `restore`
  subcommand, and the always-proceed recovery path it implements, remains
  directly invocable whether the operator runs it before or after
  reverting

### Requirement: Human dev profile is unaffected by construction
The bot-autonomy wrappers and modules SHALL be installed by the bot
post-create only. The dev post-create SHALL NOT invoke `bot-autonomy.sh
apply`, `verify`, or install the `agy` wrapper, so the human profile's
existing prompt-enabled and balanced permission policies are unchanged by
this capability's existence rather than by a separate runtime check.

#### Scenario: dev post-create never calls the bootstrap or installs the wrapper
- **WHEN** `.devcontainer/dev/post-create.sh` runs
- **THEN** it does not invoke `bot-autonomy.sh apply` or `verify`, and
  never installs the flag-injecting autonomy wrapper (state a) at
  `~/.local/bin/agy` — only `ensure-antigravity-cli.sh`'s plain
  `agy → agy-real` symlink (state b, when `HARMON_BOT_AUTONOMY_ANTIGRAVITY`
  reads `enabled` and a local copy is needed) or absence (state c, when
  disabled, or when enabled and the on-`PATH` system binary already
  satisfies the pin) is permitted in the dev profile

#### Scenario: dev profile policies remain prompt-enabled or balanced
- **WHEN** a dev profile container is created or rebuilt
- **THEN** Claude Code's managed `defaultMode` is unset (normal
  prompt-on-action), Codex's managed config reads `workspace-write`/
  `on-request`, and Antigravity's settings reflect the balanced
  `antigravity-settings-dev.json` policy — none of them the bot's values

### Requirement: End-to-end effective autonomy
A freshly rebuilt, generated bot devcontainer SHALL run a representative
filesystem operation and a representative GitHub operation through each
authenticated, in-scope, and (for a Copier-gated harness) enabled harness
with zero approval prompts. For a Copier-gated harness whose option is at
its default (disabled), the *absence* of a prompt-free run is the
correct, by-design outcome — not a gap this requirement expects closed.

#### Scenario: representative operations complete without a prompt when every Copier-gated harness is enabled (manual verification)
- **WHEN** an operator rebuilds a freshly generated bot devcontainer with
  `use_antigravity_cli: true` and `use_copilot_cli: true` and, for each of
  Claude Code, Codex, Antigravity, OpenCode, Copilot CLI, pi, and oh-my-pi,
  authenticates the harness and runs one representative filesystem write
  and one representative GitHub API read/write
- **THEN** every operation completes without an approval prompt from any
  of the seven harnesses

#### Scenario: each Copier-gated harness stays prompt-enabled by design at its default answer (manual verification)
- **WHEN** an operator rebuilds a freshly generated bot devcontainer with
  `use_antigravity_cli` and `use_copilot_cli` left at their defaults
  (disabled) and, for each of Claude Code, Codex, Antigravity, OpenCode,
  Copilot CLI, pi, and oh-my-pi, authenticates the harness and runs the
  same representative operations
- **THEN** Claude Code, Codex, OpenCode, pi, and oh-my-pi complete without
  an approval prompt, and Antigravity and Copilot CLI each prompt as they
  would out of the box — a prompt-enabled Antigravity CLI and Copilot CLI
  at their default answers is the verified-correct outcome (per the
  disabled-by-option requirements above), not a failure of this
  requirement

### Requirement: GitHub Copilot CLI's autonomy policy is Copier-gated, following the established Copier-gated-harness contract
The bot profile SHALL gate GitHub Copilot CLI's non-interactive policy behind
a new, default-off Copier answer `use_copilot_cli`, following the
Copier-gated-harness contract the archived `bot-autonomy-bootstrap` change
establishes for Antigravity: the `copilot-cli` module SHALL always exist and always cover
the harness; only its effective policy is conditional. The module's `apply`
SHALL read the rendered `containerEnv.HARMON_BOT_AUTONOMY_COPILOT` marker
(`enabled`/`disabled`, rendered as
`[[ 'enabled' if use_copilot_cli else 'disabled' ]]` — this template's own
Jinja delimiters, per `copier.yml`'s `_envops` block: `[[ … ]]` for
expressions, `[% … %]` for blocks, never the standard `{{ }}`/`{% %}` pair,
reserved so a generated `.github/workflows/*.yml` file's own
`${{ github.… }}` expressions never collide with Copier's own templating —
exactly the pattern `HARMON_BOT_AUTONOMY_ANTIGRAVITY` already uses for
`use_antigravity_cli`) and SHALL NOT derive the Copier answer any other way. Unlike `HARMON_BOT_AUTONOMY_ANTIGRAVITY`,
which the bot **and** dev `devcontainer.json` jinja twins both render (a
shared script, `ensure-antigravity-cli.sh`, runs in both profiles and needs
the marker in either), `HARMON_BOT_AUTONOMY_COPILOT` and `COPILOT_ALLOW_ALL`
SHALL be rendered into the **bot** `devcontainer.json` jinja twin only.
Nothing in the dev profile ever reads either one — the `copilot-cli` module
never runs there, and there is no Copilot equivalent of
`ensure-antigravity-cli.sh` — and `COPILOT_ALLOW_ALL` is a plain environment
variable Copilot CLI honors directly, in whichever profile sets it: were it
rendered into dev's `containerEnv` too, a human's own interactive Copilot CLI
session in the dev profile would silently run allow-all, contradicting the
dev profile's prompt-enabled/balanced posture (one of #1137's own,
already-satisfied acceptance criteria) regardless of the bot-autonomy module
never running there.

`containerEnv.COPILOT_ALLOW_ALL` SHALL be rendered to the exact literal
string `"true"` when `use_copilot_cli` is on and the exact literal string
`"false"` when it is off — present in **both** states, never omitted in
either. Omitting the key when disabled is insufficient: the bot profile also
loads `.devcontainer/devcontainer.env` via `--env-file`, a separately
populated file `init-env.sh` does not manage this variable in at all (it is
not one of the secrets that script recognizes), so an out-of-band or
stale `COPILOT_ALLOW_ALL=true` entry there — however it got there — would
otherwise survive a disabled render undisturbed; `containerEnv` values take
precedence over `--env-file` values for a key both specify, but only for a
key `containerEnv` actually specifies, not one it merely leaves out. `apply`
SHALL NOT itself attempt to set `COPILOT_ALLOW_ALL` — a container-wide
environment variable is fixed by the rendered `containerEnv` before any
lifecycle script runs, not writable at runtime the way a settings file is —
so `apply` SHALL instead treat the variable's exact value in its own process
environment as an input to check, not a value to produce. `verify` SHALL
require the exact literal `"true"` for the autonomous state, not any
truthy-looking value — the documented Copilot contract this proposal's own
research found checks for that exact string, not general truthiness, so a
render or override that produces some other non-`"true"` value (`"1"`,
`"yes"`, empty) would pass a looser check while Copilot itself still does
not grant allow-all.

#### Scenario: the disabled-by-option state is verified, not merely defaulted
- **WHEN** `use_copilot_cli` is off (the default) and `bot-autonomy.sh apply`
  runs the `copilot-cli` module in the bot profile
- **THEN** `COPILOT_ALLOW_ALL` reads the exact literal `"false"` in the
  container's environment — overriding any stale same-named value that
  might otherwise reach the container via `--env-file` — `~/.local/bin/copilot`
  does not exist, and `verify` asserts both: a prompt-enabled Copilot CLI is
  the verified-correct state in this configuration, not an uncovered gap

#### Scenario: the autonomous state requires the exact documented value
- **WHEN** `use_copilot_cli` is on and `bot-autonomy.sh apply` runs the
  `copilot-cli` module in the bot profile
- **THEN** `COPILOT_ALLOW_ALL` reads the exact literal `"true"` in the
  container's rendered environment, `~/.local/bin/copilot` exists as the
  flag-injecting wrapper, and `verify` asserts both — including confirming
  this repository's own `.dogfood-answers.yml` sets `use_copilot_cli` on, so
  this repository's own bot container runs Copilot CLI autonomously, while a
  freshly generated repo defaults to `disabled-by-option`

#### Scenario: verify fails on a truthy-but-not-exact value
- **WHEN** `use_copilot_cli` is on, `bot-autonomy.sh verify` runs in the bot
  profile, and `COPILOT_ALLOW_ALL`'s effective value is present but is not
  the exact literal `"true"` (for example `"1"`, `"yes"`, or an empty
  string reached some other way)
- **THEN** `verify` exits non-zero naming Copilot CLI — a value Copilot's
  own documented contract does not check for is not the verified-correct
  autonomous state, even if it looks truthy to a looser check

#### Scenario: a stale out-of-band value cannot survive a disabled render
- **WHEN** `use_copilot_cli` is off, `.devcontainer/devcontainer.env` (the
  bot profile's `--env-file`) already contains `COPILOT_ALLOW_ALL=true` from
  some prior, out-of-band cause, and the bot container is created or rebuilt
- **THEN** the container's effective `COPILOT_ALLOW_ALL` reads `"false"` —
  the rendered `containerEnv` entry, which Docker applies with precedence
  over `--env-file` — not the stale env-file value

#### Scenario: the dev profile never receives COPILOT_ALLOW_ALL, regardless of the answer
- **WHEN** a repo is generated (or updated) with `use_copilot_cli` at any
  value and the dev `devcontainer.json` twin is inspected
- **THEN** its `containerEnv` carries neither `HARMON_BOT_AUTONOMY_COPILOT`
  nor `COPILOT_ALLOW_ALL` — a human's own interactive Copilot CLI session in
  the dev profile is never allow-all, independent of the bot-autonomy
  module never running there either

#### Scenario: apply fails loudly on a marker/environment inconsistency
- **WHEN** `HARMON_BOT_AUTONOMY_COPILOT` reads `enabled` but
  `COPILOT_ALLOW_ALL` is not the exact literal `"true"` in `apply`'s own
  process environment (a render defect — the jinja twin failed to carry the
  marker's value into the actual environment variable correctly)
- **THEN** `apply` exits non-zero naming the inconsistency rather than
  installing the wrapper against an environment that will not actually
  grant it allow-all permissions

#### Scenario: verify fails when the enterprise kill-switch blocks bypass mode
- **WHEN** `use_copilot_cli` is on, `bot-autonomy.sh verify` runs in the bot
  profile, and `~/.copilot/settings.json`'s `permissions.disableBypassPermissionsMode`
  reads `"disable"`
- **THEN** `verify` exits non-zero naming Copilot CLI — this key is the one
  documented mechanism that neuters `COPILOT_ALLOW_ALL` and every
  `--allow-all`-family flag regardless of this module's own state, so a
  bot container in this configuration is not actually autonomous no matter
  what `apply` wrote

### Requirement: the copilot module's wrapper mirrors the Antigravity launcher invariant
WHEN the `copilot-cli` module's marker reads `enabled`, `~/.local/bin/copilot`
SHALL be the flag-injecting wrapper; WHEN it does not, `~/.local/bin/copilot`
SHALL NOT exist. The wrapper SHALL add `--allow-all` (equivalent to
`--allow-all-tools --allow-all-paths --allow-all-urls`) to every invocation
that performs an agent task — including a bare `copilot` (the interactive
UI) and `copilot -p`/`--prompt` (headless/programmatic mode) — unless the
invocation already carries full allow-all coverage explicitly: `--allow-all`,
`--yolo`, or all three of `--allow-all-tools`, `--allow-all-paths`, and
`--allow-all-urls` together. An invocation carrying only some of the three
narrower flags (for example `--allow-all-tools` alone) is **not** full
coverage and SHALL still receive `--allow-all` — prepending it alongside an
already-present narrower flag is redundant for the dimension that flag
already covers, but is what actually grants the dimensions it does not;
skipping injection there would leave that invocation restricted for
whichever of tools/paths/URLs its own flags did not name, silently
defeating the full-autonomy guarantee this wrapper exists to provide,
specifically in the sanitized-environment case (an `env -i` launcher with no
`COPILOT_ALLOW_ALL` fallback) the wrapper is meant to cover. It SHALL pass a fixed set of
administrative/informational subcommands through unmodified, without
prepending the flag: `login`, `version`/`--version`, `help`/`-h`/`--help`,
`update`, `completion`, `init`, `plugin`/`plugins`, `mcp`, `skill`, and
`app`. The wrapper SHALL resolve and exec the real, shared-image-installed
`copilot` binary without re-invoking itself (for example, by resolving the
next `copilot` on `PATH` after excluding its own directory), rather than
hardcoding one specific installation path.

`verify` SHALL check the enabled-state wrapper the same way the archived
`bot-autonomy-bootstrap` change's own Antigravity module already checks
its wrapper — presence and executability are necessary but not sufficient:
`verify` SHALL also compare the installed file's content against the
module's own known-correct wrapper content (byte-for-byte, generated from
the same source the `apply` step itself installs from, so `apply` and
`verify` can never independently drift from each other) and SHALL confirm
the wrapper's resolved delegate (the real `copilot` binary it execs) is
itself executable — matching content proves the wrapper's own bytes are
correct, but a wrapper whose delegate cannot be resolved or executed is
still an inert harness that would pass a presence-only check while every
invocation actually fails.

#### Scenario: the wrapper injects the flag on an agent-task invocation
- **WHEN** the marker reads `enabled` and the wrapper is invoked as a bare
  `copilot`, or as `copilot -p "<prompt>"`, without any `--allow-all`-family
  flag at all
- **THEN** it execs the real `copilot` binary with `--allow-all` prepended

#### Scenario: the wrapper does not duplicate already-complete coverage
- **WHEN** the marker reads `enabled` and a caller invokes `copilot` already
  passing `--allow-all`, `--yolo`, or all three of `--allow-all-tools`,
  `--allow-all-paths`, and `--allow-all-urls` together
- **THEN** the wrapper does not prepend `--allow-all` a second time

#### Scenario: a partial allow-all flag still gets the full flag prepended
- **WHEN** the marker reads `enabled` and a caller invokes
  `copilot --allow-all-tools -p "<prompt>"` — one of the three narrower
  flags, but not all three — for example inside a sanitized environment
  (`env -i`) where `COPILOT_ALLOW_ALL` is not present as a fallback
- **THEN** the wrapper still prepends `--allow-all`, so the invocation ends
  up with full tools/paths/URLs coverage rather than remaining restricted
  for the two dimensions its own explicit flag did not name

#### Scenario: administrative subcommands are not modified
- **WHEN** the marker reads `enabled` and the wrapper is invoked with
  `login`, `version`, `--version`, `help`, `-h`, `--help`, `update`,
  `completion`, `init`, `plugin`, `plugins`, `mcp`, `skill`, or `app`
- **THEN** it execs the real `copilot` binary unchanged, without prepending
  `--allow-all`

#### Scenario: a headless invocation off PATH still receives the flag
- **WHEN** the marker reads `enabled` and a programmatic launcher that never
  sources a login shell execs `copilot -p "…"` by resolving it off `PATH`
- **THEN** the resolved `~/.local/bin/copilot` wrapper adds `--allow-all` —
  the wrapper's precedence over the shared image's `copilot` binary is
  established at the container level, reusing the `PATH` prepend the
  archived `bot-autonomy-bootstrap` change already ships (an `ENV PATH=…` directive in
  `.devcontainer/Dockerfile` and its `template/` twin, ahead of the system
  binaries' directory) for Antigravity's own wrapper; this module does not
  need a second `PATH` entry

#### Scenario: toggling the option off removes the wrapper entirely
- **WHEN** `use_copilot_cli` was previously on (`~/.local/bin/copilot`
  installed) and a later render/rebuild carries the marker as `disabled`
- **THEN** the `copilot-cli` module's `apply` removes `~/.local/bin/copilot`
  on its next run, and `verify` asserts its absence

#### Scenario: verify fails on a wrapper with the wrong content or no runnable delegate
- **WHEN** the marker reads `enabled` and `bot-autonomy.sh verify` runs, and
  either `~/.local/bin/copilot`'s content does not byte-for-byte match the
  module's own known-correct wrapper content, or neither the wrapper's
  resolved delegate nor a documented fallback system binary is executable
- **THEN** `verify` exits non-zero naming Copilot CLI in each case — a
  wrapper file merely existing and being marked executable is not
  sufficient; matching content and a runnable delegate are both required,
  mirroring exactly how the Antigravity module's `verify` already checks
  its own wrapper

### Requirement: pi's non-interactive boundary is no elevated trust — decided by the maintainer
**Status: resolved — maintainer decision 2026-09-03, option (a).** Two
designs for this requirement were adjudicated and rejected during this
proposal's own challenge-review process
(`openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md` -
Decisions has the full record): a global `defaultProjectTrust: "always"` (rejected — grants
automatic trust, and per pi's own docs, automatic *extension code
execution*, to every repository the bot's pi installation is ever pointed
at, not only this one) and a workspace-scoped `~/.pi/agent/trust.json`
entry (rejected — pi resolves trust by **canonical directory path**, not
by content or commit: it survives an untrusted branch checked out into
that same path, and pi's own "closest saved decision on the current **or
parent** path" rule means a trusted path's own trust extends to anything
cloned or nested underneath it). Neither is safe as a default; pi's own
trust primitive has no content-authentication mechanism (no commit
pinning, no hash verification) for a bot-autonomy module to build a safer
version on top of. The maintainer decided the bot profile SHALL NOT
elevate pi's trust posture at all: neither `defaultProjectTrust` nor
`~/.pi/agent/trust.json` SHALL be written by this module, in either
profile — the bot profile's pi behavior is identical to the dev profile's,
pi's own safe out-of-the-box default. This is a deliberate, decided
fallback, not an oversight: #1137's acceptance criteria require every
supported harness to reach a **no-prompt** state, which this option
already satisfies for pi (pi's non-interactive modes never prompt for
trust regardless of this setting — see the pi Decision in
`openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md`); the
maintainer accepted that the bot's non-interactive pi sessions will
silently ignore this repository's own `.pi/` project resources (a
capability gap) rather than ship a mechanism this proposal's own review
process found two ways to make unsafe (a security gap). The rejected
workspace-scoped design remains available as a possible **future, explicit
opt-in** — not the default — if the maintainer later decides the risk it
carries is acceptable for a specific, bounded use; see
`openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md` -
Open Questions and Decisions for the full record. `verify` SHALL, however,
fail closed on **either** of pi's two trust-granting surfaces, regardless
of cause — this module writes to neither, but a stale volume, a manual
edit, an interactive `/trust` run inside the bot container, or a future
regression could populate either one: (1) `defaultProjectTrust` set to
`"always"` in `~/.pi/agent/settings.json`, and (2) **any** trusted saved
decision anywhere in `~/.pi/agent/trust.json` — not only one applicable to
the current workspace (its own canonical directory, or, per pi's own
"closest decision on the current or parent path" rule, a parent of it).
Checking only the global fallback would leave the exact path-keyed exposure
the rejected workspace-scoped design carried
(`openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md` -
Decisions) reachable by any of those same causes, just through the other file —
detecting both is a strengthening of this fallback's safety story, not a
re-attempt at either rejected design. Checking only *applicable* decisions
in that second file would leave a narrower version of the same gap: the
`~/.pi` volume persists for the bot container's entire lifetime, and a
trusted decision that does not apply to the workspace `verify` happens to
be checking right now is still live on disk and becomes applicable the
moment pi is later invoked against a matching path within the same
container — with no guarantee a fresh `verify` runs first to catch it.
Failing closed on any trusted entry, applicable or not, is what actually
enforces "no elevated trust" for the whole volume, not merely for whichever
workspace happened to be current at verify-time.

#### Scenario: the bot profile applies no elevated trust
- **WHEN** the `pi` module's `apply` runs in the bot profile
- **THEN** it writes nothing to `~/.pi/agent/settings.json` or
  `~/.pi/agent/trust.json` — both are left exactly as `pi`'s own install
  and any pre-existing state leave them

#### Scenario: non-interactive pi sessions silently skip project resources, by design
- **WHEN** the bot profile runs `pi -p "<prompt>"` (or `--mode json`/
  `--mode rpc`) against a repository whose `.pi/` directory carries
  project-local settings, extensions, skills, prompts, or themes, and no
  saved trust decision applies
- **THEN** those resources are silently ignored (no prompt, no error,
  pi's own non-interactive default) — the maintainer-decided, accepted
  state of this requirement, not a defect this proposal's other
  requirements are expected to compensate for

#### Scenario: verify fails closed on a dangerous global trust value, whatever its cause
- **WHEN** `bot-autonomy.sh verify` runs in the bot profile and
  `~/.pi/agent/settings.json`'s `defaultProjectTrust` reads `"always"` —
  regardless of whether this module, a stale volume, or a manual edit
  produced it
- **THEN** `verify` exits non-zero naming pi, rather than silently passing
  over a state this proposal's own review identified as unsafe

#### Scenario: verify fails closed on a pre-existing saved trust decision, whatever its cause
- **WHEN** `bot-autonomy.sh verify` runs in the bot profile and
  `~/.pi/agent/trust.json` carries a trusted decision for the current
  workspace — its own canonical directory, or, per pi's
  closest-decision-on-current-or-parent-path rule, any parent of it —
  regardless of whether an interactive `/trust` run, a stale volume, or a
  manual edit produced it
- **THEN** `verify` exits non-zero naming pi — a global `defaultProjectTrust`
  check alone would miss exactly the path-keyed exposure the rejected
  workspace-scoped design carried; `verify` closes both surfaces, not only
  the one this module itself never writes to first

#### Scenario: verify fails closed on a trusted decision even when it is not applicable to the current workspace
- **WHEN** `bot-autonomy.sh verify` runs in the bot profile and
  `~/.pi/agent/trust.json` carries a trusted decision for a workspace path
  that is neither the current workspace nor a parent of it — a decision
  pi's own closest-decision rule would not apply to *this* invocation
- **THEN** `verify` still exits non-zero naming pi — the `~/.pi` volume
  persists for the bot container's entire lifetime, and a decision
  inapplicable to today's workspace is still live on disk and becomes
  applicable the instant pi is later invoked against a matching path,
  with no guarantee a fresh `verify` runs first to catch it; scoping the
  check to path-applicability-at-verify-time would only guarantee "no
  elevated trust for today's workspace," not the "no elevated trust"
  guarantee the maintainer's decision actually states

#### Scenario: the dev profile is identical to the bot profile for this module
- **WHEN** a bot or dev profile container is created or rebuilt
- **THEN** neither `~/.pi/agent/trust.json` nor `~/.pi/agent/settings.json`'s
  `defaultProjectTrust` is touched by this module in either profile — pi's
  own out-of-the-box behavior everywhere; the maintainer's decision applies
  uniformly, with no per-profile distinction for this module to make

#### Scenario: this module has nothing to back up or restore
- **WHEN** an operator looks for a `pi` module `restore` step
- **THEN** there is none — a module that writes nothing has nothing to
  capture before a first overwrite and nothing to put back; this differs
  from the reversibility pattern every other persisted-volume module in
  this capability follows only because this module's apply is currently a
  no-op by design, not because the reversibility requirement was waived

### Requirement: oh-my-pi's non-interactive boundary is confirmed before it is enforced
Oh-my-pi SHALL NOT be Copier-gated. The primary path is: the bot profile
SHALL set `tools.approvalMode` to `"yolo"` in `~/.omp/agent/config.yml`
(oh-my-pi's own schema default, per this proposal's own research against the
pinned `v18.1.2` release — see
`openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md` -
Decisions — but written explicitly rather than left to the default, so a
project-level override, a future upstream default change, or a
stale/legacy config file cannot
silently defeat it). `verify` SHALL read the **fully resolved** effective
value — global configuration layered with any project-level
`<cwd>/.omp/config.yml` the current repository provides, via oh-my-pi's own
config-resolution surface run from the working directory being verified —
rather than the global file alone, for the same reason OpenCode's `verify`
already reads OpenCode's own resolved view instead of its global file alone.
`apply` SHALL capture the prior `tools.approvalMode` value (or its absence)
before its first overwrite, gated on no backup existing yet, matching
OpenCode's backup/restore shape (the only other module in this capability
that persists and reverts a managed value the way this one does — pi's
module writes nothing and has no backup/restore at all); `restore` SHALL
put that prior value back and clear the backup.

Implementation-time confirmation against the actually built shared image
upheld this proposal's own research — the real, installed `v18.1.2` binary
exposes the documented `tools.approvalMode` mechanism exactly as
researched — so the contingency of falling back to an `unsupported` entry
never applied.

#### Scenario: apply seeds yolo mode on a fresh volume (confirmed outcome)
- **WHEN** the `oh-my-pi` module's `apply` runs in the bot profile and
  `~/.omp/agent/config.yml` does not yet exist or has no `tools.approvalMode`
  key
- **THEN** the file has `tools: { approvalMode: yolo }` afterward, and every
  other existing key is preserved

#### Scenario: apply overrides a prior non-yolo approval mode (confirmed outcome)
- **WHEN** `apply` runs and `~/.omp/agent/config.yml` already sets
  `tools.approvalMode` to `"always-ask"` or `"write"` (a human edit, or a
  prior balanced policy)
- **THEN** `tools.approvalMode` reads `"yolo"` afterward — the prior value
  does not win — and every unrelated key in the file is unchanged

#### Scenario: verify fails on a non-yolo effective approval mode (confirmed outcome)
- **WHEN** `verify` reads the fully resolved oh-my-pi approval mode and it
  is not `"yolo"`
- **THEN** `verify` exits non-zero naming oh-my-pi

#### Scenario: a project-level override is not silently missed (confirmed outcome)
- **WHEN** the current repository provides its own `.omp/config.yml` whose
  `tools.approvalMode` is not `"yolo"`, overriding the global default
  `apply` set
- **THEN** `verify` fails, naming the project-level file as the cause

#### Scenario: restore returns the value captured before the first apply (confirmed outcome)
- **WHEN** an operator runs the `oh-my-pi` module's restore step after
  `apply` has run one or more times
- **THEN** `tools.approvalMode` returns to the value (or absence) captured
  before the *first* `apply` in that sequence, the backup file is removed,
  and every key `apply` did not manage is untouched

### Requirement: registry coverage no longer defers copilot-cli, pi, or oh-my-pi
`copilot-cli`, `pi`, and `oh-my-pi` each resolve to their own module — none
of the three is in the `unsupported` set (the archived `bot-autonomy-bootstrap`
change shipped all three there as time-bounded placeholders reasoned
"pending `bot-autonomy-new-harnesses`"; the archived
`bot-autonomy-new-harnesses` change removed every placeholder and replaced
it with a real module).

#### Scenario: the registry-completeness test passes with real coverage
- **WHEN** the bot-autonomy registry-completeness unit test runs
- **THEN** `copilot-cli`, `pi`, and `oh-my-pi` each resolve to their own
  module, never to `unsupported`
