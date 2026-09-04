#!/usr/bin/env bash
# Negative controls for the v2 policy validator.
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R . "$tmp/repo"
cd "$tmp/repo"
cp .devflow.toml "$tmp/pristine.devflow.toml"

reset_policy() {
    cp "$tmp/pristine.devflow.toml" .devflow.toml
}

rejects() {
    name="$1"
    shift
    "$@"
    if ./scripts/test-devflow-config.sh >/dev/null 2>&1; then
        echo "FAIL: accepted mutation: $name" >&2
        exit 1
    fi
    reset_policy
}

rejects legacy-version sed -i '0,/schema_version = 2/s//schema_version = 1/' .devflow.toml
rejects unknown-gate sed -i '0,/round_code      = "verify"/s//round_code      = "bad gate"/' .devflow.toml
rejects retired-tier-table sh -c 'printf "\n[tier.standard]\n" >> .devflow.toml'
rejects unknown-harness sed -i '0,/codex-cli/s//unknown-harness/' .devflow.toml
rejects misspelled-tier-escalation sed -i '0,/^tier_escalation/s//tier_escaltion/' .devflow.toml
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
    reset_policy
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

rejects_reader() {
    name="$1"
    shift
    reset_policy
    "$@"
    if resolve_reader 2>/dev/null; then
        echo "FAIL: JS reader accepted catalog mutation: $name" >&2
        exit 1
    fi
}

# The executable reader must enforce the same closed catalog as the schema,
# including dormant entries that this particular resolution does not select.
rejects_reader unknown-top-level-key sed -i '/^schema_version = 2$/a surprise = true' .devflow.toml
rejects_reader extra-stage-table sh -c 'printf "\n[stage.deploy]\n" >> .devflow.toml'
rejects_reader unknown-stage-key sed -i '/^\[stage.challenge\]/a surprise = []' .devflow.toml
rejects_reader missing-dormant-rigor sed -i '/^\[rigor.light\]/,/^\[rigor.standard\]/ { /^\[rigor.standard\]/!d; }' .devflow.toml
rejects_reader unknown-rigor-order-entry sed -i '0,/"light"/s//"ghost"/' .devflow.toml

# Reader-specific semantic controls. These bypass the Python structural gate
# so each failure proves the shipped JavaScript reader enforces the contract.
reset_policy
sed -i '/^\[rounds.light\]/,/^\[/ s/challenge      = 2/challenge      = "oops"/' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted malformed inactive rounds policy" >&2
    exit 1
fi

reset_policy
sed -i '/^\[rounds.standard\]/,/^\[/ s/wall_clock_min = 120/wall_clock_min = 0/' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted zero wall-clock ceiling" >&2
    exit 1
fi

reset_policy
sed -i '/^\[role.implementer\]/,/^\[/ s/families  = \["claude", "gpt", "gemini"\]/families  = ["claude"]/' .devflow.toml
if resolve_reader --strategy council 2>/dev/null; then
    echo "FAIL: JS reader counted council families outside implementer eligibility" >&2
    exit 1
fi

reset_policy
resolve_reader --rigor cursory --strategy oneshot

resolved="$(node scripts/devflow-policy.mjs resolve \
    --policy=.devflow.toml \
    --registry=agent-registry.json \
    --taskfile-dir=. \
    --rigor=forensic \
    --strategy=oneshot \
    --json)"
if [ "$(printf '%s' "$resolved" | jq -r '.rigor.level')" != "forensic" ]; then
    echo "FAIL: JS reader did not honor --key=value options" >&2
    exit 1
fi
if resolve_reader --rigro forensic 2>unknown-option.err; then
    echo "FAIL: JS reader accepted an unknown option" >&2
    exit 1
fi
grep -q 'unsupported option' unknown-option.err || {
    echo "FAIL: unknown option did not produce an explicit diagnostic" >&2
    exit 1
}

reset_policy
sed -i '/^\[role\.implementer\]/,/^\[/ s/harnesses = \[/harnesses = "not-an-array" #/' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted a non-array role harness preference" >&2
    exit 1
fi

reset_policy
sed -i '/^\[role\.implementer\]/a harneses = ["codex-cli"]' .devflow.toml
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted an unknown role preference key" >&2
    exit 1
fi

reset_policy
sed -i '/^\[strategy\.orchestrate\]/,/^\[/ s/delegation   = "required"/delegation   = "none"/' .devflow.toml
if resolve_reader --strategy orchestrate 2>/dev/null; then
    echo "FAIL: JS reader accepted lead-and-workers with delegation=none" >&2
    exit 1
fi

reset_policy
sed -i 's/^\[strategy\.council\]/[strategy.panel]/' .devflow.toml
sed -i '/^\[role\.implementer\]/,/^\[/ s/families  = \["claude", "gpt", "gemini"\]/families  = ["claude"]/' .devflow.toml
if resolve_reader --strategy panel 2>/dev/null; then
    echo "FAIL: JS reader let a renamed independent-proposals strategy bypass distinct-family validation" >&2
    exit 1
fi

reset_policy
cat >>.devflow.toml <<'EOF'

[rigor.standard.convergence]
converged = { all = [
  { predicate = "no_gating_findings" },
  { predicate = "repeat_after_fix" },
] }
EOF
resolve_reader

reset_policy
if resolve_reader --closure /tmp/not-a-trust-boundary 2>closure.err; then
    echo "FAIL: JS reader accepted retired in-module --closure delegation" >&2
    exit 1
fi
grep -q 'cannot establish reader trust' closure.err || {
    echo "FAIL: --closure refusal did not explain the external trust boundary" >&2
    exit 1
}
echo "devflow v2 mutation guards OK"
