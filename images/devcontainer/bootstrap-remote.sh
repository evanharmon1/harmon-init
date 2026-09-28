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
#
#   HARMON_INIT_REF=vX.Y.Z                                           # standalone: the
#   curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
#     | sudo bash -s -- --ref "$HARMON_INIT_REF"                     # tag, written once
#
# The ref must be a release tag (vX.Y.Z). That tag is the trust root of the
# standalone form: the script and everything it fetches come from one tag,
# protected by the release process and branch rules rather than by a per-file
# signature. HARMON_ALLOW_UNPINNED_REF=1 lifts the tag check for CI and
# development only, and says so loudly.
#
# Properties, each asserted by scripts/test-bootstrap-remote.sh or the
# remote-bootstrap CI job:
#   - idempotent, precisely: a second run performs no NEW installs and changes
#     no PINNED tool version (HARMON_BOOTSTRAP_NEW_INSTALLS=0, same manifest);
#     apt packages are unpinned and converge on the archive, and an upgrade
#     there is reported (HARMON_BOOTSTRAP_UPGRADES), never hidden;
#   - non-interactive, amd64 and arm64, runs as root or through sudo — and on
#     EVERY entry path (re-exec, `sudo -E`, the piped `sudo bash -s`) HOME is
#     the running uid's passwd home before a tier runs, so root never writes
#     under a caller's home and never sources a caller's ~/.profile;
#   - needs neither Docker nor Homebrew;
#   - never installs 1Password (`op`), Homebrew, or Tailscale: none may
#     resolve at the end of a run that did not resolve at its start;
#   - puts its own bin directory FIRST on PATH — by order, not membership — in
#     the system profile and its own process, so the pinned mikefarah yq v4
#     beats a pre-provisioned /usr/bin/yq (the Python yq); a user-level shadow
#     (~/.local/bin from a stock ~/.profile) is reported, never fatal. Forces
#     a UTF-8 locale, because a POSIX one makes NBSP stop reading as whitespace;
#   - records what the tiers installed in a manifest of the same shape the
#     image writes, so image and VM can be compared for the same release tag.
set -euo pipefail

readonly HARMON_REPO_RAW="https://raw.githubusercontent.com/evanharmon1/harmon-init"
readonly HARMON_RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

# The files this script needs when it was fetched on its own (the piped
# one-liner), relative to images/devcontainer/. Kept equal to what is actually
# on disk by scripts/test-bootstrap-remote.sh, so adding a tier script cannot
# leave the standalone path silently fetching an incomplete set.
readonly HARMON_REMOTE_ASSETS="
versions.env
generate-manifest.sh
install/lib.sh
install/apt-core.sh
install/install-core.sh
install/install-agents.sh
install/install-browsers.sh
"

# Tiers in dependency order. core installs Node, uv and npm, which agents and
# browsers both need, so the order is canonical here rather than taken from the
# caller's spelling.
readonly HARMON_TIER_ORDER="core agents browsers"
readonly HARMON_DEFAULT_TIERS="core,agents"

# Never installed, here or by anything this calls. 1Password and Tailscale are
# credential-bearing and a shared remote VM must not hold either; Homebrew is a
# second, unpinned package manager that would defeat the whole invariant. The
# second list is where Homebrew would put itself.
readonly HARMON_NEVER_INSTALL="op brew tailscale tailscaled"
readonly HARMON_NEVER_PREFIXES="/home/linuxbrew /opt/homebrew"

die() {
    printf 'bootstrap-remote: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'bootstrap-remote: WARNING: %s\n' "$*" >&2
}

usage() {
    cat <<'USAGE'
usage: bootstrap-remote.sh [--tiers core,agents,browsers] [--ref vX.Y.Z] [--help]

  --tiers   Comma-separated tiers to install. Default: core,agents.
            core     the dev-loop gate (Node, uv, task, lefthook, gh, yq,
                     shellcheck, shfmt, actionlint, yamllint, hadolint,
                     gitleaks, lychee, jq, copier, semgrep, markdownlint-cli2,
                     and Ubuntu's packaged git)
            agents   the Codex CLI at the shared image's pin
            browsers Playwright Chromium (opt-in; large)
  --ref     The harmon-init RELEASE TAG (vX.Y.Z) to fetch the install scripts
            from when this script was fetched on its own; ignored for fetching
            when they sit beside it. Also settable as HARMON_INIT_REF; when
            both are given they must agree. Anything but a release tag is
            refused unless HARMON_ALLOW_UNPINNED_REF=1 (CI and development).

Environment: HARMON_PREFIX (default /usr/local), HARMON_BOOTSTRAP_TIERS,
             HARMON_INIT_REF, HARMON_ALLOW_UNPINNED_REF.
USAGE
}

tiers="${HARMON_BOOTSTRAP_TIERS:-$HARMON_DEFAULT_TIERS}"
ref_env="${HARMON_INIT_REF:-}"
ref_arg=""
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
        ref_arg="$2"
        shift 2
        ;;
    --ref=*)
        ref_arg="${1#--ref=}"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ---------- the ref: one value, release-tag shaped ----------
# Validated before anything else happens (before the tier check, before the
# sudo re-exec) so that a refused ref costs nothing and the offline guard can
# prove the refusal without root.
if [ -n "$ref_env" ] && [ -n "$ref_arg" ] && [ "$ref_env" != "$ref_arg" ]; then
    die "--ref '${ref_arg}' and HARMON_INIT_REF '${ref_env}' disagree; the tag must be written once"
fi
ref="${ref_arg:-$ref_env}"
if [ -n "$ref" ] && ! printf '%s' "$ref" | grep -Eq "$HARMON_RELEASE_TAG_RE"; then
    if [ "${HARMON_ALLOW_UNPINNED_REF:-}" = "1" ]; then
        warn "ref '${ref}' is not a release tag; proceeding because HARMON_ALLOW_UNPINNED_REF=1 (CI and development only — an adapter must pin a vX.Y.Z tag)"
    else
        die "ref '${ref}' is not a release tag (vX.Y.Z). The standalone bootstrap fetches its install scripts from that tag, which is the trust root; a branch would take an untested toolchain the moment anything merged. Set HARMON_ALLOW_UNPINNED_REF=1 to override in CI or development."
    fi
fi

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
# The re-exec hands root an EXPLICIT environment, not `-E`: tiers and ref
# travel as arguments, and the HARMON_* variables read from the environment
# only when set. HOME is deliberately NOT set here — the block after this one
# sets it for every entry path, and this is only one of them.
if [ "$(id -u)" -ne 0 ]; then
    if [ -r "${BASH_SOURCE[0]}" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -- env \
            ${HARMON_PREFIX+"HARMON_PREFIX=${HARMON_PREFIX}"} \
            ${HARMON_ALLOW_UNPINNED_REF+"HARMON_ALLOW_UNPINNED_REF=${HARMON_ALLOW_UNPINNED_REF}"} \
            bash "${BASH_SOURCE[0]}" --tiers "$tiers" ${ref:+--ref "$ref"}
    fi
    die "must run as root; pipe into 'sudo bash' or re-run under sudo"
fi

# ---------- HOME: the running uid's, on every entry path ----------
# Root is established, but WHOSE home root has is decided by how it got here:
# the re-exec above arrives with root's, while `sudo -E` (measured:
# `sudo -nE bash -c 'echo $(id -u) $HOME'` → `0 /home/vscode`) and the piped
# `sudo bash -s` arrive already root with the CALLER's HOME. Everything below
# reads HOME — npm's ~/.npm, uv's ~/.cache, the login-shell locale probe that
# sources ~/.profile — so a caller's HOME here means root-owned files under an
# unprivileged user's home and that user's ~/.profile executed as uid 0. One
# rule, applied once, before any tier: HOME is the running uid's passwd home.
# The INVOKING user is still known through SUDO_USER; the shadow check near
# the end uses it on purpose, and runs AS that user.
# The `|| true` is load-bearing: under pipefail a getent miss (exit 2 — a
# container uid with no passwd entry) fails the substitution and, under `-e`,
# the script, so the `:-/root` on the next line would never run. Fixed once
# (challenge r1-7), reintroduced by round 4, refixed (r5-5); every getent
# substitution below carries the same guard, and test-bootstrap-remote.sh
# checks for it.
HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
export HOME="${HOME:-/root}"

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
    [ -n "$ref" ] || die "the install scripts are not beside this file; pass --ref <harmon-init release tag> so they can be fetched from a pinned release"
    fetched_dir="$(mktemp -d)"
    asset_dir="$fetched_dir"
    printf '==> fetching the install scripts from harmon-init %s\n' "$ref"
    # Every URL is built from the ONE validated ref above.
    for asset in $HARMON_REMOTE_ASSETS; do
        mkdir -p "$(dirname "${asset_dir}/${asset}")"
        curl -fsSL --retry 3 --retry-delay 2 \
            "${HARMON_REPO_RAW}/${ref}/images/devcontainer/${asset}" \
            -o "${asset_dir}/${asset}" ||
            die "could not fetch ${asset} at ref ${ref}"
    done
    chmod 0755 "${asset_dir}"/install/*.sh "${asset_dir}/generate-manifest.sh"
fi

export HARMON_VERSIONS_FILE="${asset_dir}/versions.env"
[ -r "$HARMON_VERSIONS_FILE" ] || die "versions file not found: $HARMON_VERSIONS_FILE"

# shellcheck source=./install/lib.sh
. "${asset_dir}/install/lib.sh"

# The run record (lib.sh: `<kind><TAB><text>` lines).
change_log="$(mktemp)"
export HARMON_CHANGE_LOG="$change_log"
tab="$(printf '\t')"

# ---------- locale and PATH ----------
# The remote VM's locale is POSIX with LANG unset (observed 2026-09-27), and a
# C locale stops NBSP reading as whitespace — which silently changes what the
# title checkers in this toolchain accept. /etc/environment is read by PAM for
# every session; the profile.d drop-in covers login shells that bypass it.
# Both writes are conditional on the content actually differing. Rewriting a
# byte-identical file is not a change the install counter should report, but it
# does churn mtime and inode on two system files every single run — which is
# exactly what configuration-drift tooling watches. "The second run changed
# nothing" should be true of the filesystem, not only of the counter.
readonly HARMON_PROFILE_DROPIN=/etc/profile.d/harmon-remote-env.sh

# ensure_environment_line <key> <value> — /etc/environment carries KEY=VALUE,
# rewriting an existing KEY= line (whatever its value or quoting) and appending
# when absent.
ensure_environment_line() {
    local key="$1" want="$1=$2"
    if [ ! -f /etc/environment ]; then
        printf '%s\n' "$want" >/etc/environment
    elif grep -qx "$want" /etc/environment; then
        : # already exactly right; leave the file alone
    elif grep -q "^${key}=" /etc/environment; then
        sed -i "s|^${key}=.*|${want}|" /etc/environment
    else
        printf '%s\n' "$want" >>/etc/environment
    fi
}

set_locale() {
    local tmp
    ensure_environment_line LANG C.UTF-8
    # A pre-existing LC_ALL=C overrides LANG for every category, so a UTF-8
    # LANG beside it changes nothing. Rewrite it when present; never add one.
    if grep -q '^LC_ALL=' /etc/environment 2>/dev/null; then
        ensure_environment_line LC_ALL C.UTF-8
    fi

    install -d -m 0755 /etc/profile.d
    tmp="$(mktemp)"
    # ${HARMON_BIN} is interpolated now; everything else is escaped so it stays
    # for the login shell to expand. The prefix is configurable
    # (HARMON_PREFIX), and a drop-in that hardcoded /usr/local/bin left a
    # custom prefix working only until this process exited — the next login
    # could not find its own tools. POSIX sh, not bash: /etc/profile.d is read
    # by whatever the login shell is.
    cat >"$tmp" <<PROFILE
# Installed by harmon-init images/devcontainer/bootstrap-remote.sh.
# Forced, not defaulted: a pre-existing LC_ALL=C (the POSIX-locale trap)
# overrides LANG and must not survive into the session.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# The pinned toolchain lives in ${HARMON_BIN} and must come FIRST on PATH.
# Membership is not enough: a pre-provisioned /usr/bin copy (notably the
# Python yq) ahead of it still wins. Remove every existing occurrence, then
# prepend.
harmon_remote_env_path=""
harmon_remote_env_ifs="\$IFS"
IFS=:
for harmon_remote_env_entry in \$PATH; do
    [ "\$harmon_remote_env_entry" = "${HARMON_BIN}" ] && continue
    harmon_remote_env_path="\${harmon_remote_env_path:+\${harmon_remote_env_path}:}\${harmon_remote_env_entry}"
done
IFS="\$harmon_remote_env_ifs"
export PATH="${HARMON_BIN}\${harmon_remote_env_path:+:\${harmon_remote_env_path}}"
unset harmon_remote_env_path harmon_remote_env_ifs harmon_remote_env_entry
PROFILE
    if ! cmp -s "$tmp" "$HARMON_PROFILE_DROPIN"; then
        install -m 0644 "$tmp" "$HARMON_PROFILE_DROPIN"
    fi
    rm -f "$tmp"
}
set_locale

# This process runs the very drop-in a login shell will, so the PATH order and
# locale the installs and the closing assertions see are the ones a session
# gets — one piece of logic, not two that agree today.
# shellcheck source=/dev/null
. "$HARMON_PROFILE_DROPIN"

# ---------- the never-installed set ----------
# The one invariant, for BOTH lists: nothing forbidden may be present at the
# end of the run that was not present at its start — a command resolving
# anywhere on the PATH the closing check uses, or a package manager's prefix
# existing. Pre-existing ones are reported by path, never fatal: a self-hosted
# VM whose administrator installed Tailscale, or that already carries a
# Homebrew prefix, is not the bootstrap installing either. Commands and
# prefixes share this one predicate and the two loops below, so a list cannot
# be snapshotted at the start and forgotten at the end.
# forbidden_present <command|/prefix> — prints where it is and succeeds;
# prints nothing and fails when absent.
forbidden_present() {
    case "$1" in
    /*) [ -d "$1" ] && printf '%s' "$1" ;;
    *) command -v "$1" 2>/dev/null ;;
    esac
}
never_before=""
for forbidden in $HARMON_NEVER_INSTALL $HARMON_NEVER_PREFIXES; do
    if forbidden_present "$forbidden" >/dev/null; then
        never_before="${never_before} ${forbidden}"
    fi
done

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
# The agent posture (managed Claude Code settings, Codex configuration) is
# #1404's unit, which adds it to the image and to this bootstrap in one change.

# ---------- verify what the tiers promised ----------
printf '\n==> verifying\n'

for forbidden in $HARMON_NEVER_INSTALL $HARMON_NEVER_PREFIXES; do
    found="$(forbidden_present "$forbidden" || true)"
    [ -n "$found" ] || continue
    case " ${never_before} " in
    *" ${forbidden} "*) printf '    (pre-existing, not ours) %s at %s\n' "$forbidden" "$found" ;;
    *) die "${forbidden} is present at ${found} and was not before this run — the bootstrap must never install ${forbidden}" ;;
    esac
done

# PATH precedence, by order, where the bootstrap owns the order: this process
# runs the system drop-in, so yq and task resolving from our bin here proves it.
for tool in yq task; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    [ "$found" = "${HARMON_BIN}/${tool}" ] ||
        die "${tool} resolves to '${found:-nothing}', not ${HARMON_BIN}/${tool} — ${HARMON_PROFILE_DROPIN} did not win PATH precedence"
done
yq --version 2>&1 | grep -q 'mikefarah' ||
    die "yq at ${HARMON_BIN}/yq is not mikefarah yq: $(yq --version 2>&1)"

# What it does NOT own: the invoking user's profile. bash reads ~/.profile after
# /etc/profile, and a stock one puts ~/.local/bin ahead of everything, so a yq
# there shadows the pinned one in that user's login shells and no system file
# can prevent it. Checked in that user's real login shell, AS that user: a
# login shell executes ~/.profile, and running one as root with a user's HOME
# would execute that user's file as uid 0. Without runuser the check is
# skipped and says so; it never falls back to root. Reported, never fatal.
# runuser lives in /usr/sbin, which a caller's PATH need not carry (`sudo -E
# env PATH=/usr/bin:/bin …` hands root exactly that), so it is looked up in
# the sbin directories too rather than skipping the check on a PATH accident.
login_user="${SUDO_USER:-root}"
# `|| true` as on the HOME lookup (r5-5): a SUDO_USER with no passwd entry
# must reach the `:-/root` fallback where login_home is read, not abort here.
login_home="$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6 || true)"
login_uid="$(id -u "$login_user" 2>/dev/null || echo 0)"
runuser_bin="$(command -v runuser 2>/dev/null || true)"
for candidate in /usr/sbin/runuser /sbin/runuser; do
    [ -n "$runuser_bin" ] || [ ! -x "$candidate" ] || runuser_bin="$candidate"
done
if [ "$login_uid" != 0 ] && [ -z "$runuser_bin" ]; then
    printf "    (not checked) %s's login shell: runuser is unavailable, and the check never runs as root with a user's HOME\n" "$login_user"
else
    for tool in yq task; do
        if [ "$login_uid" = 0 ]; then
            found="$(env -i HOME="${login_home:-/root}" USER=root PATH=/usr/bin:/bin bash -lc "command -v ${tool}" 2>/dev/null || true)"
        else
            found="$("$runuser_bin" -u "$login_user" -- env -i HOME="$login_home" USER="$login_user" PATH=/usr/bin:/bin bash -lc "command -v ${tool}" 2>/dev/null || true)"
        fi
        [ "$found" != "${HARMON_BIN}/${tool}" ] || continue
        warn "${login_user}'s login shell resolves ${tool} to '${found:-nothing}', not ${HARMON_BIN}/${tool}: a user-level PATH entry (${found%/*}) shadows the pinned toolchain. Remedy: in ${login_home:-/root}/.profile put ${HARMON_BIN} ahead of ${found%/*}, or remove ${found}."
    done
fi

# The EFFECTIVE locale, not LANG: `locale` reports what LC_CTYPE resolves to
# after LC_ALL and LANG are both applied, so a surviving LC_ALL=C shows here
# where a LANG check would pass. This process, and a login shell seeded with it.
effective_ctype() {
    "$@" 2>/dev/null | sed -n 's/^LC_CTYPE=//p' | tr -d '"'
}
process_ctype="$(effective_ctype locale)"
case "$process_ctype" in
*UTF-8 | *utf8) ;;
*) die "the effective locale is LC_CTYPE='${process_ctype:-unset}', not UTF-8" ;;
esac
login_ctype="$(effective_ctype env -i HOME="$HOME" PATH=/usr/bin:/bin LC_ALL=C bash -lc locale)"
case "$login_ctype" in
*UTF-8 | *utf8) ;;
*) die "a fresh login shell that started with LC_ALL=C still has LC_CTYPE='${login_ctype:-unset}' — ${HARMON_PROFILE_DROPIN} did not force the locale" ;;
esac

# ---------- record what was installed ----------
# The same manifest the image writes (generate-manifest.sh, the same file), so
# "image and VM install identical versions for the same release tag" is a diff
# of two files. Its entries are the record's `tool` lines — every pinned tool a
# tier installed or verified, under the image's keys — so no list here can fall
# out of step with the tiers. The revision is the checkout's commit — suffixed
# `-dirty` when the checkout has uncommitted or untracked changes, so a
# manifest never attests a clean commit for bytes that were not that commit —
# else the release tag the script was fetched from.
manifest_dir="${HARMON_PREFIX}/share/harmon-remote-env"
write_manifest() {
    local revision="" manifest="${manifest_dir}/manifest.json" before=""
    if [ -n "$self_dir" ]; then
        revision="$(git -C "$self_dir" -c safe.directory='*' rev-parse --verify HEAD 2>/dev/null || true)"
        # --no-optional-locks: root reads the caller's checkout without
        # refreshing (rewriting) its index.
        if [ -n "$revision" ] &&
            [ -n "$(git -C "$self_dir" -c safe.directory='*' --no-optional-locks status --porcelain 2>/dev/null)" ]; then
            revision="${revision}-dirty"
        fi
    fi
    if [ -z "$revision" ] && printf '%s' "$ref" | grep -Eq "$HARMON_RELEASE_TAG_RE"; then
        revision="$ref"
    fi
    if [ -z "$revision" ]; then
        warn "no manifest written: the source revision is unknown (not a git checkout, and no release tag). The image-to-VM comparison needs one or the other."
        return 0
    fi
    [ ! -f "$manifest" ] || before="$(cat "$manifest")"
    # shellcheck disable=SC2046  # the record is one name=version token per line
    HARMON_MANIFEST_DIR="$manifest_dir" HARMON_MANIFEST_NAME=harmon-remote-env \
        bash "${asset_dir}/generate-manifest.sh" "$revision" "$(harmon_arch)" \
        $(sed -n "s/^tool${tab}//p" "$change_log")
    if [ "$before" = "$(cat "$manifest")" ]; then
        harmon_skip "manifest ${manifest}"
    else
        harmon_changed "manifest ${manifest} (${revision})"
    fi
}
write_manifest

new_installs="$(grep -c "^install${tab}" "$change_log" || true)"
upgrades="$(grep -c "^upgrade${tab}" "$change_log" || true)"
rm -f "$change_log"
printf '\n==> bootstrap complete: tiers %s, %s new install(s), %s apt upgrade(s)\n' "$tiers" "$new_installs" "$upgrades"
printf 'HARMON_BOOTSTRAP_NEW_INSTALLS=%s\n' "$new_installs"
printf 'HARMON_BOOTSTRAP_UPGRADES=%s\n' "$upgrades"
printf 'HARMON_BOOTSTRAP_CHANGES=%s\n' "$((new_installs + upgrades))"
