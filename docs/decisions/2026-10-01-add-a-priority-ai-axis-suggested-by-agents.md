# Add a Priority (AI) axis, suggested by agents

Date: 2026-10-01

## Status

Accepted — maintainer decision of 2026-10-01, recorded on
[#1478](https://github.com/evanharmon1/harmon-init/issues/1478), part of epic
[#1444](https://github.com/evanharmon1/harmon-init/issues/1444).
Amends [ADR 2026-09-30 (issue classification)](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D2 (the axes and their scales) by adding one axis, and D3 (who sets them) by
adding one agent-writable priority beside the human-only Priority. Everything
else in that record stands, including D7's agent queue; how the views apply
this record's rule is #1451's.

## Context

[ADR 2026-09-30 (issue classification)](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D2 and D3 make Priority a human-only axis (`urgent`, `high`, `medium`, `low`):
an issue field on organization repositories and a `priority:*` label on
personal-account repositories, which no agent sets. That leaves no place for
the ranking an agent *can* contribute:

- Triage knows the Impact, Risk, and Complexity it has just set.
- A Codex, Gemini, or Claude review that files a follow-up issue knows the
  finding's badge (P0–P3), and loses it the moment the issue is created.
- A bug report carries a severity that nobody records.

## Decision

### D1 — A second priority axis, Priority (AI)

Priority (AI) has the values `p0`, `p1`, `p2`, `p3`, and `p4`. An agent or a
human writes it as the AI's *suggested* priority, from what the writer knows at
the time. It is stored the way Priority is stored: a single-select issue field
named `Priority (AI)` on organization repositories, and a `priority-ai:<value>`
label family on personal-account repositories. This adds a row to the axis table
in the 2026-09-30 record's D2:

| Axis | Scale | Who sets | Required for "triaged" |
|---|---|---|---|
| Priority (AI) | p0, p1, p2, p3, p4 | AI or human | no; advisory |

### D2 — The human Priority overrides it

The **effective priority** of an issue is Priority when it is set, and Priority
(AI) otherwise. Priority stays human-only and never required, so the 2026-09-30
record's D3 is unchanged for it; the override never clears the AI value, so
both stay stored. Priority (AI) is advisory: it arms nothing, and no gate,
claim, or workflow reads it as authorization.

### D3 — For a bug it reads as severity

For a bug, Priority (AI) is how bad the defect is and how important it is to
fix before merging or deploying:

| Value | Reading |
|---|---|
| `p0` | blocks a merge or deploy |
| `p1` | a real defect, or a must-do; fix next |
| `p2` | worth fixing, not blocking |
| `p3` | cosmetic or informational |
| `p4` | negligible |

The registry's one-line descriptions carry the same ladder for work that is not
a bug.

### D4 — A finding filed as an issue carries its adjudicated badge

When a review finding (Codex, Gemini, Claude, or a local challenge or review
round) is filed as follow-up work, the new issue is created with Priority (AI)
set from the **adjudicated** severity: P0 to `p0`, P1 to `p1`, P2 to `p2`, and
P3 to `p3`. A reviewer's label is a hypothesis and the adjudicated severity is
the verdict (`AGENTS.md` § "Severity gating"), so the mapping reads the
adjudicated one. Nothing from a review maps to `p4`; it is for work the AI
judges negligible outside a review.

### D5 — The registry family never becomes a triage axis

The label registry gains a `priority-ai` family: exclusive, provisioned, axis
`meta`, writers `human` and `agent`. Axis `meta` keeps it out of the classification
families, so it is never a required axis for "triaged" (2026-09-30 D6), and its
notes state that it is the AI's suggestion, that the human `priority` family
overrides it, and that it arms nothing. `scripts/test-label-registry.sh` pins
the family in both layers.

## Declined alternatives

- **Letting agents write Priority.** Priority is the human's ranking
  (2026-09-30 D2 and D3), and the agent queue reads it (2026-09-30 D7). An agent
  writing it would leave no way to tell the human's ranking from an agent's own
  write, so the AI's suggestion gets its own axis instead.
- **Reusing the Priority scale for the AI axis.** A distinct `p0`–`p4` scale
  keeps the two axes from being mistaken for each other in a view or a label
  list, and `p0`–`p3` line up with the review badges (P0–P3) that D4 carries
  across, which `urgent`, `high`, `medium`, and `low` do not.
- **Mapping a review's P3 to `p4`.** `p3` is already "cosmetic or
  informational", which is what a P3 badge means, so a review never produces
  `p4`.
- **Making Priority (AI) a required axis.** It is advisory and never required,
  so it is a `meta` family and "triaged" is unchanged.
- **Letting it arm or order anything on its own.** It arms nothing. Its use in
  the Agent queue and Needs review views is a rule those views apply, not
  something this record gives it by existing.
- **A separate Severity axis for bugs.** For a bug, Priority (AI) already
  reads as severity (D3), so a second field would hold the same answer twice.

## Consequences

- The AI's ranking has a place, and a review finding keeps its adjudicated
  badge as a durable field instead of losing it at filing.
- There are two priority-shaped axes, so every reader that ranks by priority
  applies the effective-priority rule (D2). The Agent queue and Needs review
  views are [#1451](https://github.com/evanharmon1/harmon-init/issues/1451)'s;
  this record fixes the rule and does not redefine D7's queue condition.
- Each personal-account repository gains five provisioned labels
  (`priority-ai:p0` to `priority-ai:p4`). Provisioning them on live
  repositories is a human step on collector
  [#1464](https://github.com/evanharmon1/harmon-init/issues/1464); this change
  defines the family and writes to no live repository.
- The glossary gains a "Priority (AI)" entry, and the "Priority" entry gains a
  cross-reference to it.
- The remaining work is routed to the issues that own it:
  the organization `Priority (AI)` issue field
  ([#1448](https://github.com/evanharmon1/harmon-init/issues/1448)), the rubric
  section
  ([harmon-devkit#1247](https://github.com/evanharmon1/harmon-devkit/issues/1247)),
  the effective-priority rule in the Agent queue and Needs review views
  (#1451), triage suggesting it
  ([harmon-devkit#1250](https://github.com/evanharmon1/harmon-devkit/issues/1250)),
  and the review-finding filing path, a harmon-devkit issue on the integrate
  and review skills that D4 requires.
