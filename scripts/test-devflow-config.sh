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
PY
