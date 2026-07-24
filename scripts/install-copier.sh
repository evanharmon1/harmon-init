#!/usr/bin/env bash
# install-copier.sh — install copier (the template engine) via uv, idempotently,
# and make sure it is invocable from the shell.
#
# copier is maintenance-only tooling for harmon-init itself: the template-render
# tests (`task test:template`) call it. Generated repos never render templates,
# so copier is intentionally kept out of the Brewfile and template/. It is
# installed via uv — not brew — so `task install` provisions it with or without
# Homebrew, notably inside this repo's brew-less devcontainer.
#
# --force keeps reruns idempotent AND overwrites a foreign copier entry point
# (e.g. a pre-existing pipx- or brew-managed shim already sitting in uv's tool
# bin dir), which a plain `uv tool install` refuses to replace — it would abort
# with "Executable already exists: copier (use `--force` to overwrite)".
set -euo pipefail

uv tool install --force copier

# uv installs tool shims to its bin dir (~/.local/bin by default), which a clean
# macOS does not put on PATH — so copier would be uninvocable in new shells, and
# `task verify`'s template-render tests could not find it. Ensure the dir is on
# PATH for future shells.
#
# Skip when it is already on PATH (e.g. this devcontainer prepends it): once uv's
# rc blurb is present but the current shell has not re-sourced it, a repeat
# `uv tool update-shell` exits non-zero by design ("… is not in PATH, but the
# … configuration files are already up-to-date"). That must not fail a rerun of
# `task install`, so guard the call and treat its benign non-zero exit as a
# no-op — the rc is already configured; the user just needs a fresh shell.
bindir="$(uv tool dir --bin)"
case ":${PATH}:" in
*":${bindir}:"*) ;; # already on PATH — nothing to do
*) uv tool update-shell || true ;;
esac
