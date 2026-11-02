#!/usr/bin/env bash
# Render web and non-web consumers; exercise the workflow artifact contract.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for tool in copier node yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FAIL: required tool '$tool' is not installed" >&2
        exit 1
    }
done
work="$(mktemp -d "${TMPDIR:-/tmp}/harmon-artifact-retention.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"
for profile in web-astro web-app general; do
    if ! copier copy --vcs-ref=HEAD --trust --defaults --skip-tasks \
        --data project_name="Artifact Retention Test" --data project_type="$profile" \
        --data github_remote_create=false --data github_release_init=false \
        --data run_task_install=false --data bunch_add=false --data obsidian_project_add=false \
        "$repo_root" "$work/$profile" >"$work/$profile.log" 2>&1; then
        cat "$work/$profile.log" >&2
        exit 1
    fi
done
node "$repo_root/scripts/test-artifact-retention.mjs" "$repo_root" "$work"
