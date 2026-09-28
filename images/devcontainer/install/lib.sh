#!/usr/bin/env bash
# lib.sh — shared helpers for the install scripts the shared devcontainer image
# and bootstrap-remote.sh both run.
#
# Sourced, never executed. Every function is written to be safe to re-run: the
# bootstrap's idempotence requirement (a second run performs no NEW installs
# and changes no PINNED tool version; apt packages are unpinned and converge on
# the archive, so an upgrade there is reported as a change) is met here rather
# than in each caller, so a new tool cannot forget it.
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

# Every download in this toolchain uses these options. They were duplicated at
# each inline `curl … | tar` call site, which had already drifted: those four
# omitted --retry-connrefused, so a remote VM whose egress proxy refused a
# connection failed where harmon_fetch would have retried. One array, one
# behaviour.
# shellcheck disable=SC2034  # read by the install scripts that source this file
HARMON_CURL_OPTS=(-fsSL --retry 3 --retry-delay 2 --retry-connrefused)

harmon_log() { printf '==> %s\n' "$*"; }

# The run record. One line per event, `<kind><TAB><text>`, appended to
# HARMON_CHANGE_LOG by every install site — across the tier scripts, which run
# as separate processes, so a file rather than a variable. Three kinds:
#   install  a new install, or a pinned tool moved to its pin;
#   upgrade  an unpinned apt package that converged on the archive;
#   tool     `name=version` for every pinned tool a tier installed OR verified.
# bootstrap-remote.sh counts the first two separately (a second run must show
# zero installs; upgrades are legitimate and reported) and serialises the third
# as the manifest, so the manifest is what the tiers did rather than a list
# kept beside them. "Exited 0 again" proves none of this: a script that
# re-downloaded everything also exits 0. When a script runs with no record
# (the Dockerfile runs them directly) the helpers only print.
harmon_record() {
    [ -n "${HARMON_CHANGE_LOG:-}" ] && printf '%s\t%s\n' "$1" "$2" >>"$HARMON_CHANGE_LOG"
    return 0
}
harmon_changed() {
    printf '==> %s\n' "$*"
    harmon_record install "$*"
}
harmon_upgraded() {
    printf '==> %s\n' "$*"
    harmon_record upgrade "$*"
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
    curl "${HARMON_CURL_OPTS[@]}" "$1" -o "$2" ||
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

# harmon_needs <command> <version> <version-command...>
# The one decision every pinned install makes: true when <command> must be
# installed (not at <version>, or not resolving from HARMON_BIN), false when it
# is already right. Records `<command>=<version>` either way, so a tool is in
# the manifest exactly when a tier installed or verified it, and prints the
# install/skip line so a call site is `if harmon_needs …; then <install>; fi`.
harmon_needs() {
    harmon_record tool "$1=$2"
    if harmon_at_version "$1" "$2" "${@:3}"; then
        harmon_skip "$1 $2"
        return 1
    fi
    harmon_changed "$1 $2"
}

# harmon_ensure_bin — the install prefix's bin directory exists.
#
# Called once per tier. harmon_install_bin creates it on demand, but the
# `curl … | tar -xz -C "$HARMON_BIN"` installs cannot: tar fails outright on a
# missing directory. /usr/local/bin exists on every real target, so this only
# ever bites a non-default HARMON_PREFIX — which is exactly the case where
# half the tier would install and half would not.
harmon_ensure_bin() {
    install -d -m 0755 "$HARMON_BIN"
}

# harmon_install_bin <source-file> <installed-name>
harmon_install_bin() {
    harmon_ensure_bin
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
# decide first — through harmon_needs, like every other pinned tool: a same
# version under a pre-provisioned prefix is still not ours.
harmon_npm_global() {
    if harmon_needs "$3" "$2" "$3" --version; then
        npm install -g "${1}@${2}"
    fi
}

# harmon_uv_tool <package> <version> <command>
harmon_uv_tool() {
    if harmon_needs "$3" "$2" "$3" --version; then
        uv tool install --force "${1}==${2}"
    fi
}

# harmon_cleanup_caches — download caches are pure residue: build layers the
# image ships, and disk pressure on a small VM. Neither environment reads them
# again, and doing it here rather than in the Dockerfile keeps the two paths
# identical. Scoped to the RUNNING user's own home from the passwd database,
# never to an inherited HOME: root must not delete a caller's ~/.npm.
harmon_cleanup_caches() {
    _hcc_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    _hcc_home="${_hcc_home:-${HOME:-/root}}"
    rm -rf "${_hcc_home}/.cache/uv"
    command -v npm >/dev/null 2>&1 && HOME="$_hcc_home" npm cache clean --force >/dev/null 2>&1
    return 0
}
