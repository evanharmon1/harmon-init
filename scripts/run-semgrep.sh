#!/usr/bin/env bash
set -euo pipefail

# Keep Semgrep on its PyPI/uv distribution. The Homebrew bottle has previously
# failed during TLS-store initialization on macOS, and uv gives local + CI the
# same explicitly pinned build.
# renovate: datasource=pypi depName=semgrep
SEMGREP_VERSION=1.180.0

default_uv_tool_dir() {
    local resolved=""
    if command -v uv >/dev/null 2>&1; then
        resolved="$(env -u UV_TOOL_DIR -u UV_CACHE_DIR uv tool dir 2>/dev/null || true)"
    fi
    if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
    fi
    case "${XDG_DATA_HOME:-}" in
    /*) printf '%s/uv/tools\n' "${XDG_DATA_HOME%/}" ;;
    *)
        if [ -n "${HOME:-}" ]; then
            printf '%s/.local/share/uv/tools\n' "${HOME%/}"
        fi
        ;;
    esac
}

default_uv_cache_dir() {
    local resolved=""
    if command -v uv >/dev/null 2>&1; then
        resolved="$(env -u UV_TOOL_DIR -u UV_CACHE_DIR uv cache dir 2>/dev/null || true)"
    fi
    if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
    fi
    case "${XDG_CACHE_HOME:-}" in
    /*) printf '%s/uv\n' "${XDG_CACHE_HOME%/}" ;;
    *)
        if [ -n "${HOME:-}" ]; then
            printf '%s/.cache/uv\n' "${HOME%/}"
        fi
        ;;
    esac
}

ensure_writable_dir() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    mkdir -p "$dir" 2>/dev/null || return 1
    local probe
    probe="$(mktemp -d "${dir%/}/.semgrep-uv-probe.XXXXXX" 2>/dev/null)" || return 1
    rmdir "$probe" 2>/dev/null || rm -rf "$probe" 2>/dev/null || true
    return 0
}

ensure_fallback_uv_dir() {
    local subdir="$1"
    local tmp_base="${TMPDIR:-/tmp}"
    [ -n "$tmp_base" ] || return 1
    local user_root="${tmp_base%/}/uv-$(id -u)"
    (umask 077 && mkdir -p "$user_root" 2>/dev/null) || return 1
    if [ -L "$user_root" ] || [ ! -d "$user_root" ] || [ ! -O "$user_root" ]; then
        return 1
    fi
    chmod 700 "$user_root" 2>/dev/null || return 1
    local target="${user_root}/${subdir}"
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -O "$target" ]; }; then
        return 1
    fi
    ensure_writable_dir "$target" || return 1
    printf '%s\n' "$target"
}

resolve_uv_dir() {
    local var_name="$1"
    local current_val="$2"
    local default_dir="$3"
    local fallback_subdir="$4"
    local fallback_base="${TMPDIR:-/tmp}"
    fallback_base="${fallback_base%/}/uv-$(id -u)/${fallback_subdir}"

    if [ -n "$current_val" ]; then
        if ensure_writable_dir "$current_val"; then
            printf '%s\n' "$current_val"
            return 0
        fi
        echo "ERROR: ${var_name} directory '${current_val}' is not writable." >&2
        echo "Set UV_TOOL_DIR and UV_CACHE_DIR to writable directories before running Semgrep." >&2
        return 1
    fi

    if [ -n "$default_dir" ] && ensure_writable_dir "$default_dir"; then
        printf '%s\n' "$default_dir"
        return 0
    fi

    local resolved_fallback
    if resolved_fallback="$(ensure_fallback_uv_dir "$fallback_subdir")"; then
        printf '%s\n' "$resolved_fallback"
        return 0
    fi

    echo "ERROR: Unable to find a writable directory for ${var_name} (tried default '${default_dir:-<unset>}' and fallback '${fallback_base}')." >&2
    echo "Set UV_TOOL_DIR and UV_CACHE_DIR to writable directories before running Semgrep." >&2
    return 1
}

UV_TOOL_DIR="$(resolve_uv_dir "UV_TOOL_DIR" "${UV_TOOL_DIR:-}" "$(default_uv_tool_dir)" "tools")"
UV_CACHE_DIR="$(resolve_uv_dir "UV_CACHE_DIR" "${UV_CACHE_DIR:-}" "$(default_uv_cache_dir)" "cache")"
export UV_TOOL_DIR UV_CACHE_DIR

# Semgrep defaults to the current directory when no target is provided. Do not
# append one here: callers can scope local scans with `task security:sast -- <path>`.
exec uvx --from "semgrep==${SEMGREP_VERSION}" semgrep scan \
    --config p/default \
    --metrics=off \
    --error \
    --severity ERROR \
    --exclude=.worktrees \
    "$@"
