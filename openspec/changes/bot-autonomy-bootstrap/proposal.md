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
- Replace Antigravity's shell-function wrapper with a real executable at
  `~/.local/bin/agy`, so headless and programmatic launches (`agy -p …`,
  or any exec off PATH) get `--dangerously-skip-permissions` without
  depending on a login shell. `~/.local/bin/agy` is exactly one of three
  states, never a dangling link: the flag-injecting wrapper (bot profile,
  option enabled); a plain symlink to `~/.local/bin/agy-real` (either
  profile, whenever `ensure-antigravity-cli.sh`'s compatibility copy
  exists); or absent. `use_antigravity_cli` is an existing, default-off
  Copier answer (interactive-auth caveat and free-tier/private-repo terms
  already documented next to it); the `antigravity` module follows the
  same module-always-exists/policy-conditional pattern the Copilot module
  (below) also follows — `disabled-by-option` (the default: settings
  restored via `apply-antigravity-settings.sh restore`, `agy` absent) or
  `autonomous` (this repository's own `.dogfood-answers.yml` sets the
  option on). Because `ensure-antigravity-cli.sh` and every bot-autonomy
  module are **verbatim** template twins — identical bytes in every
  generated repo, regardless of that repo's Copier answers — neither can
  read `use_antigravity_cli` directly; both read a rendered
  `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` marker instead, set by
  the **jinja** `devcontainer.json` twins (bot and dev) from that answer
  (see Impact).
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
- Does not promote the CI container assertion to a required branch-protection
  status check — that is a separate follow-on change. Promoting it needs an
  always-emitted aggregator (so a required check never sits permanently
  pending on a PR the assertion job's paths filter excludes), both ruleset
  layers (this repository's live ruleset and the
  `Branch Protection Ruleset - Protect Main.json` template artifact), a
  trusted validation path for fork PRs (this job needs credentials/build
  access a fork PR's workflow run does not have), a `merge_group` trigger
  with a credential-free container-validation path (so merge-queue runs are
  covered without handing queue-time credentials to arbitrary PR code), and
  the mirrored `docs/architecture/branch-protection.md` updates. #1137's
  actual fail-closed gate does not depend on branch protection at all: it
  is satisfied by `apply`/`verify` failing post-create and post-start
  directly (a bad configuration fails container creation, not merely a CI
  check), with this same-repository CI job adding a second, PR-visible
  signal on top.

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
- New: `.devcontainer/scripts/post-create-conductor.sh` (the Agent-Deck
  conductor-setup block extracted out of `post-create-common.sh`, so bot
  post-create can run it after `apply` rather than before — a verbatim
  twin, matching the script it came from; the implementation PR may
  instead keep it inline behind a skip flag, per design.md - Decisions).
- Changed: `.devcontainer/scripts/post-create-common.sh` (conductor-setup
  block removed, everything else unchanged), `.devcontainer/post-create.sh`
  (call `bot-autonomy.sh apply` after the shared setup completes, and the
  extracted conductor step only after `apply` succeeds),
  `.devcontainer/post-start.sh` (call `bot-autonomy.sh verify`, ordered
  ahead of the shared `post-start-common.sh` call — unlike post-create,
  `verify` needs no setup that script provides first), `devcontainer.json`
  and `dev/devcontainer.json` (add the `HARMON_BOT_AUTONOMY_ANTIGRAVITY`
  `containerEnv` marker), `ensure-antigravity-cli.sh` (retarget to
  `agy-real`, gate on the marker),
  `.github/workflows/devcontainer-build.yml` (add the container-mode assert
  step).
- Read-only: `agent-registry.json` (schema v3, consulted but not modified).
- Docs: `docs/guides/devcontainers.md`, `copier.yml`, `docs/architecture/security.md`.
- Template twins: every `.devcontainer/config/bot-autonomy/*` and
  `.devcontainer/scripts/bot-autonomy.sh` file (including
  `ensure-antigravity-cli.sh`, `post-create-common.sh`, and the new
  `post-create-conductor.sh`) is a **verbatim** template twin;
  `post-create.sh.jinja`/`post-start.sh.jinja` are **structure** twins
  (per AGENTS.md's dogfood-parity table) — the implementation PR changes
  both layers. This distinction is load-bearing, not bookkeeping: a
  verbatim twin ships identical bytes regardless of a generated repo's
  Copier answers, so it structurally cannot contain
  `{{ use_antigravity_cli }}`-style logic. What carries the per-repo
  answer is a **jinja** twin instead — `devcontainer.json` (bot) and
  `dev/devcontainer.json`, both already `[% if devcontainer %]`
  -conditional — rendering `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY`
  to `enabled`/`disabled` at copy/update time; this repository's own root
  `.devcontainer/devcontainer.json` and `.devcontainer/dev/
  devcontainer.json` (the rendered form, not jinja twins) carry the
  literal value matching `.dogfood-answers.yml`. Every verbatim script
  that needs the answer reads that rendered marker and nothing else.
