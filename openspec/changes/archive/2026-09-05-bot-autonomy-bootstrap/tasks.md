## 1. Bootstrap entrypoint and registry completeness

- [x] 1.1 Add `.devcontainer/scripts/bot-autonomy.sh apply|verify`, enumerating
      `agent-registry.json` `harnesses[]` slugs and dispatching to
      `.devcontainer/config/bot-autonomy/<slug>.sh` modules (resolving an
      aliased slug to its target module); verify it exits non-zero on any
      module failure
- [x] 1.2 Define the three coverage buckets inside `bot-autonomy.sh`: the
      alias table (`claude-code-deepseek`, `claude-code-glm`,
      `claude-code-kimi`, `claude-code-minimax`, `claude-code-qwen`,
      `claude-code-qwen-local` → `claude-code`) and the `unsupported` set
      as `slug → {reason, executable}` — `reason` is documentation only,
      `executable` is the binary name `verify` checks for on `PATH`, or
      `null` when the slug has no standalone binary at all. Entries:
      `claude-code-action` (`executable: null` — a GitHub Action, no CLI to
      detect); `qwen-code` (`executable: "qwen"`), `goose`
      (`executable: "goose"`), `cline` (`executable: "clite"`, its
      published `@cline/cli` package's bin name) — none installed in the
      shared image; `copilot-cli` (`executable: "copilot"`), `pi`
      (`executable: "pi"`) — registered, not yet installed;
      `harness-matrix` installs them, `bot-autonomy-new-harnesses` adds
      their modules; verify the registry schema
      (`agent-registry.schema.json`) is unchanged (`git diff` shows no
      schema edit)
- [x] 1.3 Add a unit test asserting every one of the registry's 16 harness
      slugs falls into exactly one of the three buckets, that every
      `unsupported` entry's `executable` is a non-empty string or `null`,
      and that an installed executable with none of the three fails
      `verify`; verify with `task test:bot-autonomy` (or the chosen test
      task name) passing and failing on injected fixtures (an uncovered
      slug, a doubly-covered slug, a missing/malformed `executable` field)
- [x] 1.4 Make `verify` fail ANY `unsupported` slug the instant its
      executable is installed but it still has no real module or alias —
      uniformly, regardless of the entry's reason (no reason category
      grants an exemption that survives installation); verify with
      fixtures that install a fake `copilot` executable against its
      `unsupported` entry AND fake executables named after each entry's
      **`executable` field, not its slug** — `qwen` (for the `qwen-code`
      slug), `goose`, and `clite` (for the `cline` slug; its package's
      actual bin name, not the slug itself) — against theirs, confirming
      `verify` fails naming each. `verify` checks `command -v <executable>`,
      so a fixture that installs a binary literally named `qwen-code` or
      `cline` would never be found and the fixture would silently fail to
      exercise this behavior at all

## 2. Per-harness modules

- [x] 2.1 Add `bot-autonomy/claude-code.sh`: apply sets
      `permissions.defaultMode=bypassPermissions` in
      `/etc/claude-code/managed-settings.json`; verify reads it back; verify
      by running `bot-autonomy.sh apply verify` in a scratch container/fixture
      and confirming the managed file, including when launched via one of
      the six aliased `claude-code-*` provider wrappers
- [x] 2.2 Add `.devcontainer/config/codex-managed-config.bot.toml` (complete
      bot baseline, `sandbox_mode = "danger-full-access"`,
      `approval_policy = "never"`, otherwise identical to
      `codex-managed-config.toml`) and `bot-autonomy/codex-cli.sh`: apply
      installs it over `/etc/codex/managed_config.toml`; verify checksums the
      installed file against the shipped one; verify by corrupting the
      installed file in a fixture and confirming `verify` fails
- [x] 2.3 Add a structural parity test between `codex-managed-config.toml`
      and `codex-managed-config.bot.toml` asserting every key matches except
      `sandbox_mode`/`approval_policy`; verify it fails when a fixture edits
      `model` in only one of the two files, and passes on the real pair
- [x] 2.4 Add `bot-autonomy/antigravity.sh`, gated by
      `$HARMON_BOT_AUTONOMY_ANTIGRAVITY` (the rendered `containerEnv`
      marker task 2.7 adds, sourced from the `use_antigravity_cli` Copier
      answer — the module never reads the Copier answer any other way):
      WHEN the marker reads `enabled`, apply sets
      `toolPermission: always-proceed` (reusing
      `apply-antigravity-settings.sh` apply semantics) and confirms task
      2.5b's `ensure-antigravity-cli.sh` run (which precedes this module,
      per task 3.1's ordering) already left the wrapper's precursor state
      in place for this module to overwrite; WHEN the marker is anything
      other than `enabled`, apply calls `apply-antigravity-settings.sh
      restore` and does **not** touch `~/.local/bin/agy` at all — task
      2.5b's script, which runs first, has already left it absent, and
      re-touching it here would be redundant, not corrective; verify
      checks whichever state the marker selects; verify with the existing
      `apply-antigravity-settings.sh` fixture pattern in
      `scripts/devcontainer-assert.sh`, run once with the marker
      `enabled` and once `disabled`, plus a toggle-off-after-apply
      fixture confirming a prior autonomous state reaches
      disabled-by-option (settings restored, `agy` absent — not a
      symlink) after a re-render flips the marker and both scripts rerun
- [x] 2.5 Install `~/.local/bin/agy` as an executable wrapper from the bot
      post-create only, and only WHEN `$HARMON_BOT_AUTONOMY_ANTIGRAVITY`
      reads `enabled`, AFTER task 2.5b's `ensure-antigravity-cli.sh` run
      in the same post-create (retiring the `agy()` shell function in
      `agy-autonomy.sh` unconditionally either way), injecting
      `--dangerously-skip-permissions` unless already present, porting
      `agy-autonomy.sh`'s exact passthrough list unmodified (bare `agy`,
      `agent`/`agents`/`changelog`/`help`/`-h`/`--help`/`install`/
      `models`/`plugin`/`plugins`/`update`/`--version`). The wrapper
      SHALL resolve and exec `~/.local/bin/agy-real` (task 2.5b's
      compatibility-copy target) when it exists and is executable,
      falling back to the system binary at `/usr/local/bin/agy` (or
      `$HARMON_ANTIGRAVITY_SYSTEM_BINARY`) only when `agy-real` is absent
      — never the reverse — matching `ensure-antigravity-cli.sh`'s own
      freshest-binary-wins precedence rather than inventing a new one.
      When the marker is not `enabled`, this task installs nothing: task
      2.5b's script has already left `agy` absent (never a symlink to a
      target that was never downloaded), and the wrapper module does not
      re-touch it; verify with a fixture invoking the wrapper directly
      (not via a sourced shell) asserting the flag lands on a
      non-passthrough invocation and is absent on every passthrough case,
      confirm the wrapper resolves `agy-real` over a deliberately stale
      system binary when both are present, and confirm `agy` is absent
      (not a symlink, not the wrapper) when the marker is not `enabled`
- [x] 2.5b Retarget `.devcontainer/config/ensure-antigravity-cli.sh` (and
      its `template/` twin) from `~/.local/bin/agy` to
      `~/.local/bin/agy-real` for every internal reference — the version
      check, the reconciliation `install`, and the download `install` —
      so this script's own idempotency and version-freshness logic
      operates on the file it actually owns, independent of whatever the
      bot-autonomy `antigravity` module later does to `agy`. Gate the
      whole download/reconcile path on
      `$HARMON_BOT_AUTONOMY_ANTIGRAVITY` (task 2.7's rendered marker): WHEN
      it reads `enabled`, in **either** profile, download/reconcile
      `agy-real` as today (retargeted) and, on every invocation including
      the early-return paths, (re)point a plain symlink
      `~/.local/bin/agy → agy-real` — so dev, which has no bot-autonomy
      wrapper, still resolves plain `agy` to the freshest pinned binary,
      exactly as today's single-path behavior does, and bot has a working
      symlink for task 2.5's `apply` to overwrite; WHEN the marker is
      anything other than `enabled` (including absent, on an image built
      before this marker existed), skip the download entirely and instead
      remove `agy-real` and `agy` if either exists — from a prior run
      before a Copier-answer toggle, or a stale image — so a default-off
      render reaches plain absence, never a symlink with nothing to point
      at. In the bot profile, this script's call moves to **before** the
      call to `.devcontainer/scripts/post-create-common.sh` (task 3.1),
      still ahead of the bot-autonomy `antigravity` module's `apply`; the
      dev profile's call keeps its existing position (after
      `post-create-common.sh`) since dev has no ordering dependency on a
      conductor-spawned `claude`'s policy; verify by confirming `agy-real`
      gets the unchanged version-check/download/reconcile behavior (same
      version and architecture cases as today) when the marker is
      `enabled`, that `agy` is a working symlink to `agy-real`
      immediately after this script runs on a profile with no wrapper
      (e.g. dev) with the marker `enabled`, and that both `agy-real` and
      `agy` are absent — including when either existed from a prior
      `enabled` run — when the marker is not `enabled`
- [x] 2.5a Prepend `/home/vscode/.local/bin` ahead of `/usr/local/bin` onto
      `PATH`, container-wide, so the wrapper's precedence does not depend
      on a shell rc `PATH` export — **implemented via the bot `Dockerfile`'s
      own `ENV PATH=` directive (and its `template/` twin), not
      `devcontainer.json`'s `containerEnv`**: a `containerEnv.PATH` entry
      that self-references `${containerEnv:PATH}` does not resolve at
      container-creation time (the devcontainers CLI passes it to
      `docker run -e` literally, unresolved, breaking the container's own
      shell — confirmed empirically during implementation), while a
      Dockerfile `ENV` directive is Docker's own working self-reference,
      resolved at image build time; verify with
      `docker exec <container> agy --version` (no login/interactive
      shell) and with `env -i PATH="$(docker exec <container> printenv
      PATH)" agy --version` inside the container, confirming both resolve
      `~/.local/bin/agy`, not the system binary — this is the case a shell
      function or an rc-only `PATH` edit cannot cover
- [x] 2.7 Add `containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` — rendered
      from `{{ use_antigravity_cli }}` to the literal string `enabled` or
      `disabled` — to the bot `devcontainer.json` **and**
      `dev/devcontainer.json` jinja twins (both already
      `[% if devcontainer %]`-conditional), plus their `template/` twins;
      set the matching literal value in this repository's own root
      `.devcontainer/devcontainer.json` and `.devcontainer/dev/
      devcontainer.json` (the rendered form, not a jinja twin) to match
      `.dogfood-answers.yml` (`enabled`, since `use_antigravity_cli` is on
      here). This is the *only* channel through which
      `ensure-antigravity-cli.sh` and the `antigravity` module — both
      **verbatim** twins that cannot contain `{{ use_antigravity_cli }}`
      logic themselves — learn the per-repo Copier answer; neither SHALL
      derive it any other way. Document the naming convention
      `HARMON_BOT_AUTONOMY_<HARNESS>` as what any future Copier-gated
      harness module follows (the `bot-autonomy-new-harnesses` follow-on
      adds `HARMON_BOT_AUTONOMY_COPILOT` once it defines that harness's
      own Copier answer — not added here, since neither this change nor
      `harness-matrix` builds the Copilot module); verify by rendering a
      copy with `use_antigravity_cli: true` and one with it at the
      default, confirming each rendered `devcontainer.json`'s
      `containerEnv` carries the expected literal, and confirming both
      `ensure-antigravity-cli.sh` (post-create) and `bot-autonomy.sh
      verify` (post-create and post-start — both lifecycle points) read
      the same value consistently within one container's lifetime
- [x] 2.6 Add `bot-autonomy/opencode.sh`: apply force-overwrites
      `"permission": {"*": "allow"}` in `~/.config/opencode/opencode.json`
      (create-if-absent, preserve every other existing key, override any
      prior `permission` value), recording the prior `permission` value (or
      its absence) in a form `restore` can read — gated on **no backup file
      existing yet**, matching `apply-antigravity-settings.sh`'s
      `[ ! -f "$backup_path" ]` guard, so a second or later `apply` never
      overwrites the first backup with the already-managed `"allow"` value;
      verify reads OpenCode's **fully resolved** configuration (global
      layered with any workspace-level `opencode.json`/
      `.opencode/opencode.json` the current repository provides) rather
      than the global file alone, and names the workspace file when that
      is the cause of a failure; verify with fixtures covering fresh-file
      creation, overriding an existing `ask`/`deny` value, preserving
      unrelated keys, an `apply → apply → restore` sequence confirming the
      restore returns the value from *before the first* apply (not the
      second), a workspace-level `opencode.json` that overrides the
      global allow-all back to `ask`/`deny`, and an **absent → apply →
      restore** sequence: `opencode.json` has no `permission` key at all
      (or does not exist) before the first `apply`, so `restore` SHALL
      remove the `permission` key entirely afterward (not set it to some
      default) — matching how `apply-antigravity-settings.sh`'s restore
      only re-adds keys that were actually present in `.present` — AND
      confirm `restore` deletes the backup file itself
      (`apply-antigravity-settings.sh`'s own `rm -f "$backup_path"` at the
      end of its restore case), so the next `apply`→`restore` cycle starts
      fresh rather than reading a stale backup left over from this one

## 3. Fail-closed wiring

- [x] 3.1 Extract `post-create-common.sh`'s "Agent-Deck conductor setup"
      block (the comment-delimited section from Telegram-token injection
      through the `agent-deck conductor setup` call, ~lines 285-341) into
      its own script — e.g. `.devcontainer/scripts/post-create-conductor.sh`
      (a verbatim twin, matching the script it came from), or equivalently
      a flag `post-create-common.sh` checks to skip that section, with
      each profile invoking the extracted logic separately — leaving
      everything else in `post-create-common.sh` (ownership fixing, Coder
      persistence symlinks, `link-claude-json.sh`, the Claude onboarding
      seed, Herdr integrations, Agent-Deck config seeding, Claude Code
      user-settings seeding, general project bootstrapping) unchanged and
      in its existing position. Then wire bot `post-create.sh`'s order to:
      **(i)** `post-create-common.sh` (now without the conductor block);
      **(ii)** `ensure-antigravity-cli.sh`; **(iii)** `bot-autonomy.sh
      apply`; **(iv)** the extracted conductor step — call `apply` only
      after (i)/(ii) have run, and the conductor step only after `apply`
      succeeds. Wire dev `post-create.sh`'s order to: `post-create-common.sh`
      (without conductor), `ensure-antigravity-cli.sh`,
      `apply-antigravity-settings.sh apply` (the dev-balanced policy), then
      the conductor step last — dev has no ordering *requirement* between
      these (a conductor-spawned `claude` under dev's default,
      prompt-enabled policy was never wrong), so this is a structural
      simplification matching bot's shape, not a correctness fix for dev.
      Confirm `.devcontainer/dev/post-create.sh` does not call
      `bot-autonomy.sh apply` at all; verify via
      `scripts/devcontainer-assert.sh` unit-mode grep-style assertions
      (matching the existing Antigravity/Codex pattern) confirming: the
      conductor block is absent from `post-create-common.sh`; bot's
      `apply` call is present and dev's is absent; and each profile's
      step order matches the sequence above — including that `apply` runs
      after `post-create-common.sh`'s ownership/Coder-persistence prefix,
      not before it
- [x] 3.2 Call `bot-autonomy.sh verify` at the end of bot post-create, and
      again in bot `post-start.sh` — **before** its existing call to the
      shared `.devcontainer/scripts/post-start-common.sh`, not after:
      that script is bot/dev-shared and its Agent-Deck conductor-start
      block (lines 66-79) launches `agent-deck session start`, an
      autonomous agent session, unconditionally once a conductor is
      registered for the repository. Starting it before `verify` has
      confirmed every harness's policy would let a conductor-launched
      session run against a drifted (prompt-enabled or under-sandboxed)
      bot profile for its entire lifetime, not just until the next verify
      point. Bot `post-start.sh` SHALL `unset NODE_OPTIONS` — duplicating
      `post-start-common.sh`'s own line 6 (which exists to stop VS Code's
      JS debug extension from breaking Node.js processes) — **before**
      calling `verify`, not after: `verify` now runs before
      `post-start-common.sh` has had a chance to sanitize it itself, and
      every module's `verify` step that shells out to a Node-distributed
      harness CLI (Claude Code, Codex, OpenCode) would otherwise inherit
      whatever `NODE_OPTIONS` the editor injected. `post-start.sh` runs
      under `set -euo pipefail`, so a `verify` failure aborts before
      `post-start-common.sh` (and its conductor block) is ever reached;
      dev `post-start.sh` is untouched, mirroring post-create's bot-only
      wiring; verify with a deliberately broken fixture confirming both
      lifecycle points fail, a fixture that sets `NODE_OPTIONS` to a value
      that would break a Node-based harness CLI and confirms `verify`
      still succeeds against a correctly-configured container, AND a
      fixture that registers a conductor, drifts the policy, runs bot
      post-start, and confirms no `agent-deck session start` process is
      ever observed for that container
- [x] 3.3 Extend `scripts/devcontainer-assert.sh`'s existing `container`
      mode to additionally `docker exec` the running container and run
      `bot-autonomy.sh verify` — its current checks cover only Codex's
      `sandbox_mode`/`approval_policy`, so wiring it into CI unmodified
      would leave Claude Code, Antigravity, and OpenCode's modules
      completely unchecked there despite the spec's "every supported
      installed harness" claim; verify with a fixture and a deliberately
      misconfigured file
- [x] 3.3b Wire the (now-extended) assertion into
      `.github/workflows/devcontainer-build.yml` for the bot profile by
      **starting a container and capturing its ID**, not by assuming one
      is already running after the `build` job's `devcontainers/ci`-action
      build/push step (that action builds and pushes an image; it does not
      leave behind a queryable running container). Reuse
      `scripts/devcontainer-smoke.sh`'s existing mechanism — `devcontainer
      up --config .devcontainer/devcontainer.json --log-format json`,
      piped through `jq -r 'select(.outcome=="success") |
      .containerId // empty'` to capture the ID, then
      `devcontainer-assert.sh container <config> <container-id> bot` —
      either by invoking `devcontainer-smoke.sh` directly as a CI step
      (sharing the `build` job's registry build cache, so the second
      build is fast, not a full rebuild) or by porting its up/capture
      steps inline; verify by running the updated workflow (or a local
      `act`/manual dry run) and confirming it fails against a
      deliberately misconfigured image (e.g. Antigravity's settings
      reverted) and passes against the real one
- [x] 3.3a Add `scripts/devcontainer-assert.sh` and, if the
      registry-completeness unit test (task 1.3) lands as a standalone
      script rather than folded into `devcontainer-assert.sh`, that script
      too (e.g. `scripts/test-bot-autonomy.sh`) to `devcontainer-build.yml`'s
      (and its jinja twin's) `paths:` filter for both `push` and
      `pull_request` triggers — today's filter (`.devcontainer/**`, the
      workflow file itself, `scripts/verify-ci-results.sh`) does not include
      either, since both live under root `scripts/`, not `.devcontainer/`;
      the bot-autonomy module tree itself
      (`.devcontainer/scripts/bot-autonomy.sh`,
      `.devcontainer/config/bot-autonomy/**`) is already covered by the
      existing `.devcontainer/**` entry. If task 3.3b's CI wiring picks
      the direct-invocation implementation (calling
      `scripts/devcontainer-smoke.sh` itself as a CI step, rather than
      porting its up/capture steps inline), add `scripts/devcontainer-
      smoke.sh` to the same filter for the same reason — it too lives
      under root `scripts/`, and a PR that changes only that script would
      not otherwise trigger the workflow that runs it; skip this addition
      if the inline-porting alternative is chosen instead, since then no
      new file outside `.devcontainer/**` is on the workflow's critical
      path. Without these, once task 3.3 makes the workflow depend on
      these scripts, a PR that changes only one of them would not trigger
      the workflow that runs it against a built image; verify by
      confirming every added path appears in both files and
      `task test:dogfood-structure` passes
- [x] 3.3c Make the CI container-assertion run (task 3.3b) and any
      repeated local `devcontainer-smoke.sh` run mount run-specific,
      uniquely-named volumes for `~/.gemini` and `~/.config/opencode`
      (for example, suffixed with the CI run ID or a generated UUID),
      created fresh for that run and removed afterward — rather than the
      same persistent named volumes a real bot devcontainer (or a
      developer's own repeated local runs) reuses across rebuilds. Both
      the OpenCode and Antigravity modules gate their backup capture on
      **no backup existing yet** (design.md), so reusing the same
      persistent volume across CI runs would only exercise the true
      first-run/absent state once, ever — every later run would see an
      already-existing backup and silently skip re-proving it, defeating
      the absent→apply→restore fixture (task 2.6) and the option-toggle
      fixtures this change adds for Antigravity (tasks 2.4/2.5); verify by
      running the container-assertion job (or `devcontainer-smoke.sh`)
      twice in a row and confirming both runs independently observe the
      same first-run, absent-backup behavior, and that no volume from
      either run survives to affect a later, unrelated run
- [x] 3.4 Update or retire `enable-claude-bypass.sh`, `enable-codex-bypass.sh`,
      and the `agy()` function in `agy-autonomy.sh` per the design's open
      question; verify no remaining caller references a retired script
- [x] 3.5 Document in `docs/architecture/ci-cd.md`'s
      `devcontainer-build.yml` description (and its `template/` twin) that
      the container-assertion smoke run stays a CI-only, manually-invoked
      check — never wired into the root or template `ci` Taskfile targets
      — because `scripts/devcontainer-smoke.sh` has no skip semantics to
      fall back on locally: it falls back to `npx @devcontainers/cli` (a
      live network dependency, not a no-op) when the `devcontainer` CLI is
      absent, exits non-zero when the `docker` binary or a running daemon
      is unavailable, and refuses outright to run from a linked git
      worktree (its own documented exclusion, lines 28-39) — a real gap
      for this repository's own `task worktree:new`-based workflow, not a
      slow-machine inconvenience. This is AGENTS.md's own `ci`-mirror
      carve-out: a check that needs CI-only infrastructure stays out of
      `ci` and is documented as an exception rather than being faked
      locally. `task test:devcontainer:root` remains the separate, manual
      verification step (task 5.2); verify with `task lint:markdown`

## 4. Docs, template parity, and cross-change coordination

- [x] 4.1 Dedupe the repeated Codex paragraph in
      `docs/guides/devcontainers.md` (lines ~25-41) and describe the
      bootstrap contract (bootstrap entrypoint, three coverage buckets,
      per-harness boundaries, fail-closed points); verify with
      `task lint:markdown`
- [x] 4.2 Update `use_antigravity_cli` help text in `copier.yml` to describe
      the executable-wrapper mechanism instead of (or alongside) the shell
      function; verify with `task check`
- [x] 4.3 Update `docs/architecture/security.md` to document the bot-autonomy
      boundary contract (fail-closed points, per-harness mechanisms); verify
      with `task lint:markdown`
- [x] 4.4 Apply every change in groups 1-3 to the `template/` twin in the
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`);
      verify with `task test:dogfood-parity` and `task test:dogfood-structure`
- [x] 4.4a Apply 4.1's and 4.3's doc edits to their own template twins too:
      `template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`
      and `template/docs/architecture/security.md.jinja` — both exist
      today and are structure twins, so a root-only doc edit leaves them
      stale in generated repos; verify with `task test:dogfood-structure`
      and `task lint:markdown`
- [x] 4.5 File or link the cross-change coordination noted in design.md's
      Decisions: when `harness-matrix` adds the `oh-my-pi` registry row,
      whichever of that change and this one merges second must add
      `oh-my-pi` to the `unsupported` set with `executable: "omp"` — the
      mapped binary name, not the `oh-my-pi` slug itself — and a reason
      naming `bot-autonomy-new-harnesses`; verify the registry-completeness
      unit test (task 1.3) fails on `oh-my-pi`'s addition until that entry
      exists, AND that a fixture installing a fake `omp` executable while
      `oh-my-pi` is still `unsupported` makes `verify` fail naming it —
      matching task 1.4's existing pattern — demonstrating the coordination
      is actually enforced rather
      than merely documented — done: #1150 (`c720eab0`) added `oh-my-pi` to
      `unsupported.json` with `executable: "omp"`; #1165 (`6d2befb5`)
      replaced it with the real `oh-my-pi.sh` module, removing the
      placeholder in the same commit
- [x] 4.6 Add a standing, unchecked checklist item to
      `scripts/sync-devcontainer-image.sh publish`'s PR-body template for
      the sync-pin PR: "bot-autonomy-new-harnesses has merged, covering
      every harness this Dockerfile bump installs (see the
      container-assertion job's result on this PR)" — present on every
      sync-pin PR, so its human reviewer (the sync-pin PR is already
      reviewed before merge, never auto-merged) has an explicit gate to
      check off, corroborated by the container-assertion job's red/green
      result rather than relying on either signal alone; this is what
      makes modules-before-pin an enforced merge prerequisite for that PR
      specifically, not a recommendation resting on the reviewer noticing
      a red check or remembering the ordering; verify the item's literal
      text appears in a sync-pin PR opened or updated after this change

## 5. Verification

- [x] 5.1 Run `task check`, `task verify`, and `task security` locally;
      verify all green
- [x] 5.2 Run `task test:devcontainer:permissions` and (where a Docker
      daemon, the `devcontainer` CLI, and a primary — non-worktree —
      checkout are all available) `task test:devcontainer:root`; this
      stays a manual step, not wired into `task ci` (see task 3.5's
      documented exception); verify both pass
- [ ] 5.3 Rebuild a freshly generated bot devcontainer with
      `use_antigravity_cli: true` and manually exercise one filesystem and
      one GitHub operation through each of Claude Code, Codex, Antigravity,
      and OpenCode; verify zero approval prompts (acceptance criterion 6,
      `[HUMAN]`). Repeat against a rebuild at the default (disabled)
      answer and confirm Claude Code/Codex/OpenCode still show zero
      prompts while Antigravity prompts as expected — the by-design,
      verified-correct outcome at the default, not a regression

      Tracked by #1137's [HUMAN] acceptance criterion; deferred by the
      maintainer 2026-09-05.
