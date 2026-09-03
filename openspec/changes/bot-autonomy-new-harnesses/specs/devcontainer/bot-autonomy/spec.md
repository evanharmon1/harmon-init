## ADDED Requirements

### Requirement: GitHub Copilot CLI's autonomy policy is Copier-gated, following the established Copier-gated-harness contract
The bot profile SHALL gate GitHub Copilot CLI's non-interactive policy behind
a new, default-off Copier answer `use_copilot_cli`, following the
Copier-gated-harness contract `bot-autonomy-bootstrap` establishes for
Antigravity: the `copilot-cli` module SHALL always exist and always cover
the harness; only its effective policy is conditional. The module's `apply`
SHALL read the rendered `containerEnv.HARMON_BOT_AUTONOMY_COPILOT` marker
(`enabled`/`disabled`, sourced from `{{ use_copilot_cli }}`) and SHALL NOT
derive the Copier answer any other way. Unlike `HARMON_BOT_AUTONOMY_ANTIGRAVITY`,
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
coverage and SHALL still receive `--allow-all` — appending it alongside an
already-present narrower flag is redundant for the dimension that flag
already covers, but is what actually grants the dimensions it does not;
skipping injection there would leave that invocation restricted for
whichever of tools/paths/URLs its own flags did not name, silently
defeating the full-autonomy guarantee this wrapper exists to provide,
specifically in the sanitized-environment case (an `env -i` launcher with no
`COPILOT_ALLOW_ALL` fallback) the wrapper is meant to cover. It SHALL pass a fixed set of
administrative/informational subcommands through unmodified, without
appending the flag: `login`, `version`/`--version`, `help`/`-h`/`--help`,
`update`, `completion`, `init`, `plugin`/`plugins`, `mcp`, `skill`, and
`app`. The wrapper SHALL resolve and exec the real, shared-image-installed
`copilot` binary without re-invoking itself (for example, by resolving the
next `copilot` on `PATH` after excluding its own directory), rather than
hardcoding one specific installation path.

#### Scenario: the wrapper injects the flag on an agent-task invocation
- **WHEN** the marker reads `enabled` and the wrapper is invoked as a bare
  `copilot`, or as `copilot -p "<prompt>"`, without any `--allow-all`-family
  flag at all
- **THEN** it execs the real `copilot` binary with `--allow-all` appended

#### Scenario: the wrapper does not duplicate already-complete coverage
- **WHEN** the marker reads `enabled` and a caller invokes `copilot` already
  passing `--allow-all`, `--yolo`, or all three of `--allow-all-tools`,
  `--allow-all-paths`, and `--allow-all-urls` together
- **THEN** the wrapper does not append `--allow-all` a second time

#### Scenario: a partial allow-all flag still gets the full flag appended
- **WHEN** the marker reads `enabled` and a caller invokes
  `copilot --allow-all-tools -p "<prompt>"` — one of the three narrower
  flags, but not all three — for example inside a sanitized environment
  (`env -i`) where `COPILOT_ALLOW_ALL` is not present as a fallback
- **THEN** the wrapper still appends `--allow-all`, so the invocation ends
  up with full tools/paths/URLs coverage rather than remaining restricted
  for the two dimensions its own explicit flag did not name

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

### Requirement: pi's non-interactive boundary is no elevated trust — decided by the maintainer
**Status: resolved — maintainer decision 2026-09-03, option (a).** Two
designs for this requirement were adjudicated and rejected during this
proposal's own challenge-review process (design.md - Decisions has the
full record): a global `defaultProjectTrust: "always"` (rejected — grants
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
trust regardless of this setting — see the pi Decision in design.md); the
maintainer accepted that the bot's non-interactive pi sessions will
silently ignore this repository's own `.pi/` project resources (a
capability gap) rather than ship a mechanism this proposal's own review
process found two ways to make unsafe (a security gap). The rejected
workspace-scoped design remains available as a possible **future, explicit
opt-in** — not the default — if the maintainer later decides the risk it
carries is acceptable for a specific, bounded use; see design.md - Open
Questions and Decisions for the full record. `verify` SHALL, however,
fail closed on **either** of pi's two trust-granting surfaces, regardless
of cause — this module writes to neither, but a stale volume, a manual
edit, an interactive `/trust` run inside the bot container, or a future
regression could populate either one: (1) `defaultProjectTrust` set to
`"always"` in `~/.pi/agent/settings.json`, and (2) an applicable saved
decision in `~/.pi/agent/trust.json` — a trusted entry for the current
workspace's own canonical directory, or, per pi's own "closest decision on
the current or parent path" rule, for any parent of it. Checking only the
global fallback would leave the exact path-keyed exposure the rejected
workspace-scoped design carried (design.md - Decisions) reachable by any of
those same causes, just through the other file — detecting both is a
strengthening of this fallback's safety story, not a re-attempt at either
rejected design.

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
  `~/.pi/agent/trust.json` carries an applicable trusted decision for the
  current workspace — its own canonical directory, or, per pi's
  closest-decision-on-current-or-parent-path rule, any parent of it —
  regardless of whether an interactive `/trust` run, a stale volume, or a
  manual edit produced it
- **THEN** `verify` exits non-zero naming pi — a global `defaultProjectTrust`
  check alone would miss exactly the path-keyed exposure the rejected
  workspace-scoped design carried; `verify` closes both surfaces, not only
  the one this module itself never writes to first

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
before its first overwrite, gated on no backup existing yet, matching
OpenCode's backup/restore shape (the only other module in this capability
that persists and reverts a managed value the way this one does — pi's
module writes nothing and has no backup/restore at all); `restore` SHALL
put that prior value back and clear the backup.

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
