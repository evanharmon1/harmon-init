## Context

See proposal.md - Why for the motivating incident. Current state, precisely:

- Four uncoordinated mechanisms exist today, called individually from
  `.devcontainer/post-create.sh`: `enable-claude-bypass.sh` (jq-patches
  `/etc/claude-code/managed-settings.json`), `enable-codex-bypass.sh` (an awk
  script that rewrites two root-level keys in `/etc/codex/managed_config.toml`
  and, on an awk pattern miss, prints a `WARNING` to stderr but still exits 0
  — a silent no-op), `agy-autonomy.sh` (a shell function sourced from
  `shell-aliases.sh`, active only inside an interactive login shell), and
  nothing for OpenCode.
- `scripts/devcontainer-assert.sh` already has a `container` mode that reads
  Codex's effective `sandbox_mode`/`approval_policy` from a running
  container, plus bot/dev git-identity and TS_AUTHKEY/GH_TOKEN checks — but it
  is invoked only by `scripts/devcontainer-smoke.sh`, which
  `task test:devcontainer:root`/`:dev` call manually. It is not part of any
  CI workflow: `.github/workflows/devcontainer-build.yml` builds and
  conditionally pushes both profile images but never runs the container to
  assert anything against it.
- `agent-registry.json` is schema v3, shared with Foreman's adapter
  classification, and has a verbatim `template/agent-registry.json` twin
  (byte-identical today; a dogfood-parity twin per AGENTS.md). It lists
  exactly 16 harnesses: `claude-code`, `claude-code-action`,
  `claude-code-deepseek`, `claude-code-glm`, `claude-code-kimi`,
  `claude-code-minimax`, `claude-code-qwen`, `claude-code-qwen-local`,
  `codex-cli`, `copilot-cli`, `qwen-code`, `antigravity`, `opencode`, `pi`,
  `goose`, `cline`. There is no `gemini` harness slug at all — Antigravity is
  the registered Google-family harness, and `gemini` appears only as a
  **model family** its `family_constraint` references, not as a harness of
  its own. Of the 16, only `claude-code`, `codex-cli`, `antigravity`, and
  `opencode` correspond to executables installed in the bot devcontainer
  image today (confirmed against both `.devcontainer/Dockerfile` and
  `images/devcontainer/Dockerfile` — neither installs `qwen-code`, `goose`,
  `cline`, `@github/copilot`, or a `pi` package). `copilot-cli` and `pi` are
  registered but not yet installed; `harness-matrix` is what installs them.
  `claude-code-action` runs as a GitHub Actions workflow and is never
  installed or launched inside any devcontainer. The six `claude-code-*`
  provider-rewired slugs (`-deepseek`, `-glm`, `-kimi`, `-minimax`, `-qwen`,
  `-qwen-local`) all launch the same `claude` executable, reconfigured by
  wrapper functions and environment variables in
  `.devcontainer/config/claude-providers.sh` — they are not separate
  binaries with their own boundary to police.
- `~/.config/opencode` and `~/.gemini` are both bot-profile **named
  volumes** (`.devcontainer/devcontainer.json`'s `mounts`), and Coder
  additionally persists them through its own `~/.persistent` symlink layer
  (`persist-opencode.sh`, the Coder block in `post-create-common.sh`). A
  value `apply` writes into either survives a container rebuild; reverting
  the implementation PR does not touch what is already on disk in a
  persisted volume.
- `apply-antigravity-settings.sh` already solves exactly that problem for
  Antigravity: it captures the pre-existing value of every key it manages
  before overriding it, and a `restore` mode puts those values back. No
  equivalent exists for OpenCode today, because no OpenCode mechanism exists
  today at all.
- `.devcontainer/config/codex-managed-config.toml` (the shared human/bot
  baseline `enable-codex-bypass.sh` mutates in place) carries far more than
  `sandbox_mode`/`approval_policy`: `model`, `model_reasoning_effort`,
  `project_doc_max_bytes`, an entire `[features]`/`[tui]` status-line
  configuration, and the managed Codex hooks
  (`claude-compat.sh`/`block-no-verify.sh`,
  `file-payload.sh`/`protect-files.sh`). A standalone bot file that is only
  checksum-compared against **itself** has no way to notice that the shared
  baseline changed underneath it.
- Constraints below were decided by Evan on 2026-09-01 and are stated here as
  requirements, not reopened: profile selection by file
  (`.devcontainer/devcontainer.json` = bot,
  `.devcontainer/dev/devcontainer.json` = human,
  `containerEnv.FOREMAN_DEVCONTAINER=bot` the runtime marker); one bootstrap
  keyed by registry slugs dispatching to per-slug modules; fail-closed at
  apply, post-create verify, post-start verify, and CI; the specific
  per-harness boundaries in proposal.md; wrappers installed by bot
  post-create only; Gemini and DeepSeek Harness out of scope; no reference to
  the already-removed `guard-process-kill` hook.

## Goals / Non-Goals

**Goals:**
- One dispatch point that can enumerate "every registered harness slug has a
  module, an alias, or an explicit, reasoned exemption" — the property that
  would have caught the Codex regression before a human did, made precise
  enough to actually be checkable against the real 16-entry registry.
- `verify` independently re-derives the effective state `apply` was supposed
  to produce, so a broken or no-op `apply` cannot pass by construction.
- Close the specific headless/programmatic-launch gap the issue names for
  Antigravity, and confirm no equivalent gap exists for the other three
  in-image harnesses.
- Every persisted-volume policy write is individually reversible, not just
  "revert the PR."
- The image-rollout sequencing between this change, `harness-matrix`, and
  `bot-autonomy-new-harnesses` cannot put a fresh bot container into a state
  where `verify` fails through no fault of its own configuration.

**Non-Goals:**
- Not designing the Copilot CLI / pi / oh-my-pi **modules** —
  `harness-matrix` has not put those binaries in the image yet, so there is
  nothing to bind a module to. Their known boundaries are recorded in
  proposal.md as a follow-on only. This change does register them in the
  `unsupported` set (see Decisions), which is coverage bookkeeping, not a
  module.
- Not redesigning `agent-registry.json` — schema v3 stays as-is; the
  unsupported-harness set and the alias table are bootstrap-owned data, not
  registry fields.
- Not deciding whether `enable-claude-bypass.sh` / `enable-codex-bypass.sh` /
  `agy-autonomy.sh`'s function are deleted outright or kept briefly as
  deprecated shims — an implementation-time call with no spec consequence
  either way (see Open Questions).

## Decisions

**One bootstrap script, per-slug modules under
`.devcontainer/config/bot-autonomy/<slug>.sh`, vs. keeping today's four
independent scripts.** Registry-driven completeness — the property this
change exists to add — is only checkable with one dispatch point that can
enumerate "every slug, covered." Four independent scripts called ad hoc from
`post-create.sh` is exactly today's state, and it is what let the Codex
divergence in #1137 ship unnoticed: nothing enumerated the scripts against
the registry to notice OpenCode had no script at all. Alternative
considered: inline each harness's apply/verify logic directly in
`post-create.sh`/`post-start.sh` — rejected, since per-harness unit testing
and the registry-completeness assertion both need a discoverable module
boundary (a directory listing), not a hand-parsed shell script.

**Registry coverage is three buckets — module, alias, unsupported — not
two.** An earlier draft of this proposal only planned modules for the four
in-image harnesses plus "unsupported" entries for `gemini` and "DeepSeek
Harness," neither of which is an actual registry slug (there is no `gemini`
harness; "DeepSeek Harness" is a future, not-yet-registered idea, distinct
from the already-registered `claude-code-deepseek`). Checked against the
real 16-slug registry, that left ten slugs — the six provider-rewired
`claude-code-*` variants, `claude-code-action`, `qwen-code`, `goose`, and
`cline` — with no fate at all, so the completeness unit test as originally
specified could never pass. Two things were missing, not one: an **alias**
bucket for slugs that share another slug's executable (the six
`claude-code-*` variants all launch the same `claude` binary,
provider-rewired — policing `claude-code`'s boundary already covers them,
and giving them their own modules would mean five redundant copies of the
same jq patch against the same file), and a complete, verified enumeration
of the **unsupported** bucket's actual membership (`claude-code-action`: a
GitHub Action, never installed in a devcontainer; `qwen-code`/`goose`/
`cline`: registered but not installed in the shared image at all;
`copilot-cli`/`pi`: registered, not yet installed, pending
`harness-matrix`). Alternative considered: narrow the completeness
requirement to "every **installed** executable," dropping static
registry-wide coverage — rejected, because the brief's own instruction ("a
unit test asserts every registry slug has a module or is in an explicit
unsupported list") asks for exactly the static property, and narrowing it
would let a slug silently fall through the cracks the way OpenCode did
originally, just at the registry layer instead of the image layer.

**Cross-change sequencing: the `unsupported` bucket satisfies static
completeness now; it does not — and must not — silence the dynamic
fail-closed check once the harness is actually installed.** `harness-matrix`
installs `copilot-cli`'s and `pi`'s binaries before
`bot-autonomy-new-harnesses` gives them modules — an ordinary consequence of
shipping them as separate changes. A first pass at this design put both
slugs in the `unsupported` set with an exemption that survived installation,
reasoning that the alternative (verify failing during the rollout window)
was worse than a temporary silent gap. That reasoning was backwards: a
`verify` that reports success while a registered, intended-to-be-supported
harness sits installed and still prompt-enabled is exactly the silent
effective-state divergence issue #1137 exists to eliminate — worse than a
loud CI failure, not better than one. The fix keeps the `unsupported` bucket
(so the *static* registry-completeness test can pass before either binary is
installed) but makes its exemption conditional on the entry's **reason**:
an out-of-scope reason (harness never installed by this image, e.g.
`qwen-code`) exempts unconditionally; a pending-follow-on reason (`copilot-cli`,
`pi`) exempts only while the executable is **absent** — the instant one is
installed, `verify` treats it exactly like any other uncovered slug and
fails. This makes the sequencing hazard self-detecting: if the rolling
`sync-pin` PR ever bumps a bot image to a revision with Copilot CLI or pi
installed before `bot-autonomy-new-harnesses` has shipped their modules, CI
goes red immediately, naming the harness — which is the correct outcome,
and turns "land the pin after the modules exist" into an enforced invariant
rather than a documentation-only convention. The same reasoning applies
going forward to `oh-my-pi`: `harness-matrix` adds its registry row with a
pending-follow-on reason, so whichever of `harness-matrix` and this change
merges second is responsible for adding that entry — see harness-matrix's
design.md, which states this from the other side — and if `oh-my-pi` is
ever installed before `bot-autonomy-new-harnesses` covers it, the same
loud-failure behavior applies.

**Codex: ship a complete `codex-managed-config.bot.toml`, installed and
verified by checksum, replacing the awk rewrite — plus a structural parity
test against the shared baseline.** The awk approach mutates two root-level
keys in place and is the exact mechanism that diverged silently in the
field: a pattern miss prints a warning but the script still exits 0, so
nothing downstream notices. A shipped, complete file plus a checksum
comparison in `verify` turns installation drift into a hard failure instead
of a warning. But a standalone file checksummed only against itself is
blind to a different failure mode: the shared baseline
(`codex-managed-config.toml`) carries model, reasoning-effort, and hook
settings well beyond the two bot-specific keys, and nothing stops the bot
file from silently going stale if the baseline is edited later without a
matching edit to the bot copy — `verify`'s checksum would still pass,
against a fork nobody meant to create. A structural parity test (every key
except `sandbox_mode`/`approval_policy` must match between the two files)
closes that gap at authoring time, independent of the runtime checksum
check. Alternative considered: generate the bot file from the baseline at
apply time (a templating/sed step that copies the baseline and overrides two
keys) — rejected, because that reintroduces exactly the awk rewrite's
fragility (a generation-script bug is the same silent-divergence shape the
whole file-replacement approach exists to avoid); a parity **test** catches
drift without reintroducing a rewrite mechanism.

**Antigravity: an executable wrapper installed to `~/.local/bin/agy` by bot
post-create, replacing the shell-function approach.** A shell function
defined in `shell-aliases.sh` exists only inside a shell that has sourced it
— it is invisible to a programmatic launcher (a Foreman-dispatched process, a
cron job, any direct exec) that resolves `agy` off `PATH` without going
through a login shell. That is the literal gap issue #1137 names for
Antigravity. An installed executable ahead of the system binary on `PATH`
(the same ordering `ensure-antigravity-cli.sh` already establishes for its
compatibility copy) intercepts every launch path uniformly, interactive or
not. Alternative considered: keep the shell function and add the wrapper
alongside it — rejected as redundant once the wrapper exists on `PATH`; the
function covered a strict subset of what the wrapper covers.

**OpenCode: force the managed `permission` key on every apply; preserve
everything else; back up the prior value for restore.** An earlier draft of
this design proposed a plain deep-merge where "existing values win" — copied
from the `claude-user-defaults.json` pattern, where letting a human's own
customization win is the point. That pattern is wrong for a
security-relevant key: if a persisted `opencode.json` already carries
`permission.* = "ask"` or `"deny"` (a prior balanced policy, a human edit, an
unmanaged default), "existing wins" would leave the prompt-enabled value in
place, and `verify`'s own allow-all check would then correctly fail every
rebuild — the merge direction directly contradicted the requirement it was
supposed to satisfy. The fix is the same shape
`apply-antigravity-settings.sh` already uses for Antigravity: a small
managed-keys list (here, just `permission`) that is always force-overwritten,
with the prior value captured before the overwrite so a `restore` step can
put it back, while every other key in the file (`theme`, anything else)
merges normally and is left alone. Reusing an already-reviewed pattern from
the same codebase, rather than inventing a second one, is deliberate.

**OpenCode `verify` inspects the fully resolved configuration, not the
global file alone.** OpenCode layers a workspace-level `opencode.json` (or
`.opencode/opencode.json`) over the global `~/.config/opencode/opencode.json`
— `opencode debug config` shows a project-level `permission.*` overriding a
global `"allow"`. `apply` can only ever set the global default: it has no
business rewriting a generated repository's own tracked files. A `verify`
that only re-reads the global file would therefore report success in
exactly the scenario this change exists to prevent — a repository whose own
`opencode.json` still denies or prompts, with the harness effectively
non-autonomous despite a clean bot-autonomy report. `verify` instead reads
OpenCode's own resolved view (its config-resolution surface, run from the
actual working directory being verified), and fails naming the
workspace-level file when that is the cause — giving whoever hits this a
concrete, actionable answer rather than a report that quietly didn't check
the thing that mattered.

**The Antigravity wrapper's flag injection is scoped to agent/headless
execution, with a fixed passthrough list — not "every launch."** An earlier
draft of the Antigravity requirement said the wrapper adds
`--dangerously-skip-permissions` to every invocation that doesn't already
carry it. That is stricter than the mechanism it replaces:
`agy-autonomy.sh`'s existing shell function already passes a specific list
of subcommands and flags straight through
(`agent`/`agents`/`changelog`/`help`/`-h`/`--help`/`install`/`models`/
`plugin`/`plugins`/`update`/`--version`, and a bare `agy`), because `agy`
either rejects the flag on those or the flag is meaningless there. Losing
that nuance in the port to an executable wrapper would break routine CLI
use — and, concretely, `ensure-antigravity-cli.sh` itself calls
`agy --version` during every post-create, so an unconditional wrapper would
break the very script that installs it. The wrapper keeps the reference
implementation's passthrough list rather than reinventing one.

**The CI container assertion invokes `bot-autonomy.sh verify` itself, rather
than duplicating each boundary's check a second time.**
`scripts/devcontainer-assert.sh`'s existing `container` mode checks only
Codex's `sandbox_mode`/`approval_policy` (plus git identity and
TS_AUTHKEY/GH_TOKEN placement) — it has no knowledge of Claude Code,
Antigravity, or OpenCode at all. Simply adding an invocation of that
existing function to `devcontainer-build.yml`, as an early draft of this
change's tasks proposed, would make CI report success while three of the
four new modules go completely unchecked — the same shape of false
confidence the checksum-only Codex check was designed to avoid, one layer
up. Rather than hand-writing three more boundary checks into
`devcontainer-assert.sh` (duplicating logic `bot-autonomy.sh verify` already
has, and now two places that can drift from each other), the container
assertion runs `docker exec <container> bot-autonomy.sh verify` — the same
verifier post-create and post-start already run, against the same
already-covered set of boundaries, with one implementation to keep correct.

**`verify` re-reads effective runtime state independently of `apply`'s
internals.** This mirrors the incident's actual root cause: the template
said the right thing while the applied file did not match it. Each module's
`verify` reads the same live path (or, for Codex, the checksum of that path)
that a human or CI would inspect, rather than re-deriving its expectation
from `apply`'s own code path — so a bug in `apply` cannot make its own
`verify` agree with it.

## Risks / Trade-offs

- [Risk] A module silently no-ops the way the current awk fallback can →
  [Mitigation] `verify` never trusts `apply`'s exit code alone; it
  independently re-reads the effective value or checksum, and the
  registry-completeness test fails any installed executable lacking
  coverage in all three buckets.
- [Risk] The alias bucket could be used to paper over a harness that
  actually needs its own boundary (declaring a false alias instead of doing
  the work) → [Mitigation] the alias table names a specific shared
  executable claim ("launches the same `claude` binary, provider-rewired");
  a reviewer checking a new alias entry against `claude-providers.sh` (or
  its future equivalent) is the intended check, the same way a code
  reviewer checks any other design claim — this is a documentation
  discipline the design records explicitly rather than a mechanism that
  verifies itself.
- [Risk] Checksum-verifying `codex-managed-config.bot.toml` could look like
  it hard-codes a checksum that then goes stale on every edit to that file →
  [Mitigation] the checksum is computed from the shipped file at
  install/verify time, not hand-maintained, so only a corrupted or
  partially-written install fails — a deliberate content change to the
  shipped file simply changes what "correct" reads as. The structural
  parity test is the separate, complementary guard against the bot file
  going stale relative to the shared baseline it was forked from.
- [Risk] An executable at `~/.local/bin/agy` could be shadowed by a stale
  binary a previous image version left in a persisted volume →
  [Mitigation] bot-autonomy `apply` runs after `ensure-antigravity-cli.sh`
  (which already reconciles a stale user-local copy against the pinned
  shared-image version), and `verify` checks the wrapper's own behavior, not
  merely a path's existence.
- [Risk] Wiring `devcontainer-assert.sh container` into
  `devcontainer-build.yml` adds a real container run to a workflow that
  today only builds and pushes, lengthening that job →
  [Mitigation] this is precisely acceptance criterion 3's [CI] requirement;
  `task test:devcontainer:root` already pays an equivalent cost locally, so
  CI gains coverage it was missing rather than adopting new mechanism.
- [Risk] The pending-follow-on `unsupported` entries for
  `copilot-cli`/`pi`/`oh-my-pi` could be forgotten when `harness-matrix` or
  `bot-autonomy-new-harnesses` actually lands, reopening the exact
  "installed but unmoduled" gap they exist to bound → [Mitigation] both
  changes' tasks.md carry an explicit cross-referencing task naming the
  other change and the specific slug to reconcile; the
  registry-completeness unit test fails loudly the moment `oh-my-pi`'s row
  exists with no covering entry, and — since a pending-follow-on exemption
  no longer survives installation — `verify` itself fails loudly if any of
  the three is ever installed before its module ships, so the risk
  surfaces as a red CI check rather than a silent pass either way.
- [Risk] Resolving the OpenCode `OPENCODE_CONFIG_CONTENT` open question later
  could make today's file-seed implementation redundant work →
  [Mitigation] the scenario contract (effective permission policy is
  allow-all, individually reversible) is mechanism-agnostic; whichever
  mechanism wins, the spec does not need to change.

## Migration Plan

- A single implementation PR (not this planning change) adds
  `bot-autonomy.sh`, its modules, and its alias/unsupported tables, switches
  `post-create.sh`/`post-start.sh` to call `apply`/`verify`, retires or shims
  the four existing scripts, adds the Codex structural parity test, and
  wires `devcontainer-build.yml`. It touches both the root `.devcontainer/`
  and its `template/` twin in the same PR per AGENTS.md dogfood parity;
  `task test:dogfood-parity` and `test:dogfood-structure` gate it.
- No data migration for the image-baked boundaries (Claude Code's
  `/etc/claude-code/managed-settings.json`, Codex's
  `/etc/codex/managed_config.toml`): both live under `/etc`, not a named
  volume, so every image rebuild resets them automatically.
- The two volume-persisted boundaries (Antigravity's
  `~/.gemini/antigravity-cli/settings.json`, OpenCode's
  `~/.config/opencode/opencode.json`) are **not** self-resetting. Rollback
  for either is: run that module's `restore` (Antigravity already has one;
  this change adds OpenCode's), not merely revert-and-rebuild — a reverted
  PR does not touch a value already written into a persisted volume.
- Rollback for the implementation as a whole: revert the PR, then run
  `restore` for Antigravity and OpenCode against any bot container that had
  already run `apply`. `agent-registry.json` and the human `dev/` profile are
  untouched by this change either way.

## Open Questions

- Can `OPENCODE_CONFIG_CONTENT` replace the `~/.config/opencode/opencode.json`
  file write entirely? Left for the implementation PR to spike; the
  behavioral contract (effective permission policy is allow-all,
  individually reversible) is unaffected either way.
- Delete `enable-claude-bypass.sh` / `enable-codex-bypass.sh` /
  `agy-autonomy.sh`'s function outright, or keep them briefly as deprecated
  shims for one release? Implementation-time judgment call with no spec
  consequence.
