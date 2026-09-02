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
- **THEN** `qwen-code` carries `executable: "qwen"`, `goose` carries
  `executable: "goose"`, and `cline` carries `executable: "clite"` (its
  published `@cline/cli` package's binary name), each with a reason
  stating it is not installed in the shared devcontainer image;
  `claude-code-action` carries `executable: null` with a reason stating it
  runs as a GitHub Actions workflow and has no devcontainer-installable
  binary; and `copilot-cli` and `pi` carry `executable: "copilot"` and
  `executable: "pi"` respectively, with a reason stating they are
  registered but not yet installed — `harness-matrix` installs the
  binaries and `bot-autonomy-new-harnesses` adds their modules —
  satisfying the registry-completeness test before any of the five is
  installed

#### Scenario: an installed unsupported harness fails verify until it gets real coverage
- **WHEN** `bot-autonomy.sh verify` runs and finds a named `unsupported`
  executable installed (whether that is `copilot`/`pi` after
  `harness-matrix` lands, or, hypothetically, `qwen`/`goose`/`clite` if a
  future image ever installed one) while its slug still has no module and
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

#### Scenario: the CI assertion covers every module, not only Codex
- **WHEN** `devcontainer-assert.sh container` runs against the bot profile
- **THEN** its coverage is not limited to Codex's `sandbox_mode`/
  `approval_policy` (the only boundary it checks today) — it additionally
  proves Claude Code, Antigravity, and OpenCode's effective policies, by
  invoking `bot-autonomy.sh verify` inside the running container (via
  `docker exec`) rather than by duplicating each boundary's check a second
  time in the assertion script

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
adds `--dangerously-skip-permissions` to every **agent/headless execution**
launch that does not already carry it. `verify` SHALL fail if either
boundary is missing. The wrapper SHALL pass a fixed set of subcommands and
flags through unmodified, without appending the flag: a bare `agy`
(interactive, already covered by the settings-file policy),
`agent`/`agents`, `changelog`, `help`/`-h`/`--help`, `install`, `models`,
`plugin`/`plugins`, `update`, and `--version` — matching the passthrough
list already proven correct in `agy-autonomy.sh`, the shell-function
mechanism this wrapper replaces. Appending the flag to any of these is
either rejected by `agy` or meaningless, and `--version` specifically is
relied on elsewhere (`ensure-antigravity-cli.sh` calls `agy --version` to
compare installed versions) — a literal "every launch" rule would break
routine CLI use and the compatibility installer alike.

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

#### Scenario: passthrough subcommands and flags are not modified
- **WHEN** the wrapper is invoked as a bare `agy`, or with `agent`,
  `agents`, `changelog`, `help`, `-h`, `--help`, `install`, `models`,
  `plugin`, `plugins`, `update`, or `--version`
- **THEN** it execs the underlying `agy` binary unchanged, without
  appending `--dangerously-skip-permissions` — including when
  `ensure-antigravity-cli.sh` calls `agy --version` during post-create,
  which must keep working exactly as it does today

#### Scenario: verify fails if the wrapper is missing or inert
- **WHEN** `verify` runs in the bot profile and `~/.local/bin/agy` is
  missing, not executable, or does not inject the flag
- **THEN** `verify` exits non-zero naming Antigravity

### Requirement: OpenCode non-interactive boundary forces the managed permission key
The bot profile SHALL force `permission.*` to `"allow"` in
`~/.config/opencode/opencode.json` on every `apply`, overriding any existing
value for that key, while preserving every other key already present in the
file. `verify` SHALL fail if the **fully resolved** effective permission
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
