## Context

See proposal.md - Why for the motivating gap. Current state, precisely:

- `images/devcontainer/Dockerfile` is a single-stage, root-owned image build.
  JS-native CLIs (Claude Code, Gemini CLI, Codex, OpenCode, dmux) install via
  one combined `npm install -g` layer with plain version `ARG`s. Binary-only
  tools with no npm package (Antigravity) install via a `TARGETARCH`-cased
  `curl` + published-checksum-verify + `install` block; Terraform uses the
  same shape against HashiCorp's GPG-signed `SHA256SUMS`/`SHA256SUMS.sig`
  pair, fetched fresh at build time rather than hardcoded. TFLint instead
  hardcodes reviewed per-architecture SHA-256 digests as separate `ARG`s
  alongside its version pin.
- Every tool, once installed, is registered in `generate-manifest.sh`'s
  argument list (→ `/usr/local/share/harmon-devcontainer/manifest.json`) and
  in `smoke.sh`'s presence loop plus a `run_version` probe; a handful
  (`task`, `terraform`, `tflint`, `agy`) additionally cross-check their live
  version against the manifest.
- `agent-registry.json` (schema v3) **already lists** `copilot-cli` and `pi`
  as registered harnesses — their `family_constraint`/`model_resolution`/
  `roles` metadata exists today. Neither is installed in the shared image.
  `oh-my-pi` (`omp`) has no registry entry at all; per its own repository
  description ("coding agent with the IDE wired in", topics including
  `multi-provider`, `anthropic`, `openai`, `mcp`) it is an independent
  multi-provider agent CLI, not a `pi` plugin, so it needs a full harness row
  shaped like `pi`'s (`family_constraint: {kind: broker}`,
  `model_resolution.owner: harness-runtime`,
  `roles: [orchestrate, implement, review]`) rather than a variant of an
  existing entry.
- `renovate.json`'s customManagers already include a **generic** Dockerfile
  ARG-pin manager (`managerFilePatterns: ["/Dockerfile(\.jinja)?$/"]`,
  matching any `# renovate: datasource=<X> depName=<Y> ARG
  <NAME>_VERSION=<value>` comment+ARG pair). It is datasource-agnostic
  today's `HERDR_VERSION` (`github-releases`) and `CLAUDE_CODE_VERSION`
  (`npm`) ARGs already coexist under this one manager. A correctly annotated
  new ARG needs no `renovate.json` change.
- Registry npm lookups performed while writing this proposal confirm real,
  installable versions: `@github/copilot@1.0.82` (bin `copilot` →
  `npm-loader.js`, a 13 KB loader — the actual platform binary is not bundled
  in the npm package and is fetched separately, likely on first run or via
  an npm lifecycle step); `@earendil-works/pi-coding-agent@0.84.4` (bin `pi`
  → a self-contained bundled `dist/bundle/cli.js`, ~21 MB unpacked, whose
  published `scripts` carry no `install`/`postinstall` lifecycle hook —
  `--ignore-scripts` is therefore hardening with no functional gap, not a
  workaround for a script this package needs). GitHub release lookups
  confirm `can1357/oh-my-pi` tag `v18.1.2` ships `omp-linux-x64`,
  `omp-linux-arm64`, and `SHA256SUMS.txt` exactly as named in the proposal,
  and `herdrdev/herdr` tag `v0.8.2` exists.

## Goals / Non-Goals

**Goals:**
- Install and verifiably pin three new harness binaries using the pattern
  already established in this Dockerfile for their respective distribution
  shapes (npm for Copilot CLI and pi; fetch-and-checksum-verify for
  oh-my-pi, matching the Terraform block's self-updating
  fetch-SHA256SUMS-at-build-time shape rather than TFLint's hardcoded-digest
  shape).
- Remove Gemini CLI's image footprint completely (ARG, install layer,
  manifest entry, smoke probe, prose) while leaving every dependency
  Antigravity has on the same namespace (`~/.gemini` volume, `gemini` model
  family, `GEMINI.md` symlink convention) untouched.
- Keep every addition provable the same way existing tools are: present on
  `PATH`, correct `--version`, and (for the checksum-verified oh-my-pi)
  matching the manifest.

**Non-Goals:**
- Not adding `agent-registry.json` rows for Copilot CLI or pi — they already
  exist. Only `oh-my-pi` is new to the registry.
- Not deciding bot-autonomy boundaries for these three harnesses — that is
  `bot-autonomy-new-harnesses`, sequenced strictly after this change's image
  publishes and the `sync-pin` PR lands it in both `Dockerfile` twins.
- Not resolving whether `@github/copilot` exposes an auto-update-disable
  switch (see Open Questions) — the spec states the requirement
  conditionally, matching how the proposal itself phrased it.
- Not touching the `.devcontainer/Dockerfile` pin (root or `template/`) —
  that is the separately automated `sync-pin` PR.

## Decisions

**oh-my-pi: fetch `SHA256SUMS.txt` at build time and verify against it,
rather than hardcoding a per-architecture digest.** This Dockerfile already
contains both shapes: Terraform fetches `_SHA256SUMS`/`_SHA256SUMS.sig` fresh
every build and verifies via GPG signature + `sha256sum --check`; TFLint
instead hardcodes reviewed `TFLINT_SHA256_AMD64`/`ARM64` `ARG`s that a human
must update by hand alongside every Renovate version bump. oh-my-pi ships a
`SHA256SUMS.txt` per release (confirmed above), so the Terraform shape
applies directly: download it alongside the platform binary, `grep` the
`omp-linux-${arch}` line, `sha256sum --check`. This self-updates on every
version bump with no companion manual-digest PR, and matches the proposal's
own "verified against its `SHA256SUMS.txt`" phrasing. Alternative considered:
hardcode reviewed digests like TFLint — rejected as unnecessary extra review
burden when the release itself publishes a checksum manifest to verify
against, unlike TFLint's release (which does not).

**pi: npm install with `--ignore-scripts`, as stated in the proposal, kept as
the sole mechanism rather than offering the prebuilt tarball as a
parallel path.** The published package metadata shows no `install` or
`postinstall` lifecycle script on `@earendil-works/pi-coding-agent@0.84.4` —
`--ignore-scripts` defends against any *transitive* dependency's lifecycle
script running during a global install (standard supply-chain hardening for
`npm install -g` of a third-party package), not a workaround this package
itself needs. Since the npm path is complete and verifiably functional
(single bundled `dist/bundle/cli.js` entry point, no missing native
download step), it is decided rather than left open; the prebuilt-tarball
alternative the proposal also named is documented here as the fallback if a
future pi release regresses (adds a real postinstall step that
`--ignore-scripts` would then break).

**Copilot CLI: install via plain `npm install -g`, in the same combined
layer as the other npm-native harnesses.** `npm-loader.js`'s small unpacked
size indicates the platform binary is fetched separately (likely on first
run, an already-established pattern for npm-distributed native CLIs); this
needs no different Dockerfile mechanism than the existing harnesses in that
layer, since every `RUN` layer in this Dockerfile already has build-time
network access. Whether that first-run fetch needs to happen once during the
image build (so a bot/dev container never pays a first-run download cost) or
is acceptable at container-create/first-invoke time is an implementation
question for the image-authoring task, not a spec-level behavioral
requirement — either way, `copilot --version` on the built image is what
`smoke.sh` and this capability's scenarios assert.

**Gemini CLI removal keeps the `~/.gemini` volume, the `gemini` model
family, and `GEMINI.md`.** These three are independent of the CLI binary:
the volume is Antigravity's persisted OAuth/session state (per
`ensure-antigravity-cli.sh`'s own comment on 1.1.3+'s file-backed OAuth
fallback), the model family is `agent-registry.json` data describing Gemini
models generally (consumed by `antigravity`'s `family_constraint`), and
`GEMINI.md` is AGENTS.md's own documented symlink convention, unrelated to
whether the `gemini` binary is installed. Removing all three alongside the
CLI would break Antigravity and the registry, which is exactly the mistake
the proposal's Non-goals section heads off.

## Risks / Trade-offs

- [Risk] Removing Gemini CLI could silently break something that still
  shells out to the `gemini` binary (as opposed to the `agy`/Antigravity
  path) → [Mitigation] `smoke.sh`'s tool-presence loop is the single
  enumeration point; removing `gemini` from it is what makes any remaining
  reference to the binary itself (not the volume/family/symlink) fail loudly
  in CI rather than staying silently broken in a generated repo.
- [Risk] `@github/copilot`'s first-run/postinstall binary fetch could fail or
  behave differently across `amd64`/`arm64` in ways a bare `npm install -g`
  does not surface at build time → [Mitigation] `smoke.sh`'s
  `copilot --version` probe runs on both architectures via the existing
  candidate-build matrix, so a platform-specific fetch failure fails the
  build rather than shipping silently.
- [Risk] oh-my-pi's fetch-SHA256SUMS-at-build-time pattern trusts the
  release's checksum file itself, with no GPG signature to verify it against
  (unlike Terraform's signed `SHA256SUMS.sig`) → [Mitigation] this is the
  same trust level Antigravity's hardcoded-per-version SHA512 already
  accepts (trusting the publisher's checksum, not a signature chain);
  recorded here rather than treated as a blocking gap, since the proposal's
  own instruction is "verified against its SHA256SUMS.txt," not "verified
  against a signature."
- [Risk] herdr 0.8.2's new `pi`/`omp`/`copilot` kind recognition could still
  mis-detect a session if those harnesses' on-disk session formats differ
  from what 0.8.2 expects → [Mitigation] out of this change's control (herdr
  is an upstream dependency); `smoke.sh`'s `herdr --version` probe only
  proves the binary is pinned correctly, not session-format compatibility,
  which is exercised at bot-autonomy-new-harnesses time when the harnesses
  are actually driven.
- [Risk] Once this change's image is published and the rolling `sync-pin`
  PR bumps both `Dockerfile` twins, `copilot-cli` and `pi` become installed
  executables before `bot-autonomy-new-harnesses` gives them bot-autonomy
  modules — and `bot-autonomy-bootstrap`'s own fail-closed contract would,
  read strictly as "every installed executable needs a module," break every
  fresh bot container in that window → [Mitigation] this is not this
  change's contract to fix, but it does share the fix:
  `bot-autonomy-bootstrap` places `copilot-cli` and `pi` in its
  `unsupported` set (with a reason naming this pin and the follow-on
  module change) regardless of which change merges first, so the window is
  exempted rather than raced. This change's own new registry addition,
  `oh-my-pi`, needs the same treatment: whichever of `harness-matrix` and
  `bot-autonomy-bootstrap` merges **second** must add `oh-my-pi` to that
  `unsupported` set — tracked as task 3.4 here and task 4.5 in
  `bot-autonomy-bootstrap`'s tasks.md, so the obligation is not left to
  memory in only one of the two changes.

## Migration Plan

- A single implementation PR (not this planning change) edits
  `images/devcontainer/Dockerfile`, `generate-manifest.sh`'s invocation args,
  `smoke.sh`, `agent-registry.json` (new `oh-my-pi` row only), and the
  Gemini-mentioning prose in `docs/guides/devcontainers.md` and both
  `devcontainer.json` twins' comments.
- That PR's merge to `main` triggers `.github/workflows/
  publish-harmon-devcontainer.yml`, publishing a new immutable image tag.
- Separately, the existing rolling `sync-pin` PR bumps
  `.devcontainer/Dockerfile` (root) and its `template/` twin to the new
  `sha-<commit>@sha256:<digest>` reference — this proposal does not touch
  that pin itself.
- No data migration: the image change is additive/subtractive at the
  toolchain layer; no persisted volume shape changes. A consumer on an older
  pin keeps working until it takes the new pin.
- Rollback: revert the implementation PR before it publishes, or pin
  consumers back to the prior immutable image reference; no downstream
  migration to undo since no persisted state changes shape.

## Open Questions

- Does `@github/copilot` document an environment variable or flag to
  disable its own auto-update check, the way Claude Code
  (`DISABLE_AUTOUPDATER`), OpenCode (`OPENCODE_DISABLE_AUTOUPDATE`), and
  Antigravity (`AGY_CLI_DISABLE_AUTO_UPDATE`) do in this same Dockerfile? The
  proposal states the requirement conditionally ("if it has a switch"); the
  implementation PR resolves this by checking Copilot CLI's own
  documentation/`--help` output. Does not change the spec's contract, which
  is written to hold either way.
- Whether `npm-loader.js`'s platform-binary fetch should be forced during
  the image `RUN` layer (so no container pays a first-run download) or is
  acceptable lazily at first invocation is an implementation choice with no
  externally observable difference once a container has been used once;
  left to the implementation PR.
