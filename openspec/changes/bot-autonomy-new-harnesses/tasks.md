## 0. Preconditions

- [ ] 0.1 Before this change's own implementation PR is finalized and
      merged, confirm `bot-autonomy-bootstrap`'s implementation (PR #1150)
      has actually merged to `main` first — `.devcontainer/scripts/bot-autonomy.sh`
      and `.devcontainer/config/bot-autonomy/{claude-code,codex-cli,antigravity,opencode}.sh`
      exist on `main`, `agent-registry.json`'s `unsupported` table (wherever
      `bot-autonomy.sh` defines it) already carries `copilot-cli`, `pi`, and
      `oh-my-pi` entries reasoned "pending `bot-autonomy-new-harnesses`";
      verify by reading that table directly rather than assuming its exact
      shape from this proposal's Context. This is a **merge-order**
      requirement, not a development-order one: work on sections 1-6 may
      proceed on a branch stacked on PR #1150 (or otherwise informed by its
      design) in parallel with that PR's own review, since every task below
      dispatches through infrastructure PR #1150 defines and this change
      cannot run against real infrastructure until it exists — but rebase
      onto `main` and reconcile against whatever `bot-autonomy-bootstrap`
      actually ships (module names, table shape, script locations may
      differ from this proposal's Context) before finalizing this change's
      own PR, and do not merge this change's PR until PR #1150's merge is
      confirmed on `main`.

## 1. GitHub Copilot CLI module

- [ ] 1.1 Add `use_copilot_cli` to `copier.yml` (default `no`,
      `when: "[[ devcontainer ]]"`, validator mirroring
      `use_antigravity_cli`'s `Enable DEVCONTAINER before …` pattern), with
      help text documenting Copilot's account requirement and free-tier/
      private-repo terms next to the question, adapting the caveat language
      `harness-matrix`'s proposal.md already drafted for this purpose;
      verify with `task check` and a rendered-template diff showing the new
      question appears in `copier copy --defaults` output
- [ ] 1.2 Add `use_copilot_cli: true` to `.dogfood-answers.yml` with a
      one-line comment matching `use_antigravity_cli`'s existing comment
      shape; verify with `task audit:dogfood` showing no new unexplained
      drift
- [ ] 1.3 Add `containerEnv.HARMON_BOT_AUTONOMY_COPILOT` (rendered from
      `{{ use_copilot_cli }}` to the literal `enabled`/`disabled`) and
      `containerEnv.COPILOT_ALLOW_ALL` (rendered to the exact literal
      `"true"` when the answer is on, the exact literal `"false"` when it
      is off — **always present, never omitted in either state**) to the
      **bot** `devcontainer.json` jinja twin only — **not**
      `dev/devcontainer.json`, unlike the existing
      `HARMON_BOT_AUTONOMY_ANTIGRAVITY` marker `bot-autonomy-bootstrap`
      added to both: nothing in the dev profile reads either new entry, and
      rendering `COPILOT_ALLOW_ALL` into dev too would hand a human's own
      interactive Copilot CLI session in the dev profile full allow-all
      permissions (design.md - Decisions). Always rendering the key (rather
      than omitting it when disabled) is load-bearing, not stylistic: the
      bot profile also loads `.devcontainer/devcontainer.env` via
      `--env-file`, `init-env.sh` does not recognize or evict
      `COPILOT_ALLOW_ALL` (it is not one of the secrets that script
      manages), and `containerEnv` only outranks `--env-file` for a key it
      actually specifies — an omitted key lets a stale out-of-band
      `COPILOT_ALLOW_ALL=true` in that file survive a disabled render
      undisturbed; set the matching literal values in this repository's own
      root `.devcontainer/devcontainer.json` only (`enabled`/`"true"`,
      matching `.dogfood-answers.yml`) and confirm
      `.devcontainer/dev/devcontainer.json` carries neither; verify by
      rendering a copy with `use_copilot_cli: true` and one at the default,
      confirming the rendered **bot** `devcontainer.json`'s `containerEnv`
      carries the expected literal in both cases (never omitted) and the
      rendered **dev** `devcontainer.json` carries neither key in either
      case; ALSO verify with a fixture that pre-seeds
      `COPILOT_ALLOW_ALL=true` in a scratch `devcontainer.env` before
      building the disabled render, confirming the container's effective
      value is `"false"`, not the stale `"true"`
- [ ] 1.4 Add `.devcontainer/config/bot-autonomy/copilot.sh`: `apply` reads
      `$HARMON_BOT_AUTONOMY_COPILOT`; WHEN `enabled`, confirms
      `$COPILOT_ALLOW_ALL` is the exact literal `true` in its own process
      environment (failing loudly if not — a render inconsistency) and
      installs `~/.local/bin/copilot`; WHEN not `enabled`, removes
      `~/.local/bin/copilot` if present and does not touch
      `$COPILOT_ALLOW_ALL` (it is not writable by this script either way —
      the render already guarantees it reads `false`); `verify` asserts the
      wrapper's presence/absence matches the marker and that
      `$COPILOT_ALLOW_ALL` is the exact literal `true` (enabled) or `false`
      (disabled) in both states — not merely present/absent, and not any
      other truthy-looking value. **Only when the marker reads `enabled`**,
      `verify` additionally checks that `~/.copilot/settings.json`'s
      `permissions.disableBypassPermissionsMode` is not `"disable"` — this
      check does NOT run in the disabled state, where a locked-out bypass
      mode is irrelevant (prompt-enabled is already the intended outcome
      there) and would otherwise fail a default-off consumer whose own org
      separately locks bypass mode via MDM, unconnected to this repo's
      Copier answer. Verify by running `bot-autonomy.sh apply verify` in a
      scratch fixture with the marker `enabled` and `disabled`, a fixture
      that sets `COPILOT_ALLOW_ALL` to a truthy-but-wrong value (`"1"`,
      `"yes"`) and confirms `verify` fails naming Copilot, a fixture with
      the marker `enabled` AND `disableBypassPermissionsMode: "disable"`
      confirming `verify` still **fails** naming Copilot (the positive
      case — proving the check actually runs when it matters, not just
      that it's skipped when it doesn't: a fixture set containing only the
      disabled-state pass case would let an implementation that never
      checks this key at all, in either state, satisfy every listed
      fixture), a complementary fixture with the marker `disabled` AND
      `disableBypassPermissionsMode: "disable"` confirming `verify` still
      **passes** (the kill-switch is irrelevant here), and a
      toggle-off-after-apply fixture confirming a prior
      autonomous state reaches disabled (wrapper absent,
      `COPILOT_ALLOW_ALL=false`) after a re-render flips the marker
- [ ] 1.5 Add the `~/.local/bin/copilot` wrapper script itself: injects
      `--allow-all` on a bare `copilot` invocation and on `copilot -p`/
      `--prompt` unless the invocation already carries full allow-all
      coverage explicitly — `--allow-all`, `--yolo`, or all three of
      `--allow-all-tools`/`--allow-all-paths`/`--allow-all-urls` together —
      appending `--allow-all` even when only *some* of the three narrower
      flags are present (a partial flag is not full coverage, and skipping
      injection there would leave that invocation restricted for whichever
      dimension its own flags did not name — the exact sanitized-environment,
      `env -i`-with-no-`COPILOT_ALLOW_ALL`-fallback case this wrapper exists
      to cover); passes `login`, `version`, `--version`, `help`,
      `-h`, `--help`, `update`, `completion`, `init`, `plugin`, `plugins`,
      `mcp`, `skill`, and `app` through unmodified; resolves and execs the
      real, shared-image-installed `copilot` binary by finding the next
      `copilot` on `PATH` after excluding its own directory (confirm the
      actual install location — likely `/usr/bin/copilot` for this image's
      NodeSource-apt Node, per design.md - Open Questions — against the
      real built image rather than assuming it) — never a hardcoded path;
      verify with a fixture invoking the wrapper directly (not via a
      sourced shell) asserting the flag lands on a bare invocation, on a
      partial-flag invocation (e.g. `--allow-all-tools` alone), and on
      `-p`, is absent on every passthrough case, and that it resolves the
      real binary correctly
- [ ] 1.6 Confirm the wrapper's `PATH` precedence needs no new
      `containerEnv.PATH` entry — `bot-autonomy-bootstrap`'s existing
      `/home/vscode/.local/bin` prepend (its task 2.5a) already covers it;
      verify with `docker exec <container> copilot --version` (no
      login/interactive shell) resolving `~/.local/bin/copilot`, not the
      system binary

## 2. pi module

- [ ] 2.1 First, confirm `~/.pi/agent/trust.json`'s actual read format
      against the real `pi` binary: in a scratch container or fixture, run
      `pi` interactively once in a throwaway workspace, use `/trust` to
      record a decision, and inspect the resulting file (key format —
      canonical path? something else? — and how to tell whether a given
      workspace path matches an entry for itself or a parent). This is a
      bounded confirmation for a **read-only** check, not the rejected
      write mechanism reopened: task 2.1 below never writes this file, it
      only needs to detect whether something else already has. Then add
      `.devcontainer/config/bot-autonomy/pi.sh` as the
      **no-elevated-trust requirement the maintainer decided** (design.md -
      Decisions, "Resolved 2026-09-03" — option (a); do not reopen that
      decision inside this task, e.g. by implementing the rejected
      workspace-scoped `trust.json` *write* instead). `apply` writes
      nothing: it does not touch `~/.pi/agent/settings.json`'s
      `defaultProjectTrust`, and does not write `~/.pi/agent/trust.json`,
      in either profile. `verify` fails, naming pi, if **either** of pi's
      two trust-granting surfaces is found active: `defaultProjectTrust`
      set to `"always"` in `~/.pi/agent/settings.json`, or an applicable
      saved decision (for the current workspace or, per pi's
      closest-decision-on-current-or-parent-path rule, any parent of it)
      in `~/.pi/agent/trust.json`, using the confirmed read format —
      regardless of whether this module, a stale volume, an interactive
      `/trust` run, or a manual edit produced either one. There is no
      `restore` (nothing is ever backed up, because nothing is ever
      overwritten). Verify with fixtures covering: `apply` on a fresh
      volume leaves `~/.pi` exactly as `pi`'s own install left it (no new
      keys, no new files beyond what pi itself creates); `verify` passes
      when neither surface is active; `verify` fails naming pi when a
      fixture pre-seeds `defaultProjectTrust: "always"` (proving the
      fail-closed check works regardless of how that value got there — do
      not special-case "this module didn't write it" in the fixture);
      `verify` **also** fails naming pi when a fixture pre-seeds a
      **trusted** `trust.json` decision for the current workspace's own
      directory, and separately when it pre-seeds one for a *parent*
      directory of the current workspace (proving the parent-path rule is
      actually checked, not only an exact-path match); `verify` **passes**
      when a fixture pre-seeds pi's own **explicit distrust** decision
      (whatever pi's confirmed format uses for "not trusted") for the
      current workspace's own directory or a parent — the positive case
      proving `verify` distinguishes a *trusted* saved decision from any
      other saved decision, not merely "an entry exists at all" (a naive
      implementation that fails closed on *any* `trust.json` entry for an
      applicable path, trusted or not, would otherwise satisfy every other
      fixture in this list while incorrectly failing a genuinely safe
      state); `verify` passes when `trust.json` carries a (trusted or
      untrusted) decision for an unrelated, non-parent workspace only; and
      a fixture confirming bot and dev profiles behave identically for this
      module (no per-profile branch exists to test)
- [ ] 2.2 Confirm the dev profile's post-create never calls this module
      (mirroring `bot-autonomy-bootstrap`'s own "dev never calls
      `bot-autonomy.sh`" wiring — this module is only ever dispatched from
      the bot's own `apply`/`verify` calls, so no separate dev-exclusion
      logic is needed inside the module itself, even though its current
      behavior happens to be identical either way); verify by grepping
      `.devcontainer/dev/post-create.sh` for any reference to this module
      or `bot-autonomy.sh` and confirming none exists
- [ ] 2.3 Add a fixture proving the capability-gap claim in design.md's pi
      Decision, so it is a tested, documented fact rather than an assertion:
      a non-interactive `pi -p` run against a fixture repository carrying
      `.pi/settings.json` (or another trust-requiring resource), with this
      module's `apply` having run (writing nothing, per task 2.1), silently
      ignores that resource — no error, no prompt, pi's own non-interactive
      default. This is not a task to "make pass" by adding logic; it exists
      to keep the accepted gap visible and tested rather than something a
      later change could silently regress further (e.g. a future edit that
      makes it error instead of silently ignore, which would be a
      *different*, newly-introduced problem this fixture would catch)

## 3. oh-my-pi module

- [ ] 3.1 Confirm this proposal's researched mechanism
      (`tools.approvalMode: yolo` in `~/.omp/agent/config.yml`, `omp config
      get tools.approvalMode --json` as the resolved-value read, project
      override at `<cwd>/.omp/config.yml`) against the actually installed
      `omp` binary at the pinned `v18.1.2` release, once it is present in a
      built image (this repository's own root pin, or a scratch build
      against `images/devcontainer/Dockerfile` directly) — this is the
      bounded confirmation design.md's Decisions describe, not an
      open-ended search: it is checking a specific, cited claim, not
      determining from scratch whether any mechanism exists. Record the
      result (confirmed as researched, confirmed with differences, or
      contradicted) in this task's own completion note
- [ ] 3.2 **IF task 3.1 confirms the mechanism** (as researched, or with
      only minor differences that do not change the contract): add
      `.devcontainer/config/bot-autonomy/oh-my-pi.sh`: unconditional; `apply`
      sets `tools: { approvalMode: yolo }` in `~/.omp/agent/config.yml`,
      capturing the prior value (or its absence) before the first
      overwrite, gated on no backup existing yet, matching OpenCode's
      `apply-antigravity-settings.sh`-derived shape; `verify` reads the
      **fully resolved** value via
      `omp config get tools.approvalMode --json` run from the workspace
      being verified (not the global file alone), failing and naming the
      project-level `.omp/config.yml` when that is the cause of a
      divergence; `restore` puts the captured value back and clears the
      backup; verify with fixtures covering fresh-file creation, overriding
      an existing `"always-ask"`/`"write"` value, preserving unrelated
      keys, an `apply → apply → restore` sequence, and a project-level
      `.omp/config.yml` overriding the global default back to a non-yolo
      mode
- [ ] 3.3 **IF task 3.1 contradicts the mechanism**: do not add a module.
      Instead, update the `unsupported` entry `bot-autonomy-bootstrap`'s
      implementation already added for `oh-my-pi` (reason "pending
      `bot-autonomy-new-harnesses`") to state what was actually found,
      keeping `executable: "omp"` unchanged; verify the registry-completeness
      unit test still passes (oh-my-pi resolves to exactly the `unsupported`
      bucket) and add a fixture installing a fake `omp` executable while
      `oh-my-pi` is still `unsupported`, confirming `bot-autonomy.sh verify`
      fails naming it — matching `bot-autonomy-bootstrap`'s existing pattern
      for `copilot`/`qwen`/`goose`/`clite` (its tasks 1.4/4.5). File a
      follow-up issue for the resulting rollout question (design.md - Risks:
      the shared image still installs `omp` unconditionally) rather than
      resolving it in this PR
- [ ] 3.4 Whichever of 3.2/3.3 applies, confirm no path through this
      module's logic can leave `omp` both installed and silently uncovered
      — verify by running the registry-completeness unit test with a real
      `omp` binary present (a scratch container or a `PATH`-injected fake)
      and confirming a pass under 3.2's real module or a fail-naming-oh-my-pi
      under 3.3's `unsupported` entry, never a silent pass with no coverage

## 4. Registry coverage reconciliation

- [ ] 4.1 Remove the `copilot-cli`, `pi`, and (only if task 3.2 applies)
      `oh-my-pi` placeholder entries from the `unsupported` table
      `bot-autonomy-bootstrap`'s implementation added, in the same PR that
      adds the corresponding real modules — never leaving a slug covered by
      both a module and a stale `unsupported` entry, even transiently
      within the PR's own commit history; verify with the registry-
      completeness unit test (`bot-autonomy-bootstrap`'s task 1.3) failing
      on a deliberately-reintroduced stale entry and passing on the real
      state
- [ ] 4.2 Verify every one of the registry's harness slugs still resolves
      to exactly one of the three coverage buckets after this change
      (`copilot-cli` → module, `pi` → module, `oh-my-pi` → module or
      updated `unsupported` per task 3's outcome, every other slug
      unchanged from `bot-autonomy-bootstrap`'s own implementation); verify
      with the full registry-completeness unit test run, not a partial diff

## 5. Docs, template parity, and CI coverage

- [ ] 5.1 Extend `docs/guides/devcontainers.md`'s bot-autonomy boundary
      section (whatever structure `bot-autonomy-bootstrap`'s own task 4.1
      dedup leaves in place — do not assume specific line numbers) with
      Copilot CLI's, pi's, and oh-my-pi's boundaries, matching the level of
      detail already given to Claude Code/Codex/Antigravity/OpenCode;
      verify with `task lint:markdown`
- [ ] 5.2 Extend `docs/architecture/security.md`'s bot-autonomy boundary
      contract section (added by `bot-autonomy-bootstrap`'s task 4.3) with
      the same three boundaries; verify with `task lint:markdown`
- [ ] 5.3 Apply 5.1's and 5.2's doc edits to their own `template/` twins
      (`template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`
      and `template/docs/architecture/security.md.jinja`); verify with
      `task test:dogfood-structure` and `task lint:markdown`
- [ ] 5.4 Apply every change in groups 1-4 to the `template/` twin in the
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`;
      `template/agent-registry.json` stays read-only). The new
      `use_copilot_cli` question is added to root `copier.yml` **only** —
      `copier.yml` has no `template/` twin at all (it is the file that
      configures Copier itself; `template/` is what Copier *emits* into a
      generated repo, per AGENTS.md's two-layer architecture), so there is
      no second copy of this question to add; verify with
      `task test:dogfood-parity` and `task test:dogfood-structure`, and
      confirm no `template/copier.yml` file was created
- [ ] 5.5 Confirm the existing `devcontainer-assert-bot` CI job (wired by
      `bot-autonomy-bootstrap`'s task 3.3b) needs no new step — it already
      runs `bot-autonomy.sh verify` inside the built bot container, which
      now covers three more harnesses by construction; verify by running
      that job (or its local equivalent, `task test:devcontainer:root`)
      against a build that includes `copilot`/`pi`/`omp` and confirming it
      fails against a deliberately misconfigured one of the three new
      modules, the same way it already does for the original four

## 6. Verification

- [ ] 6.1 Run `task check`, `task verify`, and `task security` in this
      worktree; verify all green
- [ ] 6.2 Run `task test:devcontainer:permissions` and (where a Docker
      daemon, the `devcontainer` CLI, and a primary — non-worktree —
      checkout are all available) `task test:devcontainer:root`; this stays
      a manual step per `bot-autonomy-bootstrap`'s own documented `ci`
      carve-out (its task 3.5), not wired into `task ci`; verify both pass
- [ ] 6.3 Rebuild a freshly generated bot devcontainer with
      `use_copilot_cli: true` and manually exercise one representative task
      through Copilot CLI (or oh-my-pi's documented `unsupported` state if
      task 3.3 applied); verify zero approval prompts for Copilot,
      completing the Copilot clause of #1137's first `[CI]` acceptance
      criterion and contributing to its `[HUMAN]` criterion alongside the
      four harnesses `bot-autonomy-bootstrap` already covers — note that
      #1137's own acceptance criteria name Codex, Claude Code, Antigravity,
      Copilot CLI, and OpenCode explicitly; pi and oh-my-pi are this
      change's own broader scope (registry-completeness coverage), not
      named in the issue. Repeat against a rebuild at `use_copilot_cli`'s
      default (off) and confirm Copilot prompts as expected — the
      by-design, verified-correct outcome at the default, not a
      regression. Separately, exercise pi manually and confirm it behaves
      as the maintainer's decision (design.md - Decisions, "Resolved
      2026-09-03") states: zero approval prompts (pi's non-interactive
      modes never prompt for trust regardless of this setting), and this
      repository's own `.pi/` resources (if any exist) silently not
      loading — the decided, current state, not a bug to chase
