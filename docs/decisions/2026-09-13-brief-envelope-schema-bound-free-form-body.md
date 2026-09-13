# Brief envelope — schema-bound envelope, free-form body

Date: 2026-09-13

## Status

Accepted (2026-09-13) — maintainer decision recorded on
[harmon-devkit#910](https://github.com/evanharmon1/harmon-devkit/issues/910).

**Amends [ADR 0009](0009-dev-flow-v2-orchestrator-and-results.md) D2** — D2
where it states briefs are free-form: under this record the orchestrator →
agent brief is a validated envelope plus an opaque body, not unstructured
prose. The original rationale — nothing downstream parses the brief — is now
half false: the monitor, the readiness gate, `dev-flow-exit.sh`, and retro
all read specific brief facts, and every brief-drift incident in the
slate-#2 run was a machine-read fact that existed only as prose. ADR 0009
carries the reciprocal notice.

## Context

[ADR 0009](0009-dev-flow-v2-orchestrator-and-results.md) D2 decided that
orchestrator → agent briefs are free-form prose and only results are
schema-bound. The rationale: a brief carries judgement and context downward,
which a schema flattens, and nothing downstream parses it.

That last clause is no longer true. The monitor, the readiness gate,
`dev-flow-exit.sh`, and the retro all read specific brief facts — run
identity, policy disclosure, file-scope fence, terminal sentinels — and when
those facts exist only as prose, they drift. Three premature promotions in
the slate-#2 run (harmon-devkit#926 entries 12 and 14) occurred with the
governing rule present as prose in the brief: the machine-read field was
there, but unvalidated, and the gate missed it.

Meanwhile harmon-devkit#875's orchestrator skill (`orchestrator/SKILL.md`
§ Lane briefs, `assets/lane-brief.md`) already mandates six of those fields
in prose, and slate #2's briefs were generated from eight parameters plus a
free-form scope file — the parameters are exactly the envelope, and the
scope is the body. The structure already exists; only the validation does
not.

## Decision

A brief is a validated **envelope** plus an opaque **body**. Five design
constraints make the guarantee structural:

1. **The envelope validates only what a machine reads:** active run identity
   (run id, branch, generation, active-state path, record directory, policy
   projection), file-scope fence, policy disclosure (rigor + source, rounds,
   breadth, strategy + source, role tiers, operator pins), wall-clock
   deadline, terminal sentinels. These are the fields the monitor, readiness
   gate, `dev-flow-exit.sh`, and retro already parse.
2. **The body is opaque to validation** — one free-form markdown field, any
   length, any structure; no required headings, no content lint. The
   validator cannot reject a brief for anything the body says or omits. New
   guidance, rulings, ordering advice, caveats, and prior-art notes go in
   the body with no schema change.
3. **The envelope is closed; the body is open.** Adding an envelope field
   requires a schema change — a deliberate brake on accretion. The body has
   no brake.
4. **Envelope fields are facts, not instructions** — numbers, paths, lists,
   strings the orchestrator looks up, never sentences it composes. A proposed
   field that needs judgement to fill belongs in the body.
5. **Drift test** — if a brief author ever shortens or omits an instruction
   to satisfy the schema, the schema is wrong. This sentence is the standing
   test for any future proposal to move content from the body into the
   envelope.

**Maintainer's constraint (verbatim):** the schema must not limit the LLM's
ability to give good instructions; it must not constrain good ideas and
instructions from the orchestrator.

**Not** keeping briefs fully free-form: the machine-read facts have already
caused gate failures as prose — three premature promotions with the governing
rule present but unvalidated, and every brief-drift incident in the slate-#2
run was a machine-read field that existed only as prose. The D2 rationale
("nothing downstream parses it") was a factual premise, not a value
judgement, and it is now false.

**Not** making briefs fully schema-bound: a schema flattens judgement and
context, exactly D2's original argument, which still holds for the body. The
body is where the orchestrator explains *why this run matters*, how prior
rounds went, what the change is for — prose that no script should parse,
that varies by run, and that the orchestrator must be free to write without
constraint.

## Consequences

- The spec (`harmon-devkit/specs/dev-flow-v2.md` "Briefs are free-form;
  results are schema-bound") and the orchestrator/implementer skill contracts
  change together in one harmon-devkit PR
  ([harmon-devkit#939](https://github.com/evanharmon1/harmon-devkit/issues/939)).
- The envelope schema lands in harmon-devkit `ai/schemas/` beside the result
  envelope.
- Foreman may validate a dispatch's policy disclosure from the envelope
  instead of prose.
- Nothing in this repository's template changes until that schema ships.
