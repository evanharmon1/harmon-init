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
# With no glob/file args, a canonical repo-wide default set is used: the tracked
# Markdown files in a Git work tree, or a glob over the tree anywhere else.
set -euo pipefail

mode="${1:-check}"
if [ "$#" -gt 0 ]; then shift; fi

# Canonical excludes: generated output (dist, .task, .terraform, .venv,
# node_modules), vendored agent assets (.claude/skills, .agents/skills, _bmad),
# scratch worktrees, spec fixtures, and the template/ tree (jinja markdown —
# present only in the template repo itself, an inert pattern everywhere else).
# One list feeds both default sources below, so they cannot drift apart.
default_excludes=(
    'template/**'
    '.claude/**'
    '.agents/skills/**'
    '_bmad/**'
    'specs/*/**'
    '**/node_modules/**'
    'dist/**'
    '.worktrees/**'
    '**/.terraform/**'
    '**/.venv/**'
    '**/.task/**'
    '.foreman/**'
    '.lane/**'
    '**/.lane-report.md'
)

# renovate: datasource=npm depName=markdownlint-cli2
MARKDOWNLINT_VERSION=0.24.1

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
# A failed probe, a mismatch, an unreadable banner, or a banner in an
# unrecognised shape all fall through to npx, so the pin decides what runs in
# every case.
#
# THE RULE: a read that can fail is not an answer. The probe's exit STATUS is
# taken first, and separately from parsing what it printed, because "it could
# not say" and "it said the wrong version" are different facts and only the
# second is about the pin. Discarding the status with `|| true` accepted a binary
# that printed the pinned banner and exited nonzero — a damaged global install, a
# broken wrapper, a Node runtime that has moved out from under it — as the pinned
# linter, and `task check` then ran that broken executable in place of the npx
# package that works.
#
# images/devcontainer/install/lib.sh states the same rule for the image's own
# version probes (harmon_installed_version), and the duplication is DELIBERATE
# rather than an oversight: this dispatcher cannot source that helper. It is
# root-only — part of harmon-init's image build, with no template twin — so it
# does not exist in a generated repository at all, and where it does exist it is
# a file the image or the remote bootstrap installed, so sourcing it would make
# resolving the linter depend on a provisioned machine. That is the one thing
# this script must not assume: it also runs on fresh scaffolds and unprovisioned
# CI. A change to the rule belongs in both places.
markdownlint_path_bin=""
if markdownlint_path_bin="$(command -v markdownlint-cli2 2>/dev/null)"; then
    # The banner's first line is `markdownlint-cli2 v<version> (markdownlint …)`.
    # Read with shell builtins alone, so resolving the linter needs nothing on
    # PATH but the linter.
    if markdownlint_banner="$("$markdownlint_path_bin" --version 2>/dev/null)"; then
        case "${markdownlint_banner%%$'\n'*}" in
        "markdownlint-cli2 v${MARKDOWNLINT_VERSION}" | "markdownlint-cli2 v${MARKDOWNLINT_VERSION} "*) ;;
        *) markdownlint_path_bin="" ;;
        esac
    else
        markdownlint_path_bin=""
    fi
fi

if [ -x node_modules/.bin/markdownlint-cli2 ]; then
    run=(node_modules/.bin/markdownlint-cli2)
elif [ -n "$markdownlint_path_bin" ]; then
    run=("$markdownlint_path_bin")
else
    run=(npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
fi

# THE DEFAULT SET IS THE TRACKED FILES. The gate judges what the repository
# holds, never an agent's or a tool's untracked scratch beside it: a driver's
# status file, an orchestrator brief, a run record a workflow keeps under .git/.
# A glob over the working tree reads all of those, so a clean checkout failed
# `task check` on files nobody could commit. `git ls-files` lists the index, so
# a file that is staged but not yet committed is still linted; one that is only
# on disk is not, until it is added. The lefthook hook and `task format` pass
# their files explicitly and are unaffected.
#
# markdownlint-cli2 reads every argument as a glob, and a plain path is a glob
# that matches itself, so it is handed over as it is: that keeps the `ignores`
# list in .markdownlint-cli2.jsonc in force (CHANGELOG.md, vendored trees). A
# path holding glob characters would match something else, and backslash
# escapes do not survive the tool's own path normalisation, so that path alone
# takes the `:` prefix, which marks a literal. A literal is not filtered by
# `ignores`; that is the cost of linting such a file at all, and it applies only
# to a tracked Markdown file with one of those characters in its name. A tracked
# file missing from the working tree is skipped: a deletion not yet staged is
# not a lint failure.
#
# Outside a Git work tree (a fresh scaffold before `git init`, an unpacked
# archive) there is no index to read, so the same excludes apply to a glob.
if [ "$#" -eq 0 ]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        pathspecs=(':(glob)**/*.md')
        for exclude in "${default_excludes[@]}"; do
            pathspecs+=(":(exclude,glob)${exclude}")
        done
        tracked_list="$(mktemp)"
        trap 'rm -f "$tracked_list"' EXIT
        # Status first, then the listing: a failed read is not an empty answer.
        if ! git ls-files -z -- "${pathspecs[@]}" >"$tracked_list"; then
            echo "markdownlint.sh: could not list tracked Markdown files" >&2
            exit 2
        fi
        while IFS= read -r -d '' tracked; do
            [ -f "$tracked" ] || continue
            case "$tracked" in
            *[][*?{}\(\)!+@\|#:\\]*) set -- "$@" ":${tracked}" ;;
            *) set -- "$@" "$tracked" ;;
            esac
        done <"$tracked_list"
        if [ "$#" -eq 0 ]; then
            echo "markdownlint.sh: no tracked Markdown files to lint"
            exit 0
        fi
    else
        set -- '**/*.md'
        for exclude in "${default_excludes[@]}"; do
            set -- "$@" "#${exclude}"
        done
    fi
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
