#!/usr/bin/env bash
# verify-macos-bash-compat.sh — exercise shell and guard suites under Apple
# /bin/bash 3.2 with a hostile PATH containing spaces and shell/sed
# metacharacters (harmon-init#2116).
#
# Root-only: public harmon-init runs macos-26 Actions runners at zero cost so
# downstream private repositories do not pay macOS runner rates to test
# template-originated shell scripts.
#
# Overrides for hermetic unit tests (scripts/test-macos-bash-compat.sh):
#   MACOS_BASH_COMPAT_APPLE_BASH — path to the Bash 3.2 interpreter (default: /bin/bash)
#   positional arguments         — command to run instead of the four default Task targets
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

apple_bash="${MACOS_BASH_COMPAT_APPLE_BASH:-/bin/bash}"
if [ ! -x "$apple_bash" ] || [ -d "$apple_bash" ]; then
    echo "verify-macos-bash-compat: Apple Bash 3.2 executable not found at '${apple_bash}'" >&2
    exit 1
fi

apple_bash_version="$("$apple_bash" -c 'printf "%s" "${BASH_VERSION:-}"' 2>/dev/null || true)"
case "$apple_bash_version" in
3.2.*) ;;
*)
    echo "verify-macos-bash-compat: '${apple_bash}' reported BASH_VERSION='${apple_bash_version:-<empty>}' (expected 3.2.*)" >&2
    exit 1
    ;;
esac

scratch_raw="$(mktemp -d "${TMPDIR:-/tmp}/harmon-macos-bash.XXXXXX")"
scratch=""
cleanup() {
    rm -rf "${scratch:-$scratch_raw}"
}
trap cleanup EXIT
scratch="$(cd "$scratch_raw" && pwd -P)"

case "$scratch" in
*:*)
    echo "verify-macos-bash-compat: scratch directory '${scratch}' contains ':' and cannot be placed on PATH" >&2
    exit 1
    ;;
esac

shim_dir="${scratch}/Apple Bash 3.2 bin"
sentinel="${scratch}/path-reinterpreted"
tripwire_name="__harmon_path_reinterpreted_tripwire__"
# Keep spaces, '&', '|', literal '$foo', and '; tripwire ;' in the directory name.
# Placing the tripwire as a standalone `;`-delimited word catches unquoted
# shell/eval/heredoc PATH splicing (#1684) without firing inside Apple's own
# /etc/profile `eval $(/usr/libexec/path_helper -s)` double-quoted PATH="..."
# when suite fixtures spawn `bash --login` / `bash -lc`.
hostile_dir="${scratch}/PATH with spaces & sed|shell \$foo ; ${tripwire_name} ;"

mkdir -p "$shim_dir" "$hostile_dir"
ln -s "$apple_bash" "${shim_dir}/bash"

cat >"${hostile_dir}/${tripwire_name}" <<'EOF'
#!/bin/sh
: >"${MACOS_BASH_COMPAT_SENTINEL:?}"
EOF
chmod +x "${hostile_dir}/${tripwire_name}"

export MACOS_BASH_COMPAT_SENTINEL="$sentinel"
export PATH="${shim_dir}:${hostile_dir}:${PATH}"
hash -r

resolved_bash="$(command -v bash 2>/dev/null || true)"
if [ "$resolved_bash" != "${shim_dir}/bash" ]; then
    echo "verify-macos-bash-compat: expected bash on PATH to resolve to '${shim_dir}/bash', got '${resolved_bash:-<none>}'" >&2
    exit 1
fi

active_bash_version="$(bash -c 'printf "%s" "${BASH_VERSION:-}"' 2>/dev/null || true)"
case "$active_bash_version" in
3.2.*) ;;
*)
    echo "verify-macos-bash-compat: shimmed bash reported BASH_VERSION='${active_bash_version:-<empty>}' (expected 3.2.*)" >&2
    exit 1
    ;;
esac

run_checked() {
    local rc=0
    "$@" || rc=$?
    if [ -e "$sentinel" ]; then
        echo "verify-macos-bash-compat: PATH was reinterpreted as shell syntax while running: $*" >&2
        return 1
    fi
    return "$rc"
}

if [ "$#" -gt 0 ]; then
    run_checked "$@"
else
    echo "==> macOS Bash ${active_bash_version}: task lint:shell"
    run_checked task lint:shell
    echo "==> macOS Bash ${active_bash_version}: task test:suite"
    run_checked task test:suite
    echo "==> macOS Bash ${active_bash_version}: task test:ci-results"
    run_checked task test:ci-results
    echo "==> macOS Bash ${active_bash_version}: task test:agent-profile"
    run_checked task test:agent-profile
fi
