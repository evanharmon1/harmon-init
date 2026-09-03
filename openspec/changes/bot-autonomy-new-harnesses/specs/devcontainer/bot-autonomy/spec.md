## ADDED Requirements

### Requirement: GitHub Copilot CLI's autonomy policy is Copier-gated, following the established Copier-gated-harness contract
The bot profile SHALL gate GitHub Copilot CLI's non-interactive policy behind
a new, default-off Copier answer `use_copilot_cli`, following the
Copier-gated-harness contract `bot-autonomy-bootstrap` establishes for
Antigravity: the `copilot-cli` module SHALL always exist and always cover
the harness; only its effective policy is conditional. The module's `apply`
SHALL read the rendered `containerEnv.HARMON_BOT_AUTONOMY_COPILOT` marker
(`enabled`/`disabled`, sourced from `{{ use_copilot_cli }}` by the bot and
dev `devcontainer.json` jinja twins, exactly as `HARMON_BOT_AUTONOMY_ANTIGRAVITY`
already is for Antigravity) and SHALL NOT derive the Copier answer any other
way. `apply` SHALL NOT itself attempt to set `COPILOT_ALLOW_ALL` — a
container-wide environment variable is fixed by the rendered `containerEnv`
before any lifecycle script runs, not writable at runtime the way a settings
file is — so `apply` SHALL instead treat the variable's presence in its own
process environment as an input to check, not a value to produce.

#### Scenario: the disabled-by-option state is verified, not merely defaulted
- **WHEN** `use_copilot_cli` is off (the default) and `bot-autonomy.sh apply`
  runs the `copilot-cli` module in the bot profile
- **THEN** `COPILOT_ALLOW_ALL` is absent from the container's environment,
  `~/.local/bin/copilot` does not exist, and `verify` asserts exactly that
  absence — a prompt-enabled Copilot CLI is the verified-correct state in
  this configuration, not an uncovered gap

#### Scenario: the autonomous state is verified when the option is on
- **WHEN** `use_copilot_cli` is on and `bot-autonomy.sh apply` runs the
  `copilot-cli` module in the bot profile
- **THEN** `COPILOT_ALLOW_ALL` is present (set to a truthy value) in the
  container's rendered environment, `~/.local/bin/copilot` exists as the
  flag-injecting wrapper, and `verify` asserts both — including confirming
  this repository's own `.dogfood-answers.yml` sets `use_copilot_cli` on, so
  this repository's own bot container runs Copilot CLI autonomously, while a
  freshly generated repo defaults to `disabled-by-option`

#### Scenario: apply fails loudly on a marker/environment inconsistency
- **WHEN** `HARMON_BOT_AUTONOMY_COPILOT` reads `enabled` but
  `COPILOT_ALLOW_ALL` is absent from `apply`'s own process environment (a
  render defect — the jinja twins failed to carry the marker's value into
  the actual environment variable)
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
invocation already carries `--allow-all`, `--yolo`, or one of the three
narrower `--allow-all-*` flags explicitly. It SHALL pass a fixed set of
administrative/informational subcommands through unmodified, without
appending the flag: `login`, `version`/`--version`, `help`/`-h`/`--help`,
`update`, `completion`, `init`, `plugin`/`plugins`, `mcp`, `skill`, and
`app`. The wrapper SHALL resolve and exec the real, shared-image-installed
`copilot` binary without re-invoking itself (for example, by resolving the
next `copilot` on `PATH` after excluding its own directory), rather than
hardcoding one specific installation path.

#### Scenario: the wrapper injects the flag on an agent-task invocation
- **WHEN** the marker reads `enabled` and the wrapper is invoked as a bare
  `copilot`, or as `copilot -p "<prompt>"`, without an explicit
  `--allow-all`-family flag
- **THEN** it execs the real `copilot` binary with `--allow-all` appended

#### Scenario: the wrapper does not duplicate an explicit flag
- **WHEN** the marker reads `enabled` and a caller invokes `copilot` already
  passing `--allow-all`, `--yolo`, or any of `--allow-all-tools`/
  `--allow-all-paths`/`--allow-all-urls`
- **THEN** the wrapper does not append `--allow-all` a second time

#### Scenario: administrative subcommands are not modified
- **WHEN** the marker reads `enabled` and the wrapper is invoked with
  `login`, `version`, `--version`, `help`, `-h`, `--help`, `update`,
  `completion`, `init`, `plugin`, `plugins`, `mcp`, `skill`, or `app`
- **THEN** it execs the real `copilot` binary unchanged, without appending
  `--allow-all`

#### Scenario: a headless invocation off PATH still receives the flag
- **WHEN** the marker reads `enabled` and a programmatic launcher that never
  sources a login shell execs `copilot -p "…"` by resolving it off `PATH`
- **THEN** the resolved `~/.local/bin/copilot` wrapper adds `--allow-all` —
  the wrapper's precedence over the shared image's `copilot` binary is
  established at the container level, reusing the `containerEnv.PATH`
  prepend `bot-autonomy-bootstrap` already adds ahead of the system
  binaries' directory for Antigravity's own wrapper; this module does not
  need a second `PATH` entry

#### Scenario: toggling the option off removes the wrapper entirely
- **WHEN** `use_copilot_cli` was previously on (`~/.local/bin/copilot`
  installed) and a later render/rebuild carries the marker as `disabled`
- **THEN** the `copilot-cli` module's `apply` removes `~/.local/bin/copilot`
  on its next run, and `verify` asserts its absence

### Requirement: pi's non-interactive boundary is project trust, not tool approval
Pi SHALL NOT be Copier-gated — it has no account or paid-tier dependency for
the Hard Rule to apply to. The bot profile SHALL set `defaultProjectTrust` to
`"always"` in `~/.pi/agent/settings.json` unconditionally; the dev profile
SHALL leave it at pi's own `"ask"` default. `apply` SHALL capture the prior
`defaultProjectTrust` value (or its absence) before its first overwrite,
gated on no backup existing yet, matching the pattern
`apply-antigravity-settings.sh` and the OpenCode module already use for a
persisted-volume settings key; `restore` SHALL put that prior value back and
clear the backup.

#### Scenario: apply sets always-trust on a fresh volume
- **WHEN** the `pi` module's `apply` runs in the bot profile and
  `~/.pi/agent/settings.json` does not yet exist or has no
  `defaultProjectTrust` key
- **THEN** the file has `defaultProjectTrust: "always"` afterward, and every
  other existing key is preserved

#### Scenario: non-interactive pi sessions load project resources instead of silently skipping them
- **WHEN** the bot profile runs `pi -p "<prompt>"` (or `--mode json`/
  `--mode rpc`) against a repository whose `.pi/` directory carries
  project-local settings, extensions, skills, prompts, or themes, and no
  saved trust decision applies
- **THEN** those resources are loaded — pi's non-interactive modes never
  show a trust prompt regardless of this setting, so `defaultProjectTrust:
  "always"` is what keeps the bot's headless sessions from silently
  operating against an untrusted, resource-skipping fallback rather than
  what avoids an approval prompt that would not appear either way

#### Scenario: the dev profile keeps pi's own default
- **WHEN** a dev profile container is created or rebuilt
- **THEN** `~/.pi/agent/settings.json`'s `defaultProjectTrust` is unset or
  `"ask"` — pi's own out-of-the-box behavior, not forced by this module

#### Scenario: restore returns the value captured before the first apply
- **WHEN** an operator runs the `pi` module's restore step after `apply`
  has run one or more times
- **THEN** `defaultProjectTrust` returns to the value (or absence) captured
  before the *first* `apply` in that sequence, the backup file is removed,
  and every key `apply` did not manage is untouched

### Requirement: oh-my-pi's non-interactive boundary is confirmed before it is enforced
Oh-my-pi SHALL NOT be Copier-gated. The primary path is: the bot profile
SHALL set `tools.approvalMode` to `"yolo"` in `~/.omp/agent/config.yml`
(oh-my-pi's own schema default, per this proposal's own research against the
pinned `v18.1.2` release — see design.md - Decisions — but written
explicitly rather than left to the default, so a project-level override, a
future upstream default change, or a stale/legacy config file cannot
silently defeat it). `verify` SHALL read the **fully resolved** effective
value — global configuration layered with any project-level
`<cwd>/.omp/config.yml` the current repository provides, via oh-my-pi's own
config-resolution surface run from the working directory being verified —
rather than the global file alone, for the same reason OpenCode's `verify`
already reads OpenCode's own resolved view instead of its global file alone.
`apply` SHALL capture the prior `tools.approvalMode` value (or its absence)
before its first overwrite, gated on no backup existing yet, matching pi's
and OpenCode's shape; `restore` SHALL put that prior value back and clear
the backup.

The contingency: IF implementation-time confirmation against the actually
built shared image contradicts this proposal's own research (oh-my-pi's
real, installed `v18.1.2` binary does not expose the documented mechanism,
or exposes it differently), THEN oh-my-pi's module SHALL instead be an
`unsupported` entry (`executable: "omp"`, reason citing the specific
contradiction found) rather than a real module — and, per
`bot-autonomy-bootstrap`'s own uniform rule, this exemption SHALL NOT
survive `omp` being installed: `verify` SHALL fail closed, naming oh-my-pi,
on any bot container where `omp` is present and still prompt-enabled, the
same as any other installed-but-uncovered harness.

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

#### Scenario: the contingency records an honest, non-surviving exemption
- **WHEN** implementation-time confirmation shows the real installed
  oh-my-pi binary does not honor the documented `tools.approvalMode: yolo`
  mechanism as researched
- **THEN** oh-my-pi is recorded in the `unsupported` table with
  `executable: "omp"` and a reason stating what was actually found, instead
  of a module; the registry-completeness unit test still passes (oh-my-pi
  resolves to exactly one bucket); and `verify` fails naming oh-my-pi the
  moment `omp` is found installed and still prompt-enabled, exactly as it
  would for any other installed harness with no real coverage

### Requirement: registry coverage no longer defers copilot-cli, pi, or oh-my-pi
`bot-autonomy-bootstrap`'s own implementation adds `copilot-cli`, `pi`, and
`oh-my-pi` to the registry-coverage `unsupported` table with a reason of
"pending `bot-autonomy-new-harnesses`" and, for `oh-my-pi`, the reason
`harness-matrix` independently states when reconciling its own registry
addition. This change SHALL remove all three placeholder entries and
resolve each slug to a real module — except `oh-my-pi` under the confirmed
contingency above, which instead updates (not removes) its `unsupported`
entry's reason.

#### Scenario: the registry-completeness test passes with real coverage
- **WHEN** the bot-autonomy registry-completeness unit test runs after this
  change
- **THEN** `copilot-cli` and `pi` each resolve to their own module (never to
  `unsupported`), and `oh-my-pi` resolves to either its own module or an
  `unsupported` entry whose reason is no longer "pending
  `bot-autonomy-new-harnesses`" — the follow-on this reason names has
  landed
