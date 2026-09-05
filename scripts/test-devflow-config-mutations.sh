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
rejects_reader duplicate-fallback-finder replace_in_table stage.challenge \
    '# finder_fallbacks = []' \
    'finder_fallbacks = ["codex-verification", "codex-verification"]'
rejects_reader missing-dormant-rigor delete_table rigor.light
rejects_reader unknown-rigor-order-entry replace_once \
    'rigor_order = ["cursory", "light", "standard", "thorough", "deep", "forensic"]' \
    'rigor_order = ["cursory", "ghost", "standard", "thorough", "deep", "forensic"]'

reset_policy
replace_in_table rigor.standard \
    'breadth           = "standard"' \
    $'breadth           = "standard"\nspend             = "standard"'
append_text $'\n[spend.standard]\nmax_tokens = 1000\nmax_usd = 1.5\n'
spend_resolved="$(node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --registry agent-registry.json \
    --taskfile-dir . \
    --json)"
if [ "$(printf '%s' "$spend_resolved" | jq -r '.spend.policy')" != "standard" ]; then
    echo "FAIL: JS reader did not resolve an optional per-rigor spend policy" >&2
    exit 1
fi

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
replace_in_table stage.review \
    '[stage.review]' \
    $'[stage.review]\npool = ["claude-code"]'
replace_in_table role.reviewer \
    'families  = ["gpt", "claude", "gemini"]    # (preference)' \
    'families  = ["gpt"]'
replace_in_table role.reviewer \
    'harnesses = ["codex-cli", "claude-code"]  # (preference) — same' \
    'harnesses = ["codex-cli"]'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted a stage pool with no executable role-routing intersection" >&2
    exit 1
fi

bad_finder_registry="$tmp/bad-finder-registry.json"
jq '(.finders[] | select(.slug == "codex-adversarial").invocation.target) = "missing:target"' \
    agent-registry.json >"$bad_finder_registry"
reset_policy
if node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --registry "$bad_finder_registry" \
    --taskfile-dir . >/dev/null 2>&1; then
    echo "FAIL: JS reader accepted a local finder with a missing Taskfile target" >&2
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
replace_in_table role.reviewer \
    'harnesses = ["codex-cli", "claude-code"]  # (preference) — same' \
    '# harness preference intentionally omitted; every compatible harness is eligible'
replace_in_table stage.review \
    '[stage.review]' \
    $'[stage.review]\npool = ["codex-cli"]'
resolve_reader

reset_policy
replace_in_table strategy.human-led 'delegation  = "optional"' 'delegation  = "none"'
resolve_reader --strategy human-led

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
replace_in_table convergence \
    'converged = { all = [ { predicate = "no_gating_findings" } ] }' \
    'converged = { all = [ { predicate = "no_gating_findings" } ], extra_condition = true }'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted an unknown convergence composition key" >&2
    exit 1
fi

reset_policy
replace_in_table convergence \
    'converged = { all = [ { predicate = "no_gating_findings" } ] }' \
    'converged = { all = [ { predicate = "no_gating_findings" }, { any = [ { predicate = "provenance_share", min = 0.5 }, { predicate = "repeat_after_fix" } ] } ] }'
append_text '
[rigor.standard.convergence]
converged = { all = [ { predicate = "no_gating_findings" }, { any = [ { min = 0.5, predicate = "provenance_share" }, { predicate = "repeat_after_fix" } ] } ] }
'
resolve_reader

reset_policy
replace_in_table convergence \
    'exclude_classes = ["design"]' \
    'exclude_classes = ["design", "design"]'
if resolve_reader 2>/dev/null; then
    echo "FAIL: JS reader accepted duplicate convergence exclude_classes" >&2
    exit 1
fi

reset_policy
if resolve_reader --closure /tmp/not-a-trust-boundary 2>closure.err; then
    echo "FAIL: JS reader accepted retired in-module --closure delegation" >&2
    exit 1
fi
grep -q 'cannot establish reader trust' closure.err || {
    echo "FAIL: --closure refusal did not explain the external trust boundary" >&2
    exit 1
}

task_targets="$tmp/task-targets.json"
task --list --json >"$task_targets"
node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --registry agent-registry.json \
    --task-targets "$task_targets" >/dev/null

# A requested selection belongs to the governing merge-base catalog. The
# candidate v2 catalog is still validated in full, but through its own defaults
# so a renamed v1-only rigor/strategy cannot be rejected by branch vocabulary
# before the trusted policy is decoded. Directly compatible v1 budget,
# strategy, and three-role tier values must survive that decode.
historical_policy="$tmp/historical-v1.toml"
cat >"$historical_policy" <<'TOML'
schema_version = 1
default_rigor = "standard"
default_strategy = "plan"
rigor_order = ["trivial", "standard"]

[rigor.trivial]
review = "driveby"
orchestrator_tier = "local"
implementer_tier = "local"
reviewer_tier = "economy"
budget = "bounded"

[rigor.standard]
review = "standard"
orchestrator_tier = "frontier"
implementer_tier = "standard"
reviewer_tier = "frontier"
budget = "bounded"

[review.driveby]
challenge = 1
review = 1
shepherd = 1
min_rounds = 1

[review.standard]
challenge = 3
review = 3
shepherd = 4
min_rounds = 1

[budget.bounded]
max_agent_runs = 7
max_parallel_agents = 2
wall_clock_min = 77
allow_tier_escalation = true

[strategy.plan]
topology = "single-agent"
planning = "explicit"
delegation = "optional"
human_gates = []
description = "Historical plan"

[strategy.legacy-council]
topology = "independent-proposals"
planning = "independent"
delegation = "required"
selection = "judge"
synthesis = true
min_agents = 2
human_gates = []
description = "Historical council"
TOML
historical_resolved="$(node scripts/devflow-policy.mjs resolve \
    --policy .devflow.toml \
    --merge-base-policy "$historical_policy" \
    --merge-base-registry agent-registry.json \
    --taskfile-dir . \
    --rigor trivial \
    --strategy legacy-council \
    --json)"
printf '%s' "$historical_resolved" | jq -e '
    .source == "merge-base-historical-decode:v1" and
    .rigor.level == "trivial" and
    .rigor.tier_escalation == true and
    .rounds.wall_clock_min == 77 and
    .breadth == {policy:"v1:bounded", max_agent_runs:7, max_parallel_agents:2} and
    .roles.orchestrator.tier == "local" and
    .roles.implementer.tier == "local" and
    .roles.reviewer.tier == "economy" and
    .roles.challenger.tier == "economy" and
    .strategy.name == "legacy-council" and
    .strategy.topology == "independent-proposals"
' >/dev/null || {
    echo "FAIL: JS reader did not preserve compatible merge-base v1 values" >&2
    exit 1
}

# Family, harness, and model tier must intersect in one executable tuple.
# Gemini can run through Antigravity and Claude has an apex model, but
# Antigravity cannot execute Claude; independent existence checks would accept
# this impossible role configuration.
reset_policy
replace_in_table role.implementer \
    'families  = ["claude", "gpt", "gemini"]' \
    'families  = ["gemini", "claude"]'
replace_in_table role.implementer \
    'harnesses = ["claude-code", "codex-cli", "antigravity"]' \
    'harnesses = ["antigravity"]'
replace_in_table rigor.standard 'orchestrator_tier = "frontier"' 'orchestrator_tier = "apex"'
replace_in_table rigor.standard 'implementer_tier  = "standard"' 'implementer_tier  = "apex"'
replace_in_table rigor.standard 'challenger_tier   = "frontier"' 'challenger_tier   = "apex"'
replace_in_table rigor.standard 'reviewer_tier     = "standard"' 'reviewer_tier     = "apex"'
if resolve_reader --strategy oneshot 2>/dev/null; then
    echo "FAIL: JS reader accepted a role with no executable family/harness/tier tuple" >&2
    exit 1
fi
echo "devflow v2 mutation guards OK"
