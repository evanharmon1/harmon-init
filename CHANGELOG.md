# Changelog

All notable changes to harmon-init are documented here. Versioning is
[SemVer](https://semver.org) via git tags. Releases are intentional:
release-please maintains a rolling release PR from conventional commits — merge
it to publish the tag, GitHub release, and changelog entry. `task release:*`
remains a manual override. New entries are appended above by release-please;
entries at and below v3.0.0 were hand-written in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style.

## [4.3.0](https://github.com/evanharmon1/harmon-init/compare/v4.2.5...v4.3.0) (2026-07-22)


### Features

* add Codex second-model review (challenge/review tasks, stop-gate toggle) ([#345](https://github.com/evanharmon1/harmon-init/issues/345)) ([324651a](https://github.com/evanharmon1/harmon-init/commit/324651a2be69d145a5933779ffaa83893bb07beb))


### Bug Fixes

* **devcontainer:** mask the workspace .venv with a container-private volume ([#346](https://github.com/evanharmon1/harmon-init/issues/346)) ([f6ed86a](https://github.com/evanharmon1/harmon-init/commit/f6ed86a60aee76c932e4c83bbdb73f063d630ff1))

## [4.2.5](https://github.com/evanharmon1/harmon-init/compare/v4.2.4...v4.2.5) (2026-07-21)


### Bug Fixes

* **template:** tell generated repos to index their runbooks ([#340](https://github.com/evanharmon1/harmon-init/issues/340)) ([e48bd7c](https://github.com/evanharmon1/harmon-init/commit/e48bd7c53f5f2cbcbf4e900e72d76eff0f2a921c))

## [4.2.4](https://github.com/evanharmon1/harmon-init/compare/v4.2.3...v4.2.4) (2026-07-21)


### Bug Fixes

* **template:** document the devcontainer's known failure modes ([#337](https://github.com/evanharmon1/harmon-init/issues/337)) ([489a1c5](https://github.com/evanharmon1/harmon-init/commit/489a1c5f08e736cfa8539785b879a22d28f993c8))

## [4.2.3](https://github.com/evanharmon1/harmon-init/compare/v4.2.2...v4.2.3) (2026-07-21)


### Bug Fixes

* harden bootstrap tests, downloads, and agent/runner boundaries ([#335](https://github.com/evanharmon1/harmon-init/issues/335)) ([d3f57c2](https://github.com/evanharmon1/harmon-init/commit/d3f57c26d82a8187d5c578bf2e9944a619e4c01d))
* harden shell tooling, pins, and CI guards across both layers ([#334](https://github.com/evanharmon1/harmon-init/issues/334)) ([20d29f2](https://github.com/evanharmon1/harmon-init/commit/20d29f2ddbd6d4df7fea7f70a280c14c0e689e73))

## [4.2.2](https://github.com/evanharmon1/harmon-init/compare/v4.2.1...v4.2.2) (2026-07-20)


### Bug Fixes

* **devcontainer:** harden the devcontainer scripts against wedged Docker and unpinned CLI ([#333](https://github.com/evanharmon1/harmon-init/issues/333)) ([d836e10](https://github.com/evanharmon1/harmon-init/commit/d836e10b989f79503032466c125c1003d98b5ceb))
* **devcontainer:** probe tailscale through a shell in container asserts ([#330](https://github.com/evanharmon1/harmon-init/issues/330)) ([be32b00](https://github.com/evanharmon1/harmon-init/commit/be32b00b0b66ae43e6fb222d9ec363e3de83ca46))
* **template:** correct verified defects in generated repo tooling and defaults ([#332](https://github.com/evanharmon1/harmon-init/issues/332)) ([32ce6f2](https://github.com/evanharmon1/harmon-init/commit/32ce6f2eb56985d3a5f412c296c2a31fe2ca75a7))

## [4.2.1](https://github.com/evanharmon1/harmon-init/compare/v4.2.0...v4.2.1) (2026-07-20)


### Bug Fixes

* **template:** sync harmon-devkit skills to v0.8.2 ([#325](https://github.com/evanharmon1/harmon-init/issues/325)) ([ee03bc0](https://github.com/evanharmon1/harmon-init/commit/ee03bc06f720c1580ab3199f83212f0c0fc6f2e7))

## [4.2.0](https://github.com/evanharmon1/harmon-init/compare/v4.1.2...v4.2.0) (2026-07-20)


### Features

* make CodeQL intent explicit and CI aggregates fail closed ([#320](https://github.com/evanharmon1/harmon-init/issues/320)) ([93537d3](https://github.com/evanharmon1/harmon-init/commit/93537d3faa2378cf508fcb8867b6338e52eaec3c))


### Bug Fixes

* correct generated template rendering ([#318](https://github.com/evanharmon1/harmon-init/issues/318)) ([991f328](https://github.com/evanharmon1/harmon-init/commit/991f328e232bc4d9bb0d2dd44ffd5976be2481cc))
* make shell formatting path-safe ([#319](https://github.com/evanharmon1/harmon-init/issues/319)) ([88698eb](https://github.com/evanharmon1/harmon-init/commit/88698eb0144c127258ac1247bfa1e2faf3be924c))

## [4.1.2](https://github.com/evanharmon1/harmon-init/compare/v4.1.1...v4.1.2) (2026-07-19)


### Bug Fixes

* **template:** align design handoff bundle wording with the renamed skill ([#321](https://github.com/evanharmon1/harmon-init/issues/321)) ([0ae369c](https://github.com/evanharmon1/harmon-init/commit/0ae369c513a2c64cd7cc13fade48dc84403eae04))

## [4.1.1](https://github.com/evanharmon1/harmon-init/compare/v4.1.0...v4.1.1) (2026-07-18)


### Bug Fixes

* update harmon-devkit skills to v0.7.2 ([#313](https://github.com/evanharmon1/harmon-init/issues/313)) ([7fcee68](https://github.com/evanharmon1/harmon-init/commit/7fcee68dbdcf8d7cba353af462254c5f23266bf5))

## [4.1.0](https://github.com/evanharmon1/harmon-init/compare/v4.0.2...v4.1.0) (2026-07-18)


### Features

* **ci:** guard release-worthy content against non-releasing PR titles ([#311](https://github.com/evanharmon1/harmon-init/issues/311)) ([1bde59d](https://github.com/evanharmon1/harmon-init/commit/1bde59de0b949451160aeb2f0df88fdea54e1919))

## [4.0.2](https://github.com/evanharmon1/harmon-init/compare/v4.0.1...v4.0.2) (2026-07-17)


### Bug Fixes

* **foreman:** harden review and execution boundaries ([#309](https://github.com/evanharmon1/harmon-init/issues/309)) ([cc2f8da](https://github.com/evanharmon1/harmon-init/commit/cc2f8da9bc0815d3214be60f7d168a24628da101))

## [4.0.1](https://github.com/evanharmon1/harmon-init/compare/v4.0.0...v4.0.1) (2026-07-17)


### Bug Fixes

* **ci:** harden shared setup and Semgrep wrapper ([#307](https://github.com/evanharmon1/harmon-init/issues/307)) ([69e6faa](https://github.com/evanharmon1/harmon-init/commit/69e6faa05c9fd6f0bed371d9dc75e99819112f45))

## [4.0.0](https://github.com/evanharmon1/harmon-init/compare/v3.29.1...v4.0.0) (2026-07-17)


### ⚠ BREAKING CHANGES

* **taskfile:** `task verify` now runs the test suite - it is the definition-of-done gate, not the <1-minute fast gate. Use `task check` for the fast inner loop; hooks are unaffected (they already call granular targets). Consumers pick this up via `copier update`.

### Features

* **taskfile:** verify becomes the definition-of-done gate; check is the fast gate ([#304](https://github.com/evanharmon1/harmon-init/issues/304)) ([f4a3138](https://github.com/evanharmon1/harmon-init/commit/f4a3138b4d6be11ce3965b4d5c6d613aca3a7ce4))


### Bug Fixes

* **devcontainer:** install yamllint in the devcontainer image ([#305](https://github.com/evanharmon1/harmon-init/issues/305)) ([6a36125](https://github.com/evanharmon1/harmon-init/commit/6a36125e4476400007c125a62b67ab02c1116e7d))

## [3.29.1](https://github.com/evanharmon1/harmon-init/compare/v3.29.0...v3.29.1) (2026-07-17)


### Miscellaneous Chores

* **skills:** sync standardize-repo from devkit v0.7.0 ([#302](https://github.com/evanharmon1/harmon-init/issues/302)) ([2c47aca](https://github.com/evanharmon1/harmon-init/commit/2c47acafd79d8eecb198e55d873db35dae00a741))

## [3.29.0](https://github.com/evanharmon1/harmon-init/compare/v3.28.0...v3.29.0) (2026-07-17)


### Features

* **renovate:** track harmon-devkit skill releases ([#300](https://github.com/evanharmon1/harmon-init/issues/300)) ([d78a906](https://github.com/evanharmon1/harmon-init/commit/d78a906254b780366092be571ad2ba361a0130cb))
* **security:** establish tiered repository scanning policy ([#299](https://github.com/evanharmon1/harmon-init/issues/299)) ([6d14b6b](https://github.com/evanharmon1/harmon-init/commit/6d14b6bd451add59c18d6808c57fdcc6e3ee16ce))


### Bug Fixes

* **ci:** remove paid Harden Runner dependency ([#298](https://github.com/evanharmon1/harmon-init/issues/298)) ([33095c0](https://github.com/evanharmon1/harmon-init/commit/33095c00691f32a4795150ed7d25dc8b0e704e8c))

## [3.28.0](https://github.com/evanharmon1/harmon-init/compare/v3.27.0...v3.28.0) (2026-07-15)


### Features

* **ci:** fold the review-phase hardening back into the template ([#294](https://github.com/evanharmon1/harmon-init/issues/294)) ([e03e2fe](https://github.com/evanharmon1/harmon-init/commit/e03e2fe68e5140e7c843d3c90dcae95f166dd2cb))

## [3.27.0](https://github.com/evanharmon1/harmon-init/compare/v3.26.1...v3.27.0) (2026-07-15)


### Features

* **ci:** explicit claude sender allowlist (configurable members) instead of org membership ([#293](https://github.com/evanharmon1/harmon-init/issues/293)) ([601eb24](https://github.com/evanharmon1/harmon-init/commit/601eb244c5e3bac62917d724d6fee32b132ecbf3))
* **ci:** shared setup composite action + hardened claude-implement; ADR for release-gated static-site deploys ([#291](https://github.com/evanharmon1/harmon-init/issues/291)) ([7502958](https://github.com/evanharmon1/harmon-init/commit/75029587eda4fb89b335268b15755a09abc3b07a))

## [3.26.1](https://github.com/evanharmon1/harmon-init/compare/v3.26.0...v3.26.1) (2026-07-13)


### Bug Fixes

* **template:** harden sync-skills dest against absolute/traversal paths ([#282](https://github.com/evanharmon1/harmon-init/issues/282)) ([1f995c0](https://github.com/evanharmon1/harmon-init/commit/1f995c070788b813dfc8a250e56c5dfda011bbb5))

## [3.26.0](https://github.com/evanharmon1/harmon-init/compare/v3.25.0...v3.26.0) (2026-07-13)


### Features

* foreman v1 — deterministic supervisor for milestone-driven agent dispatch ([#277](https://github.com/evanharmon1/harmon-init/issues/277)) ([b77d3c1](https://github.com/evanharmon1/harmon-init/commit/b77d3c15a41f10f16d8e075417b667aadd2f26f9))


### Bug Fixes

* **template:** review-findings batch — checkout hardening, secret-helper guards, a11y 2.2 tags ([#276](https://github.com/evanharmon1/harmon-init/issues/276)) ([bb67c3f](https://github.com/evanharmon1/harmon-init/commit/bb67c3f70b0c969468c47293b3504c20ce3f990e))

## [3.25.0](https://github.com/evanharmon1/harmon-init/compare/v3.24.0...v3.25.0) (2026-07-12)


### Features

* **template:** local-skill-safe skills sync + v3.24 sweep retro fixes ([#271](https://github.com/evanharmon1/harmon-init/issues/271)) ([def26af](https://github.com/evanharmon1/harmon-init/commit/def26af07275a4037517610fb3a8cdc56551fdc3))

## [3.24.0](https://github.com/evanharmon1/harmon-init/compare/v3.23.0...v3.24.0) (2026-07-12)


### Features

* **template:** web-app retro from omator — secrets, e2e guard, ESLint 10, renovate jinja pins ([#269](https://github.com/evanharmon1/harmon-init/issues/269)) ([9e222f4](https://github.com/evanharmon1/harmon-init/commit/9e222f4a1f1005ab020ed3851aa87eda48ff18c0))

## [3.23.0](https://github.com/evanharmon1/harmon-init/compare/v3.22.0...v3.23.0) (2026-07-12)


### Features

* **template:** vendor shared agent skills from harmon-devkit ([#267](https://github.com/evanharmon1/harmon-init/issues/267)) ([93b2300](https://github.com/evanharmon1/harmon-init/commit/93b2300f9259503540e100af12610c5f3538d5ce))

## [3.22.0](https://github.com/evanharmon1/harmon-init/compare/v3.21.2...v3.22.0) (2026-07-11)


### Features

* **template:** add axe-core a11y checks for web-app (Playwright, non-blocking) ([#259](https://github.com/evanharmon1/harmon-init/issues/259)) ([f9abd2c](https://github.com/evanharmon1/harmon-init/commit/f9abd2cddfd074f8ee9bed04b4c0ca4d2654f159)), closes [#199](https://github.com/evanharmon1/harmon-init/issues/199)
* **template:** extend axe-core a11y checks to web-astro (mirror web-app) ([#263](https://github.com/evanharmon1/harmon-init/issues/263)) ([5d098dc](https://github.com/evanharmon1/harmon-init/commit/5d098dc8d172b61febd5992a89f518bae93bfe8d)), closes [#262](https://github.com/evanharmon1/harmon-init/issues/262)

## [3.21.2](https://github.com/evanharmon1/harmon-init/compare/v3.21.1...v3.21.2) (2026-07-07)


### Bug Fixes

* **template:** guard build task on fresh scaffold + wrap long desc lines ([#255](https://github.com/evanharmon1/harmon-init/issues/255)) ([6563172](https://github.com/evanharmon1/harmon-init/commit/65631722adb703572605143e2ea71272a60e8804))

## [3.21.1](https://github.com/evanharmon1/harmon-init/compare/v3.21.0...v3.21.1) (2026-07-07)


### Bug Fixes

* **template:** manifest freeze + nested eslint ignores + pnpm key fix ([#252](https://github.com/evanharmon1/harmon-init/issues/252)) ([7be3503](https://github.com/evanharmon1/harmon-init/commit/7be35036a4102abfa5a3e1bcb109c1530cbcbe1a))

## [3.21.0](https://github.com/evanharmon1/harmon-init/compare/v3.20.2...v3.21.0) (2026-07-06)


### Features

* **template:** make fresh web-astro repos deploy-ready + pushable ([#248](https://github.com/evanharmon1/harmon-init/issues/248)) ([ab22c8b](https://github.com/evanharmon1/harmon-init/commit/ab22c8bcb235547c0d6c83572b535cc4ffcd1baf))

## [3.20.2](https://github.com/evanharmon1/harmon-init/compare/v3.20.1...v3.20.2) (2026-07-06)


### Bug Fixes

* **template:** ignore terraform state and tfvars (can contain secrets) ([#243](https://github.com/evanharmon1/harmon-init/issues/243)) ([f85bc73](https://github.com/evanharmon1/harmon-init/commit/f85bc73374ce99e08153dd0dca8533a08be9a351))

## [3.20.1](https://github.com/evanharmon1/harmon-init/compare/v3.20.0...v3.20.1) (2026-07-06)


### Bug Fixes

* **template:** web-astro .prettierignore ignores transient scratch files ([#240](https://github.com/evanharmon1/harmon-init/issues/240)) ([0d96584](https://github.com/evanharmon1/harmon-init/commit/0d965849c2baede23dfa248b160d85d0519c3189))

## [3.20.0](https://github.com/evanharmon1/harmon-init/compare/v3.19.0...v3.20.0) (2026-07-05)


### Features

* **agents:** hard rule — no unprompted password-manager writes ([#230](https://github.com/evanharmon1/harmon-init/issues/230)) ([f69a78c](https://github.com/evanharmon1/harmon-init/commit/f69a78cb014d8a7bc22bee9041ce0cf8da0bdef8))

## [3.19.0](https://github.com/evanharmon1/harmon-init/compare/v3.18.1...v3.19.0) (2026-07-05)


### Features

* **ci:** runtime CI_RUNS_ON runner switch in generated workflows ([#227](https://github.com/evanharmon1/harmon-init/issues/227)) ([c1459dc](https://github.com/evanharmon1/harmon-init/commit/c1459dc7c47d60daff94e66e76f1ebf4ef91947b))
* **deploy:** upstream the proven deployment strategies into the template ([#229](https://github.com/evanharmon1/harmon-init/issues/229)) ([acebc94](https://github.com/evanharmon1/harmon-init/commit/acebc94119942120ec7af7aa62be67013e982536))

## [3.18.1](https://github.com/evanharmon1/harmon-init/compare/v3.18.0...v3.18.1) (2026-07-04)


### Bug Fixes

* **template:** lefthook prettier hook excludes .meta/*.md vault symlinks ([#225](https://github.com/evanharmon1/harmon-init/issues/225)) ([5289927](https://github.com/evanharmon1/harmon-init/commit/528992708ef09514a478e11e0b36b7bcdae58920))

## [3.18.0](https://github.com/evanharmon1/harmon-init/compare/v3.17.0...v3.18.0) (2026-07-04)


### Features

* **template:** per-file lint-hygiene exemptions via .lint-hygiene-ignore ([#222](https://github.com/evanharmon1/harmon-init/issues/222)) ([cf5a3d3](https://github.com/evanharmon1/harmon-init/commit/cf5a3d37fbfaab47ee96be7a1c7f4a8b45352838)), closes [#213](https://github.com/evanharmon1/harmon-init/issues/213)

## [3.17.0](https://github.com/evanharmon1/harmon-init/compare/v3.16.0...v3.17.0) (2026-07-04)


### Features

* **template:** add a summable Size project number field (Fibonacci points) ([#214](https://github.com/evanharmon1/harmon-init/issues/214)) ([c6c40f6](https://github.com/evanharmon1/harmon-init/commit/c6c40f6ebc660c8ba48a4e453ef3c647346e852b))
* **template:** agents must ask before merging to main (convention + settings backstop) ([#221](https://github.com/evanharmon1/harmon-init/issues/221)) ([f3a0779](https://github.com/evanharmon1/harmon-init/commit/f3a0779a3de5ed52f7f2041e526f55cd89dcc0c1))
* **template:** shield design-handoff bundles under specs/ + mobile Playwright convention ([#219](https://github.com/evanharmon1/harmon-init/issues/219)) ([ef83be2](https://github.com/evanharmon1/harmon-init/commit/ef83be24a4d40c48ce3015616ce0e5dc8153ac6c))


### Bug Fixes

* **template:** harden web-astro validators (lychee root-dir, JSON-LD origin check) ([#218](https://github.com/evanharmon1/harmon-init/issues/218)) ([3d4aa67](https://github.com/evanharmon1/harmon-init/commit/3d4aa67de0c372c1a82242c4b135b0865f812ce8))

## [3.16.0](https://github.com/evanharmon1/harmon-init/compare/v3.15.2...v3.16.0) (2026-07-03)


### Features

* **template:** upstream downstream-pioneered install + markdownlint hardening ([#210](https://github.com/evanharmon1/harmon-init/issues/210)) ([528b903](https://github.com/evanharmon1/harmon-init/commit/528b903a44680cf6077b4004861ab5163517bc4d))


### Bug Fixes

* **template:** setup-github-project [#205](https://github.com/evanharmon1/harmon-init/issues/205) parity + stale SNYK_TOKEN setup check ([#209](https://github.com/evanharmon1/harmon-init/issues/209)) ([48dda0a](https://github.com/evanharmon1/harmon-init/commit/48dda0a38cf97860ac746bf83b304adcfadbddea))

## [3.15.2](https://github.com/evanharmon1/harmon-init/compare/v3.15.1...v3.15.2) (2026-07-03)


### Bug Fixes

* **scripts:** correct jq membership test in Status sync ([#205](https://github.com/evanharmon1/harmon-init/issues/205)) ([be41dff](https://github.com/evanharmon1/harmon-init/commit/be41dfff8902a5193cc41e3f48d1b676550e5e29))

## [3.15.1](https://github.com/evanharmon1/harmon-init/compare/v3.15.0...v3.15.1) (2026-07-03)


### Bug Fixes

* add required priority key to Agent issue-field options ([#203](https://github.com/evanharmon1/harmon-init/issues/203)) ([afe577e](https://github.com/evanharmon1/harmon-init/commit/afe577ea72e0d1a62b923dbffcbfe9fb11315983))

## [3.15.0](https://github.com/evanharmon1/harmon-init/compare/v3.14.0...v3.15.0) (2026-07-03)


### Features

* **template:** direnv secrets via .envrc.tpl + op inject ([#195](https://github.com/evanharmon1/harmon-init/issues/195)) ([1370d6c](https://github.com/evanharmon1/harmon-init/commit/1370d6cad602c256d499babb46b6b88df072e372))
* **template:** security scanning strategy (SAST/SCA/secrets/audits) + Snyk optional/local ([#197](https://github.com/evanharmon1/harmon-init/issues/197)) ([dab73ab](https://github.com/evanharmon1/harmon-init/commit/dab73ab1c6f08d3dd652de31d02b5d11698ad1f3))

## [3.14.0](https://github.com/evanharmon1/harmon-init/compare/v3.13.0...v3.14.0) (2026-07-02)


### Features

* **template:** status:setup audits the GitHub PM setup tasks ([#192](https://github.com/evanharmon1/harmon-init/issues/192)) ([ac7d8d2](https://github.com/evanharmon1/harmon-init/commit/ac7d8d2eda878fdd1660c5517f02d37981f77ea9))

## [3.13.0](https://github.com/evanharmon1/harmon-init/compare/v3.12.0...v3.13.0) (2026-07-02)


### Features

* **template:** GitHub board/issue configuration — Status pipeline, issue fields, labels ([#189](https://github.com/evanharmon1/harmon-init/issues/189)) ([a74b162](https://github.com/evanharmon1/harmon-init/commit/a74b16277a7a8e0318aa63ef53319468d3db86ca))
* **template:** issue Forms + org issue-types + issue/commit/release taxonomy ([#190](https://github.com/evanharmon1/harmon-init/issues/190)) ([de58884](https://github.com/evanharmon1/harmon-init/commit/de58884a17f3690b01a2048694c9711e6793e35c))
* **template:** resolve + name the org/user project reliably (ORG_PROJECT_ID + login titles) ([#185](https://github.com/evanharmon1/harmon-init/issues/185)) ([62a828a](https://github.com/evanharmon1/harmon-init/commit/62a828aadc4a4391c927bb8c44659618c2c10ccd))

## [3.12.0](https://github.com/evanharmon1/harmon-init/compare/v3.11.0...v3.12.0) (2026-07-01)


### Features

* **template:** add idempotent setup:github-project task + script ([#184](https://github.com/evanharmon1/harmon-init/issues/184)) ([43fad93](https://github.com/evanharmon1/harmon-init/commit/43fad938eea4f2dcbde4806bad046c203e2a2ef2))
* **template:** add project-management doc gated by new copier question ([#182](https://github.com/evanharmon1/harmon-init/issues/182)) ([719605d](https://github.com/evanharmon1/harmon-init/commit/719605d133a27ed6b4d5dfbeea636342a6d88dda))
* **template:** split .meta Bunch/Obsidian tasks into add + install ([#175](https://github.com/evanharmon1/harmon-init/issues/175)) ([88253e3](https://github.com/evanharmon1/harmon-init/commit/88253e3664c660783732d960f516ab9c319ff111))

## [3.11.0](https://github.com/evanharmon1/harmon-init/compare/v3.10.0...v3.11.0) (2026-06-30)


### Features

* **template:** add web vscode extensions + restore effort-level comment ([#170](https://github.com/evanharmon1/harmon-init/issues/170)) ([42d441b](https://github.com/evanharmon1/harmon-init/commit/42d441b9dd748ff410d75c75fbbd69ec281339cc))
* **template:** ship + self-validate a web-app (TanStack Router + Convex) ESLint config ([#168](https://github.com/evanharmon1/harmon-init/issues/168)) ([e5f9874](https://github.com/evanharmon1/harmon-init/commit/e5f987401f053e9c6ef10653f936c1f33c756941))
* **template:** ship + self-validate a web-astro ESLint config ([#166](https://github.com/evanharmon1/harmon-init/issues/166)) ([76f0e50](https://github.com/evanharmon1/harmon-init/commit/76f0e50b3eb6514475beb9b97d29f46f01a37e34))
* **template:** validate the full web-astro toolchain in the fixture ([#167](https://github.com/evanharmon1/harmon-init/issues/167)) ([14641d7](https://github.com/evanharmon1/harmon-init/commit/14641d7368573e51b26d662479ce69e9507dc157))


### Bug Fixes

* **template:** let Prettier own *.mdx (markdownlint is .md-only) ([#163](https://github.com/evanharmon1/harmon-init/issues/163)) ([de2f189](https://github.com/evanharmon1/harmon-init/commit/de2f1890ff64b9d6ca3b64d3bcc8408e7b25b0ea))

## [3.10.0](https://github.com/evanharmon1/harmon-init/compare/v3.9.1...v3.10.0) (2026-06-29)


### Features

* **ci:** add verify gate to project-automation template ([#159](https://github.com/evanharmon1/harmon-init/issues/159)) ([a1fd5df](https://github.com/evanharmon1/harmon-init/commit/a1fd5dfcd337ced3324cda05cf310a8db41c282d))


### Bug Fixes

* **ci:** name project-automation gate project-automation-verify (not verify) ([#162](https://github.com/evanharmon1/harmon-init/issues/162)) ([0d1a9b2](https://github.com/evanharmon1/harmon-init/commit/0d1a9b2599e5d8ec28394b92bab4cbe0233d634a))
* **ci:** repair project-automation issue-link grep + document CLI key-setting ([#158](https://github.com/evanharmon1/harmon-init/issues/158)) ([47b2be6](https://github.com/evanharmon1/harmon-init/commit/47b2be625cff67f1eaf615650c9b332507f5ec6f))

## [3.9.1](https://github.com/evanharmon1/harmon-init/compare/v3.9.0...v3.9.1) (2026-06-28)


### Bug Fixes

* **template:** freeze .github/CODEOWNERS (don't clobber repo owners on adopt) ([#149](https://github.com/evanharmon1/harmon-init/issues/149)) ([9183ab3](https://github.com/evanharmon1/harmon-init/commit/9183ab3f6e96cf08587999954b0648635566b8bb))
* **template:** make lint:markdown a read-only gate (drop --fix) ([#151](https://github.com/evanharmon1/harmon-init/issues/151)) ([e86c00a](https://github.com/evanharmon1/harmon-init/commit/e86c00acb80575548287e5759afe5135c4a57270))

## [3.9.0](https://github.com/evanharmon1/harmon-init/compare/v3.8.0...v3.9.0) (2026-06-28)


### Features

* **template:** add Latest Release, License, and Open-in-DevContainer README badges ([#143](https://github.com/evanharmon1/harmon-init/issues/143)) ([b83fd2f](https://github.com/evanharmon1/harmon-init/commit/b83fd2f6e9947ad1da4fc4a0399dd65c8da9c180))


### Bug Fixes

* **template:** harden side-effect tasks, fix buildx input, broaden node_modules ignore ([#142](https://github.com/evanharmon1/harmon-init/issues/142)) ([83bdc0a](https://github.com/evanharmon1/harmon-init/commit/83bdc0acbaf8f8dfd2562a6ff8df5ea2fb40965c))

## [3.8.0](https://github.com/evanharmon1/harmon-init/compare/v3.7.0...v3.8.0) (2026-06-28)


### Features

* **template:** track curated .vscode config, ignore machine-written extras ([#138](https://github.com/evanharmon1/harmon-init/issues/138)) ([edf3499](https://github.com/evanharmon1/harmon-init/commit/edf349972d235e4ace68277e342a67fab073ba2c))

## [3.7.0](https://github.com/evanharmon1/harmon-init/compare/v3.6.0...v3.7.0) (2026-06-28)


### Features

* **template:** track the workspace file and .meta/ instead of ignoring them ([#136](https://github.com/evanharmon1/harmon-init/issues/136)) ([07ff52f](https://github.com/evanharmon1/harmon-init/commit/07ff52f43069f6d89ed8868a19ef369bc9b8eba7))


### Bug Fixes

* **template:** make rendered output Prettier-clean + guard it in test-template ([#133](https://github.com/evanharmon1/harmon-init/issues/133)) ([67a4f36](https://github.com/evanharmon1/harmon-init/commit/67a4f36c701cce60cc1d19cb02db07ca03d807a7))

## [3.6.0](https://github.com/evanharmon1/harmon-init/compare/v3.5.1...v3.6.0) (2026-06-28)


### Features

* **template:** add web-astro quality gates (JSON-LD/OG/responsive/links) + Site Overview ([#132](https://github.com/evanharmon1/harmon-init/issues/132)) ([4052922](https://github.com/evanharmon1/harmon-init/commit/405292229663d43522b2dafd7641da43f52b7409))
* **template:** make `verify` the fast agent gate and `ci` a full CI mirror ([#131](https://github.com/evanharmon1/harmon-init/issues/131)) ([31eb4c0](https://github.com/evanharmon1/harmon-init/commit/31eb4c0a3d1602c709910d37112dc86dff3f481b))


### Bug Fixes

* pin the uv and starship installers in the devcontainer image ([#130](https://github.com/evanharmon1/harmon-init/issues/130)) ([0a99873](https://github.com/evanharmon1/harmon-init/commit/0a9987321c22f502a36a3f8fd9d6e603a7a5cc6d))
* **template:** make editor/prettier config project-type-aware ([#126](https://github.com/evanharmon1/harmon-init/issues/126)) ([53e0e30](https://github.com/evanharmon1/harmon-init/commit/53e0e305f3a0308dfe73125c485170b212c50d4c))
* **template:** make generated CI correct on hosted and self-hosted runners ([#125](https://github.com/evanharmon1/harmon-init/issues/125)) ([5b85fe2](https://github.com/evanharmon1/harmon-init/commit/5b85fe29b2f03969e7bbeafa24a91d3d2f7609ef))


### Performance Improvements

* **template:** drop npm download cache from devcontainer image layers ([#127](https://github.com/evanharmon1/harmon-init/issues/127)) ([0a90a5a](https://github.com/evanharmon1/harmon-init/commit/0a90a5a3c1405f5700ade99c55cc3f090be1d650))

## [3.5.1](https://github.com/evanharmon1/harmon-init/compare/v3.5.0...v3.5.1) (2026-06-27)


### Bug Fixes

* **template:** drop trailing blank line in .copier-answers.yml ([#122](https://github.com/evanharmon1/harmon-init/issues/122)) ([ec98078](https://github.com/evanharmon1/harmon-init/commit/ec980781de641b0d8528e4d153ac908722f94ed6))

## [3.5.0](https://github.com/evanharmon1/harmon-init/compare/v3.4.0...v3.5.0) (2026-06-26)


### Features

* **status:** show CHECKLIST.md completion in status:setup ([#116](https://github.com/evanharmon1/harmon-init/issues/116)) ([5efdb72](https://github.com/evanharmon1/harmon-init/commit/5efdb72df1c9307be929e641217ddefd777027a7))

## [3.4.0](https://github.com/evanharmon1/harmon-init/compare/v3.3.3...v3.4.0) (2026-06-26)


### Features

* **template:** make copier update safe (no target-repo complexity) ([#112](https://github.com/evanharmon1/harmon-init/issues/112)) ([7dd0dfa](https://github.com/evanharmon1/harmon-init/commit/7dd0dfa1221b14719ad8e611ae19885c6a9e9810))

## [3.3.3](https://github.com/evanharmon1/harmon-init/compare/v3.3.2...v3.3.3) (2026-06-25)


### Bug Fixes

* **status:** detect setup workflows by .yml and .yaml ([#109](https://github.com/evanharmon1/harmon-init/issues/109)) ([ba52871](https://github.com/evanharmon1/harmon-init/commit/ba52871e129c6e5e6494a72478f2feb2ca019ad7))

## [3.3.2](https://github.com/evanharmon1/harmon-init/compare/v3.3.1...v3.3.2) (2026-06-25)


### Bug Fixes

* **template:** idempotent task bootstrap + task test:tasks Taskfile guard ([#102](https://github.com/evanharmon1/harmon-init/issues/102)) ([1944d6e](https://github.com/evanharmon1/harmon-init/commit/1944d6e4ac00f494b545e44e067893150ff903db))

## [3.3.1](https://github.com/evanharmon1/harmon-init/compare/v3.3.0...v3.3.1) (2026-06-25)


### Bug Fixes

* **status:** status.sh set -e safety + Brewfile local-tooling parity (tokei, gum, television) ([#100](https://github.com/evanharmon1/harmon-init/issues/100)) ([581a6ec](https://github.com/evanharmon1/harmon-init/commit/581a6ec2bd161647028273604a25009225f89670))

## [3.3.0](https://github.com/evanharmon1/harmon-init/compare/v3.2.1...v3.3.0) (2026-06-24)


### Features

* **status:** add GitHub setup-completeness audit (task status:setup) ([#95](https://github.com/evanharmon1/harmon-init/issues/95)) ([98556aa](https://github.com/evanharmon1/harmon-init/commit/98556aa32b7e835c047865cd581c550d5296a625))
* **status:** broaden setup audit + visual grouped output ([#97](https://github.com/evanharmon1/harmon-init/issues/97)) ([c896ac0](https://github.com/evanharmon1/harmon-init/commit/c896ac0da3da79be0a8cf573ef14458dd97188ed))

## [3.2.1](https://github.com/evanharmon1/harmon-init/compare/v3.2.0...v3.2.1) (2026-06-24)


### Bug Fixes

* **template:** skip private vulnerability reporting on private repos ([#93](https://github.com/evanharmon1/harmon-init/issues/93)) ([8c755e2](https://github.com/evanharmon1/harmon-init/commit/8c755e2f7b43d6637f7cd1aa05b7621c25cce1de))

## [3.2.0](https://github.com/evanharmon1/harmon-init/compare/v3.1.1...v3.2.0) (2026-06-24)


### Features

* **devcontainer:** delegate Claude hooks to Taskfile and add permission tests ([#88](https://github.com/evanharmon1/harmon-init/issues/88)) ([00b4217](https://github.com/evanharmon1/harmon-init/commit/00b4217dcb1cb352525399e1208e7cfe5d44d7f6))
* **template:** add `task setup:github` for idempotent repo settings ([#86](https://github.com/evanharmon1/harmon-init/issues/86)) ([88a0940](https://github.com/evanharmon1/harmon-init/commit/88a0940c6f7337807693341c553f353bbfa30450))
* **template:** add code_owner question and improve issue/PR templates ([#89](https://github.com/evanharmon1/harmon-init/issues/89)) ([af4e742](https://github.com/evanharmon1/harmon-init/commit/af4e742e2bbc5e2fe57b016ece62169b82ec4121))


### Bug Fixes

* **template:** markdownlint — exclude artifact dirs + MD024 siblings_only ([#84](https://github.com/evanharmon1/harmon-init/issues/84)) ([7c7ae07](https://github.com/evanharmon1/harmon-init/commit/7c7ae072b0205ed85f966d94e7438c8b24ef4087))

## [3.1.1](https://github.com/evanharmon1/harmon-init/compare/v3.1.0...v3.1.1) (2026-06-23)


### Bug Fixes

* don't enforce a repo-wide YAML extension convention ([#81](https://github.com/evanharmon1/harmon-init/issues/81)) ([bb5b42d](https://github.com/evanharmon1/harmon-init/commit/bb5b42dc557eb903bb44cf61eb10e32b0cd500b5))
* ensure rendered LICENSE ends with a trailing newline ([#80](https://github.com/evanharmon1/harmon-init/issues/80)) ([42bc585](https://github.com/evanharmon1/harmon-init/commit/42bc585acd141d1fc1ded3b4c69759410fe3c3de))

## [3.1.0](https://github.com/evanharmon1/harmon-init/compare/v3.0.3...v3.1.0) (2026-06-22)


### Features

* authenticate CI workflows as a GitHub App (not a PAT) ([#74](https://github.com/evanharmon1/harmon-init/issues/74)) ([4931dfe](https://github.com/evanharmon1/harmon-init/commit/4931dfe39b5742117c1a41c2eec50692797bb469))
* release-please, DESIGN.md, IaC scaffolds, and CI polish ([#72](https://github.com/evanharmon1/harmon-init/issues/72)) ([b925224](https://github.com/evanharmon1/harmon-init/commit/b925224de9840246bf91459cebe87990d465f090))

## [3.0.0]

Breaking redesign porting the current repo conventions from harmon-infra and
sommerlawn-web into the template.

### Added

- Template generation test harness (`task test:template:*` +
  `scripts/test-template.sh`) with a 4-profile matrix (minimal/web/iac/full)
  run locally, in pre-push hooks, and in CI.
- New copier questions: `github_org`, `project_type`
  (general | web-astro | web-app | iac | docs), `include_terraform`,
  `include_ansible`, `ci_runner` (ubuntu-latest | self-hosted).
- Template: lefthook + commitlint + gitleaks, namespaced Taskfile,
  Claude Code GitHub workflows (plan/implement/review), CodeQL,
  devcontainer prebuild workflow (GHCR), branch-protection ruleset JSON,
  renovate.json, .coderabbit.yaml, dual-profile devcontainer (AI bot +
  human dev with Tailscale) ported from harmon-infra, docs tree
  (architecture/decisions/guides/runbooks/product + README/tests/
  troubleshooting/glossary/roadmap/onboarding/branch-protection/CHECKLIST),
  specs/ and tests/ at root, CHANGELOG.md, .claude settings, conditional
  pyproject.toml/.python-version (uv), terraform/ansible skeletons.
- Canonical `AGENTS.md` with `CLAUDE.md`/`GEMINI.md` symlinks (both layers).

### Changed

- Custom jinja delimiters `[[ ]]` / `[% %]` via `_envops` (no more
  `{% raw %}` escaping); `_preserve_symlinks: true`.
- `devcontainer` defaults to yes; `bunch_add` defaults to no (CI-safe).
- Root layer dogfoods the same conventions (lefthook, gitleaks, namespaced
  Taskfile, renovate, coderabbit).

### Removed

- Auto-release on merge to main (both layers) — releases are now manual via
  `task release:patch|minor|major`.
- pre-commit, whispers, check_for_pattern.sh, justfile/howzit conditionals,
  dependabot.yml (Renovate owns version updates; Dependabot alerts are repo
  settings), legacy questions (`ci_cd`, `git_provider`, `docker_*`,
  `project_url`, `github_collaboration_templates`, ...).
