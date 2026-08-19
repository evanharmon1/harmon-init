#!/usr/bin/env bash
# test-verify-ci-parity.sh — GATE: every non-exempt `task verify` target must
# be reachable from the required CI workflow (harmon-init#962).
#
# `task verify` and .github/workflows/build.yml each hand-maintain their own
# list of targets, and nothing binds them. When they diverge, CI is WEAKER
# than the local gate: a PR goes green on GitHub while the behaviour the
# missing target covers is broken. This has been reconciled by hand twice
# already (harmon-devkit#479, and harmon-init#909/PR#960 for test:gh-scopes),
# both times caught by a review rather than a gate.
#
# ONE-DIRECTIONAL BY DESIGN: only "verify runs it, CI does not" is a defect.
# CI running something verify does not is legitimate (CI-only infrastructure —
# a browser install, a service container, a credential that only exists on a
# runner) and must never fail this guard.
#
# ROOT LAYER ONLY: this script checks Taskfile.yml against
# .github/workflows/build.yml — the two root-layer files this repo dogfoods.
# The TEMPLATE layer (template/Taskfile.yml.jinja against
# template/.github/workflows/build.yml.jinja, as rendered) is checked inside
# scripts/test-template.sh's per-profile loop instead, once per copier answer
# profile (minimal/web/webapp/iac/full/meta) — not here, and not against a
# single fixed render. Two reasons: (1) template/*.jinja SOURCE cannot be
# parsed as YAML directly — copier's `[% if %]` conditionals sit on their own
# lines inside a YAML mapping, which is not valid YAML until rendered
# (confirmed empirically: `yq '.tasks.verify.cmds[].task'
# template/Taskfile.yml.jinja` errors with "found character that cannot start
# any token" at the first bare `[% if %]` line) — so it needs a REAL RENDER,
# which test-template.sh already produces per profile; (2) a single render
# (this script previously used .dogfood-answers.yml, matching harmon-init's
# own project_type: general answers) only ever exercises ONE answer path.
# Drift confined to a different profile's branch (project_type: iac, a
# use_node-gated workflow job, …) was invisible to a guard that always
# rendered the same profile. Rendering all profiles here too would add ~6
# more copier renders to `task verify`, which is unacceptable — test-template
# already renders every profile for its own checks, so hooking in there gets
# full-matrix coverage for free instead of duplicating the render cost.
#
# EXTRACTION: yq reads the YAML structure (the `task:` cmd list, the
# workflow's `run:` step bodies) via scripts/lib/verify-ci-parity.sh, shared
# with the template-layer check in test-template.sh so both callers apply
# identical rules — a plain grep over the raw file is what makes this class
# of guard rot in the first place (regex drifting out of sync with real YAML
# nesting).
#
# MATRIX-AWARE EXTRACTION for test:template: the template-test job invokes
# `task test:template:${{ matrix.profile }}`, not `task test:template`
# verbatim. Extraction strips a trailing `:` (left behind when a `run:`
# string's `task <name>` capture runs into `${{ …` and the character class
# stops at `$`) so a namespaced matrix alias resolves to its parent target
# automatically — no allowlist entry needed for test:template, and no special
# case for any future matrix-style target either.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# shellcheck source=scripts/lib/verify-ci-parity.sh
. ./scripts/lib/verify-ci-parity.sh

# Allowlisted exceptions — each one is either a legitimate CI-only-vs-local
# split or a currently-open GENUINE GAP tracked with a stated reason. This is
# checked ONLY as a fallback, after a target is confirmed both CI-unreachable
# AND not a genuinely inert placeholder (see verify_ci_parity_task_is_inert in
# the shared lib) — a name landing here can never mask real behaviour that
# happens to share a name with a placeholder in some other profile. Keep the
# list short and give each entry a factual reason.
#
# The eleven targets this guard first surfaced (audit:agent-instructions,
# test:agent-instructions-size, test:agent-skill-links, test:image-staleness,
# test:link-claude-json, test:meta-install, test:open-devcontainer,
# test:output, test:session-cleanup, test:setup-github, test:starship-glyphs)
# are NOT allowlisted: each was empirically confirmed to need no container,
# network, or credential and to run in ~1-2s, so they were added to build.yml's
# lint job instead. Likewise test:sync-devkit-release, which root already ran
# but template/.github/workflows/build.yml.jinja had never gained — root's #909
# fix had not reached the repos consumers actually receive, which is precisely
# the drift this guard exists to catch.
ALLOWLIST="
"

root_allowed() {
    case "
$ALLOWLIST
" in *"
$1
"*) return 0 ;; esac
    return 1
}

# ── Root layer ──────────────────────────────────────────────────────────────
verify_ci_parity_check_layer Taskfile.yml .github/workflows/build.yml "root" root_allowed

if [ "$fail" -ne 0 ]; then
    echo "verify/CI parity: task verify runs targets the required CI workflow never reaches (see AGENTS.md / harmon-init#962)." >&2
    echo "Add the missing 'task <target>' step to the workflow, or if it is a legitimate CI-only-vs-local split, add it to" >&2
    echo "ALLOWLIST in scripts/test-verify-ci-parity.sh WITH a stated reason." >&2
    exit 1
fi
echo "verify/CI parity OK: every non-exempt task verify target is reachable from CI (root layer; template layer checked per-profile in test-template.sh)"
