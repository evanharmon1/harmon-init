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
harness's effective runtime configuration.

#### Scenario: apply dispatches every installed harness to its module
- **WHEN** `bot-autonomy.sh apply` runs in the bot devcontainer
- **THEN** it invokes the `apply` step of the module for every registry
  harness slug whose executable is present in the image, and none other

#### Scenario: verify reads effective runtime state, not the source file
- **WHEN** `bot-autonomy.sh verify` runs after `apply`
- **THEN** each module's `verify` step re-reads the harness's live effective
  configuration (the same value a running instance of that harness would
  honor) rather than re-checking the file `apply` wrote for existence alone

#### Scenario: a registry harness without an installed executable is skipped
- **WHEN** `bot-autonomy.sh apply` or `verify` runs and a registry harness
  slug's executable is not present in the image
- **THEN** that harness's module is skipped without failing the run

### Requirement: Explicit unsupported-harness declaration
Every `agent-registry.json` harness slug SHALL have either a bot-autonomy
module or an entry in an explicit `unsupported` set carrying a reason. An
executable that is installed in the bot image but matches neither a module
nor an `unsupported` entry SHALL fail `verify`.

#### Scenario: registry completeness is unit-tested
- **WHEN** the bot-autonomy unit test runs
- **THEN** it fails if any `agent-registry.json` harness slug has neither a
  bot-autonomy module nor an `unsupported` entry with a reason

#### Scenario: an installed executable with no module fails verify
- **WHEN** `bot-autonomy.sh verify` runs and finds an executable on `PATH`
  that corresponds to a registry harness slug with no module and no
  `unsupported` entry
- **THEN** `verify` exits non-zero and names the uncovered harness

#### Scenario: Gemini and DeepSeek Harness are recorded unsupported, not silently absent
- **WHEN** the bot-autonomy unit test runs
- **THEN** the `gemini` and `deepseek` harness families' relevant slugs (to
  the extent DeepSeek Harness is registered) appear in the `unsupported` set
  with a reason, rather than being absent from both the module directory and
  the unsupported set

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
effective value differs.

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

### Requirement: OpenCode non-interactive boundary
The bot profile SHALL seed `~/.config/opencode/opencode.json` with
`"permission": {"*": "allow"}`, merging into any existing file rather than
overwriting it, and `verify` SHALL fail if the effective permission policy is
not allow-all.

#### Scenario: apply seeds permission allow-all on a fresh volume
- **WHEN** the `opencode` module's `apply` runs and
  `~/.config/opencode/opencode.json` does not yet exist
- **THEN** the file is created with `"permission": {"*": "allow"}`

#### Scenario: apply merges into an existing config without discarding other settings
- **WHEN** `apply` runs and `~/.config/opencode/opencode.json` already exists
  with unrelated user settings
- **THEN** `"permission": {"*": "allow"}` is present afterward and the
  unrelated settings are preserved

#### Scenario: verify fails on a non-allow-all effective policy
- **WHEN** `verify` reads the effective OpenCode permission policy and it is
  not allow-all
- **THEN** `verify` exits non-zero naming OpenCode

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

### Requirement: Scope excludes harnesses not present in the bot image
Harnesses not installed in the bot devcontainer image SHALL have no
bot-autonomy module. Gemini CLI has none, consistent with its removal from
the image. DeepSeek Harness has none, deferred to a follow-up issue. Copilot
CLI, pi, and oh-my-pi have none in this change; their modules are the
follow-on change `bot-autonomy-new-harnesses`, which depends on
`harness-matrix` landing first.

#### Scenario: gemini has no bot-autonomy module
- **WHEN** the bot-autonomy module directory is inspected
- **THEN** no module exists for the `gemini` harness family, and the
  registry-completeness test's `unsupported` entry (not a module) covers it

#### Scenario: Copilot CLI, pi, and oh-my-pi have no module in this change
- **WHEN** the bot-autonomy module directory is inspected after this change
  ships
- **THEN** no module exists for `copilot-cli`, `pi`, or `oh-my-pi`, and their
  boundaries are recorded only as a follow-on in proposal.md, not as modules
  or `unsupported` entries requiring one

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
