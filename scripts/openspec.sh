#!/usr/bin/env bash
set -euo pipefail

# openspec.sh — exec the pinned OpenSpec CLI (https://github.com/Fission-AI/OpenSpec).
#
# OPENSPEC_VERSION is set by the Taskfile `spec:*` tasks from the pinned
# `OPENSPEC_VERSION` var (see the `# renovate:` annotation there); defaulted
# here too so the script also runs standalone.
OPENSPEC_VERSION="${OPENSPEC_VERSION:-1.11.0}"

exec npx --yes "@fission-ai/openspec@${OPENSPEC_VERSION}" "$@"
