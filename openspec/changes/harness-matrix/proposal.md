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
  CLI exposes a switch for it.
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
  (`can1357/oh-my-pi`), verified against that release's `SHA256SUMS.txt`;
  Renovate `github-releases` datasource; binary `omp`; add a new `oh-my-pi`
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
- State the sequencing explicitly, and make it acyclic: this change
  publishes a new image from `main`; the rolling `sync-pin` PR bumps both
  `Dockerfile` twins (root + `template/`) to the new digest; the follow-on
  `bot-autonomy-new-harnesses` change does **not** wait for that pin —
  it merges independently, in either order relative to the pin. Its
  modules for `copilot-cli`/`pi` are safe to exist before either binary
  is installed, because `bot-autonomy.sh` already skips a module whose
  executable is absent (the same behavior every other module has from
  day one). Once both `bot-autonomy-new-harnesses` and the pin have
  landed — in whichever order — the modules cover the binaries the
  moment they appear installed, with no window where an installed,
  supported harness lacks coverage. Waiting for the pin before
  implementing the modules was the earlier draft of this sequencing, and
  it was self-contradictory: `bot-autonomy-bootstrap`'s `unsupported`
  entries for `copilot-cli`/`pi` exempt them only while absent (see that
  change's spec), so a pin that installs them before their modules exist
  fails `verify` and fails CI — meaning the pin genuinely cannot land
  first either, which would have made "wait for the pin" impossible to
  satisfy. Landing the modules independently removes the ordering
  constraint entirely rather than picking a side of it.

## Non-goals

- Does not add bot-autonomy policy modules for Copilot CLI, pi, or
  oh-my-pi — that is the separate follow-on change
  `bot-autonomy-new-harnesses`, gated on this change's image publishing and
  its pin landing in both `Dockerfile` twins.
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
- Downstream, independent of each other and of this change's own merge
  order: the rolling `sync-pin` PR (bumps `.devcontainer/Dockerfile` + its
  `template/` twin to the new image digest), and the follow-on
  `bot-autonomy-new-harnesses` change — see "State the sequencing
  explicitly" above for why neither needs to wait on the other.
