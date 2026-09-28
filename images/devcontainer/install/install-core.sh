#!/usr/bin/env bash
# install-core.sh — the CORE tier: the dev-loop gate.
#
# Run identically by images/devcontainer/Dockerfile and by bootstrap-remote.sh.
# Every version comes from versions.env; this file declares no pin of its own
# (scripts/test-bootstrap-remote.sh enforces that).
#
# Every host contacted here is on the remote adapter's documented allowlist
# (docs/architecture/remote-environments.md): GitHub release assets,
# nodejs.org, registry.npmjs.org, pypi.org and archive.ubuntu.com. In
# particular Node does NOT come from deb.nodesource.com and uv does NOT come
# from astral.sh — both are denied on the Claude Code on the web VM.
# The *_sha256 values come from versions.env via harmon_load_versions; the
# linter cannot follow that indirect source, so exempt the whole file rather
# than each use site.
# shellcheck disable=SC2154
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harmon_load_versions

arch="$(harmon_arch)"
harmon_ensure_bin
harmon_tmpdir_init
tmp="$HARMON_TMPDIR"

# ---------- Node.js (checksum-pinned nodejs.org tarball) ----------
# Installed under ${HARMON_PREFIX} so it wins PATH precedence over a
# pre-provisioned /usr/bin/node (the remote VM ships Node 22).
#
# The gate names npm, npx and corepack as well as node: this block publishes
# four executables and node's version alone is no evidence the other three
# landed. See harmon_needs_all in lib.sh, and the copy-order note below for the
# half the ordering already covers.
if harmon_needs_all node "$NODE_VERSION" npm npx corepack -- node --version; then
    node_arch="$(harmon_pick x64 arm64)"
    node_sha="$(harmon_pick "$node_amd64_sha256" "$node_arm64_sha256")"
    node_tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
    harmon_fetch "https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}" "${tmp}/${node_tarball}"
    harmon_verify_sha256 "${tmp}/${node_tarball}" "$node_sha"
    # Extracted into a staging directory (transient disk: one extra copy of
    # the tarball's contents until the copy below finishes) and copied into
    # the prefix only once the whole tarball is out, so an interrupted
    # extraction leaves the prefix untouched. The copy order matters too:
    # bin/ goes LAST because bin/node is what the gate reads as the version
    # witness and bin/npm is a relative symlink into ../lib/node_modules. lib/
    # first means the symlink's target exists the moment bin/ lands, and a copy
    # that dies before bin/ leaves the OLD node (or none) in place, so the next
    # run redoes the install instead of skipping a new node beside a dangling
    # npm. What the ordering cannot cover is an interruption INSIDE this last
    # copy, which can publish bin/node while bin/npm is still missing: on a
    # FIRST install there is no old node for the version comparison to catch,
    # and the run would then skip the block for good and die later on the
    # missing npm. That half is the gate's companion list above, not this loop.
    # --no-same-owner: the tarball records nodejs.org's build uid/gid, which
    # exists on no machine this runs on.
    node_stage="${tmp}/node-${NODE_VERSION}"
    mkdir -p "$node_stage"
    tar -xJf "${tmp}/${node_tarball}" -C "$node_stage" \
        --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
    [ -x "${node_stage}/bin/node" ] || harmon_die "the Node tarball did not extract completely"
    for node_dir in lib include share bin; do
        [ -d "${node_stage}/${node_dir}" ] || continue
        install -d -m 0755 "${HARMON_PREFIX}/${node_dir}"
        cp -a "${node_stage}/${node_dir}/." "${HARMON_PREFIX}/${node_dir}/"
    done
    rm -rf "$node_stage" "${tmp}/${node_tarball}"
fi
# corepack is bundled with the tarball. `corepack enable` rewrites its shims
# every time it runs, so gate it on pnpm already resolving from OUR prefix — a
# /usr/bin/pnpm on a pre-provisioned host is not the shim this creates.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
if [ "$(command -v pnpm 2>/dev/null)" = "${HARMON_BIN}/pnpm" ]; then
    harmon_skip "corepack pnpm shim"
else
    harmon_changed "corepack enable pnpm"
    corepack enable pnpm
fi

# ---------- uv (checksum-pinned GitHub release) ----------
# The gate names uvx as well as uv: the tarball carries both and repository
# operations invoke uvx directly (the Semgrep and Foreman wrappers), so a prefix
# holding the pinned uv without uvx would skip this block for good and leave the
# toolchain unusable while the bootstrap reported success.
if harmon_needs_all uv "$UV_VERSION" uvx -- uv --version; then
    uv_arch="$(harmon_pick x86_64 aarch64)"
    uv_sha="$(harmon_pick "$uv_amd64_sha256" "$uv_arm64_sha256")"
    uv_tarball="uv-${uv_arch}-unknown-linux-gnu.tar.gz"
    harmon_fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_tarball}" \
        "${tmp}/${uv_tarball}"
    harmon_verify_sha256 "${tmp}/${uv_tarball}" "$uv_sha"
    tar -xzf "${tmp}/${uv_tarball}" -C "$tmp" --strip-components=1 \
        "uv-${uv_arch}-unknown-linux-gnu/uv" "uv-${uv_arch}-unknown-linux-gnu/uvx"
    # uvx before uv, for the reason bin/ is copied last above: uv is the version
    # witness, so publishing it last means an interruption always leaves a
    # version the gate rejects rather than a pinned uv beside a stale uvx.
    harmon_install_bin "${tmp}/uvx" uvx
    harmon_install_bin "${tmp}/uv" uv
    rm -f "${tmp}/${uv_tarball}" "${tmp}/uv" "${tmp}/uvx"
fi

# ---------- checksum-free GitHub release binaries ----------
# The upstream projects publish no stable per-asset digest this repository has
# reviewed, so the pin is the release tag. Changing that is a separate decision
# from how the installs are done, and how they are done is one path: a bare
# binary goes harmon_fetch → harmon_install_bin, an archived one goes through
# harmon_install_archive_bin. Both stage first and touch the live path last,
# so an interrupted install leaves the previous tool working (lib.sh).
if harmon_needs task "$TASK_VERSION" task --version; then
    harmon_install_archive_bin \
        "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${arch}.tar.gz" \
        task task
fi

if harmon_needs lefthook "$LEFTHOOK_VERSION" lefthook version; then
    harmon_fetch \
        "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_Linux_$(harmon_pick x86_64 arm64)" \
        "${tmp}/lefthook"
    harmon_install_bin "${tmp}/lefthook" lefthook
fi

if harmon_needs gh "$GH_VERSION" gh --version; then
    gh_dir="gh_${GH_VERSION}_linux_${arch}"
    harmon_install_archive_bin \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_dir}.tar.gz" \
        gh "${gh_dir}/bin/gh"
fi

# mikefarah yq v4. On a pre-provisioned VM /usr/bin/yq is the *Python* yq and
# shadows this one under a PATH that puts /usr/bin first; installing into
# ${HARMON_BIN} is what wins, and bootstrap-remote.sh asserts the resolution.
if harmon_needs yq "$YQ_VERSION" yq --version; then
    harmon_fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}" \
        "${tmp}/yq"
    harmon_install_bin "${tmp}/yq" yq
fi

if harmon_needs shfmt "$SHFMT_VERSION" shfmt --version; then
    harmon_fetch \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${arch}" \
        "${tmp}/shfmt"
    harmon_install_bin "${tmp}/shfmt" shfmt
fi

if harmon_needs actionlint "$ACTIONLINT_VERSION" actionlint -version; then
    harmon_install_archive_bin \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
        actionlint actionlint
fi

if harmon_needs hadolint "$HADOLINT_VERSION" hadolint --version; then
    harmon_fetch \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-$(harmon_pick x86_64 arm64)" \
        "${tmp}/hadolint"
    harmon_install_bin "${tmp}/hadolint" hadolint
fi

if harmon_needs gitleaks "$GITLEAKS_VERSION" gitleaks version; then
    harmon_install_archive_bin \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_$(harmon_pick x64 arm64).tar.gz" \
        gitleaks gitleaks
fi

if harmon_needs lychee "$LYCHEE_VERSION" lychee --version; then
    lychee_arch="$(harmon_pick x86_64 aarch64)"
    harmon_install_archive_bin \
        "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${lychee_arch}-unknown-linux-gnu.tar.gz" \
        lychee "lychee-${lychee_arch}-unknown-linux-gnu/lychee"
fi

# ---------- Python tools (uv) and Node tools (npm) ----------
harmon_uv_tool semgrep "$SEMGREP_VERSION" semgrep
harmon_uv_tool copier "$COPIER_VERSION" copier
harmon_npm_global markdownlint-cli2 "$MARKDOWNLINT_CLI2_VERSION" markdownlint-cli2

harmon_cleanup_caches
harmon_log "core tier complete"
