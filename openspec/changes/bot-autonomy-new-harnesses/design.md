## Context

See proposal.md - Why for the motivating gap. Current state, precisely:

- `bot-autonomy-bootstrap` (proposed in #1148) **is now implemented**:
  PR #1150 (`feat(devcontainer): fail-closed bot autonomy bootstrap for
  every installed harness`) merged to `main` as `c720eab`, and this
  worktree's `main` now has `.devcontainer/scripts/bot-autonomy.sh` and the
  `.devcontainer/config/bot-autonomy/` tree — this branch has merged that
  `main` in. This proposal's own drafting began before that merge (see the
  Migration Plan's "development may proceed on a branch stacked on PR
  #1150" note, now moot since the prerequisite has landed); the actual
  shipped shape (`unsupported.json`, `aliases.json`, per-slug module files)
  matches what this proposal's Context assumed while it was still open —
  confirmed by inspection after the merge, not merely asserted.
- `harness-matrix` (also proposed in #1148) **is** implemented and merged
  (#1149, `feat(image): add Copilot CLI, pi, oh-my-pi; remove Gemini CLI;
  bump herdr to 0.8.2`). `images/devcontainer/Dockerfile` installs `copilot`
  (`@github/copilot@1.0.82`), `pi` (`@earendil-works/pi-coding-agent@0.84.4`),
  and `omp` (`can1357/oh-my-pi` `v18.1.2`) unconditionally, matching the
  existing Claude Code/Codex/OpenCode/Antigravity precedent. Both
  `devcontainer.json` twins already mount `~/.copilot`, `~/.pi`, and
  `~/.omp` as named volumes (bot and dev, separately per profile — confirmed
  by reading both files directly), and `docs/guides/devcontainers.md` already
  lists all three in its harness prose and volume list. `agent-registry.json`
  already carries `copilot-cli` and `pi` (pre-existing) and `oh-my-pi` (added
  by `harness-matrix`, `family_constraint: {kind: broker}`,
  `model_resolution.owner: harness-runtime`, matching `pi`'s shape).
  `.devcontainer/Dockerfile` (the root pin) has **not** been bumped yet — no
  `sync-pin` PR is open as of this writing — so none of the three binaries is
  present in this repository's own bot container today.
- `copier.yml` has no Copilot-related question today (confirmed by grep):
  only `use_antigravity_cli` exists in the devcontainer-options cluster
  (`devcontainer`, `use_statusline_pr_lookup`, `devcontainer_coder_folder_uri`,
  `use_antigravity_cli`, `use_alternative_claude_providers`, in that file
  order). `bot-autonomy-bootstrap`'s own design.md is explicit that defining
  Copilot's Copier answer is **this** change's job, not its own or
  `harness-matrix`'s: "the `bot-autonomy-new-harnesses` follow-on adds
  `HARMON_BOT_AUTONOMY_COPILOT` once it defines that harness's own Copier
  answer — not added here, since neither this change nor `harness-matrix`
  builds the Copilot module."
- `bot-autonomy-bootstrap`'s design.md separately establishes the general
  contract this change's Copilot module instantiates for the second time
  (Antigravity is the first): "A Copier-gated harness's module always
  exists; its Copier answer selects the module's policy, not whether the
  module exists" — `disabled-by-option` (no allow-all configuration) or
  `autonomous` (the allow-all configuration, plus a wrapper if the harness
  needs one for headless launches). It also states the mechanism a verbatim
  module uses to learn a per-repo Copier answer: a rendered
  `containerEnv.HARMON_BOT_AUTONOMY_<HARNESS>` marker, never a direct read of
  the Copier answer (verbatim template twins ship identical bytes to every
  generated repo).
- `bot-autonomy-bootstrap`'s tasks.md (task 1.2) and design.md both commit
  its own implementation to adding `copilot-cli`, `pi`, and (per its task
  4.5, reconciling with `harness-matrix`'s task 3.4) `oh-my-pi` to the
  registry `unsupported` table, each with `reason: "pending
  bot-autonomy-new-harnesses"` and an `executable` field (`"copilot"`,
  `"pi"`, `"omp"` respectively) — and states its own uniform rule that none
  of those exemptions survives the executable actually being installed.
  This change's job is to remove those three placeholder entries and
  replace each with real coverage.
- `.dogfood-answers.yml` records `use_antigravity_cli: true` with a one-line
  comment explaining why (line 65); it has no Copilot-related entry.
- **This capability has no `openspec/specs/` tree to modify.** Neither
  `bot-autonomy-bootstrap` nor `harness-matrix` has been archived, so
  `openspec/specs/devcontainer/bot-autonomy/` does not exist on disk — only
  `openspec/changes/bot-autonomy-bootstrap/specs/devcontainer/bot-autonomy/spec.md`
  does, as that change's own (not-yet-applied) delta. This proposal's
  Capabilities section nonetheless lists `devcontainer/bot-autonomy` as
  **Modified**, not **New** — the true relationship (this change adds
  requirements to the same contract `bot-autonomy-bootstrap` defines, not a
  second, independent contract) — and its spec delta uses `## ADDED
  Requirements` with no `## Purpose` section, matching how a delta against
  an existing capability is written. This is a deliberate choice, not
  strict adherence to the `openspec instructions specs` rule ("Modified
  capabilities: use the exact existing path from `openspec/specs/`"), which
  is written for the ordinary case of one change at a time and does not
  anticipate two siblings targeting the same not-yet-archived capability.
  `openspec validate` was confirmed empirically (scratch fixtures, both
  `## ADDED` and `## MODIFIED` headers, against this exact, non-existent
  capability path) to accept either shape without complaint — the
  New-vs-Modified distinction is an authoring convention the CLI does not
  mechanically enforce at this stage. Whichever of the two sibling changes
  is archived first materializes `openspec/specs/devcontainer/bot-autonomy/spec.md`;
  the other's delta (and this change's) is reconciled against it at that
  point, by whoever runs the archive — an ordinary consequence of three
  related changes proposed and implemented in sequence rather than
  atomically, not a defect in how any one of them is written.
- **Primary-source research performed while writing this proposal**
  (analogous to `harness-matrix`'s own registry/npm lookups) directly
  contradicts one premise the originating brief stated and confirms two
  others. All three findings are cited by URL and, where a pinned release
  exists, verified against that exact tag rather than an unpinned branch:
  - GitHub Copilot CLI: `--allow-all-tools`, `--allow-all-paths`,
    `--allow-all-urls`, and the combined `--allow-all`/`--yolo` flags; the
    `COPILOT_ALLOW_ALL` environment variable ("Set to `true` for full
    permissions", GitHub's [CLI programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference));
    the per-user `~/.copilot/settings.json` `permissions.disableBypassPermissionsMode`
    kill-switch (GitHub's [CLI configuration directory reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
    and [disabling automatic command approval](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/disable-automatic-commands));
    the `-p`/`--prompt` headless mode and the administrative-vs-agent-task
    subcommand split (GitHub's [about Copilot CLI](https://docs.github.com/copilot/concepts/agents/about-copilot-cli)
    and [CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)) —
    all confirm the brief's claims.
  - pi: `defaultProjectTrust` (`"ask"`/`"always"`/`"never"`, global-only) in
    `~/.pi/agent/settings.json`, and the specific consequence of each value
    in non-interactive mode (source:
    [`earendil-works/pi` `docs/settings.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/settings.md)
    and [`docs/security.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md),
    fetched directly) — confirms the brief's claim and sharpens its
    rationale (see Decisions).
  - oh-my-pi: **contradicts** the brief's premise ("no documented global
    auto-approve"). `docs/approval-mode.md` and `docs/settings.md` at
    `can1357/oh-my-pi`'s exact pinned tag `v18.1.2` (not just `main` —
    fetched from both and confirmed identical on every quoted point)
    document `tools.approvalMode` (`always-ask`/`write`/`yolo`, schema
    default `yolo`) in `~/.omp/agent/config.yml`, project-level override at
    `<cwd>/.omp/config.yml`, and `omp config get <key>` as the resolved-value
    inspection command
    ([`docs/approval-mode.md`](https://github.com/can1357/oh-my-pi/blob/v18.1.2/docs/approval-mode.md),
    [`docs/settings.md`](https://github.com/can1357/oh-my-pi/blob/v18.1.2/docs/settings.md)).
    See Decisions for how this proposal resolves the brief's "bounded spike
    task" instruction given this finding.

## Goals / Non-Goals

**Goals:**
- Give `copilot-cli`, `pi`, and `oh-my-pi` real registry coverage, closing
  the specific gap `bot-autonomy-bootstrap`'s own Non-goals and #1137's
  first `[CI]` acceptance criterion both name.
- Reuse every established pattern from `bot-autonomy-bootstrap` exactly
  (Copier-gated-module contract, rendered-marker channel, backup/restore
  shape, resolved-vs-global-file `verify` distinction, container-wide `PATH`
  precedence) rather than inventing a parallel one for three more harnesses.
- Resolve oh-my-pi's mechanism from actual evidence rather than leaving a
  placeholder the implementation PR would have had to resolve from scratch —
  while keeping the fail-closed contingency the brief's caution correctly
  anticipated, in case that evidence does not hold against the real binary.
- State the cross-change sequencing this change sits inside precisely enough
  that a human (or Foreman) reading only this proposal knows what must
  merge before it and what it must merge before, without having to
  reconstruct that from three separate documents.

**Non-Goals:**
- Not redesigning any part of `bot-autonomy-bootstrap`'s own contract
  (bootstrap entrypoint, three-bucket coverage model, fail-closed wiring,
  the four existing modules) — this change only adds to it.
- Not deciding whether the shared devcontainer image should ever
  Copier-gate `copilot`/`pi`/`omp`'s **installation** — that is
  `harness-matrix`'s capability, and remains unconditional installation
  regardless of any Copier answer this change adds (see Risks for why the
  oh-my-pi contingency does not reopen this).
- Not building the always-emitted aggregator, ruleset changes, fork-PR
  validation path, or `merge_group` wiring `bot-autonomy-bootstrap`'s
  proposal already scoped out of promoting the container-assertion job to a
  required status check. Unchanged here.

## Decisions

**GitHub Copilot CLI gets a new, default-off `use_copilot_cli` Copier
answer — not a reuse of `use_antigravity_cli`, and not an unconditional
module the way Claude Code/Codex/OpenCode's autonomy is.** Copilot is a
paid-tier GitHub product with its own free-tier limits, exactly the shape
AGENTS.md's Hard Rule requires an explicit, default-off opt-in for.
`harness-matrix`'s own proposal already pre-drafted the account/free-tier/
private-repo caveat language for this exact question ("Per AGENTS.md's Hard
Rule … Copilot's non-interactive/allow-all mode for the bot profile … SHALL
be gated by a Copier option defaulting off, mirroring `use_antigravity_cli`'s
shape"), anticipating this change would need to write it. A separate
answer, rather than folding Copilot under `use_antigravity_cli` or a generic
"enable account-backed harnesses" toggle, is used because the two products
have independent account requirements, terms, and adoption timelines — a
consumer might want one without the other, and Antigravity's own answer
already has an unrelated validator (`devcontainer` must be on) that a shared
toggle would tangle unnecessarily.

**The `copilot-cli` module never writes `COPILOT_ALLOW_ALL` itself; the
render does, and `apply`/`verify` only observe it.** This mirrors the
`containerEnv.PATH` reasoning `bot-autonomy-bootstrap` already applied to
Antigravity's wrapper precedence: a container-wide environment variable
that every process sees — including a `docker exec` with no login shell —
has to be injected by Docker itself, from `containerEnv` in the rendered
`devcontainer.json`, before any lifecycle script runs. A post-create script
cannot durably set an environment variable for *other, later* processes in
the same container; it could only export one into its own shell, which is
exactly the login-shell-scoped anti-pattern this entire capability exists
to eliminate (`agy-autonomy.sh`'s shell function is the canonical example
`bot-autonomy-bootstrap`'s own Why section cites). So `HARMON_BOT_AUTONOMY_COPILOT`
and `COPILOT_ALLOW_ALL` are both rendered directly by the jinja
`devcontainer.json` twin — the first as the uniform marker every
Copier-gated module reads, the second as Copilot's own actual mechanism —
and `apply`'s job in the enabled branch is to confirm the environment
variable is really there (failing loudly if it is not, rather than
installing a wrapper whose backing configuration is missing) and install
the wrapper, not to produce the variable itself.

**Both are rendered into the *bot* `devcontainer.json` twin only — unlike
`HARMON_BOT_AUTONOMY_ANTIGRAVITY`, which both twins carry.** Antigravity's
marker needs to reach both profiles because `ensure-antigravity-cli.sh`, a
shared script, runs from both bot and dev post-create and reads it either
way (see that Decision below). Copilot has no equivalent shared consumer:
the `copilot-cli` module is dispatched only from the bot's own
`bot-autonomy.sh apply`/`verify` calls, never from dev's, so nothing in the
dev profile has any reason to read `HARMON_BOT_AUTONOMY_COPILOT` at all.
`COPILOT_ALLOW_ALL` is the sharper reason this matters: it is a plain
environment variable Copilot CLI honors directly, in whichever profile sets
it, with no per-profile distinction of its own the way Antigravity's
settings file has a separate bot/dev JSON payload. Rendering it into the dev
twin as well — even though the dev post-create never runs the module that
"owns" it — would still hand every interactive `copilot` invocation in a
human's own dev container full allow-all permissions, contradicting the dev
profile's prompt-enabled/balanced posture (`bot-autonomy-bootstrap`'s own
Human dev profile requirement, and one of #1137's acceptance criteria
already checked off: "The human devcontainer retains its existing
prompt-enabled or balanced permission policies") regardless of whether the
bot-autonomy module itself ever touches that container. Restricting both to
the bot twin closes that gap structurally, rather than depending on the dev
profile happening to never invoke the module that would otherwise be the
only thing standing between a human's shell and allow-all Copilot.
Alternative considered: have `apply` write `COPILOT_ALLOW_ALL` into a
profile-scoped `.bashrc` `export` — rejected outright as the exact mechanism class this
capability was created to retire.

**`COPILOT_ALLOW_ALL` is rendered to the exact literal `"true"`/`"false"` in
both states, never omitted — and `verify` checks for the exact literal, not
general truthiness.** An earlier draft of this design omitted the key
entirely in the disabled state, reasoning that an absent `containerEnv` key
is simply absent from the container. That reasoning missed a real second
input: the bot profile also loads `.devcontainer/devcontainer.env` via
`--env-file` (`runArgs: ["--env-file", ".devcontainer/devcontainer.env"]`),
and `init-env.sh` — the script that populates and evicts entries in that
file — only recognizes a fixed, enumerated set of secret variable names
(`GH_TOKEN`, `FOREMAN_AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`AGENT_DECK_TELEGRAM_KEY`, the alt-provider keys, `TS_AUTHKEY`,
`ANTHROPIC_API_KEY`); its own comment states plainly that "vars the script
does NOT recognize are left untouched, so a value an opted-out repo
populates out-of-band… survives rebuilds." `COPILOT_ALLOW_ALL` is not a
secret and was never going to be added to that list — it is a derived,
render-time boolean, not a runtime-injected credential — so nothing evicts
a stray `COPILOT_ALLOW_ALL=true` entry in `devcontainer.env` however it got
there (a leftover from local testing, a copy-paste, an earlier draft of
this very module). Docker's `--env` (from `containerEnv`) outranks
`--env-file` for a key **both specify** — the same precedence this
repository's own `dev/devcontainer.json` already relies on to blank
`GITHUB_TOKEN`/`GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN` rather than
merely omitting them — but that precedence does nothing for a key
`containerEnv` never mentions at all. Rendering the disabled state as the
literal `"false"`, always present, closes this the same way the dev-profile
token-blanking already does, rather than depending on nothing ever having
written to the env-file out of band. On the read side, this proposal's own
research found `COPILOT_ALLOW_ALL`'s documented contract is "set to `true`"
— a specific string comparison, not a general boolean parse — so `verify`
checking for that exact literal (rather than any truthy-looking value)
keeps the check aligned with what Copilot itself actually honors, the same
"verify re-reads effective runtime state independently" discipline this
whole capability is built on. Alternative considered: leave the disabled
state as key-omission and rely on nothing else ever populating the env-file
— rejected once the env-file's actual eviction scope (a fixed secret list,
not "everything") was checked rather than assumed.

**The wrapper is deliberate defense-in-depth and Copier-gated-module
contract consistency, not a documented headless-specific gap the way
Antigravity's is.** GitHub's own docs state that `--allow-all-tools`,
`--allow-all`, and the rest are usable "in either interactive or
programmatic sessions" with no stated divergence, and describe
`COPILOT_ALLOW_ALL` as a plain, always-honored environment-variable
equivalent of `--allow-all` — unlike Antigravity, where
`docs/guides/devcontainers.md` explicitly documents that "headless `agy -p`
… ignores settings allow-rules and auto-denies," a real, stated asymmetry
between interactive and headless behavior that makes Antigravity's wrapper
load-bearing, not merely redundant. This proposal does not manufacture an
equivalent claim for Copilot that its own research did not find. The
wrapper is specified anyway, for two reasons that hold independently of
whether the env var alone would already suffice: first, defense in depth —
`COPILOT_ALLOW_ALL` is only as reliable as every layer between `containerEnv`
and the invoking process actually preserving it, and a wrapper that injects
the flag explicitly survives an intermediate layer that clears or does not
propagate the variable (a `env -i` invocation, a sub-shell that resets its
environment, a future harness update that stops honoring the variable but
keeps honoring the flag); second, `bot-autonomy-bootstrap`'s own general
Copier-gated-harness requirement already anticipates this exact shape
("installs a wrapper if the harness needs one for headless launches, the
same reasoning as Antigravity's") — Copilot is simply the first module
after Antigravity to actually exercise that clause, and doing so keeps
every Copier-gated module structurally uniform rather than making Copilot's
`apply` a special case that skips the wrapper step other modules of its
kind carry. Alternative considered: skip the wrapper, rely on
`COPILOT_ALLOW_ALL` alone — rejected on both grounds above, not merely
because the brief asked for the wrapper.

**Unlike Antigravity's bare `agy`, a bare interactive `copilot` invocation
*does* receive the injected flag — it is not a passthrough case.**
Antigravity's passthrough list keeps bare `agy` unflagged because
`docs/guides/devcontainers.md` states "interactive `agy` honors that policy
directly" through its settings file — the wrapper's flag exists
specifically to cover what the settings file cannot (headless mode).
Copilot has no such asymmetry to route around: `COPILOT_ALLOW_ALL` is a
plain environment variable that an interactive `copilot` session already
sees identically to a headless one, and GitHub's own CLI command reference
categorizes "interactive sessions via `copilot` command with prompts and
slash commands" under **agent task invocation**, the same bucket as `-p`,
separately from the administrative/informational commands
(`login`/`version`/`help`/`update`/`completion`/`init`/`plugin(s)`/`mcp`/
`skill`/`app`) this module's passthrough list actually contains. Both also
match this repository's own stated bot-profile philosophy — "Bot profile —
full autonomy" applies to interactive Antigravity too, not only headless —
so an interactive `copilot` shell in the bot profile is exactly where
allow-all is intended to apply. Porting Antigravity's exact passthrough
shape here without re-deriving it from Copilot's own documented command
categories would have been the wrong kind of consistency: matching the
prior module's *mechanism* instead of its *reasoning*.

**`disableBypassPermissionsMode` is `verify`-only, checked only in the
autonomous state; `apply` never writes it.** Unlike `permission` in
OpenCode's `opencode.json`, this key is not a policy value this module
owns — GitHub's own docs frame it as an administrator/organization
kill-switch (its enterprise-managed-settings form wraps the value in an
`overridable` object; the plain per-user `~/.copilot/settings.json` form is
the same key at user scope). If it reads `"disable"` **while
`use_copilot_cli` is on**, that is very likely a deliberate policy decision
made above this module's authority (an org MDM policy, or a human's own
explicit choice) — forcibly clearing it would mean this module silently
overriding a security control someone else set on purpose, which is a
materially different act than resetting a value this module itself
manages. `verify` failing and naming the conflict is the correct
fail-closed behavior instead: it surfaces the contradiction between "this
repository wants Copilot autonomous" and "this environment's Copilot is
policy-locked out of bypass mode" to a human, rather than either
papering over it or silently accepting a non-autonomous Copilot as if
nothing were wrong. This check does **not** run when `use_copilot_cli` is
off: a locked-out bypass mode is irrelevant to the disabled-by-option
state, where prompt-enabled is already the intended and verified-correct
outcome — checking it unconditionally would fail a default-off consumer
whose own organization separately disables bypass mode via MDM, for a
reason unconnected to this repo's Copier answer (a `task review` round 1
finding against an earlier draft of this Decision, which stated the check
unconditionally). Alternative considered: have `apply` set it to
`"allow-auto-only"` or remove the key — rejected for exactly this reason.

**The Copilot wrapper's `PATH` precedence needs no new `containerEnv.PATH`
entry — it reuses `bot-autonomy-bootstrap`'s existing prepend.** That
change's task 2.5a already adds `/home/vscode/.local/bin` ahead of the
system binaries' directory in the bot `devcontainer.json`'s
`containerEnv.PATH`, specifically so a wrapper placed at `~/.local/bin/<name>`
resolves ahead of any same-named binary anywhere later in `PATH`, regardless
of that binary's actual install location. Since a `PATH` prepend orders by
position, not by a name-to-name mapping, this precedence is generic: it
already applies to `~/.local/bin/copilot` the moment that file exists,
whether Copilot CLI's own npm-installed binary lands at `/usr/bin/copilot`
(the likely location for this image's NodeSource-apt-installed Node, whose
default global-install prefix is system-wide, not `/usr/local`) or
elsewhere — this proposal deliberately does not hardcode which, since the
wrapper resolves its delegate dynamically (see the spec's wrapper
requirement) rather than depending on a specific path (also see Open
Questions). Alternative considered: add a second, Copilot-specific `PATH`
entry — rejected as redundant; the existing prepend already covers any
future `~/.local/bin`-installed wrapper, and this module is exactly that.

**pi is not Copier-gated; oh-my-pi is not Copier-gated.** Both are
broker-style harnesses (`agent-registry.json`'s `family_constraint: {kind:
broker}` on both) with no account or paid-tier product of their own the
Hard Rule's "paid or trial-only SaaS" language could apply to — unlike
Antigravity (a Google product) and Copilot (a GitHub product), each with
its own plan and free-tier limits. This matches Claude Code/Codex/OpenCode's
own unconditional treatment in `bot-autonomy-bootstrap`: those three are not
Copier-gated either, for the same reason.

**pi: state the requirement in terms of resource loading, not prompt
avoidance — the history of two rejected scoping attempts, ending in the
maintainer's no-elevated-trust decision below.** (This heading names where
the analysis below arrives, not a scope this change actually implements —
neither a global nor a workspace-scoped trust grant ships; see the
"Resolved 2026-09-03" Decision for the final, shipped requirement.) An
earlier framing (matching the
originating brief's own wording, "the only prompt is project trust") would
suggest this setting exists to suppress an approval prompt in the bot
profile. Pi's own docs contradict that framing directly: "Non-interactive
modes (`-p`, `--mode json`, and `--mode rpc`) do not show a trust prompt" at
all, regardless of `defaultProjectTrust` — there is no prompt for this
setting to avoid in the bot's actual (headless) use. What the setting
*does* control in non-interactive mode is starkly different per value:
`"ask"` and `"never"` both "ignore" protected project resources
(`.pi/settings.json`, extensions, skills, prompt templates, themes,
system-prompt files) with no saved trust decision, while only `"always"`
loads them. A bot container left at pi's own `"ask"` default would
therefore run every headless pi session with **zero prompts and zero
errors**, silently starting from a stripped-down configuration that ignores
this repository's own `.pi/` customizations — a real effective-policy
divergence of exactly the shape this whole capability exists to catch, just
one that manifests as silently degraded capability rather than a blocking
prompt.

A first draft of the fix set `defaultProjectTrust: "always"` **globally** —
correctly targeting resource-loading, but at the wrong scope. Pi's own
docs state plainly what trusting a project actually grants: "install
missing project packages, and execute project extensions" — code
execution, not configuration. `defaultProjectTrust` is the **fallback**
pi consults only when no more specific, per-directory decision applies
("Saved decisions are stored by canonical directory in
`~/.pi/agent/trust.json`, and the closest saved decision on the current or
parent path applies before the global default"), so setting the fallback
itself to `"always"` would extend automatic trust — automatic *code
execution* — to every repository the bot's `~/.pi` installation is ever
pointed at, not only this one. That is a materially different and
materially broader grant than what any of the other four bot-autonomy
modules make: Claude Code's `bypassPermissions`, Codex's
`danger-full-access`, Antigravity's `always-proceed`, and OpenCode's
`permission: allow` all remove a *prompt in front of the model's own,
already-requested tool calls* — they do not make the harness
automatically execute repository-shipped extension code before the model
starts reasoning at all. And this repository is a concrete instance of
exactly that exposure: its own Foreman configuration already classifies
every dispatched unit `untrusted-input` on this public repo (AGENTS.md),
precisely because automated agents here can end up working with content
this repository does not control. Global `defaultProjectTrust: "always"`
would have the bot auto-execute `.pi/extensions` from *any* repository it
opens — a sibling clone under investigation, a dependency being read, a
Foreman-dispatched cross-repo task — not only the one this container was
built for.

**A second draft narrowed the scope to a workspace-keyed `~/.pi/agent/trust.json`
entry — also rejected, on a third pass of the same review.** The reasoning
looked sound: `apply` would record a trusted decision for the current
workspace's own canonical directory only, leaving `defaultProjectTrust` at
pi's safe default, so "every repository this pi installation ever touches
is trusted" would narrow to "the one repository this container was built
for." That narrowing is real, but it does not close the gap it was meant
to: pi's trust decisions are keyed by **directory path**, not by content or
commit, and by pi's own documented rule the closest saved decision on the
current directory **or any parent** applies. A path-keyed decision
therefore does not stay bound to the content that was present in that
directory when the decision was recorded — it silently re-applies to
whatever occupies that same path *later*, including an untrusted branch
checked out into the same workspace (a PR review, an `gh pr checkout` in
place rather than a fresh worktree — a real pattern, not a hypothetical
one, in a repository whose own Dev Loop routes most other work through
worktrees but does not forbid this) — and, independently of any branch
question, it extends to **anything cloned or checked out underneath** that
trusted path, because a nested directory's "closest decision" is its
trusted parent's. Neither failure mode requires an adversarial branch to be
checked out into the exact workspace `apply` ran against by name; the
second one fires for any subdirectory clone regardless of how that
workspace's own top-level content behaves. This is not a smaller version of
the first draft's mistake — it is the **same class of mistake**, wrong
axis: the first granted trust too broadly across *repositories*, this one
grants it too durably across *time and nested paths* within one.

**Both designs are rejected as unsafe defaults; this proposal escalates
rather than shipping a third, unverified attempt.** Pi's own trust
primitive gives a bot-autonomy module exactly two tools — a global
fallback and a path-keyed persisted decision — and neither can express
"trust the content this repository's own maintainer committed, regardless
of what else ever occupies this same directory path." Building a safer
mechanism (content hashing, commit pinning, or an isolation boundary that
makes path-reuse impossible) is real engineering this proposal is not
chartered to design on the spot inside a challenge-round fix, and doing so
under the pressure of "the cap is almost reached" is exactly the reflexive-fixing
failure mode this whole review process exists to damp — a third patched
design, adjudicated by nobody but this same session, would not actually be
more trustworthy than the first two, only less scrutinized. The requirement
therefore falls back to the one state this proposal's own research can
actually stand behind: no elevated trust in the bot profile at all,
matching dev exactly, with `verify` failing closed on **either** of pi's
trust-granting surfaces — `defaultProjectTrust` set to `"always"`, or an
applicable saved decision already present in `~/.pi/agent/trust.json` —
regardless of cause (a `task review` round 1 finding sharpened this from
checking only the global fallback: a pre-existing path-keyed decision,
however it got there, would otherwise carry the exact exposure the
rejected workspace-scoped design had, just reached through the file this
module never writes rather than the one it does). This accepts a capability gap
(the bot's headless pi sessions silently ignore this repository's own
`.pi/` customizations) in exchange for not shipping a security gap this
proposal's own review found twice.

**Resolved 2026-09-03 — maintainer decision: option (a), accept the
no-elevated-trust fallback as the shipped requirement.** This proposal
presented four options once both designs above were rejected:

(a) **Accept the fallback as final** — the bot's headless pi sessions never
load this repository's own `.pi/` project resources. Simplest, safest,
costs whatever capability those resources would have added.
(b) **Accept the workspace-scoped `trust.json` risk explicitly** —
reinstate the rejected scoped design, with the branch-checkout and
nested-clone exposure it carries treated as an acknowledged, bounded risk
(for example, if this repository's own operational practice can be trusted
to never check an untrusted branch out into the same workspace path a
bot's `apply` already trusted, and never clone another repository
underneath it) — a judgment call about this repository's actual workflow
discipline this proposal was not positioned to make unilaterally.
(c) **Build a stronger mechanism** — content-hash or commit-pinned trust
verification before loading `.pi/` resources, or a container/mount
boundary that makes path-reuse-with-different-content structurally
impossible. Real engineering, out of this proposal's scope to design
inline; would need its own proposal if chosen.
(d) **Something else** — a scope or mechanism this proposal did not
consider.

The maintainer chose **(a)** — the safe fallback already in the spec
becomes the decided requirement, not merely a placeholder pending further
input. The stated reasoning: #1137's acceptance criteria require every
supported harness to reach a **no-prompt** state, and option (a) already
satisfies that for pi — pi's non-interactive modes never show a trust
prompt regardless of this setting (see the resource-loading Decision
above), so the *only* thing option (a) costs relative to the rejected
designs is the capability of loading this repository's own `.pi/` project
resources in headless sessions, not compliance with #1137. Option (b)
remains on record as a **possible future, explicit opt-in**, not a
default: if the maintainer later judges its risk acceptable for a
specific, bounded scenario, it can be proposed as a deliberate,
separately-reviewed addition rather than reopened as the default here.
This decision closes the escalation from the design's own review
process — it does not reopen either rejected design's technical analysis,
which stands as written above.

**oh-my-pi: ship the module against this proposal's own researched finding,
with the brief's fail-closed fallback retained as a stated contingency
rather than the default state.** The originating brief asked for a bounded
implementation-time spike specifically because it did not know whether a
mechanism existed, and specified that until it was known, the module should
default to `unsupported-with-reason` so the completeness test stays honest
and `verify` fails closed if `omp` is ever installed and still prompts.
This proposal's own research, performed while writing it and cited in
Context above, found and directly quoted a documented, schema-default `yolo`
approval mode at the exact pinned release tag (`v18.1.2`, not an unpinned
branch) — one of the three candidate mechanisms the brief itself named
("a config key in `~/.omp/agent/config.yml`"). Treating that evidence as if
it did not exist, and shipping a placeholder `unsupported` entry anyway,
would not be the caution the brief intended; it would be declining to act
on a verified fact, which this repository's own review culture treats as
a defect in the other direction (per the Codex-review discipline in
AGENTS.md: "Treat Codex findings as hypotheses… Verify it against the
actual implementation… Fix only confirmed findings" — the same standard
applied here to the brief's own premise). At the same time, a design
document's research is not a running binary: this proposal cannot execute
`docker build` against the shared image or invoke `omp config get` in this
sandbox to confirm the documentation matches shipped behavior byte for
byte. The resolution keeps both properties: the spec's primary path is the
real module, built against cited, pinned-tag-verified evidence; the spec
also states the brief's original fallback as an explicit, still-live
contingency scenario, triggered specifically by implementation-time
confirmation contradicting the documentation, not by default. This is a
narrower, more confident task than the brief's original "determine whether
a mechanism exists at all" — it is "confirm a specific, cited claim against
the real binary," bounded by construction.

**oh-my-pi: `apply` writes `tools.approvalMode: yolo` explicitly rather than
relying on the schema default.** Three reasons converge: first, the
project-level override risk is real and documented (`<cwd>/.omp/config.yml`
sits above global config in oh-my-pi's own precedence chain, exactly the
shape that already motivated OpenCode's resolved-config `verify`) — a
repository whose own `.omp/config.yml` sets `always-ask` would silently
defeat a policy that only ever relied on the *global* schema default, and
writing the global value explicitly does not fix that either (hence
`verify` reading the fully resolved value, not the global file, matching
OpenCode's own pattern exactly); second, a future oh-my-pi release could
change its own schema default without notice, and an explicit write is not
exposed to that; third, an image built before the config file exists at all
starts from *no* file, and this module's `apply` is what brings the durable
state into existence on the persisted `~/.omp` volume in the first place —
"rely on the default" has nothing to write to a volume that starts empty.
Writing explicitly is consistent with how every other bot-autonomy module
in this capability already behaves (none of the four existing modules
relies on a harness's own out-of-the-box default even where one happens to
already match the bot policy).

**Verify's mechanism splits two ways across the five modules this change
actually ships policy for, by what each harness's own config layering
actually does — not an inconsistency, a deliberate match to each shape.**
Claude Code's `/etc/claude-code/managed-settings.json` and Codex's
`/etc/codex/managed_config.toml` are both `/etc`-scoped by design, with no
per-repository override layer to miss — a plain global-file read is
complete. Copilot's `~/.copilot/settings.json` is the same shape: documented
as global-only, with no repository-tracked settings file this proposal's
research found alongside it. pi's `verify` (see the pi Decision above)
reads two plain files rather than one, but is the same *kind* of check —
no live resolved-config command, because this module does not attempt the
project-scoped grant that would have made one necessary: it checks
`defaultProjectTrust` for one specific dangerous value in the file pi's
docs confirm is "Global setting only," **and** `~/.pi/agent/trust.json`
for an applicable saved decision (current workspace or a parent of it) —
both are files this module itself never writes, so it is detecting
external state on both surfaces, not resolving a config layer of its own.
OpenCode
and oh-my-pi are the two modules where a project-level config file
genuinely exists and genuinely overrides the global default
(`opencode.json`/`.opencode/opencode.json` project-over-global layering;
oh-my-pi's own documented `<cwd>/.omp/config.yml` precedence) — for those
two, a plain global-file read would recreate exactly the effective-state
gap this whole capability exists to close, so `verify` asks the harness's
own resolved-config command instead, from the directory being verified;
this mirrors `bot-autonomy-bootstrap`'s own reasoning for why OpenCode's
`verify` differs from Claude Code's and Codex's, applied a second time now
that a fifth module (oh-my-pi) exists with the same shape.

**Registry-table reconciliation is a removal, not a fresh addition, and it
happens in this change's implementation, not `bot-autonomy-bootstrap`'s.**
`bot-autonomy-bootstrap`'s own tasks.md (task 1.2) and design.md already
commit its implementation to writing `copilot-cli`/`pi`/`oh-my-pi` into the
`unsupported` table with `reason: "pending bot-autonomy-new-harnesses"`
before this change exists in implemented form — that entry's own reason
text names this change specifically as the thing that resolves it. This
change's implementation task is therefore to delete those three lines and
add three module dispatch entries (two unconditionally, one via the
Copier-gate table) in the same PR that adds the modules themselves, so the
registry-completeness unit test never observes a moment where a slug has
both a module and a stale `unsupported` entry (the completeness test
`bot-autonomy-bootstrap`'s task 1.3 adds already fails a slug covered by
more than one bucket).

## Risks / Trade-offs

- [Risk] Implementation-time confirmation could show oh-my-pi's real
  `v18.1.2` binary does not honor `tools.approvalMode: yolo` as documented →
  [Mitigation] the spec's own contingency scenario is the answer, not an
  open question this design leaves unresolved: oh-my-pi becomes an
  `unsupported` entry with a reason stating what was actually found, its
  exemption does not survive `omp` being installed (per
  `bot-autonomy-bootstrap`'s uniform rule), and `verify` fails closed on any
  bot container where `omp` is present and still prompt-enabled — the exact
  fail-closed behavior the originating brief asked for, just reached
  through a confirmation step instead of being the default.
- [Risk] If oh-my-pi's contingency fires, the shared image would still
  install `omp` unconditionally (an unrelated `harness-matrix` decision this
  change does not reopen — see Non-Goals), meaning **every** consumer's bot
  container would fail closed the moment its pin picks up the image,
  indefinitely, not just harmon-init's own → [Mitigation] this is a real,
  named consequence this design does not paper over: it would mean a human
  decision is needed (Copier-gate oh-my-pi's own installation in a
  `harness-matrix` follow-up, or accept oh-my-pi as dev-profile-only without
  this capability's guarantee) — out of scope for this change to decide
  unilaterally, and explicitly called out here rather than silently
  resolved by weakening the fail-closed contract to route around it. Given
  the strength of the cited, pinned-tag-verified evidence in Context, this
  is assessed as unlikely, not eliminated.
- [Risk] An enterprise's own MDM-managed `disableBypassPermissionsMode`
  policy could block Copilot's bypass mode regardless of anything this
  module writes, and this module's `verify` can only observe the per-user
  `~/.copilot/settings.json` value, not necessarily a merged
  enterprise-plus-user effective value Copilot's own docs describe but do
  not fully specify the inspection surface for → [Mitigation] `verify`
  checks the one value it can reliably read and is documented to matter
  (the per-user key); an environment where an org MDM policy additionally
  blocks bypass mode is an organizational control this repository has no
  authority over and should not attempt to route around — this is a
  disclosed residual, matching this repository's general stance that these
  are probabilistic controls to get right and disclose, not guarantees to
  chase into every administrative layer.
- [Risk] A related, open upstream report (`github/copilot-cli#4528`,
  "Non-interactive sessions bypass `disableBypassPermissionsMode`") suggests
  headless Copilot sessions might not honor this kill-switch the same way
  interactive ones do → [Mitigation] this does not change what `verify`
  should check — the key is still the one documented, inspectable signal
  for whether bypass mode is administratively blocked, and if headless mode
  turns out to bypass the kill-switch entirely, that would only mean this
  module's `autonomous` state is *more* reliably non-interactive, not less;
  noted here as a citation for whoever implements this, not as a
  requirement change.
- [Risk] Porting Antigravity's exact wrapper shape (passthrough list,
  bare-invocation handling) to Copilot without re-deriving it from Copilot's
  own documented command surface could silently miss a Copilot-specific
  subcommand or get the bare-invocation case backwards → [Mitigation] the
  passthrough list and the bare-`copilot`-gets-the-flag decision above are
  both sourced from GitHub's own CLI command reference's stated
  administrative-vs-agent-task split, not copied from Antigravity's list by
  analogy; implementation should re-verify this list against the actually
  installed `copilot --help` output at the pinned version, the same
  "verify at implementation time" discipline `harness-matrix`'s own design
  already applies to its own researched claims.
- [Risk] pi's non-interactive sessions will silently ignore this
  repository's own `.pi/` project resources for as long as the maintainer's
  2026-09-03 decision (option (a)) stands → [Mitigation] this is the
  accepted, disclosed, *decided* consequence, not an oversight (see the
  pi "Resolved 2026-09-03" Decision above) — a capability gap the
  maintainer chose deliberately over the security gap either rejected
  design would have shipped, specifically because #1137 requires no
  prompts, not project-resource loading. It remains reversible: nothing
  about the no-op-by-default module blocks a future, separately-proposed
  change from implementing option (b) or a stronger mechanism if the
  maintainer later decides differently.
- [Risk] A future contributor could "fix" the capability gap above by
  quietly reintroducing one of the two rejected designs, having forgotten
  or not read why they were rejected → [Mitigation] the spec's own
  requirement text states both rejected designs and the specific
  mechanism of each one's failure inline, not only in this design
  document — a reader implementing against the spec alone, without this
  file, still sees the warning.
- [Risk] This change's own doc edits (`devcontainers.md`, `security.md`)
  land after `bot-autonomy-bootstrap`'s implementation, which itself
  restructures `devcontainers.md` (dedupes a currently-duplicated Codex
  paragraph, per its own task 4.1) and adds the bot-autonomy boundary
  section to `security.md` for the first time (per its task 4.3, currently
  empty of any such content) → [Mitigation] this proposal deliberately does
  not cite specific line numbers for those edits the way `harness-matrix`'s
  tasks.md cites exact `devcontainers.md` line ranges for its own
  Gemini-removal edits — this change's implementation lands after
  `bot-autonomy-bootstrap`'s, so the target structure will already exist by
  then; tasks.md below describes the additions structurally (extend the
  bot-autonomy boundary-contract section with each new harness's
  subsection) rather than by line number, so it stays correct regardless of
  exactly how `bot-autonomy-bootstrap`'s implementation shapes that section.

## Migration Plan

- A single implementation PR (not this planning change) adds the three
  modules, updates the registry `unsupported` table, adds the Copier
  answer and its rendered marker, and extends the doc/test surfaces. It
  must *merge* after `bot-autonomy-bootstrap`'s implementation (PR #1150) —
  its modules dispatch through `bot-autonomy.sh`, which does not exist on
  `main` until then — but development may proceed on a branch stacked on
  PR #1150 (or otherwise informed by its design) in parallel, rebasing and
  reconciling against whatever `bot-autonomy-bootstrap` actually ships
  before this change's own PR is finalized (tasks.md task 0.1). It touches
  both the root `.devcontainer/` and its `template/` twin in the same PR,
  per AGENTS.md dogfood parity; `task test:dogfood-parity` and
  `test:dogfood-structure` gate it.
- It must itself merge before the rolling `sync-pin` PR that bumps
  `.devcontainer/Dockerfile` (root + `template`) to the image digest
  `harness-matrix`/#1149 published. This is the same "modules-before-pin"
  invariant `bot-autonomy-bootstrap`'s own design.md already establishes for
  `copilot-cli`/`pi`, generalized to `oh-my-pi` — backed the same way, and
  by precisely the same two-plus-one mechanism, no stronger and no weaker:
  neither `bot-autonomy-bootstrap`'s task 4.6 checklist item on the sync-pin
  PR's own body ("`bot-autonomy-new-harnesses` has merged, covering every
  harness this bump installs") nor the container-assertion job's red/green
  result is a branch-protection merge block — a reviewer can still click
  merge past an unchecked item or a non-required red job, exactly as with
  any other checklist or optional check on this or any GitHub repository.
  What makes the ordering more than a hopeful convention is the third,
  independent piece: `bot-autonomy.sh verify` failing closed at
  post-create/post-start on any
  real bot container built from a bad-ordering pin regardless of whether
  either signal was noticed.
- No data migration for Copilot or pi: neither module writes a persisted
  policy value (Copilot's `apply` only installs a wrapper file, not user
  data; pi's `apply` is a no-op per the maintainer's decided requirement
  above), so there is nothing to restore before a revert for
  either — removing Copilot's wrapper on rollback is sufficient and
  requires no ordering care.
- oh-my-pi's persisted-volume policy write (`~/.omp/agent/config.yml`) is
  **not** self-resetting on revert, exactly like Antigravity's and
  OpenCode's. Rollback is: run that module's `restore` **before** reverting
  the implementation PR — while the code implementing `restore` still
  exists to run — then revert. Reversing that order fails for the same
  reason `bot-autonomy-bootstrap`'s own Migration Plan already states: a
  reverted checkout no longer contains the module's restore logic to
  invoke against an already-`apply`'d persisted volume.
- Rollback for this change's implementation as a whole, in order: first run
  `restore` for oh-my-pi against every bot container that had already run
  `apply` (and, if the Copilot module's wrapper is considered part of the
  rollback surface, remove `~/.local/bin/copilot`, though this carries no
  persisted value to lose), then revert the PR.

## Open Questions

- ~~How should pi's bot-profile project trust actually be resolved?~~
  **Resolved 2026-09-03** — see the "Resolved 2026-09-03" Decision above,
  in the pi section: the maintainer chose option (a), accepting the
  no-elevated-trust fallback as the shipped requirement, with option (b)
  (the workspace-scoped `trust.json` design) recorded as a possible future
  explicit opt-in rather than the default. The four options this proposal
  originally characterized are preserved in that Decision's own text for
  the record; they are not repeated here now that the choice among them is
  made.
- The exact filesystem path npm's global install places the `copilot` and
  `pi` binaries at in this image (`/usr/bin` is the likely location for a
  NodeSource-apt-installed Node's default global prefix, but this proposal
  did not confirm it against the actual built image). This does not change
  the spec, the approach, or the task breakdown: the Copilot wrapper is
  specified to resolve its delegate dynamically rather than by a hardcoded
  path, exactly so this detail can be confirmed at implementation time
  (`npm root -g` / `command -v copilot` against the real image) without
  touching the design.
- Whether `github/copilot-cli#4528`'s report of non-interactive sessions
  bypassing `disableBypassPermissionsMode` reflects current, intended
  behavior or an acknowledged bug. Noted in Risks; does not change what
  `verify` checks either way, so left for whoever implements this to keep
  an eye on rather than resolved here.
