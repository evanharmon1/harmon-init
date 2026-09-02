## 1. Bootstrap entrypoint and registry completeness

- [ ] 1.1 Add `.devcontainer/scripts/bot-autonomy.sh apply|verify`, enumerating
      `agent-registry.json` `harnesses[]` slugs and dispatching to
      `.devcontainer/config/bot-autonomy/<slug>.sh` modules; verify it exits
      non-zero on any module failure
- [ ] 1.2 Define the `unsupported` set (slug → reason) inside
      `bot-autonomy.sh`, covering `gemini` and the DeepSeek Harness slug(s);
      verify the registry schema (`agent-registry.schema.json`) is unchanged
      (`git diff` shows no schema edit)
- [ ] 1.3 Add a unit test asserting every registry harness slug has a module
      or an `unsupported` entry, and that an installed executable with
      neither fails `verify`; verify with `task test:bot-autonomy` (or the
      chosen test task name) passing and failing on injected fixtures

## 2. Per-harness modules

- [ ] 2.1 Add `bot-autonomy/claude-code.sh`: apply sets
      `permissions.defaultMode=bypassPermissions` in
      `/etc/claude-code/managed-settings.json`; verify reads it back; verify
      by running `bot-autonomy.sh apply verify` in a scratch container/fixture
      and confirming the managed file
- [ ] 2.2 Add `.devcontainer/config/codex-managed-config.bot.toml` (complete
      bot baseline, `sandbox_mode = "danger-full-access"`,
      `approval_policy = "never"`) and `bot-autonomy/codex-cli.sh`: apply
      installs it over `/etc/codex/managed_config.toml`; verify checksums the
      installed file against the shipped one; verify by corrupting the
      installed file in a fixture and confirming `verify` fails
- [ ] 2.3 Add `bot-autonomy/antigravity.sh`: apply sets
      `toolPermission: always-proceed` (reusing `apply-antigravity-settings.sh`
      apply semantics) and confirms the bot post-create step below installed
      the wrapper; verify checks both; verify with the existing
      `apply-antigravity-settings.sh` fixture pattern in
      `scripts/devcontainer-assert.sh`
- [ ] 2.4 Install `~/.local/bin/agy` as an executable wrapper from the bot
      post-create only (retiring the `agy()` shell function in
      `agy-autonomy.sh`), injecting `--dangerously-skip-permissions` unless
      already present, passthrough for subcommands/help/version; verify with
      a fixture invoking the wrapper directly (not via a sourced shell) and
      asserting the flag lands
- [ ] 2.5 Add `bot-autonomy/opencode.sh`: apply deep-merges
      `"permission": {"*": "allow"}` into `~/.config/opencode/opencode.json`
      (create-if-absent, preserve existing keys); verify reads the effective
      policy; verify with fixtures covering both the fresh-file and
      merge-into-existing cases

## 3. Fail-closed wiring

- [ ] 3.1 Call `bot-autonomy.sh apply` from `.devcontainer/post-create.sh`
      (bot profile only) and confirm `.devcontainer/dev/post-create.sh` does
      not call it; verify via `scripts/devcontainer-assert.sh` unit-mode
      grep-style assertions (matching the existing Antigravity/Codex pattern)
- [ ] 3.2 Call `bot-autonomy.sh verify` at the end of bot post-create and
      again in bot post-start; verify a deliberately broken fixture fails
      both lifecycle points
- [ ] 3.3 Add a `devcontainer-assert.sh container` invocation for the bot
      profile to `.github/workflows/devcontainer-build.yml`, after the image
      build/push step; verify by running the updated workflow (or a local
      `act`/manual dry run) and confirming it fails against a deliberately
      misconfigured image and passes against the real one
- [ ] 3.4 Update or retire `enable-claude-bypass.sh`, `enable-codex-bypass.sh`,
      and the `agy()` function in `agy-autonomy.sh` per the design's open
      question; verify no remaining caller references a retired script

## 4. Docs and template parity

- [ ] 4.1 Dedupe the repeated Codex paragraph in
      `docs/guides/devcontainers.md` (lines ~25-41) and describe the
      bootstrap contract (bootstrap entrypoint, per-harness boundaries,
      fail-closed points); verify with `task lint:markdown`
- [ ] 4.2 Update `use_antigravity_cli` help text in `copier.yml` to describe
      the executable-wrapper mechanism instead of (or alongside) the shell
      function; verify with `task check`
- [ ] 4.3 Update `docs/architecture/security.md` to document the bot-autonomy
      boundary contract (fail-closed points, per-harness mechanisms); verify
      with `task lint:markdown`
- [ ] 4.4 Apply every change in groups 1-3 to the `template/` twin in the
      same PR (`template/[% if devcontainer %].devcontainer[% endif %]/...`);
      verify with `task test:dogfood-parity` and `task test:dogfood-structure`

## 5. Verification

- [ ] 5.1 Run `task check`, `task verify`, and `task security` locally;
      verify all green
- [ ] 5.2 Run `task test:devcontainer:permissions` and (where a Docker daemon
      is available) `task test:devcontainer:root`; verify both pass
- [ ] 5.3 Rebuild a freshly generated bot devcontainer and manually exercise
      one filesystem and one GitHub operation through each of Claude Code,
      Codex, Antigravity, and OpenCode; verify zero approval prompts
      (acceptance criterion 6, `[HUMAN]`)
