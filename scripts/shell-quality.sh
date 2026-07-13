#!/usr/bin/env bash
# Run shellcheck/shfmt over tracked shell files without losing paths that
# contain spaces. The template repository passes --exclude-template because
# Jinja-named sources are validated after rendering by task test:template.
set -euo pipefail

mode="${1:-}"
[ "$#" -gt 0 ] && shift

exclude_template=false
if [ "${1:-}" = "--exclude-template" ]; then
    exclude_template=true
    shift
fi

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    pathspecs=('*.sh' '*.bash')
    if $exclude_template; then
        pathspecs+=(':(exclude)template/**')
    fi
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(git ls-files -z -- "${pathspecs[@]}")
fi

[ "${#files[@]}" -gt 0 ] || exit 0

case "$mode" in
check)
    shellcheck --severity=error "${files[@]}"
    shfmt -d "${files[@]}"
    ;;
format)
    shfmt -w "${files[@]}"
    ;;
*)
    echo "Usage: $0 <check|format> [--exclude-template] [file ...]" >&2
    exit 2
    ;;
esac
