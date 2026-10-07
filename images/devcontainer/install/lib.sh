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

# The system trust store the package managers are pointed at (harmon_npm_global,
# harmon_uv_tool). Debian/Ubuntu's ca-certificates keeps it current, the apt
# tier installs that package, and it is where a platform adds its proxy's CA.
# Overridable so a test can exercise the present and absent cases.
HARMON_SYSTEM_CA_BUNDLE="${HARMON_SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# Node ships its own CA roots, so every Node process — npm, and the tools it
# installs, like Playwright's browser download — trusts the system store only
# when told to. Behind a platform's TLS-intercepting proxy that store holds the
# proxy's CA and nothing else survives `sudo`. Node reads this at process start
# and every tier script sources this file; a caller's own value wins, and an
# empty one names nothing.
if [ -z "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "$HARMON_SYSTEM_CA_BUNDLE" ]; then
    export NODE_EXTRA_CA_CERTS="$HARMON_SYSTEM_CA_BUNDLE"
fi

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

# The non-fatal counterpart of harmon_die, and the tier scripts' counterpart of
# bootstrap-remote.sh's `warn`, which this mirrors exactly as harmon_die mirrors
# that file's `die`: the tiers run as their own processes, so that file's helper
# is not in scope here. For a condition the run must REPORT and cannot fix — a
# pre-provisioned tool shadowing ours on PATH being the case this repository
# already handles this way.
harmon_warn() {
    printf 'harmon-install: WARNING: %s\n' "$*" >&2
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
# Prints the first dotted version triple the tool reports, and SUCCEEDS only
# when the tool actually answered.
#
# THE RULE, stated here because this is the shared place every pinned tool comes
# through: a read that can fail is not an answer until it has succeeded. The
# probe used to be the last stage of a pipeline (`<probe> | grep | head`), whose
# status is its LAST command's, so a binary that printed the pinned version and
# exited nonzero — a broken dynamic link, a missing runtime, a half-installed
# node — was read as healthy, recorded in the manifest, and skipped on every
# later run. The probe's own exit status is therefore taken FIRST, separately
# from parsing what it said, and a failed probe fails the function: the caller
# has to be able to tell "it says 9.9.9" from "it could not say".
harmon_installed_version() {
    _hiv_cmd="$1"
    shift
    command -v "$_hiv_cmd" >/dev/null 2>&1 || return 1
    _hiv_out="$("$@" 2>/dev/null)" || return 1
    # The PARSE, by contrast, is allowed to come back empty and still succeed.
    # A tool that answered but said nothing version-shaped is a MISMATCH, which
    # the caller's comparison already handles, and failing here would conflate
    # "the tool is broken" with "its output format changed". The `|| true` is
    # also what keeps a SIGPIPE off the probe's account: `head -1` closes the
    # pipe while grep may still be writing, and for a banner larger than a pipe
    # buffer grep really does die of it — which under pipefail would reinstall a
    # perfectly healthy tool on every run. A short multi-version banner fits the
    # buffer and never signals, so this is the case a test has to provoke
    # deliberately rather than stumble on (test-bootstrap-remote.sh § 22).
    printf '%s\n' "$_hiv_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' | head -1 || true
}

# harmon_at_version <command> <wanted> <version-command...>
# True when the tool is already installed at exactly the pinned version AND
# resolves from the prefix we install into. The second half matters on a
# pre-provisioned VM: a /usr/bin copy at the same version is still the wrong
# one, because a later bump would leave it shadowing nothing we control.
#
# The conjunction is three-way, not two: the probe must have SUCCEEDED as well
# as matched. Substituting the helper's output inside `[ … = … ]` discarded its
# status, which is the same defect one layer up — so the status is captured on
# its own line where `||` can act on it, and no call site has to remember.
#
# Today the helper also prints nothing when it fails, so the comparison alone
# would reinstall anyway and this `|| return 1` is belt as well as braces. It
# stays because that is a property of the helper's current body, not a contract:
# a later edit that printed a partial parse before failing would make the
# comparison the only thing standing between a broken tool and the manifest. The
# rule is stated where the decision is made.
harmon_at_version() {
    _hav_cmd="$1"
    _hav_want="$2"
    shift 2
    [ "$(command -v "$_hav_cmd" 2>/dev/null)" = "${HARMON_BIN}/${_hav_cmd}" ] || return 1
    _hav_seen="$(harmon_installed_version "$_hav_cmd" "$@")" || return 1
    [ "$_hav_seen" = "$_hav_want" ]
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

# harmon_have_bins <name>...
# True when every name is present and executable in HARMON_BIN.
#
# The file test, not `command -v`: PATH can resolve a name to some OTHER copy
# on the machine, and what a block publishes is the copy in its own prefix.
# `-x` follows symlinks, which is what makes this usable for Node — npm, npx
# and corepack are relative symlinks into ../lib/node_modules, so a dangling
# one reads as not executable and the block reinstalls.
harmon_have_bins() {
    for _hhb_name in "$@"; do
        [ -x "${HARMON_BIN}/${_hhb_name}" ] || return 1
    done
    return 0
}

# harmon_needs_all <command> <version> <also>... -- <version-command...>
# harmon_needs for a block that publishes MORE THAN ONE executable.
#
# A version number is not proof that a block finished. A first install copies a
# staged tree into the prefix piece by piece, so an interruption can publish the
# version witness while the siblings beside it are still missing — after which
# harmon_needs reads the new version, skips the block on every later run, and
# the run dies on the missing sibling instead of repairing it. Same shape when a
# block extracts two binaries and the gate consults one: the prefix keeps the
# pinned witness and never regains the other. So the decision is the CONJUNCTION
# of the two properties: <command> at <version> from HARMON_BIN (the existing
# comparison, unchanged) AND every <also> present and executable there. Either
# half failing re-runs the block, which is what makes the damage repairable.
#
# <also> is every OTHER executable the block publishes; `--` ends that list and
# the rest is the version command, exactly as harmon_needs takes it. Records and
# prints what harmon_needs records and prints, so a call site stays
# `if harmon_needs_all …; then <install>; fi` and the manifest is unaffected.
harmon_needs_all() {
    _hna_cmd="$1"
    _hna_want="$2"
    shift 2
    _hna_also=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        _hna_also+=("$1")
        shift
    done
    [ "${1:-}" = "--" ] ||
        harmon_die "harmon_needs_all ${_hna_cmd}: no -- separating the companion list from the version command"
    shift
    [ "${#_hna_also[@]}" -gt 0 ] ||
        harmon_die "harmon_needs_all ${_hna_cmd}: no companion executable named — use harmon_needs for a lone binary"
    [ "$#" -gt 0 ] || harmon_die "harmon_needs_all ${_hna_cmd}: no version command"
    harmon_record tool "${_hna_cmd}=${_hna_want}"
    if harmon_at_version "$_hna_cmd" "$_hna_want" "$@" && harmon_have_bins "${_hna_also[@]}"; then
        harmon_skip "$_hna_cmd $_hna_want"
        return 1
    fi
    harmon_changed "$_hna_cmd $_hna_want"
}

# harmon_writer_alive <pid> — true when a process with that pid exists, and true
# also when the question cannot be answered.
#
# /proc rather than `kill -0`: kill reports the same failure for "no such
# process" and "not permitted to signal it", so a staging file belonging to a
# LIVE writer running as another user would read as reapable. Anything
# unanswerable — no procfs, a field that is not a pid — counts as alive, because
# the cost of keeping a stale file is disk and the cost of a wrong answer is
# deleting the bytes a concurrent writer is mid-way through staging, which is the
# exact race the pid in the name exists to prevent. A recycled pid keeps a stale
# file around longer; it never deletes a live one.
harmon_writer_alive() {
    case "${1:-}" in
    '' | *[!0-9]*) return 0 ;;
    esac
    [ -d /proc ] || return 0
    [ -d "/proc/$1" ]
}

# harmon_reap_staging — remove staging files whose writer is GONE.
#
# Putting the pid in the staging name closed the interleave race between two
# concurrent runs and, on its own, made every abandoned staging file permanently
# unreapable: a later run has a different pid, and a tool already at the pin is
# skipped without ever reaching harmon_install_bin — so an interrupted bootstrap
# left a full-size hidden executable in the prefix forever, on exactly the small
# VMs this toolchain targets. Reaping by LIVENESS rather than by age or by name
# alone keeps both properties at once: an abandoned file goes, and a live
# concurrent writer's file is never touched. Run from harmon_ensure_bin, which
# every tier calls whether or not it installs anything, so the sweep is not
# conditional on the very install that was skipped.
harmon_reap_staging() {
    for _hrs_file in "${HARMON_BIN}"/.*.harmon-staging; do
        [ -f "$_hrs_file" ] || continue # an unmatched glob, or a stray directory
        _hrs_pid="${_hrs_file%.harmon-staging}"
        _hrs_pid="${_hrs_pid##*.}"
        harmon_writer_alive "$_hrs_pid" || rm -f "$_hrs_file"
    done
    return 0
}

# harmon_ensure_bin — the install prefix's bin directory exists, and carries no
# staging file left behind by a writer that is gone.
#
# Called once per tier, and by harmon_install_bin on demand. /usr/local/bin
# exists on every real target, so the directory half only ever bites a
# non-default HARMON_PREFIX — which is exactly the case where half the tier would
# install and half would not.
harmon_ensure_bin() {
    install -d -m 0755 "$HARMON_BIN"
    harmon_reap_staging
}

# harmon_install_bin <source-file> <installed-name>
#
# The LAST step of every binary install, and the only thing that touches the
# live path. install(1) copies into its destination, so a copy that dies
# part-way leaves a truncated executable where a working tool was; the copy
# therefore lands beside the live path and a same-directory rename — atomic on
# every filesystem this runs on — puts it in place. The live path is always
# the old binary or the new one, never a fragment of either, and a binary that
# is currently executing is replaced rather than hitting "text file busy".
#
# The staging name carries the PID as well as the tool name. A name derived
# from the tool alone is shared by every process installing that tool, so two
# runs on one VM would write the same staging file and each could rename the
# other's half-written copy into place — the one thing this function exists to
# prevent. With the pid the name identifies the WRITER, so what a run renames
# is always the bytes it staged itself; the rename stays a same-directory
# rename, which is the atomicity invariant and is unchanged.
#
# Either step failing removes THIS run's staging path before it dies: a writer
# that is about to stop existing should not leave a file only a liveness sweep
# can clean up, and the sweep is the fallback for the interruptions no handler
# sees (a kill, a power loss), not the routine path.
harmon_install_bin() {
    harmon_ensure_bin
    _hib_stage="${HARMON_BIN}/.${2}.$$.harmon-staging"
    if ! install -m 0755 "$1" "$_hib_stage"; then
        rm -f "$_hib_stage"
        harmon_die "could not stage $2 into ${HARMON_BIN}"
    fi
    if ! mv -f "$_hib_stage" "${HARMON_BIN}/$2"; then
        rm -f "$_hib_stage"
        harmon_die "could not publish $2 into ${HARMON_BIN}"
    fi
}

# harmon_install_archive_bin <url> <installed-name> <member> [sha256]
#
# THE path an archive-packaged binary takes into HARMON_BIN: download to
# staging, verify when the pin carries a digest, extract IN staging, and hand
# the one member to harmon_install_bin last. Never `curl … | tar -C
# "$HARMON_BIN"`: a stream that dies mid-archive has already truncated the
# live tool it was replacing, and the tool stays broken until the next run
# (scripts/test-bootstrap-remote.sh refuses that pattern anywhere in these
# scripts). <member> is the archive path of the binary; its basename is what
# lands in staging. tar detects the compression itself, so .tar.gz and .tar.xz
# take the same call. --no-same-owner: release archives record the publisher's
# build uid, which exists on no machine this runs on.
harmon_install_archive_bin() {
    _hiab_url="$1"
    _hiab_name="$2"
    _hiab_member="$3"
    _hiab_sha="${4:-}"
    _hiab_stage="${HARMON_TMPDIR:?harmon_tmpdir_init must run before harmon_install_archive_bin}/${_hiab_name}.stage"
    rm -rf "$_hiab_stage"
    mkdir -p "$_hiab_stage"
    harmon_fetch "$_hiab_url" "${_hiab_stage}/archive"
    [ -z "$_hiab_sha" ] || harmon_verify_sha256 "${_hiab_stage}/archive" "$_hiab_sha"
    tar -xf "${_hiab_stage}/archive" -C "$_hiab_stage" --no-same-owner "$_hiab_member"
    [ -f "${_hiab_stage}/${_hiab_member}" ] ||
        harmon_die "${_hiab_member} did not extract from ${_hiab_url}"
    harmon_install_bin "${_hiab_stage}/${_hiab_member}" "$_hiab_name"
    rm -rf "$_hiab_stage"
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
# version under a pre-provisioned prefix is still not ours. Trusts the system CA
# store through the NODE_EXTRA_CA_CERTS export near the top of this file.
harmon_npm_global() {
    if harmon_needs "$3" "$2" "$3" --version; then
        npm install -g "${1}@${2}"
    fi
}

# harmon_uv_tool <package> <version> <command>
# uv bundles its own CA roots too: --system-certs loads the system store the way
# curl already does, so a platform VM's TLS-intercepting proxy (whose CA is
# seeded there, and nothing else survives `sudo`) does not fail the install with
# UnknownIssuer. The older spelling --native-tls is a deprecated alias.
harmon_uv_tool() {
    if harmon_needs "$3" "$2" "$3" --version; then
        uv tool install --force --system-certs "${1}==${2}"
    fi
}

# harmon_cleanup_caches — download caches are pure residue: build layers the
# image ships, and disk pressure on a small VM. Neither environment reads them
# again, and doing it here rather than in the Dockerfile keeps the two paths
# identical. Scoped to the RUNNING user's own home from the passwd database,
# never to an inherited HOME: root must not delete a caller's ~/.npm.
# `|| true` for the same reason as the bootstrap's own getent sites: under
# pipefail a passwd miss (getent exits 2) would abort the script before the
# fallback on the next line runs.
harmon_cleanup_caches() {
    _hcc_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
    _hcc_home="${_hcc_home:-${HOME:-/root}}"
    rm -rf "${_hcc_home}/.cache/uv"
    command -v npm >/dev/null 2>&1 && HOME="$_hcc_home" npm cache clean --force >/dev/null 2>&1
    return 0
}
