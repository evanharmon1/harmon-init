#!/usr/bin/env python3
"""devflow-resolve.py — minimal reference resolver for .devflow.toml.

Resolves a rigor + strategy execution policy the way AGENTS.md's Dev Loop
describes and ADR 0007 (docs/decisions/0007-rigor-and-strategy-axes.md)
records: explicit operator instruction > rigor:*/strategy:* labels >
default_rigor/default_strategy > the built-in fallback (used only when
.devflow.toml is entirely absent).

This is a ROOT-ONLY reference implementation, not the versioned,
cross-consumer conformance contract — that is harmon-init#1048
(schema_version, language-neutral fixtures, a fixture corpus). It exists so
scripts/test-devflow-config.sh has something executable to run the
resolution-order case table against, and so an agent or Foreman has a
starting point rather than re-deriving the algorithm from prose each time.

Usage:
    devflow-resolve.py --config .devflow.toml \\
        [--merge-base-config PATH] \\
        [--label rigor:deep] [--label strategy:council] \\
        [--label tier:economy] [--label tier:implementer:economy] \\
        [--override rigor=deep] [--override tier.implementer=economy] \\
        [--unattended]

Prints one normalized JSON object to stdout and exits 0 if resolution
completed with no errors (warnings are fine), 1 otherwise. Errors and
warnings are always both present in the output (possibly empty lists) so a
caller never needs to guess whether the key exists.

Inputs, precisely:
  --config PATH             the branch's copy of .devflow.toml.
  --merge-base-config PATH  when given, THIS is the copy actually read —
                             the merge-base rule (AGENTS.md, "When the
                             change under review edits .devflow.toml...").
                             --config is still recorded, unread.
  --label FAMILY:VALUE      a rigor:*/strategy:*/tier:* label present on the
                             issue or PR, repeatable. tier:<value> is
                             unqualified (implementer only); tier:<role>:
                             <value> is scoped. Anything else (a label with
                             no devflow-relevant prefix) is silently
                             irrelevant, not a warning.
  --override KEY=VALUE      an explicit, attributable operator instruction,
                             repeatable. KEY is one of: rigor, strategy,
                             tier (unqualified, implementer only),
                             tier.orchestrator, tier.implementer,
                             tier.reviewer.
  --unattended               changes only how an ambiguous strategy
                             conflict resolves: an interactive run reports
                             an error and asks; an unattended run falls
                             back to default_strategy with a warning.
"""
import argparse
import hashlib
import json
import os
import sys
import tomllib

LADDER = ("local", "economy", "standard", "frontier", "apex")
ROLES = ("orchestrator", "implementer", "reviewer")

# Used only when .devflow.toml is entirely absent (AGENTS.md's built-in
# fallback sentence, kept in lockstep with it and with [review.standard] by
# scripts/test-devflow-config.sh — this script does not re-derive it from a
# config that, by definition, is not there to read).
BUILTIN_RIGOR = "standard"
BUILTIN_STRATEGY = "plan"
BUILTIN_REVIEW = {"challenge": 3, "review": 3, "shepherd": 4, "min_rounds": 1}


def load_config(path):
    """Returns (cfg, sha256_hex) or (None, None) if path does not exist."""
    if not os.path.isfile(path):
        return None, None
    with open(path, "rb") as fh:
        raw = fh.read()
    return tomllib.loads(raw.decode("utf-8")), hashlib.sha256(raw).hexdigest()


def parse_labels(raw_labels, warnings):
    rigor_labels = []
    strategy_labels = []
    tier_unqualified = None
    tier_scoped = {}
    for raw in raw_labels:
        parts = raw.split(":")
        if parts[0] == "rigor" and len(parts) == 2:
            rigor_labels.append(parts[1])
        elif parts[0] == "strategy" and len(parts) == 2:
            strategy_labels.append(parts[1])
        elif parts[0] == "tier" and len(parts) == 2:
            tier_unqualified = parts[1]  # last one wins if repeated
        elif parts[0] == "tier" and len(parts) == 3 and parts[1] in ROLES:
            tier_scoped[parts[1]] = parts[2]
        else:
            warnings.append({
                "code": "unknown_label",
                "detail": f"{raw!r} is not a recognized rigor:/strategy:/tier: label, ignored",
            })
    return rigor_labels, strategy_labels, tier_unqualified, tier_scoped


def parse_overrides(raw_overrides, errors):
    explicit_rigor = None
    explicit_strategy = None
    tier_unqualified = None
    tier_scoped = {}
    for raw in raw_overrides:
        if "=" not in raw:
            errors.append({"code": "invalid_override", "detail": f"{raw!r} is not key=value"})
            continue
        key, value = raw.split("=", 1)
        if key == "rigor":
            explicit_rigor = value
        elif key == "strategy":
            explicit_strategy = value
        elif key == "tier":
            tier_unqualified = value
        elif key in ("tier.orchestrator", "tier.implementer", "tier.reviewer"):
            tier_scoped[key.split(".", 1)[1]] = value
        else:
            errors.append({"code": "invalid_override", "detail": f"unknown override key {key!r}"})
    return explicit_rigor, explicit_strategy, tier_unqualified, tier_scoped


def validate_tier_values(unqualified, scoped, *, fatal, bucket):
    """Drops (fatal=False, bucket=warnings) or errors on (fatal=True,
    bucket=errors) any tier value that is not a concrete ladder rung —
    `adaptive` included, since a role always resolves to a concrete rung or
    not at all (ADR 0006 D7, re-scoped by ADR 0007 D2/D5 from `default_tier`
    to every role tier and override target)."""
    if unqualified is not None and unqualified not in LADDER:
        msg = f"tier={unqualified!r} is not a concrete ladder tier ({', '.join(LADDER)})"
        bucket.append({"code": "invalid_override" if fatal else "unknown_label", "detail": msg})
        unqualified = None
    for role in list(scoped):
        if scoped[role] not in LADDER:
            msg = f"tier.{role}={scoped[role]!r} is not a concrete ladder tier ({', '.join(LADDER)})"
            bucket.append({"code": "invalid_override" if fatal else "unknown_label", "detail": msg})
            del scoped[role]
    return unqualified, scoped


def merge_tier_overrides(unqualified, scoped):
    """Unqualified targets the implementer; a scoped override for the same
    role is more specific and wins (see the comment on the announcement
    line resolution order in .devflow.toml — this ordering is this
    resolver's own documented choice, not independently specified)."""
    merged = {}
    if unqualified is not None:
        merged["implementer"] = unqualified
    merged.update(scoped)
    return merged


def resolve_rigor(cfg, rigor_labels, explicit_rigor, warnings, errors):
    levels = cfg["rigor"]
    order = cfg["rigor_order"]
    rank = {name: i for i, name in enumerate(order)}
    if explicit_rigor is not None:
        if explicit_rigor not in levels:
            errors.append({
                "code": "invalid_override",
                "detail": f"rigor={explicit_rigor!r} names no [rigor.*] level",
            })
            return None, None
        return explicit_rigor, "explicit"
    known = [v for v in rigor_labels if v in levels]
    for v in rigor_labels:
        if v not in levels:
            warnings.append({"code": "unknown_label", "detail": f"rigor:{v} names no [rigor.*] level, ignored"})
    if known:
        return max(known, key=lambda v: rank.get(v, -1)), "label"
    return cfg.get("default_rigor"), "default"


def resolve_strategy(cfg, strategy_labels, explicit_strategy, unattended, warnings, errors):
    strategies = cfg["strategy"]
    if explicit_strategy is not None:
        if explicit_strategy not in strategies:
            errors.append({
                "code": "invalid_override",
                "detail": f"strategy={explicit_strategy!r} names no [strategy.*] value",
            })
            return None, None
        return explicit_strategy, "explicit"
    known = sorted({v for v in strategy_labels if v in strategies})
    for v in strategy_labels:
        if v not in strategies:
            warnings.append({"code": "unknown_label", "detail": f"strategy:{v} names no [strategy.*] value, ignored"})
    if len(known) > 1:
        if unattended:
            warnings.append({
                "code": "ambiguous_strategy",
                "detail": f"labels {known} are ambiguous (no rank) — defaulted to default_strategy",
            })
            return cfg.get("default_strategy"), "default"
        errors.append({
            "code": "ambiguous_strategy",
            "detail": f"labels {known} are ambiguous — strategies are not ranked; "
                      "an attributable operator instruction must pick one",
        })
        return None, None
    if len(known) == 1:
        return known[0], "label"
    return cfg.get("default_strategy"), "default"


def resolve_tiers(rigor_tbl, overrides_label, overrides_explicit):
    tiers = {}
    for role in ROLES:
        profile_value = rigor_tbl[f"{role}_tier"]
        value, source = profile_value, "profile"
        if role in overrides_label:
            value, source = overrides_label[role], "label"
        if role in overrides_explicit:
            value, source = overrides_explicit[role], "explicit"
        tiers[role] = {"value": value, "source": source, "off_profile": value != profile_value}
    return tiers


def check_incompatible(cfg, rigor_name, strategy_name, errors):
    if rigor_name is None or strategy_name is None:
        return
    strategy_tbl = cfg["strategy"][strategy_name]
    min_agents = strategy_tbl.get("min_agents")
    if min_agents is None:
        return
    budget_name = cfg["rigor"][rigor_name]["budget"]
    budget = cfg["budget"][budget_name]
    if min_agents > budget["max_agent_runs"] or min_agents > budget["max_parallel_agents"]:
        errors.append({
            "code": "incompatible_strategy",
            "detail": (
                f"strategy {strategy_name!r} needs min_agents={min_agents}, but rigor "
                f"{rigor_name!r}'s budget {budget_name!r} allows "
                f"max_agent_runs={budget['max_agent_runs']}, "
                f"max_parallel_agents={budget['max_parallel_agents']}"
            ),
        })


def emit(output, errors):
    print(json.dumps(output, indent=2, sort_keys=True))
    sys.exit(1 if errors else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--merge-base-config")
    ap.add_argument("--label", action="append", default=[], dest="labels")
    ap.add_argument("--override", action="append", default=[], dest="overrides")
    ap.add_argument("--unattended", action="store_true")
    args = ap.parse_args()

    warnings = []
    errors = []

    read_path = args.merge_base_config if args.merge_base_config else args.config
    config_source = "merge-base" if args.merge_base_config else "branch"

    cfg, digest = load_config(read_path)
    if cfg is None:
        emit({
            "config_path": read_path,
            "config_source": "absent",
            "config_sha256": None,
            "selections": {
                "rigor": {"value": BUILTIN_RIGOR, "source": "builtin"},
                "strategy": {"value": BUILTIN_STRATEGY, "source": "builtin"},
            },
            "review": {**BUILTIN_REVIEW, "policy": BUILTIN_RIGOR, "source": "builtin"},
            "tiers": {role: {"value": None, "source": "builtin", "off_profile": False} for role in ROLES},
            "budget": None,
            "strategy_fields": None,
            "disclosure": {"off_default": False, "off_profile": False, "same_family_reviewer": False},
            "warnings": warnings + [{
                "code": "config_absent",
                "detail": f"{read_path} does not exist — resolved from the built-in fallback",
            }],
            "errors": errors,
        }, errors)

    required_tables = ("rigor", "strategy", "review", "budget")
    missing = [t for t in required_tables if t not in cfg]
    if missing or "default_rigor" not in cfg or "default_strategy" not in cfg:
        detail_bits = missing + (["default_rigor"] if "default_rigor" not in cfg else []) + (
            ["default_strategy"] if "default_strategy" not in cfg else [])
        errors.append({
            "code": "invalid_config",
            "detail": f"{read_path}: missing required key(s)/table(s): {', '.join(detail_bits)}",
        })
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "warnings": warnings, "errors": errors}, errors)

    rigor_labels, strategy_labels, tier_label_unqualified, tier_label_scoped = parse_labels(args.labels, warnings)
    explicit_rigor, explicit_strategy, tier_override_unqualified, tier_override_scoped = parse_overrides(
        args.overrides, errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "warnings": warnings, "errors": errors}, errors)

    tier_label_unqualified, tier_label_scoped = validate_tier_values(
        tier_label_unqualified, tier_label_scoped, fatal=False, bucket=warnings)
    tier_override_unqualified, tier_override_scoped = validate_tier_values(
        tier_override_unqualified, tier_override_scoped, fatal=True, bucket=errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "warnings": warnings, "errors": errors}, errors)

    rigor_name, rigor_source = resolve_rigor(cfg, rigor_labels, explicit_rigor, warnings, errors)
    if rigor_name is None:
        emit({
            "config_path": read_path, "config_source": config_source, "config_sha256": digest,
            "selections": {"rigor": {"value": None, "source": rigor_source}},
            "warnings": warnings, "errors": errors,
        }, errors)

    strategy_name, strategy_source = resolve_strategy(
        cfg, strategy_labels, explicit_strategy, args.unattended, warnings, errors)

    check_incompatible(cfg, rigor_name, strategy_name, errors)

    rigor_tbl = cfg["rigor"][rigor_name]
    review_tbl = cfg["review"][rigor_tbl["review"]]
    budget_name = rigor_tbl["budget"]
    budget_tbl = cfg["budget"][budget_name]
    strategy_tbl = cfg["strategy"][strategy_name] if strategy_name is not None else None

    overrides_label = merge_tier_overrides(tier_label_unqualified, tier_label_scoped)
    overrides_explicit = merge_tier_overrides(tier_override_unqualified, tier_override_scoped)
    tiers = resolve_tiers(rigor_tbl, overrides_label, overrides_explicit)

    off_default = rigor_name != cfg.get("default_rigor") or (
        strategy_name is not None and strategy_name != cfg.get("default_strategy"))
    off_profile = any(t["off_profile"] for t in tiers.values())

    emit({
        "config_path": read_path,
        "config_source": config_source,
        "config_sha256": digest,
        "selections": {
            "rigor": {"value": rigor_name, "source": rigor_source},
            "strategy": {"value": strategy_name, "source": strategy_source},
        },
        "review": {**review_tbl, "policy": rigor_tbl["review"], "source": "profile"},
        "tiers": tiers,
        "budget": {**budget_tbl, "name": budget_name, "source": "profile"},
        "strategy_fields": strategy_tbl,
        "disclosure": {
            "off_default": off_default,
            "off_profile": off_profile,
            # Full reviewer-harness family selection depends on which
            # harnesses are actually configured/authenticated in the
            # consuming environment, which this reference resolver has no
            # way to know — that is consumer-specific (docs/guides/devflow.md
            # covers the tier-floor/harness/family-diversity split) and out
            # of scope for a config-only resolver. Always false here; a
            # fuller resolver (#1048) that is handed actual configured
            # families could compute this for real.
            "same_family_reviewer": False,
        },
        "warnings": warnings,
        "errors": errors,
    }, errors)


if __name__ == "__main__":
    main()
