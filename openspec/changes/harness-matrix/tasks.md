## 1. Add GitHub Copilot CLI

- [ ] 1.1 Add `# renovate: datasource=npm depName=@github/copilot` +
      `ARG COPILOT_VERSION=1.0.82` to `images/devcontainer/Dockerfile`;
      verify Renovate's dependency dashboard picks it up (or dry-run
      `renovate-config-validator`)
- [ ] 1.2 Add `"@github/copilot@${COPILOT_VERSION}"` to the npm global-install
      layer; verify `docker build` succeeds and `copilot --version` runs in
      the built image
- [ ] 1.3 Research whether Copilot CLI exposes an auto-update-disable
      switch; if so, set it in the image `ENV` block matching the
      `DISABLE_AUTOUPDATER`/`OPENCODE_DISABLE_AUTOUPDATE`/
      `AGY_CLI_DISABLE_AUTO_UPDATE` pattern; verify with `smoke.sh`

## 2. Add pi

- [ ] 2.1 Add `# renovate: datasource=npm
      depName=@earendil-works/pi-coding-agent` + `ARG PI_VERSION=0.84.4`;
      verify the annotation matches the existing generic ARG-pin regex
      (`renovate-config-validator` or a `git grep` self-check against
      `renovate.json`'s pattern)
- [ ] 2.2 Install pi in its **own** `RUN npm install -g
      "@earendil-works/pi-coding-agent@${PI_VERSION}" --ignore-scripts`
      layer, separate from the combined npm layer that installs Claude
      Code/Codex/OpenCode/dmux/Copilot CLI — `--ignore-scripts` applies to
      every package in whatever invocation it is part of, and Copilot
      CLI's `npm-loader.js` may depend on a lifecycle step to fetch its
      platform binary (see task 1.3), so combining the two would risk
      silently breaking Copilot instead of only hardening pi; verify
      `pi --version` in the built image and that the combined layer's other
      tools are unaffected
- [ ] 2.3 Set `PI_SKIP_VERSION_CHECK` in the image `ENV` block; verify with
      `smoke.sh`

## 3. Add oh-my-pi

- [ ] 3.1 Add `# renovate: datasource=github-releases
      depName=can1357/oh-my-pi extractVersion=^v?(?<version>.+)$` +
      `ARG OH_MY_PI_VERSION=18.1.2` to the Dockerfile
- [ ] 3.2 Add a `TARGETARCH`-cased install block (mirroring the Terraform
      block's shape): download `omp-linux-${arch}` and that release's
      `SHA256SUMS.txt`, `grep` the matching line, `sha256sum --check -`,
      then `install -m 0755` the binary as `omp`; verify the build fails
      when the checksum is deliberately corrupted in a scratch test and
      succeeds against the real asset
- [ ] 3.3 Add a new `oh-my-pi` harness row to **both** `agent-registry.json`
      and its verbatim twin `template/agent-registry.json`
      (`family_constraint: {kind: broker}`,
      `model_resolution.owner: harness-runtime`,
      `roles: [orchestrate, implement, review]`, matching `pi`'s shape);
      verify with `scripts/validate-agent-registry.mjs`,
      `task test:agent-registry`, and `task test:dogfood-parity` (the two
      files must stay byte-identical per AGENTS.md's dogfood-parity table)
- [ ] 3.4 Reconcile with `bot-autonomy-bootstrap`'s registry-completeness
      unit test: whichever of that change and this one merges second must
      add `oh-my-pi` to `bot-autonomy-bootstrap`'s `unsupported` set (reason:
      pending `bot-autonomy-new-harnesses`) in the same PR that adds the
      `oh-my-pi` registry row here; verify by confirming
      `bot-autonomy-bootstrap`'s registry-completeness test still passes
      after this row lands (see that change's design.md - Decisions and its
      task 4.5)

## 4. Remove Gemini CLI

- [ ] 4.1 Remove `GEMINI_CLI_VERSION` `ARG` and the
      `"@google/gemini-cli@${GEMINI_CLI_VERSION}"` npm line from the
      Dockerfile; verify `docker build` succeeds and no `gemini` binary is
      on `PATH` in the built image
- [ ] 4.2 Remove the `"gemini-cli=${GEMINI_CLI_VERSION}"` argument from the
      `generate-manifest.sh` invocation; verify the manifest no longer
      contains a `gemini-cli` key
- [ ] 4.3 Remove `gemini` from `smoke.sh`'s tool-presence loop and its
      `run_version gemini gemini --version` probe; verify `smoke.sh` passes
      against the built image without it
- [ ] 4.4 Confirm the `~/.gemini` volume mount (both `devcontainer.json`
      twins), the `gemini` family entry in `agent-registry.json`, and the
      `GEMINI.md` symlink convention are untouched; verify by diffing this
      change against those three surfaces and confirming no edits
- [ ] 4.5 Drop "Gemini" from the "(Claude Code, Codex, Gemini, OpenCode)"
      prose in `docs/guides/devcontainers.md` and both `devcontainer.json`
      twins' profile-table comments; verify with `task lint:markdown` and a
      grep for the retired phrase
- [ ] 4.6 Update `docs/guides/herdr.md` (root) and its jinja twin
      `template/docs/guides/herdr.md.jinja`: drop `gemini` from the list of
      harnesses the pinned image includes (line ~248) and update every
      "0.8.0" version reference to match the new herdr pin (task 5.1);
      verify with `task lint:markdown`, `task test:dogfood-structure`
      (jinja twin), and a grep confirming no stale `gemini`/`0.8.0`
      reference remains in either file

## 5. Bump herdr

- [ ] 5.1 Bump `HERDR_VERSION` from `0.8.0` to `0.8.2` in the Dockerfile;
      verify `herdr --version` in the built image and the manifest agree

## 6. Cross-cutting verification

- [ ] 6.1 Confirm every new/removed tool has a matching manifest arg and
      smoke probe (groups 1-4); verify with a single `smoke.sh` run against
      the built image
- [ ] 6.1a Extend `smoke.sh` with explicit reported-version-vs-manifest
      comparisons for `copilot`, `pi`, and `omp` — matching the pattern
      already used for `task`/`terraform`/`tflint`/`agy` (parse the
      version out of the tool's own output and assert it equals
      `jq -r '.tools.<key>' "$manifest"`), not the generic `run_version`
      helper alone, which only checks exit status and would let a
      successfully-running wrong version pass; verify by deliberately
      mismatching one tool's manifest entry in a fixture and confirming
      `smoke.sh` fails
- [ ] 6.2 Build both `amd64` and `arm64` via the publish workflow's
      candidate job (or local `docker buildx build --platform`); verify both
      succeed and both pass `smoke.sh`
- [ ] 6.3 Run `task check`, `task verify`, and `task security` in this
      worktree; verify all green
- [ ] 6.4 After merge to `main` and image publish, confirm (or file/track)
      the rolling `sync-pin` PR picks up the new digest for both
      `.devcontainer/Dockerfile` twins; do not bump that pin from this
      change
