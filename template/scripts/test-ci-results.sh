#!/usr/bin/env bash
# Hermetic truth-table regressions for the fail-closed CI result helpers.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
required="${repo}/scripts/verify-required-results.sh"
codeql="${repo}/scripts/verify-codeql-result.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

accept_required() {
    label="$1"
    expected="$2"
    shift 2
    if ! EXPECTED_RESULT="$expected" "$required" "$@" >/dev/null 2>&1; then
        fail "required-results helper rejected ${label}"
    fi
}

reject_required() {
    label="$1"
    expected="$2"
    shift 2
    if EXPECTED_RESULT="$expected" "$required" "$@" >/dev/null 2>&1; then
        fail "required-results helper accepted ${label}"
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

if [ -f "$codeql" ]; then
    accept_codeql() {
        label="$1"
        scan="$2"
        fork="$3"
        result="$4"
        if ! FULL_SECURITY_SCAN="$scan" IS_FORK="$fork" ANALYZE_RESULT="$result" \
            "$codeql" >/dev/null 2>&1; then
            fail "CodeQL helper rejected ${label}"
        fi
    }

    reject_codeql() {
        label="$1"
        scan="$2"
        fork="$3"
        result="$4"
        if FULL_SECURITY_SCAN="$scan" IS_FORK="$fork" ANALYZE_RESULT="$result" \
            "$codeql" >/dev/null 2>&1; then
            fail "CodeQL helper accepted ${label}"
        fi
    }

    accept_codeql "a required public/paid-private success" true false success
    accept_codeql "a disabled private scan skip" false false skipped
    accept_codeql "an unset-equivalent private scan skip" "" false skipped
    accept_codeql "a public fork skip" true true skipped
    accept_codeql "a private fork skip" false true skipped
    reject_codeql "a skipped required scan" true false skipped
    reject_codeql "a failed required scan" true false failure
    reject_codeql "a cancelled required scan" true false cancelled
    reject_codeql "a successful disabled scan" false false success
    reject_codeql "a successful fork scan" true true success
    reject_codeql "a malformed scan decision" enabled false success
    reject_codeql "a malformed fork decision" true maybe success
    reject_codeql "an unknown analyze result" true false unknown
    reject_codeql "an empty analyze result" true false ""
fi

echo "CI result helper truth tables: PASS"
