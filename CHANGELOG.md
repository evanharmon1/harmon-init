# Changelog

All notable changes to harmon-init are documented here. Versioning is
[SemVer](https://semver.org) via git tags. Releases are intentional:
release-please maintains a rolling release PR from conventional commits — merge
it to publish the tag, GitHub release, and changelog entry. `task release:*`
remains a manual override. New entries are appended above by release-please;
entries at and below v3.0.0 were hand-written in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style.

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
