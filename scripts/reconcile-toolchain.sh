#!/usr/bin/env bash
# The gate-checked tool registry, pin reader and remote-session reconciler.
# Only explicit local-vs-CI version gates belong here, currently ShellCheck;
# pin-pair groups and the bootstrap manifest also contain tools without a gate.
# Gate callers use --check <tool>; test-reconcile-toolchain.sh checks coverage.
set -euo pipefail

tools=(shellcheck)
mode="${1:---reconcile}"
if [ "$mode" = --list ]; then
    printf '%s\n' "${tools[@]}"
    exit 0
fi
case "$mode" in
--check | --reconcile | --status) ;;
*)
    echo "Usage: $0 [--list | --check <tool> | --reconcile | --status]" >&2
    exit 2
    ;;
esac
# --check is used by the gate on every platform and never installs anything.
if [ "$mode" != --check ] && [ "${CLAUDE_CODE_REMOTE:-}" != true ]; then
    exit 0
fi
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P; })"
setup_action="${ROOT}/.github/actions/setup/action.yml"

read_pin() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    sed -nE \
        -e "s/^[[:space:]]*${name}=([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+#.*)?[[:space:]]*$/\1/p" \
        -e "s/^[[:space:]]*${name}=\"([0-9]+\.[0-9]+\.[0-9]+)\"([[:space:]]+#.*)?[[:space:]]*$/\1/p" \
        -e "s/^[[:space:]]*${name}='([0-9]+\.[0-9]+\.[0-9]+)'([[:space:]]+#.*)?[[:space:]]*$/\1/p" \
        "$file"
}

installed_version() {
    local output
    # SessionStart must be able to report even a broken or hanging executable.
    if [ "$mode" = --check ]; then
        output="$("$1" --version 2>/dev/null)" || return 1
    else
        output="$(timeout --kill-after=1s 2s "$1" --version 2>/dev/null)" || return 1
    fi
    case "$1" in
    shellcheck) printf '%s\n' "$output" | sed -n 's/^version: //p' ;;
    esac
}

prefix="${HARMON_PREFIX:-/usr/local}"
cache="${prefix}/share/harmon-remote-env"
revision=unknown
if [ -r "${cache}/manifest.json" ]; then
    # jq is a bootstrap core dependency. No manifest or unreadable metadata
    # stays explicitly unknown; it must never be replaced by the checkout ref.
    revision="$(jq -r '.image.revision // "unknown"' "${cache}/manifest.json" 2>/dev/null)" || revision=unknown
fi
warn_drift() {
    printf 'WARNING: %s installed %s, checkout pin %s, environment %s: %s; set HARMON_INIT_REF to a release carrying this pin (for example the latest release) and rebuild the environment.\n' \
        "$tool" "${seen:-unknown}" "${pin:-unknown}" "${revision:-unknown}" "$1"
}

if [ "$mode" = --check ]; then
    case " ${tools[*]} " in
    *" ${2:-} "*) tools=("$2") ;;
    *)
        echo "ERROR: unregistered gate-checked tool: ${2:-missing tool}" >&2
        exit 1
        ;;
    esac
fi

for tool in "${tools[@]}"; do
    # This mapping owns the gate's pin source in root and generated checkouts.
    case "$tool" in shellcheck) pin_name=SHELLCHECK_VERSION ;; esac
    pin="$(read_pin "$setup_action" "$pin_name")"
    case "$pin" in
    *$'\n'*)
        if [ "$mode" = --check ]; then
            echo "ERROR: multiple ${pin_name} pins in $setup_action." >&2
            exit 1
        fi
        pin=ambiguous
        seen=unknown
        warn_drift "multiple ${pin_name} pins in ${setup_action}"
        continue
        ;;
    esac
    if [ -z "$pin" ]; then
        if [ "$mode" = --check ]; then
            echo "WARNING: no ${pin_name} pin found in $setup_action; continuing without a version check." >&2
        fi
        continue
    fi
    seen="$(installed_version "$tool")" || seen=unknown
    [ "$seen" != "$pin" ] || continue
    if [ "$mode" = --check ]; then
        echo "ERROR: local ${tool} ${seen:-unknown} differs from CI's pinned $pin; rebuild the devcontainer, or install ${tool} $pin." >&2
        exit 1
    fi
    if [ "$mode" = --status ]; then
        warn_drift "preparation could not reconcile this tool within its time budget"
        continue
    fi

    # Prefer checkout assets in harmon-init. Generated repositories reuse the
    # bootstrap's persisted assets. Never fetch installer code from a branch.
    assets="${ROOT}/images/devcontainer"
    [ -f "${assets}/install/install-${tool}.sh" ] || assets="$cache"
    if [ ! -r "${assets}/install/install-${tool}.sh" ] || [ ! -r "${assets}/install/lib.sh" ]; then
        warn_drift "shared installer unavailable"
        continue
    fi
    if [ "$(read_pin "${assets}/versions.env" "$pin_name")" != "$pin" ]; then
        warn_drift "installer checksum metadata does not cover the checkout pin"
        continue
    fi
    # A child task cannot export PATH to the parent agent. Use the existing
    # bootstrap prefix only when it wins PATH and is writable, without sudo.
    bin="${prefix}/bin"
    first_bin=
    IFS=: read -r -a path_entries <<<"$PATH"
    for entry in "${path_entries[@]}"; do
        if [ "$entry" = "$bin" ]; then
            first_bin="$bin"
            break
        fi
        if [ -x "${entry:-.}/${tool}" ]; then break; fi
    done
    if [ "$first_bin" != "$bin" ] || [ ! -d "$bin" ] || [ ! -w "$bin" ]; then
        warn_drift "${bin} must be writable and precede other ${tool} copies on PATH"
        continue
    fi
    rc=0
    # 30s plus a 2s grace leaves most of the outer 90s for checkout setup.
    timeout --kill-after=2s 30s env HARMON_PREFIX="$prefix" HARMON_BIN="$bin" \
        HARMON_VERSIONS_FILE="${assets}/versions.env" \
        bash "${assets}/install/install-${tool}.sh" >&2 || rc=$?
    hash -r
    after="$(installed_version "$tool")" || after=unknown
    if [ "$rc" -eq 0 ] && [ "$after" = "$pin" ]; then
        printf 'Reconciled %s %s -> %s\n' "$tool" "${seen:-unknown}" "$pin"
    else
        reason="shared installer failed (exit ${rc})"
        case "$rc" in 124 | 137) reason="reconciliation time budget exhausted" ;; esac
        warn_drift "$reason"
    fi
done
