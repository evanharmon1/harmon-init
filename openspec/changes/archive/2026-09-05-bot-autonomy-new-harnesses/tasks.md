## 0. Preconditions

- [x] 0.1 Before this change's own implementation PR is finalized and
      merged, confirm `bot-autonomy-bootstrap`'s implementation (PR #1150)
      has actually merged to `main` first — `.devcontainer/scripts/bot-autonomy.sh`
      and `.devcontainer/config/bot-autonomy/{claude-code,codex-cli,antigravity,opencode}.sh`
      exist on `main`, and `.devcontainer/config/bot-autonomy/unsupported.json`
      (and its `template/` twin — a standalone file `bot-autonomy.sh`
      reads, not a table inside `agent-registry.json`) already carries
      `copilot-cli`, `pi`, and `oh-my-pi` entries reasoned "pending
      `bot-autonomy-new-harnesses`"; verify by reading that file directly
      rather than assuming its exact shape from this proposal's Context. This is a **merge-order**
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

- [x] 1.1 Add `use_copilot_cli` to `copier.yml` (default `no`,
      `when: "[[ devcontainer ]]"`, validator mirroring
      `use_antigravity_cli`'s `Enable DEVCONTAINER before …` pattern), with
      help text documenting Copilot's account requirement and free-tier/
      private-repo terms next to the question, adapting the caveat language
      `harness-matrix`'s proposal.md already drafted for this purpose. Add
      `--data use_copilot_cli=true` to `scripts/test-template.sh`'s `full`
      profile `data_args` (the same list `--data use_antigravity_cli=true`
      already lives in — maximizing conditional coverage is that profile's
      stated purpose); add committed assertions in that script's own
      Antigravity section's pattern (its `# ── 9e1.` block:
      `if [ "$profile" = "full" ]` gated checks against the exact rendered
      string) asserting the **bot** `devcontainer.json`'s `containerEnv`
      carries the exact literals `"HARMON_BOT_AUTONOMY_COPILOT": "enabled"`
      and `"COPILOT_ALLOW_ALL": "true"`, and — unlike Antigravity's marker,
      which both twins carry — asserting the **dev** `devcontainer.json`
      carries **neither key at all** (`! grep -Fq '"HARMON_BOT_AUTONOMY_COPILOT"'`
      and `! grep -Fq '"COPILOT_ALLOW_ALL"'`, the same negative-assertion
      shape that section's own `PATH`-key check already uses), matching
      the bot-only rendering this requirement's own spec text commits to;
      verify with `task check`, a rendered-template diff showing the new
      question appears in `copier copy --defaults` output, and
      `task test:template:full` passing with these new assertions in place
      (confirm they actually fail against a deliberately-reverted render
      before committing them, so the assertions are proven to test
      something)
- [x] 1.2 Add `use_copilot_cli: true` to `.dogfood-answers.yml` with a
      one-line comment matching `use_antigravity_cli`'s existing comment
      shape; verify with `task audit:dogfood` showing no new unexplained
      drift
- [x] 1.3 Add `containerEnv.HARMON_BOT_AUTONOMY_COPILOT` (rendered
      `"[[ 'enabled' if use_copilot_cli else 'disabled' ]]"` — this
      template's own Jinja delimiters per `copier.yml`'s `_envops` block
      (`[[ … ]]` expressions, `[% … %]` blocks, never `{{ }}`/`{% %}`,
      which would collide with a generated workflow file's own GitHub
      Actions `${{ }}` syntax), matching exactly how
      `HARMON_BOT_AUTONOMY_ANTIGRAVITY` already renders from
      `use_antigravity_cli` in both `devcontainer.json` twins) and
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
- [x] 1.4 Add `.devcontainer/config/bot-autonomy/copilot-cli.sh` (named
      after the `copilot-cli` registry slug, not the shortened `copilot` —
      `bot-autonomy.sh` dispatches `${CONFIG_DIR}/<slug>.sh`): `apply` reads
      `$HARMON_BOT_AUTONOMY_COPILOT`; WHEN `enabled`, confirms
      `$COPILOT_ALLOW_ALL` is the exact literal `true` in its own process
      environment (failing loudly if not — a render inconsistency) and
      installs `~/.local/bin/copilot`; WHEN not `enabled`, removes
      `~/.local/bin/copilot` if present and does not touch
      `$COPILOT_ALLOW_ALL` (it is not writable by this script either way —
      the render already guarantees it reads `false`); factor the wrapper's
      content into a shared `write_wrapper` helper both `apply` (install)
      and `verify` (byte-compare) call, mirroring `antigravity.sh`'s own
      `write_wrapper`/`cmp -s` pattern exactly, so the two can never
      independently drift; `verify` asserts, in the enabled state: the
      wrapper exists, is a regular file (not a symlink), is executable,
      its content matches `write_wrapper`'s output byte-for-byte (not
      merely "a file exists at that path" — a corrupted or hand-edited
      wrapper must fail), and its resolved delegate (the real `copilot`
      binary, or the documented system-binary fallback) is itself
      executable (matching Antigravity's own `[ -x "$AGY_REAL" ] ||
      [ -x "$AGY_SYSTEM_BINARY" ]` check — correct wrapper bytes with no
      runnable backend is a clean verify over an inert harness); in the
      disabled state, `verify` asserts absence. Separately, `verify`
      asserts `$COPILOT_ALLOW_ALL` is the exact literal `true` (enabled) or
      `false` (disabled) in both states — not merely present/absent, and
      not any other truthy-looking value. **Only when the marker reads
      `enabled`**,
      `verify` additionally checks that `~/.copilot/settings.json`'s
      `permissions.disableBypassPermissionsMode` is not `"disable"` — this
      check does NOT run in the disabled state, where a locked-out bypass
      mode is irrelevant (prompt-enabled is already the intended outcome
      there) and would otherwise fail a default-off consumer whose own org
      separately locks bypass mode via MDM, unconnected to this repo's
      Copier answer. Verify by running `bot-autonomy.sh apply` then
      `bot-autonomy.sh verify` (two separate invocations — the script
      dispatches on `$1` alone; there is no combined `apply verify` form)
      in a scratch fixture with the marker `enabled` and `disabled`, a fixture
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
      **passes** (the kill-switch is irrelevant here), a
      toggle-off-after-apply fixture confirming a prior
      autonomous state reaches disabled (wrapper absent,
      `COPILOT_ALLOW_ALL=false`) after a re-render flips the marker, a
      fixture that corrupts the installed wrapper's content (a single
      byte changed) after a correct `apply` and confirms `verify` fails
      naming Copilot rather than passing on presence/executability alone,
      and a fixture that makes the resolved delegate non-executable (or
      absent, with no working system-binary fallback either) and confirms
      `verify` fails naming Copilot even though the wrapper's own content
      and permissions are untouched
- [x] 1.5 Add the `~/.local/bin/copilot` wrapper script itself: injects
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
- [x] 1.6 Confirm the wrapper's `PATH` precedence needs no new prepend of
      its own — `bot-autonomy-bootstrap`'s existing
      `ENV PATH="/home/vscode/.local/bin:${PATH}"` directive in
      `.devcontainer/Dockerfile` (and its `template/` twin) already covers
      it; verify with `docker exec <container> copilot --version` (no
      login/interactive shell) resolving `~/.local/bin/copilot`, not the
      system binary

## 2. pi module

- [x] 2.1 First, confirm `~/.pi/agent/trust.json`'s actual read format
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
      set to `"always"` in `~/.pi/agent/settings.json`, or **any** trusted
      saved decision anywhere in `~/.pi/agent/trust.json`, using the
      confirmed read format — not only a decision applicable to the current
      workspace (its own canonical directory or, per pi's
      closest-decision-on-current-or-parent-path rule, a parent of it).
      Scoping the check to path-applicability-at-verify-time would leave a
      real gap: `~/.pi` is one persistent volume across the bot
      container's entire lifetime, and nothing about this capability
      guarantees pi is only ever invoked against the one workspace path
      that happened to be current when `verify` last ran (a
      Foreman-dispatched task, a worktree checkout, or a `gh pr checkout`
      could all point pi at a different path later in the same container).
      A trusted decision that is not applicable *now* is still live on
      disk and becomes applicable — silently granting extension-code
      execution — the instant pi is later invoked against a matching path,
      with no guarantee a fresh `verify` runs first; checking only
      applicable decisions therefore only proves "no elevated trust for
      today's workspace," not the "no elevated trust" guarantee the
      maintainer's decision actually states — regardless of whether this
      module, a stale volume, an interactive `/trust` run, or a manual
      edit produced either surface. There is no
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
      directory, separately when it pre-seeds one for a *parent* directory
      of the current workspace (proving the parent-path rule is actually
      checked, not only an exact-path match), and separately again when it
      pre-seeds one for an **unrelated, non-parent** workspace entirely
      (proving the check is not scoped to path-applicability at all — a
      trusted decision anywhere in the file fails `verify`, whether or not
      it applies to the workspace `verify` is currently running against);
      `verify` **passes** when a fixture pre-seeds pi's own **explicit
      distrust** decision (whatever pi's confirmed format uses for "not
      trusted") for the current workspace's own directory, a parent, or an
      unrelated workspace — the positive case proving `verify` distinguishes
      a *trusted* saved decision from any other saved decision, not merely
      "an entry exists at all" (a naive implementation that fails closed on
      *any* `trust.json` entry regardless of its trust value would
      otherwise satisfy every fail-closed fixture in this list while
      incorrectly failing this genuinely safe, explicitly-distrusted
      state); and a fixture confirming bot and dev profiles behave
      identically for this module (no per-profile branch exists to test)
- [x] 2.2 Confirm the dev profile's post-create never calls this module
      (mirroring `bot-autonomy-bootstrap`'s own "dev never calls
      `bot-autonomy.sh`" wiring — this module is only ever dispatched from
      the bot's own `apply`/`verify` calls, so no separate dev-exclusion
      logic is needed inside the module itself, even though its current
      behavior happens to be identical either way); verify by grepping
      `.devcontainer/dev/post-create.sh` for any reference to this module
      or `bot-autonomy.sh` and confirming none exists
- [x] 2.3 **The real, capability-gap-proving fixture cannot run from this
      change's own implementation PR** — same reason as tasks 5.5/6.3: a
      non-interactive `pi -p` invocation needs the actual `pi` binary,
      which is not present in `.devcontainer/Dockerfile`'s pinned image
      until the sync-pin PR (#1152) lands, and
      `scripts/devcontainer-assert.sh` enforces the `FROM` line matches
      that pin exactly (no scratch/alternate-pin mechanism exists to build
      against a newer digest instead). Move the real assertion to
      `write_body()`'s "Reviewer checklist" (task 6.3): add a pi
      capability-gap item there, in the shape of "confirm pi's accepted
      capability gap: `pi -p` against a fixture repository carrying
      `.pi/settings.json` (or another trust-requiring resource) silently
      ignores that resource — no error, no prompt — the maintainer-decided
      outcome of pi's 'no elevated trust' requirement (spec.md's pi
      requirement), proven against the real binary now that it exists in
      the built image." This change's own implementation PR instead adds
      only what a fake, stub `pi` executable on `PATH` can prove: that
      this module's own `apply` (writing nothing, per task 2.1) and the
      `bot-autonomy.sh apply pi` / `verify pi` dispatch introduce no flag,
      config write, or other side effect of their own that could interfere
      with or mask pi's native non-interactive handling — confirming this
      module stays a true no-op, not that pi itself behaves as documented
      (that claim is design.md's own citation of pi's docs, and the
      real-binary fixture above is what confirms it empirically, deferred
      to #1152 for the same reason task 2.1's own first paragraph already
      defers its trust.json format confirmation to a scratch container).
      This is not a task to "make pass" by adding logic; the
      stub-executable fixture exists to catch a regression in this
      module's own no-op contract, and the deferred real-binary fixture
      exists to keep the accepted capability gap visible and tested once
      it can be, rather than something a later change could silently
      regress further (e.g. a future edit that makes pi error instead of
      silently ignore, which would be a *different*, newly-introduced
      problem the deferred fixture would catch)

## 3. oh-my-pi module

- [x] 3.1 Confirm this proposal's researched mechanism
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

      **Result: CONFIRMED AS RESEARCHED.** Run against the real image
      `ghcr.io/evanharmon1/harmon-devcontainer@sha256:c46fe85ffcb193e90206739e33399265e4eb2dea8217c86dad405c92c94efb1e`
      (the digest the open sync-pin PR #1152 bumps to), `omp --version`
      reports `omp/18.1.2`; `omp config path` reports
      `/home/vscode/.omp/agent`; `omp config get tools.approvalMode --json`
      returns `{"key","value","type":"enum","description"}` with `value` =
      `yolo` on a fresh volume (the documented schema default), tracks
      `omp config set tools.approvalMode <v>` writes to
      `~/.omp/agent/config.yml`, and resolves a project-level
      `<cwd>/.omp/config.yml` OVER the global file. Task 3.2 therefore
      applies; task 3.3's contingency does not.
- [x] 3.2 **IF task 3.1 confirms the mechanism** (as researched, or with
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
- [x] 3.3 **IF task 3.1 contradicts the mechanism**: do not add a module.
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

      **Not applicable — no action taken.** Task 3.1's confirmation above
      upheld the researched mechanism against the real `omp v18.1.2`
      binary, so the primary path (task 3.2) shipped a real module. This
      contingency's `unsupported` entry, its fake-`omp` fixture, and its
      follow-up issue are all deliberately absent, and task 6.3's
      sync-pin checklist carries the zero-prompts wording rather than the
      BLOCKING wording. Ticked to record that the branch was evaluated and
      correctly not taken.
- [x] 3.4 Whichever of 3.2/3.3 applies, confirm no path through this
      module's logic can leave `omp` both installed and silently uncovered
      — verify by running the registry-completeness unit test with a real
      `omp` binary present (a scratch container or a `PATH`-injected fake)
      and confirming a pass under 3.2's real module or a fail-naming-oh-my-pi
      under 3.3's `unsupported` entry, never a silent pass with no coverage

## 4. Registry coverage reconciliation

- [x] 4.1 Remove the `copilot-cli`, `pi`, and (only if task 3.2 applies)
      `oh-my-pi` placeholder entries from the `unsupported` table
      `bot-autonomy-bootstrap`'s implementation added, in the same PR that
      adds the corresponding real modules — never leaving a slug covered by
      both a module and a stale `unsupported` entry, even transiently
      within the PR's own commit history; verify with the registry-
      completeness unit test (`bot-autonomy-bootstrap`'s task 1.3) failing
      on a deliberately-reintroduced stale entry and passing on the real
      state
- [x] 4.2 Verify every one of the registry's harness slugs still resolves
      to exactly one of the three coverage buckets after this change
      (`copilot-cli` → module, `pi` → module, `oh-my-pi` → module or
      updated `unsupported` per task 3's outcome, every other slug
      unchanged from `bot-autonomy-bootstrap`'s own implementation); verify
      with the full registry-completeness unit test run, not a partial diff

## 5. Docs, template parity, and CI coverage

- [x] 5.1 Extend `docs/guides/devcontainers.md`'s bot-autonomy boundary
      section (whatever structure `bot-autonomy-bootstrap`'s own task 4.1
      dedup leaves in place — do not assume specific line numbers) with
      Copilot CLI's, pi's, and oh-my-pi's boundaries, matching the level of
      detail already given to Claude Code/Codex/Antigravity/OpenCode;
      verify with `task lint:markdown`
- [x] 5.2 Extend `docs/architecture/security.md`'s bot-autonomy boundary
      contract section (added by `bot-autonomy-bootstrap`'s task 4.3) with
      the same three boundaries; verify with `task lint:markdown`
- [x] 5.3 Apply 5.1's and 5.2's doc edits to their own `template/` twins
      (`template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`
      and `template/docs/architecture/security.md.jinja`); verify with
      `task test:dogfood-structure` and `task lint:markdown` — plus
      `task audit:dogfood` (AGENTS.md's own recommended check "whenever a
      change spans both layers"), reading its actual diff output rather
      than only its exit status: `test:dogfood-structure` proves only that
      every rendered heading/task exists in the root copy, not that the
      *prose* added to each stayed in step, and a jinja twin's own report
      is the one surface built to catch that
- [x] 5.4 Apply every change in groups 1-4 to the `template/` twin in the
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`;
      `template/agent-registry.json` stays read-only). The new
      `use_copilot_cli` question is added to root `copier.yml` **only** —
      `copier.yml` has no `template/` twin at all (it is the file that
      configures Copier itself; `template/` is what Copier *emits* into a
      generated repo, per AGENTS.md's two-layer architecture), so there is
      no second copy of this question to add; verify with
      `task test:dogfood-parity` and `task test:dogfood-structure`, and
      confirm no `template/copier.yml` file was created
- [x] 5.5 Confirm the existing `devcontainer-assert-bot` CI job (wired by
      `bot-autonomy-bootstrap`'s task 3.3b) needs no new step of its own —
      it already runs `bot-autonomy.sh verify` inside the built bot
      container, which covers three more harnesses by construction once
      the binaries are present. **This job cannot actually exercise
      `copilot`/`pi`/`omp` from this change's own implementation PR**: it
      builds `.devcontainer/Dockerfile` exactly as pinned
      (`scripts/devcontainer-assert.sh` enforces the `FROM` line matches
      the checked-in immutable reference — there is no scratch-image or
      alternate-pin mechanism in this repo's tooling to build against a
      newer, unpinned digest instead), and that pin is still the
      pre-`harness-matrix` image until the sync-pin PR (#1152) lands. This
      change's own verification is therefore unit fixtures only (tasks
      1.4, 2.1, 3.2/3.3); the container assertion actually covering the
      three new modules runs for the first time once #1152's pin bump
      lands — see task 5.6 and 6.3 below
- [x] 5.6 Add the smoke-isolation volume suffix
      (`${localEnv:HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX}`) to the
      `omp-config`, `copilot-config`, and `pi-config` mounts in both
      `devcontainer.json` twins (root bot + dev) and both `template/`
      twins — confirmed missing by inspection: `gemini-config` and
      `opencode-config` already carry it (`bot-autonomy-bootstrap`'s own
      task 3.3c requirement).

      **Correcting this task's own earlier reasoning (it previously
      exempted `copilot-config`/`pi-config`):** the isolation requirement
      is not only about `apply`'s backup-gated-on-no-backup-existing-yet
      writes (the reasoning `scripts/devcontainer-smoke.sh`'s own comment
      states, and the one this task originally applied) — it is about
      **any state `verify` reads that a fixture might have seeded**,
      whether or not that module has a backup/restore mechanism of its
      own. Confirmed by re-reading this change's own fixture list: task
      1.4's Copilot fixtures write `disableBypassPermissionsMode: "disable"`
      into `~/.copilot/settings.json` to exercise the kill-switch-fails
      case, and task 2.1's pi fixtures write a trusted decision into
      `~/.pi/agent/trust.json` and `defaultProjectTrust: "always"` into
      `~/.pi/agent/settings.json` to exercise the fail-closed cases — none
      of that is "backup" state (neither module has a backup/restore
      mechanism), but all of it is state `verify` reads, persisted in the
      same named volume a real container (or a later CI run reusing an
      unisolated volume) would also read. Without isolation, a fixture
      that seeds a bad value to prove `verify` fails would leave that
      value behind for the *next* run to read as if it were real,
      corrupting an otherwise-clean run's result — the identical failure
      shape task 3.3c closed for gemini/opencode's backup state, just
      triggered by a *verify-only* read instead of an *apply* write. Both
      mounts need the same fix oh-my-pi's does, for this broader reason,
      not the narrower one first considered; verify with
      `task test:dogfood-parity` (root vs. template) and by re-running the
      CI container-assertion job (once #1152 lands and it can exercise all
      three) twice in a row with an interleaved fail-closed fixture in
      between, confirming the second run is not contaminated by state the
      first run's fixture seeded

## 6. Verification

- [x] 6.1 Run `task check`, `task verify`, and `task security` in this
      worktree; verify all green
- [x] 6.2 Run `task test:devcontainer:permissions` and (where a Docker
      daemon, the `devcontainer` CLI, and a primary — non-worktree —
      checkout are all available) `task test:devcontainer:root`; this stays
      a manual step per `bot-autonomy-bootstrap`'s own documented `ci`
      carve-out (its task 3.5), not wired into `task ci`; verify both pass
- [x] 6.3 **This change's own implementation PR cannot rebuild a "freshly
      generated bot devcontainer" that actually has `copilot`/`pi`/`omp`
      installed** — same reason as task 5.5: the pin those binaries need is
      `.devcontainer/Dockerfile`'s, and it is not bumped until the
      sync-pin PR (#1152) merges, which this change's own implementation
      merges *before* (design.md - Migration Plan). The end-to-end,
      zero-prompts exercise — and, for pi, the capability-gap confirmation
      task 2.3 defers here too — therefore cannot be this change's own
      acceptance step; it belongs on the sync-pin PR's, since that PR is
      what first makes a bot container with these three binaries buildable
      at all.

      **The checklist items belong in `scripts/sync-devcontainer-image.sh`'s
      `write_body()`, not hand-added to #1152's current body text.** That
      function is what generates every rolling sync-pin PR's body — it
      already carries the "bot-autonomy-new-harnesses has merged" item
      `bot-autonomy-bootstrap`'s own task 4.6 added there (confirmed by
      reading the function directly, not the live PR alone) — and "a newer
      publication rewrites this one rolling branch and PR" (the function's
      own closing line) means any edit made only to #1152's *current* body
      is silently discarded the next time the automation regenerates it.
      Add two more checklist items to `write_body()`'s heredoc, in the
      "Reviewer checklist" section, alongside the existing one.

      **The first is the zero-prompts (or blocking) item, whose exact
      wording depends on which of this change's own task 3.2/3.3 applied —
      add exactly one of the two, never both.** If task 3.2 applied
      (oh-my-pi shipped a real module), word it in the shape of: "rebuild a
      freshly generated bot devcontainer with `use_copilot_cli: true` and
      exercise one representative **tool-using** task (a file read/write
      or a shell command — not a question with no tool call, which would
      never consult the approval-mode setting at all) through each of
      Copilot CLI, pi, and oh-my-pi; confirm **zero approval prompts for
      all three** — Copilot, pi, *and* oh-my-pi, completing the Copilot
      clause of #1137's first `[CI]` acceptance criterion and contributing
      to its `[HUMAN]` criterion; repeat at `use_copilot_cli`'s default
      (off) and confirm Copilot prompts as expected — the by-design
      outcome, not a regression." If task 3.3's contingency applied
      instead (oh-my-pi remains an `unsupported` registry entry), this
      item is a **blocking** condition, not a confirmation step — there is
      no module to confirm zero prompts against — worded in the shape of:
      "**BLOCKING — do not approve this PR**: `bot-autonomy-new-harnesses`'s
      own oh-my-pi spike (its task 3.1) found the documented
      `tools.approvalMode: yolo` mechanism does not hold against the real
      `omp` binary, so oh-my-pi is an `unsupported` registry entry, not a
      module. This image still installs `omp` unconditionally
      (`harness-matrix`'s own decision, unchanged). Merging this PR as-is
      means `bot-autonomy.sh verify` fails closed, naming oh-my-pi, on
      **every** bot container that picks up this pin, indefinitely. Do not
      merge until one of: (a) a `harness-matrix` follow-up Copier-gates or
      removes `omp`'s unconditional install, or (b) a real oh-my-pi module
      ships in a follow-up change (a fresh attempt at this change's own
      task 3.2). Rebuild and exercise Copilot and pi's own checklist items
      regardless; oh-my-pi has no zero-prompt exercise to run under this
      contingency." This mirrors design.md's own Risk/Mitigation and
      Migration Plan for exactly this scenario, which state the same
      blocking condition as this change's own required outcome, not
      merely a disclosed possibility.

      **The second is pi's own capability-gap item, unconditional** —
      task 2.3's own deferred assertion, worded in the shape of: "confirm
      pi's accepted capability gap: `pi -p` against a fixture repository
      carrying `.pi/settings.json` (or another trust-requiring resource)
      silently ignores that resource — no error, no prompt — the
      maintainer-decided outcome of pi's 'no elevated trust' requirement
      (`bot-autonomy-new-harnesses`'s spec.md pi requirement), now provable
      against the real binary."

      Extend `scripts/test-devcontainer-image-automation.sh`
      (the script's own automation test — currently asserts the rolling
      PR gets created/updated and verification ran, but has no assertion
      on the generated body's actual *text*) with a case that captures
      `write_body()`'s output and asserts every checklist item's literal
      text is present — the pre-existing task 4.6 item, whichever one of
      the two zero-prompts-or-blocking items actually applies, and the pi
      capability-gap item — so a future edit to `write_body()` cannot
      silently drop any of them. Note for whoever implements this: #1137's
      own acceptance criteria name Codex, Claude Code, Antigravity,
      Copilot CLI, and OpenCode explicitly — pi and oh-my-pi are this
      change's own broader registry-completeness scope, not named in the
      issue, so confirming their behavior on the sync-pin PR (or blocking
      it under oh-my-pi's contingency) is this change's own verification
      interest, not something #1137 itself is waiting on. This change's
      own task 6 therefore stops at 6.1/6.2 (unit-level `task verify`/
      `task security` and the permissions/root smoke tests) and task 2.3's
      own stub-executable fixture — there is nothing further this
      implementation PR can itself verify end-to-end before #1152 lands;
      verify with `task test:devcontainer:image:automation` green,
      confirming it fails when any checklist item's text is removed from
      `write_body()`, and confirming the next real regeneration of #1152
      (or its successor) carries every one of them
