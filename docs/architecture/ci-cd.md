# CI/CD

How continuous integration and delivery are wired in Harmon Init. Every
job delegates to `task` targets, so local hooks, CI, and humans run identical
commands (the Taskfile is the single source of truth).

## Quality gate

The pipeline runs `check → build → validate → test → security` (see
[../conventions.md](../conventions.md)). `build.yml` runs these as parallel jobs
plus an aggregate **`verify`** job; branch protection requires `verify` +
`security` to pass before a PR can merge to `main`.

## Workflows

- `build.yml` — on push/PR to `main`: `lint`, `security`, the `template-test`
  matrix (renders every copier profile and validates the output), then the
  aggregate **`verify`** job.
- `claude-plan` / `claude-implement` / `claude-review` — `@claude …` on issues and PRs.
- `devcontainer-build.yml` — builds the root's bot + dev devcontainers on
  `.devcontainer/**` changes (and pushes a GHCR cache on merge to `main`).
- `release.yml` — release-please maintains the rolling release PR.

## Devcontainer build verification

Split deliberately by cost:

- **The image is built once, by dogfooding.** `devcontainer-build.yml` runs a real
  `devcontainers/ci` build of the root repo's own bot + dev devcontainers on every
  PR touching `.devcontainer/**` (and pushes a GHCR cache on merge to `main`).
- **Rendered template configs are validated, not built.** `build.yml`'s
  `template-test` matrix runs `devcontainer read-configuration` on each rendered
  profile (via `scripts/test-template.sh`) — it parses `devcontainer.json` and
  resolves its `features`, but does not build the image.

We **do not** build the rendered devcontainer per copier profile: that would be
~5× the same build for almost no extra coverage, because of one load-bearing
invariant —

> **The template Dockerfile (`template/…/Dockerfile`) stays profile-invariant: no
> `[% … %]` copier conditionals.**

Since it renders identically for every `project_type`, the single dogfood build
above covers the image for all profiles. The only per-profile variation is in
`devcontainer.json` (`forwardPorts`, a few extensions, and the `terraform` feature
when `include_terraform`) — config that `read-configuration` already validates. The
one build path the dogfood does not exercise is the upstream, version-pinned
`terraform` devcontainer feature, whose ref `read-configuration` still resolves.

**If a Dockerfile conditional is ever added** (e.g. branching on `use_node`), this
invariant breaks and the dogfood stops covering all profiles — at that point add a
path-filtered, per-profile rendered build (mirroring `devcontainer-build.yml`) for
the profiles that now differ.

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
