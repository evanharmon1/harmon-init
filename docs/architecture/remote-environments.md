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

`scripts/test-bootstrap-remote.sh` (in `task verify`, and in `build.yml`'s
`lint` job on every pull request) is what makes that a property rather than an
intention:
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
| `/usr/bin/yq` is the **Python** yq | It shadows mikefarah yq v4, and every frontmatter then reads as invalid | Installs into `/usr/local/bin` and puts that directory **first** on `PATH` by order, not membership, for bash and POSIX-sh login shells — the `/etc/profile.d` drop-in removes every existing occurrence and prepends it — then asserts that `yq` and `task` *resolve* from it in the running process, which sourced that very drop-in. What the bootstrap does not own it reports: bash reads `~/.profile` *after* `/etc/profile`, and a stock one prepends `~/.local/bin`, so a `yq` there still shadows the pinned one in that user's login shells — the closing check runs the invoking user's real login shell *as that user* (via `runuser`, the user named by `SUDO_USER`; skipped with a note where `runuser` is missing, never run as root with the user's `HOME`, since a login shell executes `~/.profile`) and prints a warning naming the shadowing path and the remedy, and exits 0. Root's own `HOME` is the running uid's passwd home on every entry path — `sudo -E` preserves the caller's, and the bootstrap replaces it before any tier runs — so no probe and no install ever sources or writes under the caller's home |
| The locale is POSIX (`LANG` unset), or `LC_ALL=C` is already set | NBSP stops reading as whitespace, so Unicode-title checks silently pass what they should reject; a pre-existing `LC_ALL=C` overrides any `LANG` set beside it | Sets `LANG=C.UTF-8` in `/etc/environment` (and rewrites an `LC_ALL=` line there when one exists), **forces** `LANG` and `LC_ALL` to `C.UTF-8` in the `profile.d` drop-in rather than defaulting them, and asserts the *effective* locale — `locale` must report a UTF-8 `LC_CTYPE`, in the process and in a fresh login shell seeded with `LC_ALL=C` |

Ubuntu's **git 2.43** is kept deliberately: it is the git the shared image
ships, and the git-core PPA is denied here anyway. A devkit test that failed on
2.43 was fixed in the test (evanharmon1/harmon-devkit#1208), not by installing a
git the image does not have.

### The network the bootstrap may use

Probed through the environment's egress proxy on 2026-09-27. The core and
agents tiers download only from the allowed column.

| Allowed host | Why the bootstrap reaches it |
| --- | --- |
| `github.com` | the origin of every GitHub release download: `github.com/<owner>/<repo>/releases/download/…` answers **302**, so it is contacted for task, gh, uv, gitleaks and the rest even though the bytes come from the next host |
| `release-assets.githubusercontent.com` | the 302 target that actually serves GitHub release assets |
| `raw.githubusercontent.com` | the standalone entry fetches `versions.env`, `lib.sh` and the tier scripts from the release tag, and the agent posture from the same tag: `.devcontainer/agent/agent-autonomy.sh`, `.devcontainer/config/agent/claude-managed-settings.json`, `.devcontainer/config/agent/codex-managed-config.toml` and `.devcontainer/config/agent/harnesses.json` |
| `nodejs.org` | the checksum-pinned Node tarball |
| `archive.ubuntu.com` | the apt packages of the core tier. One of the three Ubuntu archive mirrors the VM's **own** apt sources configure, so `apt-get update` alone contacts them whether or not a package is installed; the set is written once in `images/devcontainer/install/apt-mirrors.txt` and both this table and the guard's apt implication are derived from it. amd64: the release, updates and backports pockets |
| `security.ubuntu.com` | the same apt run's **security** pocket on amd64 (`noble-security`) — a separate host, not a path under the archive, so an allowlist holding only the line above blocks a stock `apt-get update` |
| `ports.ubuntu.com` | the same packages on **arm64**, a declared target of the shared image: there every pocket, security included, is served from ports rather than from archive/security |
| `registry.npmjs.org` | `npm install -g` for the npm-installed tools (codex, markdownlint-cli2, Playwright) |
| `pypi.org` | package **metadata** for `uv tool install` — the wheels come from the next host |
| `files.pythonhosted.org` | the wheels `uv tool install` actually downloads (semgrep, copier) |
| `proxy.golang.org` | probed allowed; no tier reaches it today |
| `releases.hashicorp.com` | probed allowed; no tier reaches it today (Terraform is image-only) |
| `cdn.playwright.dev` | Chromium for the **opt-in** browsers tier only; the default tiers never contact it |

| Denied host | What it would have been for |
| --- | --- |
| `deb.nodesource.com` | the NodeSource apt repository (Node now comes from `nodejs.org`) |
| `astral.sh` | the uv installer script (uv now comes from its GitHub release) |
| `keybase.io` | HashiCorp's PGP key for the Terraform install (image-only) |
| `ppa.launchpadcontent.net` | the git-core PPA (Ubuntu's git 2.43 is kept) |
| `cli.github.com` | the gh apt repository (gh comes from its GitHub release) |
| `dl.google.com` | Google's apt repositories |

**The installers trust the system CA store.** A platform VM can sit behind a
TLS-intercepting proxy: the platform seeds the system store
(`/etc/ssl/certs/ca-certificates.crt`) with the proxy's CA and exports variables
such as `SSL_CERT_FILE` and `NODE_EXTRA_CA_CERTS` into the *session* — but the
setup script runs the bootstrap under `sudo bash`, which resets the environment,
so nothing but the store itself survives. `curl` reads the store; `uv` and Node
ship their own roots and would reject the proxy's certificate (`invalid peer
certificate: UnknownIssuer`, observed 2026-10-06 at the first `uv tool
install`), so the shared scripts tell them to. `lib.sh` — sourced by every tier
script — exports `NODE_EXTRA_CA_CERTS` pointing at the bundle when that file
exists and the caller set none (a caller's own value wins), which covers npm and
every Node process a tier starts, Playwright's browser download included;
`harmon_uv_tool` passes `--system-certs`. Where no proxy intercepts TLS the store
holds the public roots too, so both are no-ops there, and the hosts in the tables
are unchanged. `scripts/test-bootstrap-remote.sh` sources `lib.sh` and runs both
helpers against stubs, so dropping either setting fails the guard — CI's
`remote-bootstrap` job has no intercepting proxy and could not notice.

`scripts/test-bootstrap-remote.sh` keeps both tables honest in both directions:
every host the install scripts and the bootstrap contact — literally in a URL,
or through `apt-get`, `npm install`, `uv tool install` and Playwright's browser
download — must appear in the allowed table. The denied table is read straight
out of this section as the guard's own denied set, so the two cannot drift: none
of its hosts may appear in the Dockerfile, the bootstrap or an install script,
with one exemption — `keybase.io` in the Dockerfile, for the reason the last
paragraph of this section gives. That exemption is enforced in both directions
too: it fails if it goes stale (nothing contacts `keybase.io` any more), and
`keybase.io` still fails if it appears in the shared path — the bootstrap or
`install/*.sh` — which is what would actually break a VM. The allowed table is
read the other way round as well: a row nothing reaches fails, unless its own
text says `no tier reaches it today` — which is why the two probed-but-unused
rows say exactly that — and a row carrying that phrase fails the moment
something does reach it.
Without that direction a table can be *incomplete* and still be certified, which
is how the apt row named one mirror while apt contacted three; the apt mirrors
are now written once, in `images/devcontainer/install/apt-mirrors.txt`, and the
guard derives its apt implication from that file rather than naming hosts itself.

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
| **agents** | yes | The Codex CLI at the image's pin. Used only where an environment persists and holds its own login (#1406); ephemeral clouds install it and never log in. A persistent environment's login is made once, when the maintainer runs `codex login` on it while provisioning (an agent never does; `AGENTS.md` § Hard Rules), and its `~/.codex/auth.json` is never copied to another machine: the refresh token is single-use, so a copy would invalidate both holders |
| **browsers** | no | Playwright Chromium. Opt-in because it is larger than everything above put together |

`markdownlint-cli2` is in core because `lint:markdown` needs it — it was missing
from the original tier list and the omission was found by running a full dev
loop on the VM.

The browsers tier's "installed" contract is Playwright's own
`INSTALLATION_COMPLETE` marker in each browser location **and** the shared
cache being readable by the unprivileged runtime user — `o+rx` on every entry
under `PLAYWRIGHT_BROWSERS_PATH`, because the tier installs as root while the
session runs as `vscode` or another account. The marker attests the download,
not the permission, so the permission is checked rather than inferred from it:
a complete-looking cache whose permissions were left wrong (an interruption
between the download and the `chmod`, a restrictive umask) is repaired by the
next run with a `chmod` and no re-download. A system dependency removed after
the marker was written is still outside the bootstrap's guarantee, and
re-running the tier does **not** repair that — the marker makes the download
skip — so the remedy there remains to remove the browser's install location (or
just its `INSTALLATION_COMPLETE`), after which the next run reinstalls it with
`--with-deps`.

Never installed, in any tier, and asserted both by the bootstrap and by CI:
**1Password (`op`), Homebrew, Tailscale.** The first and third are
credential-bearing and a shared remote VM must not hold either; Homebrew is a
second, unpinned package manager that would defeat the contract above. The
bootstrap's closing check states one invariant for both the commands (`op`,
`brew`, `tailscale`, `tailscaled`, `PATH`-wide via `command -v`, the form a
consumer cares about) and Homebrew's prefixes (`/home/linuxbrew`,
`/opt/homebrew`): it fails if any of them is present at the end of the run
and was not at the start, and reports by path — without failing — one the
host already had, because a self-hosted VM whose administrator installed
Tailscale, or that already carries a Homebrew prefix, is not the bootstrap
installing either. Both lists are snapshotted at the start and re-read at the
end through the same predicate, so neither can be checked on mere existence.
Neither Docker nor Homebrew is required to *run* the bootstrap.

Interactive-terminal tools (zellij, herdr, starship, the TUIs) stay image-only.

## The entrypoint

`images/devcontainer/bootstrap-remote.sh` is the **only** remote setup script.
Each adapter's setup step is a call to it at a pinned harmon-init
release tag — never a platform-specific copy:

```sh
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
  && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
    -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
  && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
```

The tag is written **once** and read from that one variable: the URL the
script is fetched from and the `--ref` it fetches its install scripts and
`versions.env` from are the same value by construction, and if the script is
ever handed both `--ref` and `HARMON_INIT_REF` it refuses unless they agree.
`--ref` decides where the assets come from, and there is no preference between
the two sources: **given a ref, that tag is the only source** — every asset is
fetched from it and a file sitting beside the script is never read, whatever its
ownership or mode. Omit `--ref` and the files beside the script are used, which
is the form run from a checkout (and the one the `remote-bootstrap` CI job uses
to exercise the working tree's own scripts).

The download is its **own command**, and the script runs only if it succeeded.
Not a stylistic preference: a pipeline's exit status is its *last* command's,
so `curl … | sudo bash` exits **0** when the download 404s or the connection
drops mid-transfer — every adapter copying it would report a successful setup
having installed nothing, and a truncated script has already run as root. `set
-o pipefail` in the adapter would fix it, but a recipe that is only safe when
the caller remembers something is a recipe that will be run unsafely; `curl -o`
plus `&&` propagates the failure by construction. Nothing deletes the temporary
directory: a trailing `rm` would become the chain's exit status and reintroduce
exactly the bug, and a few kilobytes are nothing on a VM that is about to be
thrown away. `scripts/test-bootstrap-remote.sh` § 14 holds this shape in place
— it fails if any copy of the recipe (the bootstrap script's own, this
document's, and that of every guide under `docs/` that carries it, currently the
[Claude Code on the web guide](../guides/claude-code-web.md), the
[Codex cloud guide](../guides/codex-cloud.md) and the
[Sprites guide](../guides/sprites.md)) becomes a bare
pipe into a shell, stops downloading to a file, or stops using a private
directory. The guides are found by the recipe's URL, and the links in this
paragraph must be exactly the guides found: one that carries the recipe and is
not linked here fails, and so does one linked here that no longer carries it.

The script goes into a **private directory** (`mktemp -d`, with mode `0700`
stated rather than inherited from a default), not a bare `mktemp` file in shared
`/tmp`, which would make `/tmp` the script's own directory. Two independent
things now have to be true for root to be handed another user's code, and this
recipe is only one of them — which is why it stays even though it is no longer
the one that holds. The other is the script itself: this form passes `--ref`,
and **given a ref the script reads nothing beside itself**, so a
`/tmp/install/lib.sh` an unprivileged local user pre-created is never consulted,
and its ownership and mode never have to be judged. That is the layer that does
not depend on every adapter copying this recipe correctly — and an adapter
copying it imperfectly is how the recipe's own protection fails on a real host.

Deleting the question was deliberate, and it replaced an
ownership-and-permissions predicate on the script's own directory. That
predicate had to decide whether a directory could be trusted between the check
and the `source`, which is not a decision a shell script can win: it examined
two directories and so could not answer for the path's ancestors (a `0700`
directory inside a world-writable, non-sticky parent can be swapped out from
under it), it examined the container rather than the contents (a mode-`0666`
`install/lib.sh` inside a private directory passed), and the window between
check and use is the swap it was looking for. Not consulting the directory at
all has none of that to answer.

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

It runs as root or under `sudo`, and on **every** entry path — the re-exec of
an unprivileged caller (done under `sudo` with an explicit environment: tiers
and ref as arguments, the `HARMON_*` variables only when set), `sudo -E`, and
the piped `sudo bash -s` — it sets `HOME` to the running uid's passwd home
before any tier runs. `sudo -E` in particular arrives already root with the
*caller's* `HOME`, and without that step npm and uv would leave root-owned
files under the caller's home and the closing locale probe would source the
caller's `~/.profile` as root; the invoking user is still known through
`SUDO_USER` for the shadow check above. It is non-interactive, and is
**idempotent** in a
precise sense: **a second run performs no new installs and changes no pinned
tool version** — no download, no npm or uv install, no corepack shim, no
manifest rewrite, and no rewrite of the files it owns under `/etc` when their
content already matches. The apt packages are deliberately *unpinned* and
converge on the archive: every run refreshes the index and lets apt upgrade
them, and an upgrade is **reported as a change, never hidden**. That is
asserted as counts, not as an exit status — it prints
`HARMON_BOOTSTRAP_NEW_INSTALLS=<n>` and `HARMON_BOOTSTRAP_UPGRADES=<n>` (and
their sum as `HARMON_BOOTSTRAP_CHANGES`), plus
`HARMON_BOOTSTRAP_POSTURE_GAPS=<n>`, the managed paths the agent posture was
not applied to ([below](#the-agent-posture)) — a gap, not a change, so it is
outside that sum. All four are printed at the end of a run, so a run that fails
part-way prints none of them and its nonzero exit status is what reports it.
CI requires `NEW_INSTALLS=0` plus
a byte-identical manifest on the second run, because a script that
re-downloaded and re-installed everything also exits 0.

One residual is stated rather than solved: the bootstrap guarantees `PATH`
precedence for bash and POSIX-sh login shells (the ones that read
`/etc/profile.d`) and for its own process, and can only *report* a user-level
shadow such as `~/.local/bin/yq`, because that user's own profile runs last.
zsh login shells on Ubuntu do not read `/etc/profile.d` at all, so a user
whose login shell is zsh must source `/etc/profile.d/harmon-remote-env.sh` or
put `/usr/local/bin` first on `PATH` themselves.

### The agent posture

Every run, whatever the tiers, installs the **agent posture**
([#1408](https://github.com/evanharmon1/harmon-init/issues/1408)): the agent
Claude Code settings to `/etc/claude-code/managed-settings.json` and the agent
Codex configuration to `/etc/codex/managed_config.toml`, the paths both
harnesses read as managed policy and the ones the agent devcontainer installs
to. It is installed **immediately after `apt-core.sh`** (which provides `jq`,
its one dependency) **and before any tier**, so a tier that fails can never
leave a harness installed on the machine without its managed policy.

- **One definition, no copy.** The only definition is
  `.devcontainer/config/agent/`. From a checkout the bootstrap reads it in
  place; with `--ref` it fetches it from **the same tag** as the install
  scripts, into the same private directory. It carries no copy of its own:
  `scripts/test-bootstrap-remote.sh` § 24 fails if any file under
  `images/devcontainer/` is a copy or a second definition, and runs the install
  to prove it writes files byte-identical to the checked-in ones.
- **One installer.** The install is the definition's own
  `.devcontainer/agent/agent-autonomy.sh`, `apply` and then `verify` — the
  script the agent devcontainer runs — told the posture
  (`FOREMAN_DEVCONTAINER=agent`), the definition's location, and the two
  destinations. `verify` fails the run unless each file the bootstrap wrote
  matches the definition byte for byte. A second run installs nothing.
- **Harness executables are never modified.** In the agent devcontainer
  `apply` also makes every harness the definition refuses non-executable. On a
  platform's VM those executables are the platform's, so the bootstrap runs
  `apply --platform-vm` and `verify --platform-vm`, which handle the two files
  only and say so in the log. It is an argument rather than an environment
  variable so that nothing a repository sets can switch it on in the agent
  devcontainer, whose lifecycle never passes it. Harness refusal on a platform VM is a
  recorded delivery gap, and the platform's own controls are named per
  platform [below](#how-each-platform-receives-the-agent-posture).
- **A file already there is left in place.** `/etc/claude-code/` and
  `/etc/codex/` are created when missing. Anything already at either path that
  is not the definition — a file, or a symlink, dangling or not — may be the
  platform's own managed policy, possibly a stronger control than ours, so by
  default it is **not replaced**: the run reports its path and what it is (its
  SHA-256, or where a symlink points), says the agent posture is **not
  applied** for it, counts it in `HARMON_BOOTSTRAP_POSTURE_GAPS`, and still
  completes. That is a delivery gap for that machine, not a failed run; an
  adapter that must know asserts on the counter, never on the warning text.
  `HARMON_AGENT_POSTURE_REPLACE=1` is the operator's explicit opt-in to replace
  it; the previous entry is then kept beside it as
  `<path>.replaced-<unique suffix>`, a name never used before, so a second
  replacement cannot overwrite the first kept copy. The variable is forwarded
  through the `sudo` re-exec like the other `HARMON_*` settings.
- **Hooks are not delivered.** The definition's hook commands name the agent
  image's hook scripts (`/etc/claude-code/hooks/`, `/etc/codex/hooks/`, and the
  session-end archive hook under `/usr/local/share/devcontainer-config/`). The
  bootstrap installs no hooks — hook guards in remote sessions are deferred by
  [#1402](https://github.com/evanharmon1/harmon-init/issues/1402) — so it warns
  naming each hook command the machine does not have. The permission rules do
  not depend on them. A missing hook command is expected to surface as a
  non-blocking hook error each time the hook fires (expected, not yet
  observed).

What the bootstrap proves is that the files are **installed**. Whether a
platform's harness then **honours** them is a property of the platform, not of
this script, and is recorded per platform under
[How each platform receives the agent posture](#how-each-platform-receives-the-agent-posture).

### The manifest: checking that image and VM agree

At the end of a run the bootstrap writes
`/usr/local/share/harmon-remote-env/manifest.json` (under `HARMON_PREFIX`),
produced by the **same** `generate-manifest.sh` the image runs and in the same
shape (`schemaVersion`, `image.{name,revision,architecture}`, `tools`) plus
`image.tiers`, the tier set the entries were produced from — with
`image.name` set to `harmon-remote-env` and `image.revision` the checkout's
commit — suffixed `-dirty` when that checkout has uncommitted or untracked
changes, so the manifest never attests a clean commit for bytes that were not
that commit — or, for the standalone form, the release tag it was fetched
from (no repository, so never dirty). Its
`tools` are not a list the bootstrap keeps: every pinned tool a tier installs
or verifies records `name=version` as it goes, and the manifest is that record
under the same keys the image's manifest uses. `image.tiers` is there because
that makes the entries ONE RUN's records: `--tiers core` after a
`--tiers core,agents,browsers` run writes fewer tools by design, and without the
field a reader cannot tell that narrowing from a tool having vanished. The
bootstrap's own before/after check reads it, and when the two tier sets differ it
says so and compares only the tools both sets cover instead of reporting the
narrowing as a changed pin. The image build installs its whole toolchain, has no
tier selection to name, and omits the field.
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
| `task test:bootstrap-remote` | `task verify`, and `build.yml`'s `lint` job on every pull request | The pin contract, offline: no second pin owner (declared or typed into a download URL), every pin Renovate-extractable, both Node digests verified for the pinned Node, the fetch list matches the directory, no denied host, no forbidden tool named by the bootstrap or a tier script, a non-release-tag `--ref` is refused, the agent posture comes only from `.devcontainer/config/agent/`, installs byte-identical and idempotent, leaves a file already there in place unless `HARMON_AGENT_POSTURE_REPLACE=1`, never overwrites a kept copy, and changes no harness executable's mode, and no piped or live-prefix `tar` extraction in the bootstrap or a tier script. That last check is shape-based: a dashless `tar xzf`, an `unzip -d`, or a `curl -o` straight onto the live path is not detected, and for those forms the stage-verify-extract-move invariant is enforced by the one install helper in `lib.sh` and reviewed, not proved |
| `remote-bootstrap.yml` → `bootstrap` | CI, stock `ubuntu:24.04` container, seeded with `/usr/bin` ahead of `/usr/local/bin` and `LC_ALL=C` | It runs: the tiers install inside the budget, the second run performs no new installs and leaves the manifest byte-identical, `yq` and `task` resolve from `/usr/local/bin` and the effective locale is UTF-8 in a fresh login shell on the system profile path, a user with `~/.local/bin/yq` planted gets the shadow warning and exit 0 through the un-sudoed re-exec path **and** through `sudo -E` (asserted to enter as uid 0 with that user's `HOME`), each with nothing of root's left in that home and that user's `~/.profile` never executed as root, nothing forbidden appeared on `PATH`, the agent posture is delivered — after the first run both managed destinations are byte-identical to `.devcontainer/config/agent/` and the run printed `HARMON_BOOTSTRAP_POSTURE_GAPS=0` — every VM manifest key names its pin, and `task check` then passes in a harmon-init checkout. Every step that pipes the bootstrap through `tee` runs under `pipefail`, so a bootstrap that dies fails the step it died in |
| `images/devcontainer/smoke.sh` | the built image | The image really runs the shared scripts — they ship in the image beside `versions.env`, and its manifest records their versions for the comparison above |

**The `remote-bootstrap` job is advisory.** It is path-filtered and is not a
required status check (see [branch-protection.md](branch-protection.md)), yet it
is the only end-to-end evidence that the agent posture is delivered on a real
machine: a pull request can merge with it red, or without it having run. Making
it required needs the unfiltered-aggregator shape `devcontainer-verify` uses — a
job that runs on every event and decides internally whether there is anything to
prove — and that is follow-up work, not part of this change.

**The `--ref` posture fetch is not executed by any test or job** until the first
release that carries these files exists: CI runs the bootstrap from its
checkout, and a tag cannot serve files it does not contain. Until then what holds
is § 24 of `scripts/test-bootstrap-remote.sh`, which keeps the fetched asset
list equal to the files on disk and runs the fetch against a stubbed download.

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
| Claude Code on the web | #1407 | [Claude Code on the web](#claude-code-on-the-web) |
| Codex cloud | #750 | [Codex cloud](#codex-cloud) |
| Sprites | #1411 | [Sprites](#sprites) |
| Self-hosted | #1410 | *(pending)* |

### How each platform receives the agent posture

The bootstrap installs [the agent posture](#the-agent-posture) the same way
everywhere. What differs is whether the platform's harness reads what was
installed, and where it does not, what enforces the posture instead. Two gaps
are common to every platform VM: the bootstrap does not refuse harness
executables there, and a managed file the platform put there first is left in
place, with the posture not applied for it, unless the operator opts in with
`HARMON_AGENT_POSTURE_REPLACE=1`. On every platform the posture is installed
immediately after `apt-core.sh` and before any tier, so a failing tier never
leaves a harness installed without its managed policy. Evidence
tags are the guides': **docs** with the date re-read, **observed** with the date
and source, **expected, not yet observed**, and **pending** for a `[HUMAN]`
criterion of [#1404](https://github.com/evanharmon1/harmon-init/issues/1404)
that needs a live session.

| Platform | Delivery | Recorded gap | Evidence |
| --- | --- | --- | --- |
| Claude Code on the web | The setup script's bootstrap writes `/etc/claude-code/managed-settings.json`, creating the directory | The refusals observed in a session (`sudo`, `gh pr merge`, and a `gh api -i -X POST` write) are consistent with the managed file's deny rules being enforced: they carried the permission-rule message form and came without a prompt, unlike the classifier's refusals. The `gh pr merge` refusal predates the agent posture dropping its merge guard ([ADR](../decisions/2026-10-07-bot-and-agent-postures-carry-no-merge-guards.md)): from v5.3.0 the managed file allows `gh pr merge`, so a repeat uses `gh release delete x`, which it still denies. `/permissions` cannot list rules on the web, so this is inferred from behaviour, not shown by a listing. The deny rules are defence in depth, not the write boundary: they match argument patterns (bundled short flags in `gh api` are untested, [#1549](https://github.com/evanharmon1/harmon-init/issues/1549)) and are not transitive, so they do not see what an allowed `task` target or script runs ([ADR](../decisions/2026-09-29-agent-posture-three-posture-model.md)); the boundary is the bot's grants, the token's missing `workflow` scope and the rulesets. They do not cover the session's built-in GitHub tools, which opened, commented on and closed a draft PR as the bot (observed 2026-10-07). The platform's server-side auto-mode classifier is a second, separate layer above it. Harness refusal is not applied; what bounds the session instead is the managed file, the classifier, and that the platform starts Claude Code, not another harness. No hooks | observed 2026-09-27 ([evidence](https://github.com/evanharmon1/harmon-init/issues/1404#issuecomment-5860625696)) for the VM; delivery (the file written and verified) observed 2026-10-06; enforcement inferred from the refusals 2026-10-06/07, criterion 2 ([guide](../guides/claude-code-web.md#the-agent-posture)) |
| Codex cloud | The setup script's bootstrap writes `/etc/codex/managed_config.toml`, creating the directory | Whether the cloud agent reads a managed config written in the setup phase is **unproven**, and no page gives an environment a permission or approval configuration. The Codex configuration has no deny list to lose: it pins `workspace-write` and approval `never`, and the Claude deny list has no Codex equivalent. Harness refusal is not applied; the platform runs Codex and nothing else, inside its per-task isolation. No hooks | docs (legacy), 2026-09-29; delivery expected, not yet observed — pending, criterion 3 ([guide](../guides/codex-cloud.md#the-agent-posture-as-far-as-codex-cloud-can-express-it)) |
| Sprites | The bootstrap, run once per Sprite from `sprite console` at a pinned release tag, then checkpointed ([guide](../guides/sprites.md#provisioning)); the machine is ours, so the files install as they do on any platform VM | The same two gaps as every platform VM apply: the adapter adds no harness refusal and installs nothing beyond the bootstrap, and a managed file already there is left in place unless `HARMON_AGENT_POSTURE_REPLACE=1`. Egress is bounded from outside the VM by the network policy generated from the shared allowlist, which the agent cannot change from inside; that it is still in force is confirmed before each lane by comparing the stored policy with a fresh generation ([guide](../guides/sprites.md#network-policy)), because whether a checkpoint restore reverts it is pending. Codex: the Sprite is persistent, so it holds one login of its own, made once by the maintainer ([agents tier](#tiers)). No hooks | expected, not yet observed — pending, criterion 4 |
| Self-hosted | The same bootstrap, once [#1410](https://github.com/evanharmon1/harmon-init/issues/1410) builds the adapter | The adapter does not exist yet. The same two gaps as every platform VM apply: harness refusal is not applied by the bootstrap, and a managed file already there is left in place unless `HARMON_AGENT_POSTURE_REPLACE=1`. Codex: a self-hosted machine holds at most one login of its own, made once at provisioning ([agents tier](#tiers)). No hooks | expected, not yet observed — pending, #1410 |
| Agent devcontainer | Not the bootstrap: `.devcontainer/agent/post-create.sh` runs `agent-autonomy.sh apply` and `verify` against the image's baked copy of the same definition, and the image installs the hooks; `apply` there also refuses the harnesses the definition refuses | None recorded | the definition is tested by `scripts/test-agent-profile.sh`; in effect in a live session: pending, criterion 4 |

**Pending observation (#1404 criterion 4):** on a Sprite
([guide](../guides/sprites.md)) and in the agent devcontainer, start `claude` and
run `/permissions`: the agent deny rules must be listed. Then ask it to run
`gh release delete x`, which must be refused without a prompt. Run `codex` and check
that `/status` shows `workspace-write` and approval `never`. On the Sprite,
`sudo FOREMAN_DEVCONTAINER=agent
AGENT_AUTONOMY_CONFIG_DIR=<checkout>/.devcontainer/config/agent bash
<checkout>/.devcontainer/agent/agent-autonomy.sh verify --platform-vm` must pass,
where `<checkout>` is a clean checkout at the tag the bootstrap ran; in the
devcontainer, `bash .devcontainer/agent/agent-autonomy.sh verify`. Record the
date and the Claude Code and `codex` versions here.

Observed (Sprite):  *pending*

Observed (agent devcontainer):  *pending*

### Claude Code on the web

One environment for all repos, whose setup script is the entrypoint above at a
pinned release tag and whose network level is **Trusted**. The platform takes no
custom image and ignores `devcontainer.json`, so the setup script is the whole
adapter. Everything specific to the platform — the environment's configuration,
the secrets policy, how its GitHub proxy changes the `gh` calls the dev loop
makes, the terminal-to-cloud bridges, and the observations still owed by a live
session — is in
[docs/guides/claude-code-web.md](../guides/claude-code-web.md).

### Codex cloud

One environment per repository, whose setup script is the entrypoint above at a
pinned release tag. OpenAI documents two generations of Codex cloud, and the
surfaces the platform cares about — cloud reviews and tasks started by a Codex
mention — run in the **legacy** one, which has a setup script and secrets that
are removed before the agent phase; which generation `codex cloud exec` targets
is not stated and is a pending observation. The bootstrap downloads in the
setup phase, which always has internet, so the agent-phase network level is
decided by what the gate does when it runs, not by the host table above.
Everything specific to the platform — the environment's configuration, the
network levels, what a Codex mention starts, the `codex cloud exec` and `apply`
bridge for the implementer lane, and the observations still owed by a
provisioned environment — is in
[docs/guides/codex-cloud.md](../guides/codex-cloud.md).

### Sprites

A paid, opt-in platform: a repository gets anything for it only by answering
`use_fly_sprites: yes` in Copier, which defaults to no and needs the
devcontainer. Each lane runs on a persistent Fly.io Sprite, provisioned from the
operator's machine: `sprite create`, then the entrypoint above runs at a
pinned release tag from `sprite console` and `sprite exec` runs
`task setup:remote` in the checkout, and a
checkpoint taken after that makes the bootstrap run once per Sprite rather than
per lane. The machine is ours, so nothing about the toolchain or the posture is
platform-specific; whether the bootstrap, written for Ubuntu 24.04, completes on
a Sprite's Ubuntu 25.10 is a pending observation. Two things are specific to
the platform. Egress is closed from **outside** the VM by a DNS-based network
policy the agent cannot change from inside — confirmed in force before each
lane by comparing the stored policy with a fresh generation, since whether a
checkpoint restore reverts it is pending. That policy is generated from the
shared egress allowlist by `sprites/network-policy.sh` — the one file harmon-init
ships for Sprites — with `task test:sprites-policy` proving every allowlist
entry the policy can express reaches it, and that the other kinds are a named
limitation (`@github-meta`) or a refusal (an IPv4 address or CIDR). And a Sprite persists, so it holds one Codex login of its
own, made once by the maintainer. The procedure — cost and account, the
provisioning commands, credential delivery, applying and checking the policy,
attaching Herdr, and the observations still owed by a provisioned Sprite — is
in [docs/guides/sprites.md](../guides/sprites.md).
