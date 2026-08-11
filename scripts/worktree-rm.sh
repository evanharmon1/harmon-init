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

if [ ! -d "$tree" ]; then
    echo "==> $tree does not exist; pruning the registry anyway"
elif ! git -C "$tree" rev-parse --git-dir >/dev/null 2>&1; then
    # The directory outlived its registry record — a stale gitlink, not a live
    # worktree. `git worktree remove` would only report "is not a working tree";
    # prune plus the debris sweep below is the actual fix.
    echo "==> $tree is not a live worktree (stale gitlink) — cleaning it up"
else
    if [ "$force" -eq 0 ] && [ -n "$(git -C "$tree" status --porcelain)" ]; then
        die "$tree has uncommitted changes — commit or push them, or re-run with --force to discard them"
    fi
    # `git worktree remove` counts modified and untracked files, but NOT ignored
    # ones — so without this a plain remove silently deletes a `.env`, an
    # `.envrc.local`, or ignored notes, which is not what "--force to discard
    # uncommitted work" promises.
    #
    # Ignored DIRECTORIES are let through deliberately: node_modules/, .venv/,
    # dist/ are what worktree:new installs and can reinstall, and refusing on
    # them would mean every removal needed --force, which trains people to pass
    # it and defeats the guard. An ignored FILE is hand-made state instead, so
    # that is what the refusal is keyed on. `--directory` collapses an ignored
    # directory to one entry with a trailing slash, which is what distinguishes
    # the two.
    if [ "$force" -eq 0 ]; then
        ignored_files="$(
            git -C "$tree" ls-files --others --ignored --exclude-standard \
                --directory --no-empty-directory | grep -v '/$' || true
        )"
        if [ -n "$ignored_files" ]; then
            echo "worktree:rm: $tree holds ignored local files that removal would delete:" >&2
            printf '%s\n' "$ignored_files" | sed 's/^/  /' >&2
            die "move or copy them out, or re-run with --force to discard them"
        fi
    fi
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

# `git worktree remove` leaves the directory in place when it failed or when the
# registry record was already gone. Clear it only when nothing but git's own
# gitlink remains, and only under .worktrees/ — never guess at a wider path.
if [ -d "$tree" ]; then
    leftovers="$(find "$tree" -mindepth 1 -maxdepth 1 ! -name .git | head -n 1)"
    if [ -z "$leftovers" ]; then
        rm -rf "$tree"
        echo "==> Removed leftover gitlink directory $tree"
    else
        die "$tree still holds files after removal — inspect it and delete it by hand"
    fi
fi

# An empty .worktrees/ is noise; remove it when this was the last tree.
rmdir "$main_root/.worktrees" 2>/dev/null || true

echo "Worktree removed: $tree"
