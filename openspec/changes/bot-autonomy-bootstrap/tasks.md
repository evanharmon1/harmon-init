## 1. Bootstrap entrypoint and registry completeness

- [ ] 1.1 Add `.devcontainer/scripts/bot-autonomy.sh apply|verify`, enumerating
      `agent-registry.json` `harnesses[]` slugs and dispatching to
      `.devcontainer/config/bot-autonomy/<slug>.sh` modules (resolving an
      aliased slug to its target module); verify it exits non-zero on any
      module failure
- [ ] 1.2 Define the three coverage buckets inside `bot-autonomy.sh`: the
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
- [ ] 1.3 Add a unit test asserting every one of the registry's 16 harness
      slugs falls into exactly one of the three buckets, that every
      `unsupported` entry's `executable` is a non-empty string or `null`,
      and that an installed executable with none of the three fails
      `verify`; verify with `task test:bot-autonomy` (or the chosen test
      task name) passing and failing on injected fixtures (an uncovered
      slug, a doubly-covered slug, a missing/malformed `executable` field)
- [ ] 1.4 Make `verify` fail ANY `unsupported` slug the instant its
      executable is installed but it still has no real module or alias —
      uniformly, regardless of the entry's reason (no reason category
      grants an exemption that survives installation); verify with
      fixtures that install a fake `copilot` executable against its
      `unsupported` entry AND a fake `qwen-code`/`goose`/`cline` executable
      against theirs, confirming `verify` fails naming each

## 2. Per-harness modules

- [ ] 2.1 Add `bot-autonomy/claude-code.sh`: apply sets
      `permissions.defaultMode=bypassPermissions` in
      `/etc/claude-code/managed-settings.json`; verify reads it back; verify
      by running `bot-autonomy.sh apply verify` in a scratch container/fixture
      and confirming the managed file, including when launched via one of
      the six aliased `claude-code-*` provider wrappers
- [ ] 2.2 Add `.devcontainer/config/codex-managed-config.bot.toml` (complete
      bot baseline, `sandbox_mode = "danger-full-access"`,
      `approval_policy = "never"`, otherwise identical to
      `codex-managed-config.toml`) and `bot-autonomy/codex-cli.sh`: apply
      installs it over `/etc/codex/managed_config.toml`; verify checksums the
      installed file against the shipped one; verify by corrupting the
      installed file in a fixture and confirming `verify` fails
- [ ] 2.3 Add a structural parity test between `codex-managed-config.toml`
      and `codex-managed-config.bot.toml` asserting every key matches except
      `sandbox_mode`/`approval_policy`; verify it fails when a fixture edits
      `model` in only one of the two files, and passes on the real pair
- [ ] 2.4 Add `bot-autonomy/antigravity.sh`: apply sets
      `toolPermission: always-proceed` (reusing `apply-antigravity-settings.sh`
      apply semantics) and confirms the bot post-create step below installed
      the wrapper; verify checks both; wire its restore path to
      `apply-antigravity-settings.sh restore` rather than a new
      implementation; verify with the existing
      `apply-antigravity-settings.sh` fixture pattern in
      `scripts/devcontainer-assert.sh`
- [ ] 2.5 Install `~/.local/bin/agy` as an executable wrapper from the bot
      post-create only (retiring the `agy()` shell function in
      `agy-autonomy.sh`), injecting `--dangerously-skip-permissions` unless
      already present, porting `agy-autonomy.sh`'s exact passthrough list
      unmodified (bare `agy`, `agent`/`agents`/`changelog`/`help`/`-h`/
      `--help`/`install`/`models`/`plugin`/`plugins`/`update`/`--version`);
      verify with a fixture invoking the wrapper directly (not via a
      sourced shell) asserting the flag lands on a non-passthrough
      invocation and is absent on every passthrough case, and confirm
      `ensure-antigravity-cli.sh`'s `agy --version` call still behaves
      identically through the wrapper
- [ ] 2.5a Add `containerEnv.PATH` to the bot `devcontainer.json` (and its
      `template/` twin) prepending `/home/vscode/.local/bin` ahead of
      `/usr/local/bin`, so the wrapper's precedence is container-wide
      rather than dependent on a shell rc `PATH` export; verify with
      `docker exec <container> agy --version` (no login/interactive
      shell) and with `env -i PATH="$(docker exec <container> printenv
      PATH)" agy --version` inside the container, confirming both resolve
      `~/.local/bin/agy`, not the system binary — this is the case a shell
      function or an rc-only `PATH` edit cannot cover
- [ ] 2.6 Add `bot-autonomy/opencode.sh`: apply force-overwrites
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

- [ ] 3.1 Call `bot-autonomy.sh apply` from `.devcontainer/post-create.sh`
      (bot profile only) and confirm `.devcontainer/dev/post-create.sh` does
      not call it; verify via `scripts/devcontainer-assert.sh` unit-mode
      grep-style assertions (matching the existing Antigravity/Codex pattern)
- [ ] 3.2 Call `bot-autonomy.sh verify` at the end of bot post-create and
      again in bot post-start; verify a deliberately broken fixture fails
      both lifecycle points
- [ ] 3.3 Extend `scripts/devcontainer-assert.sh`'s existing `container`
      mode to additionally `docker exec` the running container and run
      `bot-autonomy.sh verify` — its current checks cover only Codex's
      `sandbox_mode`/`approval_policy`, so wiring it into CI unmodified
      would leave Claude Code, Antigravity, and OpenCode's modules
      completely unchecked there despite the spec's "every supported
      installed harness" claim; verify with a fixture and a deliberately
      misconfigured file
- [ ] 3.3b Wire the (now-extended) assertion into
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
- [ ] 3.3a Add `scripts/devcontainer-assert.sh` to
      `devcontainer-build.yml`'s (and its jinja twin's) `paths:` filter for
      both `push` and `pull_request` triggers — today's filter
      (`.devcontainer/**`, the workflow file itself,
      `scripts/verify-ci-results.sh`) does not include it, so once task
      3.3 makes the workflow depend on this script, a future PR that
      changes only `devcontainer-assert.sh` would not trigger the one
      workflow that runs it against a built image; verify by confirming
      the path appears in both files and `task test:dogfood-structure`
      passes
- [ ] 3.3c Add the CI job that now runs the container-mode assertion
      (task 3.3b) to the repository's **required status checks**
      (`.github/Branch Protection Ruleset - Protect Main.json` /
      `gh api repos/{owner}/{repo}/rulesets`) — confirmed today that only
      `verify` and `security` (from `build.yml`) are required; nothing
      from `devcontainer-build.yml` is, so a red container assertion
      currently cannot by itself block a merge. This is what makes
      "the pin cannot land before the modules exist" an *enforced*
      prerequisite rather than a visible-but-bypassable failure: the
      rolling `sync-pin` PR touches `.devcontainer/Dockerfile`, which
      triggers `devcontainer-build.yml`: once its assertion job is
      required, that PR cannot merge while it bumps to an image with a
      newly-installed, still-`unsupported` harness — see design.md -
      Decisions (the cross-change sequencing entry) and harness-matrix's
      corresponding update; verify by confirming the ruleset lists the
      job name after the change
- [ ] 3.4 Update or retire `enable-claude-bypass.sh`, `enable-codex-bypass.sh`,
      and the `agy()` function in `agy-autonomy.sh` per the design's open
      question; verify no remaining caller references a retired script

## 4. Docs, template parity, and cross-change coordination

- [ ] 4.1 Dedupe the repeated Codex paragraph in
      `docs/guides/devcontainers.md` (lines ~25-41) and describe the
      bootstrap contract (bootstrap entrypoint, three coverage buckets,
      per-harness boundaries, fail-closed points); verify with
      `task lint:markdown`
- [ ] 4.2 Update `use_antigravity_cli` help text in `copier.yml` to describe
      the executable-wrapper mechanism instead of (or alongside) the shell
      function; verify with `task check`
- [ ] 4.3 Update `docs/architecture/security.md` to document the bot-autonomy
      boundary contract (fail-closed points, per-harness mechanisms); verify
      with `task lint:markdown`
- [ ] 4.4 Apply every change in groups 1-3 to the `template/` twin in the
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`);
      verify with `task test:dogfood-parity` and `task test:dogfood-structure`
- [ ] 4.4a Apply 4.1's and 4.3's doc edits to their own template twins too:
      `template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`
      and `template/docs/architecture/security.md.jinja` — both exist
      today and are structure twins, so a root-only doc edit leaves them
      stale in generated repos; verify with `task test:dogfood-structure`
      and `task lint:markdown`
- [ ] 4.5 File or link the cross-change coordination noted in design.md's
      Decisions: when `harness-matrix` adds the `oh-my-pi` registry row,
      whichever of that change and this one merges second must add
      `oh-my-pi` to the `unsupported` set (with a reason naming
      `bot-autonomy-new-harnesses`); verify the registry-completeness unit
      test (task 1.3) fails on `oh-my-pi`'s addition until that entry
      exists, demonstrating the coordination is actually enforced rather
      than merely documented

## 5. Verification

- [ ] 5.1 Run `task check`, `task verify`, and `task security` locally;
      verify all green
- [ ] 5.2 Run `task test:devcontainer:permissions` and (where a Docker daemon
      is available) `task test:devcontainer:root`; verify both pass
- [ ] 5.3 Rebuild a freshly generated bot devcontainer and manually exercise
      one filesystem and one GitHub operation through each of Claude Code,
      Codex, Antigravity, and OpenCode; verify zero approval prompts
      (acceptance criterion 6, `[HUMAN]`)
