#!/usr/bin/env bash
set -euo pipefail

# openspec.sh — run the pinned OpenSpec CLI (https://github.com/Fission-AI/OpenSpec).
#
# OPENSPEC_VERSION always comes from the Taskfile var of the same name (the
# `# renovate:` pin lives there, singly) — every `task spec:*` exports it, so
# a standalone call must set it too; there is no second copy of the pin here
# to drift from it.
#
# Prefers the user-local install `task spec:install` puts on PATH when its
# version matches the pin — the devcontainer already has one (installed at
# postCreate), so every `task spec:*` command is instant and network-free
# there. Falls back to npx otherwise (a fresh clone that hasn't run
# spec:install), the same local-binary-or-npx dispatch
# scripts/markdownlint.sh and scripts/devcontainer-assert.sh already use for
# their own pinned CLIs.
: "${OPENSPEC_VERSION:?OPENSPEC_VERSION is not set — run via task spec:* or export it}"

if command -v openspec >/dev/null 2>&1 && [ "$(openspec --version 2>/dev/null)" = "$OPENSPEC_VERSION" ]; then
    exec openspec "$@"
fi

exec npx --yes "@fission-ai/openspec@${OPENSPEC_VERSION}" "$@"
