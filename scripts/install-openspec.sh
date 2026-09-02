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

# `npm install --prefix` cannot modify the invoking or any future shell's
# PATH — only the devcontainer's shell-aliases.sh already puts
# $HOME/.local/bin on PATH. Outside it (a stock macOS shell, e.g.), the
# install above succeeds but the generated /opsx:* skills' bare `openspec`
# invocations would still fail with "command not found" and no indication
# why, so detect that here and give the exact persistent fix.
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*)
    cat >&2 <<EOF

openspec installed to $HOME/.local/bin, but that directory is not on your
PATH, so the bare 'openspec' command the generated skills invoke will not
resolve. Add this to your shell rc (~/.bashrc, ~/.zshrc, etc.) and restart
your shell:

    export PATH="\$HOME/.local/bin:\$PATH"

EOF
    ;;
esac
