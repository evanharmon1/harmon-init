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
   `@claude` commands naming `plan`, `implement`, or `review` run behind
   sender checks. Label-event triggers are retired. A run acquires and always releases the relevant live
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
   **Amended 2026-08-16 ([ADR 0006](0006-method-and-tier-axes.md)):**
   suggestions are now human- **or agent-**authored; `suggest:*` stays
   `family[:model]` (a vendor preference), `tier:*` is the human-decided policy
   layer of the model axis, and `suggest:tier:<value>` is reserved, not built.
   The claim record gains `harness:`/`model:`/`session:` fields
   (harmon-devkit#450).
7. **D7 — Foreman selectors name harness adapters.** `foreman:<adapter>` selects
   executable machinery. The registry maps that adapter to a harness and states
   who selects the model. The family and harness axes are intentionally distinct.
8. **D8 — Family slugs name vendor intelligence, never the harness product.**
   OpenAI's family slug is `gpt`; model segments, such as `sol` or `luna`, live
   below that stable family slug, and `codex-cli` is the *harness* that runs
   it. Microsoft AI's family slug is `mai`; `copilot-cli` is a *harness* — a
   broker (D9 amendment below) whose picker defaults to `mai` but can route
   to other families. **Amended 2026-08-10**: the family slug was originally
   `codex`, and `copilot` was originally recorded as a family with no models.
   Both were the exact product-vs-family mistake D9 already fixed for
   `codex-cli` itself — Codex and Copilot are products/harnesses, GPT and MAI
   are the vendor intelligence underneath them. At the time of this 2026-08-10
   amendment, the operational guidance was a one-time human rename rather than
   an automatic rewrite: existing `suggest:codex*`/`claim:codex*` and
   `suggest:copilot*`/`claim:copilot*` labels are not deleted or auto-renamed
   (`setup-github-labels` is additive, same as the `agent:*` → `claim:*`
   cutover D4 already established). **Amended 2026-08-25 — operational
   mechanism:** that no-automatic-write decision remains, but the documented
   human path is now the guarded maintenance flow in `docs/CHECKLIST.md` and
   `docs/project-management.md`: the read-only report inventories live labels,
   and `--prune` with repeatable `--migrate OLD=NEW` validates live registry
   destinations, moves fixed-family associations across issues, PRs, and
   Discussions, and deletes only a fresh zero-association source. It must be run in a quiescent
   maintenance window. GitHub provides no transaction or compare-and-swap
   between the final read and the following edit/DELETE, so a concurrent writer
   can still race the request; the command cannot undo that mutation.
   Broker-derived Copilot labels are excluded from bulk migration: suggestions
   are re-expressed or dropped, while claims are handled per issue, PR, or
   Discussion from the actual claim/session record; `mai` is only the broker default, never a
   guessed destination.
9. **D9 — Harness slugs follow product, collision, and endpoint-variant
   rules.** Product names are lowercase slugs (`antigravity`, `opencode`,
   `pi`). A product qualifier avoids a family collision (`claude-code`,
   `codex-cli`, `copilot-cli`, `qwen-code`). Provider-rewired variants use
   `<harness>-<family>`, including `claude-code-deepseek`, `claude-code-glm`,
   `claude-code-kimi`, `claude-code-minimax`, and `claude-code-qwen`.
   MiniMax's family is `minimax`; `minimax` is never a harness slug. A venue
   is not a harness, so the GitHub Action is `claude-code-action`, not
   `gh-action`. **Amended 2026-08-10 — sanction the `-local` endpoint-variant
   suffix**: a provider-rewired harness may append `-local` to mark a variant
   that talks to a local endpoint instead of the family's hosted one, while
   staying fixed to the *same* family — `claude-code-qwen-local` is family
   `qwen`, not a separate `qwen-local` family. The suffix names an endpoint,
   not intelligence, so it never appears in a family slug or as a
   `family_constraint.family` value; the next local-lane wrapper reuses this
   rule rather than improvising a new one.
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
12. **D12 — `family_constraint` has an explicit `broker` kind (added
    2026-08-10).** A harness whose model picker routes across families
    (`opencode`, `pi`, `goose`, `cline`, `copilot-cli`) declares
    `{ "kind": "broker" }`, optionally with a `default_family` naming which
    family it picks absent other input (`copilot-cli`'s is `mai`). This
    replaces overloading the `none` kind — schema v1's "unconstrained" escape
    hatch — for the same meaning: a `none` constraint could not name a
    default, so `copilot-cli` could only be recorded `runner-config`-owned
    with no way to say *which* family it defaults to, which undersold what
    the picker actually does. `kind: "broker"` is a distinct, self-describing
    value rather than "`fixed` with nothing fixed", and `default_family`,
    when present, is validated against the family roster like any other
    family reference. Schema `schema_version` moved to `2` for the shape
    change; the validator and its mutation tests cover the new kind
    (rejecting a plain `family` on a broker, an unknown `default_family`, and
    a `default_family` on a `fixed` constraint).
13. **D13 — `Model selected by` renders as one definition list, not a
    per-row sentence (added 2026-08-10).** The harness table's last column
    used to repeat a full sentence per row for what is structurally a
    4-value enum (`agent-registry.schema.json`'s `modelResolution.owner`:
    `runner-config`, `workflow-config`, `provider-wrapper`,
    `harness-runtime`). `agent-registry-labels.mjs`'s `docs-tables` mode now
    renders each harness's bare `owner` code in the column and prints the
    four definitions once, above the table. The registry's per-harness
    `model_resolution.details` field is unchanged and still schema-validated
    (tooling and future prose may still want it) — it is simply not spliced
    into the generated table anymore, since every occurrence was restating
    one of the four fixed sentences with a harness name attached.
14. **D14 — Model-slug conventions (recorded 2026-08-10).** Family and tier
    slugs are lowercase words. A version that gets its own slug is
    hyphenated with a dotted display name (slug `5-2`, display `5.2`) —
    dots are declined *in slugs* because registry slugs feed
    `suggest:`/`claim:` label segments, and a `.` there would either break
    label-name syntax or need escaping every consumer would have to
    remember. A model slug names either a durable capability *tier* the
    vendor itself supports across versions (`claude`'s `opus`/`sonnet`/
    `haiku`/`fable`, `gpt`'s `sol`/`terra`/`luna`) or a *version* where the
    vendor does not offer that abstraction (`glm`'s `5-2`, `kimi`'s `k3`).
    A provider-rewired local-endpoint variant's harness slug may append
    `-local` per the D9 amendment above; it stays a harness-slug suffix, and
    is never folded into a model or family slug.

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
- A family rename (D8 amendment) is additive at the registry/label-provisioning
  level — no GitHub write runs automatically — so a repo seeded before
  2026-08-10 keeps its pre-refresh `suggest:codex*`/`claim:codex*`/
  `suggest:copilot*`/`claim:copilot*` labels until an operator runs the
  amended guarded maintenance flow (docs/CHECKLIST.md and
  docs/project-management.md). Fixed mappings may use bulk association
  migration; Copilot broker labels require the per-record rules above. The
  flow's quiescent precondition and non-atomic API boundary remain operational
  requirements, not guarantees supplied by the registry. `task
  test:registry-drift` only binds this repository's own provisioning script and
  wrappers to the current registry; it has no visibility into any other
  repository's live label set and cannot detect that a rename is owed.
