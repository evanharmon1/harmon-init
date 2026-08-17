#!/usr/bin/env bash
# clean-worktree-records.sh — prune stale worktree ADMIN RECORDS only, never a
# worktree directory. Run via `task clean:worktree-records`.
#
# A raw `git worktree prune` is not safe here (harmon-init#838, challenge r3):
# a stale record's HEAD can be DETACHED at a commit no branch, tag or
# remote-tracking ref contains, in which case the record is the only thing
# keeping that commit alive — pruning it makes the commit unreachable and
# eventually GC-collectible.
#
# The guard is a PIN, not a scan (challenge r4): a scan-then-prune design
# leaves a window in which the sole containing ref can vanish (a concurrent
# `fetch --prune` removing a remote-tracking ref) or a record can become
# prune-eligible after the scan. Instead, every registered record whose HEAD
# is detached gets a shared rescue ref — refs/session-cleanup/pin/<record> —
# BEFORE the prune runs. Ref creation is atomic, and a shared ref survives
# record removal, so no interleaving can strand the commit. After the prune,
# pins proven redundant (the record survived, or another shared ref contains
# the commit) are dropped; a pin that is now the commit's only reference is
# KEPT and reported with the rescue command, and the exit code is nonzero so
# wrappers notice — but nothing was lost either way.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

die() {
    echo "clean:worktree-records: $*" >&2
    exit 1
}

# Refs that would STILL reference a commit once the record is gone — the same
# exclusion set as worktree-rm.sh (per-worktree refs vanish with their
# worktree), plus this script's own pin namespace: a pin must never vouch for
# the commit it exists to protect.
shared_refs_containing() {
    git for-each-ref --contains "$1" --format='%(refname)' 2>/dev/null |
        grep -Ev '^refs/((worktree|bisect|rewritten)/|session-cleanup/pin/)' || true
}

common="$(git rev-parse --path-format=absolute --git-common-dir)"

# ── Pin every detached record HEAD before anything is removed ──────────────

pinned=""
if [ -d "$common/worktrees" ]; then
    for admin_dir in "$common"/worktrees/*; do
        [ -d "$admin_dir" ] || continue
        record="$(basename "$admin_dir")"
        record_head="$(cat "$admin_dir/HEAD" 2>/dev/null || true)"
        case "$record_head" in
        ref:* | '') continue ;; # attached to a branch: the branch keeps the commits
        esac
        git rev-parse --quiet --verify "$record_head^{commit}" >/dev/null 2>&1 || continue
        # A pin failure means the commit cannot be protected — refuse the
        # whole prune rather than proceed unguarded.
        LEFTHOOK=0 git update-ref "refs/session-cleanup/pin/$record" "$record_head" ||
            die "cannot pin detached commit $record_head of record '$record' — refusing to prune unprotected"
        pinned="$pinned $record"
    done
fi

# ── Prune (records only; git never touches worktree directories here) ──────

prune_plan="$(LC_ALL=C git worktree prune --dry-run -v 2>&1)"
if [ -z "$prune_plan" ] && [ -z "$pinned" ]; then
    echo "clean:worktree-records: nothing to prune."
    exit 0
fi
LC_ALL=C LEFTHOOK=0 git worktree prune -v

# ── Settle the pins ────────────────────────────────────────────────────────

kept=0
for record in $pinned; do
    pin_ref="refs/session-cleanup/pin/$record"
    pin_sha="$(git rev-parse --quiet --verify "$pin_ref" || true)"
    [ -n "$pin_sha" ] || continue
    if [ -d "$common/worktrees/$record" ]; then
        # The record survived the prune (live worktree): it keeps its own
        # HEAD reachable, exactly as before this script ran.
        LEFTHOOK=0 git update-ref -d "$pin_ref" "$pin_sha" 2>/dev/null || true
    elif [ -n "$(shared_refs_containing "$pin_sha")" ]; then
        LEFTHOOK=0 git update-ref -d "$pin_ref" "$pin_sha" 2>/dev/null || true
    else
        echo "KEPT  $pin_ref — pruned record '$record' held the only reference to detached commit $pin_sha; branch it (git branch rescue/$record $pin_sha) or discard it (git update-ref -d $pin_ref)"
        kept=$((kept + 1))
    fi
done

if [ "$kept" -gt 0 ]; then
    echo "clean:worktree-records: stale records pruned; $kept rescue pin(s) kept above — settle them before the next gc." >&2
    exit 2
fi
echo "clean:worktree-records: stale records pruned (worktree directories are never touched)."
