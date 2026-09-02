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

**Each `unsupported` entry names the executable `verify` checks for, or
states there is none.** The "installed executable loses its exemption"
rule (see the next Decision) is not implementable without knowing *which*
executable to check — `agent-registry.json` carries no binary-name field,
and a bare `slug → reason` map, as an earlier draft specified, gives
`verify` nothing to run `command -v` against. Each entry now carries an
`executable` field: a verified binary name (`qwen-code` → `qwen`, `goose`
→ `goose`, `cline` → `clite` — its published `@cline/cli` npm package's
`bin` entry; `copilot-cli` → `copilot`, `pi` → `pi`, both already stated
in `harness-matrix`), or the literal `null` for a slug that has no
standalone binary a devcontainer image could ever install in the first
place. `claude-code-action` is the one `null` case today: it runs as a
GitHub Actions workflow, not a CLI, so there is nothing for an
installation check to observe — its exemption is structural, not a special
reason category the way an earlier draft's "out-of-scope" reason type
tried to be (see the Decision above rejecting reason-typed exemptions).
Verifying the four binary names against each project's published package
metadata before writing them down, rather than guessing, is what makes
this concrete rather than another placeholder the implementation PR would
have had to resolve from scratch.

**A Copier-gated harness's module always exists; its Copier answer
selects the module's policy, not whether the module exists.** An earlier
draft (`harness-matrix`'s Copilot CLI requirement) required that "any
consumer-facing Copilot integration — including the future
`bot-autonomy-new-harnesses` module — SHALL be gated by a Copier option
defaulting off," without stating what that means for the module's
*existence*. Read literally, "gated off by default" could mean the module
itself is absent when the option is off — but `harness-matrix` installs
the Copilot binary in the shared image **unconditionally** (following the
same precedent as Claude Code/Codex/OpenCode/Antigravity), so a generated
repo with the option at its default (off) would have `copilot` installed
and, under that reading, no module for it — which fails this change's own
completeness requirement above ("every registry harness slug resolves to
one of three coverage buckets," and an installed executable with no
module fails `verify`). Putting `copilot-cli` in the `unsupported` bucket
to route around this would be worse: `unsupported` means "not yet
supported, pending a follow-on" (see the earlier Decision), not "supported,
but the operator declined it" — conflating the two would make a
deliberately-declined harness indistinguishable from a genuinely
uncovered one, exactly the ambiguity the three-bucket model exists to
remove. The resolution is that the Copier option gates the module's
**effective policy**, not its existence: the module for a Copier-gated
harness is always present and always covers the harness, but its `apply`
writes one of two policy states depending on the answer —
`disabled-by-option` (the default: no allow-all environment variable, no
wrapper — the harness's own out-of-the-box, prompt-enabled behavior,
left alone rather than forced) or `autonomous` (the option is on: the
allow-all configuration `harness-matrix`'s known-boundaries note already
named, `COPILOT_ALLOW_ALL` plus a wrapper injecting `--allow-all` for
headless launches, the same shape as the Antigravity wrapper). `verify`
asserts whichever state the answer selects — a prompt-enabled Copilot CLI
under the default answer is the *verified-correct* state, not a gap.
Concretely for this repository: `.dogfood-answers.yml` sets the Copilot
option on, so this repository's own bot container runs Copilot
autonomously; a freshly generated repo's default answer leaves it
`disabled-by-option`. This pattern — module always present, Copier answer
selects policy state, `verify` checks the selected state rather than one
fixed expectation — is the contract any future Copier-gated harness module
must follow, not something specific to Copilot; it is recorded here as a
constraint on `bot-autonomy-new-harnesses` even though that change (not
this one) implements the actual module.

**Cross-change sequencing: the `unsupported` bucket satisfies static
completeness now; it never silences the dynamic fail-closed check once a
harness is actually installed — for ANY reason, uniformly.**
`harness-matrix` installs `copilot-cli`'s and `pi`'s binaries before
`bot-autonomy-new-harnesses` gives them modules — an ordinary consequence of
shipping them as separate changes. Two successive passes at this design got
the exemption's scope wrong in opposite directions, and the second mistake
is as informative as the first. Pass one put both slugs in the
`unsupported` set with an exemption that survived installation outright,
reasoning that `verify` failing during the rollout window was worse than a
temporary silent gap — backwards: a `verify` that reports success while a
registered, intended-to-be-supported harness sits installed and still
prompt-enabled is exactly the silent effective-state divergence the
motivating issue (proposal.md - Why) exists to eliminate. Pass two fixed
that, but only for entries
reasoned "pending a follow-on module," leaving entries reasoned "out of
image scope" (`qwen-code`, `goose`, `cline`, `claude-code-action`) exempt
unconditionally — on the theory that those harnesses would never actually
be installed. That is a claim about the future this design has no way to
enforce: nothing stops a later change from adding `qwen-code` to the image
without anyone remembering to update this table, and the entire point of a
fail-closed system is to not depend on someone remembering. The reason
field is documentation only; it does not change what `verify` does. Every
`unsupported` entry, regardless of reason, exempts its slug ONLY while the
executable is absent — the instant any of them is installed, `verify`
treats it exactly like an uncovered slug and fails, unless a real module
now covers it. This makes the sequencing hazard self-detecting for
`copilot-cli`/`pi` today and for any future addition to the `unsupported`
set: if the rolling `sync-pin` PR ever bumps a bot image to a revision with
a still-`unsupported` harness installed, CI goes red immediately, naming
it. "Goes red" is not by itself an enforcement mechanism — a failing,
non-required check does not block a merge — so this design also requires
an **always-on aggregator** in `devcontainer-build.yml` (matching
`build.yml`'s own `verify` job) that depends on the container-mode
assertion and is itself the **required status check** on the default
branch — confirmed today that nothing from `devcontainer-build.yml` is
required, only `verify`/`security` from `build.yml`. The aggregator, not
the assertion job directly, is what must be required: the assertion job
stays path-filtered (building a container on every unrelated PR would be
wasteful), and requiring a path-filtered job directly would wedge every PR
outside that path — see the Risk entry below and
`docs/architecture/branch-protection.md`, which documents that exact
failure mode. With the aggregator in place, "land the pin after the module
exists" is an *enforced* invariant, not a documentation-only convention or
a red check someone could merge past — for every entry in the table, not
a privileged subset of it, and without blocking PRs the devcontainer never
touches. The same
reasoning applies going forward to `oh-my-pi`: `harness-matrix` adds its
registry row with a pending-module reason, so whichever of `harness-matrix`
and this change merges second is responsible for adding that entry — see
harness-matrix's design.md, which states this from the other side.

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
post-create, replacing the shell-function approach — with its `PATH`
precedence set at the container level, not a shell rc file.** A shell
function defined in `shell-aliases.sh` exists only inside a shell that has
sourced it — it is invisible to a programmatic launcher (a Foreman-
dispatched process, a cron job, any direct exec) that resolves `agy` off
`PATH` without going through a login shell. That is the literal gap issue
# 1137 names for Antigravity. An installed executable is necessary but not
sufficient: if its precedence over the system binary at `/usr/local/bin`
depends on a `.bashrc`/`.zshrc` `PATH` export the way `ensure-
antigravity-cli.sh`'s own compatibility-copy ordering historically has,
that ordering is invisible to exactly the same non-interactive population
the wrapper exists to cover — a `docker exec` without a login shell sees
the *unedited* container `PATH`, not a shell's rc-modified one. The bot
`devcontainer.json`'s `containerEnv.PATH` is what Docker applies
universally, to every process the container runs regardless of shell, so
prepending `/home/vscode/.local/bin` there (rather than relying on rc-file
`PATH` exports) is what actually closes the gap for every launch path, not
only interactive ones. Alternative considered: keep the shell function and
add the wrapper alongside it — rejected as redundant once the wrapper
exists on the container-wide `PATH`; the function covered a strict subset
of what the wrapper covers.

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
the same codebase, rather than inventing a second one, is deliberate — and
that includes the one guard that pattern already gets right and an early
draft of the OpenCode requirement did not state explicitly: the backup
capture is gated on **no backup existing yet**
(`apply-antigravity-settings.sh`'s own `[ ! -f "$backup_path" ]` check), so
only the *first* `apply` records the true pre-`apply` value. Without that
guard, a second `apply` would capture the current, already-managed
`"allow"` value as if it were "the prior value," silently replacing the
real original (`"ask"`/`"deny"`) with the value `apply` itself wrote — an
`apply → apply → restore` sequence would then "restore" to `"allow"`,
making genuine restoration impossible. The requirement states this guard
explicitly rather than leaving it implicit, since the OpenCode module is a
new port of the pattern, not a call into the existing script.

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
- [Risk] Making the container-assertion job itself a required status check
  would wedge every PR that does *not* touch `.devcontainer/**` — the job
  is (and must stay) path-filtered, so on an unrelated PR it never runs and
  never reports, and a required check with nothing to emit it "stays
  pending forever and blocks every pull request," per this repository's own
  `docs/architecture/branch-protection.md` → [Mitigation] task 3.3c
  requires an **always-on aggregator** instead — the same shape
  `build.yml`'s own `verify` job already uses (`if: always()`, depending on
  its leaf jobs, reporting via `scripts/verify-ci-results.sh`) — and makes
  *that* the required context. The aggregator itself carries no path
  filter, so it reports on every PR: success without running anything when
  a job-level change-detection step says nothing devcontainer-related
  changed, and the real assertion's result when it did. Every PR that
  *does* touch `.devcontainer/**` still cannot merge past a red assertion
  by choice or oversight — task 3.3d's scenario (a docs-only PR merges on
  an automatic pass) is what proves the fix actually closes the wedge
  risk, not merely asserts it away.
- [Risk] The pending-follow-on `unsupported` entries for
  `copilot-cli`/`pi`/`oh-my-pi` could be forgotten when `harness-matrix` or
  `bot-autonomy-new-harnesses` actually lands, reopening the exact
  "installed but unmoduled" gap they exist to bound → [Mitigation] both
  changes' tasks.md carry an explicit cross-referencing task naming the
  other change and the specific slug to reconcile; the
  registry-completeness unit test fails loudly the moment `oh-my-pi`'s row
  exists with no covering entry, and — since a pending-follow-on exemption
  no longer survives installation, and the required aggregator (task 3.3c)
  depends on the container assertion that would catch it whenever the
  change-detection filter matches — the sync-pin PR that would introduce
  the gap is mechanically blocked from merging, not merely flagged, so a
  forgotten reconciliation is caught at merge time, not after.
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
