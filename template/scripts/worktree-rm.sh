#!/usr/bin/env bash
# worktree-rm.sh — remove a linked worktree created by worktree-new.sh and clear
# the gitlink debris a bare `git worktree remove` can leave behind.
#
# Run via `task worktree:rm -- <name> [--force]`.
#
# Refuses a dirty tree by default: uncommitted work in a worktree is invisible
# from the main checkout, so removing one silently is a data-loss path.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: task worktree:rm -- <name> [--force]

Removes .worktrees/<name>, prunes the worktree registry, and clears any leftover
gitlink directory. --force discards uncommitted changes in the tree.
EOF
}

die() {
    echo "worktree:rm: $*" >&2
    exit 1
}

name=""
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
    --force | -f)
        force=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        die "unknown option: $1"
        ;;
    *)
        [ -z "$name" ] || die "unexpected extra argument: $1"
        name="$1"
        shift
        ;;
    esac
done

[ -n "$name" ] || {
    usage
    die "a worktree name is required"
}

case "$name" in
/* | -*) die "invalid name '$name': must not start with '/' or '-'" ;;
*..*) die "invalid name '$name': must not contain '..'" ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "$main_root" ] && [ -d "$main_root" ] || die "could not resolve the main worktree root"

tree="$main_root/.worktrees/$name"

# Liveness comes from the worktree REGISTRY, not from running git inside the
# directory: `git -C <dir> rev-parse` walks upward and happily finds the
# enclosing main repository, so an abandoned empty reservation from an
# interrupted create would read as a live worktree and `git worktree remove`
# would fail with "not a working tree" — leaving the path unrecoverable through
# the very command worktree:new tells you to run.
registered="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')"
tree_is_registered=0
case "
$registered
" in *"
$tree
"*) tree_is_registered=1 ;; esac

if [ ! -d "$tree" ]; then
    echo "==> $tree does not exist; pruning the registry anyway"
elif [ "$tree_is_registered" -eq 0 ]; then
    # The directory is not a registered worktree: either it outlived its record
    # (a stale gitlink) or it is an empty reservation an interrupted create left
    # behind. `git worktree remove` would only report "is not a working tree";
    # prune plus the debris sweep below is the actual fix for both.
    echo "==> $tree is not a live worktree (stale gitlink or abandoned reservation) — cleaning it up"
else
    if [ "$force" -eq 0 ] && [ -n "$(git -C "$tree" status --porcelain)" ]; then
        die "$tree has uncommitted changes — commit or push them, or re-run with --force to discard them"
    fi
    # An in-progress rebase/merge/cherry-pick leaves a CLEAN status once it
    # stops at an edit, so the check above waves it through — while the
    # per-worktree git dir still holds the sequencer state and, after a `commit
    # --amend` at that stop, a commit reachable from nothing else. Removing the
    # tree drops that state, and gc eventually collects the commit. Likewise a
    # detached HEAD ahead of every branch: nothing else references it.
    if [ "$force" -eq 0 ]; then
        tree_git_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-dir)"
        for op_state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
            if [ -e "$tree_git_dir/$op_state" ]; then
                die "$tree has an in-progress git operation ($op_state) — finish or abort it, or re-run with --force to discard it"
            fi
        done
        # `for-each-ref`, not `branch --contains`: the latter lists the current
        # detached HEAD itself as a `(HEAD detached at ...)` pseudo-entry, so it
        # is never empty here and the guard would never fire.
        #
        # ALL refs, not just refs/heads. A tag or a remote-tracking ref keeps the
        # commit just as reachable as a branch does, and narrowing the query
        # would refuse a perfectly safe removal — pushing people toward --force
        # for a tree that was never at risk, which is how a guard stops being
        # believed.
        if ! git -C "$tree" symbolic-ref -q HEAD >/dev/null &&
            [ -z "$(git -C "$tree" for-each-ref --contains HEAD --format='%(refname)' 2>/dev/null)" ]; then
            die "$tree is on a detached HEAD no branch contains — the commits there would become unreachable; branch or note them, or re-run with --force"
        fi
    fi
    # `git worktree remove` counts modified and untracked files, but NOT ignored
    # ones — so without this a plain remove silently deletes a `.env`, an
    # `.envrc.local`, or ignored notes, which is not what "--force to discard
    # uncommitted work" promises.
    #
    # The exemption is an ALLOWLIST of directories a tool can rebuild, not "any
    # ignored directory": a repo that gitignores `local-data/` or `fixtures/`
    # keeps its only copy there, and waving those through would be the same
    # data-loss path one level up. Everything not on the list — files and
    # directories alike — needs --force. The list is deliberately dull:
    # package-manager and build output, which `worktree:new`, `task install`, or
    # `task build` regenerate.
    #
    # Matching is per FILE, on whether any path component is a reinstallable
    # directory — `(^|/)name/` — rather than on collapsed directory entries.
    # `git ls-files --directory` collapses at the highest wholly-untracked
    # directory, so a monorepo's `packages/api/node_modules/...` arrives as
    # plain `packages/`, which no allowlist of cache names can recognise. Per
    # component it also handles depth for free: a `__pycache__` beside every
    # module, node_modules under every package.
    if [ "$force" -eq 0 ]; then
        reinstallable='(^|/)(node_modules|\.venv|venv|\.task|\.turbo|\.next|\.astro|\.nuxt|\.svelte-kit|\.parcel-cache|\.pytest_cache|\.mypy_cache|\.ruff_cache|__pycache__|dist|build|target|coverage|playwright-report|test-results|\.terraform)/'
        ignored_state="$(
            git -C "$tree" ls-files --others --ignored --exclude-standard |
                grep -Ev "$reinstallable" | head -n 20 || true
        )"
        if [ -n "$ignored_state" ]; then
            echo "worktree:rm: $tree holds ignored local state that removal would delete:" >&2
            printf '%s\n' "$ignored_state" | sed 's/^/  /' >&2
            die "move or copy it out, or re-run with --force to discard it"
        fi
    fi
    # Step out of the tree before deleting it. Finishing work inside the
    # worktree and removing it from there is the natural gesture, and it would
    # otherwise delete this process's own cwd — after which `git worktree prune`
    # below dies with "Unable to read current working directory" and the task
    # reports failure having already removed the tree.
    cd "$main_root" || die "could not change to $main_root"
    if [ "$force" -eq 1 ]; then
        git worktree remove --force "$tree"
    else
        git worktree remove "$tree"
    fi
fi

# Drop registry records whose working tree is gone. This is the #716 class: a
# stale record (or a leftover directory holding only a .git gitlink file) makes
# later tooling treat a dead path as a live checkout.
git worktree prune

# `git worktree prune` deliberately keeps LOCKED records, so it can succeed
# while leaving this path registered — after which the branch still reads as
# checked out and the next `worktree:new` for it fails. Reporting "removed"
# there would be a lie, so re-query and name the lock instead.
if git worktree list --porcelain | grep -qxF "worktree $tree"; then
    die "$tree is still registered after pruning — its record is locked; run 'git worktree unlock \"$tree\"' and re-run, or 'git worktree remove --force \"$tree\"'"
fi

# `git worktree remove` leaves the directory in place when it failed or when the
# registry record was already gone. Clear it only when nothing but git's own
# gitlink remains, and only under .worktrees/ — never guess at a wider path.
#
# A `.git` DIRECTORY is not that: a linked worktree's gitlink is a FILE, so a
# directory there means a standalone repository or an interrupted clone lives at
# this path, and its `.git` holds the only copy of that repository's objects.
# Auto-cleaning the file shape is safe; the directory shape gets the same
# refusal as any other unexpected content.
if [ -d "$tree" ]; then
    leftovers="$(find "$tree" -mindepth 1 -maxdepth 1 ! -name .git | head -n 1)"
    if [ -z "$leftovers" ] && [ ! -d "$tree/.git" ]; then
        rm -rf "$tree"
        echo "==> Removed leftover gitlink directory $tree"
    elif [ -d "$tree/.git" ]; then
        die "$tree holds a .git DIRECTORY, so it is a repository of its own rather than worktree debris — inspect it and delete it by hand"
    else
        die "$tree still holds files after removal — inspect it and delete it by hand"
    fi
fi

# Empty leftovers are noise. A slash-delimited name like `feat/foo` leaves an
# empty `.worktrees/feat` behind, so walk up from the removed tree, stopping at
# .worktrees/ itself (which is also removed when it was the last tree). rmdir
# only ever removes an EMPTY directory, so this cannot take a live tree with it.
parent="$(dirname "$tree")"
while [ "$parent" != "$main_root" ] && [ "$parent" != "/" ]; do
    rmdir "$parent" 2>/dev/null || break
    parent="$(dirname "$parent")"
done

echo "Worktree removed: $tree"
