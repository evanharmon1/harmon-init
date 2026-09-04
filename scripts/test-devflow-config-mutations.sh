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

replace_once() {
    python3 - "$1" "$2" <<'PY'
import pathlib
import sys

path = pathlib.Path(".devflow.toml")
text = path.read_text()
old, new = sys.argv[1:]
if text.count(old) != 1:
    raise SystemExit(f"expected exactly one occurrence of {old!r}, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
PY
}

replace_in_table() {
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib
import sys

path = pathlib.Path(".devflow.toml")
table, old, new = sys.argv[1:]
text = path.read_text()
marker = f"[{table}]"
start = text.index(f"\n{marker}\n") + 1
end = text.find("\n[", start + len(marker))
if end == -1:
    end = len(text)
section = text[start:end]
if section.count(old) != 1:
    raise SystemExit(
        f"expected exactly one occurrence of {old!r} in {marker}, found {section.count(old)}"
    )
path.write_text(text[:start] + section.replace(old, new, 1) + text[end:])
PY
}

append_text() {
    python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(".devflow.toml")
path.write_text(path.read_text() + sys.argv[1])
PY
}

delete_table() {
    python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(".devflow.toml")
text = path.read_text()
marker = f"[{sys.argv[1]}]"
start = text.index(f"\n{marker}\n") + 1
end = text.find("\n[", start + len(marker))
if end == -1:
    path.write_text(text[:start])
else:
    path.write_text(text[:start] + text[end + 1 :])
PY
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

rejects legacy-version replace_once 'schema_version = 2' 'schema_version = 1'
rejects unknown-gate replace_in_table gates 'round_code      = "verify"' 'round_code      = "bad gate"'
rejects retired-tier-table append_text $'\n[tier.standard]\n'
rejects unknown-harness replace_in_table role.implementer '"codex-cli"' '"unknown-harness"'
rejects misspelled-tier-escalation replace_in_table rigor.cursory tier_escalation tier_escaltion
rejects wrong-stage-finder replace_in_table stage.challenge 'finders = ["codex-adversarial"]' 'finders = ["codex-verification"]'
rejects stage-pool-role-mismatch replace_in_table stage.integration '[stage.integration]' $'[stage.integration]\npool = ["codex-cli"]'
rejects invalid-strategy-topology replace_in_table strategy.oneshot 'topology    = "single-agent"' 'topology    = "nonsense"'
rejects invalid-strategy-planning replace_in_table strategy.oneshot 'planning    = "inline"' 'planning    = "nonsense"'
rejects invalid-strategy-delegation replace_in_table strategy.oneshot 'delegation  = "none"' 'delegation  = "nonsense"'
rejects unknown-strategy-key replace_in_table strategy.oneshot '[strategy.oneshot]' $'[strategy.oneshot]\nsurprise = true'
rejects constitutional-strategy-gate replace_in_table strategy.oneshot 'human_gates = []' 'human_gates = ["merge"]'
rejects inverted-role-tier replace_in_table rigor.cursory 'implementer_tier  = "economy"' 'implementer_tier  = "apex"'
rejects adaptive-role-tier replace_in_table rigor.standard 'reviewer_tier     = "standard"' 'reviewer_tier     = "adaptive"'

# Exercise the shipped JS parser directly. Python's tomllib also rejects
# these mutations in test-devflow-config.sh, but that would let a regression
# in toml-lite.mjs hide behind the reference parser instead of proving both
# readers enforce the same numeric grammar.
for malformed in 1e 1__2 1_; do
    reset_policy
    replace_in_table rounds.standard 'challenge      = 3' "challenge      = $malformed"
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
rejects_reader unknown-top-level-key replace_once 'schema_version = 2' $'schema_version = 2\nsurprise = true'
rejects_reader extra-stage-table append_text $'\n[stage.deploy]\n'
rejects_reader unknown-stage-key replace_in_table stage.challenge '[stage.challenge]' $'[stage.challenge]\nsurprise = []'
rejects_reader missing-dormant-rigor delete_table rigor.light
rejects_reader unknown-rigor-order-entry replace_once \
    'rigor_order = ["cursory", "light", "standard", "thorough", "deep", "forensic"]' \
    'rigor_order = ["cursory", "ghost", "standard", "thorough", "deep", "forensic"]'

# Reader-specific semantic controls. These bypass the Python structural gate
# so each failure proves the shipped JavaScript reader enforces the contract.
reset_policy
replace_in_table rounds.light 'challenge      = 2' 'challenge      = "oops"'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted malformed inactive rounds policy" >&2
    exit 1
fi

reset_policy
replace_in_table rounds.standard 'wall_clock_min = 120' 'wall_clock_min = 0'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted zero wall-clock ceiling" >&2
    exit 1
fi

reset_policy
replace_in_table role.implementer 'families  = ["claude", "gpt", "gemini"]' 'families  = ["claude"]'
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
replace_in_table role.implementer \
    'harnesses = ["claude-code", "codex-cli", "antigravity"]' \
    'harnesses = "not-an-array"'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted a non-array role harness preference" >&2
    exit 1
fi

reset_policy
replace_in_table role.implementer '[role.implementer]' $'[role.implementer]\nharneses = ["codex-cli"]'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted an unknown role preference key" >&2
    exit 1
fi

reset_policy
replace_in_table strategy.orchestrate 'delegation   = "required"' 'delegation   = "none"'
if resolve_reader --strategy orchestrate 2>/dev/null; then
    echo "FAIL: JS reader accepted lead-and-workers with delegation=none" >&2
    exit 1
fi

reset_policy
replace_once '[strategy.council]' '[strategy.panel]'
replace_in_table role.implementer 'families  = ["claude", "gpt", "gemini"]' 'families  = ["claude"]'
if resolve_reader --strategy panel 2>/dev/null; then
    echo "FAIL: JS reader let a renamed independent-proposals strategy bypass distinct-family validation" >&2
    exit 1
fi

reset_policy
append_text '
[rigor.standard.convergence]
converged = { all = [
  { predicate = "no_gating_findings" },
  { predicate = "repeat_after_fix" },
] }
'
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
