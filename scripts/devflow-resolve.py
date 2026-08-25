#!/usr/bin/env python3
"""devflow-resolve.py — minimal reference resolver for .devflow.toml.

Resolves a rigor + strategy execution policy the way AGENTS.md's Dev Loop
describes and ADR 0007 (docs/decisions/0007-rigor-and-strategy-axes.md)
records: explicit operator instruction > rigor:*/strategy:* labels >
default_rigor/default_strategy > the built-in fallback (used only when
.devflow.toml is entirely absent).

Trust is a CONSUMER input, not something this resolver infers: --label is
UNVERIFIED by default, and --trusted-label marks the subset whose provenance
the caller has already verified against its own trusted-actor configuration
(ADR 0006 D6). Unattended automation may act only on trusted labels (D6.1) —
every other --label is ignored, with a warning naming it, and falls back to
the default. An interactive session may still act on any --label (advisory,
as before trust existed as a concept here), but an off-default result driven
by an untrusted one sets requires_confirmation, so the operator is asked
before it is used rather than applied silently (D6.2). An --override is
always trusted by definition — it is the explicit, attributable instruction
channel ADR 0006 D5 describes, never repository content.

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
        [--trusted-label rigor:deep] \\
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
                             issue or PR, repeatable — UNVERIFIED provenance.
                             tier:<value> is unqualified (implementer only);
                             tier:<role>:<value> is scoped (role one of
                             orchestrator/implementer/reviewer). Multiple
                             tier labels that land on the same role — any mix
                             of the unqualified and scoped forms — resolve
                             strongest-wins by ladder rank, regardless of
                             input order: a conflict can only ever raise the
                             tier, mirroring how a rigor conflict can only
                             ever buy more depth (ADR 0006 D5). Anything else
                             (a label with no devflow-relevant prefix) is
                             silently irrelevant, not a warning.
  --trusted-label F:V       the subset of labels (same FAMILY:VALUE forms as
                             --label) whose provenance the CALLER has already
                             verified against its own trusted-actor
                             configuration (ADR 0006 D6) — repeatable, and
                             need not literally duplicate a --label entry.
                             Under --unattended, ONLY trusted labels
                             participate in resolution. In interactive mode
                             every --label still applies as before;
                             --trusted-label instead controls whether an
                             off-default result sets requires_confirmation.
  --override KEY=VALUE      an explicit, attributable operator instruction,
                             repeatable — always trusted by definition
                             (ADR 0006 D5: an explicit instruction arrives on
                             the operator's attributable channel and is never
                             repository content). KEY is one of: rigor,
                             strategy, tier (unqualified, implementer only),
                             tier.orchestrator, tier.implementer,
                             tier.reviewer.
  --unattended               two effects, both from ADR 0006 D6.1: an
                             ambiguous strategy conflict falls back to
                             default_strategy with a warning instead of
                             erroring, AND only --trusted-label values are
                             applied at all — every plain --label is ignored
                             (with a warning naming it) and falls back to the
                             default instead.
"""
import argparse
import hashlib
import json
import os
import sys
import tomllib

LADDER = ("local", "economy", "standard", "frontier", "apex")
LADDER_RANK = {tier: i for i, tier in enumerate(LADDER)}
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


def filter_labels_by_trust(raw_labels, trusted_labels, *, unattended, warnings):
    """Returns the effective raw label list resolution should actually use.

    Interactive: every --label still applies (trust only affects
    requires_confirmation later) — --trusted-label entries are unioned in so
    a caller may assert trust for a label it did not separately re-pass via
    --label. Unattended (ADR 0006 D6.1): ONLY trusted labels apply; every
    other --label is dropped with a warning naming it, and --trusted-label
    entries are still unioned in for the same reason as above.
    """
    trusted_set = set(trusted_labels)
    if unattended:
        effective = [raw for raw in raw_labels if raw in trusted_set]
        for raw in raw_labels:
            if raw not in trusted_set:
                warnings.append({
                    "code": "untrusted_label_ignored",
                    "detail": f"{raw!r} ignored under --unattended (no matching --trusted-label) "
                              "— falls back to the default",
                })
    else:
        effective = list(raw_labels)
    for raw in trusted_labels:
        if raw not in effective:
            effective.append(raw)
    return effective


def _add_tier_candidate(tier_candidates, role, value, raw, warnings):
    if value in LADDER:
        tier_candidates[role].append(value)
    else:
        warnings.append({
            "code": "unknown_label",
            "detail": f"{raw!r} is not a concrete ladder tier ({', '.join(LADDER)}), ignored",
        })


def parse_labels(raw_labels, warnings):
    """Returns (rigor_labels, strategy_labels, tier_candidates).

    tier_candidates is {role: [valid ladder values]} — an unqualified
    tier:<value> label folds into "implementer"; a scoped tier:<role>:
    <value> label folds into its named role. A label naming something that
    is not a concrete ladder tier is dropped with a warning HERE, before the
    strongest-wins reduction, so an invalid candidate can never "win" by
    being the only one left.
    """
    rigor_labels = []
    strategy_labels = []
    tier_candidates = {role: [] for role in ROLES}
    for raw in raw_labels:
        parts = raw.split(":")
        if parts[0] == "rigor" and len(parts) == 2:
            rigor_labels.append(parts[1])
        elif parts[0] == "strategy" and len(parts) == 2:
            strategy_labels.append(parts[1])
        elif parts[0] == "tier" and len(parts) == 2:
            _add_tier_candidate(tier_candidates, "implementer", parts[1], raw, warnings)
        elif parts[0] == "tier" and len(parts) == 3 and parts[1] in ROLES:
            _add_tier_candidate(tier_candidates, parts[1], parts[2], raw, warnings)
        else:
            warnings.append({
                "code": "unknown_label",
                "detail": f"{raw!r} is not a recognized rigor:/strategy:/tier: label, ignored",
            })
    return rigor_labels, strategy_labels, tier_candidates


def strongest_tier_per_role(tier_candidates):
    """Labels are an unordered set — GitHub attaches no meaning to which was
    applied first — so multiple tier labels landing on one role must resolve
    identically regardless of input order. Strongest-by-ladder-rank is the
    same conflict rule rigor itself uses (ADR 0006 D5: "a label only ever
    buys more capability or oversight"): a conflict can only ever raise the
    tier, never silently weaken it by depending on which label happened to
    be seen, or applied, last."""
    return {
        role: max(values, key=lambda v: LADDER_RANK[v])
        for role, values in tier_candidates.items()
        if values
    }


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


def validate_override_tier_values(unqualified, scoped, errors):
    """Overrides are explicit and attributable, so an invalid tier value here
    is a hard error (never a silently-dropped candidate the way a bad label
    is) — `adaptive` included, since a role always resolves to a concrete
    rung or not at all (ADR 0006 D7, re-scoped by ADR 0007 D2/D5 from
    `default_tier` to every role tier and override target)."""
    if unqualified is not None and unqualified not in LADDER:
        errors.append({
            "code": "invalid_override",
            "detail": f"tier={unqualified!r} is not a concrete ladder tier ({', '.join(LADDER)})",
        })
        unqualified = None
    for role in list(scoped):
        if scoped[role] not in LADDER:
            errors.append({
                "code": "invalid_override",
                "detail": f"tier.{role}={scoped[role]!r} is not a concrete ladder tier ({', '.join(LADDER)})",
            })
            del scoped[role]
    return unqualified, scoped


def merge_tier_overrides(unqualified, scoped):
    """Unqualified targets the implementer; a scoped override for the same
    role is more specific and wins. Overrides are a single attributable
    operator's own instructions (not competing votes the way labels are), so
    this stays most-specific-wins rather than strongest-wins-by-rank — this
    ordering is this resolver's own documented choice, not independently
    specified."""
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


def label_drove_untrusted_off_default(rigor_name, rigor_source, cfg, trusted_set):
    return (
        rigor_source == "label"
        and rigor_name != cfg.get("default_rigor")
        and f"rigor:{rigor_name}" not in trusted_set
    )


def strategy_drove_untrusted_off_default(strategy_name, strategy_source, cfg, trusted_set):
    return (
        strategy_source == "label"
        and strategy_name is not None
        and strategy_name != cfg.get("default_strategy")
        and f"strategy:{strategy_name}" not in trusted_set
    )


def tier_drove_untrusted_off_profile(role, tier, trusted_set):
    if tier["source"] != "label" or not tier["off_profile"]:
        return False
    raw_scoped = f"tier:{role}:{tier['value']}"
    raw_unqualified = f"tier:{tier['value']}" if role == "implementer" else None
    trusted = raw_scoped in trusted_set or (raw_unqualified is not None and raw_unqualified in trusted_set)
    return not trusted


def emit(output, errors):
    print(json.dumps(output, indent=2, sort_keys=True))
    sys.exit(1 if errors else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--merge-base-config")
    ap.add_argument("--label", action="append", default=[], dest="labels")
    ap.add_argument("--trusted-label", action="append", default=[], dest="trusted_labels")
    ap.add_argument("--override", action="append", default=[], dest="overrides")
    ap.add_argument("--unattended", action="store_true")
    args = ap.parse_args()

    warnings = []
    errors = []
    trusted_set = set(args.trusted_labels)

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
            "disclosure": {"off_default": False, "off_profile": False, "same_family_reviewer": None},
            "requires_confirmation": False,
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
              "requires_confirmation": False, "warnings": warnings, "errors": errors}, errors)

    effective_labels = filter_labels_by_trust(
        args.labels, args.trusted_labels, unattended=args.unattended, warnings=warnings)
    rigor_labels, strategy_labels, tier_candidates = parse_labels(effective_labels, warnings)
    explicit_rigor, explicit_strategy, tier_override_unqualified, tier_override_scoped = parse_overrides(
        args.overrides, errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "requires_confirmation": False, "warnings": warnings, "errors": errors}, errors)

    tier_override_unqualified, tier_override_scoped = validate_override_tier_values(
        tier_override_unqualified, tier_override_scoped, errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "requires_confirmation": False, "warnings": warnings, "errors": errors}, errors)

    rigor_name, rigor_source = resolve_rigor(cfg, rigor_labels, explicit_rigor, warnings, errors)
    if rigor_name is None:
        emit({
            "config_path": read_path, "config_source": config_source, "config_sha256": digest,
            "selections": {"rigor": {"value": None, "source": rigor_source}},
            "requires_confirmation": False, "warnings": warnings, "errors": errors,
        }, errors)

    strategy_name, strategy_source = resolve_strategy(
        cfg, strategy_labels, explicit_strategy, args.unattended, warnings, errors)

    check_incompatible(cfg, rigor_name, strategy_name, errors)

    rigor_tbl = cfg["rigor"][rigor_name]
    review_tbl = cfg["review"][rigor_tbl["review"]]
    budget_name = rigor_tbl["budget"]
    budget_tbl = cfg["budget"][budget_name]
    strategy_tbl = cfg["strategy"][strategy_name] if strategy_name is not None else None

    overrides_label = strongest_tier_per_role(tier_candidates)
    overrides_explicit = merge_tier_overrides(tier_override_unqualified, tier_override_scoped)
    tiers = resolve_tiers(rigor_tbl, overrides_label, overrides_explicit)

    off_default = rigor_name != cfg.get("default_rigor") or (
        strategy_name is not None and strategy_name != cfg.get("default_strategy"))
    off_profile = any(t["off_profile"] for t in tiers.values())

    # Interactive-only (ADR 0006 D6.2): an off-default/off-profile result is
    # fine when it came from an explicit override or a TRUSTED label — both
    # are attributable to an authorized actor. It requires operator
    # confirmation when the label that produced it is not in --trusted-label.
    # Unattended automation never sets this: it already only acted on
    # trusted labels in the first place (D6.1), so there is nothing left
    # here for a human to confirm synchronously.
    requires_confirmation = False
    if not args.unattended:
        if label_drove_untrusted_off_default(rigor_name, rigor_source, cfg, trusted_set):
            requires_confirmation = True
        if strategy_drove_untrusted_off_default(strategy_name, strategy_source, cfg, trusted_set):
            requires_confirmation = True
        if any(tier_drove_untrusted_off_profile(role, t, trusted_set) for role, t in tiers.items()):
            requires_confirmation = True

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
            # of scope for a config-only resolver. `null` means genuinely
            # UNKNOWN here, not "no" — a caller must not treat a missing
            # same-family disclosure as "different family confirmed" just
            # because this resolver said false. A fuller resolver (#1048)
            # that is handed actual configured families could compute this
            # for real.
            "same_family_reviewer": None,
        },
        "requires_confirmation": requires_confirmation,
        "warnings": warnings,
        "errors": errors,
    }, errors)


if __name__ == "__main__":
    main()
