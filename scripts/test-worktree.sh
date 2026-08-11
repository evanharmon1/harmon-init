#!/usr/bin/env bash
# test-worktree.sh — behavioral test for the worktree entrypoint. Run via
# `task test:worktree`.
#
# Everything happens inside a throwaway `git init` fixture, never in the calling
# repository: the scripts under test create and delete worktrees, and a test that
# did that to the developer's own checkout would be a data-loss path.
#
# lefthook is used for real when it is on PATH (the local/devcontainer case) and
# stubbed with a shim matching lefthook's documented contract otherwise, so the
# hook assertion runs everywhere — including CI runners that carry no lefthook.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

# Hooks export GIT_DIR/GIT_WORK_TREE; left set, every `git` below would retarget
# the CALLING repository instead of the fixture. Same sanitation as
# scripts/test-template.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

refute_exists() {
    # Spelled out rather than `[ -e X ] && fail ...`: the negative case of an
    # && list is itself a non-zero statement, which is a trap under set -e.
    if [ -e "$1" ]; then
        fail "$2"
    fi
}

# `pwd -P` because macOS mktemp hands back /var/... while git reports the
# physical /private/var/... — the two must agree for the path assertions below.
test_tmp="$(cd "$(mktemp -d -t harmon-init-worktree-XXXXXX)" && pwd -P)"
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

if command -v lefthook >/dev/null 2>&1; then
    echo "==> Using the real lefthook for the hook assertions"
else
    echo "==> lefthook not installed — stubbing its install contract"
    cat >"$stub_bin/lefthook" <<'STUB'
#!/usr/bin/env bash
# Minimal stand-in for `lefthook install`: writes the same shim shape lefthook
# generates — honouring LEFTHOOK=0 and LEFTHOOK_BIN — so the entrypoint's hook
# probe exercises the real contract even where lefthook is not installed.
set -euo pipefail
case "${1:-}" in
install)
    hooks="$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "$hooks"
    cat >"$hooks/pre-commit" <<'HOOK'
#!/bin/sh
if [ "$LEFTHOOK" = "0" ]; then
  exit 0
fi
if test -n "$LEFTHOOK_BIN"; then
  "$LEFTHOOK_BIN" run "pre-commit" "$@"
else
  lefthook run "pre-commit" "$@"
fi
HOOK
    chmod +x "$hooks/pre-commit"
    ;;
*) exit 0 ;;
esac
STUB
    chmod +x "$stub_bin/lefthook"
fi

PATH="$stub_bin:$PATH"
export PATH

# ── Fixture repository ───────────────────────────────────────────────
fixture="$test_tmp/fixture"
mkdir -p "$fixture/scripts"
cp "$repo/scripts/worktree-new.sh" "$repo/scripts/worktree-rm.sh" "$fixture/scripts/"
chmod +x "$fixture/scripts/worktree-new.sh" "$fixture/scripts/worktree-rm.sh"
cat >"$fixture/lefthook.yml" <<'EOF'
pre-commit:
  commands:
    noop:
      run: "true"
EOF
printf 'fixture\n' >"$fixture/README.md"

git -C "$fixture" init -q
git -C "$fixture" config user.name "Worktree Test"
git -C "$fixture" config user.email "worktree-test@example.invalid"
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" add -A
git -C "$fixture" commit -qm "chore: fixture"
(cd "$fixture" && lefthook install >/dev/null 2>&1) || fail "could not install hooks in the fixture"
shared_hooks="$(cd "$fixture" && git rev-parse --path-format=absolute --git-path hooks)"

new() { (cd "$fixture" && bash scripts/worktree-new.sh "$@"); }
rm_wt() { (cd "$fixture" && bash scripts/worktree-rm.sh "$@"); }

# ── create → work inside → remove ────────────────────────────────────
echo "==> worktree:new creates .worktrees/<name> with its own branch"
out="$(new scratch)" || fail "worktree-new.sh failed"
[ -d "$fixture/.worktrees/scratch" ] || fail "worktree-new.sh did not create .worktrees/scratch"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/scratch" ||
    fail "the new tree is not registered as a worktree"
git -C "$fixture" show-ref --verify --quiet refs/heads/scratch ||
    fail "worktree-new.sh did not create the branch"
case "$out" in *"Worktree ready:"*) : ;; *) fail "worktree-new.sh did not print the ready path" ;; esac

echo "==> hooks are asserted, not assumed, inside the new tree"
case "$out" in *"Hooks verified"*) : ;; *) fail "worktree-new.sh did not verify hooks in the new tree" ;; esac
tree_hooks="$(git -C "$fixture/.worktrees/scratch" rev-parse --path-format=absolute --git-path hooks)"
[ "$tree_hooks" = "$shared_hooks" ] ||
    fail "git in the linked worktree resolves hooks to $tree_hooks, not the shared $shared_hooks"
[ -x "$tree_hooks/pre-commit" ] || fail "no executable pre-commit hook for the linked worktree"
# The gotcha this entrypoint exists to absorb: in a linked worktree `.git` is a
# FILE, so a hand-rolled `-c core.hooksPath=.git/hooks` resolves to nothing.
[ -f "$fixture/.worktrees/scratch/.git" ] ||
    fail "fixture assumption broken: .git in a linked worktree should be a file"

echo "==> a commit made INSIDE the worktree runs the shared hooks"
cat >"$test_tmp/commit-probe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$test_tmp/commit-probe.log"
EOF
chmod +x "$test_tmp/commit-probe"
printf 'work\n' >"$fixture/.worktrees/scratch/WORK.md"
git -C "$fixture/.worktrees/scratch" add WORK.md
LEFTHOOK_BIN="$test_tmp/commit-probe" \
    git -C "$fixture/.worktrees/scratch" commit -qm "chore: work in the worktree" \
    >"$test_tmp/commit.log" 2>&1 ||
    {
        cat "$test_tmp/commit.log" >&2
        fail "committing inside the worktree failed"
    }
grep -qx "run pre-commit" "$test_tmp/commit-probe.log" 2>/dev/null ||
    fail "the pre-commit hook did not fire for a real commit inside the worktree"

echo "==> a second create with the same name fails loudly"
if new scratch >/dev/null 2>&1; then
    fail "worktree-new.sh silently reused an existing path"
fi

echo "==> worktree:rm removes the tree and prunes the registry"
rm_wt scratch >/dev/null || fail "worktree-rm.sh failed on a clean tree"
refute_exists "$fixture/.worktrees/scratch" "worktree-rm.sh left the directory behind"
if git -C "$fixture" worktree list --porcelain | grep -q "scratch"; then
    fail "worktree-rm.sh left a stale registry record"
fi

# ── dirty-tree refusal ───────────────────────────────────────────────
echo "==> worktree:rm refuses a dirty tree, and --force overrides"
new dirty >/dev/null || fail "worktree-new.sh failed for the dirty-tree case"
printf 'uncommitted\n' >"$fixture/.worktrees/dirty/NOTES.md"
if rm_wt dirty >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a dirty tree without --force"
fi
[ -d "$fixture/.worktrees/dirty" ] || fail "worktree-rm.sh removed the dirty tree despite refusing"
rm_wt dirty --force >/dev/null || fail "worktree-rm.sh --force failed on a dirty tree"
refute_exists "$fixture/.worktrees/dirty" "worktree-rm.sh --force left the directory behind"

# ── leftover gitlink debris (the #716 class) ─────────────────────────
echo "==> worktree:rm clears a leftover gitlink directory"
new debris >/dev/null || fail "worktree-new.sh failed for the debris case"
common_dir="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "${common_dir:?}/worktrees/debris"
find "$fixture/.worktrees/debris" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
rm_wt debris >/dev/null || fail "worktree-rm.sh could not clear leftover gitlink debris"
refute_exists "$fixture/.worktrees/debris" "worktree-rm.sh left gitlink debris behind"
git -C "$fixture" branch -D debris >/dev/null 2>&1 || true

# ── .worktrees/ is anchored to the MAIN worktree ─────────────────────
echo "==> creating from inside a linked worktree still anchors to the main tree"
new outer >/dev/null || fail "worktree-new.sh failed creating the outer tree"
(cd "$fixture/.worktrees/outer" && bash scripts/worktree-new.sh inner >/dev/null) ||
    fail "worktree-new.sh failed when run from inside a linked worktree"
[ -d "$fixture/.worktrees/inner" ] ||
    fail "worktree-new.sh did not anchor .worktrees/ to the main worktree"
refute_exists "$fixture/.worktrees/outer/.worktrees" "worktree-new.sh nested .worktrees/ inside a linked worktree"
rm_wt inner >/dev/null || fail "cleanup of the inner tree failed"
rm_wt outer >/dev/null || fail "cleanup of the outer tree failed"

# ── name validation ──────────────────────────────────────────────────
echo "==> path-escaping and empty names are rejected"
for bad in "../evil" "/abs" ""; do
    if new "$bad" >/dev/null 2>&1; then
        fail "worktree-new.sh accepted the invalid name '$bad'"
    fi
done
refute_exists "$test_tmp/evil" "worktree-new.sh escaped the fixture directory"

# ── per-tree dependency install ──────────────────────────────────────
echo "==> a Node repo gets its dependencies installed in the NEW tree"
pnpm_marker="$test_tmp/pnpm-invoked"
cat >"$stub_bin/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$*" "\$PWD" >>"$pnpm_marker"
exit 0
EOF
chmod +x "$stub_bin/pnpm"
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
git -C "$fixture" add -A
git -C "$fixture" commit -qm "chore: add package.json" >"$test_tmp/commit.log" 2>&1 ||
    {
        cat "$test_tmp/commit.log" >&2
        fail "committing package.json in the fixture failed"
    }
new node-tree >/dev/null || fail "worktree-new.sh failed on a Node repo"
grep -qx "install $fixture/.worktrees/node-tree" "$pnpm_marker" 2>/dev/null ||
    fail "worktree-new.sh did not run 'pnpm install' inside the new tree"
rm_wt node-tree >/dev/null || fail "cleanup of the node tree failed"

echo "==> --no-install skips the dependency install"
: >"$pnpm_marker"
new no-install-tree --no-install >/dev/null || fail "worktree-new.sh --no-install failed"
if [ -s "$pnpm_marker" ]; then
    fail "worktree-new.sh ran the installer despite --no-install"
fi
rm_wt no-install-tree >/dev/null || fail "cleanup of the --no-install tree failed"

echo "==> a missing package manager fails loudly and rolls the tree back"
rm -f "$stub_bin/pnpm"
if (
    PATH="$stub_bin:/usr/bin:/bin"
    export PATH
    new missing-pnpm >/dev/null 2>&1
); then
    fail "worktree-new.sh succeeded with package.json present and no pnpm"
fi
refute_exists "$fixture/.worktrees/missing-pnpm" "worktree-new.sh left a half-provisioned tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/missing-pnpm; then
    fail "worktree-new.sh left the branch behind after rolling back"
fi

echo "worktree entrypoint OK: create → hooks verified → deps installed → removed"
