## 1. Add GitHub Copilot CLI

- [x] 1.1 Add `# renovate: datasource=npm depName=@github/copilot` +
      `ARG COPILOT_VERSION=1.0.82` to `images/devcontainer/Dockerfile`;
      verify Renovate's dependency dashboard picks it up (or dry-run
      `renovate-config-validator`) — verified via `task test:renovate-pins`
- [x] 1.2 Add `"@github/copilot@${COPILOT_VERSION}"` to the npm global-install
      layer; verify `docker build` succeeds and `copilot --version` runs in
      the built image — verified via `task test:devcontainer:image` (full
      build + smoke pass)
- [x] 1.3 Research whether Copilot CLI exposes an auto-update-disable
      switch; if so, set it in the image `ENV` block matching the
      `DISABLE_AUTOUPDATER`/`OPENCODE_DISABLE_AUTOUPDATE`/
      `AGY_CLI_DISABLE_AUTO_UPDATE` pattern; verify with `smoke.sh` —
      confirmed via `copilot help environment`: `COPILOT_AUTO_UPDATE=false`;
      set and verified in the built image via `smoke.sh`
- [x] 1.4 Determine whether `@github/copilot`'s platform binary is fetched
      separately from the npm package (its `npm-loader.js` bin's small
      unpacked size suggests it is) or already bundled; if fetched
      separately, force that fetch inside the same `RUN` layer as the
      `npm install -g` (e.g. running `copilot --version` once, or
      whatever the loader documents as triggering the download) so the
      built image never needs network access to run `copilot`; verify
      with a container run that blocks network access and confirms
      `copilot --version` still succeeds — the platform binary resolves via
      an npm `optionalDependency` during `npm install` itself (not a
      lifecycle script, not a first-run fetch); `copilot --version` forced
      in the same `RUN` layer, verified network-free via
      `docker run --network=none --user vscode` against both a scratch
      build and (post-gauntlet) an automated check in
      `scripts/test-devcontainer-image.sh`, covering amd64 locally and
      arm64 via the publish workflow's QEMU step

## 2. Add pi

- [x] 2.1 Add `# renovate: datasource=npm
      depName=@earendil-works/pi-coding-agent` + `ARG PI_VERSION=0.84.4`;
      verify the annotation matches the existing generic ARG-pin regex
      (`renovate-config-validator` or a `git grep` self-check against
      `renovate.json`'s pattern) — verified via `task test:renovate-pins`
- [x] 2.2 Install pi in its **own** `RUN npm install -g
      "@earendil-works/pi-coding-agent@${PI_VERSION}" --ignore-scripts`
      layer, separate from the combined npm layer that installs Claude
      Code/Codex/OpenCode/dmux/Copilot CLI — `--ignore-scripts` applies to
      every package in whatever invocation it is part of, and Copilot
      CLI's `npm-loader.js` may depend on a lifecycle step to fetch its
      platform binary (see task 1.3), so combining the two would risk
      silently breaking Copilot instead of only hardening pi; verify
      `pi --version` in the built image and that the combined layer's other
      tools are unaffected — verified via the full build + smoke pass;
      confirmed pi's own package ships no install/postinstall lifecycle
      script (hardening only), and Copilot's fetch is actually an npm
      `optionalDependency`, not a lifecycle script — the isolation is
      correct regardless
- [x] 2.3 Set `PI_SKIP_VERSION_CHECK` in the image `ENV` block; verify with
      `smoke.sh` — confirmed via pi's bundled source
      (`if(!process.env.PI_SKIP_VERSION_CHECK)`, any truthy value works);
      set to `1` and verified in the built image via `smoke.sh`

## 3. Add oh-my-pi

- [x] 3.1 Add `# renovate: datasource=github-releases
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
      trusting them — independently re-downloaded both `omp-linux-{x64,arm64}`
      assets from the live `v18.1.2` release and computed their SHA-256
      directly (not via `SHA256SUMS.txt`): both match these pinned digests
      exactly
- [x] 3.2 Add a `TARGETARCH`-cased install block (mirroring TFLint's
      hardcoded-digest shape, not Terraform's fetch-and-verify shape):
      download `omp-linux-${arch}`, check its SHA-256 against the
      matching `OH_MY_PI_SHA256_${ARCH}` `ARG` (no `SHA256SUMS.txt`
      download), then `install -m 0755` the binary as `omp`; verify the
      build fails when the checksum is deliberately corrupted in a
      scratch test and succeeds against the real asset — succeeds:
      confirmed via the full image build (`sha256sum --check -` reported
      `OK`); fails closed: confirmed in a standalone scratch test that
      `sha256sum --check -` against the real downloaded asset with a
      deliberately wrong digest reports `FAILED` / exit 1, which the
      Dockerfile's `&&`-chained `RUN` propagates to a failed `docker build`
- [x] 3.3 Add a new `oh-my-pi` harness row to **both** `agent-registry.json`
      and its verbatim twin `template/agent-registry.json`
      (`family_constraint: {kind: broker}`,
      `model_resolution.owner: harness-runtime`,
      `roles: [orchestrate, implement, review]`, matching `pi`'s shape);
      verify with `scripts/validate-agent-registry.mjs`,
      `task test:agent-registry`, and `task test:dogfood-parity` (the two
      files must stay byte-identical per AGENTS.md's dogfood-parity table)
      — all three verified green
- [x] 3.4 Reconcile with `bot-autonomy-bootstrap`'s registry-completeness
      unit test: whichever of that change and this one merges second must
      add `oh-my-pi` to `bot-autonomy-bootstrap`'s `unsupported` set (reason:
      pending `bot-autonomy-new-harnesses`; **`executable: "omp"`** — the
      mapped binary name this change installs, per task 3.2, not the
      `oh-my-pi` slug itself, matching how `verify` checks `command -v
      <executable>` against every other `unsupported` entry) in the same
      PR that adds the `oh-my-pi` registry row here; verify by confirming
      `bot-autonomy-bootstrap`'s registry-completeness test still passes
      after this row lands, AND by adding a fixture (in whichever change's
      test suite the reconciling PR touches) that installs a fake `omp`
      executable while `oh-my-pi` is still `unsupported` and confirms
      `bot-autonomy.sh verify` fails naming it — matching
      `bot-autonomy-bootstrap`'s existing pattern for
      `copilot`/`qwen`/`goose`/`clite` (see that change's design.md -
      Decisions and its tasks 1.4 and 4.5)

      **Not applicable to this PR**: `bot-autonomy-bootstrap` is not yet
      implemented (only its own OpenSpec proposal exists in this repo as of
      this PR) — there is no `unsupported` set yet to add `oh-my-pi` to.
      Per this task's own "whichever...merges second" rule, since
      `harness-matrix` (this PR) is merging first, the reconciliation falls
      to `bot-autonomy-bootstrap`'s own implementation when it lands.

      **Done**: #1150 (`c720eab0`) added `oh-my-pi` to
      `bot-autonomy-bootstrap`'s `unsupported.json` with
      `executable: "omp"`; #1165 (`6d2befb5`) replaced it with the real
      `oh-my-pi.sh` module.

## 4. Remove Gemini CLI

- [x] 4.1 Remove `GEMINI_CLI_VERSION` `ARG` and the
      `"@google/gemini-cli@${GEMINI_CLI_VERSION}"` npm line from the
      Dockerfile; verify `docker build` succeeds and no `gemini` binary is
      on `PATH` in the built image — verified via the full build (zero
      `gemini` occurrences in the entire build log) and `smoke.sh`'s new
      negative assertion
- [x] 4.2 Remove the `"gemini-cli=${GEMINI_CLI_VERSION}"` argument from the
      `generate-manifest.sh` invocation; verify the manifest no longer
      contains a `gemini-cli` key — verified via the built manifest.json and
      `smoke.sh`'s new `jq 'has("gemini-cli")|not'` assertion
- [x] 4.3 Remove `gemini` from `smoke.sh`'s tool-presence loop and its
      `run_version gemini gemini --version` probe; verify `smoke.sh` passes
      against the built image without it — verified (`harmon-devcontainer
      smoke: passed`)
- [x] 4.4 Confirm the `~/.gemini` volume mount (both `devcontainer.json`
      twins), the `gemini` family entry in `agent-registry.json`, and the
      `GEMINI.md` symlink convention are untouched; verify by diffing this
      change against those three surfaces and confirming no edits — verified
      by diff: no edits to either `mounts` array, `agent-registry.json`'s
      `gemini` family entry, or the symlink convention
- [x] 4.5 Drop "Gemini" from the "(Claude Code, Codex, Gemini, OpenCode)"
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
      all four files (both edits) — chose to note it now persists
      Antigravity's state (rather than dropping it from the list) since
      that's more informative to a reader; all verifications green, grep
      confirms zero "Gemini" occurrences across all four files
- [x] 4.5a Rewrite the version-mismatch worked example in
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
      file — reworded to a hypothetical ("a laptop may already have a newer
      patch release installed") rather than a second hardcoded number, so it
      cannot go stale the same way again; all verifications green
- [x] 4.6 Update `docs/guides/herdr.md` (root) and its jinja twin
      `template/docs/guides/herdr.md.jinja`: drop `gemini` from the list of
      harnesses the pinned image includes and bump that same sentence's
      version stamp (line ~248-249, "claude, codex, gemini, agy
      (Antigravity), and opencode are in the 0.8.0 image the devcontainers
      pin" → drop `gemini`, `0.8.0` → `0.8.2`) — a bare version-stamp
      substitution, unlike task 4.5a's worked example, since this sentence
      states no second number to go stale against; verify with `task
      lint:markdown`, `task test:dogfood-structure` (jinja twin), and a
      grep confirming no stale `gemini` reference remains in either file —
      also fixed an adjacent stale reference this same version bump caused:
      "Herdr 0.8.0 (the devcontainer pin) can report...ready before...
      (fixed in 0.8.2)" (~line 204) asserted the pin was still 0.8.0; reworded
      to "Herdr before 0.8.2 could report...(fixed in 0.8.2, which the
      devcontainer image now pins)" in both files; all verifications green

## 5. Bump herdr

- [x] 5.1 Bump `HERDR_VERSION` from `0.8.0` to `0.8.2` in the Dockerfile;
      verify `herdr --version` in the built image and the manifest agree —
      verified via the full build + smoke pass

## 6. Cross-cutting verification

- [x] 6.1 Confirm every new/removed tool has a matching manifest arg and
      smoke probe (groups 1-4); verify with a single `smoke.sh` run against
      the built image — verified (`harmon-devcontainer smoke: passed`)
- [x] 6.1a Extend `smoke.sh` with explicit reported-version-vs-manifest
      comparisons for `copilot`, `pi`, and `omp` — matching the pattern
      already used for `task`/`terraform`/`tflint`/`agy` (parse the
      version out of the tool's own output and assert it equals
      `jq -r '.tools.<key>' "$manifest"`), not the generic `run_version`
      helper alone, which only checks exit status and would let a
      successfully-running wrong version pass; verify by deliberately
      mismatching one tool's manifest entry in a fixture and confirming
      `smoke.sh` fails — added; the real build's manifest matched (correct
      case), and a standalone reproduction of the exact comparison logic
      against a deliberately mismatched fixture manifest confirmed it fails
      with the expected message (all three tools share one comparison
      pattern, so one representative test covers the shared logic)
- [x] 6.2 Build both `amd64` and `arm64` via the publish workflow's
      candidate job (or local `docker buildx build --platform`); verify both
      succeed and both pass `smoke.sh` — amd64: built and smoke-tested
      locally in full (native, no emulation). arm64: not built locally (no
      local arm64 hardware/QEMU attempted in this session); relies on the
      publish workflow's candidate job, which builds and smoke-tests it
      under QEMU on every PR touching `images/devcontainer/**` — this PR
      now also carries a matching network-isolated Copilot check on that
      arm64 path (challenge round 2), not just the pre-existing `smoke.sh`
      run
- [x] 6.3 Run `task check`, `task verify`, and `task security` in this
      worktree; verify all green — all three green at the final commit
      (`task verify` completed a full clean end-to-end run, including the
      complete `test:template:all` render matrix)
- [x] 6.4 After merge to `main` and image publish, confirm (or file/track)
      the rolling `sync-pin` PR picks up the new digest for both
      `.devcontainer/Dockerfile` twins; do not bump that pin from this
      change

      **Not yet applicable**: this task is explicitly sequenced after merge
      and image publish, neither of which has happened yet (this PR is
      still draft, per its brief's "stop at the draft PR" instruction).

      **Done**: rolling pin PR #1152 carries the new digest for both
      `.devcontainer/Dockerfile` twins (`.devcontainer/Dockerfile` and
      `template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile`,
      one line each).
      Left for whoever shepherds/merges this PR to confirm.
