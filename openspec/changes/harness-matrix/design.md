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
  shapes (npm for Copilot CLI and pi; a checksum-verified binary fetch for
  oh-my-pi, matching TFLint's and Antigravity's reviewed-per-architecture-
  digest shape rather than Terraform's fetch-and-verify-a-signed-manifest
  shape, since oh-my-pi's release ships no signature to give a fetched
  manifest independent trust).
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

**oh-my-pi: hardcode reviewed per-architecture SHA-256 digests as `ARG`s
pinned in the Dockerfile, matching TFLint's (and Antigravity's) pattern —
not fetch-and-trust `SHA256SUMS.txt` at build time.** An earlier draft of
this decision chose the opposite shape (fetch `SHA256SUMS.txt` fresh every
build, `grep` the matching line, `sha256sum --check`), reasoning it
self-updates on every version bump with no companion manual-digest PR.
That draft's own Risks section (below) already named the gap this
creates: fetching **both** the binary and its checksum manifest from the
**same mutable GitHub release** means a compromised release or account
could replace both and still pass verification — unlike Terraform's shape
(the closest apparent precedent), which verifies its fetched checksums
against a **GPG signature over a separate key the publisher controls**,
giving the fetched manifest an independent trust anchor oh-my-pi's plain
`SHA256SUMS.txt` does not have. oh-my-pi publishes no such signature, so
the Terraform shape does not actually apply here despite the surface
similarity (both fetch a checksums file) — only Terraform's *signature*
step supplies the independence that makes fetching safe. TFLint's shape
(and Antigravity's own hardcoded-per-version SHA-512 pins, already used in
this same Dockerfile for a release that similarly ships no signature) is
the correct precedent instead: a human reviews and pins the digest as part
of the version-bump review, so the trust anchor is the reviewer, not the
same release the binary comes from. This is a companion manual-digest
`ARG` alongside every version bump, the same review cost TFLint already
pays — accepted here in exchange for closing the compromised-release gap,
rather than optimizing for the self-updating convenience that gap was the
cost of.

**pi: npm install with `--ignore-scripts`, as stated in the proposal, kept as
the sole mechanism rather than offering the prebuilt tarball as a
parallel path — installed in its own `RUN` layer, not the combined one.**
The published package metadata shows no `install` or `postinstall`
lifecycle script on `@earendil-works/pi-coding-agent@0.84.4` —
`--ignore-scripts` defends against any *transitive* dependency's lifecycle
script running during a global install (standard supply-chain hardening for
`npm install -g` of a third-party package), not a workaround this package
itself needs. Since the npm path is complete and verifiably functional
(single bundled `dist/bundle/cli.js` entry point, no missing native
download step), it is decided rather than left open; the prebuilt-tarball
alternative the proposal also named is documented here as the fallback if a
future pi release regresses (adds a real postinstall step that
`--ignore-scripts` would then break). `--ignore-scripts` is an npm-invocation
flag, not a per-package one: it silences lifecycle scripts for every
package named in the same `npm install -g a b c --ignore-scripts` command.
Copilot CLI's `npm-loader.js` (see below) is small enough that its platform
binary looks fetched by a separate step, plausibly a lifecycle script —
folding pi into the same combined layer as Copilot and the other harnesses
would therefore risk silently breaking Copilot's install to harden a
package that never needed it. pi gets its own `RUN` layer.

**Copilot CLI: install via plain `npm install -g`, in the same combined
layer as the other npm-native harnesses — and force the platform-binary
fetch into that same build-time `RUN` layer, not leave it for first
invocation.** `npm-loader.js`'s small unpacked size (13 KB) indicates the
real platform binary is not bundled in the npm package and is fetched
separately; an earlier draft of this decision left the timing of that
fetch (build time vs. first run) as an implementation choice with "no
externally observable difference." That understated the difference: a
container whose first `copilot` invocation silently reaches the network
is a container that (a) fails cold in a network-restricted environment
(exactly the posture the bot profile's isolation model assumes it can
rely on for a pinned, reproducible toolchain) and (b) behaves differently
from every other harness in this image, all of which are fully
functional, network-free, the instant the container starts. The
Dockerfile's install layer SHALL force this fetch — running `copilot
--version` (or an equivalent command documented to trigger the loader's
one-time download) inside the same `RUN` instruction that installs the
package — and the image build SHALL fail if that forced run does not
leave a runnable, network-free `copilot` behind. If a future
`@github/copilot` release bundles the platform binary directly (no
separate fetch), the implementation PR SHALL instead prove that directly
(the loader's own `npm-loader.js` no longer performs a network fetch) and
this forcing step becomes unnecessary — either way, the built image must
demonstrably not need network access to run `copilot` a second time.
`smoke.sh`'s `copilot --version` probe is what proves this from the
built image, but only if the image was built to guarantee it rather than
happening to have a warm cache from the build environment's own network
access.

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
- [Risk] `@github/copilot`'s platform-binary fetch could fail or behave
  differently across `amd64`/`arm64` in ways a bare `npm install -g`
  alone would not surface at build time → [Mitigation] the Dockerfile
  forces this fetch into the same `RUN` layer as the install (see
  Decisions), so a platform-specific fetch failure fails the build
  directly, and `smoke.sh`'s `copilot --version` probe (run on both
  architectures via the existing candidate-build matrix, with network
  blocked) independently confirms the fetch already happened rather than
  quietly succeeding by reaching the network a second time.
- [Risk] Hardcoded per-architecture digests (the now-decided approach)
  require a human to actually update them on every `OH_MY_PI_VERSION` bump
  — unlike a fetch-at-build pattern, a Renovate-only version bump with no
  matching digest update would either fail closed (if the old digest no
  longer matches the new release, which is the likely outcome and a safe
  failure) or, worse, silently keep verifying against a stale digest that
  happens to still match if the binary is unchanged → [Mitigation] this is
  the same review discipline TFLint's `TFLINT_SHA256_AMD64`/`ARM64` `ARG`s
  already require in this same Dockerfile, and the failure mode on a
  missed update is fail-closed (build breaks) in the overwhelmingly likely
  case, not silent — the earlier fetch-at-build draft traded this review
  cost away in exchange for trusting the same mutable release the binary
  itself comes from, which is the worse trade for a security boundary.
- [Risk] herdr 0.8.2's new `pi`/`omp`/`copilot` kind recognition could still
  mis-detect a session if those harnesses' on-disk session formats differ
  from what 0.8.2 expects → [Mitigation] out of this change's control (herdr
  is an upstream dependency); `smoke.sh`'s `herdr --version` probe only
  proves the binary is pinned correctly, not session-format compatibility,
  which is exercised at bot-autonomy-new-harnesses time when the harnesses
  are actually driven.
- [Risk] Once this change's image is published and the rolling `sync-pin`
  PR bumps both `Dockerfile` twins, `copilot-cli` and `pi` become installed
  executables. If `bot-autonomy-new-harnesses` has not yet given them real
  modules by then, `bot-autonomy-bootstrap`'s `unsupported` exemption for
  them (absent-only) no longer applies, and `verify` fails loudly on every
  fresh bot container → [Mitigation] two things, not one, and they answer
  different questions. First, the *implementation* dependency: an earlier
  draft tried to resolve this by ordering the two changes' merges — "the
  pin must not land before the modules ship" — which directly contradicted
  the *other* statement that `bot-autonomy-new-harnesses` waits for the
  pin, so neither could safely go first. That is fixed by removing the
  implementation dependency entirely: `bot-autonomy-new-harnesses`'s
  modules are safe to *write and merge* before the pin lands, because
  `bot-autonomy.sh` already skips a module whose executable is absent
  (true for every module since `bot-autonomy-bootstrap`) — so
  implementing the modules never has to wait on this change's pin.
  Second, and separately: that does **not** make the *rollout* order
  irrelevant, and it is no longer left to a recommendation.
  `bot-autonomy-bootstrap` makes an **always-on aggregator job** in
  `devcontainer-build.yml` — not the path-filtered container-assertion job
  directly, which would wedge every PR that never touches the devcontainer
  — the **required status check** on the default branch. The assertion
  the aggregator depends on runs on any change to
  `.devcontainer/Dockerfile`, including the `sync-pin` PR this change
  feeds. If the pin merges before the modules do, that assertion fails,
  the aggregator reports failure — loud, not silent, the fail-closed
  guarantee holds — and the PR **cannot merge** while it fails, not merely
  "should not." Land `bot-autonomy-new-harnesses` before the `sync-pin` PR
  that carries these binaries into this repo's own bot image, and the
  required aggregator enforces that ordering rather than depending on
  someone following the recommendation — while still reporting an
  automatic pass for any PR the devcontainer change-detection filter
  doesn't match. This change's own new registry addition, `oh-my-pi`,
  still needs its own
  coordination: whichever of `harness-matrix` and `bot-autonomy-bootstrap`
  merges **second** must add `oh-my-pi` to that `unsupported` set —
  tracked as
  task 3.4 here and task 4.5 in `bot-autonomy-bootstrap`'s tasks.md — but
  that is registry-row bookkeeping, not a rollout-ordering dependency.

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
