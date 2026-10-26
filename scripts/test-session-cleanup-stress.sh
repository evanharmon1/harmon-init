#!/usr/bin/env bash
# Run the cleanup regression repeatedly so timing-sensitive failures cannot
# make the required CI aggregate green by chance.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
run=1

while [ "$run" -le 20 ]; do
    echo "==> cleanup regression run ${run}/20"
    "$repo/scripts/test-session-cleanup.sh"
    run=$((run + 1))
done

echo "Session cleanup stress regression: PASS (20 consecutive runs)"
