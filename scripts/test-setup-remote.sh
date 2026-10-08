#!/usr/bin/env bash
# test-setup-remote.sh — test `task setup:remote` end to end in a fixture repo:
# idempotency, the lefthook shim, frozen dependency installs, and sibling clones
# into the checkout's parent directory (stubbed lefthook/pnpm/uv/gh and a local
# bare repository as the sibling — no network).
#
# Run via `task test:setup-remote`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
unset GIT_SSH_COMMAND # a host may set one; the default (unset) case is what is under test
unset NODE_OPTIONS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
# Hermetic git: a platform may inject config (SSH->HTTPS rewrites, hooks paths).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# scripts/setup-remote.sh resolves the checkout with pwd -P (physical); a
# symlinked TMPDIR such as macOS's /var would otherwise make the printed and
# asserted paths differ (#1457).
# Two steps: a failed mktemp must stop the test here (set -e), not leave
# `cd ""` resolving the checkout itself as the directory the trap removes.
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
# A scenario may chmod a directory read-only; restore write access before removing it.
trap 'chmod -R u+w "${TMP}" 2>/dev/null; rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# --- A local bare repository standing in for a sibling on GitHub ---
BARE_BASE="${TMP}/bare-upstream"
mkdir -p "${BARE_BASE}/test-owner"
for name in sibling-a sibling-b; do
    git init -q --bare -b main "${BARE_BASE}/test-owner/${name}.git"
    git clone -q "${BARE_BASE}/test-owner/${name}.git" "${TMP}/seed-${name}" 2>/dev/null
    git -C "${TMP}/seed-${name}" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m "initial commit"
    git -C "${TMP}/seed-${name}" push -q origin HEAD:main 2>/dev/null
done

# --- A PATH holding only the tools the task needs, so a real lefthook/pnpm/uv on
# the host cannot leak into (or be missing from) a scenario. ---
MIN_BIN="${TMP}/minbin"
mkdir -p "${MIN_BIN}"
for tool in bash env git task dirname basename mktemp mv rm mkdir find cat sed grep sort cksum \
    xargs kill sleep uname head tr wc cp chmod ln touch id printf ls date; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && [ -x "$src" ] && ln -sf "$src" "${MIN_BIN}/${tool}"
done
REAL_LEFTHOOK="$(command -v lefthook 2>/dev/null || true)"

STUB_BIN="${TMP}/stubs"
LOG_DIR="${TMP}/logs"
mkdir -p "${STUB_BIN}" "${LOG_DIR}"

# lefthook: installs a pre-push shim only when it is missing or different.
cat >"${STUB_BIN}/lefthook" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG_DIR}/lefthook.log"
[ "${STUB_LEFTHOOK:-}" = "fail" ] && { echo "lefthook: simulated failure" >&2; exit 1; }
[ "${1:-}" = "install" ] || exit 2
hook=.git/hooks/pre-push
body='#!/bin/sh
# lefthook shim (stub)
exec lefthook run pre-push "$@"'
mkdir -p .git/hooks
if [ ! -f "$hook" ] || [ "$(cat "$hook")" != "$body" ]; then
    printf '%s\n' "$body" >"$hook"
    chmod +x "$hook"
fi
EOF
for tool in pnpm uv; do
    cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\${STUB_LOG_DIR}/${tool}.log"
echo "\${CI-unset}" >>"\${STUB_LOG_DIR}/${tool}.ci"
exit 0
EOF
done
# gh: authenticated; clones owner/repo from the local bare repository or fails.
cat >"${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\${STUB_LOG_DIR}/gh.log"
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then exit 0; fi
if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
    upstream="${BARE_BASE}/\$3.git"
    [ -d "\$upstream" ] || { echo "gh: repository \$3 not found" >&2; exit 1; }
    exec git clone --quiet "\$upstream" "\$4"
fi
echo "unexpected gh call: \$*" >&2
exit 1
EOF
# git: refuse any network URL so a regression cannot reach out.
REAL_GIT="$(command -v git)"
cat >"${STUB_BIN}/git" <<EOF
#!/usr/bin/env bash
[ -z "\${STUB_LOG_DIR:-}" ] || echo "\${GIT_SSH_COMMAND-unset}" >>"\${STUB_LOG_DIR}/git-ssh.log"
for arg in "\$@"; do
    case "\$arg" in
    http://* | https://* | ssh://* | git@*)
        echo "ERROR: network URL attempted in offline test: \$arg" >&2
        exit 99
        ;;
    esac
done
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${STUB_BIN}"/*

# A repository generated without a devcontainer ships setup:remote (and this test)
# but not the bootstrap script: the sibling-clone scenarios then cannot run, and the
# task is expected to say it skipped the related repos.
HAVE_BOOTSTRAP=0
if [ -f "${REPO_ROOT}/.devcontainer/scripts/bootstrap-related-repos.sh" ]; then
    HAVE_BOOTSTRAP=1
else
    echo "skip: .devcontainer/scripts/bootstrap-related-repos.sh is absent; the sibling-clone scenarios are skipped"
fi

# make_fixture <name> <related-repos.txt content|-> — a git repository standing in
# for a rendered template repo, one directory below a writable parent. The real
# scripts are copied in; the Taskfile is the repository's own (run via -t/-d).
make_fixture() {
    local name="$1" related="$2"
    FIX_PARENT="${TMP}/${name}"
    FIX="${FIX_PARENT}/checkout"
    mkdir -p "${FIX}/scripts" "${FIX}/.devcontainer/scripts"
    git init -q "${FIX}"
    cp "${REPO_ROOT}/scripts/setup-remote.sh" "${FIX}/scripts/setup-remote.sh"
    if [ "$HAVE_BOOTSTRAP" = 1 ]; then
        cp "${REPO_ROOT}/.devcontainer/scripts/bootstrap-related-repos.sh" "${FIX}/.devcontainer/scripts/"
    fi
    printf 'pre-push:\n  commands:\n    noop:\n      run: "true"\n' >"${FIX}/lefthook.yml"
    if [ "$related" != "-" ]; then
        printf '%s\n' "$related" >"${FIX}/.devcontainer/related-repos.txt"
    fi
}

# run_setup <path-dirs> [ENV=val ...] — `task setup:remote` in $FIX; sets rc, OUT, ERR.
run_setup() {
    local pathdirs="$1"
    shift
    rc=0
    OUT="${TMP}/out.txt"
    ERR="${TMP}/err.txt"
    (
        cd "${FIX}"
        export PATH="${pathdirs}"
        export STUB_LOG_DIR="${LOG_DIR}"
        export RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/"
        for kv in "$@"; do export "$kv"; done
        task --silent -t "${REPO_ROOT}/Taskfile.yml" -d "${RUN_DIR:-${FIX}}" setup:remote
    ) >"${OUT}" 2>"${ERR}" || rc=$?
}

# all_output — both streams: task's grouped output folds stderr into stdout.
all_output() { cat "${OUT}" "${ERR}"; }

# grep the captured output files directly: piping a writer into grep -q under
# pipefail can fail on SIGPIPE although the text is present (#1508)
output_has() { grep -q -- "$1" "${OUT}" "${ERR}"; }

# digest <dir> — every path and every file's content, so "changes nothing" means it.
digest() {
    (cd "$1" && find . | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum)
}

# The uncloneable entry comes first so a later entry proves the run continues.
RELATED='test-owner/missing-repo
test-owner/sibling-a # inline comments are ignored
test-owner/existing-repo
test-owner/sibling-b@main'

STUBS_PATH="${STUB_BIN}:${MIN_BIN}"

# --- Scenario 1+2: first run prepares the checkout, second run changes nothing ---
echo "==> task setup:remote prepares a checkout and its siblings"
make_fixture main "$RELATED"
mkdir -p "${FIX_PARENT}/existing-repo"
echo "custom-content" >"${FIX_PARENT}/existing-repo/marker.txt"
rm -f "${LOG_DIR}"/*.log
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "first run must succeed (rc=$rc): $(all_output)"
if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "sibling-a must be cloned into the checkout's parent"
    [ -d "${FIX_PARENT}/sibling-b/.git" ] || fail "sibling-b (listed after the failing entry) must be cloned: the run continues"
    [ ! -e "${FIX_PARENT}/missing-repo" ] || fail "an uncloneable repository must leave nothing behind"
    [ "$(cat "${FIX_PARENT}/existing-repo/marker.txt")" = "custom-content" ] || fail "an existing directory must not be modified"
    [ ! -d "${FIX_PARENT}/existing-repo/.git" ] || fail "an existing directory must not be cloned over"
    [ -z "$(find "${FIX_PARENT}" -name '.bootstrap-*' -print -quit)" ] || fail "no temporary bootstrap directory may survive"
    output_has 'WARNING: failed to clone test-owner/missing-repo' || fail "the uncloneable repository must produce a warning: $(all_output)"
    output_has "Skipping existing-repo" || fail "the existing directory must be reported as skipped"
    output_has "cloned into ${FIX_PARENT}" || fail "the task must print where it cloned"
    output_has 'reference context' || fail "the task must say siblings are reference context"
    output_has 'private to you' || fail "the task must state that the target directory must be private to the user"
    [ -s "${LOG_DIR}/git-ssh.log" ] || fail "expected git to be invoked with GIT_SSH_COMMAND recorded"
    [ "$(sort -u "${LOG_DIR}/git-ssh.log")" = "ssh -oBatchMode=yes" ] || fail "git must run with GIT_SSH_COMMAND=\"ssh -oBatchMode=yes\" (so an ssh remote cannot prompt), got: $(sort -u "${LOG_DIR}/git-ssh.log")"
    output_has "session's own repository" || fail "the task must say siblings cannot be pushed from Claude Code on the web"
else
    output_has 'is not present in this repository' || fail "without the bootstrap script the task must report the related repos as skipped: $(all_output)"
    [ -z "$(find "${FIX_PARENT}" -mindepth 1 -maxdepth 1 ! -name checkout ! -name existing-repo -print -quit)" ] || fail "nothing may be cloned without the bootstrap script"
fi

echo "==> .git/hooks/pre-push is the lefthook shim"
[ -x "${FIX}/.git/hooks/pre-push" ] || fail "pre-push must be installed and executable"
grep -q 'lefthook' "${FIX}/.git/hooks/pre-push" || fail "pre-push must be the lefthook shim"

echo "==> a second run succeeds and changes nothing"
before="$(digest "${FIX_PARENT}")"
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "second run must succeed (rc=$rc): $(all_output)"
after="$(digest "${FIX_PARENT}")"
[ "$before" = "$after" ] || fail "the second run changed the tree:
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
[ "$(wc -l <"${LOG_DIR}/lefthook.log" | tr -d ' ')" -eq 2 ] || fail "lefthook install must run on each invocation (idempotent, not skipped)"

# --- Frozen dependency installs, only for lockfiles that exist ---
echo "==> dependencies install frozen from the lockfiles that exist"
make_fixture deps -
touch "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock"
rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/*.ci
run_setup "${STUBS_PATH}" CI=false # an inherited CI=false must not let pnpm prompt
[ "$rc" -eq 0 ] || fail "deps run must succeed (rc=$rc): $(all_output)"
grep -qx 'install --frozen-lockfile' "${LOG_DIR}/pnpm.log" || fail "pnpm must install --frozen-lockfile"
grep -qx 'sync --frozen' "${LOG_DIR}/uv.log" || fail "uv must sync --frozen"
[ "$(cat "${LOG_DIR}/pnpm.ci")" = "true" ] || fail "pnpm must receive CI=true whatever was inherited, got: $(cat "${LOG_DIR}/pnpm.ci")"
[ "$(cat "${LOG_DIR}/uv.ci")" = "true" ] || fail "uv must receive CI=true whatever was inherited, got: $(cat "${LOG_DIR}/uv.ci")"
output_has 'no .devcontainer/related-repos.txt' || fail "a missing related-repos.txt must be reported as skipped"

echo "==> no lockfile means no dependency install"
make_fixture nodeps -
rm -f "${LOG_DIR}"/*.log
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "no-lockfile run must succeed (rc=$rc): $(all_output)"
[ ! -e "${LOG_DIR}/pnpm.log" ] && [ ! -e "${LOG_DIR}/uv.log" ] || fail "pnpm/uv must not run without a lockfile"
[ -z "$(find "${FIX_PARENT}" -mindepth 1 -maxdepth 1 ! -name checkout -print -quit)" ] || fail "without related-repos.txt nothing may be created beside the checkout"

if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    # --- A checkout entered through a symlink still gets its siblings beside the real one ---
    echo "==> a symlinked checkout clones siblings beside the real checkout"
    make_fixture symlinked "test-owner/sibling-a"
    mkdir -p "${TMP}/linkdir"
    ln -s "${FIX}" "${TMP}/linkdir/checkout-link"
    RUN_DIR="${TMP}/linkdir/checkout-link" run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "symlinked run must succeed (rc=$rc): $(all_output)"
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "siblings must land beside the real checkout ($(ls -A "${FIX_PARENT}"))"
    [ -z "$(find "${TMP}/linkdir" -mindepth 1 -maxdepth 1 ! -name checkout-link -print -quit)" ] || fail "nothing may be cloned beside the symlink"

    # --- A caller's own GIT_SSH_COMMAND is left alone ---
    echo "==> an existing GIT_SSH_COMMAND is preserved"
    make_fixture sshcmd "test-owner/sibling-a"
    rm -f "${LOG_DIR}/git-ssh.log"
    run_setup "${STUBS_PATH}" "GIT_SSH_COMMAND=ssh -i /custom/key"
    [ "$rc" -eq 0 ] || fail "custom GIT_SSH_COMMAND run must succeed (rc=$rc): $(all_output)"
    [ "$(sort -u "${LOG_DIR}/git-ssh.log")" = "ssh -i /custom/key" ] || fail "a caller's GIT_SSH_COMMAND must not be overwritten, got: $(sort -u "${LOG_DIR}/git-ssh.log")"

    # --- A non-writable parent is skipped, not reported as a clone ---
    echo "==> a non-writable parent is reported as skipped and nothing is cloned"
    make_fixture readonly "test-owner/sibling-a"
    chmod 555 "${FIX_PARENT}"
    if [ -w "${FIX_PARENT}" ]; then
        chmod 755 "${FIX_PARENT}"
        echo "skip: the parent is writable despite chmod 555 (running as root); non-writable-parent scenario skipped"
    else
        rm -f "${LOG_DIR}"/*.log
        run_setup "${STUBS_PATH}"
        chmod 755 "${FIX_PARENT}"
        [ "$rc" -eq 0 ] || fail "a non-writable parent is a skip, not a failure (rc=$rc): $(all_output)"
        output_has '^  - related repos: .*is not writable' || fail "the related repos must be listed under Skipped: $(all_output)"
        ! output_has '^  + related repos' || fail "a non-writable parent must not be reported as Ran: $(all_output)"
        [ ! -e "${LOG_DIR}/gh.log" ] || fail "the bootstrap must not run against a non-writable parent"
        [ ! -e "${FIX_PARENT}/sibling-a" ] || fail "nothing may be cloned into a non-writable parent"
    fi
fi

# --- A tool that is missing is skipped, not a failure ---
echo "==> a missing lefthook is reported and the run continues"
make_fixture nolefthook -
run_setup "${MIN_BIN}" # no lefthook on PATH
[ "$rc" -eq 0 ] || fail "a missing lefthook is a skip, not a failure (rc=$rc): $(all_output)"
output_has 'lefthook is not on PATH' || fail "a missing lefthook must be reported as skipped: $(all_output)"
[ ! -e "${FIX}/.git/hooks/pre-push" ] || fail "no pre-push shim can exist without lefthook"

# --- Every config name lefthook itself searches for counts ---
echo "==> lefthook config detection covers every name lefthook searches"
for cfg in lefthook.yml lefthook.yaml lefthook.toml lefthook.json .lefthook.yml .lefthook.yaml .lefthook.toml .lefthook.json; do
    make_fixture "cfg-${cfg}" -
    rm -f "${FIX}/lefthook.yml" "${FIX}/lefthook.yaml"
    : >"${FIX}/${cfg}"
    rm -f "${LOG_DIR}/lefthook.log"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "${cfg}: run must succeed (rc=$rc): $(all_output)"
    [ -s "${LOG_DIR}/lefthook.log" ] || fail "${cfg} must count as a lefthook config (lefthook install was not run)"
done
make_fixture cfg-none -
rm -f "${FIX}/lefthook.yml" "${LOG_DIR}/lefthook.log"
run_setup "${STUBS_PATH}"
[ ! -e "${LOG_DIR}/lefthook.log" ] || fail "without any lefthook config, lefthook install must not run"
output_has 'no lefthook config' || fail "a missing lefthook config must be reported as skipped"

# --- A step that could run and failed is a non-zero exit, and later steps still run ---
echo "==> a failing lefthook fails the task but the related repos are still cloned"
make_fixture failing "test-owner/sibling-a"
run_setup "${STUBS_PATH}" STUB_LEFTHOOK=fail
[ "$rc" -ne 0 ] || fail "a failed lefthook install must produce a non-zero exit"
output_has 'lefthook install failed' || fail "the failure must be named: $(all_output)"
if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "later steps must still run after a failed step"
fi

# --- Real lefthook, when the host has it: the shim is the genuine article ---
if [ -n "${REAL_LEFTHOOK}" ]; then
    echo "==> the real lefthook installs its pre-push shim"
    make_fixture reallefthook -
    mkdir -p "${TMP}/real-bin"
    ln -sf "${REAL_LEFTHOOK}" "${TMP}/real-bin/lefthook"
    # npm's lefthook is a Node entry point (#!/usr/bin/env node), unlike the
    # Homebrew or Go binary, so the minimal PATH must still reach node. Without
    # it this case fails wherever lefthook comes from npm, as in the
    # sync-harmon-devkit job.
    node_bin="$(command -v node 2>/dev/null || true)"
    [ -n "${node_bin}" ] && ln -sf "${node_bin}" "${TMP}/real-bin/node"
    run_setup "${MIN_BIN}:${TMP}/real-bin"
    [ "$rc" -eq 0 ] || fail "real lefthook run must succeed (rc=$rc): $(all_output)"
    grep -qi 'lefthook' "${FIX}/.git/hooks/pre-push" || fail "real lefthook must install its pre-push shim"
    before="$(digest "${FIX}/.git/hooks")"
    run_setup "${MIN_BIN}:${TMP}/real-bin"
    [ "$rc" -eq 0 ] || fail "second real lefthook run must succeed (rc=$rc)"
    [ "$before" = "$(digest "${FIX}/.git/hooks")" ] || fail "the second real lefthook run changed the hooks"
else
    echo "==> (lefthook is not installed on this host; the real-shim check is skipped)"
fi

echo "test-setup-remote.sh passed"
