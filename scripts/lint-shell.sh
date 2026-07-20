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

shellcheck --severity=error "${files[@]}"
shfmt -d "${files[@]}"
