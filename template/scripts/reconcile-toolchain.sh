#!/usr/bin/env bash
# The gate-checked tool registry, pin reader and remote-session reconciler.
# Only explicit local-vs-CI version gates belong here, currently ShellCheck;
# pin-pair groups and the bootstrap manifest also contain tools without a gate.
# Gate callers use --check <tool>; test-reconcile-toolchain.sh checks coverage.
set -euo pipefail

# Repositories may create .toolchain-registry (not template-owned):
#   foo .devcontainer/Dockerfile FOO_VERSION scripts/probe-foo.sh
# Four whitespace-separated fields: tool, pin file, pin name, probe script.
# Blank lines and full-line comments are allowed; paths cannot contain spaces.
# Gates call this script with --check foo, never probe versions themselves.
# The repo-owned probe runs with bash from ROOT, prints exactly X.Y.Z, and
# must not install. Remote preparation diagnoses drift; the repo owns installs.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P; })"
tools=(shellcheck)
pin_files=(.github/actions/setup/action.yml)
pin_names=(SHELLCHECK_VERSION)
probes=(builtin)
registry="${ROOT}/.toolchain-registry"
registry_error() {
    echo "ERROR: ${registry}: $*" >&2
    exit 1
}
repo_path() {
    # Keep rows literal data and paths relative to the checkout.
    [[ "$1" =~ ^[a-zA-Z0-9_.][a-zA-Z0-9_./-]*$ ]] &&
        [[ "/$1/" != *"/../"* && "/$1/" != *"/./"* ]]
}
if [ -e "$registry" ]; then
    [ -f "$registry" ] && [ -r "$registry" ] || registry_error 'expected a readable file'
    while IFS= read -r row || [ -n "$row" ]; do
        [[ "$row" =~ ^[[:space:]]*(#|$) ]] && continue
        read -r name pin_file pin_key probe extra <<<"$row"
        [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || registry_error "invalid tool: $name"
        [[ "$pin_key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || registry_error "invalid pin name: $pin_key"
        [ -z "$extra" ] && repo_path "$pin_file" && repo_path "$probe" || registry_error "invalid row: $row"
        case " ${tools[*]} " in *" $name "*) registry_error "duplicate tool: $name" ;; esac
        [ -f "${ROOT}/$pin_file" ] && [ -r "${ROOT}/$probe" ] && [ -f "${ROOT}/$probe" ] ||
            registry_error "missing pin file or probe for $name"
        tools+=("$name")
        pin_files+=("$pin_file")
        pin_names+=("$pin_key")
        probes+=("$probe")
    done <"$registry"
fi
mode="${1:---reconcile}"
if [ "$mode" = --list ]; then
    printf '%s\n' "${tools[@]}"
    exit 0
fi
case "$mode" in
--check | --reconcile | --status | --session-env) ;;
*)
    echo "Usage: $0 [--list | --check <tool> | --reconcile | --status | --session-env]" >&2
    exit 2
    ;;
esac
# --check is used by the gate on every platform and never installs anything.
if [ "$mode" != --check ] && [ "${CLAUDE_CODE_REMOTE:-}" != true ]; then
    exit 0
fi
setup_action="${ROOT}/.github/actions/setup/action.yml"

read_pin() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    sed -nE \
        -e "s/^[[:space:]]*(ARG[[:space:]]+)?${name}=([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+#.*)?[[:space:]]*$/\2/p" \
        -e "s/^[[:space:]]*(ARG[[:space:]]+)?${name}=\"([0-9]+\.[0-9]+\.[0-9]+)\"([[:space:]]+#.*)?[[:space:]]*$/\2/p" \
        -e "s/^[[:space:]]*(ARG[[:space:]]+)?${name}='([0-9]+\.[0-9]+\.[0-9]+)'([[:space:]]+#.*)?[[:space:]]*$/\2/p" \
        "$file"
}

probe_version() {
    if [ "$probe" = builtin ]; then
        "$tool" --version
    else
        (cd "$ROOT" && bash "$ROOT/$probe")
    fi
}
parse_version() {
    if [ "$probe" = builtin ]; then
        sed -n 's/^version: //p'
    else
        # Reject extra output rather than accidentally accepting a substring.
        local value
        value="$(cat)"
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        printf '%s\n' "$value"
    fi
}
installed_version() {
    local output output_file rc=0
    # The lint gate never needs temporary storage. Keep it outside the bounded
    # capture path so TMPDIR cannot create a false version mismatch in --check.
    if [ "$mode" = --check ]; then
        output="$(probe_version 2>/dev/null)" || return 1
        printf '%s\n' "$output" | parse_version || return 1
        return 0
    fi
    # SessionStart must be able to report even a broken or hanging executable.
    # A descendant can outlive timeout while holding stdout open. A regular file
    # lets the probe finish without waiting for that writer to close a pipe.
    # Status 2 means capture storage is unavailable, not that a tool drifted.
    output_file="$(mktemp "${TMPDIR:-/tmp}/reconcile-probe.XXXXXX" 2>/dev/null)" || return 2
    if [ "$probe" = builtin ]; then
        timeout --kill-after=1s 2s "$tool" --version >"$output_file" 2>/dev/null || rc=$?
    else
        (cd "$ROOT" && timeout --kill-after=1s 2s bash "$ROOT/$probe") >"$output_file" 2>/dev/null || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        parse_version <"$output_file" || rc=1
    fi
    rm -f "$output_file"
    [ "$rc" -eq 0 ]
}

prefix="${HARMON_PREFIX:-/usr/local}"
bin="${HARMON_BIN:-${prefix}/bin}"
cache="${prefix}/share/harmon-remote-env"

# Manifest pins extend the gate registry only for PATH diagnostics, never for
# per-checkout version reconciliation. Apt tools live outside bin; report only
# commands actually published in our bin. Node's bundled commands have no
# individual manifest keys, so include those explicitly.
report_path_shadows() {
    [ -f "${cache}/manifest.json" ] || return 0
    local tool found pinned_tools="node npm npx corepack pnpm uv uvx ${tools[*]}" manifest_tools
    if [ -r "${cache}/manifest.json" ] && command -v jq >/dev/null 2>&1; then
        manifest_tools="$(jq -r '.tools | keys[] | select(test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))' \
            "${cache}/manifest.json" 2>/dev/null)" || manifest_tools=
        for tool in $manifest_tools; do
            case " $pinned_tools " in
            *" $tool "*) ;;
            *) pinned_tools="${pinned_tools} ${tool}" ;;
            esac
        done
    fi
    for tool in $pinned_tools; do
        [ -x "${bin}/${tool}" ] || continue
        found="$(command -v "$tool" 2>/dev/null || true)"
        [ "$found" = "${bin}/${tool}" ] ||
            printf "WARNING: incoming PATH shadows pinned %s: resolves to '%s', expected %s/%s; put %s first on PATH.\n" \
                "$tool" "${found:-nothing}" "$bin" "$tool" "$bin"
    done
}

if [ "$mode" = --session-env ]; then
    [ -f "${cache}/manifest.json" ] || exit 0
    report_path_shadows >&2
    # Evaluated after login startup files, before each agent Bash command. Quote
    # the prefix as shell data, but expand PATH in that future shell. Repeated
    # sourcing is idempotent and preserves later session PATH additions.
    printf 'if [ "${PATH%%%%:*}" != %q ]; then export PATH=%q"${PATH:+:${PATH}}"; fi\n' "$bin" "$bin"
    exit 0
fi
if [ "$mode" = --status ]; then report_path_shadows; fi
revision=unknown
if [ -r "${cache}/manifest.json" ]; then
    # jq is a bootstrap core dependency. No manifest or unreadable metadata
    # stays explicitly unknown; it must never be replaced by the checkout ref.
    revision="$(jq -r '.image.revision // "unknown"' "${cache}/manifest.json" 2>/dev/null)" || revision=unknown
fi
# One cause-to-remedy mapping for every warning. Both remote modes classify
# the same conditions before --status stops at the installation boundary.
warn_toolchain() {
    local reason remedy= environment_pin=
    case "$1" in
    probe-capture)
        printf 'WARNING: %s version probe: mktemp failed; check TMPDIR (%s) and run task setup:remote again.\n' \
            "$tool" "${TMPDIR:-/tmp}"
        return
        ;;
    missing-pin)
        printf 'WARNING: no %s pin found in %s; continuing without a version check; keep exactly one %s assignment in %s.\n' \
            "$pin_name" "$setup_action" "$pin_name" "$setup_action" >&2
        return
        ;;
    ambiguous-pin)
        reason="multiple ${pin_name} pins in ${setup_action}"
        remedy="keep exactly one ${pin_name} assignment in ${setup_action}, then run task setup:remote again"
        ;;
    prefix)
        reason="${bin} must be writable and precede other ${tool} copies on PATH"
        remedy="make ${bin} writable and place it before other ${tool} copies on PATH, then run task setup:remote again"
        ;;
    repo-tool)
        printf 'WARNING: %s installed %s, checkout pin %s: run repository-owned preparation for %s, then rerun --check %s.\n' \
            "$tool" "${seen:-unknown}" "$pin" "$tool" "$tool"
        return
        ;;
    installer) reason="shared installer unavailable" ;;
    metadata) reason="installer checksum metadata does not cover the checkout pin" ;;
    unreconciled) reason="preparation left this tool unreconciled" ;;
    install-failed)
        reason="shared installer failed (exit ${rc})"
        case "$rc" in 124 | 137) reason="reconciliation time budget exhausted" ;; esac
        ;;
    esac
    if [ -z "$remedy" ]; then
        remedy="set HARMON_INIT_REF to a release carrying ${tool} ${pin:-unknown} and rebuild the environment"
        if [ -r "${cache}/manifest.json" ]; then
            # harmon-init's release and a tool's version are different number lines.
            # Compare the checkout pin to the TOOL version that release installed.
            environment_pin="$(jq -r --arg tool "$tool" --arg pin "$pin" '
                .tools[$tool] as $version |
                select($version | type == "string") |
                select($version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) |
                select($pin | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) |
                select(($version | split(".") | map(tonumber)) > ($pin | split(".") | map(tonumber))) |
                $version
            ' "${cache}/manifest.json" 2>/dev/null)" || environment_pin=
        fi
        if [ -n "$environment_pin" ]; then
            remedy="update the repository's ${tool} pin to the environment's ${environment_pin} (copier update for a generated repository)"
        fi
    fi
    printf 'WARNING: %s installed %s, checkout pin %s, environment %s: %s; %s.\n' \
        "$tool" "${seen:-unknown}" "${pin:-unknown}" "${revision:-unknown}" "$reason" "$remedy"
}

if [ "$mode" = --check ]; then
    case " ${tools[*]} " in
    *" ${2:-} "*) [ -n "${2:-}" ] || exit 1 ;;
    *)
        echo "ERROR: unregistered gate-checked tool: ${2:-missing tool}" >&2
        exit 1
        ;;
    esac
fi

for index in "${!tools[@]}"; do
    tool="${tools[$index]}"
    [ "$mode" != --check ] || [ "$tool" = "$2" ] || continue
    setup_action="${ROOT}/${pin_files[$index]}"
    pin_name="${pin_names[$index]}"
    probe="${probes[$index]}"
    pin="$(read_pin "$setup_action" "$pin_name")"
    case "$pin" in
    *$'\n'*)
        if [ "$mode" = --check ]; then
            echo "ERROR: multiple ${pin_name} pins in $setup_action." >&2
            exit 1
        fi
        pin=ambiguous
        seen=unknown
        warn_toolchain ambiguous-pin
        continue
        ;;
    esac
    if [ -z "$pin" ]; then
        if [ "$mode" = --check ]; then
            warn_toolchain missing-pin
            [ "$probe" = builtin ] || exit 1
        elif [ "$probe" != builtin ]; then
            warn_toolchain missing-pin
        fi
        continue
    fi
    probe_rc=0
    seen="$(installed_version "$tool")" || probe_rc=$?
    case "$probe_rc" in
    0) ;;
    2)
        warn_toolchain probe-capture
        continue
        ;;
    *) seen=unknown ;;
    esac
    [ "$seen" != "$pin" ] || continue
    if [ "$mode" = --check ]; then
        echo "ERROR: local ${tool} ${seen:-unknown} differs from CI's pinned $pin; rebuild the devcontainer, or install ${tool} $pin." >&2
        exit 1
    fi
    if [ "$probe" != builtin ]; then
        warn_toolchain repo-tool
        continue
    fi
    # Prefer checkout assets in harmon-init. Generated repositories reuse the
    # bootstrap's persisted assets. Never fetch installer code from a branch.
    assets="${ROOT}/images/devcontainer"
    [ -f "${assets}/install/install-${tool}.sh" ] || assets="$cache"
    if [ ! -r "${assets}/install/install-${tool}.sh" ] || [ ! -r "${assets}/install/lib.sh" ]; then
        warn_toolchain installer
        continue
    fi
    if [ "$(read_pin "${assets}/versions.env" "$pin_name")" != "$pin" ]; then
        warn_toolchain metadata
        continue
    fi
    # A child task cannot export PATH to the parent agent. Use the existing
    # bootstrap prefix only when it wins PATH and is writable, without sudo.
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
        warn_toolchain prefix
        continue
    fi
    if [ "$mode" = --status ]; then
        warn_toolchain unreconciled
        continue
    fi
    rc=0
    # 30s plus a 2s grace leaves most of the outer 90s for checkout setup.
    timeout --kill-after=2s 30s env HARMON_PREFIX="$prefix" HARMON_BIN="$bin" \
        HARMON_VERSIONS_FILE="${assets}/versions.env" \
        bash "${assets}/install/install-${tool}.sh" >&2 || rc=$?
    hash -r
    probe_rc=0
    after="$(installed_version "$tool")" || probe_rc=$?
    case "$probe_rc" in
    0) ;;
    2)
        warn_toolchain probe-capture
        continue
        ;;
    *) after=unknown ;;
    esac
    if [ "$rc" -eq 0 ] && [ "$after" = "$pin" ]; then
        printf 'Reconciled %s %s -> %s\n' "$tool" "${seen:-unknown}" "$pin"
    else
        warn_toolchain install-failed
    fi
done
