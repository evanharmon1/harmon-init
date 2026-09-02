#!/usr/bin/env bash
set -euo pipefail

# install-openspec.sh — user-local, PATH-visible install of the pinned
# OpenSpec CLI (https://github.com/Fission-AI/OpenSpec).
#
# scripts/openspec.sh (task spec:validate/list/update/run) fetches OpenSpec
# ephemerally through npx, which is all this repo's own automation needs. But
# the generated `/opsx:*` skills invoke a bare `openspec` command, which
# nothing puts on PATH otherwise. `~/.local/bin` is already first on PATH in
# the devcontainer (.devcontainer/config/shell-aliases.sh), so installing
# there — global to that prefix, never a repo-local node_modules, since
# there is no package.json — makes the bare command resolve without root or
# touching the shared system Node install.
#
# Usage: install-openspec.sh <version>  (Taskfile's spec:install passes the
# pinned OPENSPEC_VERSION, so the version stays single-sourced there).
version="${1:?usage: install-openspec.sh <version>}"

npm install --global --prefix "$HOME/.local" "@fission-ai/openspec@${version}"
