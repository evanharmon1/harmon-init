## MODIFIED Requirements

### Requirement: Antigravity's launcher is exactly one of three states, driven by a rendered Copier-answer marker
On its **system-binary-sufficient early return** — the pinned system
binary is present on `PATH` and no executable local `agy-real` copy
exists (`[ -x "$real_bin" ]` false) — `ensure-antigravity-cli.sh` SHALL
guarantee exactly this about `~/.local/bin/agy`, in either profile: it is
never a dangling symlink (a symlink whose target does not exist) —
already a broken launcher regardless of what replaces it later — and
never a symlink to an existing directory, the one shape
`bot-autonomy/antigravity.sh`'s `install_wrapper` cannot perform cleanly:
its unguarded `mv -f "$tmp" "$link_bin"` lands *inside* an existing
directory target instead of replacing the link. A *later* `ln -sfn` is
unaffected by that same shape — its `-n` flag treats the link name as a
plain file rather than following it as a directory, so it replaces a
symlink-to-directory cleanly; this concern is specific to `mv -f`. This
closes the gap issue `#1171` tracked as launcher
state "(d) unreconciled": that state was *any* pre-existing value this
branch left untouched, without regard for whether it broke a later
replacement; no state that broad is defined for this branch any longer.
Beyond that guarantee, this branch makes no claim about the **content**
of whatever it leaves behind, and does not inspect or validate it —
attempting to do so, and correcting what it finds, is exactly the
unconditional-removal approach a first attempt at this fix (the `#1168`
branch) took and had reverted (it could delete a still-valid wrapper
before its replacement was guaranteed).

Under this capability's own normal operation — nothing outside it having
altered what it wrote — `~/.local/bin/agy` is exactly one of three
states: **(a)** the flag-injecting autonomy wrapper — present only in the
bot profile when `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads
`enabled` — that delegates to `~/.local/bin/agy-real` when present and
executable, else the system binary at `/usr/local/bin/agy`; **(b)** a
plain symlink to an **executable** `agy-real`, present only when
`agy-real` both exists and is executable; or **(c)** absent. A value
reached only through tampering — a symlink whose target lost its
executable bit after installation, an unrelated file placed at this path
by something outside this capability, or `agy` (on any exit path other
than the early return above) or `agy-real` itself becoming a directory
rather than a regular file — is neither guaranteed to be prevented
(beyond the early-return guarantee above) nor guaranteed to be one of
(a)/(b)/(c); it is simply left as found or reconciled only as far as that
guarantee reaches, the same as any other content this capability does not
validate. Every write path here assumes `agy-real`, when it exists, is a
regular executable file — an assumption `#1171` does not change — so a
directory occupying `agy` or `agy-real` on a different exit path than the
early return above is a pre-existing, tamper-only condition this fix
neither introduces nor claims to close; it is tracked separately (this
issue's pull request records it as a deferred finding) rather than folded
into this guarantee. Validating content, not merely shape, is
`bot-autonomy.sh verify`'s job in the bot profile (below); the dev
profile has no equivalent check by design (see the Human dev profile
requirement), so a tampered value there is a pre-existing, unrelated risk
this fix neither introduces nor leaves open any further than it already
was.
`HARMON_BOT_AUTONOMY_ANTIGRAVITY` SHALL be set by the **rendered**
`devcontainer.json` (bot) and `dev/devcontainer.json` — both
`[% if devcontainer %]`-conditional jinja twins — from
`[[ 'enabled' if use_antigravity_cli else 'disabled' ]]` (this template's
own Jinja delimiters, per `copier.yml`'s `_envops` block — never the
standard `{{ }}`/`{% %}` pair), to the literal string `enabled` or
`disabled`; this repository's own root `.devcontainer/devcontainer.json`
(the rendered form, not a jinja twin) carries the literal value matching
`.dogfood-answers.yml`. No **verbatim** script —
`.devcontainer/config/ensure-antigravity-cli.sh`, `bot-autonomy.sh`, or
any `bot-autonomy` module — SHALL derive the Copier answer any other way
(no `copier.yml`/`.copier-answers.yml` read, no render-time file-tree
inspection): a verbatim twin ships identical bytes to every generated
repo regardless of that repo's answers, so the rendered `containerEnv`
marker is the only channel through which a verbatim script can know a
per-repo Copier answer at all.

`ensure-antigravity-cli.sh` SHALL own only an `agy-real` it installed and
states (b)/(c): in **either** profile, WHEN the marker reads `enabled`, it
either downloads or reconciles the pinned binary at `agy-real` and
(re)points a plain `agy → agy-real` symlink (state b), reuses an existing
exact-version executable without changing or claiming it — including an
independently managed symlink — or, on its system-binary-sufficient
early return (the pinned system binary is present on `PATH` and no
executable local `agy-real` copy exists, `[ -x "$real_bin" ]` false),
installs nothing itself and instead reconciles whatever already occupies
`agy`: absence stays absence (state c); a dangling symlink (already a
broken launcher on its own) or a symlink to an existing directory (the
one shape `bot-autonomy/antigravity.sh`'s `install_wrapper`'s unguarded
`mv -f` cannot safely replace, landing inside it instead of replacing the
link — a later `ln -sfn` is unaffected) is removed, reaching state (c);
any other
pre-existing value (a regular file, a valid wrapper, or a symlink to an
existing file) is left exactly as found, since this branch has nothing of
its own to replace it with and removing a still-valid wrapper before its
replacement exists is exactly the defect a first attempt at this fix (the
`#1168` branch) introduced and had reverted. This reconciliation is
unconditional and runs identically in both profiles: unlike the removed
state (d), reaching a valid state here never depends on the bot profile's
follow-on `apply` step. WHEN the marker reads anything other than
`enabled` (`disabled`, or absent on an image built before this marker
existed), it SHALL remove `agy` or `agy-real` only when that path's own
independent ownership proof matches both its published filesystem identity and
its immutable installed content (the link target for a symlink, or SHA-512 for
a regular file). Target equality, wrapper-marker text, filename, version, and
inode identity alone SHALL NOT authorize deletion. An unowned regular file or
symlink at either path SHALL survive unchanged; stale ownership metadata SHALL
be removed without deleting a path whose identity or content no longer matches,
including orphan executable proof encountered by a system-binary-only enabled
run. Every file proof SHALL contain a nonempty SHA-512 produced by a successful
hash command; hash failure SHALL neither authorize cleanup nor publish proof.
Cleanup of a proof-matching public path SHALL atomically move that generation to
a unique same-directory quarantine and revalidate the moved identity and content
before deletion; a non-matching captured generation SHALL be restored without
overwriting or following any newer public value (including a symlink to a
directory), or retained with a loud recovery path. If the quarantine move fails,
the matching proof SHALL remain for a later retry; once revalidation demonstrates
that the captured generation is not owned, its now-stale proof SHALL be removed.
The proof SHALL record the unique quarantine name before the move, so a following
run recovers that exact generation if interruption occurs after the move.
Before either launcher writer recovers or publishes through the fixed
transaction names, it SHALL hold one shared per-install-directory lock, so
concurrent ensure/module invocations cannot discard or promote each other's
generation.
Each multi-path publish SHALL first record a recoverable transaction for the new
generation, then publish the path, then atomically promote that transaction to
its ownership proof. A following run SHALL either promote a transaction that
matches the published path or discard a transaction that does not, so
interruption cannot strand a published managed generation without recognizable
proof. Each writer SHALL complete that recovery before replacing its transaction
metadata with a new generation. Under this capability's own untampered enabled-to-disabled transition,
those predicates remove all managed state and reach state (c); externally
supplied launchers are outside states (a)-(c) and are preserved.
The bot-autonomy `antigravity` module, bot-only, SHALL act only on top of
that: WHEN its own read of the marker is `enabled`, `apply` overwrites
`~/.local/bin/agy` — whatever `ensure-antigravity-cli.sh` left there —
with the wrapper (state a); WHEN the marker is not `enabled`, `apply`
SHALL NOT create, remove, or otherwise touch `agy` at all
(`ensure-antigravity-cli.sh`, which runs first, has already removed any
module-owned launcher while preserving independent user state) and SHALL
restore `~/.gemini/antigravity-cli/settings.json`
to its pre-managed state (via `apply-antigravity-settings.sh restore`).
`verify` SHALL assert whichever managed state the marker's value implies:
when disabled, it SHALL reject any remaining launcher/executable ownership or
transaction metadata, while accepting an independent regular launcher or valid
symlink regardless of its target or wrapper-like content. In the bot profile,
where it runs, it SHALL
also fail on a dangling symlink regardless of the marker's value. The
dev profile has no equivalent `verify` step, but does not need one for
this invariant: `ensure-antigravity-cli.sh`'s own reconciliation on the
early return (above) is what keeps the dev profile's `agy` out of a
dangling or unreplaceable state, not a follow-on check.

WHEN the wrapper is installed (state a), it SHALL prepend
`--dangerously-skip-permissions` to every **agent/headless execution**
launch that does not already carry it, and pass a fixed set of
subcommands and flags through unmodified without prepending the flag: a
bare `agy` (interactive, already covered by the settings-file policy),
`agent`/`agents`, `changelog`, `help`/`-h`/`--help`, `install`, `models`,
`plugin`/`plugins`, `update`, and `--version` — matching the passthrough
list already proven correct in `agy-autonomy.sh`, the shell-function
mechanism this wrapper replaces. Prepending the flag to any of these is
either rejected by `agy` or meaningless. `ensure-antigravity-cli.sh`'s own
version check reads `agy-real --version` directly — not through the
wrapper or the symlink — so its idempotency never depends on either being
correct. The wrapper's precedence over the system `agy` binary — when the
wrapper is installed at all — SHALL be established at the **container
level**: the bot `Dockerfile` prepends `/home/vscode/.local/bin` ahead of
`/usr/local/bin` onto `PATH` via a Docker `ENV` directive, not by a shell rc
file's `PATH` export and not by `devcontainer.json`'s `containerEnv` (a
`containerEnv.PATH` entry that self-references `${containerEnv:PATH}` does
not resolve at container-creation time — the devcontainers CLI passes it to
`docker run -e` literally, unresolved, which breaks the container's own
shell; a Docker `ENV` directive is Docker's own, working self-reference and
applies identically to any `docker exec`). This still closes the same gap a
shell function or an rc-dependent `PATH` prepend would leave open: a process
that never sources an interactive login shell (a `docker exec` without a
login/interactive shell, a Foreman-dispatched process, a cron job).

#### Scenario: the marker is rendered per repo, never derived by a verbatim script
- **WHEN** a repo is generated (or updated) with `use_antigravity_cli` at
  some value
- **THEN** the rendered bot `devcontainer.json` and `dev/devcontainer.json`
  both carry `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` set to the
  literal `"enabled"` or `"disabled"` matching that answer, and no
  verbatim script (`ensure-antigravity-cli.sh`, `bot-autonomy.sh`, the
  `antigravity` module) reads the answer any other way

#### Scenario: ensure-antigravity-cli.sh installs agy-real and the symlink when enabled, in either profile
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`,
  `ensure-antigravity-cli.sh` runs — in the bot profile or the dev profile
  — and the local `agy-real` is absent or does not satisfy the pinned version,
  and the on-`PATH` system binary does not already satisfy the pin
- **THEN** it downloads/reconciles the pinned binary at
  `~/.local/bin/agy-real` and (re)points `~/.local/bin/agy` at it as a
  plain symlink — state (b) — publishing independent identity-and-content
  proofs for both paths through recoverable transactions

#### Scenario: an unowned exact-version agy-real is reused without being claimed
- **WHEN** enabled setup finds an executable `~/.local/bin/agy-real` whose
  first version line already matches the pin but whose identity and content
  have no matching installer ownership proof, including when `agy-real` is a symlink
- **THEN** it leaves that executable and symlink target unchanged, creates no
  ownership proof for it, and may point `agy` at the compatible path; a later
  disabled run removes only the owned launcher and preserves `agy-real`

#### Scenario: ensure-antigravity-cli.sh leaves agy absent when the current system binary already satisfies the pin and nothing pre-existed
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`,
  `ensure-antigravity-cli.sh` meets the system-binary-sufficient early
  return's precondition (defined in the requirement above), and `agy` was
  already absent beforehand
- **THEN** it creates neither `agy-real` nor `agy` — avoiding an
  unnecessary shadow copy of a binary the image already ships — and
  `agy` resolves directly to the sufficient system binary via `PATH`:
  state (c)

#### Scenario: the system-binary-sufficient early return removes a leftover agy that would break a later replacement
- **WHEN** `ensure-antigravity-cli.sh` meets the system-binary-sufficient
  early return's precondition (defined in the requirement above) and
  `~/.local/bin/agy` is a dangling symlink (most plausibly left behind
  after `agy-real` was removed some other way) or a symlink to an
  existing directory
- **THEN** it removes `~/.local/bin/agy` before exiting, reaching state
  (c), in both the bot and dev profiles — so a later `install_wrapper`'s
  `mv -f` always either lands on a clean absence or is never reached
  because a fresh `ln -sfn` on a subsequent enabled run already resolved
  it, and a bare `agy` invocation never resolves through a broken link

#### Scenario: the system-binary-sufficient early return leaves a still-valid launcher untouched
- **WHEN** `ensure-antigravity-cli.sh` meets the system-binary-sufficient
  early return's precondition (defined in the requirement above) and
  `~/.local/bin/agy` is a regular file (including a wrapper installed by
  an earlier `antigravity` module `apply`, found again on a container
  rebuild) or a symlink whose target exists
- **THEN** it leaves `~/.local/bin/agy` exactly as found, byte-for-byte —
  this branch installs nothing of its own to replace it with, and a value
  already safe for a later `mv -f` or `ln -sfn` to replace needs no
  reconciliation; removing it here, with no replacement guaranteed on
  this branch, is the defect a first attempt at this fix had reverted for

#### Scenario: disabled cleanup removes only independently proven managed paths
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and
  `ensure-antigravity-cli.sh` runs — in the bot profile or the dev profile
- **THEN** it does not download `agy-real`; it removes an owned `agy` launcher,
  removes `agy-real` only when its independent identity-and-content proof
  matches, and preserves every unowned regular file or symlink at either path

#### Scenario: cleanup revalidates the atomically captured generation
- **WHEN** a public launcher or executable matches its ownership proof during
  the initial cleanup check, but an external actor replaces it before cleanup
  captures the path
- **THEN** cleanup atomically moves the generation currently at the public path
  to a unique same-directory quarantine, detects that the moved identity or
  content does not match, and restores or retains those independent bytes
  instead of deleting them under the stale proof

#### Scenario: concurrent launcher reconciliation is serialized
- **WHEN** two `ensure-antigravity-cli.sh` invocations, or ensure and the bot
  module's wrapper publisher, overlap against the same install directory
- **THEN** exactly one holds the shared launcher-state lock and may recover or
  publish through the fixed transaction names; the other fails closed before
  it can discard or promote the active generation

#### Scenario: dangling metadata symlinks are not treated as absence
- **WHEN** an ownership or transaction metadata pathname is a symlink whose
  target does not exist
- **THEN** disabled verification rejects the remaining managed metadata, and
  reconciliation treats the symlink itself as present and removes it without
  following its target

#### Scenario: a legacy pre-metadata agy-real is preserved
- **WHEN** a disabled rolling update finds markerless `agy` and `agy-real`
  paths left by a release that predates independent per-path ownership metadata
- **THEN** it preserves both paths byte-for-byte; target, wrapper-marker text,
  filename, version, and prior management history do not substitute for a
  matching independent identity-and-content proof

#### Scenario: an independent natural agy to agy-real symlink is preserved
- **WHEN** disabled cleanup or verification finds an independently installed
  `agy → ~/.local/bin/agy-real` symlink with no matching launcher proof
- **THEN** cleanup preserves the symlink and verification accepts it; the
  natural target relationship alone never implies module ownership

#### Scenario: an in-place rewrite revokes executable deletion authority
- **WHEN** an external installer rewrites a previously managed `agy-real` in
  place, retaining its inode but changing its installed content
- **THEN** disabled cleanup detects the fingerprint mismatch, preserves the
  external content, and removes the stale ownership metadata

#### Scenario: an interrupted upgrade is recovered across generations
- **WHEN** an upgrade is interrupted after the new `agy-real` is published but
  before its transaction is promoted over the old generation's ownership proof
- **THEN** the next run recognizes the new path from the transaction's matching
  identity and content, promotes that proof, and can clean the managed
  executable without leaving an unrecognized orphan

#### Scenario: bot apply installs the wrapper when enabled, over any replaceable value ensure-antigravity-cli.sh left
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and the
  `antigravity` module's `apply` runs in the bot profile, after
  `ensure-antigravity-cli.sh` has already left `~/.local/bin/agy` as a
  regular file or as a symlink that does not target a directory — one of
  states (a)-(c) under this capability's own normal operation, or a
  tampered-but-still-replaceable value otherwise (see the requirement
  above)
- **THEN** `apply` creates or overwrites `~/.local/bin/agy` with the
  flag-injecting wrapper script regardless, since `install_wrapper`'s
  `mv -f` replaces a regular file or a symlink that does not target a
  directory cleanly whatever its content (dangling or not). A symlink
  that *does* target a directory is not one of those replaceable shapes —
  `mv -f`, unlike a later `ln -sfn`, nests the wrapper inside the target
  instead of replacing the link — but it is exactly the shape
  `ensure-antigravity-cli.sh`'s early-return reconcile removes on its own
  path (see the requirement above), so it does not survive to reach this
  scenario that way. A literal directory at `agy` itself, or at
  `agy-real` (which an unguarded reconcile step can point a symlink at),
  reaches the same replacement-blocking family a different way; both it
  and a directory-targeting symlink reached other than through the
  early-return reconcile are out of scope for this fix and tracked as
  issue `#1179`

#### Scenario: bot apply does not touch agy when disabled after ownership cleanup
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and the
  `antigravity` module's `apply` runs in the bot profile
- **THEN** `apply` restores `~/.gemini/antigravity-cli/settings.json` via
  `apply-antigravity-settings.sh restore`, and does not create, remove, or
  otherwise touch `~/.local/bin/agy` — `ensure-antigravity-cli.sh`, having
  already run, has removed a module-owned launcher but preserved any
  independently owned launcher

#### Scenario: toggling the option off removes all installer-owned launcher state
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` was previously `enabled`
  (`agy-real`, the symlink, and then the wrapper all installed) and a
  later render/rebuild carries the marker as `disabled`
- **THEN** `ensure-antigravity-cli.sh` recovers any interrupted publication,
  removes both `agy-real` and `agy` plus their ownership/transaction metadata
  on its next run, and reaches state (c) absence; if an external actor replaced
  either path or rewrote its content in place, the non-matching proof does not
  authorize deleting that replacement

#### Scenario: verify rejects disabled managed remnants and accepts unowned launchers
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` is not `enabled` and `verify`
  runs in the bot profile
- **THEN** `verify` rejects any remaining launcher/executable ownership or
  transaction metadata, but accepts an independent regular launcher or valid
  symlink even when it naturally targets `agy-real` or resembles the wrapper;
  dangling symlinks remain an unconditional failure

#### Scenario: the wrapper precedes the system binary on the container-wide PATH
- **WHEN** the bot `Dockerfile` is inspected
- **THEN** it prepends `/home/vscode/.local/bin` ahead of `/usr/local/bin`
  (where the system `agy` binary is installed) onto `PATH` via an `ENV`
  directive, so the ordering applies to every process the container runs —
  not only shells that source `.bashrc`/`.zshrc` — regardless of which of
  states (a)-(c) `agy` is currently in

#### Scenario: a process with no shell rc still resolves the wrapper when enabled
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and
  `agy --version` is resolved by a process that has not sourced any shell
  rc file — a `docker exec` invocation that does not start a
  login/interactive shell, or an equivalent `env -i
  PATH=$CONTAINER_PATH agy --version` using the container's own PATH value
- **THEN** the resolved `agy` is `~/.local/bin/agy` (the wrapper), not the
  system binary at `/usr/local/bin/agy`

#### Scenario: a headless invocation off PATH still receives the flag when enabled
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and a
  programmatic launcher that never sources a login shell execs `agy -p …`
  by resolving it off `PATH` (not via the interactive shell function)
- **THEN** the resolved `~/.local/bin/agy` wrapper adds
  `--dangerously-skip-permissions` to the invocation

#### Scenario: the wrapper prefers the compatibility copy over a stale system binary
- **WHEN** the container's baked-in system binary at `/usr/local/bin/agy`
  predates the version `ensure-antigravity-cli.sh` pins (an older pinned
  image that has not yet picked up the latest shared-image release) and
  `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`
- **THEN** `ensure-antigravity-cli.sh` has already downloaded the pinned
  version to `~/.local/bin/agy-real`, and the wrapper at `~/.local/bin/agy`
  execs `agy-real` — not the stale `/usr/local/bin/agy` — so both the
  flag injection and the correct, freshest binary version hold at once

#### Scenario: the wrapper does not duplicate an explicit flag
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and a caller
  invokes `agy` already passing `--dangerously-skip-permissions`
- **THEN** the wrapper does not add the flag a second time

#### Scenario: passthrough subcommands and flags are not modified
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and the
  wrapper is invoked as a bare `agy`, or with `agent`, `agents`,
  `changelog`, `help`, `-h`, `--help`, `install`, `models`, `plugin`,
  `plugins`, `update`, or `--version`
- **THEN** it execs the resolved real `agy` binary (`agy-real` when
  present and executable, else the system binary) unchanged, without
  prepending `--dangerously-skip-permissions`

#### Scenario: verify fails if the enabled state's boundary is missing, inert, or misdirected
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, and `~/.local/bin/agy` is missing, not executable,
  does not inject the flag, or — when `agy-real` exists — does not resolve
  to it
- **THEN** `verify` exits non-zero naming Antigravity

#### Scenario: verify fails when the wrapper's own resolved backend cannot run
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, the wrapper at `~/.local/bin/agy` matches its
  expected content exactly, and neither `agy-real` nor the system binary
  it falls back to is executable
- **THEN** `verify` exits non-zero naming Antigravity — matching wrapper
  bytes are not sufficient when every invocation would exit 127

#### Scenario: verify fails when the current workspace is missing from the settings' trust list
- **WHEN** `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled`, `verify` runs
  in the bot profile, every scalar autonomy key matches the shipped
  defaults, and `~/.gemini/antigravity-cli/settings.json`'s
  `trustedWorkspaces` does not include the current workspace (the entry
  `apply-antigravity-settings.sh apply` itself writes)
- **THEN** `verify` exits non-zero naming Antigravity — a correct
  `toolPermission` value does not by itself bypass the workspace-trust gate

#### Scenario: verify fails on a dangling symlink regardless of the marker, in the bot profile where it runs
- **WHEN** `verify` runs in the bot profile and `~/.local/bin/agy` is a
  symlink whose target (`agy-real`) does not exist, regardless of the
  marker's value
- **THEN** `verify` exits non-zero naming Antigravity — none of states
  (a)-(c) is ever a dangling link. `bot-autonomy.sh verify` never runs in
  the dev profile, but `ensure-antigravity-cli.sh`'s own reconciliation on
  its early return (defined in the requirement above) is what keeps a
  dangling link from persisting there too, not a follow-on check

### Requirement: Human dev profile is unaffected by construction
The bot-autonomy wrappers and modules SHALL be installed by the bot
post-create only. The dev post-create SHALL NOT invoke `bot-autonomy.sh
apply`, `verify`, or install the `agy` wrapper, so the human profile's
existing prompt-enabled and balanced permission policies are unchanged by
this capability's existence rather than by a separate runtime check.

#### Scenario: dev post-create never calls the bootstrap or installs the wrapper
- **WHEN** `.devcontainer/dev/post-create.sh` runs
- **THEN** it does not invoke `bot-autonomy.sh apply` or `verify`, and
  never installs the flag-injecting autonomy wrapper (state a) at
  `~/.local/bin/agy`. `ensure-antigravity-cli.sh`'s own reconciliation on
  its system-binary-sufficient early return (see the requirement above)
  removes a dangling symlink or a symlink to an existing directory there
  too, so no unreconciled dangling or unreplaceable leftover can persist
  in the dev profile the way it could before issue `#1171`'s fix. That
  reconciliation is exactly that narrow, though: a regular file
  (including a wrapper a prior run already installed, or any other file
  found there) or a symlink to an existing file — executable or not — is
  preserved exactly as found, same as the requirement above describes.
  The dev profile therefore reaches its plain `agy → agy-real` symlink
  (state b, when `HARMON_BOT_AUTONOMY_ANTIGRAVITY` reads `enabled` and a
  local copy is needed) or absence (state c, when disabled, or when
  enabled and the on-`PATH` system binary already satisfies the pin) only
  when nothing else already occupied `agy`; otherwise it retains whatever
  else was already there instead

#### Scenario: dev profile policies remain prompt-enabled or balanced
- **WHEN** a dev profile container is created or rebuilt
- **THEN** Claude Code's managed `defaultMode` is unset (normal
  prompt-on-action), Codex's managed config reads `workspace-write`/
  `on-request`, and Antigravity's settings reflect the balanced
  `antigravity-settings-dev.json` policy — none of them the bot's values
