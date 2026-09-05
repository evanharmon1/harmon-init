#!/usr/bin/env bash
# Validate the v2 portable policy and its dogfood twin.
set -euo pipefail

python3 - <<'PY'
import json, pathlib, re, subprocess, sys, tempfile, tomllib

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

template_path = root / "template/.devflow.toml.jinja"
if not template_path.is_file(): fail("template/.devflow.toml.jinja is missing")
if (root / "template/.devflow.toml").exists(): fail("unrendered template/.devflow.toml shadows the Jinja policy")

def render_template_policy(*, local_review, cloud_review):
    values = {
        "use_codex_review": local_review,
        "use_codex_cloud_review": cloud_review,
    }
    text = template_path.read_text()
    expression = re.compile(r"\[\[\s*(\d+)\s+if\s+(use_codex_(?:cloud_)?review)\s+else\s+0\s*\]\]")
    text = expression.sub(lambda match: match.group(1) if values[match.group(2)] else "0", text)
    for variable, enabled in values.items():
        block = re.compile(rf"\[% if {re.escape(variable)} %\]\n(.*?)\[% endif %\]\n?", re.S)
        text = block.sub(lambda match: match.group(1) if enabled else "", text)
    if "[[" in text or "[%" in text:
        fail("template/.devflow.toml.jinja uses an untested Jinja expression")
    return text

policy_text = {
    "root .devflow.toml": (root / ".devflow.toml").read_text(),
    "template local=off cloud=off": render_template_policy(local_review=False, cloud_review=False),
    "template local=on cloud=off": render_template_policy(local_review=True, cloud_review=False),
    "template local=on cloud=on": render_template_policy(local_review=True, cloud_review=True),
}
parsed = {}
for rel, text in policy_text.items():
    cfg = tomllib.loads(text)
    parsed[rel] = cfg
    manifest_rel = "template/label-registry.json" if rel.startswith("template ") else "label-registry.json"
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
        optional = {"convergence", "spend"}
        if not required <= set(profile) or set(profile) - required - optional: fail(f"{rel}: rigor.{name} has invalid keys")
        if profile["rounds"] not in cfg["rounds"] or profile["breadth"] not in cfg["breadth"]: fail(f"{rel}: rigor.{name} references missing policy")
        if "spend" in profile and profile["spend"] not in cfg.get("spend", {}): fail(f"{rel}: rigor.{name} references missing spend policy")
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

canonical = parsed["root .devflow.toml"]
if policy_text["template local=on cloud=on"] != policy_text["root .devflow.toml"]:
    fail("root .devflow.toml must byte-match the fully opted-in template render")
for label, local_review, cloud_review in (
    ("template local=off cloud=off", False, False),
    ("template local=on cloud=off", True, False),
    ("template local=on cloud=on", True, True),
):
    cfg = parsed[label]
    for name, rounds in cfg["rounds"].items():
        expected = canonical["rounds"][name]
        for key in ("challenge", "review", "min_rounds"):
            want = expected[key] if local_review else 0
            if rounds[key] != want: fail(f"{label}: rounds.{name}.{key} must be {want}")
        want_integration = expected["integration"] if cloud_review else 0
        if rounds["integration"] != want_integration:
            fail(f"{label}: rounds.{name}.integration must be {want_integration}")
    for stage in ("challenge", "review"):
        want = canonical["stage"][stage].get("finders", []) if local_review else []
        if cfg["stage"][stage].get("finders", []) != want:
            fail(f"{label}: stage.{stage}.finders does not honor use_codex_review")
    want = canonical["stage"]["integration"].get("finders", []) if cloud_review else []
    if cfg["stage"]["integration"].get("finders", []) != want:
        fail(f"{label}: stage.integration.finders does not honor use_codex_cloud_review")

with tempfile.TemporaryDirectory() as tmp:
    for label, text in policy_text.items():
        path = pathlib.Path(tmp) / f"{len(list(pathlib.Path(tmp).iterdir()))}.toml"
        path.write_text(text)
        run = subprocess.run(
            ["node", "scripts/devflow-policy.mjs", "resolve", "--policy", str(path),
             "--registry", "template/agent-registry.json", "--taskfile-dir", ".", "--json"],
            text=True, capture_output=True,
        )
        if run.returncode != 0:
            fail(f"{label}: executable reader rejected rendered policy: {run.stderr.strip()}")

schema = json.loads((root / ".devflow.schema.json").read_text())
if schema["properties"]["schema_version"]["const"] != 2: fail("v2 schema const missing")
if schema["$defs"]["rigor_profile"]["properties"].get("convergence", {}).get("$ref") != "#/$defs/convergence_override": fail("v2 schema lacks per-rigor convergence overrides")
if schema["$defs"]["rigor_profile"]["properties"].get("spend", {}).get("type") != "string": fail("v2 schema lacks per-rigor spend pointers")
stage_schema = schema["$defs"]["stage_profiles"]
if stage_schema.get("additionalProperties") is not False or set(stage_schema.get("required", [])) != stages or set(stage_schema.get("properties", {})) != stages: fail("v2 schema must close the exact four-stage catalog")
role_schema = schema["$defs"]["role_profiles"]
if role_schema.get("additionalProperties") is not False or set(role_schema.get("required", [])) != roles or set(role_schema.get("properties", {})) != roles: fail("v2 schema must close the exact five-role catalog")
if {row.get("$ref") for row in schema["$defs"]["convergence_expression"].get("oneOf", [])} != {"#/$defs/convergence_all", "#/$defs/convergence_any"}: fail("v2 schema must make convergence roots an exclusive all/any union")
if len(schema["$defs"]["convergence_item"].get("oneOf", [])) != 6: fail("v2 schema must make convergence items an exclusive predicate/all/any union")
for key in ("finders", "finder_fallbacks", "pool"):
    if schema["$defs"]["stage_profile"]["properties"][key].get("$ref") != "#/$defs/strings_allow_empty":
        fail(f"v2 schema must permit an explicit empty stage.{key} list")
if "minItems" in schema["$defs"]["strings_allow_empty"]:
    fail("v2 schema's empty stage-list definition must not require minItems")
print("devflow config v2 OK")
PY

node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --registry agent-registry.json \
    --taskfile-dir . \
    --json >/dev/null

python3 scripts/test-devflow-conformance.py \
    --fixture .devflow-conformance-v2.json \
    --config .devflow.toml
python3 scripts/test-devflow-conformance.py \
    --fixture template/.devflow-conformance-v2.json \
    --config .devflow.toml

unsupported_v2_case="$(mktemp)"
unsupported_v2_output="$(mktemp)"
trap 'rm -f "$unsupported_v2_case" "$unsupported_v2_output"' EXIT
jq '.cases[0].labels = ["rigor:standard"]' \
    .devflow-conformance-v2.json >"$unsupported_v2_case"
if python3 scripts/test-devflow-conformance.py \
    --fixture "$unsupported_v2_case" \
    --config .devflow.toml >"$unsupported_v2_output" 2>&1; then
    echo "FAIL: v2 conformance runner silently accepted an unsupported label input" >&2
    exit 1
fi
grep -q 'v2 reader does not support case input(s): labels' "$unsupported_v2_output" || {
    echo "FAIL: v2 conformance runner did not diagnose its unsupported input" >&2
    exit 1
}
