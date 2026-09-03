#!/usr/bin/env bash
# Negative controls for the v2 policy validator.
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R . "$tmp/repo"
cd "$tmp/repo"

rejects() {
    name="$1"
    shift
    "$@"
    if ./scripts/test-devflow-config.sh >/dev/null 2>&1; then
        echo "FAIL: accepted mutation: $name" >&2
        exit 1
    fi
    cp template/.devflow.toml .devflow.toml
}

rejects legacy-version sed -i '0,/schema_version = 2/s//schema_version = 1/' .devflow.toml
rejects unknown-gate sed -i '0,/round_code      = "verify"/s//round_code      = "bad gate"/' .devflow.toml
rejects retired-tier-table sh -c 'printf "\n[tier.standard]\n" >> .devflow.toml'
rejects unknown-harness sed -i '0,/codex-cli/s//unknown-harness/' .devflow.toml
echo "devflow v2 mutation guards OK"
