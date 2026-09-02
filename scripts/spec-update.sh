#!/usr/bin/env bash
set -euo pipefail

# spec-update.sh — refresh generated OpenSpec instruction files (task
# spec:update), first refreshing the user-local CLI install
# (scripts/install-openspec.sh) if it has drifted from the pin.
#
# task spec:install puts a pinned `openspec` on PATH once; nothing re-runs
# it when OPENSPEC_VERSION later bumps. openspec.sh's own version check
# already refuses a mismatched local binary and falls back to npx, so a
# stale install is not a correctness gap for task spec:* — but it does mean
# the generated /opsx:* skills' bare `openspec` invocations, and anyone
# running the bare command directly, would keep talking to the old release
# indefinitely. Refresh it here too, so bumping the pin and running
# spec:update is enough.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

: "${OPENSPEC_VERSION:?OPENSPEC_VERSION is not set — run via task spec:update or export it}"

if command -v openspec >/dev/null 2>&1; then
    installed="$(openspec --version 2>/dev/null)"
    if [ "$installed" != "$OPENSPEC_VERSION" ]; then
        ./scripts/install-openspec.sh "$OPENSPEC_VERSION"
    fi
fi

exec ./scripts/openspec.sh update
