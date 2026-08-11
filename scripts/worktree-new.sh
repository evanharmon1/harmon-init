#!/usr/bin/env bash
# worktree-new.sh — create a ready-to-work linked git worktree under .worktrees/.
#
# Run via `task worktree:new -- <name> [options]`.
#
# One blessed entrypoint so every consumer — a parallel Claude session, Foreman,
# herdr, agent-deck, workmux, or a human — gets the same tree: checked out,
# dependencies installed for THIS tree, and git hooks proven to fire in it.
# Without it each tool rediscovers the same setup steps and the same breakers
# (a fresh worktree has no node_modules; `-c core.hooksPath=.git/hooks` silently
# resolves to nothing because `.git` is a FILE in a linked worktree).
#
# Options:
#   --branch <name>   branch to create/attach (default: the worktree name)
#   --base <ref>      base for a NEW branch (default: HEAD)
#   --no-install      skip the per-tree dependency install
#
# Exits non-zero with the fix in the message when a precondition is missing, and
# rolls back a half-provisioned tree rather than leaving debris behind.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: task worktree:new -- <name> [--branch <branch>] [--base <ref>] [--no-install]

Creates .worktrees/<name> as a linked git worktree, installs this tree's
dependencies, verifies git hooks fire inside it, and prints the ready path.
EOF
}

die() {
    echo "worktree:new: $*" >&2
    exit 1
}

name=""
branch=""
base=""
do_install=1

while [ "$#" -gt 0 ]; do
    case "$1" in
    --branch)
        [ "$#" -ge 2 ] || die "--branch needs a value"
        branch="$2"
        shift 2
        ;;
    --base)
        [ "$#" -ge 2 ] || die "--base needs a value"
        base="$2"
        shift 2
        ;;
    --no-install)
        do_install=0
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

if [ -z "$name" ]; then
    usage
    die "a worktree name is required"
fi

# The name becomes a path segment under .worktrees/ — keep it to characters that
# are safe in both a path and a branch name, and refuse anything that could
# escape the directory.
case "$name" in
/* | -*) die "invalid name '$name': must not start with '/' or '-'" ;;
*..*) die "invalid name '$name': must not contain '..'" ;;
esac
case "$name" in
*[!A-Za-z0-9._/-]*) die "invalid name '$name': use only A-Z a-z 0-9 . _ - /" ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

[ -n "$branch" ] || branch="$name"

# Anchor .worktrees/ to the MAIN worktree, never to whichever linked tree the
# caller happens to be standing in — otherwise running this from inside a
# worktree nests .worktrees/a/.worktrees/b and every tool's assumption about
# where trees live stops holding. The first `git worktree list --porcelain`
# record is always the main worktree.
main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "$main_root" ] && [ -d "$main_root" ] || die "could not resolve the main worktree root"

# The default base is the MAIN worktree's HEAD, not the caller's. Running this
# from inside a feature worktree is supported, and a bare `HEAD` there would
# silently stack the new branch on the caller's commits — the new tree would
# look independent while carrying unrelated work into its PR. Pass
# `--base HEAD` to stack deliberately.
if [ -z "$base" ]; then
    base="$(git -C "$main_root" rev-parse --verify --quiet HEAD || true)"
    [ -n "$base" ] ||
        die "the main worktree has no commits yet — make an initial commit, or pass --base <ref>"
fi

tree="$main_root/.worktrees/$name"
if [ -e "$tree" ]; then
    die "$tree already exists — remove it with 'task worktree:rm -- $name' first"
fi

# Roll back on any failure AFTER the tree exists. A half-provisioned worktree is
# worse than none: the next run refuses because the path is taken, and the tool
# that called this one sees a directory that looks ready and is not.
tree_created=0
branch_created=0
probe_dir=""
cleanup() {
    status=$?
    [ -n "$probe_dir" ] && rm -rf "$probe_dir"
    if [ "$status" -ne 0 ] && [ "$tree_created" -eq 1 ]; then
        echo "worktree:new: rolling back the half-provisioned tree $tree" >&2
        git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
        git worktree prune >/dev/null 2>&1 || true
        if [ "$branch_created" -eq 1 ]; then
            git branch -D "$branch" >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$main_root/.worktrees"

# Attach to the branch when it already exists, create it otherwise. git itself
# refuses (loudly) when the branch is already checked out in another worktree,
# which is exactly the right failure.
#
# A branch that exists only on a remote counts as existing. After a fresh clone
# every branch but the default one is remote-only, so treating that as "new"
# would create a same-named local branch at the base commit and silently drop
# the remote branch's work — the push that follows diverges or is rejected.
# `git worktree add <path> <name>` does this DWIM itself; passing -b opts out of
# it, so the remote lookup has to be explicit.
remote_ref=""
if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    remote_matches="$(git for-each-ref --format='%(refname)' "refs/remotes/*/$branch")"
    remote_count="$(printf '%s' "$remote_matches" | grep -c . || true)"
    if [ "$remote_count" -gt 1 ]; then
        die "branch '$branch' exists on more than one remote — pass --branch/--base to choose explicitly"
    fi
    [ "$remote_count" -eq 1 ] && remote_ref="$remote_matches"
fi

if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "==> Attaching existing branch '$branch'"
    git worktree add "$tree" "$branch"
elif [ -n "$remote_ref" ]; then
    echo "==> Creating branch '$branch' tracking ${remote_ref#refs/remotes/}"
    git worktree add "$tree" --track -b "$branch" "${remote_ref#refs/remotes/}"
    branch_created=1
else
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
        die "base ref '$base' does not resolve to a commit"
    echo "==> Creating branch '$branch' from '$base'"
    git worktree add "$tree" -b "$branch" "$base"
    branch_created=1
fi
tree_created=1

have() { command -v "$1" >/dev/null 2>&1; }

# ── Per-tree dependency install ──────────────────────────────────────
# A linked worktree gets its own working files, so node_modules/.venv from the
# main checkout are NOT there. Detect what this repo needs from the files in the
# tree rather than from a scaffold-time answer: the same script then works in
# every generated repo and stays a byte-identical root<->template twin.
if [ "$do_install" -eq 1 ]; then
    if [ -f "$tree/package.json" ]; then
        have pnpm || die "package.json is present but pnpm is not installed — run 'task bootstrap' (or install pnpm) and re-run"
        echo "==> Installing Node dependencies (pnpm) in the new tree"
        (cd "$tree" && pnpm install)
    fi
    if [ -f "$tree/pyproject.toml" ]; then
        have uv || die "pyproject.toml is present but uv is not installed — run 'task bootstrap' (or install uv) and re-run"
        echo "==> Installing Python dependencies (uv sync) in the new tree"
        (cd "$tree" && uv sync)
    fi
fi

# ── Hooks must FIRE in the new tree, not merely be configured ────────
# git looks a hook up in core.hooksPath when set, else $GIT_COMMON_DIR/hooks —
# `rev-parse --git-path hooks` implements exactly that resolution, so asking git
# is the assertion. --path-format=absolute resolves it against the new tree,
# which is what catches the classic breaker: `-c core.hooksPath=.git/hooks`
# points at a FILE's child in a linked worktree and silently finds nothing.
hooks_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-path hooks)"

if [ ! -x "$hooks_dir/pre-commit" ] && [ -f "$tree/lefthook.yml" ]; then
    have lefthook || die "git hooks are not installed and lefthook is missing — install lefthook, run 'task install:hooks', and re-run"
    echo "==> Installing git hooks (lefthook)"
    (cd "$tree" && lefthook install >/dev/null)
    hooks_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-path hooks)"
fi

if [ ! -x "$hooks_dir/pre-commit" ]; then
    if [ -f "$tree/lefthook.yml" ]; then
        die "no executable pre-commit hook at $hooks_dir — run 'task install:hooks' in $main_root and re-run"
    fi
    echo "==> Note: this repo has no lefthook.yml and no pre-commit hook; skipping the hook assertion"
else
    # Prove the hook RUNS from inside the tree and delegates to lefthook, without
    # running any actual lint. The lefthook-generated shim execs $LEFTHOOK_BIN
    # when set, so a probe binary records the delegation.
    probe_dir="$(mktemp -d)"
    marker="$probe_dir/invoked"
    cat >"$probe_dir/probe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
EOF
    chmod +x "$probe_dir/probe"
    (cd "$tree" && LEFTHOOK_BIN="$probe_dir/probe" "$hooks_dir/pre-commit") ||
        die "the pre-commit hook at $hooks_dir failed to execute from $tree"
    grep -q '^run pre-commit' "$marker" 2>/dev/null ||
        die "the pre-commit hook did not delegate to lefthook from $tree — reinstall with 'task install:hooks'"
    echo "==> Hooks verified: git resolves $hooks_dir and pre-commit fires in the new tree"
fi

echo
echo "Worktree ready: $tree"
echo "Branch:         $branch"
echo "Next:           cd $tree && task check"
