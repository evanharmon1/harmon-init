#!/usr/bin/env bash
set -euo pipefail

schema_dir="ai/schemas"
validator="scripts/validate-result-schemas.mjs"
oneshot="$schema_dir/fixtures/run.schema/valid/oneshot.json"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for schema in "$schema_dir"/*.schema.json; do
    jq empty "$schema"
done

node "$validator" run "$oneshot" >/dev/null
jq '.stage_transitions[2].stage = "security"' "$oneshot" >"$tmp"
if node "$validator" run "$tmp" >/dev/null 2>&1; then
    echo "FAIL: run validator accepted claim -> security" >&2
    exit 1
fi

echo "result schema smoke tests OK"
