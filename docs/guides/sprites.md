# Fly.io Sprites

How to run an autonomous remote lane on a Fly.io Sprite: provision it from the
shared bootstrap, deliver its credentials, close its egress to the shared
allowlist from outside the VM, checkpoint it, and attach a Herdr tab to it.
**Nothing here has been observed on a Sprite yet.** Every platform fact below
comes from Fly.io's documentation, and the live checks are the `[HUMAN]`
criteria of #1411, tracked in #1460.

Read this before provisioning a Sprite, when a lane on one cannot reach
something, or when deciding whether Sprites are worth paying for. The contract
every remote environment shares (one bootstrap, the same pins as the shared
image, the agent posture) is
[architecture/remote-environments.md](../architecture/remote-environments.md);
this is the Sprites-specific *procedure*. The hosted counterparts are
[claude-code-web.md](claude-code-web.md) and [codex-cloud.md](codex-cloud.md).

## How to read the evidence in this guide

| Tag | Meaning |
| --- | --- |
| **docs, 2026-10-01** | Stated by Fly.io's Sprites documentation, read on that date: [networking](https://docs.fly.io/sprites/concepts/networking/), [Set Network Policy](https://docs.fly.io/sprites/api/network-policy/set-network-policy), [CLI commands](https://docs.fly.io/sprites/cli/commands), [CLI authentication](https://docs.fly.io/sprites/cli/authentication), [checkpoints](https://docs.fly.io/sprites/concepts/checkpoints) |
| **pricing, 2026-10-01** | Stated by [fly.io/sprites](https://fly.io/sprites) and [Fly.io resource pricing](https://docs.fly.io/about/pricing), read on that date |
| **research, 2026-09-28** | [docs/research/self-hosted-cloud-environments.md](../research/self-hosted-cloud-environments.md), which records a Fly.io staff statement |
| **expected, not yet observed** | Derived from the docs or from how a script is written. **Not** an observation |
| **pending** | Needs a provisioned Sprite and the maintainer; listed under [Pending observations](#pending-observations) |

Nothing here is tagged *observed*. The `sprite` CLI is not installed in the
devcontainer, and nothing in `task verify` creates a Sprite: CI proves only that
the network policy is derived from the shared allowlist.

## Cost and account: a paid, opt-in platform

Sprites need a **paid Fly.io account**, so harmon-init ships nothing for them
unless a repository answers `use_fly_sprites: yes` in Copier (default **no**;
it also needs `devcontainer`, because the allowlist lives there).

- **A credit card on file.** "All organizations (except for Linked
  Organizations) require a credit card on file"
  ([Fly.io resource pricing](https://docs.fly.io/about/pricing), read 2026-10-01;
  [fly.io/sprites](https://fly.io/sprites) does not state it).
- **Trial credit.** "New organizations get $30 in trial credit", one per
  organization (*pricing, 2026-10-01*).
- **Billed while running, storage while idle.** CPU at $0.07 per CPU-hour,
  memory at $0.04375 per GB-hour, hot storage at $0.000683 per GB-hour while
  awake and cold storage at $0.000027 per GB-hour; a Sprite is billed while
  *running* and not while *warm* or *cold*, and goes from running to warm
  within seconds of having nothing to do (*pricing, 2026-10-01*). A warm or
  cold Sprite keeps its disk and its storage bill: "A sprite that exists but
  does nothing costs nothing beyond its storage" (*pricing, 2026-10-01*), so
  it pays for storage until it is destroyed.
- **Public and private repositories alike.** Fly.io's terms do not
  distinguish them: the Sprite holds whatever the agent's token can read.

## What harmon-init ships for Sprites

One file, `sprites/network-policy.sh`, rendered only with `use_fly_sprites`. It
generates the Sprite's network policy from the shared egress allowlist and
applies it from outside the VM ([Network policy](#network-policy)). There is no
Sprite-specific bootstrap: provisioning runs the **shared** bootstrap at a
pinned release tag, like every other platform.

## Provisioning

Run every step from the operator's machine with the `sprite` CLI signed in to
the paying organization (`sprite org auth`; *docs, 2026-10-01*). `SPRITE` is the
Sprite's name and `OWNER/REPO` the repository the lane works on.

**1. Create the Sprite** without opening a console (*docs, 2026-10-01*):

```sh
sprite create --skip-console "$SPRITE"
```

**2. Run the shared bootstrap at a pinned release tag.** Open
`sprite console -s "$SPRITE"` and run the entrypoint from
[architecture/remote-environments.md § The entrypoint](../architecture/remote-environments.md#the-entrypoint),
unchanged. No release carries the bootstrap yet, so `vX.Y.Z` is a placeholder
until one does; the bootstrap refuses any ref that is not a release tag. It
runs before the network policy, as a cloud platform's setup phase does, because
the toolchain downloads are not all on the allowlist.

```sh
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
  && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
    -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
  && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
```

**Open item — the base image.** The bootstrap targets a stock Ubuntu 24.04 VM.
A new Sprite runs Ubuntu 25.10 and cannot take a custom base image
(*research, 2026-09-28*). Whether the bootstrap completes on 25.10 is
**pending**; nothing here claims it does. If it does not, the fix belongs in the
shared bootstrap, never in a Sprite-specific copy. That `sudo` is available
without a password on a Sprite is **expected, not yet observed**.

The bootstrap installs the agent posture as it does on every platform VM, and
the two platform-VM gaps apply unchanged: harness refusal is not applied, and a
managed file already present is left in place unless
`HARMON_AGENT_POSTURE_REPLACE=1`
([how each platform receives the posture](../architecture/remote-environments.md#how-each-platform-receives-the-agent-posture)).

**3. Close egress** to the shared allowlist, from outside, before any credential
or agent reaches the Sprite: see [Network policy](#network-policy).

**4. Deliver the credentials** (next section). Before the checkpoint, confirm each
arrived — an empty file would be checkpointed as if it were a credential:
`sprite exec -s "$SPRITE" -- bash -lc 'gh auth status && test -s "$HOME/.config/harmon-agent/claude-oauth-token"'`.

**5. Clone the repository and prepare the checkout:**

```sh
sprite exec -s "$SPRITE" -- bash -lc \
  'gh repo clone OWNER/REPO "$HOME/REPO" && cd "$HOME/REPO" && task setup:remote'
```

`task setup:remote` installs the git hooks and the lockfile's dependencies and
clones the related repositories beside the checkout.

**6. Checkpoint**, so the bootstrap and the preparation run once per Sprite, not
once per lane (*docs, 2026-10-01*):

```sh
sprite checkpoint create -s "$SPRITE" --comment "bootstrap vX.Y.Z + setup:remote"
```

A checkpoint captures the writable filesystem — installed packages, the
checkout, and the credential files of step 4 — and not running processes.
`sprite restore -s "$SPRITE" <version>` returns to it, and terminates every
session on the Sprite. A process inside the Sprite can also restore its own
checkpoints (`sprite-env`), so a checkpoint is a reset point, not a control
boundary; the network policy is the control, because it cannot be changed from
inside (*docs, 2026-10-01*). Whether a restore reverts it is not documented
([pending](#pending-observations)), so the guarantee is keyed to state, not to
events: before a lane starts or is attached, run `apply` and confirm the stored
policy equals `generate`'s output ([Network policy](#network-policy)).

**7. The maintainer's one Codex login** (below), after the checkpoint.

## Credentials

Three credentials, each delivered **once per Sprite, from outside**, on stdin:
never committed, never logged, never on a command line (an argument is visible
in a process listing, so `sprite exec --env` is not used for them). The
examples read from 1Password with `op read`; any secret store works, and nothing
here writes to one.

That `sprite exec` without `--tty` passes its stdin to the command is
**expected, not yet observed**: the docs describe exec, not its stdin.

- **The agent PAT** (`AGENT_GH_TOKEN`; see
  [bot-account.md](bot-account.md#the-agent-pat-the-agent-postures-own-token)),
  never the bot's own `GH_TOKEN`. `gh` reads it from stdin and stores it:

  ```sh
  op read "op://<vault>/<item>/<field>" |
    sprite exec -s "$SPRITE" -- bash -lc 'gh auth login --with-token && gh auth setup-git'
  ```

- **`CLAUDE_CODE_OAUTH_TOKEN`**, written to a file only its user can read. The
  lane's launcher exports it from there:

  ```sh
  op read "op://<vault>/<item>/<field>" |
    sprite exec -s "$SPRITE" -- bash -c \
      'umask 077 && mkdir -p "$HOME/.config/harmon-agent" && cat >"$HOME/.config/harmon-agent/claude-oauth-token"'
  ```

- **The Sprite's own Codex sign-in.** A Sprite persists, so it holds exactly one
  Codex sign-in of its own (`AGENTS.md` § "Remote environments"). The maintainer
  makes it by hand: open `sprite console -s "$SPRITE"` and sign the Codex CLI in
  there, once. No script does it and an agent never does. The credential stays
  on that Sprite and is never copied to another machine: its refresh token is
  single-use, so a copy would invalidate both. A restore to a checkpoint taken
  before the sign-in removes it, and the maintainer signs in again.

`task test:remote-codex-policy` scans `sprites/` as a strict provisioning
surface, so no Codex credential handling can be added there.

## Network policy

A Sprite's outbound traffic is unrestricted by default. A **network policy** is
a DNS-based allowlist, set from outside the Sprite through the Sprites API and
read-only inside it at `/.sprite/policy/network.json`. A domain the policy does
not allow answers DNS `REFUSED`; a raw-IP connection is refused unless the
address was resolved from an allowed domain; private addresses are always
refused; and a change reloads live, dropping existing connections to domains it
newly blocks (*docs, 2026-10-01*).

The policy is **generated** from the shared egress allowlist
(`.devcontainer/egress-allowlist.txt` plus the optional per-repository
`.devcontainer/egress-allowlist.local.txt`), through the one parser of that
format, `egress-allowlist.sh hosts`. It is never maintained separately and
never checked in. Generate it to read it:

```sh
bash sprites/network-policy.sh generate
```

Apply it to a Sprite, from the operator's checkout, with a Sprites API token for
the organization ([sprites.dev/account](https://sprites.dev/account);
*docs, 2026-10-01*) on stdin:

```sh
op read "op://<vault>/<item>/<field>" | bash sprites/network-policy.sh apply "$SPRITE"
```

`apply` sends `POST https://api.sprites.dev/v1/sprites/<name>/policy/network`
with the generated rules (*docs, 2026-10-01*). It hands the token to `curl` on
its stdin, so the token appears in no argument list. Run `generate` and `apply`
from a checkout of the default branch (or the pinned release tag), never from a
lane's branch, so an allowlist edit an agent pushed cannot widen its own Sprite
before it is reviewed and merged. Re-run `apply` whenever either list changes.

**Before a lane starts on the Sprite, or a Herdr tab is attached to it,** run
`apply` and confirm that the stored policy equals a fresh generation. The check
reads the Sprite's state, so it holds whatever a checkpoint restore did to the
policy and whether `apply` replaces or merges an earlier one — both
[pending](#pending-observations):

```sh
diff <(bash sprites/network-policy.sh generate | jq -S .) \
     <(sprite exec -s "$SPRITE" -- cat /.sprite/policy/network.json | jq -S .)
```

How each allowlist entry maps:

| Allowlist entry | Sprite policy | Why |
| --- | --- | --- |
| `<hostname>` | `{"domain": "<hostname>", "action": "allow"}`, in list order | The policy is domain-based |
| `@github-meta` | **no rule** — a named limitation, announced on stderr at every generation | It stands for GitHub's published IP ranges, which the devcontainer's address-based filter needs. A DNS-based policy has no address rules and needs none: an address resolved from an allowed GitHub hostname passes, and those hostnames are on the list |
| `<a.b.c.d>[/n]` | **generation fails**, naming the entry | The policy cannot express an address, and a Sprite refuses raw-IP connections that no allowed domain resolved to. List the hostname the address serves instead |

The policy ends with `{"domain": "*", "action": "deny"}` and never includes the
platform's `defaults` preset: the shared list is the only source.
`task test:sprites-policy` proves that every entry the policy can express
reaches it, that the other kinds are a named limitation (`@github-meta`) or a
refusal (an address entry fails generation rather than being dropped), and that
a policy with a missing, extra or changed rule fails the comparison.

## Attaching Herdr

A lane in a Sprite is a Herdr tab whose pane runs `sprite console -s "$SPRITE"`,
so the orchestrator reads and prompts it like a local lane
([herdr.md](herdr.md)). `Ctrl+\` detaches and leaves the session running;
`sprite sessions` and `sprite attach` reconnect (*docs, 2026-10-01*). The
alternative is SSH, with `sprite proxy --ssh -s "$SPRITE"` as the
`ProxyCommand` (*docs, 2026-10-01*).

How an orchestrator launches the lane into that tab is out of scope here
(evanharmon1/harmon-devkit#1215); so is running Claude Code self-hosted
environments on a Sprite (#1410).

## Pending observations

| Observation | Where it is decided |
| --- | --- |
| A Sprite provisioned from the steps above runs `task verify`, and as an implementer lane returns its work to the orchestrator with no human step after provisioning | #1411 criterion 4, tracked in #1460 |
| A Herdr tab attached to that Sprite shows the lane's agent, and the orchestrator can prompt it and read its output | #1411 criterion 5, tracked in #1460 |
| The bootstrap completes on the Sprite's Ubuntu 25.10, and `sudo` works without a password | the criterion-4 run |
| `sprite exec` without `--tty` passes stdin through, for the credential steps | the criterion-4 run |
| The agent posture is in effect in a session on the Sprite | #1404 criterion 4 ([pending observation](../architecture/remote-environments.md#how-each-platform-receives-the-agent-posture)) |
| `/.sprite/policy/network.json` equals a fresh `generate` after `apply` | the criterion-4 run |
| Whether restoring a checkpoint — which a process inside the Sprite can do — reverts the network policy; the docs do not say | the criterion-4 run |
| Whether `apply` replaces the stored policy or merges with an earlier one; the docs do not say | the criterion-4 run |
