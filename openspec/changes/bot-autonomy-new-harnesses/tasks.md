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
      `containerEnv.COPILOT_ALLOW_ALL` (rendered to `"true"` only when the
      answer is on, omitted otherwise) to the **bot** `devcontainer.json`
      jinja twin only — **not** `dev/devcontainer.json`, unlike the existing
      `HARMON_BOT_AUTONOMY_ANTIGRAVITY` marker `bot-autonomy-bootstrap`
      added to both: nothing in the dev profile reads either new entry, and
      rendering `COPILOT_ALLOW_ALL` into dev too would hand a human's own
      interactive Copilot CLI session in the dev profile full allow-all
      permissions (design.md - Decisions); set the matching literal values
      in this repository's own root `.devcontainer/devcontainer.json` only
      (`enabled`/`"true"`, matching `.dogfood-answers.yml`) and confirm
      `.devcontainer/dev/devcontainer.json` carries neither; verify by
      rendering a copy with `use_copilot_cli: true` and one at the default,
      confirming the rendered **bot** `devcontainer.json`'s `containerEnv`
      carries the expected literals in both cases and the rendered **dev**
      `devcontainer.json` carries neither key in either case
- [ ] 1.4 Add `.devcontainer/config/bot-autonomy/copilot.sh`: `apply` reads
      `$HARMON_BOT_AUTONOMY_COPILOT`; WHEN `enabled`, confirms
      `$COPILOT_ALLOW_ALL` is present in its own process environment
      (failing loudly if not — a render inconsistency) and installs
      `~/.local/bin/copilot`; WHEN not `enabled`, removes
      `~/.local/bin/copilot` if present and does not touch
      `$COPILOT_ALLOW_ALL` (it is not writable by this script either way);
      `verify` asserts the wrapper's presence/absence matches the marker,
      that `$COPILOT_ALLOW_ALL` matches, and that
      `~/.copilot/settings.json`'s `permissions.disableBypassPermissionsMode`
      is not `"disable"`; verify by running `bot-autonomy.sh apply verify`
      in a scratch fixture with the marker `enabled` and `disabled`, plus a
      toggle-off-after-apply fixture confirming a prior autonomous state
      reaches disabled (wrapper absent) after a re-render flips the marker
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

- [ ] 2.1 Add `.devcontainer/config/bot-autonomy/pi.sh`: unconditional (no
      Copier-answer branch); `apply` sets `defaultProjectTrust: "always"` in
      `~/.pi/agent/settings.json` in the bot profile, capturing the prior
      value (or its absence) before the first overwrite, gated on no backup
      existing yet, matching `apply-antigravity-settings.sh`'s
      `[ ! -f "$backup_path" ]` guard; `verify` reads the value back; `restore`
      puts the captured value back and clears the backup; verify with
      fixtures covering fresh-file creation, overriding an existing
      `"ask"`/`"never"` value, preserving unrelated keys, and an
      `apply → apply → restore` sequence confirming restore returns the
      value from *before the first* apply
- [ ] 2.2 Confirm the dev profile's post-create never calls this module
      (mirroring `bot-autonomy-bootstrap`'s own "dev never calls
      `bot-autonomy.sh`" wiring — this module is only ever dispatched from
      the bot's own `apply`/`verify` calls, so no separate dev-exclusion
      logic is needed inside the module itself); verify by grepping
      `.devcontainer/dev/post-create.sh` for any reference to this module
      or `bot-autonomy.sh` and confirming none exists
- [ ] 2.3 Add a fixture proving the effective-behavior claim in design.md's
      pi Decision: a non-interactive `pi -p` run against a fixture
      repository carrying `.pi/settings.json` (or another trust-requiring
      resource) loads that resource when `defaultProjectTrust: "always"`,
      and silently ignores it (no error, no prompt) when left at pi's own
      `"ask"` default — verify this fixture actually distinguishes the two
      cases (a fixture that cannot tell them apart would not be exercising
      the requirement this module exists to satisfy)

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
      overwrite, gated on no backup existing yet, matching pi's and
      OpenCode's shape; `verify` reads the **fully resolved** value via
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
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`,
      `template/copier.yml` question, `template/agent-registry.json` stays
      read-only); verify with `task test:dogfood-parity` and
      `task test:dogfood-structure`
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
      through each of Copilot CLI, pi, and oh-my-pi (or confirm oh-my-pi's
      documented `unsupported` state if task 3.3 applied); verify zero
      approval prompts for Copilot and pi, completing the Copilot clause of
      #1137's first `[CI]` acceptance criterion and contributing to its
      `[HUMAN]` criterion alongside the four harnesses
      `bot-autonomy-bootstrap` already covers. Repeat against a rebuild at
      `use_copilot_cli`'s default (off) and confirm Copilot prompts as
      expected — the by-design, verified-correct outcome at the default,
      not a regression
