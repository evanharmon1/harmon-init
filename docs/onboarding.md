# Onboarding

Getting productive in Harmon Init.

## Setup

1. Clone the repo: `git clone https://github.com/evanharmon1/harmon-init.git`
2. One-time machine setup (Homebrew): `task bootstrap`
3. Install dependencies and git hooks: `task install`
4. Verify everything works: `task verify`

Prefer the devcontainer? Open the repo in VS Code and "Reopen in Container"
(human profile: `.devcontainer/dev/`), or use the Coder workspace.

## Daily workflow

- Work on feature branches; direct commits to `main` are blocked.
- Conventional commit messages are enforced (`feat:`, `fix:`, `docs:`, ...).
- `task verify` before pushing; CI runs the same checks.
- Releases are manual and intentional: `task release:patch|minor|major`.

## Where things are

See [index.md](index.md) for the documentation map and the README for the
project structure.

TODO: add project-specific context a new contributor needs.
