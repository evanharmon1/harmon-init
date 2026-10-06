# File unclassified issues with needs-triage and walk organizations standalone

Date: 2026-10-05

## Status

Accepted

Amends [ADR 2026-09-30 (issue classification)](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D4, for the organization-wide reconcile walk (as D4 was already amended by
[#1450](https://github.com/evanharmon1/harmon-init/issues/1450)), and D6, for the filing rule
on `needs-triage`. The passages of that record this one qualifies stay as written there.

## Context

Two statements in ADR 2026-09-30 stopped matching what ships.

D4 described the organization-level daily walk as one reusable workflow called from each
organization's `.github` repository, and the #1450 amendment described it as an opt-in caller
holding an App installation token. The maintainer decided on 2026-10-04, recorded on
[#1500](https://github.com/evanharmon1/harmon-init/issues/1500), that it is neither.
[The CI/CD architecture](../architecture/ci-cd.md#issue-classification-reconciler)
("Organization-wide walk") describes what ships.

D6 said `needs-triage` is derived from the required axes and never set by hand. The issue
forms already apply it at filing, and `label-registry.json` lists humans, agents and the forms
among its writers. The reconciler's per-issue event job also starts only when the sender is
not a `Bot` and is not listed in `CLASSIFICATION_AGENT_LOGINS`, so an issue an agent files
unclassified is not reached until the next scheduled walk, which is monthly on an
organization repository.

## Decision

### D1: the organization-wide walk is a standalone organization workflow

An organization that wants a daily walk of every repository it owns adds one ordinary
workflow to a private repository of the organization. Its one job mints the CI GitHub App
installation token and runs the reconciler script in the same job. It stays opt-in
([#1463](https://github.com/evanharmon1/harmon-init/issues/1463)).

It is not a "caller", and it is not a reusable workflow called from each organization's
`.github` repository. A job that calls a reusable workflow runs no steps, so a token minted
beside such a call cannot reach the called workflow.

### D2: the filing rule for `needs-triage`

Whoever files an issue that is not fully classified adds `needs-triage` at filing: the issue
forms, people and agents alike. After filing the label is derived from the required axes and
is never cleared by hand. The reconciler maintains it, and so do the skills once the pinned
skills carry the writers of Risk and Complexity. The rule for contributors is in
[conventions](../conventions.md#issues).

## Declined alternatives

- **Rewriting the 2026-09-30 passages.** Decision records are append-only: the index says
  "supersede, don't edit". D4's walk and D6's "never set by hand" stay in that record as
  history, and its Status points here.
- **A reusable-workflow caller for the organization walk.** Rejected for the token reason
  in D1.
- **Leaving `needs-triage` entirely to the reconciler.** Rejected: the event job skips agent
  senders and the organization schedule is monthly, so an unclassified agent-filed issue
  would stay out of the Triage view until the next walk.
- **Forbidding people and the forms from adding it at filing.** Rejected: the filer knows at
  filing that the issue is unclassified, and the label is only wrong when it is left in place
  after classification, which the derivation corrects.

## Consequences

- `docs/conventions.md` states the filing rule under "Issues", and the glossary `triaged`
  entry, the project-management "Triaged" paragraph and the registry's `needs-triage` notes
  say the same.
- A person clearing `needs-triage` by hand stays unsupported: the reconciler would put it
  back while an axis is missing.
- Organization repositories reach the walk through the standalone workflow only; a call from
  another repository's reusable workflow is not supported.
