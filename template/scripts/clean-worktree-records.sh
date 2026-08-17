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
# The design decisions, each deliberate (challenge r4-r7):
#
#   * Only records in git's own dry-run plan are removed, each one
#     individually, never via the global `git worktree prune` — a global
#     prune re-computes eligibility at its own moment, so a LIVE worktree
#     whose directory vanishes mid-run could be pruned on a stale HEAD
#     snapshot. A plan-verified stale record has no working directory, so
#     its HEAD cannot move. Live records are never touched.
#   * Each removal runs under the same per-path lifecycle lock that
#     worktree:new / worktree:rm hold (for trees under the blessed
#     .worktrees layout), so a removal cannot race a re-creation of the
#     same path by the blessed tooling. Raw `git worktree add` outside the
#     tooling remains the documented residual.
#   * A record that carries worktree-local state is refused, never swept:
#     review sidecars, per-worktree ref files, and an index that diverges
#     from the recorded HEAD (staged-but-uncommitted blobs the index alone
#     keeps alive). Reflogs are deliberately NOT state — every record has
#     one, and accepting reflog loss matches git's own prune semantics.
#   * A detached record HEAD is pinned as refs/session-cleanup/pin/<record>
#     BEFORE its record is removed, with a CREATE-ONLY ref write; an
#     existing mismatched pin from an earlier run refuses that record. Pins
#     are removed only by EXPLICIT human settlement — an auto-drop races
#     concurrent ref deletion — and the run exits nonzero while any await
#     action. Nothing is ever lost.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

die() {
    echo "clean:worktree-records: $*" >&2
    exit 1
}

# POSIX shell-quote for values echoed into copyable commands: refnames and
# record names legally carry shell metacharacters (challenge r7; same class
# as worktree-new.sh's printed remedies).
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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

# remove_one_record <record> — runs in a SUBSHELL so a lock refusal (die)
# aborts this record only. Every validation runs UNDER the lock (challenge
# r7): checked outside it, worktree:rm clearing the record and worktree:new
# recreating the same path could interleave before the rm -rf and lose a
# live record. Exit codes: 0 removed, 2 removed with a pin awaiting
# settlement, 3 refused cleanly (message printed), else lock/fatal.
remove_one_record() (
    record="$1"
    admin_dir="$common/worktrees/$record"
    # shellcheck source=scripts/worktree-lock.sh
    . "$REPO_ROOT/scripts/worktree-lock.sh"
    trap release_locks EXIT
    trap 'exit 129' HUP INT TERM
    wt_gitfile="$(cat "$admin_dir/gitdir" 2>/dev/null || true)"
    main_root="${common%/.git}"
    tree_path="${wt_gitfile%/.git}"
    case "$tree_path" in
    "$main_root/.worktrees/"*)
        acquire_path_locks "${tree_path#"$main_root/.worktrees/"}"
        ;;
    esac

    [ -d "$admin_dir" ] || exit 3 # already gone (another cleaner won)
    # Re-read under the lock: if the record's gitdir target exists again (a
    # worktree recreated at the old path), the record is live — leave it.
    wt_gitfile="$(cat "$admin_dir/gitdir" 2>/dev/null || true)"
    if [ -n "$wt_gitfile" ] && [ -e "$wt_gitfile" ]; then
        echo "SKIP  record '$record' — its worktree reappeared since the plan"
        exit 3
    fi

    # Single-copy worktree-local state is refused, never swept.
    carried=""
    for sub in deferred-findings adjudication-ledger shepherd-codex refs; do
        if [ -e "$admin_dir/$sub" ] &&
            [ -n "$(find "$admin_dir/$sub" -type f 2>/dev/null | head -n 1)" ]; then
            carried="$carried $sub"
        fi
    done
    if [ -n "$carried" ]; then
        echo "SKIP  record '$record' — carries worktree-local state (${carried# }); adopt or rescue it first, it exists nowhere else"
        exit 3
    fi

    record_head="$(cat "$admin_dir/HEAD" 2>/dev/null || true)"

    # The index can be the only structure referencing staged-but-uncommitted
    # blobs (challenge r7): an index that diverges from the recorded HEAD —
    # or that cannot be verified against it — is state, and refused.
    if [ -f "$admin_dir/index" ]; then
        head_commit=""
        case "$record_head" in
        ref:*) head_commit="$(git rev-parse --quiet --verify "${record_head#ref: }^{commit}" || true)" ;;
        '') : ;;
        *) head_commit="$(git rev-parse --quiet --verify "$record_head^{commit}" || true)" ;;
        esac
        if [ -z "$head_commit" ] ||
            ! GIT_INDEX_FILE="$admin_dir/index" git diff-index --cached --quiet "$head_commit" 2>/dev/null; then
            echo "SKIP  record '$record' — its index diverges from the recorded HEAD (staged-only changes, or unverifiable); recover them first (GIT_INDEX_FILE=$admin_dir/index git checkout-index ...), then remove the index file"
            exit 3
        fi
    fi

    pinned_here=false
    case "$record_head" in
    ref:* | '') : ;; # attached to a branch: the branch keeps the commits
    *)
        if git rev-parse --quiet --verify "$record_head^{commit}" >/dev/null 2>&1; then
            existing_pin="$(git rev-parse --quiet --verify "refs/session-cleanup/pin/$record" || true)"
            if [ -n "$existing_pin" ] && [ "$existing_pin" != "$record_head" ]; then
                echo "SKIP  record '$record' — refs/session-cleanup/pin/$record already pins $existing_pin from an earlier run; settle it first (git branch $(shell_quote "rescue/$record") $existing_pin, or git update-ref -d $(shell_quote "refs/session-cleanup/pin/$record"))"
                exit 3
            fi
            # Create-only (old value ''): never overwrite a pin this run did
            # not just verify.
            if ! LEFTHOOK=0 git update-ref "refs/session-cleanup/pin/$record" "$record_head" "${existing_pin:-}"; then
                echo "SKIP  record '$record' — cannot pin detached commit $record_head; refusing to remove it unprotected"
                exit 3
            fi
            pinned_here=true
        fi
        ;;
    esac

    # Records only: the stale admin directory is all that goes.
    rm -rf "$admin_dir"
    echo "pruned record '$record'"

    if [ "$pinned_here" = true ]; then
        # Reporting only — pins are settled by humans, never auto-dropped
        # (challenge r6): the reachability check picks the wording, and a
        # race can at worst mislabel, never delete.
        pin_ref="refs/session-cleanup/pin/$record"
        if [ -n "$(shared_refs_containing "$record_head")" ]; then
            echo "PINNED  $pin_ref — $record_head is also reachable from shared refs; drop it with: git update-ref -d $(shell_quote "$pin_ref")"
        else
            echo "KEPT  $pin_ref — pruned record '$record' held the only reference to detached commit $record_head; branch it (git branch $(shell_quote "rescue/$record") $record_head) or discard it (git update-ref -d $(shell_quote "$pin_ref"))"
        fi
        exit 2
    fi
)

removed=0
skipped=0
pins_pending=0
while IFS= read -r line; do
    record="$(printf '%s\n' "$line" | sed -n 's/^Removing worktrees\/\(.*\): .*$/\1/p')"
    [ -n "$record" ] || continue
    rc=0
    remove_one_record "$record" || rc=$?
    case "$rc" in
    0) removed=$((removed + 1)) ;;
    2)
        removed=$((removed + 1))
        pins_pending=$((pins_pending + 1))
        ;;
    3) skipped=$((skipped + 1)) ;;
    *)
        echo "SKIP  record '$record' — the worktree lifecycle lock refused (a worktree operation is active; details above)"
        skipped=$((skipped + 1))
        ;;
    esac
done <<EOF
$prune_plan
EOF

if [ "$removed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "clean:worktree-records: nothing to prune."
    exit 0
fi
if [ "$pins_pending" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    echo "clean:worktree-records: $removed record(s) pruned; $pins_pending pin(s) awaiting settlement, $skipped record(s) refused above." >&2
    exit 2
fi
echo "clean:worktree-records: stale records pruned (worktree directories are never touched)."
