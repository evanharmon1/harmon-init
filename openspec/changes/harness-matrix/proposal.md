## Why

The shared devcontainer image (`images/devcontainer/Dockerfile`, published as
`ghcr.io/evanharmon1/harmon-devcontainer`) is the one place every generated
repo's bot and dev profiles get their agent-harness inventory from — the
`bot-autonomy-bootstrap` change (#1137) can only cover harnesses that are
actually installed and registered. Today's image carries Gemini CLI, which
Antigravity has superseded as the Google-family harness and which is out of
`bot-autonomy-bootstrap`'s scope, and is missing three harnesses Evan wants
available: GitHub Copilot CLI, pi, and oh-my-pi. This change lands the image
side of that gap so a later change can bind bot-autonomy modules to real,
installed binaries.

## What Changes

- Add **GitHub Copilot CLI**: npm `@github/copilot@1.0.82`, binary
  `copilot`, tracked by Renovate's npm datasource; disable auto-update if the
  CLI exposes a switch for it. Installing the binary in the **shared image**
  follows the same precedent Claude Code, Codex, and OpenCode already set
  (and Antigravity's binary install follows too): the binary is present
  unconditionally, but no generated-repo configuration forces its use — a
  human or bot opts in by authenticating and invoking it with their own
  account, exactly as they would `claude`/`codex`/`opencode`. Documented
  next to that precedent, since Copilot is a paid-tier product: GitHub
  Copilot requires a GitHub account and a Copilot plan — a free tier
  exists (limited monthly completions/chat requests; historically also
  free for verified students/teachers via GitHub Education and for
  maintainers of popular open-source projects), with paid tiers (Pro/
  Business/Enterprise) raising those limits. Unlike some competing tools,
  Copilot documents that it operates on both public and private
  repositories for an authorized account, but plan eligibility, quotas,
  and data-handling terms change — review GitHub's current terms before
  relying on it for proprietary code, the same review the
  `use_antigravity_cli` help text already asks for regarding Google's
  terms. Per AGENTS.md's Hard Rule ("never make generated output depend
  on paid or trial-only SaaS by default"), Copilot's **non-interactive/
  allow-all mode for the bot profile** — the future
  `bot-autonomy-new-harnesses` module's actual autonomy configuration, not
  the binary this proposal installs — SHALL be gated by a Copier option
  defaulting off, mirroring `use_antigravity_cli`'s shape (interactive-auth
  caveat, free-tier/private-repo terms documented next to the question,
  bot vs. dev profile posture). The module **itself** is not what the
  option gates: it always exists once `bot-autonomy-new-harnesses` ships,
  because the binary is installed unconditionally (this proposal's own
  scope) and `bot-autonomy-bootstrap`'s own completeness rule fails
  `verify` on any installed, registered harness with no module — what the
  Copier option selects is that module's effective policy
  (`disabled-by-option`, the default, vs. `autonomous`), a resolved
  contradiction recorded in `bot-autonomy-bootstrap`'s design.md and spec
  (its new "Copier-gated harness" requirement) rather than restated here.
  This proposal's own scope (the binary in the shared image) needs no
  gate at all, by the same precedent the other three harnesses already
  establish; the policy gate is a requirement on the follow-on change,
  stated here so it is not overlooked when that change is proposed.
- Add **pi**: npm `@earendil-works/pi-coding-agent@0.84.4` installed with
  `--ignore-scripts` in its own separate `npm install -g` invocation, not
  folded into the combined layer that installs the other npm-based
  harnesses (`--ignore-scripts` applies to every package in whatever
  invocation it is part of, and Copilot CLI's install may depend on a
  lifecycle step — see below); the correct current package name is
  `@earendil-works/pi-coding-agent` (the older `@mariozechner`-scoped
  package is deprecated); binary `pi`; disable auto-update via
  `PI_SKIP_VERSION_CHECK`.
- Add **oh-my-pi**: the npm distribution is bun-only, so install the
  prebuilt `omp-linux-{x64,arm64}` binary from GitHub release `v18.1.2`
  (`can1357/oh-my-pi`), verified against a **per-architecture SHA-256
  digest reviewed and pinned in the Dockerfile** (the TFLint/Antigravity
  pattern — not fetching and trusting that release's own `SHA256SUMS.txt`
  at build time, which would trust a checksum manifest from the same
  mutable source as the binary itself); Renovate `github-releases`
  datasource; binary `omp`; add a new `oh-my-pi`
  harness row to `agent-registry.json`.
- Remove **Gemini CLI** (`@google/gemini-cli`): the Dockerfile `ARG`, its
  `npm install -g` line, its `generate-manifest.sh` manifest entry, its
  `smoke.sh` presence/version probe, and the "(Claude Code, Codex, Gemini,
  OpenCode)" prose in both `devcontainer.json` twins and
  `docs/guides/devcontainers.md`. Keep the `~/.gemini` named volume
  (Antigravity persists its own state there), the `gemini` model family in
  `agent-registry.json`, and the `GEMINI.md` symlink convention.
- Bump **herdr** 0.8.0 → 0.8.2 (adds recognition of the `pi`, `omp`, and
  `copilot` session kinds).
- Every addition gets a `generate-manifest.sh` manifest entry, a `smoke.sh`
  presence + `--version` probe, and confirmation both `amd64` and `arm64`
  build (the publish workflow's candidate job already matrix-builds both
  architectures).
- State the sequencing explicitly, distinguishing what is *correct in
  either order* from what is *mergeable in only one*: this
  change publishes a new image from `main`; the rolling `sync-pin` PR
  bumps both `Dockerfile` twins (root + `template/`) to the new digest;
  the follow-on `bot-autonomy-new-harnesses` change does **not need to
  wait** for that pin to be *implemented* — its modules for
  `copilot-cli`/`pi` are safe to write and merge before either binary is
  installed, because `bot-autonomy.sh` already skips a module whose
  executable is absent (the same behavior every other module has from day
  one). That removes the circular *implementation* dependency an earlier
  draft had (see below). It does **not** mean either merge order is
  equally smooth operationally, and the rollout order is no longer left to
  a recommendation someone could merge past: `bot-autonomy-bootstrap`'s
  `unsupported` entries for `copilot-cli`/`pi` exempt them only while
  their executables are absent, and `bot-autonomy-bootstrap` makes an
  **always-on aggregator job** in `devcontainer-build.yml` — not the
  path-filtered container-assertion job directly, which would wedge every
  PR outside that path — the **required status check** on the default
  branch. That aggregator depends on the assertion, which runs on any
  change to `.devcontainer/Dockerfile` — including the `sync-pin` PR that
  carries Copilot/pi into this repo's own bot image. **Modules before pin
  is therefore an enforced prerequisite, not a convention**: if the
  `sync-pin` PR ever bumps to an image with `copilot`/`pi` installed
  before `bot-autonomy-new-harnesses` has shipped their modules, the
  assertion fails, the aggregator reports failure, and the PR cannot merge
  — correctly and loudly (the fail-closed guarantee is never violated),
  but as a merge block, not merely a visible, bypassable failure. A PR
  that never touches the devcontainer is unaffected: the aggregator
  reports success on its own. An earlier draft of this
  sequencing had the opposite problem — a literal contradiction where one
  sentence required the modules to wait for the pin while another required
  the pin to wait for the modules, which no merge order could satisfy;
  removing the *implementation* dependency (modules don't need the pin to
  exist) fixed that self-contradiction, and requiring the CI check is what
  makes the *rollout* order a property the repository actually enforces
  rather than a claim resting on someone remembering it.

## Non-goals

- Does not add bot-autonomy policy modules for Copilot CLI, pi, or
  oh-my-pi — that is the separate follow-on change
  `bot-autonomy-new-harnesses`. It depends on this change publishing the
  binaries (there is nothing to write a module against otherwise), but
  not on the `sync-pin` PR that puts them in this repo's own bot image —
  see "State the sequencing explicitly" above: the modules merge
  independently of that pin, in either order, since an absent binary is
  already skipped by construction.
- Does not remove the `~/.gemini` named volume, the `gemini` registry
  family, or the `GEMINI.md` symlink convention — only the Gemini CLI binary
  and its image-layer footprint are removed.
- Does not change `agent-registry.json`'s schema (stays at v3); the new
  `oh-my-pi` row uses existing fields only.
- Does not add a DeepSeek Harness entry, out of scope per #1137.
- Does not itself bump the pin in `.devcontainer/Dockerfile` or its
  `template/` twin — that is the already-automated rolling `sync-pin` PR,
  sequenced after this change's image publishes from `main`.
- Does not write code — this change is planning artifacts only
  (`openspec/changes/harness-matrix/`).

## Capabilities

### New Capabilities

- `devcontainer/harness-image`: the shared devcontainer image's agent-harness
  inventory — which CLIs are installed, how each is pinned and verified, and
  how the manifest/smoke contract proves the built image matches.

### Modified Capabilities

(none — new capability, no existing `openspec/specs/` yet)

## Impact

- `images/devcontainer/Dockerfile`: version-pin `ARG`s, the npm/curl install
  `RUN` layers, and the `generate-manifest.sh` invocation's tool-version
  arguments.
- `images/devcontainer/smoke.sh`: the tool-presence loop and `run_version`
  probes.
- `agent-registry.json`: one new `oh-my-pi` harness row (schema v3 fields
  only).
- `renovate.json`: none expected — its existing generic Dockerfile ARG-pin
  `customManager` already tracks any correctly annotated
  `# renovate: datasource=<X> depName=<Y>` / `ARG <NAME>_VERSION=<value>`
  pair regardless of datasource (it already covers both `npm` and
  `github-releases` ARGs side by side today); see design.md - Context.
- Docs: `docs/guides/devcontainers.md` (drop Gemini from the harness-list
  prose); `.devcontainer/devcontainer.json` and its `template/` twin (drop
  "Gemini" from the profile-table comment); `docs/guides/herdr.md` and its
  jinja twin `template/docs/guides/herdr.md.jinja` (drop `gemini` from the
  pinned-image tool list, update the "0.8.0" version references).
- Downstream, implementable independently of this change's own merge order
  but not mergeable in the wrong rollout order — modules before the pin is
  enforced, not recommended: the rolling `sync-pin` PR (bumps
  `.devcontainer/Dockerfile` + its `template/` twin to the new image
  digest), and the follow-on `bot-autonomy-new-harnesses` change — see
  "State the sequencing explicitly" above for the full picture:
  implementing the modules never needs to wait on the pin, but
  `bot-autonomy-bootstrap`'s required container-assertion status check
  blocks the `sync-pin` PR from merging if it would land Copilot/pi ahead
  of their modules.
