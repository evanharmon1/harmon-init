#!/usr/bin/env bash
# guard-closing-keywords.sh — assemble the commit range and PR metadata that
# check-closing-keywords.sh needs, then run it.
#
# Why a script and not inline Taskfile `cmds:`: inline command strings are not
# seen by shellcheck/shfmt (`lint:shell` only covers `scripts/*.sh`), so this
# logic — traps, temp files, `git log`, `gh api` — was unlinted and untestable
# where it used to live (harmon-init#1196). The Taskfile target is now a
# one-liner that calls this file.
#
# Where it runs:
#   - CI (`closing-keywords.yml`) supplies PR metadata from the event payload
#     and never invokes this script; it calls check-closing-keywords.sh with a
#     trusted default-branch copy of that program.
#   - Locally, as the pre-PR pre-flight documented in AGENTS.md beside
#     `guard:release-title`, and as the first step of `task ci`.
#
# Inputs (all optional; every one has a documented fallback):
#   BASE_SHA   base commit-ish for the range          (default: origin/main)
#   HEAD_SHA   head commit-ish for the range          (default: HEAD)
#   PR_TITLE   the PR title  — see "PR metadata" below
#   PR_BODY    the PR body   — see "PR metadata" below
#   GH_REPO    owner/name    (default: `gh repo view` on the current remote)
#
# PR metadata: both PR_TITLE and PR_BODY are used verbatim when BOTH are set —
# which is how you pre-flight a title/body you have not published yet:
#
#   PR_TITLE="fix: …" PR_BODY="$(cat body.md)" task guard:closing-keywords
#
# If either is unset, the open PR for the current branch supplies both. Before
# a PR exists, a SUCCESSFUL empty listing substitutes inert placeholder
# metadata so the commit messages are still scanned; an API failure stays
# indeterminate rather than passing. Commit messages are read as data, never
# executed.
#
# Exit: 0 = ok, 1 = violation, 2 = indeterminate (refused to guess).
set -euo pipefail

# Resolve the sibling checker from THIS script's directory rather than $PWD:
# the Taskfile always runs from the repo root, but a hand-run from a
# subdirectory would otherwise fail with a confusing "no such file".
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

commits_file=$(mktemp)
trap 'rm -f "$commits_file"' EXIT

base_sha="${BASE_SHA:-origin/main}"
head_sha="${HEAD_SHA:-HEAD}"

if ! merge_base="$(git merge-base "$base_sha" "$head_sha")" || [ -z "$merge_base" ]; then
    echo "guard:closing-keywords: could not resolve merge-base for ${base_sha} and ${head_sha}; refusing to scan an indeterminate commit range" >&2
    exit 2
fi
if ! commit_count="$(git rev-list --count "${merge_base}..${head_sha}")"; then
    echo "guard:closing-keywords: could not count commits in ${merge_base}..${head_sha}; refusing an indeterminate range" >&2
    exit 2
fi
if [ "$commit_count" -gt 250 ]; then
    echo "guard:closing-keywords: PR range has ${commit_count} commits, exceeding the workflow's 250-commit API limit" >&2
    exit 1
fi
git log --format=%B "${merge_base}..${head_sha}" >"$commits_file"

if [ -z "${PR_TITLE+x}" ] || [ -z "${PR_BODY+x}" ]; then
    branch="$(git branch --show-current)"
    if [ -z "$branch" ] || ! pr_json="$(gh pr list --head "$branch" --state open --limit 2 --json title,body)"; then
        echo "guard:closing-keywords: could not list PR metadata for the current branch; supply both PR_TITLE and PR_BODY" >&2
        exit 2
    fi
    pr_count="$(printf '%s' "$pr_json" | jq 'length')"
    if [ "$pr_count" -gt 1 ]; then
        echo "guard:closing-keywords: multiple open PRs match branch ${branch}; supply both PR_TITLE and PR_BODY" >&2
        exit 2
    elif [ "$pr_count" -eq 1 ]; then
        PR_TITLE="$(printf '%s' "$pr_json" | jq -r '.[0].title')"
        PR_BODY="$(printf '%s' "$pr_json" | jq -r '.[0].body // ""')"
    else
        echo "guard:closing-keywords: no open PR for ${branch}; checking commits with inert pre-PR metadata" >&2
        PR_TITLE="Pre-PR local CI"
        PR_BODY="No pull request body exists yet."
    fi
fi
export PR_TITLE PR_BODY

repo="${GH_REPO:-}"
if [ -z "$repo" ]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

"$script_dir/check-closing-keywords.sh" --repo "$repo" \
    --title-env PR_TITLE --body-env PR_BODY --commits-file "$commits_file"
