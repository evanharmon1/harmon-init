#!/usr/bin/env bash
# test-bootstrap-related-repos.sh — unit-test bootstrap-related-repos.sh fallback,
# concurrency locking, and idempotency (stubbed gh/git and local bare git repo, no network).
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
BARE_BASE="${TMP}/bare-upstream"
mkdir -p "${BARE_BASE}/test-owner"
BARE_REPO="${BARE_BASE}/test-owner/test-repo.git"
git init --bare "${BARE_REPO}" >/dev/null 2>&1

SCRATCH="${TMP}/scratch-repo"
git clone "${BARE_REPO}" "${SCRATCH}" >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "initial commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin HEAD:main >/dev/null 2>&1
git -C "${SCRATCH}" checkout -b feature-branch >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "branch commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin feature-branch >/dev/null 2>&1
rm -rf "${SCRATCH}"

BIN_DIR="${TMP}/bin"
mkdir -p "${BIN_DIR}"

REAL_GIT="$(which git)"

# --- Stub git that enforces offline operation and logs arguments ---
cat <<EOF >"${BIN_DIR}/git"
#!/usr/bin/env bash
if [ -n "\${GIT_LOG:-}" ]; then
    echo "\$*" >>"\${GIT_LOG}"
fi
for arg in "\$@"; do
    case "\$arg" in
    *https://github.com* | *https://*)
        echo "ERROR: network URL attempted in offline test: \$arg" >&2
        exit 99
        ;;
    esac
done
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${BIN_DIR}/git"

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
        branch=""
        while [ \$# -gt 0 ]; do
            if [ "\$1" = "--branch" ]; then
                branch="\$2"
                shift 2
            else
                shift
            fi
        done
        upstream="${BARE_BASE}/\${target_spec}.git"
        if [ -n "\$branch" ]; then
            "${BIN_DIR}/git" clone --quiet --branch "\$branch" "\$upstream" "\$target_dir"
        else
            "${BIN_DIR}/git" clone --quiet "\$upstream" "\$target_dir"
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
        echo "clone error simulated" >&2
        exit 1
    fi
    ;;
concurrent-user-create)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        target_spec="\$3"
        target_dir="\$4"
        # Simulate user creating the final target directory while clone runs
        mkdir -p "\${WORKSPACES_DIR}/test-repo"
        echo "user-checkout-data" >"\${WORKSPACES_DIR}/test-repo/user-file.txt"
        upstream="${BARE_BASE}/\${target_spec}.git"
        "${BIN_DIR}/git" clone --quiet "\$upstream" "\$target_dir"
        exit 0
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
    export RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/"
    bash "${SUT}"
}

# --- Test 1: Unauthenticated gh falls back to git clone (offline) ---
echo "==> unauthenticated gh falls back to git clone (offline)"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-1.log"
GIT_LOG="${TMP}/git-1.log"
rm -f "${STUB_LOG}" "${GIT_LOG}"
export STUB_LOG GIT_LOG
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback"
grep -q "auth status" "${STUB_LOG}" || fail "expected gh auth status probe"
grep -q "clone.*test-owner/test-repo.git" "${GIT_LOG}" || fail "expected git fallback clone to be executed offline"

# --- Test 2: Failing gh repo clone falls back to git clone ---
echo "==> failing gh repo clone falls back to git clone"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-2.log"
GIT_LOG="${TMP}/git-2.log"
rm -f "${STUB_LOG}" "${GIT_LOG}"
export STUB_LOG GIT_LOG
run_sut clone-fails
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback after gh clone failed"
grep -q "clone.*test-owner/test-repo.git" "${GIT_LOG}" || fail "expected git fallback clone to be executed"

# --- Test 3: Both failing leaves no directory behind and exits 0 (offline) ---
echo "==> both failing leaves no directory behind and exits 0 (offline)"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "unknown-owner/nonexistent-repo" >"${CONFIG}"
GIT_LOG="${TMP}/git-3.log"
rm -f "${GIT_LOG}"
export GIT_LOG
rc=0
run_sut unauthenticated >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 even when clone fails"
[ ! -e "${WORKSPACES}/nonexistent-repo" ] || fail "failed clone must not leave a directory behind"
grep -q "nonexistent-repo.git" "${GIT_LOG}" || fail "expected offline git fallback attempt"

# --- Test 4: Already-present repo is skipped ---
echo "==> already-present repo is skipped"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
mkdir -p "${WORKSPACES}/test-repo"
echo "custom-content" >"${WORKSPACES}/test-repo/marker.txt"
echo "test-owner/test-repo" >"${CONFIG}"
run_sut auth-ok
[ -f "${WORKSPACES}/test-repo/marker.txt" ] || fail "existing repository contents must not be clobbered"
[ ! -d "${WORKSPACES}/test-repo/.git" ] || fail "skipped repo should not have been cloned over"

# --- Test 5: Concurrent target creation does not delete user checkout ---
echo "==> concurrent target creation does not delete user checkout"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
run_sut concurrent-user-create >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when target created concurrently"
[ -f "${WORKSPACES}/test-repo/user-file.txt" ] || fail "user checkout was deleted by bootstrap cleanup"

# --- Test 6: Branch suffix is preserved during fallback ---
echo "==> branch suffix is preserved during fallback"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo@feature-branch" >"${CONFIG}"
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected repo to be cloned"
current_branch="$(git -C "${WORKSPACES}/test-repo" rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "feature-branch" ] || fail "expected branch feature-branch, got $current_branch"

# --- Test 7: Stale lock with dead PID is reclaimed ---
echo "==> stale lock with dead PID is reclaimed"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
mkdir -p "${LOCK_DIR}"
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
done
echo "$dead_pid" >"${LOCK_DIR}/pid"
rc=0
run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "run should reclaim stale lock and exit 0"
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected repo to be cloned after reclaiming stale lock"
rm -rf "${LOCK_DIR}" 2>/dev/null || true

# --- Test 8: Active lock with live PID exits 0 without cloning ---
echo "==> active lock with live PID exits 0 without cloning"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
mkdir -p "${LOCK_DIR}"
echo "$$" >"${LOCK_DIR}/pid"
rc=0
out="$(run_sut auth-ok 2>&1)" || rc=$?
rm -rf "${LOCK_DIR}" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "active lock run must exit 0"
case "$out" in
*"already in progress"*) ;;
*) fail "expected lock rejection message, got: $out" ;;
esac
[ ! -e "${WORKSPACES}/test-repo" ] || fail "active lock run should not clone"

echo "test-bootstrap-related-repos.sh passed"
