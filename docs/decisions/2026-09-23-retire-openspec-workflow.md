# Retire the OpenSpec workflow

Date: 2026-09-23

## Status

Accepted

Supersedes [Adopt OpenSpec for spec-driven changes at the repo root](2026-09-01-adopt-openspec.md).

## Context

OpenSpec did not become part of regular harmon-init development after its
root-only adoption. Its generated integrations, CLI pin, validation tasks, and
proposal tree nevertheless created recurring maintenance and duplicated the
repository's established issue, ADR, and plain `specs/` surfaces. The decision
to remove it is tracked in
[harmon-init#1361](https://github.com/evanharmon1/harmon-init/issues/1361).

## Decision

Remove the OpenSpec CLI, generated harness integrations, task and CI wiring,
and `openspec/` tree. Return change planning to GitHub issues, ADRs, and plain
files under `specs/`; unfinished work that remains valuable is tracked on its
canonical issue before its OpenSpec artifact is removed. In particular,
[harmon-init#1091](https://github.com/evanharmon1/harmon-init/issues/1091)
retains the progress-bookkeeping work and the retirement note records the
OpenSpec draft's unresolved design obligations.

**Not:** remove the vendored Dev Loop skills managed by the skills sync.
Only OpenSpec-generated entries are retired.

**Not:** delete the superseded adoption ADR. It remains in the append-only
decision history and points here.

**Not:** abandon unfinished work merely because its OpenSpec container is
removed. Such work is migrated to or reaffirmed on its canonical issue.

## Consequences

- OpenSpec commands and generated integrations are no longer available in this
  repository.
- The OpenSpec dependency pin and its Renovate discovery annotation disappear.
- Existing issues, ADRs, and `specs/` content remain the planning and decision
  record, without adding another generated workflow to maintain.
