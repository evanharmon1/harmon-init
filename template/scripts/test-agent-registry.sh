#!/usr/bin/env bash
# test-agent-registry.sh — schema-check the registry and exercise semantic guards.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

registry="${1:-agent-registry.json}"
schema="${2:-agent-registry.schema.json}"
validator="scripts/validate-agent-registry.mjs"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

for required in "$registry" "$schema" "$validator"; do
    [ -f "$required" ] || fail "missing required registry asset: $required"
done
command -v node >/dev/null 2>&1 || fail "node is required to validate the agent registry"

node "$validator" "$registry" "$schema"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
mutated="${test_tmp}/agent-registry.json"
mutated_schema="${test_tmp}/agent-registry.schema.json"

rejects() {
    local description="$1"
    local mutation="$2"
    local expected="$3"
    local output

    if ! node --input-type=module - "$registry" "$mutated" "$mutation" <<'NODE'; then
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath, mutation] = process.argv.slice(2)
const registry = JSON.parse(await readFile(inputPath, 'utf8'))
const adapter = (slug) => registry.foreman_adapters.find((entry) => entry.slug === slug)
const harness = (slug) => registry.harnesses.find((entry) => entry.slug === slug)

switch (mutation) {
  case 'duplicate-family':
    registry.families.push(structuredClone(registry.families[0]))
    break
  case 'duplicate-harness':
    registry.harnesses.push(structuredClone(registry.harnesses[0]))
    break
  case 'missing-model-owner':
    delete registry.harnesses[0].model_resolution.owner
    break
  case 'unknown-fixed-family':
    registry.harnesses[0].family_constraint.family = 'unknown'
    break
  case 'family-on-none':
    for (const entry of registry.harnesses) {
      if (entry.family_constraint.kind === 'none') entry.family_constraint.family = 'claude'
    }
    break
  case 'production-without-harness':
    adapter('claude').harness = null
    break
  case 'harness-axis':
    registry.labels.suggest.axis = 'harness'
    break
  case 'public-mock':
    adapter('mock').provision_label = true
    break
  case 'bad-minimax-slug':
    harness('claude-code-minimax').slug = 'claude-code-mini'
    break
  case 'bad-claude-harness':
    adapter('claude').harness = 'qwen-code'
    break
  case 'non-production-claude':
    Object.assign(adapter('claude'), {
      classification: 'test-only',
      production_dispatchable: false,
      provision_label: false
    })
    break
  default:
    throw new Error(`unknown mutation: ${mutation}`)
}

await writeFile(outputPath, `${JSON.stringify(registry, null, 2)}\n`)
NODE
        fail "could not build mutation: $description"
    fi
    if output="$(node "$validator" "$mutated" "$schema" 2>&1)"; then
        fail "validator accepted mutation: $description"
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
    echo "PASS: rejects $description"
}

rejects "duplicate family slugs" \
    'duplicate-family' \
    'duplicate family slug'
rejects "duplicate harness slugs" \
    'duplicate-harness' \
    'duplicate harness slug'
rejects "missing model-resolution ownership" \
    'missing-model-owner' \
    'missing required property owner'
rejects "unknown fixed-family constraints" \
    'unknown-fixed-family' \
    'references unknown family unknown'
rejects "family values on unconstrained harnesses" \
    'family-on-none' \
    'with a none constraint'
rejects "production adapters without a harness mapping" \
    'production-without-harness' \
    'needs a production harness mapping'
rejects "harness-centric suggestion labels" \
    'harness-axis' \
    'must equal "model"'
rejects "public labels for the test-only mock adapter" \
    'public-mock' \
    'test-only Foreman adapter mock cannot dispatch or provision a public label'
rejects "a non-normalized MiniMax harness slug" \
    'bad-minimax-slug' \
    'must be named claude-code-<fixed-family>'
rejects "a legacy claude adapter mapped to the wrong harness" \
    'bad-claude-harness' \
    'legacy Foreman adapter claude must map claude.sh to harness claude-code'
rejects "a non-production legacy claude adapter" \
    'non-production-claude' \
    'legacy Foreman adapter claude must be production-dispatchable and provisionable'

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.minProperties = 99
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted an unsupported schema keyword"
fi
case "$output" in
*'unsupported schema keyword minProperties'*) ;;
*) fail "unsupported schema keyword failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects unsupported schema keywords"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name.minLength = 'one'
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a malformed minLength value"
fi
case "$output" in
*'minLength: must be a non-negative integer'*) ;;
*) fail "malformed minLength failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects malformed supported schema keyword values"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.$defs.model.properties.display_name = {
  $ref: '#/properties/schema_version/const'
}
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a reference to a primitive schema node"
fi
case "$output" in
*'does not resolve to an object schema'*) ;;
*) fail "primitive schema reference failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects references to primitive schema nodes"

node --input-type=module - "$schema" "$mutated_schema" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath] = process.argv.slice(2)
const schema = JSON.parse(await readFile(inputPath, 'utf8'))
schema.properties.families.items = false
await writeFile(outputPath, `${JSON.stringify(schema, null, 2)}\n`)
NODE
if output="$(node "$validator" "$registry" "$mutated_schema" 2>&1)"; then
    fail "validator accepted a boolean items schema"
fi
case "$output" in
*'boolean and non-object schemas are not supported'*) ;;
*) fail "boolean items schema failed for the wrong reason: $output" ;;
esac
echo "PASS: rejects boolean items schemas"

echo "agent registry mutation tests OK"
