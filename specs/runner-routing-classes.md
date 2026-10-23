# Spec: Runner routing classes

- **Status:** Approved
- **Owner:** Evan Harmon
- **Date:** 2026-10-18
- **Related:** [#1725](https://github.com/evanharmon1/harmon-init/issues/1725),
  [routing ADR](../docs/decisions/2026-10-18-route-ci-jobs-by-class.md)

## Problem / Why

One routing variable puts ordinary builds, browser tests, image builds and
secret-holding automation on the same runner pool. Per-job overrides have grown
without a rule for naming them. Consumers need stable classes that explain why
work needs a different runner, independently of the provider supplying it.

## Goal

Define five routing variables and an exhaustive template-job assignment that
workflow rendering and setup reconciliation can implement consistently.

## Non-goals

This change does not render new workflow expressions, reconcile GitHub variables,
choose providers, or change runner infrastructure. Consumer-local workflows such
as omator's `preview.yml`, `deploy.yml` and `demo-seed` are outside the template.

## Requirements

- [ ] Use exactly the five routing variables below. A variable names a class by
  its execution requirement; a provider is never part of its name.
- [ ] Treat each value as a JSON runner label set: a JSON string for one label
  (for example `"ubuntu-latest"`) or a JSON array of labels that must all match
  (for example `["self-hosted","linux","x64","build-pool"]`). The value selects
  placement; a class name does not prescribe a provider.
- [ ] Apply the fallback chains below, including the rendered default for
  default/browser/image-build/multicore and the independent safe fallback for isolated.
- [ ] Run isolated jobs only on a disposable host: the host is destroyed with
  the job. #1728's `setup:github` reconciliation must reject a `self-hosted`
  label case-insensitively and expose the result in the status readout. Labels
  cannot prove host lifetime: the operator must attest that the selected pool
  destroys the host with the job, even when that label is absent.
- [ ] On public repositories, #1728's `setup:github` must create or replace the
  repository-level `CI_RUNS_ON`, `BROWSER_RUNS_ON`, `IMAGE_BUILD_RUNS_ON`,
  `MULTICORE_RUNS_ON` and `ISOLATED_RUNS_ON` values with `"ubuntu-latest"`. All five must shadow inherited
  organization values so no class override routes public work to a persistent host.
- [ ] Keep existing merge-group GitHub-hosted pins and ternaries.
- [ ] Disable shared package caching for secret-holding or deploying jobs using
  the shared setup action (`cache: "false"`); routing alone does not fix cache
  poisoning. `deploy-preview.yml` `deploy` is the deliberate exception described
  below. Codegen and skills-sync now disable the shared cache; no tracked
  violation remains. Do not add cache restoration to API-only isolated jobs.

### Classes and fallback expressions

| Class | Variable | Reason for separate placement | Fallback chain |
|---|---|---|---|
| default | `CI_RUNS_ON` | General build, lint, test and aggregate work without a more specific requirement | `CI_RUNS_ON` → rendered `ci_runs_on_default` |
| browser | `BROWSER_RUNS_ON` | Executes a real browser: Playwright, accessibility or Lighthouse checks | `BROWSER_RUNS_ON` → `CI_RUNS_ON` → rendered `ci_runs_on_default` |
| image-build | `IMAGE_BUILD_RUNS_ON` | Builds Docker/devcontainer images or runs their container smoke/assertion tests | `IMAGE_BUILD_RUNS_ON` → `CI_RUNS_ON` → rendered `ci_runs_on_default` |
| multicore | `MULTICORE_RUNS_ON` | Measured core scaling past the default size at roughly flat per-job cost | `MULTICORE_RUNS_ON` → `CI_RUNS_ON` → rendered `ci_runs_on_default` |
| isolated | `ISOLATED_RUNS_ON` | Holds long-lived secrets, parses attacker-writable bodies, or deploys; sub-minute API-only glue also belongs here | `ISOLATED_RUNS_ON` → `"ubuntu-latest"` only |

The target template expressions are:

```yaml
# default
runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '[[ ci_runs_on_default ]]') }}
# multicore
runs-on: ${{ fromJSON(vars.MULTICORE_RUNS_ON || vars.CI_RUNS_ON || '[[ ci_runs_on_default ]]') }}
# browser
runs-on: ${{ fromJSON(vars.BROWSER_RUNS_ON || vars.CI_RUNS_ON || '[[ ci_runs_on_default ]]') }}
# image-build
runs-on: ${{ fromJSON(vars.IMAGE_BUILD_RUNS_ON || vars.CI_RUNS_ON || '[[ ci_runs_on_default ]]') }}
# isolated — never consult CI_RUNS_ON or the rendered default
runs-on: ${{ fromJSON(vars.ISOLATED_RUNS_ON || '"ubuntu-latest"') }}
```

`ci_runs_on_default` is computed by Copier: `"ubuntu-latest"` for GitHub-hosted
profiles and the configured JSON label list for `ci_runner == 'self-hosted'`.
It is not a sixth routing variable. An unset or empty class variable takes the
next tier; malformed nonempty JSON is a configuration error, not a fallback.
Repository variables override organization variables of the same name before
these expressions select a tier. Environment-scoped routing variables are not
supported because they are unspecified at `runs-on` evaluation; supporting them
is outside #1728's scope.

A job joins multicore only when measurements on one provider show it keeps
scaling past the default size: wall-clock gain at roughly flat cost per job is
the bar. Feeling heavy is not evidence; memory requirements are a separate floor.

If requirements overlap, isolated wins over every class, including multicore.
A job that needs a browser or builds images stays in that class; multicore
applies only to jobs that would otherwise be default. Thus a browser or image-building job that
also holds a long-lived secret must run on a disposable host. A short-lived
`GITHUB_TOKEN` alone does not make ordinary build work isolated. API automation
is isolated by its work, even when it needs only that token. Publishing an
artifact that others later execute does not, by itself, count as deploying in
this spec. Thus `devcontainer-build.yml` `build` stays image-build: it needs a
Docker-capable pool and holds only the ephemeral `GITHUB_TOKEN` with
`packages:write`. `security-audit-fix.yml` `audit` stays default: it holds no
long-lived secret; isolated `publish` turns its patch into a human-reviewed PR.

The case-insensitive label refusal is enforced during #1728's `setup:github`
reconciliation and reported by the status readout, not rechecked at job time.
Later UI or organization edits can invalidate that check. Operators remain
responsible for repository edits and disposable-host attestation;
harmonops/harmon-infra's organization reconciler owns organization-level drift.

### Template job assignment

This table is the single assignment source for the rendering test in #1727.
Workflow names are rendered filenames; inclusion follows the template's existing
Copier conditions. Rows name every job, including the web-app `codegen-guard`
split. Matrix variants inherit their job's class. Pinned placement is an exception to the class expression, not a new class.

| Workflow | Job | Class | Reason / placement exception |
|---|---|---|---|
| `build.yml` | `changes` | default | Fail-closed docs-only classification |
| `build.yml` | `check` | default | Lint and typecheck |
| `build.yml` | `repo-guards` | default | Instruction audit, test suite and skills drift |
| `build.yml` | `devcontainer-permissions` | default | Permission unit check; no container required |
| `build.yml` | `build-test` | multicore | Build and unit tests; measured core scaling past the default size |
| `build.yml` | `e2e` | browser | Playwright; included with Node |
| `build.yml` | `security` | default | Free baseline scanners |
| `build.yml` | `lighthouse` | browser | Lighthouse browser audit (web-astro) |
| `build.yml` | `lighthouse-stale-comment` | isolated | API-only PR-comment glue; docs-only Lighthouse annotation (web-astro) |
| `build.yml` | `render-parity` | default | Compares built output without a browser (web-astro) |
| `build.yml` | `a11y` | browser | Browser accessibility checks (web-app/web-astro) |
| `build.yml` | `verify` | default | Aggregate check |
| `build.yml` | `codegen-guard` | isolated | Generated code (web-app); `CONVEX_DEPLOY_KEY`, setup `cache: "false"` |
| `devcontainer-build.yml` | `devcontainer-changes` | default | Change detection; preserve `merge_group` → `ubuntu-latest` ternary |
| `devcontainer-build.yml` | `build` | image-build | Builds/publishes devcontainer images |
| `devcontainer-build.yml` | `build-merge-group` | image-build | Preserve hard-coded `ubuntu-latest` on merge groups |
| `devcontainer-build.yml` | `devcontainer-assert-bot` | image-build | Image smoke/assertion |
| `devcontainer-build.yml` | `devcontainer-assert-agent` | image-build | Image smoke/assertion |
| `devcontainer-build.yml` | `devcontainer-verify` | default | Aggregate; preserve `merge_group` → `ubuntu-latest` ternary |
| `terraform.yml` | `terraform-changes` | default | Change detection |
| `terraform.yml` | `terraform-validate` | default | Offline validation |
| `terraform.yml` | `terraform-plan-apply` | isolated | R2 credentials and Terraform Cloudflare tokens; infrastructure deployment |
| `terraform.yml` | `terraform-verify` | default | Aggregate check |
| `deploy-preview.yml` | `changes` | default | Fail-closed docs-only classification |
| `deploy-preview.yml` | `preflight` | isolated | `CLOUDFLARE_API_TOKEN` |
| `deploy-preview.yml` | `deploy` | isolated | Preview deployment and `CLOUDFLARE_API_TOKEN`; deliberate shared-cache exception below |
| `deploy-preview.yml` | `preview-stale-comment` | isolated | API-only PR-comment glue; docs-only preview annotation |
| `release.yml` | `release-please` | isolated | API automation and `CI_APP_PRIVATE_KEY` |
| `release.yml` | `deploy-production` | isolated | Production deployment and `CLOUDFLARE_API_TOKEN` |
| `sync-harmon-devkit.yml` | `sync` | isolated | `CI_APP_PRIVATE_KEY`; shared cache disabled for Node profiles |
| `security-audit-fix.yml` | `audit` | default | Dependency audit without the App private key |
| `security-audit-fix.yml` | `publish` | isolated | `CI_APP_PRIVATE_KEY` |
| `snyk-scheduled.yml` | `scan` | isolated | `SNYK_TOKEN`; setup `cache: "false"` |
| `claude-plan.yml` | `plan` | isolated | OAuth/App secrets and attacker-writable request bodies |
| `claude-implement.yml` | `implement` | isolated | OAuth/App secrets and attacker-writable request bodies |
| `claude-review.yml` | `review` | isolated | OAuth/App secrets and attacker-writable request bodies |
| `claim-release.yml` | `on-issue-closed` | isolated | Parses attacker-writable claim bodies |
| `claim-release.yml` | `on-pr-closed-unmerged` | isolated | Parses attacker-writable claim bodies |
| `claim-release.yml` | `on-pr-merged` | isolated | Parses attacker-writable claim bodies |
| `project-automation.yml` | `sync-status` | isolated | API automation and `CI_APP_PRIVATE_KEY` |
| `project-automation.yml` | `project-automation-verify` | default | Aggregate check |
| `classification-event.yml` | `reconcile` | isolated | Reusable-workflow caller; no `runs-on`, inherits callee placement |
| `classification-reconcile.yml` | `reconcile` | isolated | API-only classification automation |
| `closing-keywords.yml` | `closing-keywords` | isolated | API automation parsing issue/PR bodies |
| `close-milestone-on-release.yml` | `close-milestone` | isolated | API-only milestone automation |
| `release-content-guard.yml` | `guard` | isolated | Parses attacker-writable PR title/body |
| `codeql.yml` | `analyze` | default | CodeQL analysis |
| `codeql.yml` | `codeql-verify` | default | Aggregate check |

### Root-only job assignment

These jobs exist only in harmon-init. #1727 renders the template assignment above
and updates these root-only jobs to match the same class definitions.

| Workflow | Job | Class | Reason |
|---|---|---|---|
| `publish-harmon-devcontainer.yml` | `candidate` | image-build | Builds and smoke-tests native/arm64 images |
| `publish-harmon-devcontainer.yml` | `candidate-verify` | default | Aggregate check |
| `publish-harmon-devcontainer.yml` | `publish` | image-build | Builds/publishes images with ephemeral `GITHUB_TOKEN` `packages:write` |
| `publish-harmon-devcontainer.yml` | `prepare-pin` | default | Validates image metadata and prepares/tests a pin change without write credentials; no image build or smoke |
| `publish-harmon-devcontainer.yml` | `sync-pin` | isolated | Publishes the pin PR with `CI_APP_PRIVATE_KEY` |
| `remote-bootstrap.yml` | `bootstrap` | image-build | Stock-container toolchain tests require a Docker-capable pool; no long-lived secret |
| `build.yml` | `template-test` | default | Renders and validates Copier profiles |

### Shared package-cache contract and existing exceptions

`deploy-preview.yml` `deploy` deliberately keeps the shared cache even though it
holds preview credentials: it builds the PR's own code, so poisoning that cache
grants nothing the PR does not already have. This exception is documented in
`template/.github/workflows/[% if use_release_please %]release.yml[% endif %].jinja:108-112`.
Production `deploy-production` does not share that trust boundary and requires
setup `cache: "false"`.

The web-app `codegen-guard` job holds `CONVEX_DEPLOY_KEY` on the isolated
class with setup `cache: "false"`. The default-class `check` job reads the
committed tree without that secret.

`sync-harmon-devkit.yml` `sync` mints a `contents:write` App token and disables
the shared pnpm cache with setup `cache: "false"` when `use_node` is true.
The violation is corrected by #1731; no tracked shared-cache violation remains.
Non-Node profiles have no setup cache input and render no cache override.

## Acceptance criteria (Given / When / Then)

### Scenario: Existing default routing survives the class rollout

- **Given** no new class variables and a GitHub-hosted or self-hosted Copier profile
- **When** default, browser, image-build or multicore placement is evaluated
- **Then** it uses `CI_RUNS_ON`, or the profile's rendered default if unset,
  except for the preserved merge-group pins.

### Scenario: An unset isolated variable cannot reach the homelab default

- **Given** `CI_RUNS_ON` or the rendered default names a homelab label set
- **When** `ISOLATED_RUNS_ON` is unset or empty
- **Then** isolated resolves to `"ubuntu-latest"` and never consults either default.

### Scenario: Explicit class placement and host safety

- **Given** a repository sets a browser, image-build or multicore variable
- **When** a matching job runs
- **Then** its class variable takes precedence over `CI_RUNS_ON`.
- **Given** an isolated label equals `self-hosted` in any letter case
- **When** #1728's `setup:github` reconciles routing configuration
- **Then** it refuses the value and the status readout reports the refusal.
- **Given** the label check passes
- **When** an operator selects the isolated pool
- **Then** the operator must attest that the host is destroyed with the job;
  the label check cannot prove that property or reject every persistent pool.
  A later UI or organization edit is not rechecked at job time.

### Scenario: Public class overrides cannot inherit persistent organization pools

- **Given** a public repository with missing or noncanonical routing variables,
  including inherited organization class overrides
- **When** #1728's `setup:github` reconciles the repository
- **Then** it creates or replaces all five repository-level values with
  `"ubuntu-latest"`, shadowing every organization routing value.

### Scenario: Exhaustive workflow rendering

- **Given** every workflow option is rendered across the template test profiles
- **When** #1727's routing test enumerates jobs and their `runs-on` expressions
- **Then** every job matches this table, no unknown routing variable occurs,
  reusable callers inherit the callee, and merge-group pins remain intact.
- **Given** the #1729 codegen split is rendered for web-app
- **When** its setup action is inspected
- **Then** `codegen-guard` is isolated with `cache: "false"` and `check` no longer
  holds the codegen secret.

## Open questions

None for the naming, fallback or class-assignment contract. Provider selection
belongs to harmonops/harmon-infra#592 and the consumer pilots.

## Notes

Inventory baseline: `9e4e368a1eac2133e6cf3b5267b31ede7fbc185c`.
Issue #1727 renders routing and tests this table; #1728 reconciles variables;
issue #1729 splits codegen; #1730's docs-only path still runs check, repo-guards and
security. These later implementations must not treat this specification's
requirements as already implemented by the documentation PR.
