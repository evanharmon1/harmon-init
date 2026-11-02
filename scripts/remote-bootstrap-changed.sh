#!/usr/bin/env bash
# remote-bootstrap-changed.sh — decide whether a range needs the bootstrap proof.
#
# remote-bootstrap.yml has no workflow-level `paths:` filter because its
# required remote-bootstrap-verify check must report on unrelated PRs too.
# This detector keeps the expensive proof filtered inside that workflow.
#
# usage: remote-bootstrap-changed.sh <base_sha> <head_sha>
#   prints `true` or `false` (also written to $GITHUB_OUTPUT as changed=...)
#
# Fail safe, like devcontainer-changed.sh: anything unknown answers `true`.
# An unnecessary proof costs a run; skipping a required proof hides a defect.
set -euo pipefail

base="${1:-}"
head="${2:-HEAD}"

emit() {
    echo "$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "changed=$1" >>"$GITHUB_OUTPUT"
    fi
    exit 0
}

# Push and dispatch reconcile unconditionally by passing an empty base.
case "$base" in
"" | 0000000000000000000000000000000000000000)
    echo "remote-bootstrap-changed: no comparison range — reconciling" >&2
    emit true
    ;;
esac

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "remote-bootstrap-changed: base $base is not in this clone — assuming changed" >&2
    emit true
fi
if ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
    echo "remote-bootstrap-changed: head $head is not in this clone — assuming changed" >&2
    emit true
fi

tmp_diff="$(mktemp)" || emit true
trap 'rm -f "$tmp_diff"' EXIT

# Compare the event endpoints, as devcontainer-changed.sh does. --no-renames
# reports both sides of a move out of a relevant directory; -z preserves tabs,
# newlines and non-ASCII bytes rather than quoting the paths the matcher sees.
if ! git diff -z --name-only --no-renames "$base" "$head" >"$tmp_diff" 2>/dev/null; then
    echo "remote-bootstrap-changed: could not diff $base..$head — assuming changed" >&2
    emit true
fi

while IFS= read -r -d '' path; do
    case "$path" in
    images/devcontainer/* | scripts/* | Taskfile.yml | renovate.json | \
        .devcontainer/agent/agent-autonomy.sh | .devcontainer/config/agent/* | \
        .github/workflows/remote-bootstrap.yml)
        # scripts/* includes this detector and the aggregate's result helper.
        emit true
        ;;
    esac
done <"$tmp_diff"

emit false
