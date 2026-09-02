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
    # A bare command substitution assignment is NOT exempt from `set -e`: if
    # the resolved `openspec` is a broken shim that exits non-zero on
    # --version (rather than printing a wrong-but-valid one), this would
    # abort the whole script right here instead of ever reaching the
    # reinstall below. `|| true` makes a failed probe read as an empty,
    # non-matching version -- a mismatch that correctly triggers
    # install-openspec.sh, whose own post-install resolution check reports
    # loudly if the broken shim still shadows ~/.local/bin afterward.
    installed="$(openspec --version 2>/dev/null || true)"
    if [ "$installed" != "$OPENSPEC_VERSION" ]; then
        # install-openspec.sh itself verifies the bare `openspec` command
        # actually resolves to the refreshed install afterward and exits
        # non-zero if not (a shadowing PATH entry, e.g.); no `|| true` here
        # on purpose, so that failure aborts this script under `set -e`
        # rather than silently proceeding to `openspec.sh update` below
        # against a CLI that never actually got refreshed.
        ./scripts/install-openspec.sh "$OPENSPEC_VERSION"
    fi
fi

exec ./scripts/openspec.sh update
