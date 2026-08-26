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
import json
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
    ".devflow.schema.json",
    ".devflow-conformance-v1.json",
    "scripts/test-devflow-config.sh",
    "scripts/test-devflow-conformance.py",
    "scripts/devflow-resolve.py",
    "docs/guides/devflow.md",
    "template/label-registry.json",
    "template/agent-registry.json",
    "template/.devflow.toml",
    "template/.devflow.schema.json",
    "template/.devflow-conformance-v1.json",
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

# ── Compatibility version + contract surface ─────────────────────────────
rejects("a missing schema_version", sub(
    'schema_version = 1\n\n', ''
), "schema_version must be an integer")
rejects("a non-integer schema_version", sub(
    'schema_version = 1', 'schema_version = "1"'
), "schema_version must be an integer")
rejects("an unsupported schema_version", sub(
    'schema_version = 1', 'schema_version = 2'
), "schema_version=2 is unsupported")
rejects("an unknown top-level config key", sub(
    'schema_version = 1', 'schema_version = 1\nunsupported_v1_key = true'
), "unknown top-level key")


def edit_fixture(tmp, fn):
    for rel in (".devflow-conformance-v1.json", "template/.devflow-conformance-v1.json"):
        p = os.path.join(tmp, rel)
        fixture = json.load(open(p))
        fn(fixture)
        json.dump(fixture, open(p, "w"), indent=2)


def malformed_fixture(tmp):
    for rel in (".devflow-conformance-v1.json", "template/.devflow-conformance-v1.json"):
        p = os.path.join(tmp, rel)
        open(p, "w").write("{")
rejects("a malformed conformance fixture", malformed_fixture, "cannot read fixture")


def malformed_schema(tmp):
    for rel in (".devflow.schema.json", "template/.devflow.schema.json"):
        p = os.path.join(tmp, rel)
        open(p, "w").write("{")
rejects("a malformed v1 structural schema", malformed_schema, "cannot parse devflow schema JSON")


def weakened_review_schema(tmp):
    for rel in (".devflow.schema.json", "template/.devflow.schema.json"):
        p = os.path.join(tmp, rel)
        schema = json.load(open(p))
        schema["$defs"]["review"]["required"].remove("shepherd")
        json.dump(schema, open(p, "w"), indent=2)
rejects("a v1 schema that omits a required nested review cap", weakened_review_schema,
        "must require challenge, review, shepherd, and min_rounds")


def wrong_fixture_expectation(tmp):
    def mutate(fixture):
        fixture["cases"][0]["expect"]["result"]["selections"]["rigor"]["source"] = "explicit"
    edit_fixture(tmp, mutate)
rejects("an incorrect normalized-result expectation", wrong_fixture_expectation,
        "defaults: result.selections.rigor.source")


def duplicate_fixture_name(tmp):
    def mutate(fixture):
        fixture["cases"].append(fixture["cases"][0])
    edit_fixture(tmp, mutate)
rejects("duplicate conformance fixture names", duplicate_fixture_name, "fixture case names must be unique")


def malformed_expectation(tmp):
    def mutate(fixture):
        fixture["cases"][0]["expect"] = []
    edit_fixture(tmp, mutate)
rejects("a malformed conformance expectation", malformed_expectation, "defaults: expect must be an object")


def malformed_fixture_labels(tmp):
    def mutate(fixture):
        for case in fixture["cases"]:
            if case["name"] == "retired-method-label-is-ignored":
                case["labels"] = "method:council"
                return
        raise AssertionError("retired-method case missing")
    edit_fixture(tmp, mutate)
rejects("a fixture label collection that is not an array", malformed_fixture_labels,
        "retired-method-label-is-ignored: labels must be an array of strings")


def malformed_fixture_unattended(tmp):
    def mutate(fixture):
        for case in fixture["cases"]:
            if case["name"] == "unattended-authorized-label-applies":
                case["unattended"] = "true"
                return
        raise AssertionError("unattended case missing")
    edit_fixture(tmp, mutate)
rejects("a fixture unattended value that is not a boolean", malformed_fixture_unattended,
        "unattended-authorized-label-applies: unattended must be a boolean")


def omitted_expected_diagnostic(tmp):
    def mutate(fixture):
        for case in fixture["cases"]:
            if case["name"] == "unattended-unauthorized-label-is-ignored":
                case["expect"]["warning_diagnostics"] = []
                return
        raise AssertionError("unattended warning case missing")
    edit_fixture(tmp, mutate)
rejects("an omitted expected diagnostic", omitted_expected_diagnostic,
        "unexpected warning diagnostic pairs")

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

# ── [review.*] — min_rounds is scoped to challenge+review ONLY; shepherd
# is externally driven and cannot manufacture a round, so it never bounds
# min_rounds (ADR 0007-adjacent, .devflow.toml comment beside [review.*]) ─
rejects("min_rounds=2 exceeds challenge=1 (shepherd no longer bounds it)", sub(
    '[review.driveby]\nchallenge  = 1\nreview     = 1\nshepherd   = 1\nmin_rounds = 1',
    '[review.driveby]\nchallenge  = 1\nreview     = 1\nshepherd   = 1\nmin_rounds = 2',
), "exceeds min(challenge, review)")
rejects("review.none with min_rounds forced above 0", sub(
    '[review.none]\nchallenge  = 0\nreview     = 0\nshepherd   = 0\nmin_rounds = 0',
    '[review.none]\nchallenge  = 0\nreview     = 0\nshepherd   = 0\nmin_rounds = 1',
), "exceeds min(challenge, review)")
rejects("a negative stage cap", sub(
    '[review.driveby]\nchallenge  = 1', '[review.driveby]\nchallenge  = -1',
), "must be >= 0")

rejects("a multi-agent strategy missing min_agents", sub(
    'coordination = "parallel-when-independent"\nmin_agents   = 2',
    'coordination = "parallel-when-independent"',
), "missing required field(s)")

# min_rounds must ALSO stay non-decreasing along rigor_order, same as every
# other field the round-3 monotonicity check covers — thorough's own bound
# (min_rounds <= min(challenge, review) = 4) stays satisfied at 2, so this
# trips ONLY the cross-level monotonicity check, not the per-policy bound
# check above: thorough=2 then deep=1 is a drop climbing rigor_order.
rejects("min_rounds not monotonic (thorough=2 then deep=1 along rigor_order)", sub(
    '[review.thorough]\nchallenge  = 4\nreview     = 4\nshepherd   = 5\nmin_rounds = 1',
    '[review.thorough]\nchallenge  = 4\nreview     = 4\nshepherd   = 5\nmin_rounds = 2',
), "is not monotonic")

# (A demonstration that shepherd no longer bounds min_rounds at all — e.g.
# dropping [review.light].shepherd toward 0 while min_rounds stays 1 — is
# deliberately NOT exercised as a mutation here: shepherd also has to stay
# non-decreasing along rigor_order (the round-3 monotonicity check, above),
# so a shepherd-only mutation would trip THAT check instead and prove
# nothing about min_rounds specifically. The rejects case above already
# proves the bound is min(challenge, review) — challenge=1 alone is what
# blocks min_rounds=2 regardless of shepherd's value.)

# ── [budget.*] ───────────────────────────────────────────────────────────
rejects("a non-boolean allow_tier_escalation", sub(
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\nwall_clock_min        = 15\nallow_tier_escalation = false',
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\nwall_clock_min        = 15\nallow_tier_escalation = "false"',
), "must be a boolean")
rejects("a zero max_agent_runs", sub(
    '[budget.trivial]\nmax_agent_runs        = 1', '[budget.trivial]\nmax_agent_runs        = 0',
), "must be an integer > 0")
rejects("a non-finite max_usd (nan)", sub(
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\n'
    'wall_clock_min        = 15\nallow_tier_escalation = false',
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\n'
    'wall_clock_min        = 15\nallow_tier_escalation = false\nmax_usd               = nan',
), "must be finite (not nan/inf)")
rejects("a non-finite max_usd (+inf, which the > 0 check alone would miss)", sub(
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\n'
    'wall_clock_min        = 15\nallow_tier_escalation = false',
    '[budget.trivial]\nmax_agent_runs        = 1\nmax_parallel_agents   = 1\n'
    'wall_clock_min        = 15\nallow_tier_escalation = false\nmax_usd               = inf',
), "must be finite (not nan/inf)")


def add_shrinking_max_tokens(tmp):
    # max_tokens is absent from every shipped envelope (unenforced, i.e. the
    # largest possible ceiling) — this mutation ADDS it to two adjacent
    # rigor_order levels rather than lowering an existing value, since there
    # is no existing value to lower. light gets a finite cap where it
    # previously had none; standard (the next-stronger level) gets a LOWER
    # finite cap — a decrease either way you read it: light's absent->1000
    # is not itself the violation (absent is treated as +infinity, so
    # "adding" a cap only ever narrows from infinity), but 1000 -> 500 one
    # step later in rigor_order is a plain numeric drop.
    edit_toml(tmp, lambda t: t.replace(
        '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2\n'
        'wall_clock_min        = 45\nallow_tier_escalation = false',
        '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2\n'
        'wall_clock_min        = 45\nallow_tier_escalation = false\nmax_tokens            = 1000',
    ).replace(
        '[budget.standard]\nmax_agent_runs        = 6\nmax_parallel_agents   = 3\n'
        'wall_clock_min        = 120\nallow_tier_escalation = true',
        '[budget.standard]\nmax_agent_runs        = 6\nmax_parallel_agents   = 3\n'
        'wall_clock_min        = 120\nallow_tier_escalation = true\nmax_tokens            = 500',
    ))
rejects("optional budget.max_tokens not monotonic (light=1000 then standard=500)",
        add_shrinking_max_tokens, "budget.max_tokens drops 1000 -> 500")

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

# council-only fields (selection/synthesis) are permitted only on
# topology=independent-proposals; min_agents also on lead-and-workers;
# coordination on either multi-agent topology. Not merely "valid wherever
# present" — meaningless, and rejected, on a topology they don't describe.
rejects("selection on plan (topology=single-agent, not independent-proposals)", sub(
    '[strategy.plan]\ntopology    = "single-agent"\nplanning    = "explicit"\ndelegation  = "optional"\nhuman_gates = []',
    '[strategy.plan]\ntopology    = "single-agent"\nplanning    = "explicit"\ndelegation  = "optional"\nselection   = "judge"\nhuman_gates = []',
), "selection is only valid on topology=independent-proposals")
rejects("synthesis on orchestrate (topology=lead-and-workers, not independent-proposals)", sub(
    'coordination = "parallel-when-independent"\nmin_agents   = 2\nhuman_gates  = []',
    'coordination = "parallel-when-independent"\nmin_agents   = 2\nsynthesis    = true\nhuman_gates  = []',
), "synthesis is only valid on topology=independent-proposals")
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
        undocument_orchestrate_trivial, "not in KNOWN_INCOMPATIBLE")


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


def shrink_light_budget_to_two_runs(tmp):
    # council's min_agents=2 counts PROPOSERS only — the coordinator that
    # judges them is one MORE run, so council needs max_agent_runs >=
    # min_agents + 1 = 3, not just >= 2. A 2-runs/2-parallel budget has
    # enough PARALLEL capacity (2 >= min_agents) but not enough TOTAL RUN
    # capacity — exactly the gap the "+1" formula exists to catch, and
    # exactly what a same-value-on-both-ceilings formula would have missed
    # (2 >= 2 would have looked fine). orchestrate's min_agents=2 already
    # counts its lead, and (unlike council) is checked with NO subtraction
    # or addition on either ceiling — it needs max_agent_runs >= 2 AND
    # max_parallel_agents >= 2, both of which this exact budget already
    # satisfies — so this same mutation leaves orchestrate compatible,
    # proving the two formulas are genuinely different, not just
    # differently worded.
    edit_toml(tmp, lambda t: t.replace(
        '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2',
        '[budget.light]\nmax_agent_runs        = 2\nmax_parallel_agents   = 2',
    ))
rejects("council under a 2-runs/2-parallel budget is incompatible (needs the coordinator's +1 run)",
        shrink_light_budget_to_two_runs, "not in KNOWN_INCOMPATIBLE")


def shrink_light_budget_parallel_only(tmp):
    # orchestrate's min_agents=2 counts the lead PLUS its worker — the
    # WHOLE roster — and is checked with NO "the lead doesn't count"
    # subtraction on max_parallel_agents. A 3-runs/1-parallel budget has
    # enough TOTAL RUN capacity (3 >= 2) but not enough PARALLEL capacity
    # (1 < 2) — exactly what a formula that subtracted 1 for the lead
    # would have missed (1 >= 2-1 would have looked fine).
    edit_toml(tmp, lambda t: t.replace(
        '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 2',
        '[budget.light]\nmax_agent_runs        = 3\nmax_parallel_agents   = 1',
    ))
rejects("orchestrate under a 3-runs/1-parallel budget is incompatible (no lead subtraction)",
        shrink_light_budget_parallel_only, "not in KNOWN_INCOMPATIBLE")

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
