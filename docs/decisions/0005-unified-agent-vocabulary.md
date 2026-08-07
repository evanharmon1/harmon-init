# 5. Use one model-centric agent vocabulary and registry

Date: 2026-08-07

## Status

Accepted. Amends ADR 0002's issue-field-versus-label arming decision: Foreman
arming is label-only on every owner type because the label timeline records the
actor and project-field changes do not.

## Context

Agent identity had become several incompatible vocabularies. Project planning
used an `Agent` field, live work used `agent:*` labels, Foreman arming used
`foreman:*` backend names, and wrappers used product or provider names. The
copies drifted independently. In particular, harmon-init provisioned Foreman
selectors for adapters absent from its pinned Foreman release.

The vocabulary also mixed two different questions: which model family should do
the reasoning, and which executable harness should run it. That made a harness
slug such as `qwen-code` look interchangeable with a family slug such as `qwen`,
and left no authoritative answer for where a model is selected.

## Decision

The machine-readable `agent-registry.json`, checked against
`agent-registry.schema.json`, is the source contract for model families,
harnesses, model-selection ownership, and Foreman adapter mappings. Executable
checks and human-facing tables consume or validate against it rather than
maintaining independent rosters.

The following decisions are adopted together:

1. **D1 — Foreman owns the `foreman:*` namespace.** Every label Foreman reads or
   writes, including PR lifecycle outputs, uses that prefix.
2. **D2 — PR delivery is draft-first.** Agents and Foreman keep implementation,
   CI, automated review, and shepherding on a draft PR. Passing the readiness
   gate promotes it for human review. The accurate Foreman output is
   `foreman:ready-for-review`, not `ready-to-merge`; approval remains GitHub's
   native review decision and merging remains human-only.
3. **D3 — Claude Actions are mention-triggered and claim-aware.** The
   `@claude plan|implement|review` commands run behind sender checks. Label-event
   triggers are retired. A run acquires and always releases the relevant live
   claim, including on failure.
4. **D4 — The `Agent` project field is retired.** Advisory routing moves to
   `suggest:*`; live ownership uses `claim:*`. Existing live fields require a
   deliberate migration because setup remains additive-only.
5. **D5 — Completion gets no agent label.** There is no `done:*` or `by:*`
   family. Claim/release comments, PR authorship, and `ai-generated` preserve
   history without leaving a second lifecycle marker to drift.
6. **D6 — Suggestions and claims name model intelligence.** Both accept
   family-level and optional model-level forms:
   `suggest:<family>[:<model>]` and `claim:<family>[:<model>]`. Suggestions are
   human-authored advice; claims are live, agent-authored ownership and are
   released at wrap or shepherd completion. Neither arms automation.
7. **D7 — Foreman selectors name harness adapters.** `foreman:<adapter>` selects
   executable machinery. The registry maps that adapter to a harness and states
   who selects the model. The family and harness axes are intentionally distinct.
8. **D8 — Codex's family slug is `codex`.** Model segments, such as `sol` or
   `luna`, live below that stable family slug.
9. **D9 — Harness slugs follow product and collision rules.** Product names are
   lowercase slugs (`antigravity`, `opencode`, `pi`). A product qualifier avoids
   a family collision (`claude-code`, `codex-cli`, `copilot-cli`, `qwen-code`).
   Provider-rewired variants use `<harness>-<family>`, including
   `claude-code-deepseek`, `claude-code-glm`, `claude-code-kimi`, and
   `claude-code-minimax`. MiniMax's family is `minimax`; `minimax` is never a
   harness slug. A venue is not a harness, so the GitHub Action is
   `claude-code-action`, not `gh-action`.
10. **D10 — Project-management documentation is the human authority.** It must
    explain the label security boundary, the label-versus-field rule, Claude
    workflow behavior, the full label taxonomy, and registry-derived family and
    harness tables. Labels have no per-label permissions; every label-triggered
    automation consumer must verify who applied it. Labels carry multi-valued,
    repo-visible, repo-writable, timeline-attributable data; fields carry
    single-valued planning metadata such as Status, Priority, Size, Product,
    Domain, and Layer.
11. **D11 — The registry has executable teeth.** `task verify` schema-checks its
    structure and semantic relationships. It rejects duplicate family or harness
    slugs, absent model-resolution ownership, inconsistent family constraints,
    model labels on the harness axis, and production-dispatchable adapters without
    a harness mapping. Later drift checks bind provisioning, wrappers, and the
    pinned upstream adapter roster to the same contract.

Foreman's legacy production adapter `claude.sh` maps to harness `claude-code`.
Its `mock.sh` adapter is a hermetic test seam only: it has no harness mapping,
is not production-dispatchable, and must never imply a public `foreman:mock`
label.

## Rejected alternatives

- **Keep the `Agent` field and `agent:*` labels.** They answer advisory routing
  and live ownership with the same vocabulary, fail on personal repositories,
  and provide no actor-attributable arming signal.
- **Name claims after harnesses.** That makes routing depend on whichever CLI is
  installed instead of the model capability or cost class and confuses harness
  aliases with model families.
- **Treat `suggest:*` as Foreman arming.** Suggestions are deliberately advisory;
  using them for dispatch would turn ordinary triage edits into execution.
- **Publish every possible `foreman:*` label.** A selector without a production
  adapter is a false capability and can strand armed work.
- **Document `mock` as a public adapter.** Its only role is hermetic upstream
  testing; exposing it would promise execution machinery that intentionally does
  no production work.
- **Maintain the registry only as a Markdown table.** Tables cannot reject drift
  in CI and would repeat the failure mode this decision resolves.

## Consequences

- Root and generated repositories ship byte-identical registry and schema files,
  plus the same validator and mutation tests.
- Consumers can derive family-level labels eagerly and model-level labels on
  demand without confusing harness slugs for families.
- Every harness row records where model selection occurs, even when the answer is
  runner configuration rather than a label or Foreman.
- Adapter availability is explicit: current production dispatch is the legacy
  `claude` adapter mapped to `claude-code`; `mock` remains visible to checks but
  invisible to provisioning.
- Provisioning, workflow migration, vendored-skill migration, Foreman lifecycle
  changes, and final documentation remain separate rollout units. The registry
  establishes their shared contract without prematurely rewriting each consumer.
