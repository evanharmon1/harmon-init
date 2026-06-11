# Changelog

All notable changes to harmon-init are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org) via git tags (`task release:*` — releases are
manual and intentional).

## [Unreleased] — v3.0.0

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
  (architecture/decisions/design/guides/runbook + index/testing/
  troubleshooting/glossary/roadmap/onboarding/branchProtection/CHECKLIST),
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
