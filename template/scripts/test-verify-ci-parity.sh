#!/usr/bin/env bash
# `verify` and the required Build workflow run their `test:*` targets through
# ONE aggregate Taskfile task (test:suite), so the two lists cannot drift
# (harmon-init#962, #1461). This is the whole guard: it fails when the Build
# workflow stops calling that task or when `verify` stops running it. Plain
# text only — it never parses the workflow's YAML or its shell.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo}/.github/workflows/build.yml"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# An uncommented `run: task test:suite` step (a comment starts with `#`, so it
# can never satisfy the anchor).
workflow_calls_suite() {
    grep -Eq '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+task test:suite[[:space:]]*$' "$1"
}

# `task --dry` flattens task calls, so `verify` reaching the suite shows as a
# member only the suite lists — this guard's own task.
verify_runs_suite() {
    # Captured first: `grep -q` closing the pipe early would SIGPIPE `task`,
    # which pipefail turns into a false "not in the plan".
    local plan
    plan="$(cd "$1" && task --dry --color=false verify 2>&1)" || return 1
    grep -qF 'task: [test:verify-ci-parity]' <<<"$plan"
}

[ -f "$workflow" ] || fail "${workflow} not found"
workflow_calls_suite "$workflow" ||
    fail "the Build workflow no longer runs \`task test:suite\` in a step — add it back rather than listing test:* targets in build.yml"
verify_runs_suite "$repo" ||
    fail "\`task verify\` no longer runs test:suite (its member test:verify-ci-parity is not in the plan)"

# Planted cases: the checks above must be able to fail.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

grep -Ev 'run:[[:space:]]+task test:suite' "$workflow" >"${scratch}/removed.yml"
! workflow_calls_suite "${scratch}/removed.yml" ||
    fail "planted case: a workflow without the aggregate step still passed"
printf '%s\n' '      # - run: task test:suite' >"${scratch}/commented.yml"
! workflow_calls_suite "${scratch}/commented.yml" ||
    fail "planted case: a commented-out aggregate step still passed"

mkdir "${scratch}/ok" "${scratch}/drifted"
printf '%s\n' \
    "version: '3'" 'tasks:' \
    '  verify:' '    cmds:' '      - task: test:suite' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' \
    '  test:verify-ci-parity:' '    cmds:' '      - echo parity' >"${scratch}/ok/Taskfile.yml"
printf '%s\n' \
    "version: '3'" 'tasks:' \
    '  verify:' '    cmds:' '      - echo no suite here' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' \
    '  test:verify-ci-parity:' '    cmds:' '      - echo parity' >"${scratch}/drifted/Taskfile.yml"
verify_runs_suite "${scratch}/ok" ||
    fail "planted case: a verify that runs the suite was rejected"
! verify_runs_suite "${scratch}/drifted" ||
    fail "planted case: a verify that does not run the suite still passed"

echo "test-verify-ci-parity: PASS"
