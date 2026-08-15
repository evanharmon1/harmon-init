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
# cross-file invariant that byte-equality cannot see: every tier must have a
# provisioned `rigor:<tier>` label, or the documented label resolution path
# names something GitHub cannot apply.
#
# Root-only by design (no template twin): it guards what harmon-init SHIPS.
# A consumer retuning their own tiers is editing their policy, the same way
# they may edit their AGENTS.md, and owes no gate here.
set -euo pipefail
cd "$(dirname "$0")/.."

# The provisioned rigor:* vocabulary lives in the label registry (per layer —
# the manifests legitimately diverge in other families, so each .devflow.toml
# is checked against its own layer's manifest).
LABEL_REGISTRY_ROOT="label-registry.json"
LABEL_REGISTRY_TEMPLATE="template/label-registry.json"
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

python3 - "$LABEL_REGISTRY_ROOT" "$LABEL_REGISTRY_TEMPLATE" "$AGENTS_ROOT" "$AGENTS_TEMPLATE" \
    .devflow.toml template/.devflow.toml <<'PY'
import json
import re
import sys
import tomllib

registry_root, registry_template, agents_root, agents_template, *config_paths = sys.argv[1:]
STAGES = ("challenge", "review", "shepherd")
# The floor is 2, not 1: a stage exits on two consecutive adjudicated-clean
# rounds, so a cap of 1 makes any single finding an instant escalation.
FLOOR = {"challenge": 2, "review": 2, "shepherd": 1}

def rigor_values(registry_path):
    # Only values the renderer actually seeds count: a retired or
    # provision:false rigor value has no live label, so a .devflow.toml tier
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

failures = []

for path in config_paths:
    with open(path, "rb") as fh:
        try:
            cfg = tomllib.load(fh)
        except tomllib.TOMLDecodeError as exc:
            failures.append(f"{path}: not valid TOML — {exc}")
            continue

    tiers = cfg.get("rigor")
    if not isinstance(tiers, dict) or not tiers:
        failures.append(f"{path}: no [rigor.*] tiers defined")
        continue

    default = cfg.get("default_rigor")
    if not isinstance(default, str):
        failures.append(f"{path}: default_rigor is missing or not a string")
    elif default not in tiers:
        failures.append(
            f"{path}: default_rigor={default!r} names no tier "
            f"(have: {', '.join(sorted(tiers))})"
        )

    shepherd_values = set()
    for name, caps in sorted(tiers.items()):
        if not isinstance(caps, dict):
            failures.append(f"{path}: [rigor.{name}] is not a table")
            continue
        missing = [s for s in STAGES if s not in caps]
        if missing:
            failures.append(f"{path}: [rigor.{name}] missing {', '.join(missing)}")
        extra = [k for k in caps if k not in STAGES]
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
        if isinstance(caps.get("shepherd"), int) and not isinstance(caps.get("shepherd"), bool):
            shepherd_values.add(caps["shepherd"])

        registry_path, provisioned = provisioned_by_config[path]
        if name not in provisioned:
            failures.append(
                f"{path}: tier {name!r} has no rigor:{name} label in {registry_path} — "
                "the documented label resolution path cannot select it"
            )

    # shepherd bounds other people's findings, not self-generated work, so it
    # is fixed across tiers by design (AGENTS.md). Catch a tier-varying edit.
    if len(shepherd_values) > 1:
        failures.append(
            f"{path}: shepherd varies by tier ({sorted(shepherd_values)}) — it is "
            "fixed by design; lowering it abandons unanswered reviews"
        )

FALLBACK_RE = re.compile(r"built-in (\d+ / \d+ / \d+)")
fallbacks = {}
for path in (agents_root, agents_template):
    found = set(FALLBACK_RE.findall(open(path).read()))
    if len(found) != 1:
        failures.append(
            f"{path}: expected exactly one 'built-in N / N / N' fallback, found "
            f"{sorted(found) if found else 'none'} — the resolution rule needs it"
        )
    else:
        fallbacks[path] = found.pop()
if len(set(fallbacks.values())) > 1:
    failures.append(
        "the fallback caps disagree across the dogfood: "
        + "; ".join(f"{p} says {v}" for p, v in sorted(fallbacks.items()))
        + " — root and generated agents would use different caps"
    )

if failures:
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)

with open(config_paths[0], "rb") as fh:
    cfg = tomllib.load(fh)
tiers = cfg["rigor"]
summary = "; ".join(
    f"{n}={t['challenge']}/{t['review']}/{t['shepherd']}" for n, t in sorted(tiers.items())
)
print(f"devflow config OK: default={cfg['default_rigor']} — {summary}")
print("  (challenge/review/shepherd; both copies valid, every tier has a rigor:* label)")
PY
