## 1. Copier answer and template gating

- [ ] 1.1 Add the `use_fly_sprites` question to `copier.yml` (bool, default no, `when: "[[ devcontainer ]]"`, help text naming the Fly.io account requirement, usage-based pricing, trial-only free allowance, and the private-repository caveat) and verify `task test:copier-validators` and `task test:template:all` pass with the option off and on
- [ ] 1.2 Add the `use_fly_sprites` row to `docs/copier-options.md` and verify `task test:registry-docs`/`lint:markdown` pass
- [ ] 1.3 Gate the new files under `template/` on the answer (jinja-named paths for `taskfiles/sprites.yml`, `scripts/sprite-lane.sh`, `scripts/test-sprite-lane.sh`, `docs/guides/sprites.md`) and verify a `--defaults` render contains none of them while a `use_fly_sprites: yes` render contains all of them (`task test:template:all`, plus a new profile or an assertion in `scripts/test-template.sh`)
- [ ] 1.4 Record `use_fly_sprites: true` in `.dogfood-answers.yml`, add the root twins, and verify `task test:dogfood-parity` and `task test:dogfood-structure` are green; add any intentional divergence to `scripts/audit-dogfood.sh` with a reason

## 2. Lane helper

- [ ] 2.1 Write `scripts/sprite-lane.sh` with subcommands `pool init|list`, `lane new|exec|attach|harvest|rm`, and `audit`, each shelling to the `sprite` CLI and the devcontainers CLI only (no hand-rolled API calls beyond `sprite api` for the network policy and Tasks hold), and verify `task lint:shell` passes (shellcheck `--severity=error`, `shfmt -d`, bash 3.2 portable)
- [ ] 2.2 Implement `pool init`: install Docker, the devcontainers CLI, and `openssh-server` in the sprite, register `dockerd` and `sshd` as sprite Services, pull the pinned image by bringing the bot profile up once and tearing it down, record the image pin in a sprite label, take the golden checkpoint, and refuse beyond the configured pool ceiling; verify with the offline test that the golden checkpoint is taken before any credential step and that the ceiling refusal fires
- [ ] 2.3 Implement `lane new` in the specified order — refuse an unpushed branch, refuse a stale golden pin, restore the golden checkpoint, set the DNS allowlist policy, clone the branch into the inner container's workspace, bring the bot profile up (post-create runs `bot-autonomy.sh apply`/`verify`), inject the env-file through `init-env.sh`'s allow-list, copy the Codex login — and verify the offline test asserts this exact order and that a `verify` failure exits non-zero with the harness named
- [ ] 2.4 Implement `lane exec` (a detachable `sprite exec --tty` into the inner container that runs the given harness command) and `lane attach` (`sprite sessions attach` for the lane's session) and verify with the stubbed CLI that both target the inner container and never the sprite's own shell
- [ ] 2.5 Implement the Tasks-API hold: acquire while a lane pane's agent is `working` or a gate is running, heartbeat under the one-hour limit, release when idle; verify the offline test covers acquire/renew/release and that a killed helper leaves no live hold (the heartbeat process dies with it)
- [ ] 2.6 Implement `lane harvest` (copy the report file to the orchestrator's scratch directory and print the path) and `lane rm` (refuse on unpushed commits without `--force`, stop the container, scrub the env-file and Codex login, restore the golden checkpoint, return to pool or `--destroy`); verify the refusal and the scrub with the offline test
- [ ] 2.7 Implement `audit`: one row per pool sprite and lane (name, state, age, TTL, issue, golden pin) from sprite labels, non-zero exit on any expired lane; verify with the stubbed CLI's canned `sprite list` output
- [ ] 2.8 Write `scripts/test-sprite-lane.sh` with a stubbed `sprite` and `devcontainer` on `PATH` that record every invocation, asserting the ordering rule, every refusal, and that the Sprites token (env var, token file, keyring path) never appears in any recorded argument or written file; wire it as `task test:sprite-lane` into `task verify` (root) and verify `task verify` is green

## 3. Taskfile and configuration

- [ ] 3.1 Add `taskfiles/sprites.yml` with `sprite:pool:init`, `sprite:pool:list`, `sprite:lane:new`, `sprite:lane:exec`, `sprite:lane:attach`, `sprite:lane:harvest`, `sprite:lane:rm`, and `sprite:audit`, each a trivial `cmds:` call into `scripts/sprite-lane.sh`, and include it from `Taskfile.yml` under `sprite:`; verify `task test:tasks` passes and `task --list-all` shows the tasks
- [ ] 3.2 Add the pool ceiling, lane TTL default, and the egress allowlist as variables in `taskfiles/sprites.yml` (with the plan-limit rationale as comments) and verify the helper reads them and the offline test exercises the ceiling
- [ ] 3.3 Update the `runner` comment in `.foreman.toml` (root and template twin) to state what `"sprite"` will mean and that dispatch stays refused until Foreman ships the runner; verify `task test:dogfood-parity` still passes and the value is unchanged

## 4. Documentation

- [ ] 4.1 Write `docs/guides/sprites.md` (root and template twin): prerequisites (Fly account, `sprite` CLI, `sprite org auth`), pool init, the lane loop from Herdr with a worked brief/sentinel/report example, takeover with `herdr --remote` and the SSH alias, cost controls and audit, and the "what Sprites cannot do and the alternative" table; verify `task lint:markdown` and `task test:dogfood-structure`
- [ ] 4.2 Add a "Remote lanes" section to `docs/guides/herdr.md` (and twin) pointing at the sprites guide and stating the pane-process-is-the-session topology and the `unknown`-detection fallback; verify `task test:dogfood-structure`
- [ ] 4.3 Add the sprite credential boundary to `docs/architecture/security.md` (what enters a lane, what never does, the Sprites org token rule) and a pointer from `docs/guides/devcontainers.md`; verify `task lint:markdown`
- [ ] 4.4 Add the dispatch selector (`--env sprite`) to the dev-loop dispatch text this repository owns and verify `task audit:agent-instructions`/`test:agent-instructions-size` stay green

## 5. Follow-ups filed and verification

- [ ] 5.1 File the follow-up issues named in the research note's recommendation (harmon-devkit: herdr skill and dispatch-recipe text; ponderousdev/foreman: runner naming and D5/D6 reconciliation; harmon-init: shorter-lived lane credentials) and verify each is linked from the implementation PR body with `Refs`
- [ ] 5.2 Run the first real lane end to end on the maintainer's Fly account (the `[HUMAN]` criterion on harmon-init#1120) and record wall-clock, cost, Herdr detection result, memory behaviour under `task verify`, and the literal egress hostnames in the research note; verify the note's "Verification status" section is updated and the open questions in design.md are answered or re-deferred
