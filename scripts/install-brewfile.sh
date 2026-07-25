#!/usr/bin/env bash
# install-brewfile.sh — install this repo's Brewfile deps, but no-op gracefully
# when Homebrew is absent.
#
# `task install` must work in two very different places: a Homebrew host (Evan's
# Mac), and harmon-init's OWN devcontainer, which bakes its toolchain into the
# image and ships no brew. Running `brew bundle` unconditionally hard-fails in
# the latter before `task install` can reach the uv-based copier step the
# template-render tests need. So skip the Brewfile when brew is missing rather
# than aborting; on a brew host this behaves exactly like the previous inline
# `brew bundle` call.
set -euo pipefail

# Absolute path to THIS repo's Brewfile (never a user/global one).
root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v brew >/dev/null 2>&1; then
    echo "install: Homebrew not found — skipping Brewfile (image-baked toolchain assumed; run 'task bootstrap' to install Homebrew)."
    exit 0
fi

# HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: don't cascade-upgrade unrelated
# already-installed brew dependents.
HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew bundle --file="${root}/Brewfile"
