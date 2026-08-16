#!/usr/bin/env bash
# test-devflow-config-mutations.sh — prove test-devflow-config.sh REJECTS bad
# configs, not only that it accepts the good one.
#
# test:devflow-config runs the validator against the checked-in (valid) config,
# so it proves the happy path and nothing else: a regression that stopped
# rejecting `default_tier = "adaptive"`, a dangling escalate_to, an unknown
# model slug, a missing local harness, or method-rank drift would leave that
# task green. This test exercises each advertised rejection by mutating a
# throwaway copy of the whole config layout and asserting the validator fails
# with the expected reason — the same shape as test-agent-registry.sh's
# `rejects` cases. Root-only, like the validator it guards.
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
# The validator reads both .devflow.toml copies, both label + agent registries,
# and both AGENTS files; a mutation layout has to mirror that whole surface.
LAYOUT = [
    "label-registry.json",
    "agent-registry.json",
    "AGENTS.md",
    ".devflow.toml",
    "scripts/test-devflow-config.sh",
    "template/label-registry.json",
    "template/agent-registry.json",
    "template/.devflow.toml",
    "template/AGENTS.md.jinja",
]

failures = []


def build(tmp):
    os.makedirs(os.path.join(tmp, "scripts"))
    os.makedirs(os.path.join(tmp, "template"))
    for rel in LAYOUT:
        shutil.copy(os.path.join(repo, rel), os.path.join(tmp, rel))


def edit_toml(tmp, fn):
    # Mutate both .devflow.toml copies identically, so the twin-parity check is
    # not what trips — we are testing the tier/method logic, not that gate.
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

# default_tier / default_method
rejects("default_tier = adaptive", sub('default_tier   = "standard"', 'default_tier   = "adaptive"'),
        "default_tier='adaptive' is rejected")
rejects("default_tier names no provisioned tier",
        sub('default_tier   = "standard"', 'default_tier   = "bogus"'), "names no provisioned tier")
rejects("default_method names no provisioned method",
        sub('default_method = "plan"', 'default_method = "nope"'), "names no provisioned method")

# tier model maps
rejects("unknown model slug", sub('claude   = "sonnet"', 'claude   = "notamodel"'),
        "is not a registered model")
rejects("unknown family in a tier table", sub('claude   = "sonnet"', 'banana   = "sonnet"'),
        "is not in")

# escalate_to shape
rejects("non-monotonic escalate_to", sub('[tier.economy]\nescalate_to = ["standard"]',
        '[tier.economy]\nescalate_to = ["local"]'), "not monotonic toward apex")
rejects("local escalate_to is not economy",
        sub('endpoint    = "local"\nescalate_to = ["economy"]',
            'endpoint    = "local"\nescalate_to = ["standard"]'),
        'escalate_to must be exactly ["economy"]')

# ladder completeness / referential chain
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

# endpoint rules
rejects("endpoint on a non-local tier",
        sub('[tier.economy]\nescalate_to = ["standard"]',
            '[tier.economy]\nendpoint    = "local"\nescalate_to = ["standard"]'),
        "sets endpoint but is not the local tier")
rejects("local tier missing endpoint",
        sub('[tier.local]\nendpoint    = "local"\nescalate_to', '[tier.local]\nescalate_to'),
        'must set endpoint = "local"')

# local harness binding
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

# [method].rank
rejects("[method].rank reordered",
        sub('rank = ["human-led", "plan-approved"', 'rank = ["plan-approved", "human-led"'),
        "must be exactly")
rejects("[method] table removed",
        sub('[method]\nrank = ["human-led", "plan-approved", "council", "orchestrate", "plan", "oneshot"]', ''),
        "[method] table is missing")

if failures:
    print()
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)
print("devflow config mutation tests OK: every advertised rejection fires")
PY
