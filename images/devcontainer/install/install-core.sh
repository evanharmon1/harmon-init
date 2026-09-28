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
harmon_tmpdir_init
tmp="$HARMON_TMPDIR"

# ---------- Node.js (checksum-pinned nodejs.org tarball) ----------
# Installed under ${HARMON_PREFIX} so it wins PATH precedence over a
# pre-provisioned /usr/bin/node (the remote VM ships Node 22).
if harmon_at_version node "$NODE_VERSION" node --version; then
    harmon_skip "node ${NODE_VERSION}"
else
    node_arch="$(harmon_pick x64 arm64)"
    node_sha="$(harmon_pick "$node_amd64_sha256" "$node_arm64_sha256")"
    node_tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
    harmon_changed "node ${NODE_VERSION} (${node_arch})"
    harmon_fetch "https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}" "${tmp}/${node_tarball}"
    harmon_verify_sha256 "${tmp}/${node_tarball}" "$node_sha"
    # --no-same-owner: the tarball records nodejs.org's build uid/gid, which
    # exists on no machine this runs on.
    tar -xJf "${tmp}/${node_tarball}" -C "$HARMON_PREFIX" \
        --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
    rm -f "${tmp}/${node_tarball}"
fi
# corepack is bundled with the tarball; enabling pnpm is idempotent.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable pnpm

# ---------- uv (checksum-pinned GitHub release) ----------
if harmon_at_version uv "$UV_VERSION" uv --version; then
    harmon_skip "uv ${UV_VERSION}"
else
    uv_arch="$(harmon_pick x86_64 aarch64)"
    uv_sha="$(harmon_pick "$uv_amd64_sha256" "$uv_arm64_sha256")"
    uv_tarball="uv-${uv_arch}-unknown-linux-gnu.tar.gz"
    harmon_changed "uv ${UV_VERSION} (${uv_arch})"
    harmon_fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_tarball}" \
        "${tmp}/${uv_tarball}"
    harmon_verify_sha256 "${tmp}/${uv_tarball}" "$uv_sha"
    tar -xzf "${tmp}/${uv_tarball}" -C "$tmp" --strip-components=1 \
        "uv-${uv_arch}-unknown-linux-gnu/uv" "uv-${uv_arch}-unknown-linux-gnu/uvx"
    harmon_install_bin "${tmp}/uv" uv
    harmon_install_bin "${tmp}/uvx" uvx
    rm -f "${tmp}/${uv_tarball}" "${tmp}/uv" "${tmp}/uvx"
fi

# ---------- checksum-free GitHub release binaries ----------
# These mirror the shared image's long-standing install shape exactly: the
# upstream projects publish no stable per-asset digest this repository has
# reviewed, so the pin is the release tag. Changing that is a separate
# decision from moving the installs, and moving the installs is this file's job.
if harmon_at_version task "$TASK_VERSION" task --version; then
    harmon_skip "task ${TASK_VERSION}"
else
    harmon_changed "task ${TASK_VERSION}"
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${arch}.tar.gz" |
        tar -xz -C "$HARMON_BIN" task
fi

if harmon_at_version lefthook "$LEFTHOOK_VERSION" lefthook version; then
    harmon_skip "lefthook ${LEFTHOOK_VERSION}"
else
    harmon_changed "lefthook ${LEFTHOOK_VERSION}"
    harmon_fetch \
        "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_Linux_$(harmon_pick x86_64 arm64)" \
        "${tmp}/lefthook"
    harmon_install_bin "${tmp}/lefthook" lefthook
fi

if harmon_at_version gh "$GH_VERSION" gh --version; then
    harmon_skip "gh ${GH_VERSION}"
else
    harmon_changed "gh ${GH_VERSION}"
    gh_dir="gh_${GH_VERSION}_linux_${arch}"
    harmon_fetch \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_dir}.tar.gz" \
        "${tmp}/gh.tar.gz"
    tar -xzf "${tmp}/gh.tar.gz" -C "$tmp" "${gh_dir}/bin/gh"
    harmon_install_bin "${tmp}/${gh_dir}/bin/gh" gh
    rm -rf "${tmp}/gh.tar.gz" "${tmp}/${gh_dir}"
fi

# mikefarah yq v4. On a pre-provisioned VM /usr/bin/yq is the *Python* yq and
# shadows this one under a PATH that puts /usr/bin first; installing into
# ${HARMON_BIN} is what wins, and bootstrap-remote.sh asserts the resolution.
if harmon_at_version yq "$YQ_VERSION" yq --version; then
    harmon_skip "yq ${YQ_VERSION}"
else
    harmon_changed "yq ${YQ_VERSION}"
    harmon_fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}" \
        "${tmp}/yq"
    harmon_install_bin "${tmp}/yq" yq
fi

if harmon_at_version shfmt "$SHFMT_VERSION" shfmt --version; then
    harmon_skip "shfmt ${SHFMT_VERSION}"
else
    harmon_changed "shfmt ${SHFMT_VERSION}"
    harmon_fetch \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${arch}" \
        "${tmp}/shfmt"
    harmon_install_bin "${tmp}/shfmt" shfmt
fi

if harmon_at_version actionlint "$ACTIONLINT_VERSION" actionlint -version; then
    harmon_skip "actionlint ${ACTIONLINT_VERSION}"
else
    harmon_changed "actionlint ${ACTIONLINT_VERSION}"
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" |
        tar -xz -C "$HARMON_BIN" actionlint
fi

if harmon_at_version hadolint "$HADOLINT_VERSION" hadolint --version; then
    harmon_skip "hadolint ${HADOLINT_VERSION}"
else
    harmon_changed "hadolint ${HADOLINT_VERSION}"
    harmon_fetch \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-$(harmon_pick x86_64 arm64)" \
        "${tmp}/hadolint"
    harmon_install_bin "${tmp}/hadolint" hadolint
fi

if harmon_at_version gitleaks "$GITLEAKS_VERSION" gitleaks version; then
    harmon_skip "gitleaks ${GITLEAKS_VERSION}"
else
    harmon_changed "gitleaks ${GITLEAKS_VERSION}"
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_$(harmon_pick x64 arm64).tar.gz" |
        tar -xz -C "$HARMON_BIN" gitleaks
fi

if harmon_at_version lychee "$LYCHEE_VERSION" lychee --version; then
    harmon_skip "lychee ${LYCHEE_VERSION}"
else
    harmon_changed "lychee ${LYCHEE_VERSION}"
    lychee_arch="$(harmon_pick x86_64 aarch64)"
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${lychee_arch}-unknown-linux-gnu.tar.gz" |
        tar -xz --strip-components=1 -C "$HARMON_BIN" \
            "lychee-${lychee_arch}-unknown-linux-gnu/lychee"
fi

# ---------- Python tools (uv) and Node tools (npm) ----------
harmon_uv_tool semgrep "$SEMGREP_VERSION" semgrep
harmon_uv_tool copier "$COPIER_VERSION" copier
harmon_npm_global markdownlint-cli2 "$MARKDOWNLINT_CLI2_VERSION" markdownlint-cli2

harmon_cleanup_caches
harmon_log "core tier complete"
