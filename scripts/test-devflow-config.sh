#!/usr/bin/env bash
# Validate the v2 portable policy and its dogfood twin.
set -euo pipefail

python3 - <<'PY'
import json, pathlib, re, subprocess, sys, tempfile, tomllib

root = pathlib.Path.cwd()
roles = {"orchestrator", "implementer", "challenger", "reviewer", "integrator"}
stages = {"implement", "challenge", "review", "integration"}
# harmon-init#1571: [stage.integration].review_trigger, the one scalar stage key.
review_triggers = ["after-ci", "with-push", "after-ci-first"]
tiers = ["local", "economy", "standard", "frontier", "apex"]
# ADR 2026-09-30 D2/D4: [tier.matrix] rows are Complexity, columns Risk.
complexities = ["xs", "s", "m", "l", "xl"]
risks = ["trivial", "low", "medium", "high", "critical"]

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
    expected = {"schema_version", "default_rigor", "default_strategy", "rigor_order", "tier_order", "rigor", "rounds", "breadth", "run", "gates", "convergence", "role", "stage", "strategy"}
    extra = set(cfg) - expected - {"spend", "tier"}
    if extra: fail(f"{rel}: unsupported top-level keys: {sorted(extra)}")
    if "tier" in cfg:
        if set(cfg["tier"]) != {"matrix"}: fail(f"{rel}: [tier] may hold only [tier.matrix], got {sorted(cfg['tier'])}")
        matrix = cfg["tier"]["matrix"]
        if not isinstance(matrix, dict) or set(matrix) != set(complexities): fail(f"{rel}: [tier.matrix] rows must be exactly {complexities}")
        for complexity, row in matrix.items():
            if not isinstance(row, dict) or set(row) != set(risks): fail(f"{rel}: [tier.matrix].{complexity} columns must be exactly {risks}")
            for risk, cell in row.items():
                if cell not in tiers: fail(f"{rel}: [tier.matrix].{complexity}.{risk} must be a tier_order rung, got {cell!r}")
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
        if set(breadth) != {"max_agent_runs", "max_parallel_agents", "max_in_flight"}: fail(f"{rel}: breadth.{name} has invalid keys")
        if any(not isinstance(v, int) or v < 1 for v in breadth.values()): fail(f"{rel}: breadth.{name} must use positive integers")
        if breadth["max_in_flight"] < breadth["max_parallel_agents"]: fail(f"{rel}: breadth.{name} in-flight ceiling is below parallel ceiling")
    if cfg["breadth"].get("fleet") != {"max_agent_runs": 30, "max_parallel_agents": 5, "max_in_flight": 15}: fail(f"{rel}: fleet breadth drifted")
    if cfg["run"].get("standardize-repo") != {"rigor": "standard", "breadth": "fleet", "strategy": "orchestrate"}: fail(f"{rel}: standardize-repo run drifted")
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
            if name == "integration" and key == "review_trigger":
                if entries not in review_triggers: fail(f"{rel}: stage.integration.review_trigger must be one of {review_triggers}")
                continue
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
    # The shipped timing is today's serial order on every render.
    if cfg["stage"]["integration"].get("review_trigger") != "after-ci":
        fail(f"{label}: stage.integration.review_trigger must ship as after-ci")

with tempfile.TemporaryDirectory() as tmp:
    for label, text in policy_text.items():
        path = pathlib.Path(tmp) / f"{len(list(pathlib.Path(tmp).iterdir()))}.toml"
        path.write_text(text)
        run = subprocess.run(
            ["node", ".claude/skills/dev-flow-support/assets/devflow-policy.mjs", "resolve", "--policy", str(path),
             "--registry", "agent-registry.json", "--taskfile-dir", ".", "--json"],
            text=True, capture_output=True,
        )
        if run.returncode != 0:
            fail(f"{label}: executable reader rejected rendered policy: {run.stderr.strip()}")
        named_run = subprocess.run(
            ["node", ".claude/skills/dev-flow-support/assets/devflow-policy.mjs", "resolve", "--policy", str(path),
             "--registry", "agent-registry.json", "--taskfile-dir", ".", "--run", "standardize-repo", "--json"],
            text=True, capture_output=True,
        )
        if named_run.returncode != 0:
            fail(f"{label}: vendored reader rejected standardize-repo run: {named_run.stderr.strip()}")
        named = json.loads(named_run.stdout)
        if named["breadth"].get("max_in_flight") != 15:
            fail(f"{label}: standardize-repo did not resolve fleet breadth")
        # harmon-init#1326: the base-merge exemption is DERIVED, so it must
        # track the charged ceiling on every render — 0 included. A repo that
        # opted out of cloud review has no reviewer to run an exempt cycle
        # against, so a positive exempt ceiling there would conjure cycles the
        # operator disabled; a render is the only place that case is reachable,
        # since no shipped level sets integration = 0.
        resolved_policy = json.loads(run.stdout)
        if resolved_policy["stages"]["integration"].get("review_trigger") != "after-ci":
            fail(f"{label}: resolved stages.integration.review_trigger must be after-ci")
        resolved_rounds = resolved_policy["rounds"]
        if "integration_exempt" not in resolved_rounds:
            fail(f"{label}: resolved rounds must expose integration_exempt")
        if resolved_rounds["integration_exempt"] != resolved_rounds["integration"]:
            fail(
                f"{label}: rounds.integration_exempt ({resolved_rounds['integration_exempt']}) "
                f"must equal integration ({resolved_rounds['integration']})"
            )

schema = json.loads((root / ".devflow.schema.json").read_text())
if schema["properties"]["schema_version"]["const"] != 2: fail("v2 schema const missing")
if schema["properties"].get("run", {}).get("$ref") != "#/$defs/run_profiles": fail("schema must accept named runs")
if schema["$defs"]["breadth_profile"]["properties"].get("max_in_flight") != {"type": "integer", "minimum": 1}: fail("schema must accept max_in_flight")
if schema["$defs"]["run_profile"]["properties"].get("gates", {}).get("$ref") != "#/$defs/run_gate_overrides": fail("schema must accept run gate overrides")
if schema["$defs"]["rigor_profile"]["properties"].get("convergence", {}).get("$ref") != "#/$defs/convergence_override": fail("v2 schema lacks per-rigor convergence overrides")
if schema["$defs"]["rigor_profile"]["properties"].get("spend", {}).get("type") != "string": fail("v2 schema lacks per-rigor spend pointers")
stage_schema = schema["$defs"]["stage_profiles"]
if schema["$defs"].get("review_trigger", {}).get("enum") != review_triggers: fail("v2 schema's review_trigger enum must be exactly after-ci, with-push, after-ci-first")
integration_schema = schema["$defs"].get("integration_stage_profile", {})
if stage_schema.get("properties", {}).get("integration", {}).get("$ref") != "#/$defs/integration_stage_profile" or integration_schema.get("additionalProperties") is not False or set(integration_schema.get("properties", {})) != {"finders", "finder_fallbacks", "pool", "review_trigger"}: fail("v2 schema must admit review_trigger on [stage.integration] alone")
if "review_trigger" in schema["$defs"]["stage_profile"].get("properties", {}): fail("v2 schema must not admit review_trigger outside [stage.integration]")
if stage_schema.get("additionalProperties") is not False or set(stage_schema.get("required", [])) != stages or set(stage_schema.get("properties", {})) != stages: fail("v2 schema must close the exact four-stage catalog")
role_schema = schema["$defs"]["role_profiles"]
if role_schema.get("additionalProperties") is not False or set(role_schema.get("required", [])) != roles or set(role_schema.get("properties", {})) != roles: fail("v2 schema must close the exact five-role catalog")
if {row.get("$ref") for row in schema["$defs"]["convergence_expression"].get("oneOf", [])} != {"#/$defs/convergence_all", "#/$defs/convergence_any"}: fail("v2 schema must make convergence roots an exclusive all/any union")
if len(schema["$defs"]["convergence_item"].get("oneOf", [])) != 6: fail("v2 schema must make convergence items an exclusive predicate/all/any union")
for profile in ("stage_profile", "integration_stage_profile"):
    for key in ("finders", "finder_fallbacks", "pool"):
        if schema["$defs"][profile]["properties"][key].get("$ref") != "#/$defs/strings_allow_empty":
            fail(f"v2 schema must permit an explicit empty stage.{key} list ({profile})")
if "minItems" in schema["$defs"]["strings_allow_empty"]:
    fail("v2 schema's empty stage-list definition must not require minItems")
if schema["$defs"]["tier"].get("enum") != tiers: fail("v2 schema's tier enum must be exactly tier_order (no retired adaptive)")
tier_schema = schema["properties"].get("tier", {})
if tier_schema.get("additionalProperties") is not False or tier_schema.get("required") != ["matrix"] or set(tier_schema.get("properties", {})) != {"matrix"}: fail("v2 schema must close [tier] to a required matrix")
if "tier" in schema["required"]: fail("v2 schema must keep [tier.matrix] optional (an absent matrix is indeterminate, not invalid)")
matrix_schema = schema["$defs"]["tier_matrix"]
if matrix_schema.get("additionalProperties") is not False or set(matrix_schema.get("required", [])) != set(complexities) or set(matrix_schema.get("properties", {})) != set(complexities): fail("v2 schema must close [tier.matrix] to the five Complexity rows")
row_schema = schema["$defs"]["tier_matrix_row"]
if row_schema.get("additionalProperties") is not False or set(row_schema.get("required", [])) != set(risks) or {key: value.get("$ref") for key, value in row_schema.get("properties", {}).items()} != {risk: "#/$defs/tier" for risk in risks}: fail("v2 schema must close each [tier.matrix] row to the five Risk columns of tier values")
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

# The absent-merge-base guard lives in the library, not only the CLI: a library
# caller (dev-flow-exit.mjs) must not get the built-in fallback without a branch
# policy. The conformance corpus drives the CLI, whose own pre-check exits first.
if ! node --input-type=module -e '
import { resolvePolicy, PolicyError } from "./scripts/devflow-policy.mjs"
try {
  resolvePolicy(null, { mergeBasePolicyAbsent: true })
} catch (err) {
  if (err instanceof PolicyError) process.exit(0)
  throw err
}
process.exit(1)
'; then
    echo "FAIL: resolvePolicy accepted an absent merge-base policy without a branch policy" >&2
    exit 1
fi

# Exercise the root reader's fleet/run contract, including dormant invalid profiles.
node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { parseToml } from './scripts/lib/toml-lite.mjs'
import { resolvePolicy } from './scripts/devflow-policy.mjs'
const base = parseToml(readFileSync('.devflow.toml', 'utf8'))
const clone = () => structuredClone(base)
let doc = clone()
let result = resolvePolicy(doc, { run: 'standardize-repo' })
assert.equal(result.breadth.policy, 'fleet')
assert.equal(result.breadth.max_in_flight, 15)
assert.equal(result.rigor.chosen_by, 'operator')
assert.equal(result.strategy.name, 'orchestrate')
doc = clone()
delete doc.breadth.standard.max_in_flight
assert.equal(resolvePolicy(doc).breadth.max_in_flight, doc.breadth.standard.max_parallel_agents)
for (const invalid of [0, 2, 3.5, '3']) {
  doc = clone()
  doc.breadth.standard.max_in_flight = invalid
  assert.throws(() => resolvePolicy(doc))
}
for (const change of [
  p => { p.run.bad = { rigor: 'missing', breadth: 'fleet', strategy: 'orchestrate' } },
  p => { p.run.bad = { rigor: 'standard', breadth: 'missing', strategy: 'orchestrate' } },
  p => { p.run.bad = { rigor: 'standard', breadth: 'fleet', strategy: 'missing' } },
  p => { p.run.bad = { rigor: 'standard', breadth: 'fleet', strategy: 'orchestrate', extra: true } },
  p => { p.run.bad = { rigor: 'standard', breadth: 'fleet', strategy: 'orchestrate', gates: { extra: 'check' } } },
  p => { p.run.bad = { rigor: 'standard', breadth: 'fleet', strategy: 'orchestrate', gates: {} } },
]) {
  doc = clone(); change(doc); assert.throws(() => resolvePolicy(doc))
}
doc = clone()
doc.run['standardize-repo'].gates = { round_code: 'check', docs_only_paths: ['docs/**'] }
result = resolvePolicy(doc, { run: 'standardize-repo' })
assert.equal(result.gates.round_code, 'check')
assert.equal(result.gates.secret_scan, doc.gates.secret_scan)
assert.deepEqual(result.gates.docs_only_paths, ['docs/**'])
assert.throws(() => resolvePolicy(doc, { run: 'standardize-repo', rigor: 'deep' }))
assert.equal(resolvePolicy(doc, { run: 'standardize-repo', rigor: 'deep', rigorSource: 'label' }).rigor.level, 'standard')
console.log('fleet and named run reader cases OK')
NODE
