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
for bad_coder_uri in \
    'vscode://ms-vscode-remote.remote-containers/cloneInVolume' \
    'vscode-remote://dev-container+7b7d' \
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

if [ "$failures" -gt 0 ]; then
    echo "test-copier-validators: FAILED ($failures)" >&2
    exit 1
fi
echo "test-copier-validators: PASS"
