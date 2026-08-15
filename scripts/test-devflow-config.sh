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

LABELS_SCRIPT="scripts/setup-github-labels.sh"
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

python3 - "$LABELS_SCRIPT" "$AGENTS_ROOT" "$AGENTS_TEMPLATE" \
    .devflow.toml template/.devflow.toml <<'PY'
import re
import sys
import tomllib

labels_script, agents_root, agents_template, *config_paths = sys.argv[1:]
STAGES = ("challenge", "review", "shepherd")
# `min_rounds` is a floor on rounds actually run, not a cap — it gates only the
# empty-round instant exit (AGENTS.md, "Loop cap and exit"). It is required in
# every tier, so both dogfood copies state it rather than relying on a default.
MIN_ROUNDS = "min_rounds"
KNOWN_KEYS = STAGES + (MIN_ROUNDS,)
# The floor is 2, not 1: a stage exits on two consecutive adjudicated-clean
# rounds, so a cap of 1 makes any single finding an instant escalation.
FLOOR = {"challenge": 2, "review": 2, "shepherd": 1}

provisioned = set(re.findall(r"^rigor:([A-Za-z0-9_-]+)\|", open(labels_script).read(), re.M))

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
            else:
                # A floor above the ceiling makes the stage impossible to exit:
                # the empty-round path is unreachable and the cap forces an
                # escalation that no amount of reviewing could avoid.
                for stage in ("challenge", "review"):
                    cap = caps.get(stage)
                    if isinstance(cap, int) and not isinstance(cap, bool) and floor_value > cap:
                        failures.append(
                            f"{path}: rigor.{name}.{MIN_ROUNDS}={floor_value} exceeds the "
                            f"{stage} cap of {cap} — the floor cannot be above the ceiling"
                        )

        if isinstance(caps.get("shepherd"), int) and not isinstance(caps.get("shepherd"), bool):
            shepherd_values.add(caps["shepherd"])

        if name not in provisioned:
            failures.append(
                f"{path}: tier {name!r} has no rigor:{name} label in {labels_script} — "
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
    f"{n}={t['challenge']}/{t['review']}/{t['shepherd']} (min {t['min_rounds']})"
    for n, t in sorted(tiers.items())
)
print(f"devflow config OK: default={cfg['default_rigor']} — {summary}")
print("  (challenge/review/shepherd + min_rounds; both copies valid, every tier has a label)")
PY
