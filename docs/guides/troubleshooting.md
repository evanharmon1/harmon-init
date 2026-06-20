# Troubleshooting

Common issues in Harmon Init and how to fix them.

## Git hooks

- **"lefthook is not installed" on commit** — run `task install:hooks` (or `task install`).
- **Hook failures** — never bypass with `--no-verify`; run `task fix` and re-stage.

## Devcontainer

- **Stale tools after a Dockerfile change** — rebuild the container; prebuilt images come from GHCR (see `.github/workflows/devcontainer-build.yml`).
- **Missing secrets in the container** — the env-file is seeded by `.devcontainer/scripts/init-env.sh` from 1Password or host env on rebuild.

## CI

- **`verify` check missing on a PR** — ensure the Build & Validate workflow ran; required checks are `verify` and `security`.

TODO: add project-specific issues as they come up.
