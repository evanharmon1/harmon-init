## Why

The bot devcontainer's declared policy ("every harness runs non-interactively")
and its effective runtime policy have already diverged once in the wild: a
generated bot container reported Codex's managed `sandbox_mode` as
`workspace-write` with approvals required, instead of the intended
`danger-full-access`/`never` (issue #1137, observed 2026-09-01). The current
mechanism is four independent, ad hoc scripts
(`enable-claude-bypass.sh`, `enable-codex-bypass.sh`'s awk rewrite,
`agy-autonomy.sh`'s shell function, and no OpenCode step at all) called from
`post-create.sh` with no shared enumeration and no verification that the
*effective* runtime value matches. Nothing fails when one of them silently
no-ops. Antigravity's shell function is a known, documented gap on top of
that: it only intercepts `agy` inside an interactive login shell, so a
programmatic launcher that execs `agy` directly bypasses the policy entirely.

One bootstrap keyed by `agent-registry.json`, with a mandatory `verify` step
wired into fail-closed CI, replaces "four scripts that happen to be called"
with one dispatch point that can prove every installed harness is covered.

## What Changes

- Add `.devcontainer/scripts/bot-autonomy.sh apply|verify`, a single
  entrypoint keyed by `agent-registry.json` harness slugs, dispatching to
  per-slug policy modules under `.devcontainer/config/bot-autonomy/<slug>.sh`.
- Each module declares its executable, an idempotent `apply` at a durable
  configuration boundary (never a login-shell-only mechanism), and a `verify`
  that reads back the *effective* runtime value — not the source file.
- Add modules for the harnesses present in the bot image today: `claude-code`,
  `codex-cli`, `antigravity`, `opencode`.
- Add a unit test asserting every `agent-registry.json` harness slug (16
  today) resolves to exactly one of three buckets: a bot-autonomy module; an
  alias to another slug's module, for a slug that launches the same
  executable under a different provider configuration (the six
  `claude-code-*` provider-rewired variants alias to `claude-code`); or an
  explicit `unsupported` entry with a reason (`claude-code-action`,
  `qwen-code`, `goose`, `cline` — not installed or not launched in a
  devcontainer; `copilot-cli`, `pi` — registered but not yet installed,
  pending `harness-matrix`). An installed executable in none of the three
  buckets fails `verify`.
- Replace the Codex awk rewrite with a complete, shipped
  `codex-managed-config.bot.toml`, installed and verified by checksum, plus
  a structural parity test asserting it matches the shared
  `codex-managed-config.toml` baseline on every key except `sandbox_mode`
  and `approval_policy` — so an edit to the shared baseline cannot silently
  go stale in the bot copy.
- Replace Antigravity's shell-function wrapper with a real executable
  installed to `~/.local/bin/agy` by the bot post-create only, so headless
  and programmatic launches (`agy -p …`, or any exec off PATH) get
  `--dangerously-skip-permissions` without depending on a login shell.
- Add an OpenCode module: force `"permission": {"*": "allow"}` in
  `~/.config/opencode/opencode.json` on every apply — overriding any prior
  value for that key while preserving every other key — with the prior
  value backed up for restore, matching the pattern
  `apply-antigravity-settings.sh` already uses for Antigravity (no
  OpenCode file is seeded today, and both `~/.config/opencode` and
  `~/.gemini` are named volumes that outlive a container rebuild, so a
  reversible write matters here as much as it already does for Antigravity).
- Fail closed at three points: `apply` exits non-zero so
  `postCreateCommand` fails visibly; `verify` runs at the end of post-create
  AND in post-start; `.github/workflows/devcontainer-build.yml` runs
  `devcontainer-assert.sh container` against the built bot image (that
  workflow builds and pushes today but never asserts against the running
  container).
- Update `docs/guides/devcontainers.md` (dedupe the repeated Codex
  paragraph), `copier.yml`'s `use_antigravity_cli` help text, and
  `docs/architecture/security.md` to describe the bootstrap's boundary
  contract.
- Record, as a stated follow-on (not scenarios here): Copilot CLI / pi /
  oh-my-pi modules land in a later change, `bot-autonomy-new-harnesses`,
  once `harness-matrix` (change 2) has actually put those binaries in the
  image.

## Non-goals

- Does not add bot-autonomy modules for Copilot CLI, pi, or oh-my-pi — those
  harnesses do not exist in the bot image until `harness-matrix` lands; their
  modules are the follow-on change `bot-autonomy-new-harnesses`.
- Does not add a DeepSeek Harness module — deferred to a separate follow-up
  issue per #1137's scope.
- Does not change the human `dev/` profile's permission posture. Wrappers and
  modules are installed by the bot post-create only; the dev post-create is
  unchanged by construction, not by a runtime check.
- Does not change `agent-registry.json`'s schema (stays at v3; no new
  fields). The unsupported-harness list is the bootstrap's own data, not a
  registry field.
- Does not reference or restore the `guard-process-kill` Claude hook, which
  was removed repo-wide in PR #1145.
- Does not edit `template/` or `images/`, and does not write any code — this
  change is planning artifacts only (`openspec/changes/bot-autonomy-bootstrap/`).
  The implementation PR that follows edits both the root and `template/`
  layers in lockstep per AGENTS.md's dogfood-parity rule.

## Capabilities

### New Capabilities

- `devcontainer/bot-autonomy`: the bot-only, fail-closed, registry-keyed
  non-interactive policy contract for every agent harness installed in the
  bot devcontainer image.

### Modified Capabilities

(none — this repository has no existing `openspec/specs/` yet; both OpenSpec
changes in this PR introduce new capabilities.)

## Impact

- New: `.devcontainer/scripts/bot-autonomy.sh`,
  `.devcontainer/config/bot-autonomy/{claude-code,codex-cli,antigravity,opencode}.sh`,
  `.devcontainer/config/codex-managed-config.bot.toml`, a registry-completeness
  unit test covering all three coverage buckets (e.g.
  `scripts/test-bot-autonomy.sh` or folded into
  `scripts/devcontainer-assert.sh`), and a Codex baseline/bot-config
  structural parity test.
- Cross-change: this proposal's `unsupported` set names `copilot-cli` and
  `pi`; `harness-matrix`'s implementation (or this change's, whichever
  merges second) is responsible for reconciling `oh-my-pi` into the same
  set once its registry row exists — see design.md - Decisions.
- Retired/replaced: `.devcontainer/scripts/enable-claude-bypass.sh`,
  `.devcontainer/scripts/enable-codex-bypass.sh`, the `agy()` shell function in
  `.devcontainer/config/agy-autonomy.sh`.
- Changed: `.devcontainer/post-create.sh`, `.devcontainer/post-start.sh`
  (call `bot-autonomy.sh apply` / `verify`),
  `.github/workflows/devcontainer-build.yml` (add the container-mode assert
  step).
- Read-only: `agent-registry.json` (schema v3, consulted but not modified).
- Docs: `docs/guides/devcontainers.md`, `copier.yml`, `docs/architecture/security.md`.
- Template twins: every `.devcontainer/config/bot-autonomy/*` and
  `.devcontainer/scripts/bot-autonomy.sh` file is a **verbatim** template
  twin; `post-create.sh.jinja` is a **structure** twin (per AGENTS.md's
  dogfood-parity table) — the implementation PR changes both layers.
