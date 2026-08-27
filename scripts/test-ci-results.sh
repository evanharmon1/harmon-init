#!/usr/bin/env bash
# Hermetic truth tables for CI aggregation and closing-keyword semantics.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verifier="${repo}/scripts/verify-ci-results.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

accept_required() {
    label="$1"
    expected="$2"
    shift 2
    if ! EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper rejected ${label}"
    fi
}

reject_required() {
    label="$1"
    expected="$2"
    shift 2
    if EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper accepted ${label}"
    fi
}

accept_required "trusted jobs succeeding" success lint=success security=success
accept_required "fork-suppressed jobs skipping" skipped lint=skipped security=skipped
reject_required "a skipped trusted job" success lint=success security=skipped
reject_required "a successful fork-suppressed job" skipped lint=skipped security=success
reject_required "a failed job" success lint=success security=failure
reject_required "a cancelled job" success lint=success security=cancelled
reject_required "an unknown job result" success lint=success security=unknown
reject_required "an empty result" success lint=success security=
reject_required "an empty job name" success =success
reject_required "a malformed pair" success lint
reject_required "an unsupported expectation" neutral lint=neutral
reject_required "an empty result set" success

workflow="${repo}/.github/workflows/build.yml"
grep -q 'HEAD_REPO:.*head.repo.full_name' "$workflow" || fail 'bootstrap must compare the PR head repository'
grep -q "grep -q '(HTTP 404)'" "$workflow" || fail 'bootstrap must require a confirmed default-branch 404'
grep -Fq '[ "$HEAD_REPO" = "$GH_REPO" ]' "$workflow" || fail 'bootstrap must permit same-repo heads only'
grep -q 'fetch_script "$DEFAULT_BRANCH"' "$workflow" || fail 'guard must prefer the default-branch script'
grep -q 'fetch_script "$HEAD_SHA"' "$workflow" || fail 'same-repo bootstrap must fetch the head SHA'

# Keep the closing-keyword fixtures in this CI contract test rather than in an
# orphan target: all five semantic cases run wherever CI checks its result
# aggregation, including generated repositories without vendored skills.
"${repo}/scripts/test-closing-keywords.sh"

echo "CI result helper truth tables: PASS"
