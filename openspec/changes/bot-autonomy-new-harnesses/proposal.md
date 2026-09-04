## Why

Issue #1137's first `[CI]` acceptance criterion ("The bot profile applies a
native no-prompt or allow-all policy to every supported installed agent
harness, including Codex, Claude Code, Antigravity, GitHub Copilot CLI, and
OpenCode") names GitHub Copilot CLI explicitly, but `bot-autonomy-bootstrap`
(proposed in #1148) deliberately excludes it: its own Non-goals state that
Copilot CLI, pi, and oh-my-pi modules are a follow-on change, because none of
the three had a binary in the shared devcontainer image when it was proposed.
`harness-matrix` (also proposed in #1148, implemented in #1149, merged) has
since installed all three (`copilot`, `pi`, `omp`) in the shared image and
provisioned their `~/.copilot`/`~/.pi`/`~/.omp` persistence volumes in both
`devcontainer.json` twins. The follow-on now has real binaries to bind policy
modules to, and #1137's first `[CI]` criterion cannot close until the Copilot
clause does.

## What Changes

- Add `.devcontainer/config/bot-autonomy/copilot-cli.sh` (named after the
  `copilot-cli` registry slug — `bot-autonomy.sh` dispatches
  `${CONFIG_DIR}/<slug>.sh`, never a shortened form), dispatched by
  `bot-autonomy-bootstrap`'s `bot-autonomy.sh` entrypoint: a Copier-gated
  module (new, default-off `use_copilot_cli` answer) following the
  "module always exists, only its policy is conditional" contract
  `bot-autonomy-bootstrap` establishes for Antigravity — `disabled-by-option`
  (`COPILOT_ALLOW_ALL` rendered to the exact literal `"false"`, always
  present in `containerEnv` so it overrides any stale same-named value that
  might otherwise reach the container via `--env-file`; no wrapper) or
  `autonomous` (`COPILOT_ALLOW_ALL` rendered to the exact literal `"true"`
  plus a `~/.local/bin/copilot` wrapper injecting `--allow-all` for agent
  invocations, following the Antigravity launcher invariant — but bot-profile
  only; unlike Antigravity's marker, neither `COPILOT_ALLOW_ALL` nor its
  Copier-gate marker is ever rendered into the dev profile). `verify`
  requires the exact literal `"true"`, not merely a truthy-looking value,
  and separately confirms `~/.copilot/settings.json`'s
  `permissions.disableBypassPermissionsMode` is not `"disable"` (the one
  documented kill-switch that would neuter `COPILOT_ALLOW_ALL`/`--allow-all`
  regardless of this module's own state). harmon-init's own
  `.dogfood-answers.yml` sets the new answer on.
- Add `.devcontainer/config/bot-autonomy/pi.sh`: unconditional (not
  Copier-gated — pi has no account or paid-tier dependency for the Hard Rule
  to apply to). **pi's project-trust posture: no elevated trust, decided by
  the maintainer 2026-09-03 (design.md - Decisions).** This proposal's own
  challenge-review process rejected two successive designs as unsafe
  defaults: a global `defaultProjectTrust: "always"` (extends automatic
  trust — and, per pi's own docs, automatic *extension code execution* — to
  every repository the bot's pi installation is ever pointed at, not only
  this one) and a workspace-scoped `~/.pi/agent/trust.json` entry (pi
  resolves trust by directory path, not content or commit, so a scoped
  decision still survives an untrusted branch checked out into that same
  path and still extends to anything cloned underneath it). Pi's own trust
  primitive has no content-authentication mechanism a bot-autonomy module
  could build a safer version on top of. Presented with these two rejected
  designs plus the option of a stronger content-authentication mechanism,
  the maintainer decided: `apply` writes neither key, in either profile —
  the bot profile's pi behavior matches dev's exactly, accepting that
  headless pi sessions silently skip this repository's own `.pi/`
  customizations (a capability gap) rather than shipping a mechanism this
  review found two ways to make unsafe (a security gap) — because #1137's
  own acceptance criteria require every harness to reach a **no-prompt**
  state, which this option already satisfies for pi (its non-interactive
  modes never prompt for trust regardless of this setting). The
  workspace-scoped design is recorded as a possible future, explicit
  opt-in, not the default. `verify` still fails closed on either of pi's
  two trust-granting surfaces regardless of cause: `defaultProjectTrust`
  found `"always"`, or an applicable saved decision already present in
  `~/.pi/agent/trust.json` for the current workspace or a parent of it.
- Add `.devcontainer/config/bot-autonomy/oh-my-pi.sh`: this proposal's own
  research (design.md - Decisions) found and cites a documented, pinned-release
  auto-approve mechanism (`tools.approvalMode: yolo` in
  `~/.omp/agent/config.yml`) the originating brief did not know about; the
  module is specified against that finding, with backup/restore matching
  OpenCode's shape, and `verify` reading the **fully resolved**
  effective value (global config layered with any project-level
  `.omp/config.yml` override) rather than the global file alone — the same
  reason OpenCode's `verify` already reads OpenCode's own resolved view.
  Implementation still owes a bounded confirmation of that finding against
  the actually-built image before shipping it as fact; the spec states the
  contingency if that confirmation contradicts the documentation
  (`unsupported`, not surviving installation, fail-closed) alongside the
  primary, evidence-based path.
- Retire the `copilot-cli`, `pi`, and `oh-my-pi` entries `bot-autonomy-bootstrap`'s
  own implementation adds to the registry-coverage `unsupported` table
  (reason "pending `bot-autonomy-new-harnesses`") — this change is that
  follow-on, so each slug now resolves to a real module (or, only for
  `oh-my-pi` under the contingency above, an updated `unsupported` entry
  whose exemption does not survive installation, per
  `bot-autonomy-bootstrap`'s own uniform rule).
- Add `use_copilot_cli` to `copier.yml`: default off, `when: "[[ devcontainer ]]"`,
  documenting Copilot's account requirement and free-tier/private-repo terms
  next to the question (AGENTS.md's Hard Rule) — the exact caveat language
  `harness-matrix`'s proposal already pre-drafted for this purpose. Add the
  matching `HARMON_BOT_AUTONOMY_COPILOT` `containerEnv` marker, rendered
  from that answer the same way `HARMON_BOT_AUTONOMY_ANTIGRAVITY` already
  is — but into the **bot** `devcontainer.json` jinja twin only, not dev's:
  unlike Antigravity, nothing in the dev profile ever reads this marker or
  `COPILOT_ALLOW_ALL` itself, and rendering the latter into dev too would
  silently hand a human's own interactive Copilot CLI session in the dev
  profile full allow-all permissions (design.md - Decisions).
- Add unit fixtures for all three modules to whichever test surface
  `bot-autonomy-bootstrap`'s implementation lands (its own tasks name
  `scripts/test-bot-autonomy.sh` as the likely location): absent → apply →
  verify → restore for oh-my-pi; a fixture proving pi's `apply` writes
  nothing and `verify` fails closed on a pre-existing `defaultProjectTrust:
  "always"`; disabled/enabled and a toggle fixture for Copilot; an
  installed-but-still-`unsupported` fixture for the oh-my-pi contingency,
  matching the existing pattern `bot-autonomy-bootstrap`'s own tasks 1.4/4.5
  already establish for `copilot`/`qwen`/`goose`/`clite`.
- Extend the existing `devcontainer-assert-bot` CI job's container
  assertions with the new modules — no new CI step, since that job already
  invokes `bot-autonomy.sh verify` inside the running container per
  `bot-autonomy-bootstrap`, and `verify` now covers three more harnesses by
  construction. That coverage becomes real only once the sync-pin PR
  (#1152) also lands — the job builds the checked-in pin exactly as
  committed, and this change's own implementation PR merges before that
  pin is bumped (design.md - Migration Plan); this change's own
  verification is unit fixtures (tasks.md group 1-3), not this CI job.
- Extend `docs/guides/devcontainers.md`, `docs/architecture/security.md`,
  and `copier.yml`'s help text with each new harness's boundary, alongside
  whatever bot-autonomy-bootstrap's own implementation leaves in place
  there. Both root and `template/` twins.
- State the sequencing explicitly: this change's implementation PR must
  *merge* after `bot-autonomy-bootstrap`'s (PR #1150) — these modules
  dispatch through `bot-autonomy.sh`, which does not exist on `main` until
  then. Development itself need not wait: it may proceed as a branch
  stacked on PR #1150 (or otherwise informed by its design) in parallel,
  rebasing onto `main` and reconciling against whatever `bot-autonomy-bootstrap`
  actually ships once it lands, before this change's own PR is finalized.
  It must also itself merge before the rolling `sync-pin` PR that bumps
  `.devcontainer/Dockerfile` (root + `template`) to the image
  `harness-matrix`/#1149 published. Landing it completes the Copilot clause
  of #1137's first `[CI]` acceptance criterion and satisfies the
  "modules-before-pin" checklist item `bot-autonomy-bootstrap`'s task 4.6
  adds to the sync-pin PR's body.

## Non-goals

- Does not implement `bot-autonomy-bootstrap`'s own four modules
  (`claude-code`, `codex-cli`, `antigravity`, `opencode`), its bootstrap
  entrypoint, or its fail-closed post-create/post-start/CI wiring — this
  change's modules dispatch through that infrastructure and cannot be
  implemented before it merges.
- Does not re-litigate the registry-coverage `unsupported` bucket's
  remaining permanent members (`claude-code-action`, `qwen-code`, `goose`,
  `cline`) or the six `claude-code-*` provider-alias entries — untouched,
  out of scope.
- Does not add a DeepSeek Harness module — out of #1137's scope per
  `bot-autonomy-bootstrap`'s own Non-goals; unchanged here.
- Does not change `agent-registry.json`'s schema or add new registry rows.
  `copilot-cli` and `pi` were already registered before `harness-matrix`;
  `harness-matrix` already added `oh-my-pi`'s row. This change only changes
  which coverage bucket each slug resolves to.
- Does not promote the CI container-assertion job to a required
  branch-protection status check — `bot-autonomy-bootstrap`'s own stated
  follow-on (its proposal's Non-goals), not reopened here.
- Does not touch `template/` or `images/`, and does not write any code —
  planning artifacts only (`openspec/changes/bot-autonomy-new-harnesses/`).
  The implementation PR edits the root and `template/` layers in lockstep
  per AGENTS.md's dogfood-parity rule.
- Does not gate pi's or oh-my-pi's module behind a Copier option. Neither
  harness has an account or paid-tier dependency the Hard Rule applies to
  (both are broker-style, model-agnostic harnesses per
  `agent-registry.json`'s `family_constraint: {kind: broker}"` on both) —
  unlike Antigravity and Copilot, which are account-backed products with
  their own free-tier limits.
- Does not add a Dockerfile-level (image-install) Copier gate for any of
  the three harnesses, and does not change `harness-matrix`'s decision to
  install all three unconditionally — even under the oh-my-pi contingency
  above, changing what the shared image installs is `harness-matrix`'s
  capability, not this one's, and is a human decision (see design.md -
  Risks) rather than something this proposal resolves unilaterally.
- Does not resolve oh-my-pi's mechanism by guessing, but does not leave it
  fully open either: this proposal cites a specific, pinned-release-verified
  finding (design.md - Decisions) as the primary path, with an explicit,
  spec'd fallback if implementation-time confirmation against the real
  binary contradicts it — see the "confirmed before enforced" requirement
  in the spec delta.

## Capabilities

### Modified Capabilities

- `devcontainer/bot-autonomy`: extends the bot-only, fail-closed,
  registry-keyed non-interactive policy contract with per-harness
  boundaries for `copilot-cli`, `pi`, and `oh-my-pi`, plus the
  registry-coverage-table updates that retire their placeholder
  `unsupported` entries. This capability is defined by the sibling
  `bot-autonomy-bootstrap` change, which has not been archived at the time
  this proposal is written (this repository has no `openspec/specs/` tree
  yet at all — see design.md - Context for how this delta relates to that
  not-yet-archived capability, and why it is written as a delta against an
  existing capability rather than a second `## Purpose`-carrying "new"
  capability of the same name).

## Impact

- New: `.devcontainer/config/bot-autonomy/{copilot-cli,pi,oh-my-pi}.sh` —
  named after the registry slug each module covers, matching how
  `bot-autonomy.sh` dispatches (`${CONFIG_DIR}/<slug>.sh`) — or, for
  `oh-my-pi` only, an updated `unsupported.json` entry instead of a module
  (see the oh-my-pi contingency above); unit fixtures extending
  `bot-autonomy-bootstrap`'s test surface for all three harnesses.
- Changed: `.devcontainer/config/bot-autonomy/unsupported.json` (and its
  `template/` twin) — the standalone file `bot-autonomy.sh` reads for its
  unsupported-bucket table, not something defined inside the script itself
  — `bot-autonomy-bootstrap`'s implementation populates it with
  `copilot-cli`/`pi`/`oh-my-pi` placeholder entries; this change removes
  them; `copier.yml` (new `use_copilot_cli` question);
  `.dogfood-answers.yml` (records the new answer on); `.devcontainer/devcontainer.json`
  only, not its dev twin (new `HARMON_BOT_AUTONOMY_COPILOT`/`COPILOT_ALLOW_ALL`
  `containerEnv` entries — bot-only, see design.md - Decisions).
  `.github/workflows/devcontainer-build.yml`'s existing
  container-assertion step gains coverage for free — it already invokes
  `bot-autonomy.sh verify` per `bot-autonomy-bootstrap`, which now checks
  three more harnesses with no new CI step — but not until the sync-pin PR
  (#1152) also lands and the job's built image actually contains the three
  binaries (tasks.md task 5.5).
- Docs: `docs/guides/devcontainers.md`, `docs/architecture/security.md`,
  `copier.yml` help text.
- Template twins: most files above have a `template/` twin per AGENTS.md's
  dogfood-parity table, and the implementation PR changes both layers in
  the same commit set — but not all: `copier.yml` and `.dogfood-answers.yml`
  are root-only by construction (the former configures Copier itself
  rather than being emitted content; the latter records this repo's own
  answers and has no per-repo equivalent to twin against), matching
  AGENTS.md's own qualifier ("most root files have a template/ counterpart"),
  not a universal claim.
- Read-only: `agent-registry.json` (both `copilot-cli`/`pi`, pre-existing,
  and `oh-my-pi`, added by `harness-matrix`, are consulted but not modified).
- Cross-change: depends on `bot-autonomy-bootstrap`'s implementation (PR
  #1150) merging first. Must itself merge before the rolling `sync-pin` PR
  that bumps `.devcontainer/Dockerfile` (root + `template`) to the image
  digest `harness-matrix`/#1149 published — see design.md - Migration Plan
  for what actually backs that ordering: a named, human-reviewer-facing
  checklist item and a non-required CI signal (neither is a branch-protection
  merge block), plus a true, code-level fail-closed backstop that holds
  regardless of whether either is noticed.
