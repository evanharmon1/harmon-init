#!/usr/bin/env bash
# Root-only test because Copier never renders the toolchain floors files into
# generated repositories. Exercise the same configured Task guard as CI.
set -euo pipefail
cd "$(dirname "$0")/.."

for floors_file in toolchain-floors.json toolchain-floors.schema.json; do
    echo "==> changing only $floors_file requires a releasing title"
    rc=0
    PR_TITLE='chore: update toolchain floors' PR_BODY='' CHANGED_FILES="$floors_file" \
        task --exit-code guard:release-title >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 1 ]; then
        echo "TEST FAIL: chore + $floors_file should fail (exit 1, got $rc)" >&2
        exit 1
    fi
    PR_TITLE='fix: update toolchain floors' PR_BODY='' CHANGED_FILES="$floors_file" \
        task --exit-code guard:release-title
done
