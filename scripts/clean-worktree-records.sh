#!/usr/bin/env bash
# clean-worktree-records.sh — prune stale worktree ADMIN RECORDS only, never a
# worktree directory. Run via `task clean:worktree-records`.
#
# A raw `git worktree prune` is not safe here (harmon-init#838, challenge r3):
# a stale record's HEAD can be DETACHED at a commit no branch, tag or
# remote-tracking ref contains, in which case the record is the only thing
# keeping that commit alive — pruning it makes the commit unreachable and
# eventually GC-collectible. worktree-rm.sh refuses exactly this case for a
# single record; this script applies the same guard to the bulk prune: while
# any at-risk record exists, the whole prune is refused with the rescue
# command, because `git worktree prune` offers no per-record selection.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

die() {
    echo "clean:worktree-records: $*" >&2
    exit 1
}

# Refs that would STILL reference a commit once the record is gone — the same
# exclusion set as worktree-rm.sh: per-worktree refs vanish with their
# worktree, so counting them would let the guard vouch for the very thing it
# is deciding about.
shared_refs_containing() {
    git for-each-ref --contains "$1" --format='%(refname)' 2>/dev/null |
        grep -Ev '^refs/(worktree|bisect|rewritten)/' || true
}

common="$(git rev-parse --path-format=absolute --git-common-dir)"

# git's own dry run is the authority on what a prune would remove
# ("Removing worktrees/<name>: <reason>"); LC_ALL=C pins the message shape.
prune_plan="$(LC_ALL=C git worktree prune --dry-run -v 2>&1)"
if [ -z "$prune_plan" ]; then
    echo "clean:worktree-records: nothing to prune."
    exit 0
fi

unsafe=0
while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | sed -n 's/^Removing worktrees\/\(.*\): .*$/\1/p')"
    [ -n "$name" ] || continue
    head_file="$common/worktrees/$name/HEAD"
    record_head="$(cat "$head_file" 2>/dev/null || true)"
    case "$record_head" in
    ref:* | '') : ;; # attached to a branch: the branch keeps the commits
    *)
        if git rev-parse --quiet --verify "$record_head^{commit}" >/dev/null 2>&1 &&
            [ -z "$(shared_refs_containing "$record_head")" ]; then
            echo "REFUSE  record '$name' still holds detached commit $record_head, which no branch, tag or remote-tracking ref contains — rescue it first: git branch rescue/$name $record_head" >&2
            unsafe=1
        fi
        ;;
    esac
done <<EOF
$prune_plan
EOF

if [ "$unsafe" -eq 1 ]; then
    die "refusing to prune while a record is the last reference to a commit (see above); rescue or discard those commits, then re-run"
fi

LC_ALL=C git worktree prune -v
echo "clean:worktree-records: stale records pruned (worktree directories are never touched)."
