#!/usr/bin/env bash
# `verify` and the required Build workflow run their `test:*` targets through
# ONE aggregate Taskfile task (test:suite) and the project's own test tier
# through `task test`, so local `verify` and CI cannot drift
# (harmon-init#962, #1461, #1681). This is the whole guard: it fails when the
# Build workflow's lint job stops calling `task test:suite`, when the project
# test job stops calling `task test`, when `verify` stops calling either, or
# when `verify` gains a `test:*` entry of its own that the workflow would never
# run. Plain text only — a block is the lines from its key to the next key at
# the same two-space indent; no YAML or shell is parsed, and `task` itself is
# not needed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo}/.github/workflows/build.yml"
taskfile="${repo}/Taskfile.yml"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# block FILE KEY — the two-space-indented `KEY:` entry's lines (a Taskfile task
# or a workflow job): up to the next line indented exactly two spaces.
block() {
    awk -v key="$2" '
        $0 ~ "^  " key ":[[:space:]]*$" { on = 1; next }
        on && /^  [^ #]/ { exit }
        on' "$1"
}

# An uncommented `run: task test:suite` step inside the `lint` job (a comment
# starts with `#`, so it can never satisfy the anchor; another job cannot
# satisfy it either).
workflow_calls_suite() {
    block "$1" lint | grep -E '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+task test:suite[[:space:]]*$' >/dev/null
}

# An uncommented `run: task test` step (that exact command — `task test:*`
# fails the end anchor) inside the job that runs the project test tier
# (`build-test` in the template; `test` or `test-*` when a consumer names or
# splits the job differently). A comment starts with `#`, so it cannot satisfy
# the anchor, and non-test jobs (`lint`, `security`, `e2e`, `a11y`, `verify`,
# `template-test`) cannot satisfy it either.
workflow_calls_test() {
    local job
    while IFS= read -r job; do
        [ -n "$job" ] || continue
        if block "$1" "$job" | grep -E '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+task test[[:space:]]*$' >/dev/null; then
            return 0
        fi
    done < <(sed -nE 's/^  (build-test|test(-[a-z0-9-]+)?):[[:space:]]*$/\1/p' "$1")
    return 1
}

# `verify` itself lists `task: test:suite` — calling a leaf the suite also
# lists would pass a weaker check while the suite went unused.
verify_runs_suite() {
    block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test:suite[[:space:]]*$' >/dev/null
}

# `verify` itself lists `task: test` (generated repos do; harmon-init's root
# Taskfile runs `task: test:template` instead).
verify_runs_test() {
    block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test[[:space:]]*$' >/dev/null
}

# project_test_tier_active TASKFILE WORKFLOW — true when the Build workflow
# must carry a `run: task test` step: either the workflow already defines a
# project test job (`build-test` in the template; `test` / `test-*` in a
# consumer), or `verify` lists `task: test` and the `test` task is no longer
# the unwired non-Node scaffold stub (harmon-init#978: fresh non-Node renders
# ship that stub with no `build-test` job yet).
project_test_tier_active() {
    grep -Eq '^  (build-test|test(-[a-z0-9-]+)?):[[:space:]]*$' "$2" && return 0
    verify_runs_test "$1" || return 1
    ! block "$1" test | grep -Fq 'TODO: wire tests for this project'
}

# verify_has_no_stray_tests TASKFILE WORKFLOW — every `test:*` entry in
# `verify` must be the suite, or test:template when (and only when) the same
# build.yml defines the `template-test:` job it runs as. A repository without
# that job has no required step for test:template, so there it is stray like
# any other entry: it would run locally and in no required Build step, the
# drift this guard exists for.
verify_has_no_stray_tests() {
    local stray allowed='suite'
    if grep -Eq '^  template-test:[[:space:]]*$' "$2"; then
        allowed='(suite|template)'
    fi
    stray="$(block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test:' |
        grep -Ev "task:[[:space:]]+test:${allowed}[[:space:]]*\$" || true)"
    [ -z "$stray" ] || {
        echo "$stray" >&2
        return 1
    }
}

[ -f "$workflow" ] || fail "${workflow} not found"
[ -f "$taskfile" ] || fail "${taskfile} not found"
workflow_calls_suite "$workflow" ||
    fail "the Build workflow's lint job no longer runs \`task test:suite\` in a step — add it back rather than listing test:* targets in build.yml"
if project_test_tier_active "$taskfile" "$workflow"; then
    workflow_calls_test "$workflow" ||
        fail "the Build workflow no longer runs \`task test\` in a project test job — add an uncommented \`run: task test\` step rather than enumerating test:* targets in build.yml"
    verify_runs_test "$taskfile" ||
        fail "\`verify\` no longer lists \`task: test\` itself"
fi
verify_runs_suite "$taskfile" ||
    fail "\`verify\` no longer lists \`task: test:suite\` itself"
verify_has_no_stray_tests "$taskfile" "$workflow" ||
    fail "\`verify\` lists the test:* entries above directly — add them to test:suite instead, or the Build workflow never runs them"

# Planted cases: every check above must be able to fail.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

grep -Ev 'run:[[:space:]]+task test:suite' "$workflow" >"${scratch}/removed.yml"
! workflow_calls_suite "${scratch}/removed.yml" ||
    fail "planted case: a workflow without the aggregate step still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      # - run: task test:suite' '  security:' '    steps:' >"${scratch}/commented.yml"
! workflow_calls_suite "${scratch}/commented.yml" ||
    fail "planted case: a commented-out aggregate step still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task check' \
    '  security:' '    steps:' '      - run: task test:suite' >"${scratch}/moved.yml"
! workflow_calls_suite "${scratch}/moved.yml" ||
    fail "planted case: the aggregate step in another job still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' '  security:' '    steps:' >"${scratch}/ok.yml"
workflow_calls_suite "${scratch}/ok.yml" ||
    fail "planted case: a lint job that runs the aggregate step was rejected"

if project_test_tier_active "$taskfile" "$workflow"; then
    grep -Ev 'run:[[:space:]]+task test([[:space:]]|$)' "$workflow" >"${scratch}/test-removed-live.yml"
    ! workflow_calls_test "${scratch}/test-removed-live.yml" ||
        fail "planted case: the live workflow without its task test step still passed"
fi
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task build' '      - run: task validate' \
    '  security:' '    steps:' >"${scratch}/test-removed.yml"
! workflow_calls_test "${scratch}/test-removed.yml" ||
    fail "planted case: a workflow without the project test step still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      # - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-commented.yml"
! workflow_calls_test "${scratch}/test-commented.yml" ||
    fail "planted case: a commented-out project test step still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task build' \
    '  security:' '    steps:' '      - run: task test' >"${scratch}/test-moved.yml"
! workflow_calls_test "${scratch}/test-moved.yml" ||
    fail "planted case: the project test step in another job still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task test:unit' \
    '  security:' '    steps:' >"${scratch}/test-leaf.yml"
! workflow_calls_test "${scratch}/test-leaf.yml" ||
    fail "planted case: a project test job running only a test:* target instead of task test still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-ok.yml"
workflow_calls_test "${scratch}/test-ok.yml" ||
    fail "planted case: a build-test job that runs task test was rejected"
printf '%s\n' 'jobs:' '  test-skills:' '    steps:' '      - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-consumer-ok.yml"
workflow_calls_test "${scratch}/test-consumer-ok.yml" ||
    fail "planted case: a consumer test-* job that runs task test was rejected"

printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test' \
    '  test:' '    cmds:' '      - ./scripts/test-unit.sh' >"${scratch}/wired-test.Taskfile"
project_test_tier_active "${scratch}/wired-test.Taskfile" "${scratch}/ok.yml" ||
    fail "planted case: a Taskfile with a wired test task was not treated as active"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test' \
    '  test:' '    cmds:' '      - '\''echo "TODO: wire tests for this project (see docs/architecture/tests.md); test files live in tests/"'\''' >"${scratch}/unwired-test.Taskfile"
! project_test_tier_active "${scratch}/unwired-test.Taskfile" "${scratch}/ok.yml" ||
    fail "planted case: an unwired non-Node scaffold Taskfile without build-test was treated as active"
project_test_tier_active "${scratch}/unwired-test.Taskfile" "${scratch}/test-removed.yml" ||
    fail "planted case: a workflow with build-test was not treated as active"

printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' '  template-test:' '    steps:' >"${scratch}/with-matrix.yml"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test:template' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/ok.Taskfile"
verify_runs_suite "${scratch}/ok.Taskfile" && verify_has_no_stray_tests "${scratch}/ok.Taskfile" "${scratch}/with-matrix.yml" ||
    fail "planted case: a verify that runs the suite (+ test:template, with the template-test job present) was rejected"
! verify_has_no_stray_tests "${scratch}/ok.Taskfile" "${scratch}/ok.yml" 2>/dev/null ||
    fail "planted case: a direct test:template in verify passed although the workflow has no template-test job"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:verify-ci-parity' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/leaf.Taskfile"
! verify_runs_suite "${scratch}/leaf.Taskfile" ||
    fail "planted case: a verify calling a suite member instead of the suite still passed"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - echo no suite here' \
    '  test:suite:' '    cmds:' '      - task: test:suite-ish' >"${scratch}/drifted.Taskfile"
! verify_runs_suite "${scratch}/drifted.Taskfile" ||
    fail "planted case: a verify that does not run the suite still passed"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: test:suite' '      - task: test:renovate-config' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/stray.Taskfile"
! verify_has_no_stray_tests "${scratch}/stray.Taskfile" "${scratch}/with-matrix.yml" 2>/dev/null ||
    fail "planted case: a verify with a direct test:* entry still passed"

echo "test-verify-ci-parity: PASS"
