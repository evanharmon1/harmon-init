#!/usr/bin/env bash
# lib.sh — shared helpers for the install scripts the shared devcontainer image
# and bootstrap-remote.sh both run.
#
# Sourced, never executed. Every function is written to be safe to re-run: the
# bootstrap's idempotence requirement (running it twice is a no-op the second
# time) is met here rather than in each caller, so a new tool cannot forget it.
#
# Portability: bash 3.2 and Linux coreutils only — no `mapfile`, no `grep -P`.

# shellcheck shell=bash

harmon_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARMON_INSTALL_DIR="$harmon_lib_dir"
export HARMON_VERSIONS_FILE="${HARMON_VERSIONS_FILE:-$(dirname "$harmon_lib_dir")/versions.env}"

# Where binaries land. /usr/local/bin precedes /usr/bin in the default PATH on
# both Debian/Ubuntu and the devcontainer base, which is what lets the pinned
# mikefarah yq v4 win over a pre-provisioned /usr/bin/yq (the Python yq).
export HARMON_PREFIX="${HARMON_PREFIX:-/usr/local}"
export HARMON_BIN="${HARMON_BIN:-${HARMON_PREFIX}/bin}"

# uv installs its tools system-wide. `export` rather than a command-prefix
# assignment: a `VAR=x cmd1 && cmd2` prefix applies to cmd1 only, so every tool
# after the first would silently install under the invoking user's ~/.local.
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-${HARMON_BIN}}"
export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/uv-tools}"

harmon_log() { printf '==> %s\n' "$*"; }

# harmon_changed / harmon_skip — the idempotence record.
#
# The bootstrap must be a no-op on a second run, and "exited 0 again" does not
# prove that: a script that re-downloaded and re-installed everything also
# exits 0. So every install site calls exactly one of these, and
# bootstrap-remote.sh counts the `harmon_changed` lines. A second run reporting
# a non-zero count is the failure, and CI asserts the count rather than the
# exit status. HARMON_CHANGE_LOG is set by the bootstrap; when a script is run
# directly (the Dockerfile does exactly that) the counter is simply absent.
harmon_changed() {
    printf '==> %s\n' "$*"
    [ -n "${HARMON_CHANGE_LOG:-}" ] && printf '%s\n' "$*" >>"$HARMON_CHANGE_LOG"
    return 0
}
harmon_skip() { printf '    (already at the pinned version) %s\n' "$*"; }

harmon_die() {
    printf 'harmon-install: %s\n' "$*" >&2
    exit 1
}

harmon_load_versions() {
    [ -f "$HARMON_VERSIONS_FILE" ] || harmon_die "versions file not found: $HARMON_VERSIONS_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$HARMON_VERSIONS_FILE"
    set +a
}

# harmon_arch — normalise to the two architectures this toolchain supports.
harmon_arch() {
    case "${TARGETARCH:-$(uname -m)}" in
    amd64 | x86_64) echo amd64 ;;
    arm64 | aarch64) echo arm64 ;;
    *) harmon_die "unsupported architecture: ${TARGETARCH:-$(uname -m)}" ;;
    esac
}

# harmon_pick <amd64-value> <arm64-value>
harmon_pick() {
    case "$(harmon_arch)" in
    amd64) printf '%s' "$1" ;;
    arm64) printf '%s' "$2" ;;
    esac
}

# harmon_fetch <url> <destination>
# Retries because a remote VM reaches these hosts through an egress proxy.
harmon_fetch() {
    curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused "$1" -o "$2" ||
        harmon_die "download failed: $1"
}

# harmon_verify_sha256 <file> <expected-hex>
harmon_verify_sha256() {
    [ -n "${2:-}" ] || harmon_die "no checksum supplied for $1"
    printf '%s  %s\n' "$2" "$1" | sha256sum --check --status ||
        harmon_die "checksum mismatch for $1 (expected $2)"
}

# harmon_installed_version <command> <version-command...>
# Prints the first dotted version triple the tool reports, or nothing.
harmon_installed_version() {
    _hiv_cmd="$1"
    shift
    command -v "$_hiv_cmd" >/dev/null 2>&1 || return 0
    "$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' | head -1
}

# harmon_at_version <command> <wanted> <version-command...>
# True when the tool is already installed at exactly the pinned version AND
# resolves from the prefix we install into. The second half matters on a
# pre-provisioned VM: a /usr/bin copy at the same version is still the wrong
# one, because a later bump would leave it shadowing nothing we control.
harmon_at_version() {
    _hav_cmd="$1"
    _hav_want="$2"
    shift 2
    [ "$(command -v "$_hav_cmd" 2>/dev/null)" = "${HARMON_BIN}/${_hav_cmd}" ] || return 1
    [ "$(harmon_installed_version "$_hav_cmd" "$@")" = "$_hav_want" ]
}

# harmon_install_bin <source-file> <installed-name>
harmon_install_bin() {
    install -d -m 0755 "$HARMON_BIN"
    install -m 0755 "$1" "${HARMON_BIN}/$2"
}

# harmon_tmpdir_init — create HARMON_TMPDIR and remove it when the calling
# script exits.
#
# Sets a variable instead of printing the path, because a helper called as
# `dir="$(harmon_tmpdir)"` runs in a SUBSHELL: its EXIT trap fires the moment
# the substitution closes, so the caller is handed a directory that has already
# been deleted. Caught by the first image build of this refactor
# (`curl: (23) Failure writing output to destination`), which is exactly the
# shape of failure that is easy to misread as a network fault.
harmon_tmpdir_init() {
    HARMON_TMPDIR="$(mktemp -d)"
    export HARMON_TMPDIR
    trap 'rm -rf "$HARMON_TMPDIR"' EXIT
}

# harmon_npm_global <package> <version> <command>
# npm's own idempotence is a network round-trip even when nothing changes, so
# check the installed version first.
harmon_npm_global() {
    if [ "$(harmon_installed_version "$3" "$3" --version)" = "$2" ]; then
        harmon_skip "${1}@${2}"
        return 0
    fi
    harmon_changed "npm install -g ${1}@${2}"
    npm install -g "${1}@${2}"
}

# harmon_uv_tool <package> <version> <command>
harmon_uv_tool() {
    if harmon_at_version "$3" "$2" "$3" --version; then
        harmon_skip "$1==$2"
        return 0
    fi
    harmon_changed "uv tool install ${1}==${2}"
    uv tool install --force "${1}==${2}"
}

# harmon_cleanup_caches — download caches are pure residue: build layers the
# image ships, and disk pressure on a small VM. Neither environment reads them
# again, and doing it here rather than in the Dockerfile keeps the two paths
# identical.
harmon_cleanup_caches() {
    rm -rf "${HOME:-/root}/.cache/uv"
    command -v npm >/dev/null 2>&1 && npm cache clean --force >/dev/null 2>&1
    return 0
}
