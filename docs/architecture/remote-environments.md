# Remote environments

How a cloud VM that cannot pull the shared devcontainer image still gets the
same toolchain, from the same pins.

The shared image ([devcontainer-image.md](devcontainer-image.md)) is where the
platform's toolchain is installed correctly — pinned versions, per-architecture
checksums, Renovate annotations. Some environments cannot use it: Claude Code
on the web ignores `devcontainer.json` and takes no custom image, and it is not
alone. The obvious response is to re-type the installs into each platform's
setup script, which produces one copy per platform and a fleet that drifts —
the CI composite action is already such a copy, and it pins a different
go-task version from the image.

## The core contract

> **Every tool the remote environment installs is installed by the same script,
> from the same pin, that the shared image uses.**

Two consequences, and they are the whole point:

- bumping a version in one place updates the devcontainer **and** every remote
  environment together;
- a remote bootstrap **cannot** pin anything the image does not — there is no
  second place to write a version.

`scripts/test-bootstrap-remote.sh` (in `task verify`, and the `guard` job of
`remote-bootstrap.yml`) is what makes that a property rather than an intention:
it fails if any install script or the bootstrap declares a version or checksum
of its own, or if the Dockerfile re-declares one that moved.

### What the environment actually is

A remote VM is **pre-provisioned, not bare**. The Claude Code on the web VM
observed on 2026-09-27 (Ubuntu 24.04.4, amd64, 4 CPUs, 15 GB, running as
**root**) already had Node 22.22, Python 3.11, Go, uv 0.8.17, Docker 29.3, git
2.43, curl, sudo and apt. Two of its properties are traps, because everything
exits 0 and the answers are quietly wrong:

| Trap | What breaks | How the bootstrap answers it |
| --- | --- | --- |
| `/usr/bin/yq` is the **Python** yq | It shadows mikefarah yq v4, and every frontmatter then reads as invalid | Installs into `/usr/local/bin`, which precedes `/usr/bin`, and asserts the resolution before exiting |
| The locale is POSIX (`LANG` unset) | NBSP stops reading as whitespace, so Unicode-title checks silently pass what they should reject | Sets `LANG=C.UTF-8` in `/etc/environment` and a `profile.d` drop-in, and asserts it |

Ubuntu's **git 2.43** is kept deliberately: it is the git the shared image
ships, and the git-core PPA is denied here anyway. A devkit test that failed on
2.43 was fixed in the test (evanharmon1/harmon-devkit#1208), not by installing a
git the image does not have.

### The network the bootstrap may use

Probed through the environment's egress proxy on 2026-09-27. The core and
agents tiers download only from the allowed column.

| Allowed | Denied |
| --- | --- |
| GitHub release assets (`release-assets.githubusercontent.com`), `raw.githubusercontent.com`, `nodejs.org`, `archive.ubuntu.com`, `registry.npmjs.org`, `pypi.org`, `proxy.golang.org`, `releases.hashicorp.com` | `deb.nodesource.com`, `astral.sh`, `keybase.io`, `ppa.launchpadcontent.net`, `cli.github.com`, `dl.google.com` |

Two of the denials moved the **image** as well as the bootstrap, because a
shared script cannot reach a host one side is denied: Node now comes from the
checksum-pinned `nodejs.org` tarball rather than the `deb.nodesource.com` apt
repository, and uv from its checksum-pinned GitHub release rather than the
`astral.sh` installer. Neither host needs allow-listing by any adapter, and as
a side effect Node is pinned to an exact patch release for the first time — the
apt repository pinned only the major.

`keybase.io` stays in the Dockerfile: it fetches HashiCorp's PGP key for the
Terraform install, and Terraform is image-only.

## Source-of-truth mapping

| Devcontainer asset | Remote bootstrap | Who reads it |
| --- | --- | --- |
| `images/devcontainer/versions.env` | the same file | **Both.** Every pin on the remote path, with its `# renovate:` annotation |
| `images/devcontainer/install/lib.sh` | the same file | Arch detection, checksum-verified download, idempotence, change accounting |
| `images/devcontainer/install/apt-core.sh` | the same file | Ubuntu's packaged core (git, jq, shellcheck, yamllint, python3, …). The image passes its interactive extras as arguments |
| `images/devcontainer/install/install-core.sh` | the same file | The **core** tier |
| `images/devcontainer/install/install-agents.sh` | the same file | The **agents** tier |
| `images/devcontainer/install/install-browsers.sh` | the same file | The **browsers** tier |
| `images/devcontainer/install/install-posture.sh` | the same file | The agent-posture extension point (below) |
| `images/devcontainer/Dockerfile` | `images/devcontainer/bootstrap-remote.sh` | The two entrypoints. Each runs the scripts above; each adds only what the other has no use for |

Image-only pins stay as Dockerfile `ARG`s (Terraform, TFLint, the
interactive-terminal tools, the other agent CLIs). The split is not stylistic:
a pin in `versions.env` is a promise that both paths install that tool, and the
guard enforces the promise in both directions.

## Tiers

The platform's cached-setup budget is roughly five minutes, so the default is
what the dev loop actually gates on and nothing else.

| Tier | Default | Contents |
| --- | --- | --- |
| **core** | yes | Node + corepack/pnpm, uv, go-task, lefthook, gh, mikefarah yq, shfmt, actionlint, hadolint, gitleaks, lychee, semgrep, copier, markdownlint-cli2, and Ubuntu's packaged git, jq, shellcheck, yamllint, python3 |
| **agents** | yes | The Codex CLI at the image's pin. Used only where an environment persists and holds its own login (#1406); ephemeral clouds install it and never log in |
| **browsers** | no | Playwright Chromium. Opt-in because it is larger than everything above put together |

`markdownlint-cli2` is in core because `lint:markdown` needs it — it was missing
from the original tier list and the omission was found by running a full dev
loop on the VM.

Never installed, in any tier, and asserted both by the bootstrap and by CI:
**1Password (`op`), Homebrew, Tailscale.** The first and third are
credential-bearing and a shared remote VM must not hold either; Homebrew is a
second, unpinned package manager that would defeat the contract above. Neither
Docker nor Homebrew is required to *run* the bootstrap.

Interactive-terminal tools (zellij, herdr, starship, the TUIs) stay image-only.

## The entrypoint

`images/devcontainer/bootstrap-remote.sh` is the **only** remote setup script.
Each adapter's setup step is a one-line call to it at a pinned harmon-init
release tag — never a platform-specific copy:

```sh
curl -fsSL https://raw.githubusercontent.com/evanharmon1/harmon-init/vX.Y.Z/images/devcontainer/bootstrap-remote.sh \
  | sudo bash -s -- --ref vX.Y.Z
```

`--ref` is required in that form and is what pins it: fetched on its own, the
script pulls its install scripts and `versions.env` from that same ref. From a
checkout it uses the files beside it and ignores `--ref`. Fetching from a
**release tag, never `main`**, is the contract: an adapter that tracked `main`
would take an untested toolchain the moment anything merged.

`--tiers core,agents,browsers` selects tiers (default `core,agents`); `core`
cannot be skipped.

It runs as root or under `sudo`, is non-interactive, and is **idempotent**: a
second run installs nothing. That is asserted as a count, not as an exit
status — it prints `HARMON_BOOTSTRAP_CHANGES=<n>` and CI requires `0` on the
second run, because a script that re-downloaded and re-installed everything
also exits 0.

### The agent-posture extension point

`install-posture.sh` runs last and **today does nothing**. Defining the managed
Claude Code settings and Codex configuration is #1408's unit, and proving each
platform honours them is #1404's. Until those land, running the bootstrap on a
remote VM leaves the agent posture **unset** — stated here rather than left to
be discovered. The step exists now so that work lands as one named phase at a
fixed point in the sequence (after every tool it might reference is on `PATH`)
instead of being retrofitted into the middle of a tier.

## Proof

| Check | Where | What it proves |
| --- | --- | --- |
| `task test:bootstrap-remote` | `task verify`, and the `guard` job | The pin contract, offline: no second pin owner, every pin Renovate-extractable, the fetch list matches the directory, no denied host |
| `remote-bootstrap.yml` → `bootstrap` | CI, stock `ubuntu:24.04` container | It runs: the tiers install inside the budget, the second run changes nothing, the yq and locale traps are resolved, nothing forbidden is installed, and `task check` then passes in a harmon-init checkout |
| `images/devcontainer/smoke.sh` | the built image | The image and the bootstrap really did install the same tools — the shared scripts ship in the image and the manifest records their versions |

The CI job runs on the runner's native architecture, so `vars.CI_RUNS_ON` is
what decides whether arm64 is exercised. On GitHub-hosted runners it is amd64;
point that variable at arm64 hardware and the same job proves arm64 unchanged.
Until such a runner exists the arm64 download paths are checksum-verified but
**not executed**. The five-minute figure is likewise measured on a
GitHub-hosted runner, which is not the remote VM — #1407's HUMAN item is what
proves the VM.

## Known divergence

`.github/actions/setup/action.yml` pins its own go-task (3.51.1) while the
image pins 3.53.1. Converging CI onto `versions.env` is deliberately **out of
scope** here and is recorded rather than quietly fixed: the composite action
runs on GitHub-hosted runners with their own constraints, and folding it in
would widen a change whose subject is the image-to-VM path.

## Adapters

Each platform gets one section below, appended by its own issue. A row here
names the adapter's issue, not its content — the contract above is what every
adapter shares, and the section is where a platform's specifics go.

| Platform | Issue | Section |
| --- | --- | --- |
| Claude Code on the web | #1407 | *(pending)* |
| Codex cloud | #750 | *(pending)* |
| Sprites | #1411 | *(pending)* |
| Self-hosted | #1410 | *(pending)* |
