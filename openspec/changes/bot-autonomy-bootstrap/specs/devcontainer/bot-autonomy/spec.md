## Purpose

Defines the bot-only, fail-closed contract that keeps every agent harness
installed in the bot devcontainer image running non-interactively, keyed by
the agent registry, so a declared no-prompt policy can never silently diverge
from the effective runtime policy the way Codex's did in issue #1137.

## ADDED Requirements

### Requirement: Bootstrap entrypoint and module dispatch
The bot devcontainer SHALL provide a single entrypoint,
`.devcontainer/scripts/bot-autonomy.sh apply|verify`, that dispatches to
per-harness policy modules under `.devcontainer/config/bot-autonomy/<slug>.sh`
keyed by `agent-registry.json` harness slugs. Each module SHALL declare the
executable it governs, an idempotent `apply`, and a `verify` that reads the
harness's effective runtime configuration. A slug aliased to another slug's
module (see the registry-coverage requirement below) is governed by that
module and dispatches no separate one.

#### Scenario: apply dispatches every installed harness to its module
- **WHEN** `bot-autonomy.sh apply` runs in the bot devcontainer
- **THEN** it invokes the `apply` step of the module for every registry
  harness slug whose executable is present in the image — resolving an
  aliased slug to its target module — and none other

#### Scenario: verify reads effective runtime state, not the source file
- **WHEN** `bot-autonomy.sh verify` runs after `apply`
- **THEN** each module's `verify` step re-reads the harness's live effective
  configuration (the same value a running instance of that harness would
  honor) rather than re-checking the file `apply` wrote for existence alone

#### Scenario: a registry harness without an installed executable is skipped
- **WHEN** `bot-autonomy.sh apply` or `verify` runs and a registry harness
  slug's executable is not present in the image
- **THEN** that harness's module (or, for an aliased slug, its target
  module) is skipped without failing the run

### Requirement: Every registry harness slug resolves to one of three coverage buckets
Every `agent-registry.json` harness slug SHALL be covered by exactly one of:
a bot-autonomy module; an alias naming another slug's module, used only
where both slugs launch the same underlying executable under a different
provider configuration; or an entry in an explicit `unsupported` set
carrying a reason. A unit test SHALL enumerate the full registry and fail if
any slug falls into none of the three buckets, or into more than one.

#### Scenario: registry completeness is unit-tested across all three buckets
- **WHEN** the bot-autonomy unit test runs
- **THEN** it fails if any `agent-registry.json` harness slug has no
  module, no alias to a moduled slug, and no `unsupported` entry with a
  reason, and fails if any slug is covered by more than one bucket

#### Scenario: provider-rewired Claude Code variants alias to the claude-code module
- **WHEN** the bot-autonomy module directory and its alias table are
  inspected
- **THEN** `claude-code-deepseek`, `claude-code-glm`, `claude-code-kimi`,
  `claude-code-minimax`, `claude-code-qwen`, and `claude-code-qwen-local`
  each alias to the `claude-code` module rather than carrying their own —
  all six launch the same `claude` executable, provider-rewired by wrapper
  functions and environment variables (`claude-providers.sh`), and so share
  its `/etc/claude-code/managed-settings.json` boundary

#### Scenario: harnesses absent from the bot image are unsupported with a reason
- **WHEN** the bot-autonomy unsupported set is inspected
- **THEN** `qwen-code`, `goose`, and `cline` each carry a reason stating
  they are not installed in the shared devcontainer image, and
  `claude-code-action` carries a reason stating it runs as a GitHub Actions
  workflow and is never installed or launched inside a devcontainer

#### Scenario: harnesses pending a later change are unsupported with a reason, not silently absent
- **WHEN** the bot-autonomy unsupported set is inspected
- **THEN** `copilot-cli` and `pi` each carry a reason stating they are
  registered but not yet installed in the bot image — `harness-matrix`
  installs the binaries and `bot-autonomy-new-harnesses` adds their
  modules — and this entry holds regardless of which change merges first,
  so an installed-but-unmoduled Copilot CLI or pi binary never fails
  `verify` before its module exists

#### Scenario: an installed executable with no covering entry fails verify
- **WHEN** `bot-autonomy.sh verify` runs and finds an executable on `PATH`
  that corresponds to a registry harness slug with no module, no alias, and
  no `unsupported` entry
- **THEN** `verify` exits non-zero and names the uncovered harness

### Requirement: Fail-closed enforcement at apply, both verify points, and CI
`apply` SHALL exit non-zero on any module failure so `postCreateCommand`
fails visibly. `verify` SHALL run at the end of post-create and again in
post-start, failing each lifecycle step on divergence.
`.github/workflows/devcontainer-build.yml` SHALL run
`devcontainer-assert.sh container` against the built bot image and fail the
workflow if any supported installed harness is not at its declared bot
policy.

#### Scenario: apply failure aborts postCreateCommand visibly
- **WHEN** any bot-autonomy module's `apply` step fails
- **THEN** `bot-autonomy.sh apply` exits non-zero and `postCreateCommand`
  fails, rather than continuing past the failure

#### Scenario: post-create verify gates container creation
- **WHEN** post-create finishes applying every module
- **THEN** `bot-autonomy.sh verify` runs before post-create completes, and a
  divergence fails post-create

#### Scenario: post-start verify catches drift on every start
- **WHEN** the bot container starts (including a restart of an
  already-created container)
- **THEN** `bot-autonomy.sh verify` runs again in post-start, and a
  divergence fails post-start

#### Scenario: CI asserts the built bot image, not just its source files
- **WHEN** `.github/workflows/devcontainer-build.yml` builds the bot profile
  image
- **THEN** it runs `devcontainer-assert.sh container` against the running
  built image and fails the workflow if any supported installed harness is
  prompt-enabled or sandboxed below its declared bot policy

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

### Requirement: Antigravity non-interactive boundary covers headless and programmatic launches
The bot profile SHALL set `toolPermission: always-proceed` (and the existing
managed keys) in `~/.gemini/antigravity-cli/settings.json`, AND the bot
post-create SHALL install an executable wrapper at `~/.local/bin/agy` that
adds `--dangerously-skip-permissions` to every launch that does not already
carry it. `verify` SHALL fail if either boundary is missing.

#### Scenario: apply sets always-proceed in Antigravity settings
- **WHEN** the `antigravity` module's `apply` runs in the bot profile
- **THEN** `~/.gemini/antigravity-cli/settings.json` has `toolPermission` set
  to `"always-proceed"`

#### Scenario: bot post-create installs the executable wrapper
- **WHEN** the bot profile's post-create completes
- **THEN** `~/.local/bin/agy` exists, is executable, and is ordered ahead of
  the system `agy` binary on `PATH`

#### Scenario: a headless invocation off PATH still receives the flag
- **WHEN** a programmatic launcher that never sources a login shell execs
  `agy -p …` by resolving it off `PATH` (not via the interactive shell
  function)
- **THEN** the resolved `~/.local/bin/agy` wrapper adds
  `--dangerously-skip-permissions` to the invocation

#### Scenario: the wrapper does not duplicate an explicit flag
- **WHEN** a caller invokes `agy` already passing
  `--dangerously-skip-permissions`
- **THEN** the wrapper does not add the flag a second time

#### Scenario: verify fails if the wrapper is missing or inert
- **WHEN** `verify` runs in the bot profile and `~/.local/bin/agy` is
  missing, not executable, or does not inject the flag
- **THEN** `verify` exits non-zero naming Antigravity

### Requirement: OpenCode non-interactive boundary forces the managed permission key
The bot profile SHALL force `permission.*` to `"allow"` in
`~/.config/opencode/opencode.json` on every `apply`, overriding any existing
value for that key, while preserving every other key already present in the
file. `verify` SHALL fail if the effective permission policy is not
allow-all.

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
- **WHEN** `verify` reads the effective OpenCode permission policy and it is
  not allow-all
- **THEN** `verify` exits non-zero naming OpenCode

### Requirement: OpenCode and Antigravity policy changes are individually reversible
Because `~/.config/opencode` and `~/.gemini` are named volumes that persist
across a container rebuild (and across a Coder workspace, via its own
persistence layer), `apply` SHALL record each managed key's prior value (or
its absence) before overriding it, in a form a `restore` operation can use
to put the prior value back — matching the pattern
`apply-antigravity-settings.sh` already implements for Antigravity.
Reverting the implementation PR alone does not undo a value already written
to a persisted volume; `restore` is what does.

#### Scenario: OpenCode apply records the prior permission value
- **WHEN** the `opencode` module's `apply` runs and
  `~/.config/opencode/opencode.json` already has a `permission` key
- **THEN** the prior value is captured in a form a restore step can read
  back, before `apply` overrides it

#### Scenario: OpenCode restore returns the prior permission value
- **WHEN** an operator runs the `opencode` module's restore step after
  `apply` has run at least once
- **THEN** `permission.*` returns to the value captured before the first
  `apply`, and every key `apply` did not manage is untouched

#### Scenario: Antigravity's existing restore mechanism is reused, not reinvented
- **WHEN** the bot-autonomy `antigravity` module's restore path is invoked
- **THEN** it delegates to `apply-antigravity-settings.sh restore`, the
  existing mechanism that already backs up and restores the keys it
  manages, rather than a new parallel implementation

### Requirement: Human dev profile is unaffected by construction
The bot-autonomy wrappers and modules SHALL be installed by the bot
post-create only. The dev post-create SHALL NOT invoke `bot-autonomy.sh
apply`, `verify`, or install the `agy` wrapper, so the human profile's
existing prompt-enabled and balanced permission policies are unchanged by
this capability's existence rather than by a separate runtime check.

#### Scenario: dev post-create never calls the bootstrap
- **WHEN** `.devcontainer/dev/post-create.sh` runs
- **THEN** it does not invoke `bot-autonomy.sh apply` or `verify`, and does
  not install `~/.local/bin/agy`

#### Scenario: dev profile policies remain prompt-enabled or balanced
- **WHEN** a dev profile container is created or rebuilt
- **THEN** Claude Code's managed `defaultMode` is unset (normal
  prompt-on-action), Codex's managed config reads `workspace-write`/
  `on-request`, and Antigravity's settings reflect the balanced
  `antigravity-settings-dev.json` policy — none of them the bot's values

### Requirement: End-to-end effective autonomy
A freshly rebuilt, generated bot devcontainer SHALL run a representative
filesystem operation and a representative GitHub operation through each
authenticated, in-scope harness with zero approval prompts.

#### Scenario: representative operations complete without a prompt (manual verification)
- **WHEN** an operator rebuilds a freshly generated bot devcontainer and, for
  each of Claude Code, Codex, Antigravity, and OpenCode, authenticates the
  harness and runs one representative filesystem write and one
  representative GitHub API read/write
- **THEN** every operation completes without an approval prompt from any of
  the four harnesses
