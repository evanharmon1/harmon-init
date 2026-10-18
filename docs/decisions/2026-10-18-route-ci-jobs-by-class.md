# Route CI jobs by execution class

Date: 2026-10-18

## Status

Accepted. Records the maintainer's 2026-10-17 routing decision in
[#1725](https://github.com/evanharmon1/harmon-init/issues/1725).
The [spec](../../specs/runner-routing-classes.md) owns the job-assignment table
and exact expressions; workflow rendering and setup reconciliation follow later.

## Context

One `CI_RUNS_ON` variable sends jobs with different execution requirements to
one pool. Consumers have introduced job-specific overrides, but those names do
not explain when a new override is justified. Provider names would entangle
workflow interfaces with infrastructure choices.

A homelab runner runs on hardware the maintainer owns. Its runner container can
be ephemeral while its host is persistent and mounts the Docker socket. A fresh
container therefore does not isolate long-lived secrets from previous jobs or
from code that can reach the host. The isolation boundary must be the host.

## Decision

Use four variables named by the reason a job needs its placement:

- `CI_RUNS_ON`: default build, lint, test and aggregate work.
- `BROWSER_RUNS_ON`: work executing a real browser.
- `IMAGE_BUILD_RUNS_ON`: Docker/devcontainer builds and their smoke/assertion jobs.
- `ISOLATED_RUNS_ON`: jobs holding long-lived secrets, parsing attacker-writable
  bodies or deploying. Sub-minute API-only glue jobs also use this class.

Each value is a JSON runner label set (a string or an array of matching labels).
A provider may supply the value's runner pool, but is never part of a variable's
name. More than one class may deliberately select the same pool.

Default reads `CI_RUNS_ON`, then the rendered `[[ ci_runs_on_default ]]`.
Browser and image-build read their own variable, then `CI_RUNS_ON`, then that
rendered default. Existing merge-group GitHub-hosted pins remain.

**Isolated never falls back to `CI_RUNS_ON` or to the rendered default.** Its
expression is `fromJSON(vars.ISOLATED_RUNS_ON || '"ubuntu-latest"')` on every
Copier profile. If either default points at a homelab, inheriting it would send
secrets straight back to the persistent host when the isolated variable is
unset. The independent GitHub-hosted fallback closes that path.

**`ISOLATED_RUNS_ON` may never resolve to a value containing the `self-hosted`
label, and its selected host must be destroyed with the job.** GitHub's
`self-hosted` label is broad enough to cover hosted-ephemeral runners as well
as homelab runners; it is not a domain term or evidence of host lifetime. The
label prohibition is deliberately conservative, and a label set without it
still needs evidence of a disposable host. Provider choice and provisioning
are separate work, not implied by these names.

The target shared package-cache rule requires setup `cache: "false"` for
secret-holding/deploying jobs, with one deliberate exception: `deploy-preview.yml`
`deploy` builds the PR's own code, so poisoning its cache grants nothing that PR
does not already have (the rationale in `release.yml.jinja:108-112`). Disposable
placement alone does not prevent restoring attacker-controlled cache contents.
This rule is not yet satisfied everywhere: web-app `lint`'s codegen secret/cache
combination is corrected by #1729; `sync-harmon-devkit.yml` `sync`'s App token
with `contents:write` and shared pnpm cache on `use_node` is corrected by #1731.

## Not

- **One variable.** It cannot keep secrets off the persistent default pool while
  independently placing expensive browser and image work.
- **One variable per job.** It multiplies configuration and makes every new job
  a naming decision. Jobs with the same execution requirement should move together.
- **One variable per provider.** It describes infrastructure instead of the
  reason for placement, couples workflow names to vendor changes, and cannot
  express the disposable-host requirement.
- **An isolated fallback through the default.** It silently removes the safety
  boundary on precisely the private homelab repositories that need it.
- **A disposable runner container as proof of isolation.** A persistent host
  with a mounted Docker socket survives container replacement.

## Consequences

Private repositories whose `CI_RUNS_ON` selects a homelab now spend GitHub Actions
minutes on isolated work when `ISOLATED_RUNS_ON` is unset. Usage can consume their
included allowance and incur charges under their plan. With a $0 Actions budget,
isolated jobs stop starting once included minutes run out rather than incurring
charges. Because `closing-keywords` is both isolated and required, that also
blocks merges. The main minute consumers are `claude-implement.yml` `implement`,
`terraform.yml` `terraform-plan-apply`, and the preview/production deploy jobs.
This cost and availability trade-off is intentional:
configure a verified disposable-host pool explicitly rather than silently using
persistent hardware to save minutes. The fallback introduces no new paid SaaS
account or provider dependency.

The spec is the assignment source; architecture docs explain the contract and
the glossary defines its four terms. Rendering, validation and reconciliation
must implement it in later chunks. The existing web-app codegen/cache violation
is recorded in the spec and is removed by #1729's isolated `codegen-guard` split;
issue #1731 owns the existing skills-sync cache violation.
