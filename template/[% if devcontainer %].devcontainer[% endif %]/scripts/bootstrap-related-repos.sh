#!/usr/bin/env bash
set -euo pipefail

# Clone "related" repos listed in .devcontainer/related-repos.txt into
# /workspaces/, adjacent to the main repo. Idempotent and NON-DESTRUCTIVE: if a
# target dir already exists it is left completely untouched (no fetch, no pull,
# no checkout, no warning) — fetching is fetch-related-repos.sh's job at start.
#
# Runs on devcontainer create (post-create-common.sh), on devcontainer start
# (post-start-common.sh in background), and upon scope verification in
# setup-gh-scopes.sh, so a rebuilt, persistence-lost, or newly authenticated
# container re-clones any sibling that is missing.
#
# Config format (.devcontainer/related-repos.txt):
#   owner/repo                       # default branch, cloned via gh CLI or git fallback
#   owner/repo@branch                # specific branch
#   https://github.com/owner/repo    # full URL (also supports .git suffix)
#   git@github.com:owner/repo.git    # ssh URL
#
# Lines starting with # are comments. Blank lines are ignored.
#
# Failures (missing config, bad URL, network errors) log a warning and
# continue — this script never causes post-create, post-start, or scope setup to fail.

# Prevent VS Code's JS debug bootloader from breaking child Node processes
# spawned by gh. See post-create-common.sh for the full explanation.
unset NODE_OPTIONS

# Never prompt or hang on missing credentials or behind egress filters.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../related-repos.txt}"
WORKSPACES_DIR="${WORKSPACES_DIR:-/workspaces}"
GIT_BASE_URL="${RELATED_REPOS_GIT_BASE_URL:-https://github.com/}"

# --- Pre-flight checks ---

if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> No related-repos.txt found at ${CONFIG_FILE}; skipping."
    exit 0
fi

if [ ! -d "$WORKSPACES_DIR" ]; then
    echo "==> WARNING: ${WORKSPACES_DIR} does not exist; skipping related-repo bootstrap." >&2
    exit 0
fi

# /workspaces is owned by root in the devcontainer image — VS Code only fixes
# ownership on the workspace folder itself, not its parent. Make it writable
# by vscode so subsequent `git clone` calls can create sibling directories.
# Idempotent: chown is a no-op if ownership already matches.
if [ ! -w "$WORKSPACES_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo chown vscode:vscode "$WORKSPACES_DIR" 2>/dev/null || true
    fi
fi

# --- Clean up orphaned temporary directories ---
# Remove leftover .bootstrap-* directories older than 60 minutes (from runs killed
# mid-clone). Younger ones are left alone since concurrent runs may own them.
while IFS= read -r orphan_dir; do
    [ -n "$orphan_dir" ] || continue
    echo "==> Removing orphaned temporary bootstrap directory: ${orphan_dir}"
    rm -rf "$orphan_dir"
done < <(find "$WORKSPACES_DIR" -maxdepth 1 -name '.bootstrap-*' -type d -mmin +60 2>/dev/null || true)

# --- Parse and clone ---

cloned=0
skipped=0
failed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip inline comments (everything from the first # onward), then trim
    # leading and trailing whitespace.
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines (and lines that were comment-only).
    [ -z "$line" ] && continue

    # Split optional @branch suffix. Only split on the LAST @ so ssh URLs
    # like git@github.com:o/r.git are not mangled — those URLs always end
    # in .git, so a trailing @branch on the same line is unambiguous.
    branch=""
    target_spec="$line"
    if [[ "$line" == *"@"* ]]; then
        suffix="${line##*@}"
        # Treat the suffix as a branch only if it doesn't look like a host
        # (no dots, no colons, no slashes). This keeps `git@github.com:...`
        # intact while still splitting `owner/repo@feature/foo` correctly
        # only when the user wrote a plain branch name.
        if [[ "$suffix" != *.* && "$suffix" != *:* && "$suffix" != */* ]]; then
            branch="$suffix"
            target_spec="${line%@*}"
        fi
    fi

    # Derive the target basename.
    #   owner/repo                  -> repo
    #   https://host/owner/repo.git -> repo
    #   git@host:owner/repo.git     -> repo
    basename_raw="${target_spec##*/}"  # strip everything up to last /
    basename_raw="${basename_raw##*:}" # strip ssh "host:" prefix if any
    basename="${basename_raw%.git}"    # strip optional .git

    if [ -z "$basename" ]; then
        echo "==> WARNING: could not derive directory name for entry '${raw_line}'; skipping." >&2
        failed=$((failed + 1))
        continue
    fi

    target="${WORKSPACES_DIR}/${basename}"

    if [ -e "$target" ]; then
        echo "==> Skipping ${basename} (already present at ${target})"
        skipped=$((skipped + 1))
        continue
    fi

    # Clone into a private temporary directory first. Never clone into $target
    # directly: if a user or concurrent process creates $target in between,
    # cleaning up a failed clone must never remove the user's checkout.
    clone_tmp="$(mktemp -d "${WORKSPACES_DIR}/.bootstrap-${basename}.XXXXXX")"

    # Decide whether to use gh (for owner/repo shorthand) or git (for URLs).
    use_gh=false
    if [[ "$target_spec" != *://* && "$target_spec" != *@*:* && "$target_spec" == */* ]]; then
        use_gh=true
    fi

    branch_label="${branch:-default branch}"
    echo "==> Cloning ${target_spec} (${branch_label}) -> ${target}"

    clone_rc=1
    if [ "$use_gh" = true ]; then
        gh_auth=false
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            gh_auth=true
        fi

        if [ "$gh_auth" = true ]; then
            set +e
            if [ -n "$branch" ]; then
                gh repo clone "$target_spec" "$clone_tmp" -- --branch "$branch" --quiet
            else
                gh repo clone "$target_spec" "$clone_tmp" -- --quiet
            fi
            clone_rc=$?
            set -e

            if [ "$clone_rc" -ne 0 ]; then
                echo "==> WARNING: gh repo clone failed for ${target_spec} (exit ${clone_rc}); falling back to git clone." >&2
                rm -rf "$clone_tmp"
                clone_tmp="$(mktemp -d "${WORKSPACES_DIR}/.bootstrap-${basename}.XXXXXX")"
            fi
        else
            echo "==> gh is unauthenticated; falling back to git clone for ${target_spec}"
        fi

        if [ "$clone_rc" -ne 0 ]; then
            fallback_url="${GIT_BASE_URL%/}/${target_spec}.git"
            set +e
            if [ -n "$branch" ]; then
                git clone --quiet --branch "$branch" "$fallback_url" "$clone_tmp"
            else
                git clone --quiet "$fallback_url" "$clone_tmp"
            fi
            clone_rc=$?
            set -e
        fi
    else
        set +e
        if [ -n "$branch" ]; then
            git clone --quiet --branch "$branch" "$target_spec" "$clone_tmp"
        else
            git clone --quiet "$target_spec" "$clone_tmp"
        fi
        clone_rc=$?
        set -e
    fi

    if [ "$clone_rc" -eq 0 ]; then
        # Atomically publish into the target path. GNU coreutils mv -T treats the
        # destination as a normal file/directory target rather than a directory into
        # which to move; it renames atomically when $target is absent and fails
        # (without nesting or clobbering) if $target already exists as a non-empty
        # directory or file. (Note: this script runs only in the Linux devcontainer).
        set +e
        mv -T "$clone_tmp" "$target" 2>/dev/null
        publish_rc=$?
        set -e

        if [ "$publish_rc" -eq 0 ]; then
            cloned=$((cloned + 1))
        else
            echo "==> Skipping ${basename} (destination ${target} appeared concurrently or already exists)"
            skipped=$((skipped + 1))
            rm -rf "$clone_tmp"
        fi
    else
        echo "==> WARNING: failed to clone ${target_spec} (exit ${clone_rc}); continuing." >&2
        failed=$((failed + 1))
        rm -rf "$clone_tmp"
    fi
done <"$CONFIG_FILE"

# --- Summary ---

total=$((cloned + skipped + failed))
if [ "$total" -eq 0 ]; then
    echo "==> No repos configured in ${CONFIG_FILE}; nothing to do."
else
    echo "==> Bootstrap complete: ${cloned} cloned, ${skipped} skipped, ${failed} failed"
fi

# Always exit 0 — failures are logged but never block post-create.
exit 0
