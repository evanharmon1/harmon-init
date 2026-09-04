#!/usr/bin/env bash
# Validate the v2 portable policy and its dogfood twin.
set -euo pipefail

python3 - <<'PY'
import json, pathlib, re, sys, tomllib

root = pathlib.Path.cwd()
roles = {"orchestrator", "implementer", "challenger", "reviewer", "integrator"}
stages = {"implement", "challenge", "review", "integration"}
tiers = ["local", "economy", "standard", "frontier", "apex"]

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

taskfile = (root / "Taskfile.yml").read_text()
registry = json.loads((root / "agent-registry.json").read_text())
families = {row["slug"] for row in registry["families"]}
harnesses = {row["slug"] for row in registry["harnesses"]}
finders = {row["slug"] for row in registry["finders"]}

for rel in (".devflow.toml", "template/.devflow.toml"):
    cfg = tomllib.loads((root / rel).read_text())
    manifest_rel = "template/label-registry.json" if rel.startswith("template/") else "label-registry.json"
    manifest = json.loads((root / manifest_rel).read_text())
    if cfg.get("schema_version") != 2:
        fail(f"{rel}: schema_version=2 is required; migrate legacy v1 configuration")
    expected = {"schema_version", "default_rigor", "default_strategy", "rigor_order", "tier_order", "rigor", "rounds", "breadth", "gates", "convergence", "role", "stage", "strategy"}
    extra = set(cfg) - expected - {"spend"}
    if extra: fail(f"{rel}: unsupported top-level keys: {sorted(extra)}")
    if set(cfg["rigor_order"]) != set(cfg["rigor"]): fail(f"{rel}: rigor_order must permute rigor tables")
    if cfg["tier_order"] != tiers: fail(f"{rel}: tier_order must be {tiers}")
    if cfg["default_rigor"] not in cfg["rigor"] or cfg["default_strategy"] not in cfg["strategy"]: fail(f"{rel}: invalid defaults")
    rigor_family = next((family for family in manifest["families"] if family["family"] == "rigor"), None)
    if rigor_family is None: fail(f"{manifest_rel}: missing rigor label family")
    label_rigor = {row["value"]: row["description"] for row in rigor_family["values"]}
    if list(label_rigor) != cfg["rigor_order"]: fail(f"{manifest_rel}: rigor labels must follow rigor_order")
    for value, description in label_rigor.items():
        if description != cfg["rigor"][value]["description"]:
            fail(f"{manifest_rel}: rigor:{value} description drifted from {rel}")
    for name, profile in cfg["rigor"].items():
        required = {"rounds", "breadth", "orchestrator_tier", "implementer_tier", "challenger_tier", "reviewer_tier", "integrator_tier", "tier_escalation", "description"}
        optional = {"convergence"}
        if not required <= set(profile) or set(profile) - required - optional: fail(f"{rel}: rigor.{name} has invalid keys")
        if profile["rounds"] not in cfg["rounds"] or profile["breadth"] not in cfg["breadth"]: fail(f"{rel}: rigor.{name} references missing policy")
        if any(profile[key] not in tiers for key in required if key.endswith("_tier")): fail(f"{rel}: rigor.{name} has unknown tier")
    for name, rounds in cfg["rounds"].items():
        if set(rounds) != {"challenge", "review", "integration", "remediation", "min_rounds", "wall_clock_min"}: fail(f"{rel}: rounds.{name} has invalid keys")
        if any(not isinstance(v, int) or v < 0 for key, v in rounds.items() if key != "wall_clock_min"): fail(f"{rel}: rounds.{name} caps/floor must be non-negative integers")
        if not isinstance(rounds["wall_clock_min"], int) or rounds["wall_clock_min"] < 1: fail(f"{rel}: rounds.{name}.wall_clock_min must be a positive integer")
        if rounds["min_rounds"] > min(rounds["challenge"], rounds["review"]): fail(f"{rel}: rounds.{name}.min_rounds exceeds a confidence-stage cap")
    for name, breadth in cfg["breadth"].items():
        if set(breadth) != {"max_agent_runs", "max_parallel_agents"}: fail(f"{rel}: breadth.{name} has invalid keys")
        if any(not isinstance(v, int) or v < 1 for v in breadth.values()): fail(f"{rel}: breadth.{name} must use positive integers")
    for key in ("round_code", "round_docs", "secret_scan", "pre_pr"):
        value = cfg["gates"].get(key)
        if not isinstance(value, str) or " " in value or "/" in value or not re.search(rf"^  {re.escape(value)}:", taskfile, re.M): fail(f"{rel}: gates.{key} must be a Taskfile target")
    if not cfg["gates"].get("docs_only_paths"): fail(f"{rel}: docs_only_paths must be non-empty")
    if set(cfg["role"]) != roles: fail(f"{rel}: role tables must match registry roles")
    for role, value in cfg["role"].items():
        if value["tier"] not in tiers or not set(value["families"]) <= families or not set(value.get("harnesses", [])) <= harnesses: fail(f"{rel}: role.{role} has unresolved preferences")
    if set(cfg["stage"]) != stages: fail(f"{rel}: stage tables are incomplete")
    for name, value in cfg["stage"].items():
        for key, entries in value.items():
            if key not in {"finders", "finder_fallbacks", "pool"} or not isinstance(entries, list): fail(f"{rel}: stage arrays must be monomorphic")
            universe = harnesses if key == "pool" else finders
            if not set(entries) <= universe: fail(f"{rel}: stage.{name}.{key} contains unknown slugs")
    conv = cfg["convergence"]
    if set(conv) != {"converged", "diverging"}: fail(f"{rel}: convergence requires composed converged/diverging predicates")

if (root / ".devflow.toml").read_bytes() != (root / "template/.devflow.toml").read_bytes(): fail(".devflow.toml dogfood twin drift")
schema = json.loads((root / ".devflow.schema.json").read_text())
if schema["properties"]["schema_version"]["const"] != 2: fail("v2 schema const missing")
if schema["$defs"]["rigor_profile"]["properties"].get("convergence", {}).get("$ref") != "#/$defs/convergence_override": fail("v2 schema lacks per-rigor convergence overrides")
print("devflow config v2 OK")
PY

for policy in .devflow.toml template/.devflow.toml; do
    registry="agent-registry.json"
    if [[ "$policy" == template/* ]]; then
        registry="template/agent-registry.json"
    fi
    node scripts/devflow-policy.mjs resolve \
        --policy "$policy" \
        --registry "$registry" \
        --taskfile-dir . \
        --json >/dev/null
done

python3 scripts/test-devflow-conformance.py \
    --fixture .devflow-conformance-v2.json \
    --config .devflow.toml
python3 scripts/test-devflow-conformance.py \
    --fixture template/.devflow-conformance-v2.json \
    --config template/.devflow.toml
