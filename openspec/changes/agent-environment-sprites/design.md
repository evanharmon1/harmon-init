## Context

See proposal.md - Why for the motivation and
[docs/research/remote-implementer-environments.md](../../../docs/research/remote-implementer-environments.md)
for the evidence. The facts that shape this design, all read from primary
sources on 2026-09-05 (URLs in the research note's Sources section):

- **A sprite is a Firecracker microVM with a fixed Ubuntu 25.10 base image.**
  Fly.io staff on the community forum: "Right now you can't use a custom
  base image. But we're looking into the idea of forking from a sprite."
  Fly's own engineering post says the standard container for every sprite
  is what lets them keep pools of empty sprites standing by. This is the
  single fact the design has to bend around: the maintainer's intent —
  same image, same tooling, same bootstrap as the bot devcontainer — cannot
  be met by booting the image.
- **Docker runs inside a sprite, but unofficially.** A community thread
  installs `docker-ce` from Docker's apt repository and starts `dockerd`
  by hand; Fly staff confirmed they had run Docker in sprites. Sprites have
  no systemd, so long-running daemons are sprite **Services**
  (`sprite-env services create`), which auto-start on boot and survive a
  warm wake.
- **Persistence and sleep.** Each sprite has 100 GB of persistent ext4
  storage backed by NVMe cache and object storage; the filesystem survives
  everything short of `destroy`. After about 30 s idle a sprite goes
  `warm` (VM suspended, memory frozen, 100–500 ms resume, processes continue
  where they were) and later `cold` (memory dropped, 1–2 s wake, processes
  start fresh). Open TCP connections drop on any pause. A **Task** holds a
  sprite active for up to one hour per registration, renewed by heartbeat.
- **Checkpoints** capture the whole writable filesystem (not memory or
  processes), are copy-on-write, restore asynchronously and destructively
  (active sessions are terminated), and are mounted read-only under
  `/.sprite/checkpoints/` (last five). The docs describe no way to seed a
  new sprite from another sprite's checkpoint.
- **Sessions.** `sprite exec --tty` and `sprite console` run over
  WebSockets; every TTY session is detachable (`Ctrl+\`,
  `sprite sessions list|attach|kill`). Sessions do not survive hibernation.
  There is no SSH server; the documented workaround installs
  `openssh-server` as a Service and tunnels with
  `sprite proxy -s <name> -W 22` as an SSH `ProxyCommand`.
- **Networking.** Outbound is unrestricted by default; a DNS-based
  allowlist policy is set through the API, reloads live, blocks raw-IP
  connections not resolved through an allowed domain, always blocks private
  IPs, and is read-only inside the sprite.
- **Auth and secrets.** The CLI and API use **org-scoped** tokens
  (`SPRITES_TOKEN`, `sprite auth setup --token`, keyring or
  `~/.sprites/sprites.json`); there is no sprite-scoped token. **Connectors**
  keep a GitHub OAuth or API-key credential in Fly's gateway so the sprite
  never sees it — but the gateway proxies API calls, not `git push`, so it
  does not replace `GH_TOKEN` for pushing.
- **Sizing and price.** The lifecycle doc states 8 vCPUs per sprite with
  memory managed by the platform; the JS SDK exposes `cpus`/`ramMB`/`region`
  creation fields the API reference does not document. Pricing is
  $0.07/CPU-hour, $0.04375/GB-hour of memory, $0.000683/GB-hour hot and
  $0.000027/GB-hour cold storage, nothing per sprite, nothing while asleep;
  one $30 trial credit per user; paid plans raise concurrency and creation
  rate (pay-as-you-go creates 10 sprites/minute; the exact pay-as-you-go
  concurrency ceiling is unverified).
- **What the bot devcontainer needs from its host.** `initializeCommand`
  runs `init-env.sh` on the host to compose the env-file from an allow-list;
  `postCreateCommand` runs `post-create.sh` (ownership fixes, git identity,
  `gh auth setup-git`, Herdr integrations, Claude settings seed,
  `bot-autonomy.sh apply` then `verify`); `postStartCommand` runs
  `post-start.sh` (`verify` before the conductor block); `runArgs` add
  `--init`, `--shm-size=2g`, `--env-file`; features add Python,
  docker-in-docker, and the GitHub CLI; twelve named volumes persist agent
  state. All of that is devcontainers-CLI semantics, not image content.
- **Herdr's contract for remote work** already exists in
  `docs/guides/herdr.md`: an orchestrator drives pane workers with
  `pane run` / `agent prompt` / `pane wait-output` on a per-attempt
  sentinel, harvests a file report, verifies ground truth itself, and
  retires what it created; `herdr --remote <ssh-target>` attaches a thin
  client to a Herdr server over SSH (verified against Coder's
  `coder ssh --stdio` ProxyCommand).
- **Foreman's written design** (ponderousdev/foreman `specs/foreman-v2.md`)
  D5 says "Sprites do not run Docker" and D6 says "Fly boots OCI images as
  a microVM root filesystem … the DinD binaries inside are inert weight".
  Both sentences describe **Fly Machines**, which do boot OCI images; they
  do not describe Sprites as shipped in 2026. foreman#30's scope — create a
  Machine from the pinned image, poll for exit code, exec, stop rather than
  destroy — is the Machines API. And Machines cannot boot this image
  either: "Machines have an 8GB rootfs limit" (Fly troubleshooting docs),
  while the shared image is 8.36 GB uncompressed and the built bot profile
  9.26 GB (`docker images` in this checkout).

## Goals / Non-Goals

**Goals:**
- Reproduce the bot devcontainer in a sprite **bit-for-bit where the
  platform allows**: same pinned image, same `devcontainer.json`, same
  `post-create.sh`/`post-start.sh`, same fail-closed `bot-autonomy` gate —
  so a lane cannot silently run a different policy than the local bot
  container.
- Keep the Herdr pane-worker loop unchanged: a lane is a pane whose process
  is the sprite session; brief, sentinel, report, harvest, and retire work
  exactly as for a local worker.
- Narrow, not widen, the credential set relative to the local bot
  container, and keep the one new credential class (the Sprites org token)
  on the orchestrator's side only.
- Make idle free and cost visible: hold the sprite awake only while work
  runs, and put every lane's age in one audit command.
- Say plainly where Sprites cannot meet a requirement and what the
  alternative is, rather than papering over it in the spec.

**Non-Goals:**
- A native sprite image, a slim image, or a sprite-side toolchain — one
  agent image (foreman D6) is the rule this design keeps.
- Foreman's runner implementation, or changing foreman's D5/D6 from this
  repository — filed as follow-ups in ponderousdev/foreman.
- Human (`dev/`) profile lanes; multi-region placement; GPU; a self-hosted
  sprite runtime.

## Decisions

**Nested devcontainer inside the sprite, vs. a native bootstrap of the
sprite's Ubuntu from the Dockerfile pins, vs. Fly Machines booting the
image.** Chosen: nested. The native bootstrap would be a second maintained
toolchain — every `# renovate:` pin in `images/devcontainer/Dockerfile`
reproduced in a script, drifting on the first bump — which is exactly what
foreman D6 forbids ("never a separately maintained image"), and it would run
`post-create.sh` against a different base OS and user than the one it was
written for. Fly Machines boot the image directly and satisfy the intent
most literally, but give up what makes Sprites the better *interactive*
environment: automatic sleep with memory preserved, persistent disk that
costs nothing per sprite, detachable sessions, filesystem checkpoints, and
a DNS egress policy without building any of it. Nesting keeps the image and
the whole devcontainer lifecycle (the devcontainers CLI runs
`postCreateCommand` and `postStartCommand` for real, applies the features,
mounts the named volumes as Docker volumes on the sprite's disk) and pays
for it with one unofficial dependency: Docker in a sprite. That dependency
is the design's biggest risk (below) and is why Fly Machines is named as the
alternative rather than dismissed. The shape is the one the repository
already runs on Coder — outer host with Docker, inner devcontainer, attach
to the inner agent — so the documentation and the mental model carry over.

**Pool of pre-initialised sprites with a golden checkpoint, vs. bootstrap
per lane, vs. keeping one long-lived sprite per issue.** Chosen: pool +
golden checkpoint. A per-lane bootstrap re-pulls a ~13 GB image and re-runs
`post-create.sh` every time (minutes, plus egress); a long-lived sprite per
issue accumulates state and credentials across lanes. Because a checkpoint
cannot seed a new sprite, the pool is the only way to amortise the pull:
each pool sprite is bootstrapped once, checkpointed clean, and every lane
starts from that checkpoint. The pool is small (the ceiling mirrors the
plan's concurrency), owned by the operator, and re-initialised — not
patched — whenever its golden stamp (the image pin, the hash of the lane
helper and its in-sprite supervisor, and the pinned devcontainers CLI
version) no longer matches the current tree, so a lane's toolchain and
outer-host tooling are always the ones the repository ships; an image pin
alone would miss a helper or supervisor change the checkpoint baked in. If Fly ships fork-from-sprite, the pool collapses to one golden
sprite; nothing else in this design changes.

**Golden checkpoint before credentials, restore before every lane.** A
checkpoint captures every file; taking it after `gh auth setup-git` or the
Codex login would freeze a credential into something the audit does not
track and rotation cannot reach. Restoring before every lane is what makes
"a lane never inherits a sibling's files or tokens" a mechanism rather than
a hope, and it is cheap (metadata shuffle, per Fly's engineering post).

**Credentials: the bot profile's own allow-list, delivered through the
devcontainer's own lifecycle, plus one new exclusion.** The inner container
is the same bot profile, so it gets its env-file the way Coder populates
it: the lane's allow-listed variables are present in the environment of
the `devcontainer up` the lane helper runs inside the sprite, and the
profile's own `initializeCommand` (`init-env.sh`) captures them from that
host environment into the env-file before the container is created. The
lane's list is explicit and narrower than the profile's own
`initializeCommand` list, which also carries `FOREMAN_AGENT_GH_TOKEN` and
`AGENT_DECK_TELEGRAM_KEY`; the helper passes exactly `GH_TOKEN`,
`CLAUDE_CODE_OAUTH_TOKEN`, and the opted-in provider keys rather than
forwarding whatever the orchestrator's environment or the profile allows,
so a lane never inherits a credential it has no use for. That is the only order that works with
the profile unchanged — `initializeCommand`, the `--env-file` in `runArgs`,
and `postCreateCommand` (which runs `gh auth setup-git` and the sibling
clones) all execute inside `devcontainer up`, so a credential injected
after the container starts would leave post-create unauthenticated. The
Codex login is the one credential copied after the container is up,
because it lives on the `~/.codex` volume rather than in the environment.
The checkout comes first, on the outer host: the devcontainers CLI reads
`.devcontainer/` from the workspace folder it is given and bind-mounts that
folder into the container, so the lane clones the remote branch head to
`/workspaces/<repo>` on the sprite before `devcontainer up`, with the PAT
handed to git through the credential helper's environment and never
written to disk. The same rule makes pool initialisation work for a
private repository: the clone the profile build needs is made with the
PAT in memory, the containers are torn down, and the checkout — env-file
and all — is removed before the golden checkpoint, which is defined by
its content (no credential, no checkout) rather than by when it was taken.
Two consequences follow. First,
the exfiltration prize inside a lane is the same as inside the local bot
container — the scoped bot PAT and a spendable Claude OAuth token — and the
research note records the same shorter-lived alternatives foreman#30 weighs
(per-lane GitHub App installation tokens, `billing = "api"` with a capped
key) as follow-ups, not defaults. Second, the **Sprites org token is the
one credential this environment adds and it must not enter any lane**: a
lane holding it could `sprite exec` into its siblings, which recreates the
"panes are not a security boundary" problem the microVM exists to solve.
The Codex login is copied as `~/.codex/auth.json` (the Codex docs document
exactly this for containers) rather than device-code auth, so lane creation
needs no human step. Sprites Connectors were considered for GitHub and
rejected for now: the gateway proxies API calls, not git over HTTPS, so it
cannot carry `git push`; it may still be worth using for `gh`-only lanes
later.

**Claim, then restore to completion, then everything else.** A checkpoint
restore is asynchronous and terminates active sessions; a lane that
proceeded while one was in flight would have its own clone or container
erased. The helper therefore polls the platform until the restore reports
complete and refuses to continue on a timeout — leaving the lease in a
`restoring` state that every later entry command checks against the
platform, so a half-restored lane is never entered and a timed-out
`lane:new` resumes at the wait rather than restoring twice. Before the
restore it claims
the sprite: a lease (owner, lane, pool sprite name, issue, expiry) written
to the sprite's labels under the orchestrator-side lane lock. Labels only
record the lease; the lock arbitrates, which is why one pool is driven
from one orchestrator at a time (an explicit precondition of the lane-lock
requirement, with a shared pool as the named follow-up), and why an
expired lease is reclaimed only by `sprite:audit --reclaim` after
confirmation rather than silently by the next lane. Reclaim is not a
second procedure: it is `lane:rm` invoked by the audit owner on an expired
lease, with the same lane lock held for the same span, the same
cleanliness gate, and the same `--force`. The lease is renewed by every
authenticated activity and by `lane:extend`, and never expires before the
lane's TTL, so a long-lived valid lane is never mistaken for an abandoned
one.

**One orchestrator-side `flock` per sprite, and nothing else.** Two review
rounds hardened the order "closing mark, then activity check, then
restore"; the next replaced it with a lock plus a persistent closing state
plus a session registration made before the session existed; the round
after that found a seam in each of those three. Every extra piece of state
is a new thing to leave half-written, so the design keeps exactly one
primitive. The lane lock is an advisory `flock` on a per-sprite lock file
in the orchestrator's lane state directory, keyed by the pool sprite's
platform name — sound because one orchestrator drives a pool at a time,
now stated as the requirement's precondition rather than an aside; `flock`
itself is a stated prerequisite (util-linux on Linux, `brew install flock`
on macOS) that the helper checks before any platform call, because a
home-grown lock is exactly the kind of mechanism this design refuses to
grow. Labels record the lease and never arbitrate. The platform's session
list is the only authority on activity; the identifiers the helper caches
after creating a session are discarded on reconcile when the platform no
longer lists them, so a finished detached command can never block a
retirement through a stale record. There is no closing state: an ending
operation holds the lock from its first check until the golden restore has
completed and the lease is released, so a refused retirement releases the
lock with nothing changed and the lane is usable at once, and anything
that would start a command while the lock is held refuses immediately
with `retiring <lane>` rather than blocking behind a multi-minute restore.
There is no provisional registration: startup holds the lock only long
enough to create the platform session and record its identifier, so a
crash mid-startup leaves at worst a real session, which the activity check
already reads from the platform. `lane:extend` takes the same lock and
writes TTL and lease together. The review's interleavings are carried into
the offline test as named cases driven deterministically against a stubbed
`flock`.

**Egress: allowlist first, credentials second.** The default is
unrestricted; a lane sets the DNS allowlist before any secret exists in the
sprite, so a prompt-injected agent cannot post the bot PAT anywhere the
policy does not name. The one phase that needs package hosts — installing
`openssh-server` into the inner container — brackets the install with two
policy writes that add and then remove `archive.ubuntu.com` and
`security.ubuntu.com` (the shared image's `ubuntu.sources` URIs), with
`apt-get update` restricted to the Ubuntu sources so the image's
third-party lists are never fetched, and the restoring write runs on every
exit path of that step (a trap on failure and interruption), so a failed
install never leaves the wide policy behind; baking `openssh-server` into
the shared image removes the phase entirely and is the named follow-up.
The list is repository-owned and reviewed; the sprite cannot widen it.
Private IPs are blocked by the platform. The list itself is not written
by hand: the feasibility spike runs the whole unconditional loop under a
deny-by-default policy and records every host it needed, which is the
only way to get Semgrep's rule registry and API right rather than guessing
them. The known starting points for that run are `github.com`,
`api.github.com`, `ghcr.io` and the GitHub content and package hosts they
redirect to, the npm and PyPI registries, `api.anthropic.com`, the Codex
CLI's ChatGPT backend, Convex's local-backend release host, and
`semgrep.dev` for Semgrep's registry — starting points, recorded and then
replaced by what the spike actually observed.

**Herdr topology: pane-process-is-the-session for orchestration,
`herdr --remote` for takeover.** The orchestrator's `herdr agent …`
commands act on its own server, so the orchestration loop needs the remote
agent to be visible in a **local** pane: the pane's foreground process is
`sprite exec --tty` into the inner container running the harness. Herdr
classifies agents from the terminal stream, so the same rendering that
identifies a local `claude` identifies a remote one; where it does not
(`unknown`), the file report and per-attempt sentinel are the contract the
Herdr guide already prescribes. For a human taking a lane over with the
full Herdr UI, a Herdr server runs inside the inner container and the
operator attaches with `herdr --remote` through an SSH alias whose
`ProxyCommand` is `sprite proxy -s <pool-sprite> -W <inner-address>:22`,
generated from the leased pool sprite's platform name (the lane name is
only the helper's key) — the
proxy's `-W [host]:port` form reaches a host inside the sprite's network,
and the inner container's bridge address is such a host — to an SSH server
the helper installs **inside the inner container** after `devcontainer up`.
An SSH server on the outer sprite was considered and rejected: the outer
filesystem deliberately holds no Herdr, so a session landing there has
nothing to attach to, and a forced-command bridge through `docker exec`
is a second mechanism to get wrong. Authentication is public-key only
with a per-lane keypair generated on the orchestrator (the private half
never enters the sprite), the container's host key is recorded in the
alias at creation so the connection is pinned rather than trusted on
first use, and both are removed at retirement — the platform's proxy
authenticates the operator to the sprite, but not to the container, so
the container's sshd must not be weakened to make the hop work.
Reconciliation is idempotent across container identity: a recreated
container gets sshd reinstalled, `authorized_keys` regenerated from the
lane's public key, and its new host key re-pinned through the same
`sprite exec` channel used at creation, never trust-on-first-use over
SSH. The helper refreshes the alias's
address on every reconcile because the container's address can change
across restarts — and the alias does not wait for a reconcile to happen
to it: its `ProxyCommand` is the helper's `lane ssh-proxy`, which runs the
same reconcile as every other entry (wake, restart the container, refresh
the address, re-pin on identity change, under the same lock refusals) and
only then execs `sprite proxy`, so a cold lane is taken over without a
prior lane command. Takeover is a UI, not a side door: inside the lane
every registered harness resolves on `PATH` to the supervisor wrapper (the
image already puts `~/.local/bin` first for the Antigravity wrapper's
sake), so whether an agent is launched by `lane:exec`, by `agent start`
through the in-container Herdr server, or by a human typing its name in a
remote pane, it runs with the duration bound, the TTL and grace, and the
platform-visible registration — the activity authority sees every agent,
and nothing launched through takeover can outlive or escape the lane's
rules. Both attach paths are marked for verification in the
first real lane; the version-match prompt `herdr --remote` shows on a
mismatch installs into `~/.local/bin`, which on the container's volume
persists, so it prompts once per pool sprite rather than per rebuild.

**Cold wake: reconcile on every entry.** A cold pause stops every process,
including the inner container and its Herdr server; only `dockerd` comes
back on its own (a Service). Rather than a second Service that races
`dockerd` to restart the container, every `lane:exec`/`attach`/`harvest`
first reconciles: `devcontainer up` is idempotent, reuses the existing
container, and reruns `post-start.sh` — so `bot-autonomy.sh verify` gates
the restart exactly as it gates a local container start — then the Herdr
server is restarted if one was running. A failed `verify` fails the entry
and runs nothing.

**Cost controls: activity lives in the sprite, TTL stops new work, ceiling
on the pool.** The invariant is that the sprite stays active exactly while
a lane command runs, whether or not anything on the orchestrator's machine
is alive. The mechanism is in-sprite by construction: the platform counts a
running exec session as activity, so a gate or agent launched through
`lane:exec` keeps the sprite awake for its own lifetime and lets it sleep
when it exits; where a Tasks-API hold is needed at all, its owner is an
in-sprite supervisor wrapping the command, never a heartbeat on the laptop
— a laptop heartbeat is precisely what dies when a pane is closed while
the remote gate keeps running. No lane command runs unbounded: the in-sprite supervisor applies a
per-command duration bound and stops the command with its output intact,
so a hung agent or a stalled fetch cannot keep the sprite active
indefinitely. The TTL the supervisor enforces is read from lane-local
state inside the sprite — a file the helper writes over `sprite exec`
under the lane lock, with the lease's TTL only a mirror — because a
supervisor that only knew the TTL it was launched with could never see an
extension; `lane:extend` writes that file before the lease so a running
command observes the new deadline. At TTL expiry the helper stops registering holds, refuses
new commands until `lane:extend`, and gives a running command one grace
period before stopping it the same way — so a lane's active compute is
bounded by TTL plus grace — but never destroys anything: stopping a
command preserves the checkout, the container, and the volumes, and the
Herdr guide's rule that sweeping is the operator's step still holds.
Reclaiming an expired lease is retirement under the same lane lock, held
for the same span, and the same cleanliness gate — which enumerates every
checkout under `/workspaces`, not only the primary, because related-repo
bootstrap is disabled in lanes but an agent can still clone — because an
expired lease is bookkeeping, not evidence that the work inside is
finished or that it was pushed. The pool ceiling
mirrors the plan's concurrency limit so `pool:init` cannot walk the account
into "concurrent sprites exceeded" errors mid-dispatch.

**Selection: explicit `--env sprite`; `.foreman.toml` `runner` for Foreman;
labels select nothing.** Consistent with AGENTS.md: `rigor:*`/`strategy:*`
labels are advisory and arm nothing, and `foreman:*` plus `.foreman.toml`
remain the only arming and runner-selection surface. This change only
documents what `runner = "sprite"` will mean.

**Foreman: record the D5/D6 mismatch, do not resolve it here.** Foreman's
sprite runner as written (boot the OCI image, no daemon) is a Fly Machines
runner, and Fly Machines cannot boot this image today (8 GB rootfs limit
against a 9.26 GB built profile). Two honest options exist — supersede D5
and implement the runner against the Sprites API around the nested lane
above, or slim the image under 8 GB (foreman#33) and implement it against
the Machines API as foreman#30 literally describes — and the choice belongs
to the foreman repository. The research note recommends the first because
it gives Herdr dispatch and Foreman one lane recipe and one image, and
because the Sprites API already carries the egress defence foreman#31
wants; the lane helper here exposes create/exec/wait/harvest/retire
primitives so a Sprites-backed runner can shell to them or reimplement them
over the API.

## Risks / Trade-offs

- [Docker inside a sprite is community-verified, not a documented
  feature] → The first real lane (`[HUMAN]` on harmon-init#1120) is the proof; the
  helper fails loudly if `dockerd` does not come up. If Fly withdraws it,
  the fallback is Fly Machines booting a bot image slimmed under the 8 GB
  rootfs limit — same Dockerfile with a slim target (never a second image),
  same `post-create.sh` invoked by the Machine's init command, SSH via
  Fly's built-in `hallpass` server — at the cost of explicit VM sizing and
  no automatic sleep; Northflank and Ona take the image as-is and are the
  next candidates. The research note carries all three so the switch is a
  re-target, not a redesign.
- [No custom image means the nested container's ~13 GB pull happens per
  pool sprite] → The pool + golden checkpoint amortises it to once per
  sprite per image pin; cold storage for the layers is cents per month.
- [Memory is platform-managed; `task verify` peaks near 4 GB on one
  `shellcheck` invocation (harmon-devkit#716)] → Unverified whether a
  sprite throttles or OOM-kills under that; the first real lane measures
  it. If it fails, the sizing fields the SDK exposes are the first thing to
  try, and Fly Machines with an explicit `performance-4x`/16 GB guest is
  the fallback.
- [Cold pause kills processes: Herdr server, agents, sshd] → sshd and
  dockerd are Services and restart on boot; the Tasks hold prevents a
  pause mid-gate; on a cold wake Herdr's snapshot restore brings the layout
  back and `resume_agents_on_restore` resumes harnesses whose integration
  recorded a session (installed by `post-create.sh`). The warm→cold
  transition timing is undocumented; treat any lost session as a cold wake
  and re-prompt from the report.
- [The org-scoped Sprites token on the orchestrator's machine] → The
  orchestrator is itself an agent; a prompt-injected orchestrator could
  reach every sprite. Mitigation: the token lives only where the
  orchestrator already holds the bot PAT (the bot devcontainer or the
  operator's laptop keyring), never in a lane; the research note files a
  follow-up asking Fly for sprite-scoped tokens, and the helper is unit
  tested to never forward it.
- [Region is undocumented; latency to the operator and to GitHub] →
  Measure in the first lane; the SDK's `region` field is the lever if it
  matters.
- [A checkpoint restore is destructive and terminates sessions] → The
  helper restores only at lane start and lane retirement (reclaim being
  retirement), waits for the restore to complete before any later step,
  holds the lane lock from its first check through the completed restore
  so no command can start around the restore and nothing is recorded
  before a session exists, never restores a leased
  sprite it does not own, and refuses retirement over a non-clean checkout
  (modified, staged, untracked, or ignored files — a restore deletes an
  ignored `.env` without a trace, the same reason `scripts/worktree-rm.sh`
  refuses on them — or a branch with commits not on its upstream, no
  upstream, or a missing remote counterpart — porcelain status alone cannot
  see an ahead-but-clean branch).
- [Whether a detached exec session still counts as activity once the
  client disconnects, and whether the Tasks API is reachable from inside
  the sprite without the org token] → Both are settled by the feasibility
  spike before any productised tooling is built (tasks.md § 0); if neither
  holds, the fallback is an in-sprite Service that holds a Task through
  `sprite-env` for the command's lifetime, and the spec's invariant is
  unchanged.
- [Foreman's D5 forbids the Docker the nested lane needs] → The research
  note recommends foreman supersede D5 and run the same nested lane through
  the Sprites API; if foreman instead slims the image and keeps D5 on Fly
  Machines, this change is unaffected — the interactive lane and the
  Foreman runner would then use two Fly products on one account, one
  billing surface, and one Dockerfile. Either split collapses to one if Fly
  ships custom or forked sprite images, which the follow-up tracks.

## Migration Plan

- A throwaway **feasibility spike** runs first, before any Copier or
  Taskfile work (tasks.md § 0): one hand-made sprite, Docker as a Service,
  `devcontainer up` of the bot profile, `task verify` inside it, a cold
  wake, the intended DNS allowlist applied, and — under that policy — the
  required-host checks and a key-authenticated
  `sprite proxy -W <inner-address>:22` attach, since the policy blocks
  private addresses on egress and the attach targets the container's
  bridge address. If it fails,
  the documented fallback (Fly Machines after slimming; Northflank; Ona)
  is chosen before the tooling is built, and this change is re-planned.
- The option defaults off; existing generated repositories see no change on
  `copier update` unless they opt in.
- This repository's root adopts the option in `.dogfood-answers.yml` so the
  twins are parity-gated; the maintainer's Fly account is needed only to run
  `task sprite:pool:init`, never to run `task verify`.
- Rollback is turning the answer off (the tooling is removed by the
  template's ordinary conditional rendering) and `task sprite:lane:rm
  --destroy` on any live lane; pool sprites can be destroyed from the Fly
  dashboard at any time with no effect on the repository.

## Open Questions

Deferrable — none of these changes the specs, the approach, or the task
breakdown; each is answered by the first real lane run or a Fly release:

- Does Herdr classify a `claude`/`codex` rendered through `sprite exec
  --tty` the same as a local one? (If not, the sentinel/report path is the
  contract, already specified.)
- Does `sprite proxy -W <host>:22` reach the inner container's bridge
  address, and does a detached exec session count as activity after its
  client disconnects? (Both are feasibility-spike items; the spec's
  invariants do not change with the answer, only the mechanism.)
- What is the warm→cold transition window, and does a `working` agent's
  Tasks hold ever race it?
- Which literal hostnames the Codex CLI (ChatGPT-plan auth) and the Convex
  local backend download need — the spec names them by purpose; the
  implementation fixes the list from the first lane's DNS log.
- Whether Fly ships fork-from-sprite or custom images, which would remove
  the pool and the nested Docker layer.
