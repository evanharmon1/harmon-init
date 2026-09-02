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
  classification. Of its 14 `harnesses[]` entries, only `claude-code`,
  `codex-cli`, `antigravity`, and `opencode` are installed in the bot
  devcontainer image today (see `harness-matrix` for what image change adds
  `copilot-cli` and the not-yet-registered `pi`/`oh-my-pi`).
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
  module or an explicit, reasoned exemption" — the property that would have
  caught the Codex regression before a human did.
- `verify` independently re-derives the effective state `apply` was supposed
  to produce, so a broken or no-op `apply` cannot pass by construction.
- Close the specific headless/programmatic-launch gap the issue names for
  Antigravity, and confirm no equivalent gap exists for the other three
  in-image harnesses.

**Non-Goals:**
- Not designing the Copilot CLI / pi / oh-my-pi modules — `harness-matrix`
  has not put those binaries in the image yet, so there is nothing to bind a
  module to. Their known boundaries are recorded in proposal.md as a
  follow-on only.
- Not redesigning `agent-registry.json` — schema v3 stays as-is; the
  unsupported-harness set is bootstrap-owned data, not a registry field.
- Not deciding whether `enable-claude-bypass.sh` / `enable-codex-bypass.sh` /
  `agy-autonomy.sh`'s function are deleted outright or kept briefly as
  deprecated shims — an implementation-time call with no spec consequence
  either way (see Open Questions).

## Decisions

**One bootstrap script, per-slug modules under
`.devcontainer/config/bot-autonomy/<slug>.sh`, vs. keeping today's four
independent scripts.** Registry-driven completeness — the property this
change exists to add — is only checkable with one dispatch point that can
enumerate "every slug, module-or-unsupported." Four independent scripts
called ad hoc from `post-create.sh` is exactly today's state, and it is what
let the Codex divergence in #1137 ship unnoticed: nothing enumerated the
scripts against the registry to notice OpenCode had no script at all.
Alternative considered: inline each harness's apply/verify logic directly in
`post-create.sh`/`post-start.sh` — rejected, since per-harness unit testing
and the registry-completeness assertion both need a discoverable module
boundary (a directory listing), not a hand-parsed shell script.

**Codex: ship a complete `codex-managed-config.bot.toml`, installed and
verified by checksum, replacing the awk rewrite.** The awk approach mutates
two root-level keys in place and is the exact mechanism that diverged
silently in the field: a pattern miss prints a warning but the script still
exits 0, so nothing downstream notices. A shipped, complete file plus a
checksum comparison in `verify` turns drift into a hard failure instead of a
warning. Alternative considered: keep the awk rewrite and add a stricter
post-condition check (assert the two keys read back correctly) — rejected;
that still leaves a partial, mutated file as the source of truth, and the
"shared baseline file, bot changes two keys" structure is what made the awk
script's failure mode silent in the first place. A whole-file checksum has
no partial-success state to hide behind.

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

**OpenCode: seed the config file via a deep-merge, not an overwrite.**
OpenCode documents no per-invocation bypass flag equivalent to Antigravity's
`--dangerously-skip-permissions`; `"permission": {"*": "allow"}` in
`~/.config/opencode/opencode.json` is the mechanism. Merge (existing keys
win, matching the pattern `claude-user-defaults.json` already uses) rather
than overwrite, so a human inspecting or customizing the bot container's
OpenCode config later does not have every rebuild silently discard their
edits. Whether `OPENCODE_CONFIG_CONTENT` (an env-var-based full-config
override OpenCode also documents) could replace the file-write mechanism
entirely is recorded as an open question rather than decided — the answer
does not change the behavioral contract (effective permission policy is
allow-all), only which mechanism satisfies it.

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
  registry-completeness test fails any installed executable lacking both
  `apply` and `verify`.
- [Risk] Checksum-verifying `codex-managed-config.bot.toml` could look like
  it hard-codes a checksum that then goes stale on every edit to that file →
  [Mitigation] the checksum is computed from the shipped file at
  install/verify time, not hand-maintained, so only a corrupted or
  partially-written install fails — a deliberate content change to the
  shipped file simply changes what "correct" reads as.
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
- [Risk] Resolving the OpenCode open question later could make today's
  file-seed implementation redundant work →
  [Mitigation] the scenario contract (effective permission policy is
  allow-all) is mechanism-agnostic; whichever mechanism wins, the spec does
  not need to change.

## Migration Plan

- A single implementation PR (not this planning change) adds
  `bot-autonomy.sh` and its modules, switches `post-create.sh`/`post-start.sh`
  to call `apply`/`verify`, retires or shims the four existing scripts, and
  wires `devcontainer-build.yml`. It touches both the root `.devcontainer/`
  and its `template/` twin in the same PR per AGENTS.md dogfood parity;
  `task test:dogfood-parity` and `test:dogfood-structure` gate it.
- No data migration: bot devcontainers are ephemeral and routinely rebuilt.
  A container that predates this change simply picks up the bootstrap on its
  next rebuild; `verify` in post-start catches anything that attached to a
  stale container without rebuilding.
- Rollback: revert the implementation PR. Neither `agent-registry.json` nor
  the human `dev/` profile is touched by this change, so rollback carries no
  downstream migration.

## Open Questions

- Can `OPENCODE_CONFIG_CONTENT` replace the `~/.config/opencode/opencode.json`
  file write entirely? Left for the implementation PR to spike; the
  behavioral contract (effective permission policy is allow-all) is
  unaffected either way.
- Delete `enable-claude-bypass.sh` / `enable-codex-bypass.sh` /
  `agy-autonomy.sh`'s function outright, or keep them briefly as deprecated
  shims for one release? Implementation-time judgment call with no spec
  consequence.
