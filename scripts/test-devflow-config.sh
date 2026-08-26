#!/usr/bin/env bash
# test-devflow-config.sh — validate the rigor/strategy execution-policy config.
#
# `.devflow.toml` is the single source of the rigor levels, review-policy
# round caps, budget envelopes, strategy definitions, and model tiers
# (AGENTS.md, "Rigor and strategy are resolved, not stated here"; ADR 0007).
# Nothing at runtime parses it on its own — an agent, or
# scripts/devflow-resolve.py, reads it — so a typo has no natural failure
# mode: it would simply make resolution undefined while every other gate
# stays green. test:dogfood-parity only proves the root and template copies
# are byte-identical, which two identically-broken files also satisfy.
#
# This checks the invariants the prose and ADR 0007 promise, on BOTH copies,
# the cross-file invariants byte-equality cannot see (every level/strategy
# has a provisioned label with a matching description; every role has an
# eligible harness; the AGENTS.md fallback sentence matches [review.standard]),
# and — in a second pass — runs scripts/devflow-resolve.py over a case table
# covering the resolution-order rules themselves.
#
# Root-only by design (no template twin): it guards what harmon-init SHIPS.
# A consumer retuning their own levels is editing their policy, the same way
# they may edit their AGENTS.md, and owes no gate here.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL_REGISTRY_ROOT="label-registry.json"
LABEL_REGISTRY_TEMPLATE="template/label-registry.json"
AGENT_REGISTRY_ROOT="agent-registry.json"
AGENT_REGISTRY_TEMPLATE="template/agent-registry.json"
# The built-in fallback applies when .devflow.toml is ABSENT, so it cannot
# live in that file — it has to be stated in the policy, on both sides of the
# dogfood. That is two prose copies no other gate compares:
# test:dogfood-structure comes closest and deliberately checks headings and
# tasks, not paragraph bodies.
AGENTS_ROOT="AGENTS.md"
AGENTS_TEMPLATE="template/AGENTS.md.jinja"
DEVFLOW_GUIDE="docs/guides/devflow.md"
SCHEMA_ROOT=".devflow.schema.json"
SCHEMA_TEMPLATE="template/.devflow.schema.json"
CONFORMANCE_ROOT=".devflow-conformance-v1.json"
CONFORMANCE_TEMPLATE="template/.devflow-conformance-v1.json"

for f in .devflow.toml template/.devflow.toml "$SCHEMA_ROOT" "$SCHEMA_TEMPLATE" \
    "$CONFORMANCE_ROOT" "$CONFORMANCE_TEMPLATE"; do
    [ -f "$f" ] || {
        echo "FAIL: missing ${f}" >&2
        exit 1
    }
done
[ -f "$DEVFLOW_GUIDE" ] || {
    echo "FAIL: missing ${DEVFLOW_GUIDE} — .devflow.toml's header links to it" >&2
    exit 1
}

python3 - "$LABEL_REGISTRY_ROOT" "$LABEL_REGISTRY_TEMPLATE" \
    "$AGENT_REGISTRY_ROOT" "$AGENT_REGISTRY_TEMPLATE" "$AGENTS_ROOT" "$AGENTS_TEMPLATE" \
    "$DEVFLOW_GUIDE" "$SCHEMA_ROOT" "$SCHEMA_TEMPLATE" .devflow.toml template/.devflow.toml <<'PY'
import json
import math
import re
import sys
import tomllib

(registry_root, registry_template, agent_registry_root, agent_registry_template,
 agents_root, agents_template, devflow_guide, schema_root, schema_template, *config_paths) = sys.argv[1:]

failures = []

# The schema is the portable structural contract; the executable checks below
# enforce its TOML-specific and cross-file clauses. Keep root/template copies
# equal so a generated repository receives the same contract the root dogfoods.
try:
    schema_root_data = json.load(open(schema_root))
    schema_template_data = json.load(open(schema_template))
except (OSError, json.JSONDecodeError) as exc:
    failures.append(f"cannot parse devflow schema JSON: {exc}")
    schema_root_data = schema_template_data = {}
else:
    if schema_root_data != schema_template_data:
        failures.append(".devflow.schema.json differs from template/.devflow.schema.json")
    if schema_root_data.get("properties", {}).get("schema_version", {}).get("const") != 1:
        failures.append(".devflow.schema.json must declare schema_version const 1")
    if schema_root_data.get("additionalProperties") is not False:
        failures.append(".devflow.schema.json must reject unknown top-level keys")
    # The resolver executes the checked-in schema, so a schema edit that
    # silently drops a required nested review cap would otherwise weaken the
    # portable v1 contract while the shipped configuration still passes.
    # Pin the required review-policy shape here as part of the validator's
    # own contract, rather than trusting the current TOML instance to expose
    # every missing schema requirement.
    review_definition = schema_root_data.get("$defs", {}).get("review", {})
    required_review_caps = {"challenge", "review", "shepherd", "min_rounds"}
    if not isinstance(review_definition, dict) or not required_review_caps.issubset(
        set(review_definition.get("required", []))
    ):
        failures.append(
            ".devflow.schema.json must require challenge, review, shepherd, and min_rounds "
            "in $defs.review"
        )
    if review_definition.get("additionalProperties") is not False:
        failures.append(".devflow.schema.json must reject unknown $defs.review keys")

# ── Fixed vocabulary (ADR 0007) ─────────────────────────────────────────────
SUPPORTED_SCHEMA_VERSION = 1
RIGOR_LEVELS = {"trivial", "minimal", "light", "standard", "thorough", "deep"}
REVIEW_POLICIES = {"none", "driveby", "light", "standard", "thorough", "deep"}
BUDGET_PROFILES = {"trivial", "light", "standard", "thorough", "deep"}
STRATEGIES = {"oneshot", "plan", "plan-approved", "orchestrate", "council", "human-led"}

RIGOR_REQUIRED_KEYS = {
    "review", "orchestrator_tier", "implementer_tier", "reviewer_tier", "budget", "description",
}
REVIEW_KEYS = {"challenge", "review", "shepherd", "min_rounds"}
STAGE_KEYS = ("challenge", "review", "shepherd")
BUDGET_REQUIRED_KEYS = {"max_agent_runs", "max_parallel_agents", "wall_clock_min", "allow_tier_escalation"}
BUDGET_OPTIONAL_KEYS = {"max_tokens", "max_usd"}
STRATEGY_REQUIRED_KEYS = {"topology", "planning", "delegation", "human_gates", "description"}
STRATEGY_OPTIONAL_KEYS = {"coordination", "selection", "synthesis", "min_agents"}
TOP_LEVEL_KEYS = {
    "schema_version", "default_rigor", "default_strategy", "rigor_order",
    "rigor", "review", "budget", "strategy", "tier",
}

TOPOLOGY_ENUM = {"single-agent", "lead-and-workers", "independent-proposals", "human-directed"}
PLANNING_ENUM = {"inline", "explicit", "independent", "collaborative"}
DELEGATION_ENUM = {"none", "optional", "required"}
COORDINATION_ENUM = {"parallel-when-independent"}
SELECTION_ENUM = {"judge"}

ALLOWED_HUMAN_GATES = {
    "after-discovery", "after-plan", "before-delegation", "before-selection",
    "before-synthesis", "before-scope-expansion", "before-budget-escalation",
    "before-publication", "before-ready-for-review", "each-phase",
}
# Never configurable by any strategy — enforced by AGENTS.md hard rules,
# branch protection, CODEOWNERS, and the operator's own Constitution,
# entirely outside rigor/strategy (ADR 0007 D6).
CONSTITUTIONAL_GATES = {
    "merge", "release", "destructive-actions", "credential-store-writes",
    "security-relevant-settings",
}

# The tier ladder is fixed by ADR 0006 D2; `adaptive` is off-ladder and never
# a legal role-tier value (ADR 0006 D7, re-scoped by ADR 0007 D2/D5 from
# `default_tier` to every [rigor.*] role tier and override target).
LADDER = ("local", "economy", "standard", "frontier", "apex")
LADDER_RANK = {tier: i for i, tier in enumerate(LADDER)}
RESERVED_TIER_KEYS = {"endpoint", "escalate_to"}

# A strategy whose min_agents exceeds the paired rigor's budget
# (max_agent_runs OR max_parallel_agents) is a documented incompatibility,
# never a silent substitution (ADR 0007 D11). Every shipped pair not listed
# here must actually resolve; every pair listed here must actually be
# incompatible — both directions are checked below, so a retune that closes
# or opens a gap is caught either way.
KNOWN_INCOMPATIBLE = {("council", "trivial"), ("orchestrate", "trivial")}


def family_values(registry_path, family_name):
    # Only values the renderer actually seeds count: a retired or
    # provision:false value has no live label, so a config that names it
    # would be unselectable by the documented label path.
    with open(registry_path, "rb") as fh:
        manifest = json.load(fh)
    return {
        value["value"]: value.get("description")
        for family in manifest.get("families", [])
        if family.get("family") == family_name
        and family.get("provision") is True
        and family.get("retired") is not True
        for value in family.get("values", [])
        if value.get("provision") is not False and value.get("retired") is not True
    }


def registry_models(agent_registry_path):
    # family slug -> {model slugs}
    with open(agent_registry_path, "rb") as fh:
        reg = json.load(fh)
    return {f["slug"]: {m["slug"] for m in f.get("models", [])} for f in reg.get("families", [])}


def local_harness_families(agent_registry_path):
    # Families with a registered `-local` endpoint-variant harness (ADR 0005
    # D9): a [tier.local] entry may only name one of these.
    with open(agent_registry_path, "rb") as fh:
        reg = json.load(fh)
    fams = set()
    for harness in reg.get("harnesses", []):
        constraint = harness.get("family_constraint", {})
        if (
            harness.get("slug", "").endswith("-local")
            and harness.get("provider_rewired") is True
            and constraint.get("kind") == "fixed"
            and constraint.get("family")
        ):
            fams.add(constraint["family"])
    return fams


def registry_harnesses(agent_registry_path):
    with open(agent_registry_path, "rb") as fh:
        reg = json.load(fh)
    return reg.get("harnesses", [])


# agent-registry.json's roles vocabulary (verb forms) vs .devflow.toml's
# role-tier field names (noun forms) — kept as two vocabularies on purpose
# (each file's natural spelling), so the coverage check below needs the map
# between them.
ROLE_TIER_TO_HARNESS_ROLE = {
    "orchestrator_tier": "orchestrate",
    "implementer_tier": "implement",
    "reviewer_tier": "review",
}


registries_by_config = {
    ".devflow.toml": (registry_root, agent_registry_root),
    "template/.devflow.toml": (registry_template, agent_registry_template),
}

for path in config_paths:
    with open(path, "rb") as fh:
        raw_text = fh.read().decode("utf-8")
        try:
            cfg = tomllib.loads(raw_text)
        except tomllib.TOMLDecodeError as exc:
            failures.append(f"{path}: not valid TOML — {exc}")
            continue

    if "docs/guides/devflow.md" not in raw_text:
        failures.append(f"{path}: header does not link to docs/guides/devflow.md")

    unknown_top_level = set(cfg) - TOP_LEVEL_KEYS
    if unknown_top_level:
        failures.append(f"{path}: has unknown top-level key(s) {sorted(unknown_top_level)}")

    schema_version = cfg.get("schema_version")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool):
        failures.append(f"{path}: schema_version must be an integer (got {schema_version!r})")
    elif schema_version != SUPPORTED_SCHEMA_VERSION:
        failures.append(
            f"{path}: schema_version={schema_version!r} is unsupported; "
            f"supported version is {SUPPORTED_SCHEMA_VERSION}"
        )

    for removed in ("default_tier", "default_method"):
        if removed in cfg:
            failures.append(f"{path}: {removed!r} is present but was removed by ADR 0007")
    if "method" in cfg:
        failures.append(f"{path}: [method] table is present but was removed by ADR 0007")

    default_rigor = cfg.get("default_rigor")
    default_strategy = cfg.get("default_strategy")
    rigor_order = cfg.get("rigor_order")
    levels = cfg.get("rigor")
    reviews = cfg.get("review")
    budgets = cfg.get("budget")
    strategies = cfg.get("strategy")

    if not isinstance(levels, dict) or set(levels) != RIGOR_LEVELS:
        failures.append(
            f"{path}: [rigor.*] must define exactly {sorted(RIGOR_LEVELS)} "
            f"(have: {sorted(levels) if isinstance(levels, dict) else levels!r})"
        )
        levels = {}
    if not isinstance(reviews, dict) or set(reviews) != REVIEW_POLICIES:
        failures.append(
            f"{path}: [review.*] must define exactly {sorted(REVIEW_POLICIES)} "
            f"(have: {sorted(reviews) if isinstance(reviews, dict) else reviews!r})"
        )
        reviews = {}
    if not isinstance(budgets, dict) or set(budgets) != BUDGET_PROFILES:
        failures.append(
            f"{path}: [budget.*] must define exactly {sorted(BUDGET_PROFILES)} "
            f"(have: {sorted(budgets) if isinstance(budgets, dict) else budgets!r})"
        )
        budgets = {}
    if not isinstance(strategies, dict) or set(strategies) != STRATEGIES:
        failures.append(
            f"{path}: [strategy.*] must define exactly {sorted(STRATEGIES)} "
            f"(have: {sorted(strategies) if isinstance(strategies, dict) else strategies!r})"
        )
        strategies = {}

    if not isinstance(default_rigor, str):
        failures.append(f"{path}: default_rigor is missing or not a string")
    elif default_rigor not in levels:
        failures.append(f"{path}: default_rigor={default_rigor!r} names no [rigor.*] level")

    if not isinstance(default_strategy, str):
        failures.append(f"{path}: default_strategy is missing or not a string")
    elif default_strategy not in strategies:
        failures.append(f"{path}: default_strategy={default_strategy!r} names no [strategy.*] value")

    # rigor_order: a PERMUTATION of the [rigor.*] keys — not pinned to one
    # exact sequence the way the old [method].rank was (ADR 0007's top-level
    # comment explains why: it is a retunable value, not a cross-consumer
    # conflict-resolution contract).
    if not isinstance(rigor_order, list) or not all(isinstance(v, str) for v in rigor_order):
        failures.append(f"{path}: rigor_order must be a list of strings")
    elif len(rigor_order) != len(set(rigor_order)):
        dupes = sorted({v for v in rigor_order if rigor_order.count(v) > 1})
        failures.append(f"{path}: rigor_order has duplicate entries: {dupes}")
    elif set(rigor_order) != set(levels):
        missing_o = sorted(set(levels) - set(rigor_order))
        extra_o = sorted(set(rigor_order) - set(levels))
        detail = []
        if missing_o:
            detail.append(f"missing {missing_o}")
        if extra_o:
            detail.append(f"names unknown level(s) {extra_o}")
        failures.append(f"{path}: rigor_order is not a permutation of [rigor.*] — {'; '.join(detail)}")
    else:
        # rigor_order is a confirmed-valid permutation — being "a
        # permutation" only says the SET is right; it says nothing about
        # whether the ORDER actually climbs. "Strongest label wins" is only
        # a safe conflict rule if strength is monotonic in everything a
        # rigor level composes: for every CONSECUTIVE pair (weaker,
        # stronger), review caps, each role tier (ladder rank), and budget
        # fields must never decrease — allow_tier_escalation may only turn
        # ON — moving up the list. A dip anywhere would mean the "strongest"
        # label doesn't actually buy strictly more of everything, which is
        # the entire premise the conflict rule (and the announcement line)
        # relies on.
        for weaker, stronger in zip(rigor_order, rigor_order[1:]):
            w_tbl, s_tbl = levels.get(weaker), levels.get(stronger)
            if not isinstance(w_tbl, dict) or not isinstance(s_tbl, dict):
                continue  # reported elsewhere ([rigor.*] is not a table)

            w_review = reviews.get(w_tbl.get("review"))
            s_review = reviews.get(s_tbl.get("review"))
            if isinstance(w_review, dict) and isinstance(s_review, dict):
                for stage in STAGE_KEYS:
                    wv, sv = w_review.get(stage), s_review.get(stage)
                    if isinstance(wv, int) and isinstance(sv, int) and sv < wv:
                        failures.append(
                            f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                            f"review.{stage} drops {wv} -> {sv}"
                        )
                # min_rounds is checked separately from STAGE_KEYS above — it
                # is bounded by min(challenge, review) per-policy (below),
                # not itself a stage cap, but it must still never decrease
                # along rigor_order for the same reason challenge/review/
                # shepherd can't: a "stronger" rigor level requiring FEWER
                # confirming rounds than a weaker one would mean climbing
                # rigor_order doesn't actually buy strictly more of
                # everything the level composes.
                wv, sv = w_review.get("min_rounds"), s_review.get("min_rounds")
                if isinstance(wv, int) and isinstance(sv, int) and sv < wv:
                    failures.append(
                        f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                        f"review.min_rounds drops {wv} -> {sv}"
                    )

            for role in ("orchestrator_tier", "implementer_tier", "reviewer_tier"):
                wv, sv = w_tbl.get(role), s_tbl.get(role)
                if wv in LADDER_RANK and sv in LADDER_RANK and LADDER_RANK[sv] < LADDER_RANK[wv]:
                    failures.append(
                        f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                        f"{role} drops {wv!r} -> {sv!r}"
                    )

            w_budget = budgets.get(w_tbl.get("budget"))
            s_budget = budgets.get(s_tbl.get("budget"))
            if isinstance(w_budget, dict) and isinstance(s_budget, dict):
                for field in ("max_agent_runs", "max_parallel_agents", "wall_clock_min"):
                    wv, sv = w_budget.get(field), s_budget.get(field)
                    if isinstance(wv, int) and isinstance(sv, int) and sv < wv:
                        failures.append(
                            f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                            f"budget.{field} drops {wv} -> {sv}"
                        )
                # max_tokens/max_usd are OPTIONAL — absent means UNENFORCED
                # ([budget.*]'s own preamble: a consumer that cannot measure
                # tokens/spend must report the limit as unenforced, not
                # zero), which is the LARGEST possible ceiling, not the
                # smallest. Comparing with absent treated as +infinity keeps
                # that reading consistent: a weaker level with no cap and a
                # stronger level that adds a finite one IS a decrease (the
                # ceiling shrank from unlimited to something finite), while a
                # weaker level with a cap and a stronger level with none is
                # fine (the ceiling only grew). A present-but-non-numeric
                # value is also treated as +infinity here — the field's own
                # type check (below) already reports that separately; this
                # loop only needs to avoid a bad comparison, not re-report it.
                for field in ("max_tokens", "max_usd"):
                    raw_w, raw_s = w_budget.get(field), s_budget.get(field)
                    wv = raw_w if isinstance(raw_w, (int, float)) and not isinstance(raw_w, bool) else float("inf")
                    sv = raw_s if isinstance(raw_s, (int, float)) and not isinstance(raw_s, bool) else float("inf")
                    if sv < wv:
                        w_disp = "absent (unenforced)" if wv == float("inf") else wv
                        s_disp = "absent (unenforced)" if sv == float("inf") else sv
                        failures.append(
                            f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                            f"budget.{field} drops {w_disp} -> {s_disp}"
                        )
                wv, sv = w_budget.get("allow_tier_escalation"), s_budget.get("allow_tier_escalation")
                if wv is True and sv is False:
                    failures.append(
                        f"{path}: rigor_order {weaker!r} -> {stronger!r} is not monotonic — "
                        "budget.allow_tier_escalation turns off (true -> false)"
                    )

    label_registry_path, agent_registry_path = registries_by_config[path]
    rigor_family = family_values(label_registry_path, "rigor")
    strategy_family = family_values(label_registry_path, "strategy")
    models_by_family = registry_models(agent_registry_path)
    local_families = local_harness_families(agent_registry_path)

    # The provisioned tier vocabulary must EQUAL the ADR-fixed ladder, plus
    # `adaptive`, plus the durable role-scoped forms `<role>:<tier>` for
    # every role × every concrete ladder rung (`tier:orchestrator:economy`
    # etc. — never `tier:<role>:adaptive`, since a role tier is always
    # concrete) — both directions, unchanged from before ADR 0007 ("tier
    # maps resolve against agent-registry as today") except for that
    # addition. A missing rung (bare or role-scoped) silently narrows what a
    # [rigor.*] role tier, a label, or an override may name; an EXTRA value
    # (a future `tier:ultra` or `tier:reviewer:ultra`) provisions a label
    # with no ladder position, table, or rank, leaving strongest-wins
    # resolution undefined.
    #
    # The role-scoped forms live in their OWN family, `tier-role` — a
    # `prefix: null` family whose values are the COMPLETE label name
    # (`"tier:orchestrator:economy"`, not a bare `"orchestrator:economy"`
    # suffix), because the label-registry schema's slug pattern forbids a
    # colon inside a value under a non-null prefix. Strip the shared
    # `"tier:"` prefix so both families compare in one `<role>:<tier>` shape;
    # a `tier-role` value that does NOT start with it is left unstripped on
    # purpose — it then simply fails to match anything in `expected_tiers`
    # below and surfaces as an "unexpected" entry, which is the correct
    # failure for a malformed value rather than a bespoke second message.
    SCOPED_TIER_ROLES = ("orchestrator", "implementer", "reviewer")
    valid_tiers = set(family_values(label_registry_path, "tier"))
    for full_name in family_values(label_registry_path, "tier-role"):
        valid_tiers.add(full_name[len("tier:"):] if full_name.startswith("tier:") else full_name)
    expected_tiers = (
        set(LADDER)
        | {"adaptive"}
        | {f"{role}:{tier}" for role in SCOPED_TIER_ROLES for tier in LADDER}
    )
    if valid_tiers != expected_tiers:
        missing_t = sorted(expected_tiers - valid_tiers)
        extra_t = sorted(valid_tiers - expected_tiers)
        detail = []
        if missing_t:
            detail.append(f"missing {', '.join(missing_t)}")
        if extra_t:
            detail.append(f"unexpected {', '.join(extra_t)} (no ladder position/table/rank)")
        failures.append(
            f"{path}: provisioned tier vocabulary in {label_registry_path} does not "
            f"match the ADR-fixed ladder plus role-scoped forms — {'; '.join(detail)}"
        )

    # ── [rigor.*] ────────────────────────────────────────────────────────
    for name, tbl in sorted(levels.items()):
        if not isinstance(tbl, dict):
            failures.append(f"{path}: [rigor.{name}] is not a table")
            continue
        missing_k = RIGOR_REQUIRED_KEYS - set(tbl)
        extra_k = set(tbl) - RIGOR_REQUIRED_KEYS
        if missing_k:
            failures.append(f"{path}: [rigor.{name}] missing {sorted(missing_k)}")
        if extra_k:
            failures.append(f"{path}: [rigor.{name}] has unknown key(s) {sorted(extra_k)}")

        # Type-checked as a scalar string BEFORE dict-membership tests
        # (`x not in reviews`/`x not in budgets`) — `reviews`/`budgets` are
        # dicts, whose membership test requires a hashable LHS, and TOML
        # happily parses e.g. `review = ["none"]` as a valid (if wrong)
        # list value. An unhashable value there would otherwise raise a raw
        # TypeError instead of the FAIL this validator exists to produce.
        review_ref = tbl.get("review")
        if not isinstance(review_ref, str):
            failures.append(f"{path}: [rigor.{name}].review must be a string (got {review_ref!r})")
        elif review_ref not in reviews:
            failures.append(f"{path}: [rigor.{name}].review={review_ref!r} names no [review.*] policy")

        budget_ref = tbl.get("budget")
        if not isinstance(budget_ref, str):
            failures.append(f"{path}: [rigor.{name}].budget must be a string (got {budget_ref!r})")
        elif budget_ref not in budgets:
            failures.append(f"{path}: [rigor.{name}].budget={budget_ref!r} names no [budget.*] profile")

        role_tiers = {}
        for role in ("orchestrator_tier", "implementer_tier", "reviewer_tier"):
            value = tbl.get(role)
            # `value not in LADDER` alone would never raise (tuple
            # membership just compares, unlike dict membership above), but
            # the isinstance check still gives a more specific message.
            if not isinstance(value, str):
                failures.append(f"{path}: [rigor.{name}].{role} must be a string (got {value!r})")
            elif value not in LADDER:
                failures.append(
                    f"{path}: [rigor.{name}].{role}={value!r} is not a concrete ladder tier "
                    f"({', '.join(LADDER)}) — never `adaptive`"
                )
            else:
                role_tiers[role] = value
        if len(role_tiers) == 3:
            impl = LADDER_RANK[role_tiers["implementer_tier"]]
            for role in ("orchestrator_tier", "reviewer_tier"):
                if LADDER_RANK[role_tiers[role]] < impl:
                    failures.append(
                        f"{path}: [rigor.{name}] {role}={role_tiers[role]!r} is below "
                        f"implementer_tier={role_tiers['implementer_tier']!r} — built-in levels "
                        "must satisfy orchestrator_tier >= implementer_tier and "
                        "reviewer_tier >= implementer_tier"
                    )

        description = tbl.get("description")
        if not isinstance(description, str) or not description:
            failures.append(f"{path}: [rigor.{name}].description is missing or not a string")
        elif len(description) > 100:
            failures.append(f"{path}: [rigor.{name}].description is {len(description)} chars, over 100")
        else:
            if name not in rigor_family:
                failures.append(
                    f"{path}: level {name!r} has no rigor:{name} label in {label_registry_path} — "
                    "the documented label resolution path cannot select it"
                )
            elif rigor_family[name] != description:
                failures.append(
                    f"{path}: [rigor.{name}].description does not match the rigor:{name} label "
                    f"description in {label_registry_path} "
                    f"({description!r} vs {rigor_family[name]!r})"
                )

    # ── [review.*] ───────────────────────────────────────────────────────
    for name, tbl in sorted(reviews.items()):
        if not isinstance(tbl, dict):
            failures.append(f"{path}: [review.{name}] is not a table")
            continue
        missing_k = REVIEW_KEYS - set(tbl)
        extra_k = set(tbl) - REVIEW_KEYS
        if missing_k:
            failures.append(f"{path}: [review.{name}] missing {sorted(missing_k)}")
        if extra_k:
            failures.append(f"{path}: [review.{name}] has unknown key(s) {sorted(extra_k)}")

        stage_values = {}
        for stage in STAGE_KEYS:
            value = tbl.get(stage)
            if not isinstance(value, int) or isinstance(value, bool):
                failures.append(f"{path}: review.{name}.{stage}={value!r} is not an integer")
            elif value < 0:
                failures.append(f"{path}: review.{name}.{stage}={value} must be >= 0")
            else:
                stage_values[stage] = value

        min_rounds = tbl.get("min_rounds")
        if not isinstance(min_rounds, int) or isinstance(min_rounds, bool):
            failures.append(f"{path}: review.{name}.min_rounds={min_rounds!r} is not an integer")
        elif min_rounds < 0:
            failures.append(f"{path}: review.{name}.min_rounds={min_rounds} must be >= 0")
        elif "challenge" in stage_values and "review" in stage_values:
            # Scoped to challenge/review ONLY — shepherd is externally
            # driven (CI results, human review, Codex), not something the
            # agent paces itself, so it cannot manufacture a round the way
            # a self-generated challenge/review pass can, and never bounds
            # min_rounds. A policy where both challenge and review are
            # capped at 0 (`none`) requires min_rounds=0 right along with
            # them, regardless of what shepherd's own cap is.
            ceiling = min(stage_values["challenge"], stage_values["review"])
            if min_rounds > ceiling:
                failures.append(
                    f"{path}: review.{name}.min_rounds={min_rounds} exceeds "
                    f"min(challenge, review)={ceiling} for this policy — shepherd is externally "
                    "driven and does not bound min_rounds"
                )

    # shepherd is EXPECTED to vary by policy now (ADR 0007 D4) — no
    # uniformity check here; that is the point of the change.

    # ── [budget.*] ───────────────────────────────────────────────────────
    for name, tbl in sorted(budgets.items()):
        if not isinstance(tbl, dict):
            failures.append(f"{path}: [budget.{name}] is not a table")
            continue
        missing_k = BUDGET_REQUIRED_KEYS - set(tbl)
        extra_k = set(tbl) - BUDGET_REQUIRED_KEYS - BUDGET_OPTIONAL_KEYS
        if missing_k:
            failures.append(f"{path}: [budget.{name}] missing {sorted(missing_k)}")
        if extra_k:
            failures.append(f"{path}: [budget.{name}] has unknown key(s) {sorted(extra_k)}")
        for field in ("max_agent_runs", "max_parallel_agents", "wall_clock_min"):
            value = tbl.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                failures.append(f"{path}: [budget.{name}].{field}={value!r} must be an integer > 0")
        esc = tbl.get("allow_tier_escalation")
        if not isinstance(esc, bool):
            failures.append(f"{path}: [budget.{name}].allow_tier_escalation={esc!r} must be a boolean")
        if "max_tokens" in tbl:
            v = tbl["max_tokens"]
            if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
                failures.append(f"{path}: [budget.{name}].max_tokens={v!r} must be an integer > 0")
        if "max_usd" in tbl:
            v = tbl["max_usd"]
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
                failures.append(f"{path}: [budget.{name}].max_usd={v!r} must be a number > 0")
            elif not math.isfinite(v):
                # TOML has nan/inf/-inf float literals; NaN and +inf both
                # slip past the "> 0" check above (NaN compares False to
                # everything, +inf compares True to "> 0") without this —
                # neither is a JSON-safe value nor a sane USD ceiling.
                failures.append(f"{path}: [budget.{name}].max_usd={v!r} must be finite (not nan/inf)")

    # ── [strategy.*] ─────────────────────────────────────────────────────
    for name, tbl in sorted(strategies.items()):
        if not isinstance(tbl, dict):
            failures.append(f"{path}: [strategy.{name}] is not a table")
            continue
        missing_k = STRATEGY_REQUIRED_KEYS - set(tbl)
        extra_k = set(tbl) - STRATEGY_REQUIRED_KEYS - STRATEGY_OPTIONAL_KEYS
        if missing_k:
            failures.append(f"{path}: [strategy.{name}] missing {sorted(missing_k)}")
        if extra_k:
            failures.append(f"{path}: [strategy.{name}] has unknown key(s) {sorted(extra_k)}")

        topology = tbl.get("topology")
        if topology not in TOPOLOGY_ENUM:
            failures.append(f"{path}: [strategy.{name}].topology={topology!r} not in {sorted(TOPOLOGY_ENUM)}")
        planning = tbl.get("planning")
        if planning not in PLANNING_ENUM:
            failures.append(f"{path}: [strategy.{name}].planning={planning!r} not in {sorted(PLANNING_ENUM)}")
        delegation = tbl.get("delegation")
        if delegation not in DELEGATION_ENUM:
            failures.append(f"{path}: [strategy.{name}].delegation={delegation!r} not in {sorted(DELEGATION_ENUM)}")

        # topology constrains delegation, not the other way round — the
        # triangle documented beside [strategy.*] above: single-agent (one
        # ACCOUNTABLE lead, helpers only when delegation permits) forbids
        # `required`; lead-and-workers AND independent-proposals both
        # require it — a lead-and-workers lead delegates to first-class
        # workers, and an independent-proposals coordinator equally
        # delegates each proposal as a first-class unit before judging (no
        # one plans FOR the proposers; "the lead" is just spelled
        # "coordinator" there) — `none` describes only single-agent, since
        # every other topology inherently involves more than the one
        # accountable party.
        DELEGATION_REQUIRED_TOPOLOGIES = {"lead-and-workers", "independent-proposals"}
        if topology == "single-agent" and delegation == "required":
            failures.append(
                f"{path}: [strategy.{name}] topology=single-agent forbids delegation=required "
                "— an accountable lead cannot be MANDATED to delegate away its own work"
            )
        if topology in DELEGATION_REQUIRED_TOPOLOGIES and delegation != "required":
            failures.append(
                f"{path}: [strategy.{name}] topology={topology!r} requires delegation=required "
                f"(got {delegation!r}) — {topology} always delegates to first-class units, "
                "worker or proposer alike"
            )
        if delegation == "none" and topology != "single-agent":
            failures.append(
                f"{path}: [strategy.{name}] delegation=none is only valid with topology=single-agent "
                f"(got topology={topology!r})"
            )

        # These four fields are meaningful only on the topologies whose
        # shape they describe — permitted there, not merely valid wherever
        # present. `selection`/`synthesis` describe how independent
        # proposals get judged, so only independent-proposals (council)
        # defines them. `min_agents` is the multi-agent floor, so it is
        # legal on independent-proposals AND lead-and-workers (orchestrate)
        # — the two topologies with a floor at all — never on single-agent
        # or human-directed. `coordination` governs scheduling among
        # DELEGATED agents, so it is legal on either multi-agent topology
        # too, even though only orchestrate uses it today.
        MULTI_AGENT_TOPOLOGIES = {"lead-and-workers", "independent-proposals"}
        if "coordination" in tbl and topology not in MULTI_AGENT_TOPOLOGIES:
            failures.append(
                f"{path}: [strategy.{name}].coordination is only valid on a multi-agent topology "
                f"{sorted(MULTI_AGENT_TOPOLOGIES)} (got topology={topology!r})"
            )
        if "selection" in tbl and topology != "independent-proposals":
            failures.append(
                f"{path}: [strategy.{name}].selection is only valid on topology=independent-proposals "
                f"(got topology={topology!r})"
            )
        if "synthesis" in tbl and topology != "independent-proposals":
            failures.append(
                f"{path}: [strategy.{name}].synthesis is only valid on topology=independent-proposals "
                f"(got topology={topology!r})"
            )
        if "min_agents" in tbl and topology not in MULTI_AGENT_TOPOLOGIES:
            failures.append(
                f"{path}: [strategy.{name}].min_agents is only valid on a multi-agent topology "
                f"{sorted(MULTI_AGENT_TOPOLOGIES)} (got topology={topology!r})"
            )

        required_by_topology = []
        if topology == "lead-and-workers":
            required_by_topology.extend(["coordination", "min_agents"])
        if topology == "independent-proposals":
            required_by_topology.extend(["selection", "synthesis", "min_agents"])
        missing_by_topology = [field for field in required_by_topology if field not in tbl]
        if missing_by_topology:
            failures.append(
                f"{path}: [strategy.{name}] topology={topology!r} is missing required field(s) "
                f"{sorted(missing_by_topology)}"
            )

        if "coordination" in tbl and tbl["coordination"] not in COORDINATION_ENUM:
            failures.append(
                f"{path}: [strategy.{name}].coordination={tbl['coordination']!r} "
                f"not in {sorted(COORDINATION_ENUM)}"
            )
        if "selection" in tbl and tbl["selection"] not in SELECTION_ENUM:
            failures.append(
                f"{path}: [strategy.{name}].selection={tbl['selection']!r} not in {sorted(SELECTION_ENUM)}"
            )
        if "synthesis" in tbl and not isinstance(tbl["synthesis"], bool):
            failures.append(f"{path}: [strategy.{name}].synthesis={tbl['synthesis']!r} must be a boolean")
        if "min_agents" in tbl:
            ma = tbl["min_agents"]
            if not isinstance(ma, int) or isinstance(ma, bool) or ma < 2:
                failures.append(f"{path}: [strategy.{name}].min_agents={ma!r} must be an integer >= 2")

        if name == "council":
            if tbl.get("selection") != "judge" or tbl.get("synthesis") is not True or not (
                isinstance(tbl.get("min_agents"), int) and not isinstance(tbl.get("min_agents"), bool)
                and tbl.get("min_agents", 0) >= 2
            ):
                failures.append(
                    f"{path}: [strategy.council] must set selection=\"judge\", synthesis=true, "
                    "and min_agents >= 2"
                )

        gates = tbl.get("human_gates")
        if not isinstance(gates, list) or not all(isinstance(g, str) for g in gates):
            failures.append(f"{path}: [strategy.{name}].human_gates must be a list of strings")
        else:
            for gate in gates:
                if gate in CONSTITUTIONAL_GATES:
                    failures.append(
                        f"{path}: [strategy.{name}].human_gates names constitutional gate {gate!r} — "
                        "constitutional approvals are never configurable by a strategy"
                    )
                elif gate not in ALLOWED_HUMAN_GATES:
                    failures.append(
                        f"{path}: [strategy.{name}].human_gates names {gate!r}, not in the allowed "
                        f"set {sorted(ALLOWED_HUMAN_GATES)}"
                    )

        description = tbl.get("description")
        if not isinstance(description, str) or not description:
            failures.append(f"{path}: [strategy.{name}].description is missing or not a string")
        elif len(description) > 100:
            failures.append(f"{path}: [strategy.{name}].description is {len(description)} chars, over 100")
        else:
            if name not in strategy_family:
                failures.append(
                    f"{path}: strategy {name!r} has no strategy:{name} label in {label_registry_path} — "
                    "the documented label resolution path cannot select it"
                )
            elif strategy_family[name] != description:
                failures.append(
                    f"{path}: [strategy.{name}].description does not match the strategy:{name} label "
                    f"description in {label_registry_path} "
                    f"({description!r} vs {strategy_family[name]!r})"
                )

    # ── strategy × rigor compatibility matrix ───────────────────────────
    # min_agents COUNTS DIFFERENTLY per topology (comment beside
    # [strategy.*] above), so ONLY council's arithmetic changes — every
    # topology is still checked against BOTH ceilings directly, no
    # subtraction anywhere:
    #   independent-proposals (council): min_agents counts PROPOSERS only —
    #     the coordinator that judges them afterward is one MORE run but
    #     does not need a concurrent slot (it runs after the proposers
    #     finish). Needs max_agent_runs >= min_agents + 1 and
    #     max_parallel_agents >= min_agents.
    #   lead-and-workers (orchestrate): min_agents counts the lead PLUS its
    #     workers — the WHOLE minimum roster, lead included. Needs
    #     max_agent_runs >= min_agents and max_parallel_agents >=
    #     min_agents, exactly like the generic fallback below — no "the
    #     lead doesn't count" discount on either ceiling.
    #     specs/issue-strategy.md states the plain "min_agents exceeds
    #     max_agent_runs or max_parallel_agents" rule with no per-topology
    #     discount; orchestrate does not special-case away from that the
    #     way council's different COUNTING convention does.
    #   anything else: no topology-specific formula is defined, so fall
    #     back to the conservative same-value check.
    #
    # Every (strategy, rigor) pair is evaluated below, even one whose
    # strategy carries no min_agents at all (has_min_agents=False forces
    # incompatible=False rather than skipping the pair outright) — a
    # strategy that LOSES its min_agents field is exactly the case that must
    # still trip the "documented but no longer incompatible" branch further
    # down; `continue`-ing past it here would let a stale KNOWN_INCOMPATIBLE
    # entry survive undetected instead of merely under-triggering.
    for sname, stbl in strategies.items():
        min_agents = stbl.get("min_agents") if isinstance(stbl, dict) else None
        has_min_agents = isinstance(min_agents, int) and not isinstance(min_agents, bool)
        topology = stbl.get("topology") if isinstance(stbl, dict) else None
        required_runs = required_parallel = None
        if has_min_agents:
            if topology == "independent-proposals":
                required_runs, required_parallel = min_agents + 1, min_agents
            elif topology == "lead-and-workers":
                required_runs = required_parallel = min_agents  # no lead discount — see above
            else:
                required_runs = required_parallel = min_agents
        for rname, rtbl in levels.items():
            if not isinstance(rtbl, dict):
                continue
            budget_name = rtbl.get("budget")
            budget_tbl = budgets.get(budget_name)
            if not isinstance(budget_tbl, dict):
                continue
            runs = budget_tbl.get("max_agent_runs")
            parallel = budget_tbl.get("max_parallel_agents")
            incompatible = has_min_agents and (
                (isinstance(runs, int) and required_runs > runs)
                or (isinstance(parallel, int) and required_parallel > parallel)
            )
            documented = (sname, rname) in KNOWN_INCOMPATIBLE
            if incompatible and not documented:
                failures.append(
                    f"{path}: strategy {sname!r} ({topology!r}, min_agents={min_agents}) needs "
                    f"max_agent_runs>={required_runs}, max_parallel_agents>={required_parallel}, "
                    f"but rigor {rname!r}'s budget {budget_name!r} has max_agent_runs={runs}, "
                    f"max_parallel_agents={parallel} — not in KNOWN_INCOMPATIBLE"
                )
            if documented and not incompatible:
                failures.append(
                    f"{path}: KNOWN_INCOMPATIBLE lists ({sname!r}, {rname!r}) but it actually "
                    "resolves cleanly now — remove the stale entry"
                )

    # ── [tier.*] — unchanged in shape from ADR 0006, re-scoped resolution ─
    tiers = cfg.get("tier")
    if tiers is None:
        failures.append(f"{path}: [tier] tables are missing — harmon-init ships the full ladder (ADR 0006 D2)")
    elif not isinstance(tiers, dict):
        failures.append(f"{path}: [tier] is not a table")
        tiers = None
    if isinstance(tiers, dict):
        missing_tables = [t for t in LADDER if t not in tiers]
        if missing_tables:
            failures.append(
                f"{path}: [tier] is missing table(s) for {', '.join(missing_tables)} — "
                "the shipped ladder must be complete (ADR 0006 D2)"
            )
        for name, tbl in sorted(tiers.items()):
            if not isinstance(tbl, dict):
                failures.append(f"{path}: [tier.{name}] is not a table")
                continue
            if name == "adaptive":
                failures.append(
                    f"{path}: [tier.adaptive] is not allowed — `adaptive` is resolved by "
                    "preflight, never a concrete map (ADR 0006 D7)"
                )
                continue
            if name not in LADDER_RANK:
                failures.append(f"{path}: [tier.{name}] names no ladder tier (ladder: {' → '.join(LADDER)})")

            endpoint = tbl.get("endpoint")
            if endpoint is not None and endpoint != "local":
                failures.append(f'{path}: [tier.{name}] endpoint={endpoint!r} — only "local" is valid')
            if name == "local" and endpoint != "local":
                failures.append(f'{path}: [tier.local] must set endpoint = "local" (ADR 0006 D2)')
            if name != "local" and endpoint is not None:
                failures.append(f"{path}: [tier.{name}] sets endpoint but is not the local tier")

            esc = tbl.get("escalate_to")
            if esc is None:
                failures.append(f"{path}: [tier.{name}] is missing escalate_to")
            elif not isinstance(esc, list) or not all(isinstance(e, str) for e in esc):
                failures.append(f"{path}: [tier.{name}] escalate_to must be a list of strings")
            else:
                for target in esc:
                    if target not in LADDER_RANK:
                        failures.append(
                            f"{path}: [tier.{name}] escalate_to → {target!r} is not a ladder "
                            f"tier (ladder: {' → '.join(LADDER)}; `adaptive` is not a target)"
                        )
                        continue
                    if name in LADDER_RANK and LADDER_RANK[target] <= LADDER_RANK[name]:
                        failures.append(
                            f"{path}: [tier.{name}] escalate_to → {target!r} is not monotonic "
                            f"toward apex (it must rank above {name})"
                        )

            if name == "local" and isinstance(esc, list) and esc != ["economy"]:
                failures.append(
                    f'{path}: [tier.local] escalate_to must be exactly ["economy"] '
                    f"(ADR 0006 D2), got {esc}"
                )

            for fam, slug in tbl.items():
                if fam in RESERVED_TIER_KEYS:
                    continue
                if not isinstance(slug, str):
                    failures.append(f"{path}: [tier.{name}] {fam} model must be a string")
                    continue
                if fam not in models_by_family:
                    failures.append(f"{path}: [tier.{name}] family {fam!r} is not in {agent_registry_path}")
                elif slug not in models_by_family[fam]:
                    failures.append(
                        f"{path}: [tier.{name}] {fam}={slug!r} is not a registered model of "
                        f"{fam} in {agent_registry_path}"
                    )
                if name == "local" and fam not in local_families:
                    failures.append(
                        f"{path}: [tier.local] family {fam!r} has no registered `-local` harness "
                        f"in {agent_registry_path} (ADR 0006 D2 — local is opt-in per family)"
                    )

    # ── agent-registry harness coverage ─────────────────────────────────
    # Not just "some harness declares this role at all" — for EVERY shipped
    # rigor level and EVERY role, at least one harness declaring that role
    # must be able to reach a model AT THE TIER that role needs: a broker
    # harness (family_constraint.kind == "broker") qualifies whenever ANY
    # family has a model at that tier; a fixed-family harness
    # (kind == "fixed") qualifies only when its OWN family does.
    harnesses = registry_harnesses(agent_registry_path)
    tier_families = {
        tname: {k for k in ttbl if k not in RESERVED_TIER_KEYS}
        for tname, ttbl in (tiers.items() if isinstance(tiers, dict) else [])
        if isinstance(ttbl, dict)
    }
    for rname, rtbl in sorted(levels.items()):
        if not isinstance(rtbl, dict):
            continue
        for role_field, harness_role in ROLE_TIER_TO_HARNESS_ROLE.items():
            tname = rtbl.get(role_field)
            families = tier_families.get(tname)
            if families is None:
                continue  # a dangling/missing tier table is reported elsewhere
            served = any(
                harness_role in h.get("roles", [])
                and (
                    (h.get("family_constraint", {}).get("kind") == "broker" and bool(families))
                    or h.get("family_constraint", {}).get("family") in families
                )
                for h in harnesses
            )
            if not served:
                failures.append(
                    f"{path}: [rigor.{rname}].{role_field}={tname!r} — no harness in "
                    f"{agent_registry_path} declaring the {harness_role!r} role can reach a "
                    f"{tname!r}-tier model (families with a {tname!r}-tier model: "
                    f"{sorted(families) or 'none'})"
                )

# ── AGENTS.md / template twin: the built-in fallback sentence ───────────────
# Exactly one match per file, of exactly this shape, and the captured numbers
# must equal the [review.<name>] table they name — equal across layers too.
FALLBACK_RE = re.compile(
    r"built-in fallback \(the `(\w+)` review policy: (\d+) / (\d+) / (\d+), min_rounds (\d+)\)"
)
fallbacks = {}
for agents_path in (agents_root, agents_template):
    text = open(agents_path).read()
    found = FALLBACK_RE.findall(text)
    if len(found) != 1:
        failures.append(
            f"{agents_path}: expected exactly one built-in fallback sentence, found {len(found)}"
        )
        continue
    level, challenge, review, shepherd, min_rounds = found[0]
    fallbacks[agents_path] = (level, int(challenge), int(review), int(shepherd), int(min_rounds))

if len(set(fallbacks.values())) > 1:
    failures.append(
        "the built-in fallback sentence disagrees across the dogfood: "
        + "; ".join(f"{p} says {v}" for p, v in sorted(fallbacks.items()))
    )

# Cross-check against the root config's own [review.<name>] table — the
# fallback sentence must describe a policy that actually exists and matches.
if config_paths and fallbacks:
    with open(config_paths[0], "rb") as fh:
        root_cfg_for_fallback = tomllib.load(fh)
    root_reviews = root_cfg_for_fallback.get("review", {})
    for agents_path, (level, challenge, review, shepherd, min_rounds) in fallbacks.items():
        policy = root_reviews.get(level)
        if not isinstance(policy, dict):
            failures.append(
                f"{agents_path}: built-in fallback names review policy {level!r}, which "
                "[review.*] does not define"
            )
            continue
        actual = (policy.get("challenge"), policy.get("review"), policy.get("shepherd"), policy.get("min_rounds"))
        stated = (challenge, review, shepherd, min_rounds)
        if actual != stated:
            failures.append(
                f"{agents_path}: built-in fallback states {level}={stated} but "
                f"[review.{level}] is actually {actual}"
            )

if failures:
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)

with open(config_paths[0], "rb") as fh:
    cfg = tomllib.load(fh)
levels = cfg["rigor"]
reviews = cfg["review"]
strategies = cfg["strategy"]
print(f"devflow config OK: default_rigor={cfg['default_rigor']} default_strategy={cfg['default_strategy']}")
print(
    "  rigor levels: "
    + ", ".join(
        f"{n}[{t['review']}/{t['orchestrator_tier'][:3]}-{t['implementer_tier'][:3]}-"
        f"{t['reviewer_tier'][:3]}/{t['budget']}]"
        for n, t in sorted(levels.items())
    )
)
print(
    "  review policies: "
    + ", ".join(
        f"{n}={t['challenge']}/{t['review']}/{t['shepherd']} (min {t['min_rounds']})"
        for n, t in sorted(reviews.items())
    )
)
print("  strategies: " + ", ".join(sorted(strategies)))
print("  (both copies valid; every level/strategy has a matching label; tiers/harness roles resolve)")
PY

# `set -e` above already stops this script if the static validation just run
# exited non-zero, so reaching here means it passed.

# ── Resolver case table ──────────────────────────────────────────────────
# Exercises scripts/devflow-resolve.py against the resolution-order rules
# ADR 0007 defines, over the checked-in root config. This is a REFERENCE
# resolver (harmon-init#1048 adds the versioned fixture corpus); this table
# covers the cases that matter for confidence that the rules above actually
# compose the way the prose says they do.
python3 - "$PWD" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
import tomllib

repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
resolver = os.path.join(repo, "scripts", "devflow-resolve.py")
config = os.path.join(repo, ".devflow.toml")

with open(config, "rb") as fh:
    default_strategy = tomllib.load(fh)["default_strategy"]

failures = []


def run(*args):
    # --config-unchanged by default: every case below is exercising
    # rigor/strategy/tier resolution, not the merge-base distinction, so
    # "read --config directly" (the branch-unchanged basis) is the right
    # default — pass an explicit --merge-base-config/--merge-base-absent in
    # *args to override it for a case that specifically needs to.
    result = subprocess.run(
        [sys.executable, resolver, "--config", config, "--config-unchanged", *args],
        capture_output=True, text=True,
    )
    try:
        return result.returncode, json.loads(result.stdout)
    except json.JSONDecodeError:
        failures.append(
            f"devflow-resolve.py {' '.join(args)}: stdout was not JSON: "
            f"{result.stdout!r} {result.stderr!r}"
        )
        return result.returncode, {}


def check(description, condition):
    if condition:
        print(f"  RESOLVES: {description}")
    else:
        failures.append(f"resolver case failed: {description}")


# rigor conflict -> strongest by rigor_order
code, out = run("--label", "rigor:light", "--label", "rigor:deep")
check("rigor conflict resolves to the strongest label (deep)",
      code == 0 and out["selections"]["rigor"] == {"value": "deep", "source": "label"})

# two strategy labels -> ambiguous (interactive: error; unattended: default+warning)
code, out = run("--label", "strategy:plan", "--label", "strategy:orchestrate")
check("two strategy labels are ambiguous and error (interactive)",
      code == 1 and out["selections"]["strategy"]["value"] is None
      and any(e["code"] == "ambiguous_strategy" for e in out["errors"]))

# Trust-filtering runs BEFORE ambiguity resolution, so both conflicting
# labels need --trusted-label here or they never survive to be ambiguous at
# all — that "plain label filtered under --unattended" path is covered
# separately below (rigor:trivial, untrusted, no --trusted-label).
code, out = run("--label", "strategy:plan", "--label", "strategy:orchestrate",
                "--trusted-label", "strategy:plan", "--trusted-label", "strategy:orchestrate",
                "--unattended")
check("two TRUSTED strategy labels default with a warning, once unattended",
      code == 0
      and out["selections"]["strategy"] == {"value": default_strategy, "source": "default"}
      and any(w["code"] == "ambiguous_strategy" for w in out["warnings"]))

# council x trivial -> incompatible, reported not substituted
code, out = run("--override", "rigor=trivial", "--override", "strategy=council")
check("council under trivial is a reported incompatibility",
      code == 1 and any(e["code"] == "incompatible_strategy" for e in out["errors"]))

# orchestrate x trivial -> also incompatible (delegation=required needs a lead + >=1 worker)
code, out = run("--override", "rigor=trivial", "--override", "strategy=orchestrate")
check("orchestrate under trivial is also a reported incompatibility",
      code == 1 and any(e["code"] == "incompatible_strategy" for e in out["errors"]))
check("... and the message shows NO lead subtraction — both ceilings need min_agents directly",
      code == 1 and any(
          e["code"] == "incompatible_strategy"
          and "max_agent_runs>=2" in e["detail"] and "max_parallel_agents>=2" in e["detail"]
          for e in out["errors"]
      ))

# multiple tier labels for the SAME role resolve strongest-wins by ladder
# rank, regardless of input order — the literal apex/economy example from
# the finding this fixes, checked both ways round.
code, out = run("--label", "tier:apex", "--label", "tier:economy")
check("tier:apex then tier:economy resolves to apex (strongest, not last)",
      code == 0 and out["tiers"]["implementer"]["value"] == "apex")
code, out = run("--label", "tier:economy", "--label", "tier:apex")
check("tier:economy then tier:apex ALSO resolves to apex (order-independent)",
      code == 0 and out["tiers"]["implementer"]["value"] == "apex")
# the unqualified and scoped forms land on the same role and must be
# reconciled together, not treated as two independent overrides.
code, out = run("--label", "tier:economy", "--label", "tier:implementer:frontier")
check("an unqualified and a scoped label for the same role also resolve strongest-wins",
      code == 0 and out["tiers"]["implementer"]["value"] == "frontier")

# --unattended: an untrusted --label is NOT applied — it is ignored (named
# in a warning) and falls back to the default, per ADR 0006 D6.1.
code, out = run("--label", "rigor:trivial", "--unattended")
check("under --unattended, an untrusted rigor label is ignored and falls back to the default",
      code == 0
      and out["selections"]["rigor"] == {"value": "standard", "source": "default"}
      and any(w["code"] == "untrusted_label_ignored" and "rigor:trivial" in w["detail"]
              for w in out["warnings"]))

# --unattended + --trusted-label: a TRUSTED label still applies.
code, out = run("--label", "rigor:trivial", "--trusted-label", "rigor:trivial", "--unattended")
check("under --unattended, a --trusted-label of the same value applies normally",
      code == 0 and out["selections"]["rigor"] == {"value": "trivial", "source": "label"})

# interactive mode: --label stays advisory as before, but an off-default
# result driven by an UNTRUSTED label requires operator confirmation
# (ADR 0006 D6.2) — and does not when the same label is trusted, or when
# the result was never off-default in the first place.
code, out = run("--label", "rigor:deep")
check("interactive + untrusted off-default label -> requires_confirmation",
      code == 0 and out["selections"]["rigor"]["value"] == "deep"
      and out["requires_confirmation"] is True)
code, out = run("--label", "rigor:deep", "--trusted-label", "rigor:deep")
check("interactive + TRUSTED off-default label -> no confirmation needed",
      code == 0 and out["selections"]["rigor"]["value"] == "deep"
      and out["requires_confirmation"] is False)
code, out = run()
check("interactive + on-default result -> no confirmation needed (nothing off-default)",
      code == 0 and out["requires_confirmation"] is False)

# tier:implementer:economy under standard -> refines + off_profile disclosed
code, out = run("--override", "rigor=standard", "--label", "tier:implementer:economy")
check("scoped tier:implementer:economy refines just the implementer, off-profile disclosed",
      code == 0
      and out["tiers"]["implementer"]["value"] == "economy"
      and out["tiers"]["implementer"]["source"] == "label"
      and out["tiers"]["implementer"]["off_profile"] is True
      and out["tiers"]["orchestrator"]["off_profile"] is False
      and out["tiers"]["reviewer"]["off_profile"] is False
      and out["disclosure"]["off_profile"] is True)

# unqualified tier:economy -> implementer only
code, out = run("--override", "rigor=standard", "--label", "tier:economy")
check("unqualified tier:economy refines the implementer only",
      code == 0
      and out["tiers"]["implementer"]["value"] == "economy"
      and out["tiers"]["orchestrator"]["source"] == "profile"
      and out["tiers"]["reviewer"]["source"] == "profile")

# tier:adaptive is a VALID provisioned value ONLY via the unqualified
# tier:<value> label shape (implementer-targeting) — three resolution paths
# from there: (a) --adaptive-result wins outright, (b) absent it,
# preflight_required + the rigor profile's own tier as a provisional
# placeholder, (c) a concrete tier label on the same role beats adaptive.
# tier:<role>:adaptive is a DIFFERENT, unprovisioned shape — covered as
# "unknown" further below, not exercised here.
code, out = run("--override", "rigor=standard", "--label", "tier:adaptive",
                "--adaptive-result", "economy")
check("(a) --adaptive-result wins outright for a role that resolved to adaptive",
      code == 0
      and out["tiers"]["implementer"]["value"] == "economy"
      and out["tiers"]["implementer"]["requested"] == "adaptive"
      and out["tiers"]["implementer"]["preflight_required"] is False
      and out["preflight_required"] is False)

code, out = run("--override", "rigor=standard", "--label", "tier:adaptive")
check("(b) no --adaptive-result -> preflight_required, provisional = rigor profile's own tier",
      code == 0
      and out["tiers"]["implementer"]["preflight_required"] is True
      and out["tiers"]["implementer"]["value"] == "standard"  # rigor.standard's own implementer_tier
      and out["tiers"]["implementer"]["off_profile"] is False  # provisional != a real deviation
      and out["preflight_required"] is True)

code, out = run("--override", "rigor=standard",
                "--label", "tier:adaptive", "--label", "tier:economy")
check("(c) a concrete tier label on the same role beats adaptive",
      code == 0
      and out["tiers"]["implementer"]["value"] == "economy"
      and out["tiers"]["implementer"]["preflight_required"] is False)

# tier:<role>:adaptive is NOT a provisioned label shape — label-registry.json's
# tier-role family holds only the 15 concrete role x ladder combinations, never
# a role-scoped adaptive variant (a role can't be pinned to "let a preflight
# classifier decide"). Treated as unknown and ignored, same as any other
# unrecognized value — not a second route to preflight classification.
code, out = run("--label", "tier:reviewer:adaptive")
check("tier:<role>:adaptive is not provisioned -- unknown, ignored, reviewer stays on profile",
      code == 0
      and out["tiers"]["reviewer"]["value"] == "frontier"  # rigor.standard's own reviewer_tier
      and out["tiers"]["reviewer"]["preflight_required"] is False
      and any(w["code"] == "unknown_label" and "tier:reviewer:adaptive" in w["detail"]
              for w in out["warnings"]))

# requires_confirmation stays honest through adaptive resolution: it must
# be computed from what was actually REQUESTED (adaptive), not from
# whatever --adaptive-result later resolved it to, or trust-checking would
# look for a label that was never applied.
code, out = run("--label", "tier:adaptive", "--adaptive-result", "economy")
check("requires_confirmation fires for an UNTRUSTED adaptive label once resolved off-profile",
      code == 0 and out["tiers"]["implementer"]["off_profile"] is True
      and out["requires_confirmation"] is True)
code, out = run("--label", "tier:adaptive", "--trusted-label", "tier:adaptive",
                "--adaptive-result", "economy")
check("... but not for the identical TRUSTED adaptive label",
      code == 0 and out["tiers"]["implementer"]["off_profile"] is True
      and out["requires_confirmation"] is False)

# --override is the explicit, attributable instruction channel — "defer to
# a preflight classifier" is not a concrete instruction, so adaptive is
# rejected here even though the identical value is fine as a LABEL.
code, out = run("--override", "tier=adaptive")
check("--override tier=adaptive is rejected as invalid_input, not accepted",
      code == 1 and any(e["code"] == "invalid_input" and "adaptive" in e["detail"] for e in out["errors"]))
code, out = run("--override", "tier.reviewer=adaptive")
check("--override tier.reviewer=adaptive is ALSO rejected as invalid_input (scoped, too)",
      code == 1 and any(e["code"] == "invalid_input" and "adaptive" in e["detail"] for e in out["errors"]))

# explicit override beats label
code, out = run("--label", "rigor:light", "--override", "rigor=deep")
check("an explicit override beats a conflicting label",
      code == 0 and out["selections"]["rigor"] == {"value": "deep", "source": "explicit"})

# merge-base config wins over branch config
with tempfile.TemporaryDirectory() as tmp:
    branch_cfg = open(config).read().replace('default_rigor    = "standard"', 'default_rigor    = "deep"')
    mergebase_cfg = open(config).read().replace('default_rigor    = "standard"', 'default_rigor    = "trivial"')
    branch_path = os.path.join(tmp, "branch.toml")
    mergebase_path = os.path.join(tmp, "mergebase.toml")
    open(branch_path, "w").write(branch_cfg)
    open(mergebase_path, "w").write(mergebase_cfg)
    result = subprocess.run(
        [sys.executable, resolver, "--config", branch_path, "--merge-base-config", mergebase_path],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("merge-base config is read instead of the branch copy",
          result.returncode == 0
          and out["config_source"] == "merge-base"
          and out["selections"]["rigor"] == {"value": "trivial", "source": "default"})

# A v1 config that loses any required table is invalid to the resolver too,
# not merely to the root-only validator. The tier tables sit last in the
# shipped file, so this creates a syntactically valid partial config without
# disturbing the other profile references.
with tempfile.TemporaryDirectory() as tmp:
    partial_path = os.path.join(tmp, "partial.toml")
    open(partial_path, "w").write(open(config).read().split("[tier.local]", 1)[0])
    result = subprocess.run(
        [sys.executable, resolver, "--config", partial_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
check("a schema-v1 config missing [tier.*] is invalid to the resolver",
      result.returncode == 1
      and any(e["code"] == "invalid_config" and "tier" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    broken_path = os.path.join(tmp, "non-table-tier.toml")
    open(broken_path, "w").write(open(config).read().split("[tier.local]", 1)[0] + 'tier = "broken"\n')
    result = subprocess.run(
        [sys.executable, resolver, "--config", broken_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 non-table tier registry is invalid_config, never a traceback",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "tier" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    partial_path = os.path.join(tmp, "partial-tier-ladder.toml")
    open(partial_path, "w").write(open(config).read().split("[tier.economy]", 1)[0])
    result = subprocess.run(
        [sys.executable, resolver, "--config", partial_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 config missing concrete tier maps is invalid to the resolver",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "economy" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    native_path = os.path.join(tmp, "native-tier-value.toml")
    open(native_path, "w").write(open(config).read().replace(
        'escalate_to = ["economy"]', 'escalate_to = [2026-08-25]', 1))
    result = subprocess.run(
        [sys.executable, resolver, "--config", native_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a TOML-native uniqueItems value is invalid_config, never a traceback",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "tier.local.escalate_to" in e["detail"]
                  for e in out["errors"]))

# Required nested fields are part of the same v1 structural contract. A
# missing cap must not make a resolver silently emit a policy that a consumer
# can mistake for a zero/default cap.
with tempfile.TemporaryDirectory() as tmp:
    partial_path = os.path.join(tmp, "partial-review.toml")
    open(partial_path, "w").write(open(config).read().replace("challenge  = 3\n", "", 1))
    result = subprocess.run(
        [sys.executable, resolver, "--config", partial_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
check("a schema-v1 config missing a required review cap is invalid to the resolver",
      result.returncode == 1
      and any(e["code"] == "invalid_config" and "review.standard" in e["detail"]
                  and "challenge" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    partial_path = os.path.join(tmp, "partial-strategy.toml")
    open(partial_path, "w").write(open(config).read().replace("min_agents   = 2\n", "", 1))
    result = subprocess.run(
        [sys.executable, resolver, "--config", partial_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 multi-agent strategy missing min_agents is invalid to the resolver",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "min_agents" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    topology_path = os.path.join(tmp, "wrong-topology-field.toml")
    open(topology_path, "w").write(open(config).read().replace(
        'delegation  = "optional"\nhuman_gates',
        'delegation  = "optional"\ncoordination = "parallel-when-independent"\nhuman_gates', 1,
    ))
    result = subprocess.run(
        [sys.executable, resolver, "--config", topology_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 topology-only strategy field is invalid to the resolver",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "coordination" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    endpoint_path = os.path.join(tmp, "wrong-tier-endpoint.toml")
    open(endpoint_path, "w").write(open(config).read().replace(
        '[tier.economy]\nescalate_to', '[tier.economy]\nendpoint = "local"\nescalate_to', 1,
    ))
    result = subprocess.run(
        [sys.executable, resolver, "--config", endpoint_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 non-local tier endpoint is invalid to the resolver",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "endpoint" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    impossible_path = os.path.join(tmp, "impossible-review.toml")
    open(impossible_path, "w").write(open(config).read().replace("min_rounds = 1\n", "min_rounds = 99\n", 1))
    result = subprocess.run(
        [sys.executable, resolver, "--config", impossible_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a schema-v1 review floor above its stage caps is invalid to the resolver",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "min_rounds" in e["detail"] for e in out["errors"]))

with tempfile.TemporaryDirectory() as tmp:
    branch_path = os.path.join(tmp, "branch.toml")
    merge_base_path = os.path.join(tmp, "merge-base.toml")
    branch_text = open(config).read()
    merge_base_text = branch_text.replace("schema_version = 1\n\n", "", 1)
    open(branch_path, "w").write(branch_text.replace("schema_version = 1", "schema_version = 2", 1))
    open(merge_base_path, "w").write(merge_base_text)
    result = subprocess.run(
        [sys.executable, resolver, "--config", branch_path, "--merge-base-config", merge_base_path],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("a legacy merge-base transition requires a valid schema-v1 branch config",
          result.returncode == 1
          and any(e["code"] == "invalid_config" and "schema_version=2" in e["detail"] for e in out["errors"]))

# absent config -> builtin (--config-unchanged: the branch's OWN copy is
# the one that's absent, not a merge-base extraction)
result = subprocess.run(
    [sys.executable, resolver, "--config", "/nonexistent/path/.devflow.toml", "--config-unchanged"],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("an absent config resolves from the built-in fallback",
      result.returncode == 0
      and out["selections"]["rigor"] == {"value": "standard", "source": "builtin"}
      and out["selections"]["strategy"] == {"value": "plan", "source": "builtin"}
      and out["review"]["challenge"] == 3 and out["review"]["review"] == 3
      and out["review"]["shepherd"] == 4 and out["review"]["min_rounds"] == 1
      and out["review"]["min_rounds_scope"] == ["challenge", "review"])


def run_absent(*args):
    result = subprocess.run(
        [sys.executable, resolver, "--config", "/nonexistent/path/.devflow.toml",
         "--config-unchanged", *args],
        capture_output=True, text=True,
    )
    return result.returncode, json.loads(result.stdout)


# absent config: an override/trusted-label/label are still parsed and
# applied over the built-in fallback, not short-circuited past.
code, out = run_absent("--override", "rigor=standard")
check("absent config + an override the built-in CAN honor resolves normally",
      code == 0 and out["selections"]["rigor"] == {"value": "standard", "source": "explicit"})

code, out = run_absent("--override", "rigor=deep")
check("absent config + an override the built-in CANNOT honor is a deterministic error",
      code == 1 and any(e["code"] == "invalid_override" for e in out["errors"]))

code, out = run_absent("--label", "rigor:deep", "--trusted-label", "rigor:deep")
check("absent config + a TRUSTED label the built-in cannot honor is also a deterministic error",
      code == 1 and any(e["code"] == "invalid_override" for e in out["errors"]))

code, out = run_absent("--label", "rigor:deep")
check("absent config + a plain (untrusted) label naming the same thing just warns and falls back",
      code == 0 and out["selections"]["rigor"] == {"value": "standard", "source": "builtin"}
      and any(w["code"] == "unknown_label" for w in out["warnings"]))

# a present config whose cross-references dangle must fail cleanly
# (invalid_config), never traceback.
DEVFLOW_TOML_TEXT = open(config).read()


def run_malformed(description, old, new, expect_substring, *extra_args):
    with tempfile.TemporaryDirectory() as tmp:
        bad_path = os.path.join(tmp, "bad.toml")
        assert old in DEVFLOW_TOML_TEXT, f"anchor text not found for {description!r}"
        open(bad_path, "w").write(DEVFLOW_TOML_TEXT.replace(old, new))
        result = subprocess.run(
            [sys.executable, resolver, "--config", bad_path, "--config-unchanged", *extra_args],
            capture_output=True, text=True,
        )
        try:
            out = json.loads(result.stdout)
        except json.JSONDecodeError:
            failures.append(f"{description}: not JSON — a traceback? stdout={result.stdout!r} stderr={result.stderr!r}")
            return
        ok = (
            result.returncode == 1
            and any(e["code"] == "invalid_config" and expect_substring in e["detail"] for e in out["errors"])
        )
        check(description, ok)


run_malformed(
    "default_rigor naming nothing -> invalid_config, not a traceback",
    'default_rigor    = "standard"', 'default_rigor    = "bogus-does-not-exist"',
    "names no [rigor.*] level",
)
run_malformed(
    "a rigor naming a missing review policy -> invalid_config, not a traceback",
    'review             = "none"', 'review             = "nonexistent-review-policy"',
    "names no [review.*] policy",
)
run_malformed(
    "a rigor_order entry with no matching table -> invalid_config, not a traceback",
    '"thorough", "deep"]', '"thorough", "nonexistent-level"]',
    "rigor_order is not a permutation of [rigor.*]",
)
# deep stays a defined [rigor.*] level but drops out of rigor_order entirely
# — resolve_rigor builds {name: i for i, name in enumerate(rigor_order)} and
# falls back to rank -1 for anything missing, so without this check "deep"
# would silently rank WEAKEST and lose a conflict it should win, rather than
# failing loudly. rigor:deep + rigor:standard is exactly that conflict.
run_malformed(
    "deep missing from rigor_order (but still defined) -> invalid_config, not a silent wrong winner",
    '"trivial", "minimal", "light", "standard", "thorough", "deep"]',
    '"trivial", "minimal", "light", "standard", "thorough"]',
    "rigor_order is not a permutation of [rigor.*]",
    "--label", "rigor:deep", "--label", "rigor:standard",
)
run_malformed(
    "a TOML date anywhere in [strategy.*]/[review.*]/[budget.*] -> invalid_config, not a TypeError",
    "human_gates  = []", "human_gates  = 2026-08-25",
    "no JSON equivalent",
)
run_malformed(
    "a non-finite max_usd (nan) -> invalid_config, not a value json.dumps() would mangle",
    '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2\n'
    'wall_clock_min        = 45\nallow_tier_escalation = false',
    '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2\n'
    'wall_clock_min        = 45\nallow_tier_escalation = false\nmax_usd               = nan',
    "no JSON equivalent",
)
run_malformed(
    "a rigor naming a missing budget profile -> invalid_config, not a traceback",
    'budget             = "trivial"', 'budget             = "nonexistent-budget-profile"',
    "names no [budget.*] profile",
)
run_malformed(
    "default_rigor as a list (not a scalar string) -> invalid_config, not a TypeError",
    'default_rigor    = "standard"', 'default_rigor    = ["standard"]',
    "must be a string",
)

# labels outside rigor:/strategy:/tier: are silently irrelevant — no warning
# of any kind, in either mode.
code, out = run("--label", "bug", "--label", "area:ci")
check("plain non-devflow labels produce zero warnings (interactive)",
      code == 0 and out["warnings"] == [])
code, out = run("--label", "bug", "--label", "area:ci", "--unattended")
check("... and zero warnings under --unattended too (no untrusted_label_ignored either)",
      code == 0 and out["warnings"] == [])

# --merge-base-config naming a path that does not exist is a caller/
# extraction ERROR, never a silent fallback to the built-in — genuine
# merge-base absence must be asserted explicitly.
result = subprocess.run(
    [sys.executable, resolver, "--config", config,
     "--merge-base-config", "/nonexistent/path/mb.toml"],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("--merge-base-config naming a nonexistent path is a deterministic error",
      result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

result = subprocess.run(
    [sys.executable, resolver, "--config", config, "--merge-base-absent"],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("--merge-base-absent explicitly confirms genuine absence and resolves cleanly",
      result.returncode == 0
      and out["config_source"] == "absent"
      and out["selections"]["rigor"] == {"value": "standard", "source": "builtin"}
      and not any(e["code"] == "invalid_input" for e in out["errors"]))

result = subprocess.run(
    [sys.executable, resolver, "--config", config,
     "--merge-base-config", config, "--merge-base-absent"],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("--merge-base-config and --merge-base-absent together is rejected",
      result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

# exactly one config-basis flag is REQUIRED — reading --config must never be
# a silent default. Zero flags, and all three at once, are both rejected.
result = subprocess.run([sys.executable, resolver, "--config", config], capture_output=True, text=True)
out = json.loads(result.stdout)
check("zero config-basis flags is rejected (no silent default)",
      result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

result = subprocess.run(
    [sys.executable, resolver, "--config", config, "--config-unchanged",
     "--merge-base-absent", "--merge-base-config", config],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("all three config-basis flags at once is also rejected",
      result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

# a present config that cannot even be parsed as TOML -> invalid_config, not
# a traceback.
with tempfile.TemporaryDirectory() as tmp:
    garbage_path = os.path.join(tmp, "garbage.toml")
    open(garbage_path, "w").write("this is [not valid toml at all {{{\n")
    result = subprocess.run(
        [sys.executable, resolver, "--config", garbage_path, "--config-unchanged"],
        capture_output=True, text=True,
    )
    try:
        out = json.loads(result.stdout)
    except json.JSONDecodeError:
        failures.append(f"garbage TOML: stdout was not JSON — a traceback? {result.stdout!r} {result.stderr!r}")
    else:
        check("a present config that fails to parse as TOML -> invalid_config, not a traceback",
              result.returncode == 1 and any(e["code"] == "invalid_config" for e in out["errors"]))

    # --config naming something that EXISTS but is not a regular file (here,
    # the temp directory itself) must never be silently treated the same as
    # a genuinely missing path — that would mask a caller/path mistake as
    # "this repo has no .devflow.toml".
    result = subprocess.run(
        [sys.executable, resolver, "--config", tmp, "--config-unchanged"],
        capture_output=True, text=True,
    )
    out = json.loads(result.stdout)
    check("--config naming a directory is invalid_input, never treated as absent",
          result.returncode == 1
          and any(e["code"] == "invalid_input" and "not a regular file" in e["detail"] for e in out["errors"])
          and out.get("config_source") != "absent")

# argparse-level failures (missing --config, an unrecognized flag, a missing
# option value) must ALSO honor the "always emit normalized JSON to stdout,
# exit 0 or 1" contract — never argparse's own default of a bare usage
# message on stderr and exit 2, which would look like a crash to a caller
# that only reads stdout.
result = subprocess.run([sys.executable, resolver, "--config-unchanged"], capture_output=True, text=True)
try:
    out = json.loads(result.stdout)
except json.JSONDecodeError:
    failures.append(
        f"missing --config: stdout was not JSON — argparse bypassed the contract? "
        f"returncode={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
    )
else:
    check("a missing required --config is invalid_input via stdout JSON, not a bare argparse exit",
          result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

result = subprocess.run(
    [sys.executable, resolver, "--config", config, "--config-unchanged", "--not-a-real-flag"],
    capture_output=True, text=True,
)
try:
    out = json.loads(result.stdout)
except json.JSONDecodeError:
    failures.append(
        f"unrecognized flag: stdout was not JSON — argparse bypassed the contract? "
        f"returncode={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
    )
else:
    check("an unrecognized flag is invalid_input via stdout JSON, not a bare argparse exit",
          result.returncode == 1 and any(e["code"] == "invalid_input" for e in out["errors"]))

if failures:
    print()
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)
print("devflow-resolve.py case table OK: rigor/strategy conflicts, incompatibility (topology-"
      "aware budget formula), tier overrides (order-independent strongest-wins), trust "
      "(--trusted-label / --unattended / requires_confirmation), explicit-vs-label, exactly-"
      "one-of-three config-basis flags required (--merge-base-config / --merge-base-absent / "
      "--config-unchanged — a missing --merge-base-config path errors; genuine absence needs "
      "--merge-base-absent; zero or multiple flags errors), absent-config (still honoring "
      "overrides/trusted-labels over the built-in floor), dangling-reference and unparseable "
      "configs (invalid_config, never a traceback), and the rigor:/strategy:/tier: namespace "
      "filter all resolve as documented")
PY

# The portable fixture corpus is separate from the resolver's regression
# table above. Run it against BOTH copies, so a consumer can verify its own
# config without relying on root-only dogfood values.
python3 scripts/test-devflow-conformance.py --repo "$PWD" --fixture "$CONFORMANCE_ROOT"
python3 scripts/test-devflow-conformance.py --repo "$PWD" --fixture "$CONFORMANCE_TEMPLATE" --config template/.devflow.toml
