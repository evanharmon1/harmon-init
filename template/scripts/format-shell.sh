#!/usr/bin/env bash
# Format every tracked shell file without splitting paths on whitespace.
#
# `git ls-files -z` and a NUL-delimited read keep Copier/Jinja paths (a
# "[%"-delimited conditional dir name) intact. `set -o pipefail` ensures a shfmt failure
# reaches `task format` instead of being mistaken for an empty file list.
set -euo pipefail

git ls-files -z -- '*.sh' '*.bash' |
    while IFS= read -r -d '' file; do
        shfmt -w "$file"
    done
