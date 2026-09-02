#!/usr/bin/env bash
set -euo pipefail

# install-openspec.sh — user-local, PATH-visible install of the pinned
# OpenSpec CLI (https://github.com/Fission-AI/OpenSpec).
#
# scripts/openspec.sh (task spec:validate/list/update/run) fetches OpenSpec
# ephemerally through npx, which is all this repo's own automation needs. But
# the generated /opsx:* skills invoke a bare `openspec` command, which
# nothing puts on PATH otherwise. `~/.local/bin` is already on PATH in the
# devcontainer (baked into the shared image's own PATH, not dependent on
# shell-aliases.sh's interactive-shell sourcing), so installing there —
# global to that prefix, never a repo-local node_modules, since there is no
# package.json — makes the bare command resolve without root or touching
# the shared system Node install.
#
# Usage: install-openspec.sh <version>  (Taskfile's spec:install passes the
# pinned OPENSPEC_VERSION, so the version stays single-sourced there).
version="${1:?usage: install-openspec.sh <version>}"

npm install --global --prefix "$HOME/.local" "@fission-ai/openspec@${version}"

# `npm install --prefix` places the binary on disk; it cannot make the bare
# `openspec` command resolve to it. An earlier PATH entry (a different
# global install, a stale shim) — or $HOME/.local/bin simply not being on
# PATH at all — can silently shadow it, so the generated /opsx:* skills
# would still invoke the wrong CLI (or none) even though this install
# itself succeeded. This is the invariant those skills depend on, so verify
# the EFFECTIVE resolution rather than trusting a successful `npm install`
# to imply it, and fail closed if it does not hold.
resolved="$(command -v openspec || true)"
resolved_version=""
[ -n "$resolved" ] && resolved_version="$(openspec --version 2>/dev/null || true)"
if [ -z "$resolved" ] || [ "$resolved_version" != "$version" ]; then
    cat >&2 <<EOF

openspec ${version} was installed to $HOME/.local/bin/openspec, but the bare
'openspec' command on PATH resolves to ${resolved:-nothing} (version
${resolved_version:-unknown}), not that install. Either \$HOME/.local/bin is
not on PATH, or an earlier PATH entry shadows it — check with
'which -a openspec' and fix the ordering, or put \$HOME/.local/bin first on
PATH:

    export PATH="\$HOME/.local/bin:\$PATH"

EOF
    exit 1
fi
