#!/usr/bin/env bash
# test-copier-validators.sh — guard the answer validators that keep unsafe
# characters out of paths rendered into Taskfile commands.
#
# These validators are the ONLY thing standing between a user-supplied
# destination and an invalid generated Taskfile: `bunches_directory` and
# `obsidian_directory` are interpolated into a YAML plain scalar that is then
# parsed as a single-quoted shell word, so a `:` breaks the YAML and a `'`
# breaks the shell. Nothing else covers them — the render profiles only exercise
# the defaults, and test-meta-install.sh calls the script directly, bypassing
# copier entirely. Without this, deleting a character from a validator leaves
# every other test green while generated repos break.
#
# Rejections are cheap: copier validates answers before rendering any file, so
# only the final accepted case pays for a full render.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

# copier itself is not optional here: this script IS one of the primary
# template-render gates, so a local skip would report `task verify` green
# while validating nothing. copier is now preinstalled in the devcontainer
# image and installed by `task install` on every other host
# (scripts/install-copier.sh), so there is no supported environment where it
# is legitimately absent — fail loudly instead of silently skipping. See #921.
if ! command -v copier >/dev/null 2>&1; then
    # `task install` is the only remedy correct on every host: it installs the
    # Brewfile's copier under Homebrew and the pinned uv one otherwise
    # (scripts/install-copier.sh no-ops under brew by design, so naming it
    # directly would silently do nothing on a Mac). Deliberately NOT a bare
    # `uv tool install copier`: that resolves to whatever is latest, so
    # following the advice would satisfy this check and then run the render
    # gates on an unreviewed version, defeating the pin this repo just added.
    echo "FAIL: copier not found — run 'task install'" >&2
    exit 1
fi

work="$(mktemp -d -t harmon-init-validators-XXXXXX)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "  ok — $1"; }
fail() {
    echo "  FAIL — $1" >&2
    failures=$((failures + 1))
}

# Name the real cause when a render dies on copier's dirty-tree wip commit
# having swept in a registered git worktree (e.g. an agent worktree under
# .claude/worktrees/). Such a directory is a gitlink with no `.gitmodules`
# entry, so the nested clone reports a submodule error in a repo with no
# submodules — and the operator's diff is usually nowhere near it.
hint_stale_worktree() {
    if grep -q 'No url found for submodule path' "$work/render.log"; then
        echo "      hint: a registered git worktree inside this checkout was staged as a gitlink by copier's dirty-tree commit (this repo has no submodules). Gitignore it, or remove it with 'git worktree remove' / 'git worktree prune'." >&2
    fi
}

# One render attempt. Echoes nothing; returns copier's exit status.
render() {
    local answer="$1" out="$2"
    rm -rf "$out"
    copier copy --vcs-ref=HEAD --trust --defaults --skip-tasks \
        --data project_name="Validator Test" \
        --data project_slug="validator-test" \
        --data bunch_add=true \
        --data "bunches_directory=$answer" \
        . "$out" >"$work/render.log" 2>&1
}

render_coder_uri() {
    local answer="$1" out="$2"
    rm -rf "$out"
    copier copy --vcs-ref=HEAD --trust --defaults --skip-tasks \
        --data project_name="Validator Test" \
        --data project_slug="validator-test" \
        --data "devcontainer_coder_folder_uri=$answer" \
        . "$out" >"$work/render.log" 2>&1
}

echo "==> unsafe characters are rejected at answer time"
# Each of these breaks the YAML scalar, the shell quoting, or both.
i=0
for bad in "/tmp/Vault: Work" "~/Bob's Vault" '~/say "hi"' '~/a$b' '~/a#b' '~/a`b`c' '~/a\b'; do
    i=$((i + 1))
    if render "$bad" "$work/bad-$i"; then
        fail "accepted an unsafe destination: $bad"
    elif grep -q 'Validation error' "$work/render.log"; then
        pass "rejected: $bad"
    else
        fail "rejected $bad, but not by the validator — copier failed for another reason"
        sed 's/^/      /' "$work/render.log" >&2
        hint_stale_worktree
    fi
done

echo "==> an ordinary path containing a space still renders and parses"
if render '~/Fine Vault' "$work/good"; then
    if grep -q "meta-install.sh bunch 'Validator Test' '~/Fine Vault'" "$work/good/Taskfile.yml"; then
        pass "destination rendered into the install command"
    else
        fail "destination did not render as expected"
    fi
    if (cd "$work/good" && task --list >/dev/null 2>&1); then
        pass "generated Taskfile parses"
    else
        fail "generated Taskfile does not parse"
    fi
else
    fail "rejected a valid path containing a space"
    sed 's/^/      /' "$work/render.log" >&2
    hint_stale_worktree
fi

echo "==> the Coder README badge accepts only a captured Dev Containers URI"
if render_coder_uri 'vscode-remote://dev-container%2B7b7d@ssh-remote+coder.dev/workspaces/test' "$work/escaped-coder-uri"; then
    if grep -Fq 'vscode.dev/redirect?url=vscode%3A//vscode-remote/dev-container%252B7b7d' "$work/escaped-coder-uri/README.md"; then
        pass "accepted and safely wrapped the capture helper's percent-encoded separator"
    else
        fail "accepted the percent-encoded separator but rendered the wrong external protocol URL"
    fi
else
    fail "rejected the capture helper's percent-encoded separator"
    sed 's/^/      /' "$work/render.log" >&2
    hint_stale_worktree
fi

for bad_coder_uri in \
    'vscode://ms-vscode-remote.remote-containers/cloneInVolume' \
    'VSCODE-REMOTE://dev-container+7b7d@ssh-remote+coder.dev/workspaces/test' \
    'vscode-remote://dev-container+7b7d' \
    'vscode-remote://dev-container+zz@ssh-remote+coder.dev/workspaces/test' \
    'vscode-remote://dev-container+7b7@ssh-remote+coder.dev/workspaces/test' \
    'vscode-remote://dev-container+7b7d@ssh-remote+coder.dev/not-a-workspace'; do
    if render_coder_uri "$bad_coder_uri" "$work/bad-coder-uri"; then
        fail "accepted an incomplete captured Coder folder URI: $bad_coder_uri"
    elif grep -q 'Validation error' "$work/render.log"; then
        pass "rejected an incomplete captured Coder folder URI"
    else
        fail "rejected the incomplete captured URI for an unexpected reason"
        sed 's/^/      /' "$work/render.log" >&2
        hint_stale_worktree
    fi
done

# copier is installed from two places that cannot see each other: the shared
# devcontainer image (images/devcontainer/Dockerfile, baked in) and
# scripts/install-copier.sh (`task install` on every other brew-less host).
# Renovate bumps each independently, so nothing else catches them drifting
# apart — a stale image pin would silently ship every devcontainer an older
# copier than every other host installs. Both files sit in Renovate's
# "Devcontainer" group (images/devcontainer/** and scripts/**), so a release
# bumps both in ONE PR and this check passes or fails as a unit.
#
# This runs in required CI too (build.yml's lint job lists it explicitly, after
# the copier install) — a guard that only runs locally would miss the case it
# exists for: a Renovate bump that moves one pin and not the other arrives as a
# PR. Scope note: CI still installs copier UNPINNED, here and in the
# template-test matrix, so the version CI renders with is not the pinned one.
# Pinning every copier execution across the workflows is its own unit of work
# (#966), as is binding verify's target list to the workflow's (#962).
#
# This check lives here (root-only, no template/ twin) rather than in
# scripts/test-tasks.sh, which IS a byte-identical twin shipped to generated
# repos that have neither file. See #921.
echo "==> copier version pins agree between the devcontainer image and install-copier.sh"
pin_from() {
    # $1 = file, $2 = ERE capturing the whole `NAME=<version>` assignment.
    # `|| true` on the pipeline so a no-match returns EMPTY rather than killing
    # the script: under `set -euo pipefail` a failing grep inside a command
    # substitution aborts silently, with a non-zero exit and no diagnostic —
    # fail-closed, but unexplained. Emptiness is the signal the explicit
    # `[ -n ... ] || fail` checks below turn into a named failure. grep's own
    # stderr is deliberately NOT redirected, so a missing file still says so.
    grep -oE "$2" "$1" | head -n1 | cut -d= -f2 | tr -d '"' || true
}
image_pin="$(pin_from "$repo/images/devcontainer/Dockerfile" '^ARG COPIER_VERSION=[^[:space:]]+')"
install_pin="$(pin_from "$repo/scripts/install-copier.sh" '^COPIER_VERSION=[^[:space:]]+')"

[ -n "$image_pin" ] || fail "images/devcontainer/Dockerfile: no 'ARG COPIER_VERSION=' found"
[ -n "$install_pin" ] || fail "scripts/install-copier.sh: no 'COPIER_VERSION=' found"

if [ -n "$image_pin" ] && [ -n "$install_pin" ]; then
    if [ "$image_pin" != "$install_pin" ]; then
        fail "copier version pins disagree: image=${image_pin}, install-copier.sh=${install_pin}"
    else
        echo "  ok — both pin ${image_pin}"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "test-copier-validators: FAILED ($failures)" >&2
    exit 1
fi
echo "test-copier-validators: PASS"
