#!/usr/bin/env bash
# Check shell files with shellcheck + shfmt without splitting paths on whitespace.
#
# The check-side counterpart to format-shell.sh. The Taskfile previously built a
# space-joined string and passed it unquoted, so any shell file under a path
# containing whitespace was split into fragments and reported as missing. The
# lefthook pre-commit hook forwards {staged_files} here, so in a generated repo
# a script under e.g. `my scripts/` produced a confusing failure.
#
# Explicit arguments win (that is the hook path); otherwise enumerate tracked
# files NUL-delimited. `template/` is excluded because its jinja-named paths are
# not valid shell targets — the RENDERED scripts are checked by test:template.
# That exclusion is a harmless no-op in a generated repo, which has no template/.
set -euo pipefail

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(git ls-files -z -- '*.sh' '*.bash' ':(exclude)template/*' 2>/dev/null)
fi

# Empty-array expansion under `set -u` is an error in bash 3.2 (macOS).
if [ "${#files[@]}" -eq 0 ]; then
    exit 0
fi

# CI's setup action is the single source of truth for the ShellCheck version.
# Some generated repos omit that action, so an absent pin is advisory only.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/.." && pwd -P; })"
setup_action="${repo_root}/.github/actions/setup/action.yml"
pinned_version=
if [ -f "$setup_action" ]; then
    # Separate quote forms keep pattern backreferences out of POSIX ERE.
    pinned_version="$(sed -nE \
        -e 's/^[[:space:]]*SHELLCHECK_VERSION=([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+#.*)?[[:space:]]*$/\1/p' \
        -e 's/^[[:space:]]*SHELLCHECK_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"([[:space:]]+#.*)?[[:space:]]*$/\1/p' \
        -e "s/^[[:space:]]*SHELLCHECK_VERSION='([0-9]+\.[0-9]+\.[0-9]+)'([[:space:]]+#.*)?[[:space:]]*$/\1/p" \
        "$setup_action")"
fi
case "$pinned_version" in
*$'\n'*)
    echo "ERROR: multiple SHELLCHECK_VERSION pins in $setup_action." >&2
    exit 1
    ;;
esac
if [ -z "$pinned_version" ]; then
    echo "WARNING: no SHELLCHECK_VERSION pin found in $setup_action; continuing without a version check." >&2
else
    local_version="$(shellcheck --version | sed -n 's/^version: //p')"
    if [ "$local_version" != "$pinned_version" ]; then
        echo "ERROR: local shellcheck ${local_version:-unknown} differs from CI's pinned $pinned_version; rebuild the devcontainer, or install shellcheck $pinned_version." >&2
        exit 1
    fi
fi

shellcheck --severity=error "${files[@]}"
shfmt -d "${files[@]}"
