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
# call to it at a pinned harmon-init release tag — never a
# platform-specific copy. See docs/architecture/remote-environments.md.
#
#   sudo ./images/devcontainer/bootstrap-remote.sh                  # from a checkout
#
#   # standalone: the tag is written ONCE, and the download is its own command
#   # so a failure stops the chain. Never `curl … | sudo bash`: a pipeline's
#   # status is its LAST command's, so a 404 or a truncated transfer exits 0 —
#   # the adapter reports a successful setup having installed nothing, and a
#   # partial script has already run as root. The script goes into a PRIVATE
#   # directory (`mktemp -d` plus an explicit mode 0700 rather than a trusted
#   # default), never a bare `mktemp` in shared /tmp, which would make /tmp
#   # this script's own directory. That is the SECOND of two independent
#   # reasons root cannot be handed another user's code, and it stays here
#   # precisely because it is no longer the only one: this form passes --ref,
#   # and given a ref the script fetches every asset from that tag and reads
#   # nothing beside itself, so a /tmp/install/lib.sh an unprivileged user
#   # pre-created is never consulted. Nothing removes the directory afterwards
#   # on purpose: a trailing cleanup command would become the chain's exit
#   # status and put the swallowed-failure bug back.
#   HARMON_INIT_REF=vX.Y.Z
#   harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
#     && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
#       -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
#     && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
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
#     image writes, so image and VM can be compared for the same release tag;
#   - installs the agent posture (#1408) from the single checked-in definition
#     in .devcontainer/config/agent/ — read from the same checkout or fetched
#     from the same tag as the tiers, never carried as a copy — and fails the
#     run unless agent-autonomy.sh verify then passes for every destination
#     the run wrote. A destination left in place is not verified; it is
#     counted in HARMON_BOOTSTRAP_POSTURE_GAPS.
set -euo pipefail

readonly HARMON_REPO_RAW="https://raw.githubusercontent.com/evanharmon1/harmon-init"
readonly HARMON_RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
# The system profile drop-in this script owns. Declared here rather than beside
# set_locale because the prefix validation names it, and one path spelled twice
# is a path that will disagree with itself.
readonly HARMON_PROFILE_DROPIN=/etc/profile.d/harmon-remote-env.sh

# The files this script needs when it was fetched on its own (the standalone
# recipe above), relative to images/devcontainer/. Kept equal to what is actually
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

# The agent posture (#1408, docs/decisions/2026-09-29-agent-posture-three-posture-model.md)
# and the one script that installs it, relative to the REPOSITORY ROOT rather
# than to images/devcontainer/: the definition lives only in
# .devcontainer/config/agent/, and this script carries no copy of it. From a
# checkout they are read in place; with --ref they are fetched from the same
# tag as everything else. scripts/test-bootstrap-remote.sh holds this list equal
# to what agent-autonomy.sh reads and fails if any file under images/devcontainer/
# carries a copy of the definition.
readonly HARMON_AGENT_POSTURE_ASSETS="
.devcontainer/agent/agent-autonomy.sh
.devcontainer/config/agent/claude-managed-settings.json
.devcontainer/config/agent/codex-managed-config.toml
.devcontainer/config/agent/harnesses.json
"
# Where the posture is installed: the paths the agent devcontainer installs it
# to, and the ones Claude Code and Codex read as managed (unoverridable) policy.
readonly HARMON_AGENT_CLAUDE_MANAGED=/etc/claude-code/managed-settings.json
readonly HARMON_AGENT_CODEX_MANAGED=/etc/codex/managed_config.toml

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

# check_safe_path <variable-name> <value> — the value is an absolute path this
# script may render into a shell file verbatim, or the run stops naming the
# caller's mistake.
#
# The install prefix is interpolated into /etc/profile.d/harmon-remote-env.sh,
# which this process sources and so does every later login shell on the machine.
# The defect that matters is not injection — whoever sets the prefix already
# runs this as root and could write that file directly — it is CORRUPTION: a
# prefix carrying a quote, a `$`, a backtick or a newline writes a broken
# drop-in and breaks every login shell, persistently, long after the run that
# did it. Refusing such a prefix with a reason is a better outcome than escaping
# it into something that works here and is copied somewhere else.
# SAFE ADMITS an absolute path of ordinary path characters — ASCII letters and
# digits and `. _ - + @ /` — and nothing else. `:` is refused with the rest
# because a colon cannot survive in a PATH entry however carefully it is quoted.
# Matched with a `case` pattern rather than a grep on purpose: grep is
# LINE-oriented, so `printf '%s' "$v" | grep -Eq '^…$'` accepts any value whose
# FIRST line matches — it would have waved through the newline that is the one
# character most certain to corrupt the drop-in.
check_safe_path() {
    local why=""
    case "$2" in
    /*) ;;
    *) why="it is not an absolute path" ;;
    esac
    if [ -z "$why" ]; then
        case "$2" in
        *[!A-Za-z0-9._+@/-]*)
            why="it carries a character outside letters, digits and '. _ - + @ /' — whitespace, a newline, a quote, a '\$', a backtick and ':' are all refused rather than escaped"
            ;;
        esac
    fi
    [ -z "$why" ] ||
        die "${1} '${2}' is not a safe absolute path: ${why}. It is rendered into ${HARMON_PROFILE_DROPIN} verbatim, and that file is sourced by this root process and by every later login shell on the machine, so a value that cannot be written there safely is refused at the door instead of escaped."
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
            and versions.env from. Given a ref, that tag is the ONLY source:
            files sitting beside this script are never read, whatever their
            ownership or mode. Omit it to run the install scripts beside this
            one, which is the form used from a checkout. Also settable as
            HARMON_INIT_REF; when both are given they must agree. Anything but
            a release tag is refused unless HARMON_ALLOW_UNPINNED_REF=1 (CI
            and development).

Every run, whatever the tiers, installs the agent posture from the same
checkout or tag: .devcontainer/config/agent/ to
/etc/claude-code/managed-settings.json and /etc/codex/managed_config.toml,
through .devcontainer/agent/agent-autonomy.sh. Anything already at either
path that is not the definition — a file, or a symlink, dangling or not — is
left in place, reported, and counted in HARMON_BOOTSTRAP_POSTURE_GAPS (the
posture is then not applied for it) unless HARMON_AGENT_POSTURE_REPLACE=1,
which replaces it and keeps the previous entry beside it. Harness executables
are never modified.

Environment: HARMON_PREFIX (default /usr/local), HARMON_BOOTSTRAP_TIERS,
             HARMON_INIT_REF, HARMON_ALLOW_UNPINNED_REF,
             HARMON_AGENT_POSTURE_REPLACE.
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
#
# Matched with bash's `=~` rather than `printf '%s' "$ref" | grep -Eq '^…$'`,
# for the reason check_safe_path states above: grep is LINE-oriented, so the
# pipeline form accepts any value whose FIRST line matches, and
# `v1.2.3<newline>anything` passed the release-tag check. An ERE has no
# multiline mode — `$` anchors the end of the STRING, not of a line — so `=~`
# answers about the whole value. Both single-line values this file validates
# are now validated the same way, rather than one by shape and one by first
# line; the tag reaches a URL and argv rather than a shell string, so the blast
# radius was small, but two idioms for one job is a question waiting to be
# asked. The pattern stays in HARMON_RELEASE_TAG_RE and unquoted on the right
# of `=~`: quoting it there would match it as a literal.
if [ -n "$ref_env" ] && [ -n "$ref_arg" ] && [ "$ref_env" != "$ref_arg" ]; then
    die "--ref '${ref_arg}' and HARMON_INIT_REF '${ref_env}' disagree; the tag must be written once"
fi
ref="${ref_arg:-$ref_env}"
if [ -n "$ref" ] && ! [[ $ref =~ $HARMON_RELEASE_TAG_RE ]]; then
    if [ "${HARMON_ALLOW_UNPINNED_REF:-}" = "1" ]; then
        warn "ref '${ref}' is not a release tag; proceeding because HARMON_ALLOW_UNPINNED_REF=1 (CI and development only — an adapter must pin a vX.Y.Z tag)"
    else
        die "ref '${ref}' is not a release tag (vX.Y.Z). The standalone bootstrap fetches its install scripts from that tag, which is the trust root; a branch would take an untested toolchain the moment anything merged. Set HARMON_ALLOW_UNPINNED_REF=1 to override in CI or development."
    fi
fi

# ---------- the install prefix ----------
# Validated here, beside the ref and for the same reason: before the sudo
# re-exec, so a caller's typo costs nothing and the offline guard can prove the
# refusal without root. BOTH settable values are checked, not only the prefix:
# lib.sh derives HARMON_BIN as `${HARMON_BIN:-${HARMON_PREFIX}/bin}`, so those
# two are its only inputs and checking both is what makes the RENDERED value
# safe by construction — `sudo -E` carries a HARMON_BIN the re-exec never
# forwards, and validating the prefix alone would leave that path open. Only a
# value the caller actually SET is checked; the defaults are lib.sh's, and
# appending `/bin` to an admitted path cannot produce a character that was not.
[ -z "${HARMON_PREFIX:-}" ] || check_safe_path HARMON_PREFIX "$HARMON_PREFIX"
[ -z "${HARMON_BIN:-}" ] || check_safe_path HARMON_BIN "$HARMON_BIN"

# ---------- the tier selection: ONE canonical value ----------
# This used to be a permissive parse followed by a strict one: validation split
# on commas AND whitespace, so `--tiers 'core, agents'` validated cleanly, while
# every later membership check split on commas alone, kept the leading space and
# silently dropped ` agents`. The run then exited 0 reporting a selection it had
# not installed. Two parsers of one string will disagree again, so there is now
# one: `tiers` is REPLACED here by the canonical form, and the install loop, the
# core check and the manifest's tier field all read that single value. The
# canonical form is deduplicated and spelled in HARMON_TIER_ORDER order, so one
# selection always spells itself one way — `--tiers agents,core` and `--tiers
# 'core, agents'` are the same set and say so.
tiers_given="$tiers"
tiers_seen=""
tiers_rest="$tiers_given"
# Space and tab, spelled out. The trim below used `[![:space:]]`, whose meaning
# comes from the ambient locale — and this block runs LONG before set_locale
# forces C.UTF-8, in a file whose own header warns that a change of locale
# changes what counts as whitespace. Moving the canonicalisation after
# set_locale is not the cleaner fix: it runs here on purpose, before the sudo
# re-exec, so a refused selection costs nothing and the offline guard can prove
# the refusal without root — and the re-exec forwards the CANONICAL value. An
# explicit ASCII class instead, so the trim means exactly one thing in every
# environment this runs in.
tier_ws=$' \t'
while :; do
    tier="${tiers_rest%%,*}"
    # Trim surrounding whitespace only. Whitespace INSIDE an element is not
    # trimmed away into a valid tier: `--tiers 'core agents'` is one unknown
    # element and is refused, not silently read as two.
    tier="${tier#"${tier%%[!$tier_ws]*}"}"
    tier="${tier%"${tier##*[!$tier_ws]}"}"
    [ -n "$tier" ] ||
        die "empty tier in --tiers '${tiers_given}' (known: ${HARMON_TIER_ORDER// /, })"
    # Exact equality against each known tier, not `case " $HARMON_TIER_ORDER "
    # in *" $tier "*`: in a case pattern the element is a GLOB and the list is
    # one space-separated string, so `c*` and even `core agents` matched a run
    # of the known names and were accepted as a tier. They were then refused
    # further down for the wrong reason ("core cannot be skipped"), which is the
    # kind of near-miss that becomes a real acceptance the moment the tier list
    # grows a name that is a prefix of another.
    tier_known=0
    for known_tier in $HARMON_TIER_ORDER; do
        if [ "$tier" = "$known_tier" ]; then
            tier_known=1
        fi
    done
    [ "$tier_known" = 1 ] ||
        die "unknown tier '${tier}' in --tiers '${tiers_given}' (known: ${HARMON_TIER_ORDER// /, })"
    tiers_seen="${tiers_seen},${tier},"
    case "$tiers_rest" in
    *,*) tiers_rest="${tiers_rest#*,}" ;;
    *) break ;;
    esac
done
tiers=""
for tier in $HARMON_TIER_ORDER; do
    case "$tiers_seen" in
    *",${tier},"*) tiers="${tiers:+${tiers},}${tier}" ;;
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
            ${HARMON_AGENT_POSTURE_REPLACE+"HARMON_AGENT_POSTURE_REPLACE=${HARMON_AGENT_POSTURE_REPLACE}"} \
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
# TWO sources, and `--ref` decides which — never both, and never a preference
# between them.
#
# WITH a ref, that tag is the only source: every asset is fetched from it into a
# private directory this run made itself, and a file sitting beside this script
# is not read at all, whatever its ownership or mode. That is what makes the
# standalone form's trust root the TAG rather than whichever directory the
# download happened to land in. It replaced an ownership-and-permissions
# predicate on the script's own directory, and deleting the question is a better
# answer than a third attempt at answering it: that predicate checked two
# directories and so could not answer for the path's ancestors (a 0700 directory
# inside a world-writable, non-sticky parent can be swapped out from under it),
# it checked the container rather than the contents (a mode-0666 install/lib.sh
# inside a private directory passed), and it left a window between the check and
# the `source` for the very swap it was looking for. None of those has anywhere
# to land once the directory is never consulted.
#
# WITHOUT a ref the caller ran this file out of a checkout — the documented
# `sudo ./images/devcontainer/bootstrap-remote.sh` form, and the one the
# remote-bootstrap CI job uses to exercise the working tree's own scripts. The
# assets beside this file are then the only thing there is to run: there is no
# pinned source to fall back to, and the operator chose the path they ran. That
# checkout is also where the agent posture comes from, and it reaches OUTSIDE
# this directory: .devcontainer/agent/agent-autonomy.sh, two levels up, is run
# as root, and the definition beside it is installed as managed policy. The
# same choice covers both: the operator ran this checkout, so its tree is what
# runs.
self_dir=""
if [ -r "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# Whether the assets the tiers RUN came from that directory. `self_dir` alone
# does not answer it: this file can sit in any git checkout (copied in, vendored,
# or a repo that only holds the standalone entry) while the install scripts are
# fetched from `--ref`, and only the branch below knows which happened. The
# manifest's provenance is decided by this flag, never by self_dir (review r2-3).
assets_local=0

fetched_dir=""
posture_scratch=""
# The agent posture's run state, file-scope like the rest: the managed paths
# left in place as found, and their count for HARMON_BOOTSTRAP_POSTURE_GAPS.
posture_left_in_place=""
posture_gaps=0
cleanup() {
    [ -n "$fetched_dir" ] && rm -rf "$fetched_dir"
    [ -n "$posture_scratch" ] && rm -rf "$posture_scratch"
    return 0
}
trap cleanup EXIT

if [ -z "$ref" ]; then
    if [ -z "$self_dir" ] || [ ! -r "${self_dir}/install/lib.sh" ]; then
        die "the install scripts are not beside this file; pass --ref <harmon-init release tag> so they can be fetched from a pinned release"
    fi
    asset_dir="$self_dir"
    assets_local=1
    printf '==> using the install scripts beside this file (%s)\n' "$asset_dir"
else
    fetched_dir="$(mktemp -d)"
    # Stated rather than inherited, for the same reason the recipe states it:
    # this is the directory root is about to execute install scripts out of.
    chmod 0700 "$fetched_dir"
    asset_dir="$fetched_dir"
    assets_local=0
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

# ---------- locate the agent posture ----------
# From the SAME source as the install scripts, decided by the same flag: the
# checkout the tiers came from, or the tag they were fetched from. Never a mix,
# and never a copy carried here. Fetched before any tier runs, so a tag that
# lacks the definition stops the run before it has installed anything; and
# installed before any tier too (below, right after apt-core), so a failing
# tier cannot leave a harness on this machine without its managed policy.
if [ "$assets_local" = 1 ]; then
    posture_root="$(cd "${self_dir}/../.." && pwd)"
    for asset in $HARMON_AGENT_POSTURE_ASSETS; do
        [ -r "${posture_root}/${asset}" ] ||
            die "the agent posture is not in this checkout (${posture_root}/${asset} is missing); run the bootstrap from a harmon-init checkout, or pass --ref <harmon-init release tag>"
    done
else
    posture_root="${fetched_dir}/posture"
    for asset in $HARMON_AGENT_POSTURE_ASSETS; do
        mkdir -p "$(dirname "${posture_root}/${asset}")"
        curl -fsSL --retry 3 --retry-delay 2 \
            "${HARMON_REPO_RAW}/${ref}/${asset}" \
            -o "${posture_root}/${asset}" ||
            die "could not fetch ${asset} at ref ${ref}"
    done
fi

# ---------- locale and PATH ----------
# The remote VM's locale is POSIX with LANG unset (observed 2026-09-27), and a
# C locale stops NBSP reading as whitespace — which silently changes what the
# title checkers in this toolchain accept. /etc/environment is read by PAM for
# every session; the profile.d drop-in covers login shells that bypass it.
# Both writes are conditional on the content actually differing. Rewriting a
# byte-identical file is not a change the install counter should report, but it
# does churn mtime and inode on two system files every single run — which is
# exactly what configuration-drift tooling watches. "The second run changed
# nothing" should be true of the filesystem, not only of the counter. The
# drop-in's path is HARMON_PROFILE_DROPIN, declared with the other constants at
# the top because the prefix validation names it too.

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
    # for the login shell to expand. Every interpolation of it lands INSIDE
    # double quotes, and that is load-bearing rather than tidy: this file is
    # sourced by this root process and by every login shell on the machine, so
    # an unquoted path with a space in it would silently write a broken drop-in
    # that breaks every later login, persistently. The quoting handles an
    # awkward path; check_safe_path above is what stops a hostile one, because
    # no amount of quoting survives a value carrying its own quote or newline.
    # scripts/test-bootstrap-remote.sh holds both halves.
    #
    # The prefix is configurable
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

# ---------- the agent posture ----------
# Installed HERE, right after apt-core (which provides jq, its one dependency)
# and before any tier: a tier that fails must never leave a harness installed
# on this machine without its managed policy.
#
# Every remote environment runs under the agent posture (#1408): the agent
# Claude Code managed settings and the agent Codex managed config, located
# above. They are installed and verified by the definition's own installer,
# agent-autonomy.sh — the script the agent devcontainer runs — so there is one
# install path rather than two that agree today. It is told four things, for
# this one child process only — three in its environment, one as an argument:
#   FOREMAN_DEVCONTAINER=agent  the posture this machine runs under. The script
#                               refuses to touch managed policy without it,
#                               which is what keeps it off the bot and dev
#                               profiles; a remote environment is agent by
#                               decision (#1404, 2026-09-27), so that is the
#                               true value rather than a way past the check.
#   AGENT_AUTONOMY_CONFIG_DIR   the definition located above. Unset, the script
#                               prefers an image-baked copy, and a machine that
#                               happened to carry one would install bytes other
#                               than this ref's.
#   AGENT_AUTONOMY_*_MANAGED    the destinations, stated rather than defaulted
#                               so this file and that one cannot disagree.
#   --platform-vm               install and verify the two files only. In the
#                               agent devcontainer apply also makes every harness
#                               the definition refuses non-executable; on a
#                               platform's VM those executables are the
#                               platform's, and changing their modes as root is
#                               not this script's to do. Harness refusal on a
#                               platform VM is a recorded delivery gap, with the
#                               platform's own controls named per platform in
#                               docs/architecture/remote-environments.md.
#                               An argument, never an environment variable, so
#                               no repository setting can switch it on in the
#                               agent devcontainer, whose lifecycle never
#                               passes it.
#
# A file already at a destination that is NOT the definition is left in place:
# a platform may supply managed policy of its own, and replacing it could
# remove a stronger control than ours. The run reports the file and its digest,
# records the posture as not applied for it, and completes. Replacing it is an
# operator's explicit choice, HARMON_AGENT_POSTURE_REPLACE=1, which keeps the
# previous file beside it under a name never used before.

# posture_digest <file> — SHA-256, from GNU sha256sum or the shasum macOS ships.
posture_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# posture_describe <path> — what was found there: its SHA-256, or, for a
# symlink, where it points and whether that target exists. Only a regular file
# has a digest; anything else (a directory, a device) says so rather than
# printing an empty one.
posture_describe() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then
        printf 'a dangling symlink to %s' "$(readlink "$1")"
    elif [ -L "$1" ] && [ -f "$1" ]; then
        printf 'a symlink to %s, sha256 %s' "$(readlink "$1")" "$(posture_digest "$1")"
    elif [ -L "$1" ]; then
        printf 'a symlink to %s, not a regular file' "$(readlink "$1")"
    elif [ -f "$1" ]; then
        printf 'sha256 %s' "$(posture_digest "$1")"
    else
        printf 'not a regular file'
    fi
}

# prepare_posture_dest <definition file> <destination> — decide what happens to
# one destination, and print the path agent-autonomy.sh is to use for it: the
# destination itself, or, when a platform's file is left in place, the scratch
# path $3, so the installer cannot replace it. Creates the
# destination's directory when it is missing (Claude Code on the web has no
# /etc/claude-code/, observed 2026-09-27). Every destination written is
# recorded as an install, so a second run reports none. It runs in a command
# substitution, so it sets no variable of the caller's.
prepare_posture_dest() {
    local src="$1" dest="$2" scratch="$3" kept
    if [ ! -d "$(dirname "$dest")" ]; then
        install -d -m 0755 "$(dirname "$dest")"
        printf '    created %s\n' "$(dirname "$dest")" >&2
    fi
    # Absent means NOTHING at the path. `-e` alone follows a symlink, so a
    # dangling one — a platform's link to a target it has not populated yet —
    # would read as absent and be replaced without a word.
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
        harmon_changed "agent posture ${dest}" >&2
    elif cmp -s "$src" "$dest"; then
        printf '    (already the agent posture) %s\n' "$dest" >&2
    elif [ "${HARMON_AGENT_POSTURE_REPLACE:-}" = "1" ]; then
        # mktemp, never a timestamp alone: two runs in one second would
        # otherwise overwrite the first kept copy with the posture itself.
        # -P keeps a symlink as the link itself, dangling or not.
        kept="$(mktemp "${dest}.replaced-XXXXXX")" &&
            cp -pP -- "$dest" "$kept" ||
            die "could not keep the existing ${dest} before replacing it"
        if [ -L "$dest" ]; then
            rm -f -- "$dest" || die "could not remove the symlink at ${dest} before replacing it"
        fi
        warn "found ${dest} ($(posture_describe "$kept")) that is not the agent posture — replacing it because HARMON_AGENT_POSTURE_REPLACE=1; the previous file is kept at ${kept}"
        harmon_changed "agent posture ${dest} (replaced; the previous file is ${kept})" >&2
    else
        warn "found ${dest} ($(posture_describe "$dest")) that is not the agent posture — left in place, so the agent posture is NOT applied for this file. A platform may supply managed policy of its own; set HARMON_AGENT_POSTURE_REPLACE=1 to replace it (the previous file is kept)."
        printf '%s\n' "$scratch"
        return 0
    fi
    printf '%s\n' "$dest"
}

# posture_missing_hooks — the files the installed posture's hook commands name
# that do not exist on this machine, one per line: EVERY absolute path in a
# command, not only its first word, because a Codex hook is a wrapper whose
# argument is the hook script. The definition's hooks are the
# agent IMAGE's files (/etc/claude-code/hooks/, /etc/codex/hooks/), and this
# bootstrap installs none: hook guards in remote sessions are deferred by
# #1402. Reported so the gap is visible where it happens, never "fixed" by
# editing the definition, and recorded per platform in
# docs/architecture/remote-environments.md § Adapters. A file left in place is
# not the posture, so it is not read.
posture_missing_hooks() {
    local cmd
    {
        case " ${posture_left_in_place} " in
        *" ${HARMON_AGENT_CLAUDE_MANAGED} "*) ;;
        *) jq -r '.. | objects | .command? | select(type == "string") | split("\\s+"; "")[] | select(startswith("/"))' "$HARMON_AGENT_CLAUDE_MANAGED" ;;
        esac
        case " ${posture_left_in_place} " in
        *" ${HARMON_AGENT_CODEX_MANAGED} "*) ;;
        *) sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$HARMON_AGENT_CODEX_MANAGED" | tr ' \t' '\n\n' | sed -n '/^\//p' ;;
        esac
    } | sort -u | while IFS= read -r cmd; do
        [ -n "$cmd" ] && [ ! -x "$cmd" ] && printf '%s\n' "$cmd"
        true
    done
}

install_agent_posture() {
    local config_dir="${posture_root}/.devcontainer/config/agent"
    local autonomy="${posture_root}/.devcontainer/agent/agent-autonomy.sh"
    local missing step dest claude_target codex_target covered=""
    printf '\n==> agent posture (from %s)\n' "${ref:-the checkout at ${posture_root}}"
    # Global, so cleanup() removes it on every exit, a die in the loop included.
    posture_scratch="$(mktemp -d)"
    # Stated rather than inherited, as for fetched_dir: root's installer writes
    # the decoy destinations here.
    chmod 0700 "$posture_scratch"
    claude_target="$(prepare_posture_dest "${config_dir}/claude-managed-settings.json" \
        "$HARMON_AGENT_CLAUDE_MANAGED" "${posture_scratch}/managed-settings.json")"
    codex_target="$(prepare_posture_dest "${config_dir}/codex-managed-config.toml" \
        "$HARMON_AGENT_CODEX_MANAGED" "${posture_scratch}/managed_config.toml")"
    # The substitutions above ran in subshells; which destinations were left in
    # place is recovered from where they now point.
    posture_left_in_place=""
    [ "$claude_target" = "$HARMON_AGENT_CLAUDE_MANAGED" ] ||
        posture_left_in_place="${posture_left_in_place} ${HARMON_AGENT_CLAUDE_MANAGED}"
    [ "$codex_target" = "$HARMON_AGENT_CODEX_MANAGED" ] ||
        posture_left_in_place="${posture_left_in_place} ${HARMON_AGENT_CODEX_MANAGED}"
    # The count the run reports beside its install counters, so a run that left
    # every destination in place cannot read like a clean re-run.
    posture_gaps="$(printf '%s' "$posture_left_in_place" | wc -w | tr -d ' ')"
    for dest in "$HARMON_AGENT_CLAUDE_MANAGED" "$HARMON_AGENT_CODEX_MANAGED"; do
        case " ${posture_left_in_place} " in
        *" ${dest} "*) ;;
        *) covered="${covered} ${dest}" ;;
        esac
    done
    for step in apply verify; do
        FOREMAN_DEVCONTAINER=agent \
            AGENT_AUTONOMY_CONFIG_DIR="$config_dir" \
            AGENT_AUTONOMY_CLAUDE_MANAGED="$claude_target" \
            AGENT_AUTONOMY_CODEX_MANAGED="$codex_target" \
            bash "$autonomy" "$step" --platform-vm ||
            die "agent-autonomy.sh ${step} failed — the agent posture is not in effect on this machine"
    done
    rm -rf "$posture_scratch"
    posture_scratch=""
    # verify ran against a scratch path for a destination left in place, so its
    # "verify passed" is about the files named here and nothing else.
    printf '==> agent posture: verify covered%s%s\n' "${covered:- nothing}" \
        "${posture_left_in_place:+ (not verified, left in place:${posture_left_in_place})}"
    if [ -n "$posture_left_in_place" ]; then
        warn "the agent posture is NOT applied for:${posture_left_in_place} — each was left in place as found (see above). That is a delivery gap for this machine, not a failed run."
    fi
    # A report, so it can never fail the run: a scan that errors says so.
    missing="$(posture_missing_hooks)" ||
        warn "could not scan the installed agent posture's hook commands — the hook-gap report below is incomplete"
    [ -z "$missing" ] ||
        warn "the agent posture names hook commands this machine does not have: $(printf '%s' "$missing" | tr '\n' ' ' | sed 's/ $//') — the bootstrap installs no hooks (hook guards in remote sessions are deferred by #1402), so each is a failing command whenever its hook fires. The permission rules do not depend on them."
}
install_agent_posture

for tier in $HARMON_TIER_ORDER; do
    case ",${tiers}," in
    *",${tier},"*)
        printf '\n'
        "${asset_dir}/install/install-${tier}.sh"
        ;;
    esac
done

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
# out of step with the tiers. The revision names the source of the assets that
# were actually RUN: the checkout's commit when the tiers came from the checkout
# beside this file — suffixed `-dirty` when that checkout has uncommitted or
# untracked changes, so a manifest never attests a clean commit for bytes that
# were not that commit — else the release tag they were fetched from. Reading
# `self_dir`'s HEAD whenever it merely EXISTS attributed a fetched install to
# whatever repository this file happened to be sitting in (review r2-3), which
# is worse than no revision at all: the image-to-VM comparison would be run
# against a commit that never supplied a byte of what is installed.
manifest_dir="${HARMON_PREFIX}/share/harmon-remote-env"
write_manifest() {
    local revision="" manifest="${manifest_dir}/manifest.json" before=""
    local after="" before_tiers="" status_out="" status_rc=0
    if [ "$assets_local" = 1 ]; then
        revision="$(git -C "$self_dir" -c safe.directory='*' rev-parse --verify HEAD 2>/dev/null || true)"
        if [ -n "$revision" ]; then
            # THE RULE, and this is the third surface in this change that needed
            # it: absence and cleanliness are CLAIMS, and a claim requires a
            # SUCCESSFUL read — not merely an empty one. `git status
            # --porcelain` prints nothing both when the checkout is clean and
            # when the command failed outright (an unreadable repository, a
            # safe.directory refusal, a git that rejects an option), so its
            # output and its exit status are captured separately instead of the
            # output being read as the answer. On a failed read no manifest is
            # written, because every alternative is a lie: suffixing `-dirty`
            # invents a fact, and attesting the bare commit hands the
            # image-to-VM comparison a clean commit for bytes nobody checked —
            # exactly the guarantee the comment above this function makes.
            # Clearing `revision` and falling through would be wrong too: the
            # assets came from the CHECKOUT, so the release tag supplied none of
            # them (review r2-3), which is why this returns instead.
            # --no-optional-locks: root reads the caller's checkout without
            # refreshing (rewriting) its index.
            status_out="$(git -C "$self_dir" -c safe.directory='*' --no-optional-locks status --porcelain 2>/dev/null)" ||
                status_rc=$?
            if [ "$status_rc" -ne 0 ]; then
                warn "no manifest written: git exited ${status_rc} reading the working-tree status of ${self_dir}, so whether the installed bytes are commit ${revision} cannot be established. An empty status from a FAILED read is not a clean checkout, and a manifest attesting one would defeat the image-to-VM comparison it exists for."
                return 0
            fi
            if [ -n "$status_out" ]; then
                revision="${revision}-dirty"
            fi
        fi
    fi
    if [ -z "$revision" ] && [[ $ref =~ $HARMON_RELEASE_TAG_RE ]]; then
        revision="$ref"
    fi
    if [ -z "$revision" ]; then
        warn "no manifest written: the source revision is unknown (not a git checkout, and no release tag). The image-to-VM comparison needs one or the other."
        return 0
    fi
    if [ -f "$manifest" ]; then
        before="$(cat "$manifest")"
        before_tiers="$(printf '%s' "$before" | jq -r '.image.tiers // ""' 2>/dev/null || true)"
    fi
    # The tier set these entries were produced from travels INTO the manifest as
    # `$tiers` itself — the one canonical value built at validation, already
    # deduplicated and spelled in HARMON_TIER_ORDER order. It used to be
    # re-derived here with a second pass over the caller's string, which is how
    # `--tiers 'core, agents'` could have recorded a tier set the install loop
    # never ran: one representation, consumed everywhere, cannot disagree with
    # itself.
    # shellcheck disable=SC2046  # the record is one name=version token per line
    HARMON_MANIFEST_DIR="$manifest_dir" HARMON_MANIFEST_NAME=harmon-remote-env \
        HARMON_MANIFEST_TIERS="$tiers" \
        bash "${asset_dir}/generate-manifest.sh" "$revision" "$(harmon_arch)" \
        $(sed -n "s/^tool${tab}//p" "$change_log")
    after="$(cat "$manifest")"
    if [ "$before" = "$after" ]; then
        harmon_skip "manifest ${manifest}"
    elif [ -z "$before" ] || [ "$before_tiers" = "$tiers" ]; then
        harmon_changed "manifest ${manifest} (${revision})"
    else
        # A manifest is ONE RUN's records, so a run whose tier set differs from
        # the one that wrote the file lists a different set of tools by design:
        # the tools only the other tier set installs are simply not in this
        # run's record, whether or not they are still installed. Reporting that
        # as a changed pin is a false positive, and reporting nothing would hide
        # the entries that just left the file — so compare like with like, the
        # tools BOTH tier sets cover, and say out loud that that is what was
        # compared. The idempotence claim ("a second run leaves the manifest
        # byte-identical") is a claim about two runs of the SAME tiers, and this
        # is the branch where that precondition does not hold.
        warn "the manifest at ${manifest} records tiers '${before_tiers:-none (written before the tier set was recorded)}' and this run selected '${tiers}'. Its entries are this run's records, so tools only the other tier set installs are no longer listed — they may still be installed. Compared on the tools both tier sets cover, and nothing else."
        if printf '%s\n' "$before" "$after" | jq -e -s '
            (.[0].tools // {}) as $a | (.[1].tools // {}) as $b
            | ($a | with_entries(select(.key | in($b)))) == ($b | with_entries(select(.key | in($a))))
            ' >/dev/null 2>&1; then
            harmon_skip "manifest ${manifest} (tier set ${before_tiers:-none} -> ${tiers}; every shared tool unchanged)"
        else
            harmon_changed "manifest ${manifest} (${revision}; tier set ${before_tiers:-none} -> ${tiers}; a shared tool's version differs)"
        fi
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
# Managed files left in place, so the agent posture is NOT applied for them. A
# gap, not a change: a second run reports the same gaps and still installs 0.
printf 'HARMON_BOOTSTRAP_POSTURE_GAPS=%s\n' "$posture_gaps"
