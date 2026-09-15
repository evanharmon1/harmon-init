#!/usr/bin/env bash
# Unit tests for verify-ci-results.sh
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verifier="${repo}/scripts/verify-ci-results.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

assert_rc() {
    expected_rc="$1"
    label="$2"
    shift 2
    rc=0
    # Capture both stdout and stderr and silence it, but evaluate the exit code
    out="$("$verifier" "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne "$expected_rc" ]; then
        fail "${label}: expected exit code ${expected_rc}, got ${rc}. Output: ${out}"
    fi
}

# Happy paths (exit 0)
EXPECTED_RESULT="success" assert_rc 0 "trusted jobs succeeding" lint=success security=success
EXPECTED_RESULT="skipped" assert_rc 0 "fork-suppressed jobs skipping" lint=skipped security=skipped

# Usage errors (exit 2)
EXPECTED_RESULT="neutral" assert_rc 2 "an unsupported expectation" lint=neutral
EXPECTED_RESULT="success" assert_rc 2 "an empty result set"

# Job failures or mismatches (exit 1)
EXPECTED_RESULT="success" assert_rc 1 "a skipped trusted job" lint=success security=skipped
EXPECTED_RESULT="skipped" assert_rc 1 "a successful fork-suppressed job" lint=skipped security=success
EXPECTED_RESULT="success" assert_rc 1 "a failed job" lint=success security=failure
EXPECTED_RESULT="success" assert_rc 1 "a cancelled job" lint=success security=cancelled
EXPECTED_RESULT="success" assert_rc 1 "an unknown job result" lint=success security=unknown

# Malformed input (exit 1)
EXPECTED_RESULT="success" assert_rc 1 "an empty result" lint=success security=
EXPECTED_RESULT="success" assert_rc 1 "an empty job name" =success
EXPECTED_RESULT="success" assert_rc 1 "a malformed pair" lint

echo "verify-ci-results.sh truth tables: PASS"
