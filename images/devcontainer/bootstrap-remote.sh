#!/usr/bin/env bash
# bootstrap-remote.sh — provision a stock Ubuntu 24.04 VM with the same
# toolchain, from the same pins, that the shared devcontainer image installs.
#
# THE INVARIANT: every tool this installs is installed by the same script, from
# the same pin, that images/devcontainer/Dockerfile uses. It declares no
# version of its own; scripts/test-bootstrap-remote.sh fails if it ever does.
# Bumping a version in images/devcontainer/versions.env therefore updates the
# devcontainer and every remote environment together.
#
# This is the ONLY remote setup script. Each platform adapter's setup step is a
# one-line call to it at a pinned harmon-init release tag — never a
# platform-specific copy. See docs/architecture/remote-environments.md.
#
#   sudo ./images/devcontainer/bootstrap-remote.sh                  # from a checkout
#   curl -fsSL "$raw/vX.Y.Z/images/devcontainer/bootstrap-remote.sh" \
#     | sudo bash -s -- --ref vX.Y.Z                                # standalone
#
# Properties, each asserted by scripts/test-bootstrap-remote.sh or the
# remote-bootstrap CI job:
#   - idempotent: a second run installs nothing and exits 0;
#   - non-interactive, amd64 and arm64, runs as root or through sudo;
#   - needs neither Docker nor Homebrew;
#   - never installs 1Password (`op`), Homebrew, or Tailscale;
#   - wins PATH precedence for its own pins, so the pinned mikefarah yq v4
#     beats a pre-provisioned /usr/bin/yq (the Python yq), and sets a UTF-8
#     locale, because a POSIX one makes NBSP stop reading as whitespace.
set -euo pipefail

readonly HARMON_REPO_RAW="https://raw.githubusercontent.com/evanharmon1/harmon-init"

# The files this script needs when it was fetched on its own (the piped
# one-liner), relative to images/devcontainer/. Kept equal to what is actually
# on disk by scripts/test-bootstrap-remote.sh, so adding a tier script cannot
# leave the standalone path silently fetching an incomplete set.
readonly HARMON_REMOTE_ASSETS="
versions.env
install/lib.sh
install/apt-core.sh
install/install-core.sh
install/install-agents.sh
install/install-browsers.sh
install/install-posture.sh
"

# Tiers in dependency order. core installs Node, uv and npm, which agents and
# browsers both need, so the order is canonical here rather than taken from the
# caller's spelling.
readonly HARMON_TIER_ORDER="core agents browsers"
readonly HARMON_DEFAULT_TIERS="core,agents"

# Never installed, here or by anything this calls. 1Password and Tailscale are
# credential-bearing and a shared remote VM must not hold either; Homebrew is a
# second, unpinned package manager that would defeat the whole invariant.
readonly HARMON_NEVER_INSTALL="op brew tailscale tailscaled"

die() {
    printf 'bootstrap-remote: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
usage: bootstrap-remote.sh [--tiers core,agents,browsers] [--ref <git-ref>] [--help]

  --tiers   Comma-separated tiers to install. Default: core,agents.
            core     the dev-loop gate (Node, uv, task, lefthook, gh, yq,
                     shellcheck, shfmt, actionlint, yamllint, hadolint,
                     gitleaks, lychee, jq, copier, semgrep, markdownlint-cli2,
                     and Ubuntu's packaged git)
            agents   the Codex CLI at the shared image's pin
            browsers Playwright Chromium (opt-in; large)
  --ref     harmon-init ref to fetch the install scripts from when this script
            was fetched on its own. Ignored when they sit beside it.
            Also settable as HARMON_INIT_REF.

Environment: HARMON_PREFIX (default /usr/local), HARMON_BOOTSTRAP_TIERS.
USAGE
}

tiers="${HARMON_BOOTSTRAP_TIERS:-$HARMON_DEFAULT_TIERS}"
ref="${HARMON_INIT_REF:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
    --tiers)
        [ "$#" -ge 2 ] || die "--tiers needs a value"
        tiers="$2"
        shift 2
        ;;
    --tiers=*)
        tiers="${1#--tiers=}"
        shift
        ;;
    --ref)
        [ "$#" -ge 2 ] || die "--ref needs a value"
        ref="$2"
        shift 2
        ;;
    --ref=*)
        ref="${1#--ref=}"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown argument: $1 (try --help)" ;;
    esac
done

for tier in $(printf '%s' "$tiers" | tr ',' ' '); do
    case " ${HARMON_TIER_ORDER} " in
    *" ${tier} "*) ;;
    *) die "unknown tier '${tier}' (known: ${HARMON_TIER_ORDER// /, })" ;;
    esac
done
case ",${tiers}," in
*,core,*) ;;
*) die "the core tier is the base every other tier builds on; it cannot be skipped" ;;
esac

# ---------- privilege ----------
# Requiring root rather than sprinkling `sudo` through the install scripts: the
# scripts are shared with a Docker build that has no sudo at all, and a
# half-privileged run that installs some tools and fails on others is worse
# than one that refuses up front.
if [ "$(id -u)" -ne 0 ]; then
    if [ -r "${BASH_SOURCE[0]}" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E -- bash "${BASH_SOURCE[0]}" --tiers "$tiers" ${ref:+--ref "$ref"}
    fi
    die "must run as root; pipe into 'sudo bash' or re-run under sudo"
fi

# ---------- locate the install scripts ----------
self_dir=""
if [ -r "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

fetched_dir=""
cleanup() {
    [ -n "$fetched_dir" ] && rm -rf "$fetched_dir"
    return 0
}
trap cleanup EXIT

if [ -n "$self_dir" ] && [ -r "${self_dir}/install/lib.sh" ]; then
    asset_dir="$self_dir"
    printf '==> using the install scripts beside this file (%s)\n' "$asset_dir"
else
    [ -n "$ref" ] || die "the install scripts are not beside this file; pass --ref <harmon-init tag> so they can be fetched from a pinned release"
    fetched_dir="$(mktemp -d)"
    asset_dir="$fetched_dir"
    printf '==> fetching the install scripts from harmon-init %s\n' "$ref"
    for asset in $HARMON_REMOTE_ASSETS; do
        mkdir -p "$(dirname "${asset_dir}/${asset}")"
        curl -fsSL --retry 3 --retry-delay 2 \
            "${HARMON_REPO_RAW}/${ref}/images/devcontainer/${asset}" \
            -o "${asset_dir}/${asset}" ||
            die "could not fetch ${asset} at ref ${ref}"
    done
    chmod 0755 "${asset_dir}"/install/*.sh
fi

export HARMON_VERSIONS_FILE="${asset_dir}/versions.env"
[ -r "$HARMON_VERSIONS_FILE" ] || die "versions file not found: $HARMON_VERSIONS_FILE"

# shellcheck source=./install/lib.sh
. "${asset_dir}/install/lib.sh"

change_log="$(mktemp)"
export HARMON_CHANGE_LOG="$change_log"

# ---------- locale ----------
# The remote VM's locale is POSIX with LANG unset (observed 2026-09-27), and a
# C locale stops NBSP reading as whitespace — which silently changes what the
# title checkers in this toolchain accept. /etc/environment is read by PAM for
# every session; the profile.d drop-in covers login shells that bypass it.
set_locale() {
    local marker="LANG=C.UTF-8"
    if [ -f /etc/environment ]; then
        if grep -q '^LANG=' /etc/environment; then
            sed -i "s|^LANG=.*|${marker}|" /etc/environment
        else
            printf '%s\n' "$marker" >>/etc/environment
        fi
    else
        printf '%s\n' "$marker" >/etc/environment
    fi
    install -d -m 0755 /etc/profile.d
    cat >/etc/profile.d/harmon-remote-env.sh <<'PROFILE'
# Installed by harmon-init images/devcontainer/bootstrap-remote.sh.
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
# The pinned toolchain lives in /usr/local/bin and must outrank a
# pre-provisioned /usr/bin copy (notably the Python yq).
case ":${PATH}:" in
*:/usr/local/bin:*) ;;
*) export PATH="/usr/local/bin:${PATH}" ;;
esac
PROFILE
    chmod 0644 /etc/profile.d/harmon-remote-env.sh
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
}
set_locale

case ":${PATH}:" in
*":${HARMON_BIN}:"*) ;;
*) export PATH="${HARMON_BIN}:${PATH}" ;;
esac

# ---------- install ----------
"${asset_dir}/install/apt-core.sh"
for tier in $HARMON_TIER_ORDER; do
    case ",${tiers}," in
    *",${tier},"*)
        printf '\n'
        "${asset_dir}/install/install-${tier}.sh"
        ;;
    esac
done
printf '\n'
# Always last: every tool a posture might reference is on PATH by now.
"${asset_dir}/install/install-posture.sh"

# ---------- verify what the tiers promised ----------
printf '\n==> verifying\n'

for forbidden in $HARMON_NEVER_INSTALL; do
    [ ! -e "${HARMON_BIN}/${forbidden}" ] ||
        die "${HARMON_BIN}/${forbidden} exists — the bootstrap must never install ${forbidden}"
done
if [ -d /home/linuxbrew ] || [ -d /opt/homebrew ]; then
    die "a Homebrew prefix exists — the bootstrap must never install Homebrew"
fi

yq_path="$(command -v yq || true)"
[ "$yq_path" = "${HARMON_BIN}/yq" ] ||
    die "yq resolves to '${yq_path:-nothing}', not ${HARMON_BIN}/yq — the pinned mikefarah yq v4 lost PATH precedence"
yq --version 2>&1 | grep -q 'mikefarah' ||
    die "yq at ${HARMON_BIN}/yq is not mikefarah yq: $(yq --version 2>&1)"

case "${LANG:-}" in
*UTF-8 | *utf8) ;;
*) die "LANG is '${LANG:-unset}', not a UTF-8 locale" ;;
esac

changes="$(grep -c . "$change_log" 2>/dev/null || true)"
rm -f "$change_log"
printf '\n==> bootstrap complete: tiers %s, %s change(s) applied\n' "$tiers" "${changes:-0}"
printf 'HARMON_BOOTSTRAP_CHANGES=%s\n' "${changes:-0}"
