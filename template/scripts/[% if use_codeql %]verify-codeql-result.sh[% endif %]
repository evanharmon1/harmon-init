#!/usr/bin/env bash
# Fail closed unless CodeQL ran or skipped exactly as selected by the public/
# paid-private scan decision and the fork trust boundary.
set -euo pipefail

scan="${FULL_SECURITY_SCAN-}"
is_fork="${IS_FORK-}"
result="${ANALYZE_RESULT-}"

# Unset/empty means the optional private scan is disabled. Public workflows
# pass true explicitly because CodeQL is automatic and required there.
if [ -z "$scan" ]; then
    scan=false
fi

case "$scan" in
true | false) ;;
*)
    echo "Invalid FULL_SECURITY_SCAN value: ${scan:-<empty>} (expected true or false)" >&2
    exit 1
    ;;
esac

case "$is_fork" in
true | false) ;;
*)
    echo "Invalid fork decision: ${is_fork:-<empty>} (expected true or false)" >&2
    exit 1
    ;;
esac

case "$result" in
success | failure | cancelled | skipped) ;;
*)
    echo "Invalid CodeQL analyze result: ${result:-<empty>}" >&2
    exit 1
    ;;
esac

expected=skipped
if [ "$scan" = true ] && [ "$is_fork" = false ]; then
    expected=success
fi

if [ "$result" != "$expected" ]; then
    echo "CodeQL analyze result: $result (expected $expected; scan=$scan fork=$is_fork)" >&2
    exit 1
fi

echo "CodeQL analyze: $result (scan=$scan fork=$is_fork)"
