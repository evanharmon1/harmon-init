# devcontainer/harness-image Specification

## Purpose
Defines the shared devcontainer image's agent-harness inventory contract:
which CLIs are installed, how each is pinned and integrity-verified, and how
the manifest and smoke-test surface prove a built image matches — the
foundation `bot-autonomy-bootstrap` and its `bot-autonomy-new-harnesses`
follow-on depend on to have real binaries to bind policy modules to.

## Requirements

### Requirement: GitHub Copilot CLI is installed and version-pinned
The shared image SHALL install GitHub Copilot CLI via npm at a
Renovate-tracked version pin and expose the `copilot` binary on `PATH`. If
Copilot CLI documents a mechanism to disable its own auto-update check, the
image SHALL set it. If Copilot CLI's platform binary is fetched separately
from the npm package (rather than bundled), the Dockerfile's install layer
SHALL force that fetch at build time, so a freshly created container never
needs network access to run `copilot` the first time.

#### Scenario: copilot is present and pinned
- **WHEN** the shared image is built
- **THEN** `copilot --version` succeeds in the built image and its reported
  version matches the pinned `@github/copilot` version recorded in the
  manifest

#### Scenario: the version pin is Renovate-tracked
- **WHEN** the Dockerfile's Copilot CLI `ARG` is inspected
- **THEN** it carries a `# renovate: datasource=npm depName=@github/copilot`
  annotation immediately above the version `ARG`

#### Scenario: auto-update is disabled where a documented switch exists
- **WHEN** the built image is inspected and Copilot CLI documents an
  environment variable or flag that disables its own update check
- **THEN** that variable or flag is set in the image

#### Scenario: a fresh container needs no network to run copilot
- **WHEN** a container built from the image runs `copilot --version` (or
  any invocation that would trigger a first-run platform-binary fetch)
  with network access blocked
- **THEN** it succeeds — the platform binary was already fetched during
  the image build, in the same `RUN` layer as the npm install, or the npm
  package already bundles it

### Requirement: pi is installed and version-pinned
The shared image SHALL install pi via `npm install -g
@earendil-works/pi-coding-agent@0.84.4 --ignore-scripts`, expose the `pi`
binary on `PATH`, and set `PI_SKIP_VERSION_CHECK` to disable its auto-update
check.

#### Scenario: pi is present and pinned
- **WHEN** the shared image is built
- **THEN** `pi --version` succeeds in the built image and its reported
  version matches the pinned `@earendil-works/pi-coding-agent` version
  recorded in the manifest

#### Scenario: the install uses --ignore-scripts
- **WHEN** the Dockerfile's pi install layer is inspected
- **THEN** the `npm install -g` invocation for
  `@earendil-works/pi-coding-agent` includes `--ignore-scripts`

#### Scenario: auto-update is disabled
- **WHEN** the built image's environment is inspected
- **THEN** `PI_SKIP_VERSION_CHECK` is set

### Requirement: oh-my-pi is installed, checksum-verified, and registered
The shared image SHALL install oh-my-pi from the prebuilt
`omp-linux-{x64,arm64}` asset of `can1357/oh-my-pi` release `v18.1.2`,
verifying the downloaded binary against a **per-architecture SHA-256
digest pinned in the Dockerfile** (as a reviewed `ARG` alongside the
version pin — the same pattern TFLint and Antigravity already use in this
file), not by fetching and trusting that release's own `SHA256SUMS.txt` at
build time. `agent-registry.json` SHALL carry a new `oh-my-pi` harness
row.

#### Scenario: omp is present and pinned
- **WHEN** the shared image is built
- **THEN** `omp --version` succeeds in the built image and its reported
  version matches the pinned oh-my-pi release recorded in the manifest

#### Scenario: the downloaded binary is checksum-verified against a pinned digest
- **WHEN** the Dockerfile's oh-my-pi install layer runs
- **THEN** it checks the downloaded `omp-linux-${arch}` asset's SHA-256
  against a per-architecture digest hardcoded in the Dockerfile (not one
  fetched from the release at build time) and fails the build on a
  mismatch — it does not install an unverified binary

#### Scenario: the pinned digests are updated alongside the version
- **WHEN** `OH_MY_PI_VERSION` is bumped to a new release
- **THEN** the per-architecture SHA-256 `ARG`s are reviewed and updated in
  the same change, the way `TFLINT_SHA256_AMD64`/`ARM64` already are
  alongside `TFLINT_VERSION`

#### Scenario: oh-my-pi is a registered harness in both registry twins
- **WHEN** `agent-registry.json` and its verbatim twin
  `template/agent-registry.json` are validated
- **THEN** both contain an identical harness row with slug `oh-my-pi`,
  `scripts/validate-agent-registry.mjs` accepts it against the unchanged v3
  schema, and `task test:dogfood-parity` passes on the pair

### Requirement: Gemini CLI is fully removed while its dependents are preserved
The shared image SHALL NOT install Gemini CLI (`@google/gemini-cli`): its
Dockerfile `ARG`, `npm install -g` line, manifest entry, and `smoke.sh`
presence probe SHALL all be absent. The `~/.gemini` named volume, the
`gemini` model family in `agent-registry.json`, and the `GEMINI.md` symlink
convention SHALL remain unchanged.

#### Scenario: gemini is absent from the built image
- **WHEN** the shared image is built
- **THEN** no `gemini` binary is present on `PATH`, and the manifest
  contains no `gemini-cli` entry

#### Scenario: smoke no longer probes for gemini
- **WHEN** `smoke.sh` runs against the built image
- **THEN** it does not check for a `gemini` binary and does not fail for its
  absence

#### Scenario: Antigravity's dependents on the gemini namespace are untouched
- **WHEN** the devcontainer configuration is inspected after this change
- **THEN** the `~/.gemini` named volume mount is still declared in both
  `devcontainer.json` twins, the `gemini` family entry is still present in
  `agent-registry.json`, and the `GEMINI.md` symlink convention is
  unchanged

#### Scenario: harness-list prose drops Gemini
- **WHEN** `docs/guides/devcontainers.md` (and its jinja twin) and both
  `devcontainer.json` twins' profile-table comments are inspected
- **THEN** neither lists Gemini among the bot profile's agent harnesses,
  and the Herdr-resume paragraph no longer describes Gemini's resume
  integration status or lists `~/.gemini` as a Gemini-CLI conversation
  volume

### Requirement: herdr is bumped to a version that recognizes the new harness kinds
The shared image SHALL pin herdr to `0.8.2` or later.

#### Scenario: herdr is at the new pin
- **WHEN** the shared image is built
- **THEN** `herdr --version` reports `0.8.2` (or later) and the manifest
  agrees

### Requirement: every addition and removal is covered by the manifest and smoke contract
Each harness added or removed by this change SHALL have a corresponding
`generate-manifest.sh` argument (added or removed) and a corresponding
`smoke.sh` presence-and-`--version` probe (added or removed), matching the
contract every existing tool in the image already follows.

#### Scenario: every new tool is in the manifest
- **WHEN** `generate-manifest.sh` runs during the image build
- **THEN** its arguments include `copilot`, `pi`, and `omp` (or their
  manifest key names) at their pinned versions, and no longer include
  `gemini-cli`

#### Scenario: every new tool is smoke-tested
- **WHEN** `smoke.sh` runs against the built image
- **THEN** it asserts `copilot`, `pi`, and `omp` are on `PATH`, each
  responds to a version/help probe without a loader or command-not-found
  failure, AND each tool's reported version is explicitly compared against
  its manifest entry — the generic exit-status-only probe alone would let
  a successfully-running wrong version satisfy this scenario while
  violating the version-pin scenarios above

### Requirement: both supported architectures build
Every addition SHALL build successfully for both `amd64` and `arm64`.

#### Scenario: the candidate build matrix proves both architectures
- **WHEN** the publish workflow's candidate job builds the image
- **THEN** both the `amd64` and `arm64` builds succeed and each built
  image's `smoke.sh` run passes

### Requirement: new version pins require no renovate.json change
A correctly annotated `# renovate: datasource=<X> depName=<Y>` /
`ARG <NAME>_VERSION=<value>` pin added to the Dockerfile for any of the three
new tools SHALL be tracked by the existing generic Dockerfile ARG-pin
`customManager`, without adding a new `customManagers` entry.

#### Scenario: new ARGs match the existing generic manager
- **WHEN** `renovate.json`'s Dockerfile ARG-pin `customManager` regex is
  applied to the new Copilot CLI, pi, and oh-my-pi `ARG` lines
- **THEN** each line matches without requiring a new or modified
  `customManagers` entry
