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

for f in .devflow.toml template/.devflow.toml; do
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
    "$DEVFLOW_GUIDE" .devflow.toml template/.devflow.toml <<'PY'
import json
import re
import sys
import tomllib

(registry_root, registry_template, agent_registry_root, agent_registry_template,
 agents_root, agents_template, devflow_guide, *config_paths) = sys.argv[1:]

failures = []

# ── Fixed vocabulary (ADR 0007) ─────────────────────────────────────────────
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
KNOWN_INCOMPATIBLE = {("council", "trivial")}


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


def harness_role_coverage(agent_registry_path):
    # role -> whether >=1 harness declares it.
    with open(agent_registry_path, "rb") as fh:
        reg = json.load(fh)
    covered = {"orchestrate": False, "implement": False, "review": False}
    for harness in reg.get("harnesses", []):
        for role in harness.get("roles", []):
            if role in covered:
                covered[role] = True
    return covered


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

    label_registry_path, agent_registry_path = registries_by_config[path]
    rigor_family = family_values(label_registry_path, "rigor")
    strategy_family = family_values(label_registry_path, "strategy")
    models_by_family = registry_models(agent_registry_path)
    local_families = local_harness_families(agent_registry_path)

    # The provisioned tier vocabulary must EQUAL the ADR-fixed ladder plus
    # `adaptive` — both directions, unchanged from before ADR 0007 ("tier
    # maps resolve against agent-registry as today"). A missing rung
    # silently narrows what a [rigor.*] role tier or an override may name; an
    # EXTRA value (a future `tier:ultra`) provisions a label with no ladder
    # position, table, or rank, leaving strongest-wins resolution undefined.
    valid_tiers = set(family_values(label_registry_path, "tier"))
    expected_tiers = set(LADDER) | {"adaptive"}
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
            f"match the ADR-fixed ladder — {'; '.join(detail)}"
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

        review_ref = tbl.get("review")
        if review_ref not in reviews:
            failures.append(f"{path}: [rigor.{name}].review={review_ref!r} names no [review.*] policy")

        budget_ref = tbl.get("budget")
        if budget_ref not in budgets:
            failures.append(f"{path}: [rigor.{name}].budget={budget_ref!r} names no [budget.*] profile")

        role_tiers = {}
        for role in ("orchestrator_tier", "implementer_tier", "reviewer_tier"):
            value = tbl.get(role)
            if value not in LADDER:
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
        elif len(stage_values) == len(STAGE_KEYS):
            ceiling = min(stage_values.values())
            if min_rounds > ceiling:
                failures.append(
                    f"{path}: review.{name}.min_rounds={min_rounds} exceeds "
                    f"min(challenge, review, shepherd)={ceiling} for this policy"
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
    for sname, stbl in strategies.items():
        min_agents = stbl.get("min_agents") if isinstance(stbl, dict) else None
        if not isinstance(min_agents, int) or isinstance(min_agents, bool):
            continue
        for rname, rtbl in levels.items():
            if not isinstance(rtbl, dict):
                continue
            budget_name = rtbl.get("budget")
            budget_tbl = budgets.get(budget_name)
            if not isinstance(budget_tbl, dict):
                continue
            runs = budget_tbl.get("max_agent_runs")
            parallel = budget_tbl.get("max_parallel_agents")
            incompatible = (isinstance(runs, int) and min_agents > runs) or (
                isinstance(parallel, int) and min_agents > parallel
            )
            documented = (sname, rname) in KNOWN_INCOMPATIBLE
            if incompatible and not documented:
                failures.append(
                    f"{path}: strategy {sname!r} (min_agents={min_agents}) is incompatible with "
                    f"rigor {rname!r}'s budget {budget_name!r} (max_agent_runs={runs}, "
                    f"max_parallel_agents={parallel}) but is not in KNOWN_INCOMPATIBLE"
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

    # ── agent-registry role coverage ────────────────────────────────────
    coverage = harness_role_coverage(agent_registry_path)
    for role, has_any in coverage.items():
        if not has_any:
            failures.append(
                f"{path}: no harness in {agent_registry_path} declares the {role!r} role — "
                "resolution could never staff that role"
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
    result = subprocess.run(
        [sys.executable, resolver, "--config", config, *args],
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

code, out = run("--label", "strategy:plan", "--label", "strategy:orchestrate", "--unattended")
check("two strategy labels default with a warning, once unattended",
      code == 0
      and out["selections"]["strategy"] == {"value": default_strategy, "source": "default"}
      and any(w["code"] == "ambiguous_strategy" for w in out["warnings"]))

# council x trivial -> incompatible, reported not substituted
code, out = run("--override", "rigor=trivial", "--override", "strategy=council")
check("council under trivial is a reported incompatibility",
      code == 1 and any(e["code"] == "incompatible_strategy" for e in out["errors"]))

# tier:implementer:economy under standard -> refines + off_profile disclosed
code, out = run("--override", "rigor=standard", "--label", "tier:implementer:economy")
check("scoped tier:implementer:economy refines just the implementer, off-profile disclosed",
      code == 0
      and out["tiers"]["implementer"] == {"value": "economy", "source": "label", "off_profile": True}
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

# absent config -> builtin
result = subprocess.run(
    [sys.executable, resolver, "--config", "/nonexistent/path/.devflow.toml"],
    capture_output=True, text=True,
)
out = json.loads(result.stdout)
check("an absent config resolves from the built-in fallback",
      result.returncode == 0
      and out["selections"]["rigor"] == {"value": "standard", "source": "builtin"}
      and out["selections"]["strategy"] == {"value": "plan", "source": "builtin"}
      and out["review"]["challenge"] == 3 and out["review"]["review"] == 3
      and out["review"]["shepherd"] == 4 and out["review"]["min_rounds"] == 1)

if failures:
    print()
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)
print("devflow-resolve.py case table OK: rigor/strategy conflicts, incompatibility, tier "
      "overrides, explicit-vs-label, merge-base, and absent-config all resolve as documented")
PY
