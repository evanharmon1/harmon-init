#!/usr/bin/env bash
# test-devflow-config.sh — validate the Dev Loop round-cap config.
#
# `.devflow.toml` is the single source of the challenge/review/shepherd caps
# (AGENTS.md, "Round caps are resolved, not stated here"). Nothing at runtime
# parses it — an agent reads it — so a typo has no natural failure mode: it
# would simply make cap resolution undefined while every other gate stays
# green. test:dogfood-parity only proves the root and template copies are
# byte-identical, which two identically-broken files also satisfy.
#
# This checks the invariants the prose promises, on BOTH copies, plus the one
# cross-file invariant that byte-equality cannot see: every level must have a
# provisioned `rigor:<level>` label, or the documented label resolution path
# names something GitHub cannot apply.
#
# Root-only by design (no template twin): it guards what harmon-init SHIPS.
# A consumer retuning their own levels is editing their policy, the same way
# they may edit their AGENTS.md, and owes no gate here.
set -euo pipefail
cd "$(dirname "$0")/.."

# The provisioned rigor:* vocabulary lives in the label registry (per layer —
# the manifests legitimately diverge in other families, so each .devflow.toml
# is checked against its own layer's manifest).
LABEL_REGISTRY_ROOT="label-registry.json"
LABEL_REGISTRY_TEMPLATE="template/label-registry.json"
# The tier tables map families → model slugs, so tier validation resolves each
# slug against the agent registry (per layer, same as the label registry).
AGENT_REGISTRY_ROOT="agent-registry.json"
AGENT_REGISTRY_TEMPLATE="template/agent-registry.json"
# The fallback applies when .devflow.toml is ABSENT, so it cannot live in that
# file — it has to be stated in the policy, on both sides of the dogfood. That
# is two prose copies no other gate compares: test:dogfood-structure comes
# closest and deliberately checks headings and tasks, not paragraph bodies.
AGENTS_ROOT="AGENTS.md"
AGENTS_TEMPLATE="template/AGENTS.md.jinja"

for f in .devflow.toml template/.devflow.toml; do
    [ -f "$f" ] || {
        echo "FAIL: missing ${f}" >&2
        exit 1
    }
done

python3 - "$LABEL_REGISTRY_ROOT" "$LABEL_REGISTRY_TEMPLATE" \
    "$AGENT_REGISTRY_ROOT" "$AGENT_REGISTRY_TEMPLATE" "$AGENTS_ROOT" "$AGENTS_TEMPLATE" \
    .devflow.toml template/.devflow.toml <<'PY'
import json
import re
import sys
import tomllib

(registry_root, registry_template, agent_registry_root, agent_registry_template,
 agents_root, agents_template, *config_paths) = sys.argv[1:]
STAGES = ("challenge", "review", "shepherd")
# `min_rounds` is a floor on rounds actually run, not a cap — it gates only the
# empty-round instant exit (AGENTS.md, "Loop cap and exit"). It is required in
# every level, so both dogfood copies state it rather than relying on a default.
MIN_ROUNDS = "min_rounds"
KNOWN_KEYS = STAGES + (MIN_ROUNDS,)
# The floor is 2, not 1: a stage exits on two consecutive adjudicated-clean
# rounds, so a cap of 1 makes any single finding an instant escalation.
FLOOR = {"challenge": 2, "review": 2, "shepherd": 1}

def rigor_values(registry_path):
    # Only values the renderer actually seeds count: a retired or
    # provision:false rigor value has no live label, so a .devflow.toml level
    # named after one would be unselectable by the documented label path.
    with open(registry_path, "rb") as fh:
        manifest = json.load(fh)
    return {
        value["value"]
        for family in manifest.get("families", [])
        if family.get("family") == "rigor"
        and family.get("provision") is True
        and family.get("retired") is not True
        for value in family.get("values", [])
        if value.get("provision") is not False and value.get("retired") is not True
    }

provisioned_by_config = {
    ".devflow.toml": (registry_root, rigor_values(registry_root)),
    "template/.devflow.toml": (registry_template, rigor_values(registry_template)),
}

# ── Strategy axes (harmon-init#855, ADR 0006) ────────────────────────────────
# The tier ladder is fixed by ADR 0006 D2; `adaptive` is off-ladder. The rank is
# what makes "monotonic toward apex" checkable — and a strictly-increasing hop
# can never revisit a value, so monotonic ⇒ acyclic for free.
LADDER = ("local", "economy", "standard", "frontier", "apex")
LADDER_RANK = {tier: i for i, tier in enumerate(LADDER)}
RESERVED_TIER_KEYS = {"endpoint", "escalate_to"}
# The method conflict rank is fixed by ADR 0006 D4 and shipped in [method].rank
# so every consumer resolves conflicts identically — validation pins the shipped
# config to this exact order (most human oversight first).
METHOD_RANK = ("human-led", "plan-approved", "council", "orchestrate", "plan", "oneshot")


def _axis_values(registry_path, family_name):
    # Same provisioned-value gate as rigor_values(), for any label family: a
    # retired or provision:false value has no live label, so a config that names
    # it would be unselectable by the documented label path.
    with open(registry_path, "rb") as fh:
        manifest = json.load(fh)
    return {
        value["value"]
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
    # Families with a registered `-local` endpoint-variant harness (ADR 0005 D9):
    # a [tier.local] entry may only name one of these. The `-local` suffix alone
    # is not enough — an endpoint variant is a provider-rewired harness bound to
    # a fixed family (it repoints the runtime at a local endpoint). A future row
    # whose slug merely ends in `-local` without being provider-rewired must not
    # make its family look locally runnable, so require both properties.
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


axis_registries = {
    ".devflow.toml": (registry_root, agent_registry_root),
    "template/.devflow.toml": (registry_template, agent_registry_template),
}

failures = []

for path in config_paths:
    with open(path, "rb") as fh:
        try:
            cfg = tomllib.load(fh)
        except tomllib.TOMLDecodeError as exc:
            failures.append(f"{path}: not valid TOML — {exc}")
            continue

    levels = cfg.get("rigor")
    if not isinstance(levels, dict) or not levels:
        failures.append(f"{path}: no [rigor.*] levels defined")
        continue

    default = cfg.get("default_rigor")
    if not isinstance(default, str):
        failures.append(f"{path}: default_rigor is missing or not a string")
    elif default not in levels:
        failures.append(
            f"{path}: default_rigor={default!r} names no level "
            f"(have: {', '.join(sorted(levels))})"
        )

    shepherd_values = set()
    for name, caps in sorted(levels.items()):
        if not isinstance(caps, dict):
            failures.append(f"{path}: [rigor.{name}] is not a table")
            continue
        missing = [s for s in KNOWN_KEYS if s not in caps]
        if missing:
            failures.append(f"{path}: [rigor.{name}] missing {', '.join(missing)}")
        extra = [k for k in caps if k not in KNOWN_KEYS]
        if extra:
            failures.append(f"{path}: [rigor.{name}] has unknown key(s) {', '.join(extra)}")
        for stage in STAGES:
            value = caps.get(stage)
            if value is None:
                continue
            # bool is an int subclass in Python; `challenge = true` must fail.
            if not isinstance(value, int) or isinstance(value, bool):
                failures.append(f"{path}: rigor.{name}.{stage}={value!r} is not an integer")
            elif value < FLOOR[stage]:
                failures.append(
                    f"{path}: rigor.{name}.{stage}={value} is below the floor of {FLOOR[stage]}"
                )
        floor_value = caps.get(MIN_ROUNDS)
        if floor_value is not None:
            # bool is an int subclass in Python; `min_rounds = true` must fail.
            if not isinstance(floor_value, int) or isinstance(floor_value, bool):
                failures.append(
                    f"{path}: rigor.{name}.{MIN_ROUNDS}={floor_value!r} is not an integer"
                )
            elif floor_value < 1:
                failures.append(
                    f"{path}: rigor.{name}.{MIN_ROUNDS}={floor_value} is below 1 — a stage "
                    "always runs at least one round"
                )
            elif floor_value > 2:
                # A floor above 2 is unenforceable, not merely aggressive: two
                # consecutive adjudicated-clean rounds — including two empty
                # ones — exit the stage at round 2 whatever the floor says, so
                # accepting 3+ would document a budget no stage ever spends.
                # (2 <= every cap, so the floor can never exceed a cap either.)
                failures.append(
                    f"{path}: rigor.{name}.{MIN_ROUNDS}={floor_value} is above 2 — the "
                    "two-consecutive-clean exit ends a stage at round 2 whatever the "
                    "floor, so values above 2 cannot bind"
                )

        if isinstance(caps.get("shepherd"), int) and not isinstance(caps.get("shepherd"), bool):
            shepherd_values.add(caps["shepherd"])

        registry_path, provisioned = provisioned_by_config[path]
        if name not in provisioned:
            failures.append(
                f"{path}: level {name!r} has no rigor:{name} label in {registry_path} — "
                "the documented label resolution path cannot select it"
            )

    # shepherd bounds other people's findings, not self-generated work, so it
    # is fixed across levels by design (AGENTS.md). Catch a level-varying edit.
    if len(shepherd_values) > 1:
        failures.append(
            f"{path}: shepherd varies by level ({sorted(shepherd_values)}) — it is "
            "fixed by design; lowering it abandons unanswered reviews"
        )

    # ── Strategy axes: tier + method (harmon-init#855, ADR 0006) ─────────────
    label_registry_path, agent_registry_path = axis_registries[path]
    valid_tiers = _axis_values(label_registry_path, "tier")
    valid_methods = _axis_values(label_registry_path, "method")
    models_by_family = registry_models(agent_registry_path)
    local_families = local_harness_families(agent_registry_path)

    # The ADR-fixed ladder (plus `adaptive`) must be provisioned; a drifted
    # registry that dropped a rung would silently narrow what config can name.
    missing_ladder = [t for t in (*LADDER, "adaptive") if t not in valid_tiers]
    if missing_ladder:
        failures.append(
            f"{path}: tier value(s) {', '.join(missing_ladder)} are not provisioned "
            f"in {label_registry_path}"
        )

    dtier = cfg.get("default_tier")
    if not isinstance(dtier, str):
        failures.append(f"{path}: default_tier is missing or not a string")
    elif dtier == "adaptive":
        # `adaptive` is itself resolved by preflight, so it can never be the
        # concrete fallback (ADR 0006 D7).
        failures.append(
            f"{path}: default_tier='adaptive' is rejected — the default must be a "
            "concrete tier (ADR 0006 D7)"
        )
    elif dtier not in valid_tiers:
        failures.append(
            f"{path}: default_tier={dtier!r} names no provisioned tier "
            f"(have: {', '.join(sorted(valid_tiers))})"
        )

    dmethod = cfg.get("default_method")
    if not isinstance(dmethod, str):
        failures.append(f"{path}: default_method is missing or not a string")
    elif dmethod not in valid_methods:
        failures.append(
            f"{path}: default_method={dmethod!r} names no provisioned method "
            f"(have: {', '.join(sorted(valid_methods))})"
        )

    # The method rank is config-backed (specs/issue-strategy.md) and fixed
    # (ADR 0006 D4): [method].rank must equal the shipped order exactly, so a
    # consumer resolves conflicting method:* labels identically rather than from
    # divergent prose. Each value must also be a provisioned method label, and
    # default_method must sit somewhere in the rank.
    method_tbl = cfg.get("method")
    if not isinstance(method_tbl, dict):
        failures.append(f"{path}: [method] table is missing (needs the config-backed rank)")
    else:
        rank = method_tbl.get("rank")
        if not isinstance(rank, list) or not all(isinstance(v, str) for v in rank):
            failures.append(f"{path}: [method].rank must be a list of strings")
        else:
            if tuple(rank) != METHOD_RANK:
                failures.append(
                    f"{path}: [method].rank must be exactly {list(METHOD_RANK)} "
                    f"(ADR 0006 D4, fixed for identical resolution) — got {rank}"
                )
            unprovisioned = [v for v in rank if v not in valid_methods]
            if unprovisioned:
                failures.append(
                    f"{path}: [method].rank names unprovisioned method(s) "
                    f"{', '.join(unprovisioned)} in {label_registry_path}"
                )
            if isinstance(dmethod, str) and dmethod not in rank:
                failures.append(
                    f"{path}: default_method={dmethod!r} is not present in [method].rank"
                )

    tiers = cfg.get("tier")
    # This validator guards what harmon-init SHIPS, and harmon-init ships the
    # full ladder — so [tier] is required here, unconditionally. (ADR 0006 D7's
    # "absent sections are advisory-only" is a fallback for CONSUMER repos that
    # carry no such config; it never licenses harmon-init's own copy to drop the
    # tables, which byte-equality between the twins would not catch.)
    if tiers is None:
        failures.append(
            f"{path}: [tier] tables are missing — harmon-init ships the full ladder "
            "(ADR 0006 D2)"
        )
    elif not isinstance(tiers, dict):
        failures.append(f"{path}: [tier] is not a table")
        tiers = None
    if isinstance(tiers, dict):
        # This guard protects what harmon-init SHIPS: if it ships tier tables at
        # all, every concrete ladder tier must have one, or a tier:* label (or an
        # escalate_to hop) could resolve to a missing map. [tier] may be absent
        # entirely (ADR 0006 D7 advisory fallback) — but a partial ladder is a
        # silent gap, which is exactly what byte-equality between the twins
        # cannot see.
        missing_tables = [t for t in LADDER if t not in tiers]
        if missing_tables:
            failures.append(
                f"{path}: [tier] is missing table(s) for {', '.join(missing_tables)} — "
                "the shipped ladder must be complete (ADR 0006 D2)"
            )
        # default_tier must map to a defined table, mirroring default_rigor →
        # [rigor.*]: a non-adaptive default that resolves to no table has no
        # candidate to select.
        if isinstance(dtier, str) and dtier != "adaptive" and dtier not in tiers:
            failures.append(
                f"{path}: default_tier={dtier!r} has no [tier.{dtier}] table "
                f"(have: {', '.join(sorted(tiers))})"
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
                failures.append(
                    f"{path}: [tier.{name}] names no ladder tier (ladder: {' → '.join(LADDER)})"
                )

            # endpoint = "local" belongs to the local tier alone, and is required
            # there (ADR 0006 D2).
            endpoint = tbl.get("endpoint")
            if endpoint is not None and endpoint != "local":
                failures.append(
                    f'{path}: [tier.{name}] endpoint={endpoint!r} — only "local" is valid'
                )
            if name == "local" and endpoint != "local":
                failures.append(f'{path}: [tier.local] must set endpoint = "local" (ADR 0006 D2)')
            if name != "local" and endpoint is not None:
                failures.append(
                    f"{path}: [tier.{name}] sets endpoint but is not the local tier"
                )

            # escalate_to: referential + monotonic toward apex (⇒ acyclic).
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
                    # Referential: the hop must land on a defined table, not merely
                    # a name in the ladder — a chain that points at a dropped table
                    # dead-ends at a nonexistent config node (ADR 0006 D3).
                    if target not in tiers:
                        failures.append(
                            f"{path}: [tier.{name}] escalate_to → {target!r} has no "
                            f"[tier.{target}] table — the chain is not referential (ADR 0006 D3)"
                        )
                    if name in LADDER_RANK and LADDER_RANK[target] <= LADDER_RANK[name]:
                        failures.append(
                            f"{path}: [tier.{name}] escalate_to → {target!r} is not monotonic "
                            f"toward apex (it must rank above {name})"
                        )

            # ADR 0006 D2 pins the local hop specifically — tier:local escalates
            # to `economy`, not merely to some higher-ranked rung. Any other
            # monotonic target (or an empty chain) would pass the generic check
            # above yet break the stated contract, so pin it.
            if name == "local" and isinstance(esc, list) and esc != ["economy"]:
                failures.append(
                    f'{path}: [tier.local] escalate_to must be exactly ["economy"] '
                    f"(ADR 0006 D2), got {esc}"
                )

            # Every family → model slug must resolve; a local entry additionally
            # binds to a registered `-local` harness for that family.
            for fam, slug in tbl.items():
                if fam in RESERVED_TIER_KEYS:
                    continue
                if not isinstance(slug, str):
                    failures.append(f"{path}: [tier.{name}] {fam} model must be a string")
                    continue
                if fam not in models_by_family:
                    failures.append(
                        f"{path}: [tier.{name}] family {fam!r} is not in {agent_registry_path}"
                    )
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

FALLBACK_RE = re.compile(r"built-in (\d+ / \d+ / \d+)")
# The missing-key floor exists only in prose, so its parity is checked the
# same way as the caps: exactly one statement per layer, equal across layers.
FLOOR_FALLBACK_RE = re.compile(r"`min_rounds` floor of\s+(\d+) for any level that\s+does not define it")
fallbacks = {}
floor_fallbacks = {}
for path in (agents_root, agents_template):
    text = open(path).read()
    found = set(FALLBACK_RE.findall(text))
    if len(found) != 1:
        failures.append(
            f"{path}: expected exactly one 'built-in N / N / N' fallback, found "
            f"{sorted(found) if found else 'none'} — the resolution rule needs it"
        )
    else:
        fallbacks[path] = found.pop()
    floor_found = set(FLOOR_FALLBACK_RE.findall(text))
    if len(floor_found) != 1:
        failures.append(
            f"{path}: expected exactly one 'min_rounds floor of N wherever no level "
            f"defines one' fallback, found {sorted(floor_found) if floor_found else 'none'}"
        )
    else:
        floor_fallbacks[path] = floor_found.pop()
if len(set(fallbacks.values())) > 1:
    failures.append(
        "the fallback caps disagree across the dogfood: "
        + "; ".join(f"{p} says {v}" for p, v in sorted(fallbacks.items()))
        + " — root and generated agents would use different caps"
    )
if len(set(floor_fallbacks.values())) > 1:
    failures.append(
        "the fallback min_rounds floor disagrees across the dogfood: "
        + "; ".join(f"{p} says {v}" for p, v in sorted(floor_fallbacks.items()))
        + " — root and generated agents would use different exit rules"
    )
for path, value in sorted(floor_fallbacks.items()):
    # Same range as configured min_rounds: 1 or 2. A fallback outside it would
    # hand absent-file/legacy repos an exit rule no shipped level may state.
    if not value.isdigit() or not 1 <= int(value) <= 2:
        failures.append(
            f"{path}: fallback min_rounds floor {value} is outside the supported "
            "range 1-2"
        )

if failures:
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)

with open(config_paths[0], "rb") as fh:
    cfg = tomllib.load(fh)
levels = cfg["rigor"]
summary = "; ".join(
    f"{n}={t['challenge']}/{t['review']}/{t['shepherd']} (min {t['min_rounds']})"
    for n, t in sorted(levels.items())
)
print(f"devflow config OK: default={cfg['default_rigor']} — {summary}")
print("  (challenge/review/shepherd + min_rounds; both copies valid, every level has a label)")
tier_summary = ", ".join(
    f"{t}[{','.join(sorted(k for k in tbl if k not in RESERVED_TIER_KEYS))}]"
    for t, tbl in sorted(cfg.get("tier", {}).items(), key=lambda kv: LADDER_RANK.get(kv[0], 99))
)
print(
    f"tier/method OK: default_tier={cfg.get('default_tier')} "
    f"default_method={cfg.get('default_method')} — {tier_summary}"
)
print("  (slugs resolve; escalate_to referential/acyclic/monotonic; local binds a -local harness)")
PY
