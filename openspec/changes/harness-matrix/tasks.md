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
- [ ] 1.4 Determine whether `@github/copilot`'s platform binary is fetched
      separately from the npm package (its `npm-loader.js` bin's small
      unpacked size suggests it is) or already bundled; if fetched
      separately, force that fetch inside the same `RUN` layer as the
      `npm install -g` (e.g. running `copilot --version` once, or
      whatever the loader documents as triggering the download) so the
      built image never needs network access to run `copilot`; verify
      with a container run that blocks network access and confirms
      `copilot --version` still succeeds

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
      `ARG OH_MY_PI_VERSION=18.1.2` to the Dockerfile, plus reviewed
      per-architecture digest `ARG`s **mirroring TFLint's
      `TFLINT_SHA256_AMD64`/`ARM64` shape**, not a build-time
      `SHA256SUMS.txt` fetch (see design.md - Decisions): `ARG
      OH_MY_PI_SHA256_AMD64=c6a306347a57c872bf38587e81132db50490228867e3e179a363a4cf874da1a0`
      (`omp-linux-x64`) and `ARG
      OH_MY_PI_SHA256_ARM64=2865c21a73ae8b893fd5553bf302afc5be8a0bcafa015af99732349d518830da`
      (`omp-linux-arm64`) — both fetched and verified against release
      `v18.1.2`'s published `SHA256SUMS.txt` while writing this proposal;
      re-verify against the actual release at implementation time before
      trusting them
- [ ] 3.2 Add a `TARGETARCH`-cased install block (mirroring TFLint's
      hardcoded-digest shape, not Terraform's fetch-and-verify shape):
      download `omp-linux-${arch}`, check its SHA-256 against the
      matching `OH_MY_PI_SHA256_${ARCH}` `ARG` (no `SHA256SUMS.txt`
      download), then `install -m 0755` the binary as `omp`; verify the
      build fails when the checksum is deliberately corrupted in a
      scratch test and succeeds against the real asset
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
      prose in `docs/guides/devcontainers.md` **and its own jinja twin**
      `template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`,
      plus both `devcontainer.json` twins' profile-table comments, AND the
      Herdr-resume paragraph at root line ~315-318 ("post-create installs
      the Claude Code, Codex, and OpenCode integrations automatically
      (`herdr integration install`, idempotent) — Gemini has no resume
      integration in v0.8. The conversations themselves persist
      regardless, in the `~/.claude`, `~/.codex`, `~/.gemini`, and
      `~/.local/share/opencode` volumes...") and its jinja twin: once
      Gemini CLI is not installed, "Gemini has no resume integration"
      reads as describing a still-present harness rather than a removed
      one, and listing `~/.gemini` alongside the other three
      *conversation*-persistence volumes is misleading once that volume
      holds only Antigravity's OAuth/session state, not Gemini CLI
      conversations — drop the Gemini clause and either drop `~/.gemini`
      from this specific volume list or note it now persists Antigravity's
      state instead; verify with `task lint:markdown`, `task
      test:dogfood-structure`, and a grep for the retired phrase across
      all four files (both edits)
- [ ] 4.5a Rewrite the version-mismatch worked example in
      `docs/guides/devcontainers.md` **root line ~649** and its jinja twin
      `template/docs/guides/[% if devcontainer %]devcontainers.md[% endif %].jinja`
      — not `herdr.md`, which task 4.6 handles separately: "The image pins
      `HERDR_VERSION` (0.8.0 today), while a laptop may run a newer
      version (0.8.2)." This is a specific illustration of a mismatch, not
      a bare version stamp, so once the image pin becomes 0.8.2 the
      example must either cite a still-current hypothetical newer laptop
      version or be reworded so it does not claim two different pins are
      simultaneously current; a blind 0.8.0→0.8.2 substitution would leave
      both numbers identical and the example nonsensical; verify with
      `task lint:markdown`, `task test:dogfood-structure` (jinja twin),
      and a grep confirming no stale `0.8.0` reference remains in either
      file
- [ ] 4.6 Update `docs/guides/herdr.md` (root) and its jinja twin
      `template/docs/guides/herdr.md.jinja`: drop `gemini` from the list of
      harnesses the pinned image includes and bump that same sentence's
      version stamp (line ~248-249, "claude, codex, gemini, agy
      (Antigravity), and opencode are in the 0.8.0 image the devcontainers
      pin" → drop `gemini`, `0.8.0` → `0.8.2`) — a bare version-stamp
      substitution, unlike task 4.5a's worked example, since this sentence
      states no second number to go stale against; verify with `task
      lint:markdown`, `task test:dogfood-structure` (jinja twin), and a
      grep confirming no stale `gemini` reference remains in either file

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
