# 1. Record architecture decisions

Date: TODO

## Status

Accepted

## Context

We need to record the architectural decisions made on this project — the ones
that are significant, hard to reverse, or surprising to a newcomer (including an
AI agent). Without a durable record, the *why* behind a choice is lost and gets
relitigated.

## Decision

We will use Architecture Decision Records (ADRs), as
[described by Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

- One ADR per decision, stored in `docs/decisions/`.
- Numbered sequentially and zero-padded: `0001-...`, `0002-...`.
  *Amended 2026-08-29 — see Amendments below: new records are named
  `YYYY-MM-DD-<kebab-title>.md` by filing date; this bullet is kept as the
  original decision.*
- Each ADR has: Status (Proposed / Accepted / Deprecated / Superseded), Context,
  Decision, and Consequences. Keep them short. *Amended 2026-08-29 — see
  Amendments below: `Rejected` joins the status vocabulary; this bullet is
  kept as the original decision.*
- ADRs are immutable once accepted; to change a decision, add a new ADR that
  supersedes the old one (and update the old one's Status).

## Consequences

- The reasoning behind decisions is preserved and discoverable.
- Reviewers and agents can read the trail instead of guessing intent.
- Copy this file as the template for the next ADR.

## Amendments

- 2026-08-29 (harmon-init#1112): naming switched from sequential zero-padded
  numbers (`0001-...`) to `YYYY-MM-DD-<kebab-title>.md` — the date the record
  was filed, fixed at creation; a `Proposed` record keeps its name when
  accepted or rejected, and the Status line carries the outcome. Filing a
  record then needs no "look up the last number" step, and two branches
  adding records never collide on the next one. Records already numbered
  keep their names — renaming would break inbound links — so both forms are
  valid. The Decision bullet above is left as written, per this record's own
  supersede-don't-edit rule, and `Rejected` joins the status vocabulary so a
  `Proposed` record that is turned down can say so without renaming.
