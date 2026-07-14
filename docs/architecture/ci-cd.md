# CI/CD

How continuous integration and delivery are wired in Harmon Init. Every
job delegates to `task` targets, so local hooks, CI, and humans run identical
commands (the Taskfile is the single source of truth).

## Quality gate

The pipeline runs `check → build → validate → test → security` (see
[../conventions.md](../conventions.md)). `build.yml` runs these as parallel jobs
plus an aggregate **`verify`** job; branch protection requires `verify` +
`security` to pass before a PR can merge to `main`.

Repository-controlled leaf jobs deliberately skip untrusted fork PRs. The
aggregate accepts that state only when the event is actually a fork and every
suppressed leaf reports `skipped`; its fork path is an inline diagnostic that
does not check out or execute repository code. Same-repository PRs and all
non-PR events require every leaf to report `success`. The devcontainer
aggregate follows the same contract.

This contract does not make persistent self-hosted runners generally safe for
public repositories. Treat runner exposure as a manual policy check: keep
untrusted contribution workflows on GitHub-hosted runners, and audit every
custom workflow for fork, `pull_request_target`, and other untrusted-input paths
before allowing it to target a self-hosted runner.

## Workflows

- `build.yml` — on push/PR to `main`: lint, security, then the aggregate **`verify`** job.
- `claude-plan` / `claude-implement` / `claude-review` — `@claude …` on issues and PRs.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR on `.devcontainer/**` changes.
- `release.yml` — release-please maintains the rolling release PR.
- `close-milestone-on-release.yml` — closes the milestone matching the tag on release publish.

## Authentication

CI workflows authenticate as the **`evanharmon1-ci` GitHub App** (short-lived
tokens minted at runtime), not a PAT — see [security.md](security.md).
Third-party actions are pinned by commit SHA and bumped by Renovate.

## Releases

release-please opens a rolling release PR from conventional commits; merging it
cuts the tag, GitHub release, and CHANGELOG. Nothing auto-releases on a normal
merge.

TODO: document deployment targets/environments here once they exist; the deploy
how-to lives at [../guides/deploying.md](../guides/deploying.md).
