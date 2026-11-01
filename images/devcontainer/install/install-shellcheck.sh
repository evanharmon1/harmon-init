#!/usr/bin/env bash
# The same checksum-verified ShellCheck install for the image, bootstrap and
# per-session reconciliation. All pins come from HARMON_VERSIONS_FILE.
# shellcheck disable=SC2154
set -euo pipefail
# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harmon_load_versions
harmon_ensure_bin
harmon_tmpdir_init

if harmon_needs shellcheck "$SHELLCHECK_VERSION" shellcheck --version; then
    shellcheck_arch="$(harmon_pick x86_64 aarch64)"
    shellcheck_sha="$(harmon_pick "$shellcheck_amd64_sha256" "$shellcheck_arm64_sha256")"
    shellcheck_tarball="shellcheck-v${SHELLCHECK_VERSION}.linux.${shellcheck_arch}.tar.xz"
    harmon_fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${shellcheck_tarball}" \
        "${HARMON_TMPDIR}/${shellcheck_tarball}"
    harmon_verify_sha256 "${HARMON_TMPDIR}/${shellcheck_tarball}" "$shellcheck_sha"
    tar -xJf "${HARMON_TMPDIR}/${shellcheck_tarball}" -C "$HARMON_TMPDIR" \
        "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
    # Verify in staging, before the atomic publication replaces the old tool.
    staged="${HARMON_TMPDIR}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
    reported="$("$staged" --version)"
    [ "$(printf '%s\n' "$reported" | sed -n 's/^version: //p')" = "$SHELLCHECK_VERSION" ] ||
        harmon_die "downloaded shellcheck does not report ${SHELLCHECK_VERSION}"
    harmon_install_bin "$staged" shellcheck
fi
