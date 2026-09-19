#!/usr/bin/env bash
# test-devcontainer-git-ownership.sh — regression coverage for bind-mounted
# workspace permissions, exact Git trust, and repository-managed hooks.
#
# The fixture exercises the real permissions reconciliation helper with a
# logging sudo shim. The Linux bot devcontainer smoke test remains the decisive
# check of a real UID-mismatched bind mount and host-runner checkout.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_script="scripts/test-devcontainer-git-ownership.sh"
post_create=".devcontainer/scripts/post-create-common.sh"
template_common="template/[% if devcontainer %].devcontainer[% endif %]/scripts/post-create-common.sh"
bot_post_create=".devcontainer/post-create.sh"
template_bot_post_create="template/[% if devcontainer %].devcontainer[% endif %]/post-create.sh.jinja"
template_test="template/scripts/[% if devcontainer %]test-devcontainer-git-ownership.sh[% endif %]"

for required_file in "$test_script" "$post_create" "$bot_post_create"; do
    [ -r "$required_file" ] || fail "$required_file not found"
done
# The root checkout owns the Copier source tree and its dogfood answers. A
# generated consumer may legitimately have a project directory named
# "template", so the directory name alone is not a root-repository marker.
if [ -f .dogfood-answers.yml ] && [ -d template ]; then
    for required_file in "$template_common" "$template_bot_post_create" "$template_test"; do
        [ -r "$required_file" ] || fail "$required_file not found"
    done
    cmp -s "$post_create" "$template_common" ||
        fail "root and template permissions helpers diverged"
    cmp -s "$test_script" "$template_test" ||
        fail "root and template focused tests diverged"
fi

# Extract the production helper verbatim. This keeps the fixture attached to
# the implementation instead of growing a second, drifting permissions routine.
tmp_root="$(mktemp -d -t harmon-git-ownership-XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT
helpers="$tmp_root/workspace-permissions.sh"
sed -n '/^resolve_workspace_root()/,/^# --- End workspace permissions reconciliation ---$/p' "$post_create" | sed '$d' >"$helpers"
[ -s "$helpers" ] || fail "could not extract workspace permissions helpers"
grep -q '^reconcile_workspace_permissions()' "$helpers" ||
    fail "the extracted helpers do not include reconcile_workspace_permissions"
grep -q '^resolve_git_dir()' "$helpers" ||
    fail "the extracted helpers do not include resolve_git_dir"
! grep -Fq 'a+rwX' "$helpers" ||
    fail "permissions reconciliation still grants world-writable Git metadata permissions"
! grep -Eq 'mountpoint|hard.?link|core[.]hooksPath' "$helpers" ||
    fail "permissions reconciliation retained recursive filesystem policy"
grep -Fq '[ -L "$candidate/.git" ]' "$helpers" ||
    fail "permissions reconciliation does not reject symlinked Git markers"
grep -Fq 'git_dir="$(resolve_git_dir "$workspace_root")"' "$helpers" ||
    fail "permissions reconciliation does not resolve the real Git directory before touching it"
grep -Fq 'sudo chown -R "$(id -u):$(id -g)" "$git_dir"' "$helpers" ||
    fail "permissions reconciliation does not reclaim ownership of the Git directory"
grep -Fq 'find "$git_dir" -type d -exec chmod 0755 {} +' "$helpers" ||
    fail "permissions reconciliation does not set exact directory permissions"
grep -Fq 'find "$git_dir" -type f -exec chmod 0644 {} +' "$helpers" ||
    fail "permissions reconciliation does not set exact file permissions"

reconcile_line="$(grep -nF 'reconcile_workspace_permissions "$ENV_GITCONFIG"' "$post_create" |
    head -1 | cut -d: -f1)"
lefthook_line="$(grep -n '^    lefthook install$' "$post_create" |
    head -1 | cut -d: -f1)"
[ -n "$reconcile_line" ] && [ -n "$lefthook_line" ] ||
    fail "could not locate reconciliation or lefthook install in $post_create"
[ "$reconcile_line" -lt "$lefthook_line" ] ||
    fail "workspace permissions reconciliation occurs after lefthook install"
! grep -Fq 'reconcile_workspace_ownership' "$post_create" ||
    fail "the old ownership reconciliation name remains"
grep -Fq 'reconcile_workspace_permissions "$ENV_GITCONFIG"' "$post_create" ||
    fail "permissions reconciliation is not called directly"

assert_managed_hook_script() {
    local bot_script="$1"

    grep -Fq 'install_repo_managed_hooks()' "$bot_script" ||
        fail "$bot_script does not define managed hook installation"
    grep -Fq 'cp "$hook" "$target"' "$bot_script" ||
        fail "$bot_script does not copy named managed hooks"
    grep -Fq 'chmod +x "$target"' "$bot_script" ||
        fail "$bot_script does not chmod named managed hooks"
    ! grep -Fq 'chmod +x "$target" || true' "$bot_script" ||
        fail "$bot_script still swallows a chmod +x failure on a managed hook"
    ! grep -Fq 'chmod +x .git/hooks/*' "$bot_script" ||
        fail "$bot_script still chmods every Git sample hook"
    ! grep -Fq 'chmod +x "$hooks_dir"/*' "$bot_script" ||
        fail "$bot_script still chmods a wildcard hook path"
}
assert_managed_hook_script "$bot_post_create"
if [ -f .dogfood-answers.yml ] && [ -d template ]; then
    assert_managed_hook_script "$template_bot_post_create"
fi

managed_helpers="$tmp_root/managed-hooks.sh"
sed -n '/^install_repo_managed_hooks()/,/^}$/p' "$bot_post_create" >"$managed_helpers"
[ -s "$managed_helpers" ] || fail "could not extract managed hook installer"
grep -q '^install_repo_managed_hooks()' "$managed_helpers" ||
    fail "the extracted hook installer is missing its function"

fixture="$tmp_root/fixture"
repo="$fixture/workspaces/example"
unrelated="$fixture/unrelated"
home="$fixture/home"
xdg="$fixture/xdg"
exact_xdg="$fixture/exact-xdg"
no_safe_xdg="$fixture/no-safe-xdg"
host_home="$fixture/host-home"
host_xdg="$fixture/host-xdg"
fake_bin="$fixture/bin"
log="$fixture/sudo.log"
mkdir -p "$repo/subdirectory" "$unrelated" "$home" "$xdg/git" "$exact_xdg/git" "$no_safe_xdg/git" "$host_home" "$host_xdg/git" "$fake_bin"
repo="$(cd "$repo" && pwd -P)"
unrelated="$(cd "$unrelated" && pwd -P)"

git -C "$repo" init -q
mkdir -p "$repo/.git/hooks"
printf '%s\n' tracked >"$repo/tracked.txt"
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test add tracked.txt
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit -qm init
git -C "$repo" config --file "$xdg/git/config" --add safe.directory '*'
chmod 0500 "$repo/.git/hooks"
chmod 0700 "$repo/.git"

git_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
expected_owner="$(id -u):$(id -g)"

# The real post-create script invokes sudo only for chown (the fixture's
# invoking user already owns the tree, so chown to its own uid/gid needs no
# real privilege); this fixture records the exact target while letting the
# command actually run against the fixture's own Git metadata.
cat >"$fake_bin/sudo" <<'SUDO'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$SUDO_LOG"
if [ "$SUDO_FAIL" = "$1" ]; then
    exit 1
fi
"$@"
SUDO
chmod 0755 "$fake_bin/sudo"
SUDO_FAIL=""

run_reconcile_at() {
    local target_repo="$1" target_config="$2" target_log="$3"
    (
        cd "$target_repo/subdirectory"
        HOME="$home" XDG_CONFIG_HOME="$xdg" SUDO_LOG="$target_log" SUDO_FAIL="$SUDO_FAIL" PATH="$fake_bin:$PATH" bash -c 'set -e; . "$1"; reconcile_workspace_permissions "$2"; printf "%s\\n" "$RECONCILED_WORKSPACE_ROOT"' _ "$helpers" "$target_config"
    )
}
run_reconcile() {
    run_reconcile_at "$repo" "$xdg/git/config" "$log"
}

echo "==> mismatched-workspace fixture reclaims ownership and sets exact, non-world-writable modes"
resolved="$(run_reconcile)"
[ "$resolved" = "$repo" ] ||
    fail "resolved workspace root was '$resolved', expected '$repo'"
grep -Fqx "chown -R $expected_owner $repo/.git" "$log" ||
    fail "Git metadata ownership was not reclaimed for the container user at the resolved root"
! grep -Eq '^(find|mountpoint|mkdir) ' "$log" ||
    fail "permissions reconciliation ran unexpected commands under sudo"
! grep -Fq "$unrelated" "$log" ||
    fail "permissions reconciliation touched an unrelated path"
[ "$(git_mode "$repo/.git")" = "755" ] ||
    fail "Git metadata directory is not exactly 0755 after permissions repair"
[ "$(git_mode "$repo/.git/hooks")" = "755" ] ||
    fail "Git hooks directory is not exactly 0755 after permissions repair"
[ "$(git_mode "$repo/.git/config")" = "644" ] ||
    fail "a Git metadata file is not exactly 0644 after permissions repair"
if find "$repo/.git" -perm -022 | grep -q .; then
    fail "some Git metadata entry remains group- or world-writable"
fi
[ -r "$repo/.git" ] && [ -w "$repo/.git" ] && [ -x "$repo/.git" ] ||
    fail "Git metadata directory is not readable, writable, and traversable"
[ -r "$repo/.git/hooks" ] && [ -w "$repo/.git/hooks" ] && [ -x "$repo/.git/hooks" ] ||
    fail "Git hooks directory is not writable after permissions repair"

host_status="$(GIT_CONFIG_NOSYSTEM=1 HOME="$host_home" XDG_CONFIG_HOME="$host_xdg" git -C "$repo" status --short)"
[ -z "$host_status" ] ||
    fail "host-side Git was not usable after container setup: $host_status"

cat >"$fake_bin/lefthook" <<'LEFTHOOK'
#!/bin/sh
set -eu
[ "$1" = install ]
printf '%s\n' installed >"$LETHOOK_TARGET"
LEFTHOOK
chmod 0755 "$fake_bin/lefthook"
(
    cd "$repo"
    LETHOOK_TARGET="$repo/.git/hooks/pre-commit" PATH="$fake_bin:$PATH" lefthook install
)
[ -f "$repo/.git/hooks/pre-commit" ] ||
    fail "a Lefthook hook could not be written after permissions repair"

echo "==> exact safe.directory is added beside, not instead of, a wildcard"
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$xdg" git config --file "$xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "the exact workspace safe.directory entry is missing or duplicated: $safe_entries"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc '*')" -eq 1 ] ||
    fail "the pre-existing wildcard safe.directory entry was unexpectedly rewritten"
actual_root="$(GIT_CONFIG_NOSYSTEM=1 HOME="$home" XDG_CONFIG_HOME="$xdg" git -C "$repo" rev-parse --path-format=absolute --show-toplevel)"
[ "$actual_root" = "$repo" ] ||
    fail "Git did not inspect the exact safe workspace: $actual_root"

echo "==> exact safe.directory is effective without a wildcard"
run_reconcile_at "$repo" "$exact_xdg/git/config" "$fixture/exact-sudo.log" >/dev/null
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$exact_xdg" git config --file "$exact_xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "the exact-only safe.directory entry is missing or duplicated: $safe_entries"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc '*')" -eq 0 ] ||
    fail "the exact-only safe.directory config unexpectedly contains a wildcard"
if GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 HOME="$home" XDG_CONFIG_HOME="$no_safe_xdg" git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
    fail "Git accepted the ownership-mismatched fixture without safe.directory"
fi
actual_root="$(GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 HOME="$home" XDG_CONFIG_HOME="$exact_xdg" git -C "$repo" rev-parse --path-format=absolute --show-toplevel)" ||
    fail "Git rejected the exact safe.directory entry for the ownership-mismatched fixture"
[ "$actual_root" = "$repo" ] ||
    fail "Git did not inspect the exact-only safe workspace: $actual_root"

echo "==> repeated permissions reconciliation is idempotent"
: >"$log"
run_reconcile >/dev/null
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$xdg" git config --file "$xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "repeated reconciliation duplicated safe.directory: $safe_entries"
grep -Fqx "chown -R $expected_owner $repo/.git" "$log" ||
    fail "repeated reconciliation did not re-assert ownership"
[ "$(git_mode "$repo/.git")" = "755" ] ||
    fail "repeated reconciliation changed the Git metadata directory mode"

echo "==> linked-worktree fixture reconciles the real common directory, not the .git pointer file (#1241 item 6)"
wt_main="$fixture/workspaces/wt-main"
wt_linked="$fixture/workspaces/wt-linked"
wt_xdg="$fixture/wt-xdg/git/config"
wt_log="$fixture/wt-sudo.log"
mkdir -p "$wt_main" "$fixture/wt-xdg/git"
wt_main="$(cd "$wt_main" && pwd -P)"
git -C "$wt_main" init -q
git -C "$wt_main" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm init
git -C "$wt_main" worktree add -q "$wt_linked" -b wt-fixture-branch
wt_linked="$(cd "$wt_linked" && pwd -P)"
mkdir -p "$wt_linked/subdirectory"
[ -f "$wt_linked/.git" ] && [ ! -d "$wt_linked/.git" ] ||
    fail "fixture setup: expected the linked worktree's .git to be a file, not a directory"
wt_admin_name="$(basename "$wt_linked")"
[ -d "$wt_main/.git/worktrees/$wt_admin_name" ] ||
    fail "fixture setup: expected a worktree admin directory at $wt_main/.git/worktrees/$wt_admin_name"

resolved="$(run_reconcile_at "$wt_linked" "$wt_xdg" "$wt_log")"
[ "$resolved" = "$wt_linked" ] ||
    fail "linked-worktree resolved workspace root was '$resolved', expected '$wt_linked'"
grep -Fqx "chown -R $expected_owner $wt_main/.git" "$wt_log" ||
    fail "linked-worktree reconciliation did not reclaim ownership of the MAIN checkout's common Git directory"
! grep -Fq "$wt_linked/.git " "$wt_log" ||
    fail "linked-worktree reconciliation targeted the worktree's .git POINTER FILE instead of the resolved common directory"
[ "$(git_mode "$wt_main/.git")" = "755" ] ||
    fail "linked-worktree reconciliation did not set the common directory's mode"
[ "$(git_mode "$wt_main/.git/worktrees/$wt_admin_name")" = "755" ] ||
    fail "linked-worktree reconciliation did not reach the worktree's own private admin directory"
if find "$wt_main/.git" -perm -022 | grep -q .; then
    fail "linked-worktree reconciliation left some common-directory entry group- or world-writable"
fi
wt_safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$fixture/wt-xdg" git config --file "$wt_xdg" --get-all safe.directory)"
[ "$(printf '%s\n' "$wt_safe_entries" | grep -Fxc "$wt_linked")" -eq 1 ] ||
    fail "linked-worktree safe.directory entry does not name the worktree root: $wt_safe_entries"
wt_host_status="$(GIT_CONFIG_NOSYSTEM=1 HOME="$host_home" XDG_CONFIG_HOME="$host_xdg" git -C "$wt_linked" status --short)"
[ -z "$wt_host_status" ] ||
    fail "host-side Git was not usable in the linked worktree after container setup: $wt_host_status"

echo "==> symlinked Git markers fail closed before chmod"
symlink_repo="$fixture/workspaces/symlinked"
symlink_target="$fixture/external-git-target"
symlink_config="$fixture/symlink-xdg/git/config"
symlink_log="$fixture/symlink-sudo.log"
mkdir -p "$symlink_repo/subdirectory" "$symlink_target/.git/hooks" "$fixture/symlink-xdg/git"
ln -s "$symlink_target/.git" "$symlink_repo/.git"
chmod 0700 "$symlink_target/.git"
symlink_mode_before="$(ls -ld "$symlink_target/.git" | awk '{ print $1 }')"
if run_reconcile_at "$symlink_repo" "$symlink_config" "$symlink_log" >/dev/null 2>"$tmp_root/symlink.err"; then
    fail "a symlinked Git marker unexpectedly passed permissions reconciliation"
fi
[ ! -e "$symlink_log" ] || [ ! -s "$symlink_log" ] ||
    fail "symlink rejection invoked sudo"
symlink_mode_after="$(ls -ld "$symlink_target/.git" | awk '{ print $1 }')"
[ "$symlink_mode_after" = "$symlink_mode_before" ] ||
    fail "symlink rejection changed the external Git metadata mode"
symlink_safe_entries="$(git config --file "$symlink_config" --get-all safe.directory 2>/dev/null || true)"
! grep -Fqx "$symlink_repo" <<<"$symlink_safe_entries" ||
    fail "symlink rejection persisted safe.directory"

echo "==> permission failures stop before adding safe.directory"
failed_repo="$fixture/workspaces/failed"
failed_config="$fixture/failed-xdg/git/config"
failed_log="$fixture/failed-sudo.log"
mkdir -p "$failed_repo/subdirectory" "$fixture/failed-xdg/git"
git -C "$failed_repo" init -q
mkdir -p "$failed_repo/.git/hooks"
chmod 0700 "$failed_repo/.git"
failed_owner_before="$(ls -dn "$failed_repo/.git" | awk '{ print $3 ":" $4 }')"
if SUDO_FAIL=chown run_reconcile_at "$failed_repo" "$failed_config" "$failed_log" >/dev/null 2>"$tmp_root/failed.err"; then
    fail "a failed permissions reconciliation unexpectedly succeeded"
fi
failed_safe_entries="$(git config --file "$failed_config" --get-all safe.directory 2>/dev/null || true)"
! grep -Fqx "$failed_repo" <<<"$failed_safe_entries" ||
    fail "a failed reconciliation persisted safe.directory"
failed_owner_after="$(ls -dn "$failed_repo/.git" | awk '{ print $3 ":" $4 }')"
[ "$failed_owner_after" = "$failed_owner_before" ] ||
    fail "a failed reconciliation changed Git metadata ownership"

echo "==> only repository-managed hook names are chmodded"
hook_fixture="$fixture/managed-hooks"
mkdir -p "$hook_fixture/.devcontainer/hooks" "$hook_fixture/.git/hooks"
printf '%s\n' '#!/bin/sh' 'echo managed' >"$hook_fixture/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_fixture/.devcontainer/hooks/post-checkout"
printf '%s\n' sample >"$hook_fixture/.git/hooks/applypatch-msg.sample"
chmod 0644 "$hook_fixture/.git/hooks/applypatch-msg.sample"
(
    cd "$hook_fixture"
    . "$managed_helpers"
    install_repo_managed_hooks
)
[ -x "$hook_fixture/.git/hooks/post-checkout" ] ||
    fail "the managed hook was not made executable"
[ ! -x "$hook_fixture/.git/hooks/applypatch-msg.sample" ] ||
    fail "the Git sample hook was unexpectedly chmodded"
grep -Fqx 'echo managed' "$hook_fixture/.git/hooks/post-checkout" ||
    fail "the managed hook was not copied"

echo "==> a managed hook that cannot be made executable fails post-create loudly (#1241 item 5)"
hook_fail_fixture="$fixture/managed-hooks-fail"
hook_fail_bin="$fixture/hook-fail-bin"
mkdir -p "$hook_fail_fixture/.devcontainer/hooks" "$hook_fail_fixture/.git/hooks" "$hook_fail_bin"
printf '%s\n' '#!/bin/sh' 'echo managed' >"$hook_fail_fixture/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_fail_fixture/.devcontainer/hooks/post-checkout"
cat >"$hook_fail_bin/chmod" <<'CHMODFAIL'
#!/bin/sh
echo "simulated chmod +x failure" >&2
exit 1
CHMODFAIL
chmod 0755 "$hook_fail_bin/chmod"
if (
    cd "$hook_fail_fixture"
    PATH="$hook_fail_bin:$PATH"
    . "$managed_helpers"
    install_repo_managed_hooks
) >/dev/null 2>"$tmp_root/hook-fail.err"; then
    fail "a chmod +x failure on a managed hook did not abort install_repo_managed_hooks"
fi
grep -q . "$tmp_root/hook-fail.err" ||
    fail "a chmod +x failure on a managed hook produced no diagnostic output"

echo "devcontainer Git permissions: all cases passed"
