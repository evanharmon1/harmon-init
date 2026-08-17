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
# Two design decisions close that, and both are deliberate (challenge r4+r5):
#
#   * Only records in git's own dry-run plan are removed, each one
#     individually, never via the global `git worktree prune` — a global
#     prune re-computes eligibility at its own moment, so a LIVE worktree
#     whose directory vanishes mid-run could be pruned on a HEAD snapshot
#     taken while it was still advancing. A plan-verified stale record has
#     no working directory, so its HEAD cannot move; removing exactly that
#     set makes the snapshot race structurally impossible. Live records are
#     never touched, and a record that goes stale mid-run simply waits for
#     the next run.
#   * A detached record HEAD is pinned as refs/session-cleanup/pin/<record>
#     BEFORE its record is removed, with a CREATE-ONLY ref write: an
#     existing pin under the same name from an earlier run may be the sole
#     reference to an older commit, so it is never overwritten — a mismatch
#     refuses the whole run until that pin is settled. Pins are removed only
#     by EXPLICIT human settlement, never automatically (challenge r6): a
#     reachability-checked auto-drop races any concurrent ref deletion. The
#     run reports each pin with its settle command and exits nonzero while
#     any await settlement — nothing is ever lost.
#
# A record that carries worktree-local state — review sidecars, per-worktree
# ref files — is refused outright: that state exists nowhere else, and no
# pin can stand in for it.
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

# git's own dry run is the authority on what is prunable
# ("Removing worktrees/<name>: <reason>"); LC_ALL=C pins the message shape.
prune_plan="$(LC_ALL=C git worktree prune --dry-run -v 2>&1)"
if [ -z "$prune_plan" ]; then
    echo "clean:worktree-records: nothing to prune."
    exit 0
fi

pinned=""
removed=0
skipped=0
while IFS= read -r line; do
    record="$(printf '%s\n' "$line" | sed -n 's/^Removing worktrees\/\(.*\): .*$/\1/p')"
    [ -n "$record" ] || continue
    admin_dir="$common/worktrees/$record"
    [ -d "$admin_dir" ] || continue
    # Belt, not testable deterministically: if the record's gitdir target
    # exists again (a worktree resurrected at the old path since the plan),
    # the record is live — leave it alone rather than orphan a live tree.
    wt_gitfile="$(cat "$admin_dir/gitdir" 2>/dev/null || true)"
    if [ -n "$wt_gitfile" ] && [ -e "$wt_gitfile" ]; then
        echo "SKIP  record '$record' — its worktree reappeared since the plan"
        continue
    fi
    # A record can carry worktree-local state that exists NOWHERE else
    # (challenge r6): review sidecars a linked-worktree session wrote under
    # its admin dir — the same single-copy state audit:session-artifacts
    # reports — and per-worktree ref files whose targets may be reachable
    # only from here. Such a record is refused, never swept; a human adopts
    # the sidecars (gauntlet orphan-sweep) or rescues the refs first.
    # Reflogs (logs/) are deliberately NOT state: every record has one, and
    # accepting reflog loss matches git's own prune semantics — the HEAD
    # pin below covers the final position.
    carried=""
    for sub in deferred-findings adjudication-ledger shepherd-codex refs; do
        if [ -e "$admin_dir/$sub" ] &&
            [ -n "$(find "$admin_dir/$sub" -type f 2>/dev/null | head -n 1)" ]; then
            carried="$carried $sub"
        fi
    done
    if [ -n "$carried" ]; then
        echo "SKIP  record '$record' — carries worktree-local state (${carried# }); adopt or rescue it first, it exists nowhere else"
        skipped=$((skipped + 1))
        continue
    fi
    record_head="$(cat "$admin_dir/HEAD" 2>/dev/null || true)"
    case "$record_head" in
    ref:* | '') : ;; # attached to a branch: the branch keeps the commits
    *)
        if git rev-parse --quiet --verify "$record_head^{commit}" >/dev/null 2>&1; then
            existing_pin="$(git rev-parse --quiet --verify "refs/session-cleanup/pin/$record" || true)"
            if [ -n "$existing_pin" ] && [ "$existing_pin" != "$record_head" ]; then
                die "refs/session-cleanup/pin/$record already pins $existing_pin from an earlier run — settle it first (git branch rescue/$record $existing_pin, or git update-ref -d refs/session-cleanup/pin/$record), then re-run"
            fi
            # Create-only (old value ''): never overwrite a pin this run did
            # not just verify; a concurrent writer refuses the run.
            LEFTHOOK=0 git update-ref "refs/session-cleanup/pin/$record" "$record_head" "${existing_pin:-}" ||
                die "cannot pin detached commit $record_head of record '$record' — refusing to remove it unprotected"
            pinned="$pinned $record"
        fi
        ;;
    esac
    # Records only: the stale admin directory is all that goes.
    rm -rf "$admin_dir"
    echo "pruned record '$record'"
    removed=$((removed + 1))
done <<EOF
$prune_plan
EOF

if [ "$removed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "clean:worktree-records: nothing to prune."
    exit 0
fi

# ── Report the pins ────────────────────────────────────────────────────────

# Pins are removed ONLY by explicit human settlement (challenge r6): an
# automatic drop after a reachability check races any concurrent ref
# deletion — the last vouching ref can vanish between the check and the
# drop, and the drop then discards the sole remaining reference. The check
# below chooses the WORDING; it never deletes anything.
pins_pending=0
for record in $pinned; do
    pin_ref="refs/session-cleanup/pin/$record"
    pin_sha="$(git rev-parse --quiet --verify "$pin_ref" || true)"
    [ -n "$pin_sha" ] || continue
    if [ -n "$(shared_refs_containing "$pin_sha")" ]; then
        echo "PINNED  $pin_ref — $pin_sha is also reachable from shared refs; drop it with: git update-ref -d $pin_ref"
    else
        echo "KEPT  $pin_ref — pruned record '$record' held the only reference to detached commit $pin_sha; branch it (git branch rescue/$record $pin_sha) or discard it (git update-ref -d $pin_ref)"
    fi
    pins_pending=$((pins_pending + 1))
done

if [ "$pins_pending" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    echo "clean:worktree-records: $removed record(s) pruned; $pins_pending pin(s) awaiting settlement, $skipped record(s) refused above." >&2
    exit 2
fi
echo "clean:worktree-records: stale records pruned (worktree directories are never touched)."
