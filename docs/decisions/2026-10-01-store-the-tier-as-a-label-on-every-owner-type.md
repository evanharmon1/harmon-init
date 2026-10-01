# Store the Tier as a label on every owner type

Date: 2026-10-01

## Status

Accepted — maintainer decision of 2026-10-01, recorded on
[#1444](https://github.com/evanharmon1/harmon-init/issues/1444#issuecomment-5925031249).
Amends [ADR 2026-09-30 (issue classification)](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D2 for the Tier axis only.

## Context

[ADR 2026-09-30 (issue classification)](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D2 stored the Tier as an issue field on organization repositories and as a
label on personal-account repositories. The maintainer decided on 2026-10-01
that the Tier is a label on every owner type.

## Decision

The Tier is stored as the `tier:<value>` label (`local`, `economy`, `standard`,
`frontier`, `apex`) on every owner type, organization and personal-account
repositories alike, and is never an organization issue field. An issue carries
at most one tier value; `tier:pinned` is the separate pin marker beside it.

The other axes keep their D2 storage: Impact, Risk, Complexity, Priority, and
Effort are issue fields on organization repositories and labels on
personal-account repositories. The pin is unchanged: a human sets the Tier
label and adds `tier:pinned`. Where the 2026-09-30 record's pin rationale
(Declined alternatives, "A separate override field") says "the Tier field",
read "the Tier label". Everything else in that record, including the
derivation (D4) and the resolution order (D5), stands.

## Consequences

- One storage path for the Tier on both owner types, so readers, the
  reconciler, and the writers (triage, track-work, breakdown) treat the label
  the same way everywhere.
- Organizations get no `Tier` issue field; the organization-fields work
  ([#1448](https://github.com/evanharmon1/harmon-init/issues/1448)) does not
  create one.
- Label writes on private organization repositories emit `labeled` events, so
  the reconciler and any per-repository workflow must keep job-level filters
  ([#1450](https://github.com/evanharmon1/harmon-init/issues/1450)).
