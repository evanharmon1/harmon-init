#!/usr/bin/env bash
# markdownlint.sh — resolve markdownlint-cli2 and run it in check or fix mode.
#
# Prefer the repo-pinned binary (node_modules/.bin) so hooks/CI match the
# lockfile; then a PATH-installed binary already AT the pin, which is what a
# provisioned machine (the devcontainer image, a remote VM the bootstrap set up)
# has; fall back to npx for non-node repos and fresh scaffolds. Invoking
# the .bin shim directly is package-manager-agnostic (works under npm too,
# where `pnpm exec` would break). Keeps this dispatch out of the
# Taskfile per the "keep cmds trivial; non-trivial shell lives in scripts/*.sh"
# rule.
#
# Usage:
#   markdownlint.sh check [glob-or-file ...]   # read-only gate
#   markdownlint.sh fix   [glob-or-file ...]   # best-effort auto-fix
# With no glob/file args, a canonical repo-wide default set is used.
set -euo pipefail

mode="${1:-check}"
if [ "$#" -gt 0 ]; then shift; fi

# Canonical excludes: generated output (dist, .task, .terraform, .venv,
# node_modules), vendored agent assets (.claude/skills, .agents/skills, _bmad),
# scratch worktrees, spec fixtures, and the template/ tree (jinja markdown —
# present only in the template repo itself, an inert glob everywhere else).
default_globs=(
    '**/*.md'
    '#template/**'
    '#.claude/**'
    '#.agents/skills/**'
    '#_bmad/**'
    '#specs/*/**'
    '#**/node_modules/**'
    '#dist/**'
    '#.worktrees/**'
    '#**/.terraform/**'
    '#**/.venv/**'
    '#**/.task/**'
    '#.foreman/**'
)

# renovate: datasource=npm depName=markdownlint-cli2
MARKDOWNLINT_VERSION=0.23.2

# Prefer a repo-local install; then a PATH binary at the pin; otherwise fetch a
# PINNED version. Resolving `latest` here meant a new upstream rule could turn
# every repo red with no commit — the opposite of what a lint gate is for.
#
# The PATH step is there because `npx` never looks at PATH: it resolves a local
# or remote npm package. A machine the devcontainer image or the remote
# bootstrap provisioned already carries markdownlint-cli2 at this pin, and
# without this step `task check` re-downloaded it — so a job claiming to run
# with only what its setup installed did not, and an environment whose egress
# closes after setup could not run the gate at all.
#
# The version must MATCH the pin, and that is a safety condition rather than a
# nicety: preferring any PATH binary would silently downgrade every machine
# carrying an older global copy, which is the `latest` problem above in reverse.
# A mismatch, an unreadable banner, or a banner in an unrecognised shape all
# fall through to npx, so the pin decides what runs in every case.
markdownlint_path_bin=""
if markdownlint_path_bin="$(command -v markdownlint-cli2 2>/dev/null)"; then
    # The banner's first line is `markdownlint-cli2 v<version> (markdownlint …)`.
    # Read with shell builtins alone, so resolving the linter needs nothing on
    # PATH but the linter.
    markdownlint_banner="$("$markdownlint_path_bin" --version 2>/dev/null || true)"
    case "${markdownlint_banner%%$'\n'*}" in
    "markdownlint-cli2 v${MARKDOWNLINT_VERSION}" | "markdownlint-cli2 v${MARKDOWNLINT_VERSION} "*) ;;
    *) markdownlint_path_bin="" ;;
    esac
fi

if [ -x node_modules/.bin/markdownlint-cli2 ]; then
    run=(node_modules/.bin/markdownlint-cli2)
elif [ -n "$markdownlint_path_bin" ]; then
    run=("$markdownlint_path_bin")
else
    run=(npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
fi

if [ "$#" -eq 0 ]; then
    set -- "${default_globs[@]}"
fi

case "$mode" in
check)
    "${run[@]}" "$@"
    ;;
fix)
    # Best-effort: --fix must not abort `task format` on un-auto-fixable rule
    # violations (e.g. MD024 duplicate heading, MD040 missing fence language) —
    # `markdownlint.sh check` is the gate.
    "${run[@]}" --fix "$@" || true
    ;;
*)
    echo "markdownlint.sh: unknown mode '$mode' (expected check|fix)" >&2
    exit 2
    ;;
esac
