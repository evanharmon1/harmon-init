#!/usr/bin/env bash
# clean-branches.sh — delete local branches, but only on positive evidence the
# work is safe to drop. Run via `task clean:branches` (dry run) or
# `task clean:branches -- --delete` (act).
#
# The rule this script encodes (harmon-init#838): every deletion requires
# positive evidence — either the branch is an ANCESTOR of the remote default
# branch (so `git branch -d` succeeds on its own), or a MERGED PR whose head
# commit is exactly this branch's tip proves the same work landed by squash or
# rebase. "The upstream is gone" is an inference, not evidence: this repo
# squash-merges, so a delivered branch is not an ancestor of main and is
# indistinguishable, by ancestry alone, from genuinely unmerged work.
#
# What it never does:
#   * force-delete (the capital-D flag) — that discards the evidence rule by
#     design, and issue #838's verify greps this file to prove its absence.
#   * remove a worktree, or touch any remote branch.
#   * delete the current branch, the default branch, or a branch checked out
#     in any worktree (git refuses for `branch -d`; the update-ref path below
#     bypasses that guard, so the worktree check here is load-bearing).
#   * delete unpushed work. Ancestry evidence means every commit is on the
#     remote default branch; PR evidence means the merged PR's head commit IS
#     this tip, so every local commit was pushed into the PR that merged. A
#     tip that sits even one commit past the merged head matches neither and
#     is refused.
#
# Squash-merged branches are deleted with a guarded compare-and-delete
# (`git update-ref -d <ref> <verified-tip>`) rather than `git branch -d`,
# because `-d` structurally refuses a non-ancestor no matter how much evidence
# exists — the very branches the PR API check makes safe to clear. The old
# value guard makes the delete atomic: if anything moves the branch between
# verification and deletion, git refuses. Same pattern as worktree-new.sh's
# rollback. Every deletion prints the tip SHA so `git branch <name> <sha>`
# can restore it until git prunes the objects.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
    cat >&2 <<'EOF'
Usage: task clean:branches [-- --delete]

Dry run by default: reports what would be deleted and why, mutating nothing.
--delete performs the deletions. Only branches with positive merge evidence
(ancestry into the remote default branch, or a merged PR whose head commit
equals the local tip) are ever deleted, always without force.
EOF
}

die() {
    echo "clean:branches: $*" >&2
    exit 1
}

do_delete=false
for arg in "$@"; do
    case "$arg" in
    --delete) do_delete=true ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        die "unknown argument: $arg"
        ;;
    esac
done

# ── Ground truth ────────────────────────────────────────────────────────────

remotes="$(git remote)"
if [ -z "$remotes" ]; then
    echo "clean:branches: no remote configured — no merge evidence is possible; nothing to do."
    exit 0
fi
if printf '%s\n' "$remotes" | grep -qx origin; then
    remote=origin
elif [ "$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')" = "1" ]; then
    remote="$remotes"
else
    die "multiple remotes and none named origin — cannot pick a merge-evidence source"
fi

# Default branch of the remote: the ancestry target, and protected from
# deletion. Falls back to a main/master probe when the remote HEAD symref was
# never recorded locally (`git remote set-head $remote --auto` records it).
default_branch=""
if default_ref="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD")"; then
    default_branch="${default_ref#"refs/remotes/$remote/"}"
else
    for cand in main master; do
        if git show-ref --verify --quiet "refs/remotes/$remote/$cand"; then
            default_branch="$cand"
            break
        fi
    done
fi
[ -n "$default_branch" ] ||
    die "cannot resolve $remote's default branch (try: git remote set-head $remote --auto)"
ancestry_target="refs/remotes/$remote/$default_branch"

current_branch="$(git branch --show-current || true)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/clean-branches.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Branches checked out anywhere: name<TAB>worktree-path. `git branch -d`
# refuses these on its own; the update-ref path would not, so this check
# guards it explicitly (do not work around a refusal either way).
git worktree list --porcelain | awk '
    /^worktree /            { path = substr($0, 10) }
    /^branch refs\/heads\// { printf "%s\t%s\n", substr($0, 19), path }
' >"$tmp/checked-out"

# Bounded network probes, resolved once (status.sh precedent: a hung gh call
# must not wedge the run; stock macOS gets `timeout` from coreutils).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
fi

gh_pr_probe() {
    # gh_pr_probe <args...> — bounded, stdin-closed gh invocation.
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 5 "${GH_TIMEOUT:-30}" gh "$@" </dev/null
    else
        gh "$@" </dev/null
    fi
}

# PR-evidence availability: gh present and able to name the remote's repo.
# Resolved from the remote URL rather than gh's default-repo state, because a
# multi-remote checkout can default to a different repository.
gh_repo=""
if command -v gh >/dev/null 2>&1; then
    gh_repo="$(gh_pr_probe repo view "$(git remote get-url "$remote")" \
        --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || gh_repo=""
fi

# merged_pr_for <branch> <tip> — echo the merged PR number whose head commit
# is exactly <tip>; echo nothing when no merged PR matches; return nonzero
# when the probe itself failed (so a network error is never mistaken for "no
# PR"). Tip equality is the point: matching by branch NAME alone would let a
# recycled branch name inherit an old PR's merged-ness and delete unrelated
# new work.
merged_pr_for() {
    gh_pr_probe pr list --repo "$gh_repo" --head "$1" --state merged \
        --json number,headRefOid \
        --jq '.[] | [(.number | tostring), .headRefOid] | @tsv' \
        >"$tmp/pr-probe" 2>/dev/null || return 1
    awk -F'\t' -v tip="$2" '$2 == tip { print $1; exit }' "$tmp/pr-probe"
}

# ── Classify every branch ───────────────────────────────────────────────────

git for-each-ref refs/heads \
    --format='%(refname:short)%09%(objectname)%09%(upstream:track)' \
    >"$tmp/branches"

total=0
candidates=0
refused=0
active=0

while IFS=$'\t' read -r branch tip track; do
    total=$((total + 1))

    [ "$branch" = "$current_branch" ] && continue
    [ "$branch" = "$default_branch" ] && continue

    if wt_path="$(awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' "$tmp/checked-out")" &&
        [ -n "$wt_path" ]; then
        echo "SKIP  $branch — checked out in worktree $wt_path (never deleted from here)"
        refused=$((refused + 1))
        continue
    fi

    # Evidence class 1 — ancestry: every commit is reachable from the remote
    # default branch, so nothing local can be lost. `git branch -d` performs
    # the delete and stays the final authority.
    if git merge-base --is-ancestor "refs/heads/$branch" "$ancestry_target"; then
        printf '%s\t%s\tancestry\t\n' "$branch" "$tip" >>"$tmp/candidates"
        candidates=$((candidates + 1))
        continue
    fi

    # Evidence class 2 — a merged PR whose HEAD COMMIT equals this tip. Squash
    # merge rewrites history, so after the remote branch is deleted these
    # commits sit on no remote-tracking ref and no rev-list check can clear
    # them; tip equality is what proves every local commit was in the merged
    # PR (pushed, reviewed, delivered). Anything short of that equality —
    # including one extra local commit on top of the merged head — falls
    # through to the refusals below.
    if [ "$track" = "[gone]" ] && [ -n "$gh_repo" ]; then
        if ! pr="$(merged_pr_for "$branch" "$tip")"; then
            echo "SKIP  $branch — upstream gone, but the merged-PR probe failed (gh/network error)"
            refused=$((refused + 1))
            continue
        fi
        if [ -n "$pr" ]; then
            printf '%s\t%s\tpr\t%s\n' "$branch" "$tip" "$pr" >>"$tmp/candidates"
            candidates=$((candidates + 1))
            continue
        fi
    fi

    # No evidence. A gone upstream still gets a loud line (it is the
    # population this tool exists to triage); everything else is ordinary
    # in-flight work and stays quiet.
    if [ "$track" = "[gone]" ]; then
        unpushed="$(git rev-list --count "refs/heads/$branch" --not --remotes --)"
        if [ -z "$gh_repo" ]; then
            echo "SKIP  $branch — upstream gone, but gh is unavailable so no merged PR can vouch for it"
        elif [ "$unpushed" -gt 0 ]; then
            echo "SKIP  $branch — upstream gone, $unpushed commit(s) on no remote and no merged PR matches tip ${tip:0:12} (unpushed work is never deleted)"
        else
            echo "SKIP  $branch — upstream gone and no merged PR matches tip ${tip:0:12} (a human decides)"
        fi
        refused=$((refused + 1))
        continue
    fi
    active=$((active + 1))
done <"$tmp/branches"

# ── Act (or report) ─────────────────────────────────────────────────────────

deleted=0
if [ -s "$tmp/candidates" ]; then
    while IFS=$'\t' read -r branch tip evidence pr; do
        case "$evidence" in
        ancestry) why="merged by ancestry into $remote/$default_branch" ;;
        pr) why="merged PR #$pr (head == tip)" ;;
        esac
        if [ "$do_delete" != true ]; then
            echo "WOULD DELETE  $branch (${tip:0:12}) — $why"
            continue
        fi
        # Re-check checkout state at the moment of deletion: another session
        # can have claimed the branch since classification, and update-ref
        # does not respect git's checked-out guard.
        if git worktree list --porcelain | grep -Fxq "branch refs/heads/$branch"; then
            echo "SKIP  $branch — became checked out in a worktree since classification"
            refused=$((refused + 1))
            continue
        fi
        # LEFTHOOK=0 on both delete forms: a reference-transaction hook must
        # not fire on cleanup ref writes (worktree-new.sh precedent).
        if [ "$evidence" = ancestry ]; then
            if LEFTHOOK=0 git branch -d "$branch" >/dev/null; then
                echo "deleted  $branch (was ${tip}) — $why — recover: git branch $branch ${tip:0:12}"
                deleted=$((deleted + 1))
            else
                echo "SKIP  $branch — git branch -d refused (its refusal is final; never forced)"
                refused=$((refused + 1))
            fi
        else
            # Compare-and-delete: refuses if the tip moved since verification.
            if LEFTHOOK=0 git update-ref -d "refs/heads/$branch" "$tip" 2>/dev/null; then
                git config --local --remove-section "branch.$branch" 2>/dev/null || true
                echo "deleted  $branch (was ${tip}) — $why — recover: git branch $branch ${tip:0:12}"
                deleted=$((deleted + 1))
            else
                echo "SKIP  $branch — tip moved since verification (compare-and-delete refused)"
                refused=$((refused + 1))
            fi
        fi
    done <"$tmp/candidates"
fi

echo
if [ "$do_delete" = true ]; then
    echo "clean:branches: $deleted deleted, $refused skipped, $active in-flight kept, $total local branches scanned."
else
    echo "clean:branches (dry run): $candidates deletable, $refused skipped, $active in-flight kept, $total local branches scanned."
    if [ "$candidates" -gt 0 ]; then
        echo "Run 'task clean:branches -- --delete' to delete the branches listed above."
    fi
fi
