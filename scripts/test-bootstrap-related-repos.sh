#!/usr/bin/env bash
# test-bootstrap-related-repos.sh — unit-test bootstrap-related-repos.sh fallback,
# concurrency locking, and idempotency (stubbed gh and local bare git repo, no network).
#
# Run via `task test:related-repos`.
set -euo pipefail
cd "$(dirname "$0")/.."

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
unset NODE_OPTIONS

SUT="./.devcontainer/scripts/bootstrap-related-repos.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# --- Setup local bare git repository to act as hermetic upstream ---
BARE_REPO="${TMP}/bare-repo.git"
git init --bare "${BARE_REPO}" >/dev/null 2>&1

SCRATCH="${TMP}/scratch-repo"
git clone "${BARE_REPO}" "${SCRATCH}" >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "initial commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin HEAD:main >/dev/null 2>&1
git -C "${SCRATCH}" checkout -b feature-branch >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "branch commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin feature-branch >/dev/null 2>&1
rm -rf "${SCRATCH}"

# Redirect https://github.com/test-owner/test-repo to our local bare repo.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://${BARE_REPO}.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/test-owner/test-repo.git"
export GIT_CONFIG_KEY_1="url.file://${BARE_REPO}.insteadOf"
export GIT_CONFIG_VALUE_1="https://github.com/test-owner/test-repo"

BIN_DIR="${TMP}/bin"
mkdir -p "${BIN_DIR}"

make_stub() {
    local scenario="$1"
    cat <<EOF >"${BIN_DIR}/gh"
#!/usr/bin/env bash
if [ -n "\${STUB_LOG:-}" ]; then
    echo "\$*" >>"\${STUB_LOG}"
fi
case "$scenario" in
auth-ok)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        target_spec="\$3"
        target_dir="\$4"
        shift 4
        # Parse optional branch after --
        branch=""
        while [ \$# -gt 0 ]; do
            if [ "\$1" = "--branch" ]; then
                branch="\$2"
                shift 2
            else
                shift
            fi
        done
        if [ -n "\$branch" ]; then
            git clone --quiet --branch "\$branch" "https://github.com/\${target_spec}.git" "\$target_dir"
        else
            git clone --quiet "https://github.com/\${target_spec}.git" "\$target_dir"
        fi
        exit 0
    fi
    ;;
unauthenticated)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        echo "You are not logged into any GitHub hosts." >&2
        exit 1
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        echo "Authentication required." >&2
        exit 1
    fi
    ;;
clone-fails)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        # Create a partial/broken target to test cleanup
        mkdir -p "\$4/partial-junk"
        echo "clone error simulated" >&2
        exit 1
    fi
    ;;
esac
echo "unexpected stub call: \$*" >&2
exit 1
EOF
    chmod +x "${BIN_DIR}/gh"
}

WORKSPACES="${TMP}/workspaces"
CONFIG="${TMP}/related-repos.txt"
LOCK_DIR="${TMP}/test.lock"

run_sut() {
    local scenario="$1"
    make_stub "${scenario}"
    export PATH="${BIN_DIR}:${PATH}"
    export WORKSPACES_DIR="${WORKSPACES}"
    export CONFIG_FILE="${CONFIG}"
    export BOOTSTRAP_LOCK_DIR="${LOCK_DIR}"
    bash "${SUT}"
}

# --- Test 1: Unauthenticated gh falls back to git clone ---
echo "==> unauthenticated gh falls back to git clone"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-1.log"
rm -f "${STUB_LOG}"
export STUB_LOG
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback"
grep -q "auth status" "${STUB_LOG}" || fail "expected gh auth status probe"

# --- Test 2: Failing gh repo clone falls back to git clone ---
echo "==> failing gh repo clone falls back to git clone"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-2.log"
rm -f "${STUB_LOG}"
export STUB_LOG
run_sut clone-fails
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback after gh clone failed"
[ ! -d "${WORKSPACES}/test-repo/partial-junk" ] || fail "partial junk from failed gh clone should have been cleaned up"

# --- Test 3: Both failing leaves no directory behind and exits 0 ---
echo "==> both failing leaves no directory behind and exits 0"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
# This repo is not in insteadOf redirection, so git clone will fail too
echo "unknown-owner/nonexistent-repo" >"${CONFIG}"
rc=0
run_sut unauthenticated >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 even when clone fails"
[ ! -e "${WORKSPACES}/nonexistent-repo" ] || fail "failed clone must not leave a directory behind"

# --- Test 4: Already-present repo is skipped ---
echo "==> already-present repo is skipped"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
mkdir -p "${WORKSPACES}/test-repo"
echo "custom-content" >"${WORKSPACES}/test-repo/marker.txt"
echo "test-owner/test-repo" >"${CONFIG}"
run_sut auth-ok
[ -f "${WORKSPACES}/test-repo/marker.txt" ] || fail "existing repository contents must not be clobbered"
[ ! -d "${WORKSPACES}/test-repo/.git" ] || fail "skipped repo should not have been cloned over"

# --- Test 5: Branch suffix is preserved during fallback ---
echo "==> branch suffix is preserved during fallback"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo@feature-branch" >"${CONFIG}"
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected repo to be cloned"
current_branch="$(git -C "${WORKSPACES}/test-repo" rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "feature-branch" ] || fail "expected branch feature-branch, got $current_branch"

# --- Test 6: Concurrent bootstrap run is locked out and exits 0 ---
echo "==> concurrent bootstrap run is locked out and exits 0"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
mkdir -p "${LOCK_DIR}"
rc=0
out="$(run_sut auth-ok 2>&1)" || rc=$?
rmdir "${LOCK_DIR}" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "locked out bootstrap must exit 0"
case "$out" in
*"already in progress"*) ;;
*) fail "expected lock rejection message, got: $out" ;;
esac
[ ! -e "${WORKSPACES}/test-repo" ] || fail "locked out run should not clone"

echo "test-bootstrap-related-repos.sh passed"
