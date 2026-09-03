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

- Add `.devcontainer/config/bot-autonomy/copilot.sh`, dispatched by
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
  to apply to). `apply` records a **workspace-scoped** trusted decision in
  `~/.pi/agent/trust.json` for the current repository only — never touching
  the global `defaultProjectTrust` fallback, which would extend automatic
  trust (and, per pi's own docs, automatic *extension code execution*) to
  every repository the bot's pi installation is ever pointed at, not only
  this one (design.md - Decisions; this repository's own Foreman
  configuration already classifies dispatched work `untrusted-input` on this
  public repo). Dev leaves both `trust.json` and `defaultProjectTrust`
  untouched — pi's own defaults in both. The scoped write uses the same
  capture-before-first-overwrite backup/restore shape `apply-antigravity-settings.sh`
  and the OpenCode
  module already use for a persisted-volume settings key.
- Add `.devcontainer/config/bot-autonomy/oh-my-pi.sh`: this proposal's own
  research (design.md - Decisions) found and cites a documented, pinned-release
  auto-approve mechanism (`tools.approvalMode: yolo` in
  `~/.omp/agent/config.yml`) the originating brief did not know about; the
  module is specified against that finding, with backup/restore matching
  OpenCode's and pi's shape, and `verify` reading the **fully resolved**
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
  verify → restore for pi and oh-my-pi; disabled/enabled and a toggle
  fixture for Copilot; an installed-but-still-`unsupported` fixture for the
  oh-my-pi contingency, matching the existing pattern
  `bot-autonomy-bootstrap`'s own tasks 1.4/4.5 already establish for
  `copilot`/`qwen`/`goose`/`clite`.
- Extend the existing `devcontainer-assert-bot` CI job's container
  assertions with the new modules — no new CI step, since that job already
  invokes `bot-autonomy.sh verify` inside the running container per
  `bot-autonomy-bootstrap`, and `verify` now covers three more harnesses by
  construction.
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

- New: `.devcontainer/config/bot-autonomy/{copilot,pi,oh-my-pi}.sh` (or, for
  `oh-my-pi` only, an updated `unsupported` table entry instead of a module —
  see the oh-my-pi contingency above); unit fixtures extending
  `bot-autonomy-bootstrap`'s test surface for all three harnesses.
- Changed: the `unsupported` table `bot-autonomy-bootstrap`'s implementation
  defines inside `bot-autonomy.sh` (removes the `copilot-cli`/`pi`/`oh-my-pi`
  placeholder entries); `copier.yml` (new `use_copilot_cli` question);
  `.dogfood-answers.yml` (records the new answer on); `.devcontainer/devcontainer.json`
  only, not its dev twin (new `HARMON_BOT_AUTONOMY_COPILOT`/`COPILOT_ALLOW_ALL`
  `containerEnv` entries — bot-only, see design.md - Decisions).
  `.github/workflows/devcontainer-build.yml`'s existing
  container-assertion step gains coverage for free — it already invokes
  `bot-autonomy.sh verify` per `bot-autonomy-bootstrap`, which now checks
  three more harnesses with no new CI step.
- Docs: `docs/guides/devcontainers.md`, `docs/architecture/security.md`,
  `copier.yml` help text.
- Template twins: every file above outside `openspec/` has a `template/`
  twin per AGENTS.md's dogfood-parity table; the implementation PR changes
  both layers in the same commit set.
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
