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
rejects misspelled-tier-escalation sed -i '0,/tier_escalation/s//tier_escaltion/' .devflow.toml
rejects wrong-stage-finder sed -i '/^\[stage.challenge\]/,/^\[/ s/finders = \["codex-adversarial"\]/finders = ["codex-verification"]/' .devflow.toml
rejects stage-pool-role-mismatch sed -i '/^\[stage.integration\]/a pool = ["codex-cli"]' .devflow.toml

# Exercise the shipped JS parser directly. Python's tomllib also rejects
# these mutations in test-devflow-config.sh, but that would let a regression
# in toml-lite.mjs hide behind the reference parser instead of proving both
# readers enforce the same numeric grammar.
for malformed in 1e 1__2 1_; do
    cp template/.devflow.toml .devflow.toml
    sed -i "0,/challenge      = 3/s//challenge      = $malformed/" .devflow.toml
    if node scripts/devflow-policy.mjs resolve --config .devflow.toml >/dev/null 2>&1; then
        echo "FAIL: JS reader accepted malformed number: $malformed" >&2
        exit 1
    fi
done
echo "devflow v2 mutation guards OK"
