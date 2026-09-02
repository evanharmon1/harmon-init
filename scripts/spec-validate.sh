#!/usr/bin/env bash
set -euo pipefail

# spec-validate.sh — offline-safe wrapper around `openspec validate --all`.
#
# `task verify` (and the pre-push hook it backs) is documented and relied on
# to run OFFLINE (see Taskfile.yml's `ci` task: verify:skills is the one
# NETWORK check, deliberately kept out of verify). scripts/openspec.sh execs
# the CLI through `npx`, which needs the network on a cold cache even just to
# report "nothing to validate" — confirmed by a review sandbox with no
# network hitting `npm error EAI_AGAIN` on an empty repo. Skip the CLI
# entirely when there is nothing to validate, so the common case (no changes
# or specs yet) never touches the network; only an actual proposal — where
# the author is already mid-workflow, with network already needed for
# `openspec` itself — pays the npx cost.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# True if $1 has any entry one level down, other entries in "$@" excluded by
# name. `openspec/changes/archive/` is a container `openspec init` always
# creates, not itself a change, so it is excluded when checking for changes.
has_entries() {
    local dir="$1"
    shift
    [ -d "$dir" ] || return 1
    find "$dir" -mindepth 1 -maxdepth 1 "$@" -print -quit 2>/dev/null | grep -q .
}

if ! has_entries openspec/changes -not -name archive && ! has_entries openspec/specs; then
    echo "spec-validate: no OpenSpec changes or specs present — skipping (offline no-op)"
    exit 0
fi

exec ./scripts/openspec.sh validate --all --no-interactive
