#!/usr/bin/env bash
# install-copier.sh — ensure copier (the template engine) is installed, on the
# platforms where the Brewfile can't provide it.
#
# copier is maintenance-only tooling for harmon-init itself: the template-render
# tests (`task test:template`) call it. Generated repos never render templates,
# so it is kept out of template/.
#
# On a Homebrew host copier comes from the Brewfile (`brew "copier"`), already on
# PATH via brew — nothing to do here. Only the brew-less case (this repo's
# devcontainer) needs uv to provide it; uv installs to ~/.local/bin, which the
# devcontainer image already puts on PATH. This is the same platform split the
# Brewfile uses for codex (`cask "codex" if OS.mac?`, else npm on Linux).
#
# --force overwrites any foreign same-named entry point (e.g. a stale pipx shim)
# instead of aborting, and keeps reruns idempotent.
#
# Pinned to the same version images/devcontainer/Dockerfile installs, so a
# brew-less host (this repo's devcontainer, or a bare Linux box) lands on the
# identical, tested copier release rather than whatever uv resolves that day.
# scripts/test-copier-validators.sh cross-checks that the two pins agree.
set -euo pipefail

# renovate: datasource=pypi depName=copier
COPIER_VERSION=9.17.1

if command -v brew >/dev/null 2>&1; then
    exit 0
fi

uv tool install --force "copier==${COPIER_VERSION}"
