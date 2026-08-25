#!/usr/bin/env bash
# test-devflow-config-mutations.sh — prove test-devflow-config.sh REJECTS bad
# configs, not only that it accepts the good one.
#
# test:devflow-config runs the validator against the checked-in (valid)
# config, so it proves the happy path and nothing else: a regression that
# stopped rejecting a role tier of `adaptive`, a rigor_order that isn't a
# permutation, a constitutional human_gate, an undocumented strategy×rigor
# incompatibility, or a description that drifted from label-registry.json
# would leave that task green. This test exercises each advertised
# rejection by mutating a throwaway copy of the whole config layout and
# asserting the validator fails with the expected reason — the same shape as
# test-agent-registry.sh's `rejects` cases. Root-only, like the validator it
# guards.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$PWD" <<'PY'
import os
import re
import shutil
import subprocess
import sys
import tempfile

repo = sys.argv[1]
# The validator reads both .devflow.toml copies, both label + agent
# registries, both AGENTS files, docs/guides/devflow.md (existence only),
# and shells out to scripts/devflow-resolve.py — a mutation layout has to
# mirror that whole surface.
LAYOUT = [
    "label-registry.json",
    "agent-registry.json",
    "AGENTS.md",
    ".devflow.toml",
    "scripts/test-devflow-config.sh",
    "scripts/devflow-resolve.py",
    "docs/guides/devflow.md",
    "template/label-registry.json",
    "template/agent-registry.json",
    "template/.devflow.toml",
    "template/AGENTS.md.jinja",
]

failures = []


def build(tmp):
    for rel in LAYOUT:
        dest = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy(os.path.join(repo, rel), dest)


def edit_toml(tmp, fn):
    # Mutate both .devflow.toml copies identically, so the twin-parity check
    # is not what trips — we are testing the rigor/strategy logic, not that
    # gate.
    for rel in (".devflow.toml", "template/.devflow.toml"):
        p = os.path.join(tmp, rel)
        content = open(p).read()  # read before opening for write — truncation first would empty it
        open(p, "w").write(fn(content))


def edit_registry(tmp, fn):
    import json
    for rel in ("agent-registry.json", "template/agent-registry.json"):
        p = os.path.join(tmp, rel)
        reg = json.load(open(p))
        fn(reg)
        json.dump(reg, open(p, "w"), indent=2)


def edit_label_registry(tmp, fn):
    import json
    for rel in ("label-registry.json", "template/label-registry.json"):
        p = os.path.join(tmp, rel)
        reg = json.load(open(p))
        fn(reg)
        json.dump(reg, open(p, "w"), indent=2)


def run(tmp):
    return subprocess.run(
        ["bash", "scripts/test-devflow-config.sh"],
        cwd=tmp, capture_output=True, text=True,
    )


def rejects(description, mutate, expect):
    tmp = tempfile.mkdtemp()
    try:
        build(tmp)
        mutate(tmp)
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"{description}: validator ACCEPTED a config it must reject")
        elif expect not in (result.stdout + result.stderr):
            failures.append(
                f"{description}: rejected, but no message matched {expect!r}\n"
                f"        got: {result.stderr.strip().splitlines()[-1] if result.stderr.strip() else '(no stderr)'}"
            )
        else:
            print(f"  REJECTS: {description}")
    finally:
        shutil.rmtree(tmp)


def accepts(description):
    tmp = tempfile.mkdtemp()
    try:
        build(tmp)
        result = run(tmp)
        if result.returncode != 0:
            failures.append(
                f"{description}: validator REJECTED the checked-in valid config\n"
                f"        {result.stderr.strip()}"
            )
        else:
            print(f"  ACCEPTS: {description}")
    finally:
        shutil.rmtree(tmp)


def sub(old, new):
    def fn(tmp):
        edit_toml(tmp, lambda t: t.replace(old, new))
    return fn


# Control: the unmutated layout must pass, or every rejection below is vacuous.
accepts("the checked-in configuration")

# ── Removed top-level shape (ADR 0007) ──────────────────────────────────────
rejects("default_tier still present", sub(
    'default_strategy = "plan"', 'default_strategy = "plan"\ndefault_tier = "standard"'
), "'default_tier' is present but was removed")
rejects("default_method still present", sub(
    'default_strategy = "plan"', 'default_strategy = "plan"\ndefault_method = "plan"'
), "'default_method' is present but was removed")
rejects("[method] table still present", sub(
    'claude = "fable"\ngpt    = "sol"',
    'claude = "fable"\ngpt    = "sol"\n\n[method]\n'
    'rank = ["human-led", "plan-approved", "council", "orchestrate", "plan", "oneshot"]',
), "[method] table is present")

# ── rigor_order ──────────────────────────────────────────────────────────
rejects("rigor_order has a duplicate entry (rank violation)", sub(
    'rigor_order = ["trivial", "minimal", "light", "standard", "thorough", "deep"]',
    'rigor_order = ["trivial", "minimal", "light", "standard", "thorough", "thorough"]',
), "duplicate entries")
rejects("rigor_order missing a level", sub(
    'rigor_order = ["trivial", "minimal", "light", "standard", "thorough", "deep"]',
    'rigor_order = ["trivial", "minimal", "light", "standard", "thorough"]',
), "is not a permutation of [rigor.*]")
rejects("rigor_order not monotonic (light and standard swapped)", sub(
    'rigor_order = ["trivial", "minimal", "light", "standard", "thorough", "deep"]',
    'rigor_order = ["trivial", "minimal", "standard", "light", "thorough", "deep"]',
), "is not monotonic")

# ── [rigor.*] ────────────────────────────────────────────────────────────
rejects("a role tier of adaptive", sub(
    'implementer_tier   = "economy"\nreviewer_tier      = "economy"\nbudget             = "trivial"',
    'implementer_tier   = "adaptive"\nreviewer_tier      = "economy"\nbudget             = "trivial"',
), "is not a concrete ladder tier")
rejects("orchestrator_tier below implementer_tier", sub(
    'orchestrator_tier  = "frontier"\nimplementer_tier   = "standard"\nreviewer_tier      = "frontier"\nbudget             = "standard"',
    'orchestrator_tier  = "economy"\nimplementer_tier   = "standard"\nreviewer_tier      = "frontier"\nbudget             = "standard"',
), "must satisfy orchestrator_tier >= implementer_tier")
rejects("a budget reference that resolves nothing", sub(
    'budget             = "trivial"\ndescription        = "Rigor: no AI review',
    'budget             = "nonexistent"\ndescription        = "Rigor: no AI review',
), "names no [budget.*] profile")
rejects("a review reference that resolves nothing", sub(
    'review             = "none"\norchestrator_tier  = "economy"',
    'review             = "nonexistent"\norchestrator_tier  = "economy"',
), "names no [review.*] policy")
rejects("a rigor description drifted from the label registry", sub(
    'description        = "Rigor: no AI review, economy tiers throughout, smallest budget — near-zero-risk changes"',
    'description        = "Rigor: something completely different from the seeded label"',
), "does not match the rigor:trivial label description")

# ── [review.*] ───────────────────────────────────────────────────────────
rejects("min_rounds above every stage cap", sub(
    '[review.driveby]\nchallenge  = 1\nreview     = 1\nshepherd   = 1\nmin_rounds = 1',
    '[review.driveby]\nchallenge  = 1\nreview     = 1\nshepherd   = 1\nmin_rounds = 2',
), "exceeds min(challenge, review, shepherd)")
rejects("review.none with min_rounds forced above 0", sub(
    '[review.none]\nchallenge  = 0\nreview     = 0\nshepherd   = 0\nmin_rounds = 0',
    '[review.none]\nchallenge  = 0\nreview     = 0\nshepherd   = 0\nmin_rounds = 1',
), "exceeds min(challenge, review, shepherd)")
rejects("a negative stage cap", sub(
    '[review.driveby]\nchallenge  = 1', '[review.driveby]\nchallenge  = -1',
), "must be >= 0")

# ── [budget.*] ───────────────────────────────────────────────────────────
rejects("a non-boolean allow_tier_escalation", sub(
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\nwall_clock_min        = 15\nallow_tier_escalation = false',
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\nwall_clock_min        = 15\nallow_tier_escalation = "false"',
), "must be a boolean")
rejects("a zero max_agent_runs", sub(
    '[budget.trivial]\nmax_agent_runs        = 1', '[budget.trivial]\nmax_agent_runs        = 0',
), "must be an integer > 0")

# ── [strategy.*] ─────────────────────────────────────────────────────────
rejects("council with min_agents lowered to 1", sub(
    'selection   = "judge"\nsynthesis   = true\nmin_agents  = 2',
    'selection   = "judge"\nsynthesis   = true\nmin_agents  = 1',
), "must be an integer >= 2")
rejects("an unknown field on a strategy table", sub(
    '[strategy.oneshot]\ntopology    = "single-agent"',
    '[strategy.oneshot]\ntopology    = "single-agent"\nbogus_field = "x"',
), "has unknown key(s)")
rejects("an invalid topology enum value", sub(
    '[strategy.oneshot]\ntopology    = "single-agent"',
    '[strategy.oneshot]\ntopology    = "some-made-up-topology"',
), "not in")

# ── topology/delegation triangle (single-agent forbids required;
# lead-and-workers requires required; delegation=none only with
# single-agent) ──────────────────────────────────────────────────────────
rejects("topology=single-agent with delegation=required", sub(
    '[strategy.oneshot]\ntopology    = "single-agent"\nplanning    = "inline"\ndelegation  = "none"',
    '[strategy.oneshot]\ntopology    = "single-agent"\nplanning    = "inline"\ndelegation  = "required"',
), "forbids delegation=required")
rejects("topology=lead-and-workers with delegation=optional", sub(
    'topology     = "lead-and-workers"\nplanning     = "explicit"\ndelegation   = "required"',
    'topology     = "lead-and-workers"\nplanning     = "explicit"\ndelegation   = "optional"',
), "requires delegation=required")
rejects("topology=independent-proposals (council) with delegation=optional", sub(
    'topology    = "independent-proposals"\nplanning    = "independent"\ndelegation  = "required"',
    'topology    = "independent-proposals"\nplanning    = "independent"\ndelegation  = "optional"',
), "requires delegation=required")
rejects("delegation=none with a non-single-agent topology", sub(
    'topology    = "human-directed"\nplanning    = "collaborative"\ndelegation  = "optional"',
    'topology    = "human-directed"\nplanning    = "collaborative"\ndelegation  = "none"',
), "delegation=none is only valid with topology=single-agent")
rejects("a constitutional gate in human_gates", sub(
    '[strategy.plan-approved]\ntopology    = "single-agent"\nplanning    = "explicit"\ndelegation  = "optional"\nhuman_gates = ["after-plan"]',
    '[strategy.plan-approved]\ntopology    = "single-agent"\nplanning    = "explicit"\ndelegation  = "optional"\nhuman_gates = ["after-plan", "merge"]',
), "constitutional gate")
rejects("an unrecognized (non-constitutional) human gate", sub(
    '[strategy.oneshot]\ntopology    = "single-agent"\nplanning    = "inline"\ndelegation  = "none"\nhuman_gates = []',
    '[strategy.oneshot]\ntopology    = "single-agent"\nplanning    = "inline"\ndelegation  = "none"\nhuman_gates = ["not-a-real-gate"]',
), "not in the allowed set")
rejects("a strategy description drifted from the label registry", sub(
    'description = "Strategy: single agent, no separate plan phase"',
    'description = "Strategy: something completely different from the seeded label"',
), "does not match the strategy:oneshot label description")

# ── strategy × rigor compatibility matrix ───────────────────────────────
def widen_trivial_budget(tmp):
    # If council's min_agents no longer exceeds trivial's budget, the
    # KNOWN_INCOMPATIBLE entry for (council, trivial) goes stale — the
    # validator must catch a documented incompatibility that stopped being
    # one, not just an undocumented one that started being one. (Widening
    # also moots orchestrate's min_agents=2 against trivial, so this single
    # mutation exercises staleness for both documented entries at once.)
    edit_toml(tmp, lambda t: t.replace(
        '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1',
        '[budget.trivial]\nmax_agent_runs        = 4\nmax_parallel_agents   = 4',
    ))
rejects("a documented incompatibility (council x trivial) that no longer applies",
        widen_trivial_budget, "but it actually resolves cleanly now")


def edit_script(tmp, fn):
    p = os.path.join(tmp, "scripts", "test-devflow-config.sh")
    content = open(p).read()
    open(p, "w").write(fn(content))


def undocument_orchestrate_trivial(tmp):
    edit_script(tmp, lambda t: t.replace(
        'KNOWN_INCOMPATIBLE = {("council", "trivial"), ("orchestrate", "trivial")}',
        'KNOWN_INCOMPATIBLE = {("council", "trivial")}',
    ))
rejects("orchestrate x trivial incompatibility left undocumented in the script",
        undocument_orchestrate_trivial, "is not in KNOWN_INCOMPATIBLE")


def drop_orchestrate_min_agents(tmp):
    # A strategy that LOSES its min_agents field entirely must not let a
    # documented KNOWN_INCOMPATIBLE entry for it go unchecked — this is the
    # gap the has_min_agents restructuring (not just a lowered value) closes.
    edit_toml(tmp, lambda t: t.replace(
        'coordination = "parallel-when-independent"\nmin_agents   = 2\nhuman_gates  = []',
        'coordination = "parallel-when-independent"\nhuman_gates  = []',
    ))
rejects("orchestrate's min_agents removed entirely while still documented as incompatible",
        drop_orchestrate_min_agents, "but it actually resolves cleanly now")

# ── tier model maps (unchanged surface, ADR 0006) ───────────────────────
rejects("unknown model slug", sub('claude   = "sonnet"', 'claude   = "notamodel"'),
        "is not a registered model")
rejects("unknown family in a tier table", sub('claude   = "sonnet"', 'banana   = "sonnet"'),
        "is not in")

rejects("non-monotonic escalate_to", sub('[tier.economy]\nescalate_to = ["standard"]',
        '[tier.economy]\nescalate_to = ["local"]'), "not monotonic toward apex")
rejects("local escalate_to is not economy",
        sub('endpoint    = "local"\nescalate_to = ["economy"]',
            'endpoint    = "local"\nescalate_to = ["standard"]'),
        'escalate_to must be exactly ["economy"]')


def drop_frontier(tmp):
    edit_toml(tmp, lambda t: re.sub(
        r"# Opus-class.*?qwen   = \"max\"\n\n", "", t, flags=re.S))
rejects("dropping a ladder table", drop_frontier, "missing table(s) for frontier")
# Referentiality of escalate_to is guaranteed structurally (targets are ladder
# tiers and every ladder tier must have a table), so there is no separate
# referential rejection to exercise — a dropped table is caught above.


def add_extra_tier(tmp):
    def fn(reg):
        for fam in reg.get("families", []):
            if fam.get("family") == "tier":
                fam["values"].append({"value": "ultra", "description": "bogus extra rung"})
    edit_label_registry(tmp, fn)
rejects("an extra provisioned tier value beyond the fixed ladder",
        add_extra_tier, "does not match the ADR-fixed ladder")


def drop_all_tiers(tmp):
    edit_toml(tmp, lambda t: re.sub(
        r"\n# Self-hosted stratum.*?gpt    = \"sol\"\n", "\n", t, flags=re.S))
rejects("removing the whole [tier] section", drop_all_tiers, "[tier] tables are missing")

rejects("endpoint on a non-local tier",
        sub('[tier.economy]\nescalate_to = ["standard"]',
            '[tier.economy]\nendpoint    = "local"\nescalate_to = ["standard"]'),
        "sets endpoint but is not the local tier")
rejects("local tier missing endpoint",
        sub('[tier.local]\nendpoint    = "local"\nescalate_to', '[tier.local]\nescalate_to'),
        'must set endpoint = "local"')

rejects("local family with no -local harness",
        sub('endpoint    = "local"\nescalate_to = ["economy"]\nqwen        = "coder-30b"   # served locally by claude-code-qwen-local',
            'endpoint    = "local"\nescalate_to = ["economy"]\nclaude      = "haiku"'),
        "has no registered `-local` harness")


def unrewire_local(tmp):
    def fn(reg):
        for h in reg["harnesses"]:
            if h["slug"] == "claude-code-qwen-local":
                h["provider_rewired"] = False
    edit_registry(tmp, fn)
rejects("a -local harness that is not provider-rewired", unrewire_local,
        "has no registered `-local` harness")

# ── agent-registry role coverage (new, ADR 0007) ────────────────────────
def strip_role(role):
    def fn(reg):
        for h in reg.get("harnesses", []):
            if "roles" in h:
                h["roles"] = [r for r in h["roles"] if r != role]
    return fn


def drop_review_role(tmp):
    edit_registry(tmp, strip_role("review"))
rejects("no harness left declaring the review role", drop_review_role, "no harness in")


def strip_review_from_apex_capable_harnesses(tmp):
    # "apex-capable" = a broker (any family) or a fixed-family harness whose
    # family has an apex-tier model (claude, gpt) — everything else was
    # never going to serve reviewer_tier="apex" anyway, so leaving those
    # untouched isolates the mutation to exactly the harnesses that matter.
    def fn(reg):
        for h in reg.get("harnesses", []):
            constraint = h.get("family_constraint", {})
            apex_capable = constraint.get("kind") == "broker" or constraint.get("family") in ("claude", "gpt")
            if apex_capable and "roles" in h:
                h["roles"] = [r for r in h["roles"] if r != "review"]
    edit_registry(tmp, fn)
rejects("every apex-capable harness loses the review role -> no reviewer can serve apex",
        strip_review_from_apex_capable_harnesses,
        "declaring the 'review' role can reach a 'apex'-tier model")

if failures:
    print()
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)
print("devflow config mutation tests OK: every advertised rejection fires")
PY
