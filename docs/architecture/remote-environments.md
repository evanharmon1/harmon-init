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

- for the same release tag, the image and a VM install **identical versions**
  of every shared tool: one bump in `versions.env` moves both, and the two
  manifests below are how that is checked rather than believed;
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
| `/usr/bin/yq` is the **Python** yq | It shadows mikefarah yq v4, and every frontmatter then reads as invalid | Installs into `/usr/local/bin` and puts that directory **first** on `PATH` by order, not membership — the `profile.d` drop-in removes every existing occurrence and prepends it — then asserts that `yq` and `task` *resolve* from it in the running process, which sourced that very drop-in. What the bootstrap does not own it reports: bash reads `~/.profile` *after* `/etc/profile`, and a stock one prepends `~/.local/bin`, so a `yq` there still shadows the pinned one in that user's login shells — the closing check runs the invoking user's real login shell *as that user* (via `runuser`; skipped with a note where it is missing, never run as root with the user's `HOME`, since a login shell executes `~/.profile`) and prints a warning naming the shadowing path and the remedy, and exits 0 |
| The locale is POSIX (`LANG` unset), or `LC_ALL=C` is already set | NBSP stops reading as whitespace, so Unicode-title checks silently pass what they should reject; a pre-existing `LC_ALL=C` overrides any `LANG` set beside it | Sets `LANG=C.UTF-8` in `/etc/environment` (and rewrites an `LC_ALL=` line there when one exists), **forces** `LANG` and `LC_ALL` to `C.UTF-8` in the `profile.d` drop-in rather than defaulting them, and asserts the *effective* locale — `locale` must report a UTF-8 `LC_CTYPE`, in the process and in a fresh login shell seeded with `LC_ALL=C` |

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
| `images/devcontainer/generate-manifest.sh` | the same file | Writes the tool manifest each side ends with (below) |
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

The browsers tier's "installed" contract is Playwright's own
`INSTALLATION_COMPLETE` marker in each browser location; a system dependency
removed after that marker was written is outside the bootstrap's guarantee,
and re-running the tier re-runs `--with-deps`.

Never installed, in any tier, and asserted both by the bootstrap and by CI:
**1Password (`op`), Homebrew, Tailscale.** The first and third are
credential-bearing and a shared remote VM must not hold either; Homebrew is a
second, unpinned package manager that would defeat the contract above. The
bootstrap's closing check is `PATH`-wide (`command -v`, the form a consumer
cares about) and states one invariant: it fails if any of them resolves at the
end of the run and did not at the start, and reports by path — without failing
— one the host already had, because a self-hosted VM whose administrator
installed Tailscale is not the bootstrap installing Tailscale. Neither Docker
nor Homebrew is required to *run* the bootstrap.

Interactive-terminal tools (zellij, herdr, starship, the TUIs) stay image-only.

## The entrypoint

`images/devcontainer/bootstrap-remote.sh` is the **only** remote setup script.
Each adapter's setup step is a one-line call to it at a pinned harmon-init
release tag — never a platform-specific copy:

```sh
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
  | sudo bash -s -- --ref "$HARMON_INIT_REF"
```

The tag is written **once** and read from that one variable: the URL the
script is fetched from and the `--ref` it fetches its install scripts and
`versions.env` from are the same value by construction, and if the script is
ever handed both `--ref` and `HARMON_INIT_REF` it refuses unless they agree.
From a checkout it uses the files beside it and ignores `--ref` for fetching.

`--ref` must be a **release tag** (`vX.Y.Z`); a branch, a bare commit, or a
pre-release is refused with the reason. That tag is the trust root this design
chose, and it is worth stating what that does and does not buy: everything the
standalone form runs comes from one immutable tag, protected by the release
process and the branch rules that gate what gets tagged — **not** by a
per-file signature or checksum, so it is as strong as the repository's
release controls and no stronger. An adapter that tracked `main` would take an
untested toolchain the moment anything merged, which is why the check exists.
`HARMON_ALLOW_UNPINNED_REF=1` lifts it for CI and development only, and prints
a warning naming the unpinned ref so a log can never pass one off as pinned.

`--tiers core,agents,browsers` selects tiers (default `core,agents`); `core`
cannot be skipped.

It runs as root or under `sudo` (an unprivileged caller is re-executed under
`sudo` with an explicit environment and `HOME=/root`, so root never writes
under the caller's home), is non-interactive, and is **idempotent** in a
precise sense: **a second run performs no new installs and changes no pinned
tool version** — no download, no npm or uv install, no corepack shim, no
manifest rewrite, and no rewrite of the two files under `/etc` when their
content already matches. The apt packages are deliberately *unpinned* and
converge on the archive: every run refreshes the index and lets apt upgrade
them, and an upgrade is **reported as a change, never hidden**. That is
asserted as counts, not as an exit status — it prints
`HARMON_BOOTSTRAP_NEW_INSTALLS=<n>` and `HARMON_BOOTSTRAP_UPGRADES=<n>` (and
their sum as `HARMON_BOOTSTRAP_CHANGES`), and CI requires `NEW_INSTALLS=0` plus
a byte-identical manifest on the second run, because a script that
re-downloaded and re-installed everything also exits 0.

One residual is stated rather than solved: the bootstrap guarantees `PATH`
precedence for the system profile and its own process, and can only *report*
a user-level shadow such as `~/.local/bin/yq`, because that user's own profile
runs last.

The agent posture (managed Claude Code settings, Codex configuration) is not
installed by the bootstrap today: #1404 adds the agent-posture install to both
the image and the bootstrap in the same change.

### The manifest: checking that image and VM agree

At the end of a run the bootstrap writes
`/usr/local/share/harmon-remote-env/manifest.json` (under `HARMON_PREFIX`),
produced by the **same** `generate-manifest.sh` the image runs and in the same
shape (`schemaVersion`, `image.{name,revision,architecture}`, `tools`) — with
`image.name` set to `harmon-remote-env` and `image.revision` the checkout's
commit or, for the standalone form, the release tag it was fetched from. Its
`tools` are not a list the bootstrap keeps: every pinned tool a tier installs
or verifies records `name=version` as it goes, and the manifest is that record
under the same keys the image's manifest uses.
`scripts/test-bootstrap-remote.sh` proves the key set — every `*_VERSION` pin
the default tiers read is recorded, under the key the Dockerfile's manifest
layer gives the same pin — with both sides derived from the files, so no
third list exists to drift.

That makes the drift claim testable rather than asserted. For the same release
tag, the image's manifest and the VM's must agree on every **shared** pin. The
image's manifest carries more (its image-only tools), so the image side is
narrowed to the keys `versions.env` pins — never to the keys the VM happens to
have, which would hide a shared tool the VM failed to record:

```sh
vm=/usr/local/share/harmon-remote-env/manifest.json
shared=$(sed -n 's/^\([A-Z][A-Z0-9_]*\)_VERSION=.*/\1/p' images/devcontainer/versions.env | tr 'A-Z_' 'a-z-' | jq -Rn '[inputs]')
diff <(jq -S .tools "$vm") \
     <(jq -S --argjson shared "$shared" '.tools | with_entries(select(.key | IN($shared[])))' image-manifest.json)
```

(`image-manifest.json` is `/usr/local/share/harmon-devcontainer/manifest.json`
copied out of a container running the image built from the same tag.) An
empty diff is the contract holding; a version line is a pin that differs, and
a key present only on the image side is a shared tool the VM did not record —
expected only for a tier the VM did not select (the browsers pins, by
default).
`smoke.sh` stays image-only — it asserts the image's whole toolchain,
including the tools the bootstrap never installs — so it is not the way to
check a VM; the comparison above is.

## Proof

| Check | Where | What it proves |
| --- | --- | --- |
| `task test:bootstrap-remote` | `task verify`, and the `guard` job | The pin contract, offline: no second pin owner (declared or typed into a download URL), every pin Renovate-extractable, both Node digests verified for the pinned Node, the fetch list matches the directory, no denied host, no forbidden tool named by the bootstrap or a tier script, and a non-release-tag `--ref` is refused |
| `remote-bootstrap.yml` → `bootstrap` | CI, stock `ubuntu:24.04` container, seeded with `/usr/bin` ahead of `/usr/local/bin` and `LC_ALL=C` | It runs: the tiers install inside the budget, the second run performs no new installs and leaves the manifest byte-identical, `yq` and `task` resolve from `/usr/local/bin` and the effective locale is UTF-8 in a fresh login shell on the system profile path, a user with `~/.local/bin/yq` planted gets the shadow warning and exit 0 through the un-sudoed re-exec path with nothing of root's left in that home and that user's `~/.profile` never executed as root, nothing forbidden appeared on `PATH`, every VM manifest key names its pin, and `task check` then passes in a harmon-init checkout |
| `images/devcontainer/smoke.sh` | the built image | The image really runs the shared scripts — they ship in the image beside `versions.env`, and its manifest records their versions for the comparison above |

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
