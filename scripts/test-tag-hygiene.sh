#!/usr/bin/env bash
# test-tag-hygiene.sh — the tag `git describe` selects must look like a release.
#
# harmon-init renders itself with `copier --vcs-ref=HEAD`, and copier derives the
# template version from `git describe`. `git describe` considers only tags that
# are ANCESTORS of HEAD and prefers the NEAREST one — so a non-release tag on a
# reachable commit close to HEAD outranks the release tag and feeds copier a
# version string it rejects as non-PEP 440. That kills `test:copier-validators`
# and `test:template` for every commit descending from that tag, whatever the
# commit contains (issue #598: `v0.0.0-probe` on the v4.15.0 release commit).
#
# The remedy is never to move the release tags but to keep operator tags — the
# foreman tag-immutability probe target above all — on an ORPHAN commit, which
# is unreachable from every branch and therefore invisible to `git describe`.
# docs/CHECKLIST.md carries the recipe.
#
# Scope: the SELECTED tag, not every reachable one. This repo's history carries
# pre-v3 tags that are not release-shaped (`2.0.15`, `list`, from 2024) and are
# entirely harmless, because `git describe` prefers the nearest tag and never
# reaches back to them. Failing on those would make `verify` permanently red
# while saying nothing about the failure this guards. Tags sharing the selected
# tag's commit ARE checked: that is exactly the #598 shape (two tags on one
# release commit), and which of them `git describe` reports is not a tie-break
# worth betting the gate on.
#
# Vacuous without tags: GitHub's checkout fetches none by default, leaving
# `git describe` nothing to select, so this would pass while asserting nothing.
# The build workflow's lint job therefore checks out with `fetch-depth: 0` — the
# guard's first job is local `task verify` (this failure class originates on a
# workstation, where an operator creates the tag), but once such a tag reaches
# origin, CI naming it directly beats seven opaque template-test failures.
# A tagless checkout elsewhere still passes by design rather than erroring.
# Root-only: only a repo that copier-renders ITSELF derives a version this way,
# so there is no template twin.
set -euo pipefail
cd "$(dirname "$0")/.."

# Release tags as release-please writes them: v<major>.<minor>.<patch>. Any
# suffix (pre-release, probe, scratch) is what breaks the derivation, so the
# pattern is deliberately strict rather than a general semver match.
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

# The nearest tag reachable from HEAD — the one `git describe` derives from.
# Empty when no tag is reachable (a tagless CI checkout, or a fresh repo).
nearest=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$nearest" ]; then
    echo "tag hygiene OK: no tag reachable from HEAD (nothing for git describe to select)"
    exit 0
fi

selected_commit=$(git rev-list -n 1 "$nearest")

bad=""
checked=0
# Read via a while loop rather than `mapfile`, which macOS bash 3.2 lacks.
while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    checked=$((checked + 1))
    # `grep -E`, not `grep -P`: BSD grep has no -P.
    if ! printf '%s\n' "$tag" | grep -qE "$RELEASE_TAG_RE"; then
        bad="${bad}${bad:+ }${tag}"
    fi
done < <(git tag --points-at "$selected_commit")

if [ -n "$bad" ]; then
    echo "FAIL: non-release tag(s) on the commit git describe selects: ${bad}" >&2
    cat >&2 <<'EOF'
`git describe` derives its version from the nearest reachable tag, so this
outranks the release tag and copier renders a non-PEP 440 template version —
breaking `task test:copier-validators` and `task test:template` on every commit
below it, locally and in PR CI alike.

Remediation: the tag must not be reachable from HEAD. Renaming it does NOT
help — `git describe --tags` considers tags of every name, so any tag on a
reachable commit still wins. Either delete it, or re-point it at an orphan
commit using the recipe under "Foreman operator setup" in docs/CHECKLIST.md:

  git tag -d <tag>
  git push origin :refs/tags/<tag>          # may need a ruleset bypass
  # keep it (e.g. the foreman probe target)? recreate it unreachable:
  git tag <tag> "$(git commit-tree "$(git hash-object -t tree /dev/null)" -m 'probe target (orphan; keep unreachable from any branch)')"
  git push origin <tag>
EOF
    exit 1
fi

echo "tag hygiene OK: git describe selects ${nearest}; ${checked} tag(s) on that commit are release-shaped"
