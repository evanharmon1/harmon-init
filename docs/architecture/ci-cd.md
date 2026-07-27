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

- `build.yml` — on push/PR to `main`: lint, security, then the aggregate **`verify`** job.
- `claude-plan` / `claude-implement` / `claude-review` — `@claude …` on issues and PRs.
- `codeql.yml` — Python CodeQL SAST. It runs automatically because Harmon Init is
  public; the private-repository path requires paid GitHub Code Security and
  `FULL_SECURITY_SCAN=true`.
- The `build.yml` security job runs gitleaks + dependency audit and, when a
  repository is private without the paid CodeQL opt-in, Semgrep CE.
- Generated repositories may explicitly opt into `snyk-scheduled.yml` at a
  weekly or daily cadence. It has only schedule/manual triggers, runs Snyk SAST
  and SCA as advisory second-opinion scans, and is never a required PR check.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR on `.devcontainer/**` changes.
- `release.yml` — release-please maintains the rolling release PR.
- `close-milestone-on-release.yml` — closes the milestone matching the tag on release publish.
- `sync-harmon-devkit.yml` — **root-only**: turns a published harmon-devkit
  release into a verified pin-and-sync PR (see below).

## Root-only vs template-shipped workflows

Most root workflows are the rendered form of a `template/` twin and must be
edited in lockstep (AGENTS.md, "Dogfood parity"). A few are **root-only**: they
exist because harmon-init sits inside harmon-platform, and a generated repo has
no such edge. `close-milestone-on-release.yml` and `sync-harmon-devkit.yml` are
root-only; they have no `template/` counterpart, and the dogfood checks are
twin-driven (they walk `template/`), so root-only files are correctly invisible
to them. Do not add a twin to make them "consistent".

## harmon-devkit skills propagation

harmon-init vendors harmon-devkit's shared agent skills at a released tag
(`.skills-sync.yaml` and its template twin). `sync-harmon-devkit.yml` automates
everything between the two intentional release gates:

```text
human merges harmon-devkit's release PR  ->  stable tag
        | repository_dispatch (harmon-devkit-released)
harmon-init validates the tag, pins it, vendors, verifies, opens/updates ONE PR
        |
human merges the sync PR, then harmon-init's release PR
```

- **Triggers:** the dispatch, `workflow_dispatch` (optional tag, for recovery),
  and a daily reconciliation `schedule` so a dropped dispatch cannot leave the
  pin stale. One `concurrency` group serializes all three.
- **Trust:** the payload tag is untrusted. `scripts/sync-devkit-release.sh`
  checks its shape in pure shell (no regex a newline can split), then confirms
  the release exists upstream and is neither a draft nor a prerelease, before
  anything is written. It reaches the helper only through the environment.
- **Token scope:** the checkout keeps `persist-credentials: false`; the App
  token authenticates only the individual `git` calls that talk to origin, via
  a process-scoped credential helper, and the sync and verification targets run
  with `GH_TOKEN` scrubbed. A contents:write credential is therefore never
  visible to the copier renders, `npx`, and `uvx` that `task verify` spawns.
- **Base integrity:** the run refuses to start unless `HEAD` is `main` and
  `main` matches `origin/main`, so a force-push can never publish unrelated
  local commits under a bot title.
- **Fail-closed:** the run aborts before any push if the two pins already
  disagree, if the tag would move the pin *backwards* — measured against the
  newest tag in flight, so a delayed dispatch cannot drag an open sync PR back
  either; only a manual run may downgrade, as the recovery path off a bad
  release — if `task sync:skills` writes a path outside the manifests,
  provenance, and managed skills, or if `task verify:skills:offline`,
  `task security:secrets`, `task verify:skills`, or `task verify` fails.
  gitleaks runs *before* the push, not just on the PR: this step vendors files
  from another repository, and a pushed secret needs rotating whether or not
  the PR ever merges.
- **One rolling PR:** a deterministic `bot/sync-harmon-devkit` branch, rebuilt
  from `main` every run, so a newer release supersedes an open sync PR instead
  of opening a second one. Replaying an event after the PR merged is a no-op;
  replaying it while the PR is open compares trees and leaves the branch alone,
  so the daily schedule never force-pushes an identical commit or re-triggers
  the PR's checks.
- **Recovery:** `workflow_dispatch` with an explicit tag, or locally
  `task sync:devkit-release -- vX.Y.Z`. A sync PR that was closed by hand is
  re-opened from the pushed branch on the next run.
- **Never merges.** Not the sync PR, not either repository's release PR.

Renovate keeps its approval-gated harmon-devkit rule as a passive stale-pin
signal and manual fallback; it cannot vendor the skills itself, and its
Dependency Dashboard approval means it never races this workflow into a
duplicate branch.

The harmon-devkit side of the edge (emitting the dispatch on release) lives in
that repository's `release.yml`.

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

## Runners

Jobs use `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`, so the
`CI_RUNS_ON` repository variable can move CI to different runners without a
commit.

That convenience is also the risk: it is a runtime change with no diff and no
review. **Do not point a public repository at a persistent self-hosted runner.**
Workflows here already refuse to check out fork-controlled code on the trusted
aggregate job, but that contract bounds one specific job — it does not make a
long-lived runner safe for untrusted contributions generally. A fork PR that can
execute anything on a persistent runner can read its filesystem, its
credentials, and whatever the previous job left behind.

Before setting `CI_RUNS_ON` to a self-hosted value, audit every workflow for
`pull_request_target` and for any step that runs code from the PR head. Keep
untrusted-contribution workflows on GitHub-hosted runners.
