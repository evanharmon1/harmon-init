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
rejects invalid-strategy-topology sed -i '0,/topology    = "single-agent"/s//topology    = "nonsense"/' .devflow.toml
rejects invalid-strategy-planning sed -i '0,/planning    = "inline"/s//planning    = "nonsense"/' .devflow.toml
rejects invalid-strategy-delegation sed -i '0,/delegation  = "none"/s//delegation  = "nonsense"/' .devflow.toml
rejects unknown-strategy-key sed -i '/^\[strategy.oneshot\]/a surprise = true' .devflow.toml
rejects constitutional-strategy-gate sed -i '0,/human_gates = \[\]/s//human_gates = ["merge"]/' .devflow.toml
rejects inverted-role-tier sed -i '/^\[rigor.cursory\]/,/^\[/ s/implementer_tier  = "economy"/implementer_tier  = "apex"/' .devflow.toml
rejects adaptive-role-tier sed -i '/^\[rigor.standard\]/,/^\[/ s/reviewer_tier     = "standard"/reviewer_tier     = "adaptive"/' .devflow.toml

# Exercise the shipped JS parser directly. Python's tomllib also rejects
# these mutations in test-devflow-config.sh, but that would let a regression
# in toml-lite.mjs hide behind the reference parser instead of proving both
# readers enforce the same numeric grammar.
for malformed in 1e 1__2 1_; do
    cp template/.devflow.toml .devflow.toml
    sed -i "0,/challenge      = 3/s//challenge      = $malformed/" .devflow.toml
    if node scripts/devflow-policy.mjs resolve --policy .devflow.toml >/dev/null 2>&1; then
        echo "FAIL: JS reader accepted malformed number: $malformed" >&2
        exit 1
    fi
done

resolve_reader() {
    node scripts/devflow-policy.mjs resolve \
        --policy .devflow.toml \
        --registry agent-registry.json \
        --taskfile-dir . \
        "$@" >/dev/null
}

# Reader-specific semantic controls. These bypass the Python structural gate
# so each failure proves the shipped JavaScript reader enforces the contract.
cp template/.devflow.toml .devflow.toml
sed -i '/^\[rounds.light\]/,/^\[/ s/challenge      = 2/challenge      = "oops"/' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted malformed inactive rounds policy" >&2
    exit 1
fi

cp template/.devflow.toml .devflow.toml
sed -i '/^\[rounds.standard\]/,/^\[/ s/wall_clock_min = 120/wall_clock_min = 0/' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted zero wall-clock ceiling" >&2
    exit 1
fi

cp template/.devflow.toml .devflow.toml
sed -i '/^\[role.implementer\]/,/^\[/ s/families  = \["claude", "gpt", "gemini"\]/families  = ["claude"]/' .devflow.toml
if resolve_reader --strategy council 2>/dev/null; then
    echo "FAIL: JS reader counted council families outside implementer eligibility" >&2
    exit 1
fi

cp template/.devflow.toml .devflow.toml
resolve_reader --rigor cursory --strategy oneshot

if resolve_reader --closure /tmp/not-a-trust-boundary 2>closure.err; then
    echo "FAIL: JS reader accepted retired in-module --closure delegation" >&2
    exit 1
fi
grep -q 'cannot establish reader trust' closure.err || {
    echo "FAIL: --closure refusal did not explain the external trust boundary" >&2
    exit 1
}
echo "devflow v2 mutation guards OK"
