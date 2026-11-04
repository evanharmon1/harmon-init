#!/usr/bin/env bash
# Validate the v2 portable policy and its dogfood twin.
set -euo pipefail

# Reject invalid root policies before paying for the full Copier matrix.
node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --registry agent-registry.json \
    --taskfile-dir . \
    --json >/dev/null

python3 - <<'PY'
import itertools, json, pathlib, re, shutil, subprocess, sys, tempfile, tomllib

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

# Validate the complete document, including unrelated definitions. This small
# offline validator covers the policy schema vocabulary, refusing unknown keys.
def validate_schema(value, spec, schema, where="$"):
    if isinstance(spec, bool):
        if not spec: raise ValueError(f"{where}: false schema")
        return
    supported = {"$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum",
                 "required", "properties", "additionalProperties", "minProperties", "items", "minItems",
                 "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum", "exclusiveMinimum",
                 "allOf", "anyOf", "oneOf", "not", "if", "then", "else"}
    unknown = set(spec) - supported
    if unknown: raise RuntimeError(f"unsupported schema keywords: {unknown}")
    def check(v, rule, path=where): validate_schema(v, rule, schema, path)
    def matches(rule):
        try: check(value, rule); return True
        except ValueError: return False
    if "$ref" in spec:
        ref = spec["$ref"]
        if not ref.startswith("#/"): raise RuntimeError(f"non-local schema ref: {ref}")
        target = schema
        for key in ref[2:].split("/"): target = target[key.replace("~1", "/").replace("~0", "~")]
        check(value, target)
    types = {"object": isinstance(value, dict), "array": isinstance(value, list),
             "string": isinstance(value, str), "boolean": isinstance(value, bool),
             "integer": isinstance(value, int) and not isinstance(value, bool),
             "number": isinstance(value, (int, float)) and not isinstance(value, bool), "null": value is None}
    if "type" in spec and not types[spec["type"]]: raise ValueError(f"{where}: expected {spec['type']}")
    if "const" in spec and value != spec["const"]: raise ValueError(f"{where}: const mismatch")
    if "enum" in spec and value not in spec["enum"]: raise ValueError(f"{where}: enum mismatch")
    for rule in spec.get("allOf", []): check(value, rule)
    if "anyOf" in spec and not any(matches(r) for r in spec["anyOf"]): raise ValueError(f"{where}: anyOf")
    if "oneOf" in spec and sum(matches(r) for r in spec["oneOf"]) != 1: raise ValueError(f"{where}: oneOf")
    if "not" in spec and matches(spec["not"]): raise ValueError(f"{where}: not")
    if "if" in spec: check(value, spec.get("then" if matches(spec["if"]) else "else", {}))
    if types["object"]:
        if len(value) < spec.get("minProperties", 0): raise ValueError(f"{where}: minProperties")
        for key in spec.get("required", []):
            if key not in value: raise ValueError(f"{where}: missing required {key}")
        for key, item in value.items():
            rule = spec.get("properties", {}).get(key, spec.get("additionalProperties", True))
            check(item, rule, f"{where}.{key}")
    if types["array"]:
        if len(value) < spec.get("minItems", 0): raise ValueError(f"{where}: minItems")
        if spec.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            raise ValueError(f"{where}: uniqueItems")
        for i, item in enumerate(value): check(item, spec.get("items", {}), f"{where}[{i}]")
    if types["string"]:
        if not spec.get("minLength", 0) <= len(value) <= spec.get("maxLength", float("inf")):
            raise ValueError(f"{where}: string length")
        if "pattern" in spec and not re.search(spec["pattern"], value): raise ValueError(f"{where}: pattern")
    if types["number"]:
        if not spec.get("minimum", -float("inf")) <= value <= spec.get("maximum", float("inf")):
            raise ValueError(f"{where}: numeric bounds")
        if "exclusiveMinimum" in spec and value <= spec["exclusiveMinimum"]: raise ValueError(f"{where}: exclusiveMinimum")

schema = json.loads((root / ".devflow.schema.json").read_text())
# TOML values are converted through JSON so this exercises the published schema.
validate_schema(json.loads(json.dumps(tomllib.loads((root / ".devflow.toml").read_text()))), schema, schema)

floor_match = re.search(r'^_min_harmon_devkit_skills: "v(\d+)\.(\d+)\.(\d+)"$', (root / "copier.yml").read_text(), re.M)
if not floor_match or tuple(map(int, floor_match.groups())) < (0, 63, 1):
    fail("finder policies and readiness require harmon-devkit skills v0.63.1 or newer")

taskfile = (root / "Taskfile.yml").read_text()
registry = json.loads((root / "agent-registry.json").read_text())
families = {row["slug"] for row in registry["families"]}
harnesses = {row["slug"] for row in registry["harnesses"]}
finders = {row["slug"] for row in registry["finders"]}

template_path = root / "template/.devflow.toml.jinja"
if not template_path.is_file(): fail("template/.devflow.toml.jinja is missing")
if (root / "template/.devflow.toml").exists(): fail("unrendered template/.devflow.toml shadows the Jinja policy")

reviewer_options = {
    "use_codex_cloud_review": "codex-cloud", "use_claude_review": "claude",
    "use_greptile": "greptile", "use_coderabbit": "coderabbit-cloud",
    "use_gemini_code_assist": "gemini",
}
policy_text = {"root .devflow.toml": (root / ".devflow.toml").read_text()}
render_options = {}
# Exercise actual Copier question validation, Jinja and filename inclusion for
# the complete 2^5 reviewer matrix. Isolate only the artifacts under test;
# full-project profiles remain the responsibility of test:template:all.
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / "source"
    source.mkdir()
    shutil.copy(root / "copier.yml", source / "copier.yml")
    for rel in ["template/.devflow.toml.jinja", "template/agent-registry.json.jinja",
                "template/label-registry.json", "template/.devflow.schema.json",
                "template/.github/workflows/[% if use_claude_review %]claude-review.yml[% endif %].jinja"]:
        target = source / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(root / rel, target)
    cases = [dict(zip(reviewer_options, bits)) for bits in itertools.product([False, True], repeat=5)]
    cases.append({**dict.fromkeys(reviewer_options, False), "use_codex_review": False})
    for i, options in enumerate(cases):
        options = {"use_codex_review": True, **options}
        dest = pathlib.Path(tmp) / f"render-{i}"
        args = ["copier", "copy", "--trust", "--defaults", "--skip-tasks", "--vcs-ref=HEAD", "--data", "project_name=finder-matrix",
                "--data", "claude_review_actor_id=295644852",
                "--data", "claude_review_actor_login=evanharmon1-ci[bot]"]
        for key, enabled in options.items(): args += ["--data", f"{key}={str(enabled).lower()}"]
        run = subprocess.run([*args, str(source), str(dest)], text=True, capture_output=True)
        if run.returncode: fail(f"reviewer matrix {options}: {run.stderr}")
        label = f"template matrix {i}"
        policy_text[label] = (dest / ".devflow.toml").read_text()
        render_options[label] = options
        cfg = tomllib.loads(policy_text[label])
        rendered_schema = json.loads((dest / ".devflow.schema.json").read_text())
        validate_schema(json.loads(json.dumps(cfg)), rendered_schema, rendered_schema, label)
        entries = cfg["stage"]["integration"].get("finder", [])
        expected = [slug for option, slug in reviewer_options.items() if options[option]]
        if [entry["id"] for entry in entries] != expected: fail(f"{label}: incorrect enabled finder entries")
        if (dest / ".github/workflows/claude-review.yml").exists() != options["use_claude_review"]:
            fail(f"{label}: Claude workflow does not honor opt-in")
        rendered_registry = json.loads((dest / "agent-registry.json").read_text())
        by_id = {entry["slug"]: entry for entry in rendered_registry["finders"]}
        for entry in entries:
            if entry["id"] != "codex-cloud" and entry.get("gates") is not False:
                fail(f"{label}: {entry['id']} must set gates=false until harmon-devkit's lifecycle counts every reviewer (evanharmon1/harmon-devkit#1819)")
            if int(by_id[entry["id"]]["trusted_actor_id"]) != entry["completion"]["actor_id"]:
                fail(f"{label}: policy and registry actor identity disagree")
            if by_id[entry["id"]]["collection"]["trigger"]["body"] != entry["trigger"]:
                fail(f"{label}: policy and registry trigger disagree")
        labels = {v["value"]: v for family in json.loads((dest / "label-registry.json").read_text())["families"] for v in family["values"]}
        if not {"parked", "merge-ready"} <= labels.keys(): fail(f"{label}: missing delivery labels")
        if labels["needs-review"]["description"] != "An agent still owes review work on the delivery PR": fail(f"{label}: stale review label")
    for missing in ("claude_review_actor_id", "claude_review_actor_login"):
        args = ["copier", "copy", "--trust", "--defaults", "--skip-tasks", "--vcs-ref=HEAD", "--data", "project_name=finder-matrix",
                "--data", "use_claude_review=true", "--data", f"{missing}="]
        other = "claude_review_actor_login" if missing.endswith("_id") else "claude_review_actor_id"
        value = "evanharmon1-ci[bot]" if other.endswith("_login") else "295644852"
        run = subprocess.run([*args, "--data", f"{other}={value}", str(source), str(pathlib.Path(tmp) / missing)], text=True, capture_output=True)
        if run.returncode == 0 or "CLAUDE REVIEW requires" not in run.stderr:
            fail(f"Claude opt-in must clearly refuse missing {missing}: {run.stderr}")
    default_dest = pathlib.Path(tmp) / "defaults"
    run = subprocess.run(["copier", "copy", "--trust", "--defaults", "--skip-tasks", "--vcs-ref=HEAD", "--data", "project_name=finder-matrix", str(source), str(default_dest)], text=True, capture_output=True)
    if run.returncode or (default_dest / ".github/workflows/claude-review.yml").exists(): fail("Claude review must default off")
print("Copier reviewer matrix: all 32 combinations, local opt-out, default-off and identity refusals passed")
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
            if name == "integration" and key == "finder":
                if not isinstance(entries, list) or not {entry["id"] for entry in entries} <= finders: fail(f"{rel}: invalid finder entries")
                continue
            if key not in {"finders", "finder_fallbacks", "pool"} or not isinstance(entries, list): fail(f"{rel}: stage arrays must be monomorphic")
            universe = harnesses if key == "pool" else finders
            if not set(entries) <= universe: fail(f"{rel}: stage.{name}.{key} contains unknown slugs")
    conv = cfg["convergence"]
    if set(conv) != {"converged", "diverging"}: fail(f"{rel}: convergence requires composed converged/diverging predicates")

canonical = parsed["root .devflow.toml"]
all_on = next(label for label, options in render_options.items() if all(options.values()))
if policy_text[all_on] != policy_text["root .devflow.toml"]:
    fail("root .devflow.toml must byte-match the fully opted-in template render")
for label, options in render_options.items():
    local_review = options["use_codex_review"]
    integration_review = options["use_codex_cloud_review"]
    cfg = parsed[label]
    for name, rounds in cfg["rounds"].items():
        expected = canonical["rounds"][name]
        for key in ("challenge", "review", "min_rounds"):
            want = expected[key] if local_review else 0
            if rounds[key] != want: fail(f"{label}: rounds.{name}.{key} must be {want}")
        want_integration = expected["integration"] if integration_review else 0
        if rounds["integration"] != want_integration:
            fail(f"{label}: rounds.{name}.integration must be {want_integration}")
    for stage in ("challenge", "review"):
        want = canonical["stage"][stage].get("finders", []) if local_review else []
        if cfg["stage"][stage].get("finders", []) != want:
            fail(f"{label}: stage.{stage}.finders does not honor use_codex_review")
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
if stage_schema.get("properties", {}).get("integration", {}).get("$ref") != "#/$defs/integration_stage_profile" or integration_schema.get("additionalProperties") is not False or set(integration_schema.get("properties", {})) != {"finders", "finder_fallbacks", "pool", "review_trigger", "finder"}: fail("v2 schema must admit review_trigger on [stage.integration] alone")
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
import { createSchemaValidator } from './scripts/lib/json-schema-subset.mjs'
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

# Per-reviewer settings must resolve identically in the root and pinned readers.
node --input-type=module <<'JS'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { parseToml } from './scripts/lib/toml-lite.mjs'
import * as root from './scripts/devflow-policy.mjs'
import * as vendored from './.claude/skills/dev-flow-support/assets/devflow-policy.mjs'
import { createSchemaValidator } from './scripts/lib/json-schema-subset.mjs'
const base = parseToml(readFileSync('.devflow.toml', 'utf8'))
const fixture = structuredClone(base)
fixture.stage.integration = { finder: [
  { id: 'codex-cloud', trigger: 'fixture full', gates: true, carry: 'identity', completion: { kind: 'review', actor_id: 199175422 } },
  { id: 'coderabbit-cloud', trigger: 'fixture full', trigger_incremental: 'fixture incremental', budget: 3, rounds: { full: [1], incremental: [2, 3] }, gates: false, carry: 'identity-or-incremental' },
] }
const override = { run_id: 'finder-test', instruction: 'Operator requests one full review only', finders: [{ id: 'coderabbit-cloud', budget: 1, rounds: 1 }] }
for (const reader of [root, vendored]) {
  const result = reader.resolvePolicy(fixture)
  assert.deepEqual(result.stages.integration.finders, ['codex-cloud', 'coderabbit-cloud'])
  assert.deepEqual(result.stages.integration.finder, fixture.stage.integration.finder)
  const changed = reader.resolvePolicy(fixture, { runId: 'finder-test', finderOverrides: override })
  assert.equal(changed.stages.integration.finder[1].budget, 1)
  assert.equal(changed.stages.integration.finder[1].rounds, 1)
  assert.deepEqual(changed.finder_repository, fixture.stage.integration.finder)
  const validate = reader.validateFinderDisclosure ?? reader.validateResolvedPolicy
  validate(changed)
  const tampered = structuredClone(changed)
  tampered.stages.integration.finder[1].budget = 99
  assert.throws(() => validate(tampered), /disclose every difference/)
  assert.throws(() => reader.resolvePolicy(fixture, { runId: 'wrong', finderOverrides: override }), /run_id must match/)
  const candidate = structuredClone(fixture)
  candidate.stage.integration.finder[1].budget = 9
  assert.equal(reader.resolvePolicy(candidate, { mergeBaseDoc: fixture }).stages.integration.finder[1].budget, 3)
  for (const patch of [
    { budget: -1 }, { budget: 1.5 }, { gates: 'yes' }, { carry: 'maybe' },
    { trigger: '' }, { trigger_incremental: false }, { rounds: 0 },
    { rounds: { full: [1], incremental: [1] } }, { rounds: { typo: [1] } },
    { completion: { kind: 'review', actor_id: '123' } }, { typo: true },
    { completion: { kind: 'workflow', actor_id: 1, workflow: 'review' } },
    { completion: { kind: 'reaction', actor_id: 1, reaction: '+1', body: 'foreign' } },
  ]) {
    const invalid = structuredClone(fixture)
    Object.assign(invalid.stage.integration.finder[0], patch)
    assert.throws(() => reader.resolvePolicy(invalid))
  }
  const duplicate = structuredClone(fixture)
  duplicate.stage.integration.finder.push(structuredClone(duplicate.stage.integration.finder[0]))
  assert.throws(() => reader.resolvePolicy(duplicate), /duplicate finder IDs/)
}
assert.deepEqual(root.resolvePolicy(fixture).stages.integration, vendored.resolvePolicy(fixture).stages.integration)
// Schema accepts all completion kinds and rejects field/type mistakes.
const schema = JSON.parse(readFileSync('.devflow.schema.json', 'utf8'))
const finderSchema = { ...schema.$defs.integration_finder, $defs: Object.fromEntries(
  ['integration_finder', 'finder_rounds', 'finder_completion'].map(key => [key, schema.$defs[key]])
) }
const engine = createSchemaValidator(finderSchema)
engine.assertSupportedSchema(finderSchema)
for (const entry of base.stage.integration.finder) assert.deepEqual(engine.validate(entry, finderSchema, '$finder'), [])
for (const completion of [
  { kind: 'review', actor_id: 1 }, { kind: 'comment', actor_id: 1, body: 'complete' },
  { kind: 'reaction', actor_id: 1, reaction: '+1' },
  { kind: 'workflow', actor_id: 1, workflow: 'review.yml', conclusion: 'success' },
]) {
  const candidate = structuredClone(fixture)
  candidate.stage.integration.finder[0].completion = completion
  assert.deepEqual(engine.validate(candidate.stage.integration.finder[0], finderSchema, '$finder'), [])
}
for (const patch of [{ budget: -1 }, { rounds: {} }, { rounds: 0 },
  { completion: { kind: 'review', actor_id: '1' } }, { carry: 'unknown' },
  { completion: { kind: 'comment', actor_id: 1 } }, { unknown: true }]) {
  const candidate = structuredClone(fixture)
  Object.assign(candidate.stage.integration.finder[0], patch)
  assert.notEqual(engine.validate(candidate.stage.integration.finder[0], finderSchema, '$finder').length, 0)
}
console.log('root and vendored per-reviewer finder parity and schema cases OK')
JS
