#!/usr/bin/env bash
# Root-only: trim_blocks drops the newline after an inline Jinja block tag.
# Preserve it with +%] whenever prose precedes a line-ending block tag.
set -euo pipefail
cd "$(dirname "$0")/.."

scan_file() {
    awk '
        /%\][[:space:]]*$/ {
            rest = $0
            prose = ""
            last = ""
            while (match(rest, /\[%([^%]|%[^]])*%\]/)) {
                prose = prose substr(rest, 1, RSTART - 1)
                last = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
            if (rest ~ /^[[:space:]]*$/ && prose ~ /[^[:space:]]/ &&
                last !~ /\+%\]$/) {
                printf "FAIL: %s:%d: inline block tag must close with +%%]\n", FILENAME, FNR
                failed = 1
            }
        }
        END { exit failed }
    ' "$1"
}

# Exercise the same matcher as the real scan. A disabled matcher must fail here.
fixtures="$(mktemp -d "${TMPDIR:-/tmp}/md-block-trim.XXXXXX")"
trap 'rm -rf "$fixtures"' EXIT
printf '%s\n' 'Prose[% endif %]' 'Next line' >"$fixtures/fail.md.jinja"
printf '%s\n' 'Prose[% set x = 1 %]' 'Next line' >"$fixtures/set.md.jinja"
printf '%s\n' 'Prose[% endif +%]' '[% endif %]' 'Prose[[ variable ]]' >"$fixtures/pass.md.jinja"
if scan_file "$fixtures/fail.md.jinja" >"$fixtures/fail.log"; then
    echo "FAIL: md-block-trim self-test accepted the must-fail fixture" >&2
    exit 1
fi
if scan_file "$fixtures/set.md.jinja" >"$fixtures/set.log"; then
    echo "FAIL: md-block-trim self-test accepted the must-fail set fixture" >&2
    exit 1
fi
if ! scan_file "$fixtures/pass.md.jinja"; then
    echo "FAIL: md-block-trim self-test rejected the must-pass fixtures" >&2
    exit 1
fi
echo "md-block-trim self-test OK: rejected unsafe endif/set tags; accepted +%], tag-only lines and variables"

[ -d template ] || {
    echo "FAIL: template/ is missing — nothing was scanned" >&2
    exit 1
}
failed=0
while IFS= read -r -d '' file; do
    if ! scan_file "$file"; then
        failed=1
    fi
done < <(find template -type f -name '*.md.jinja' -print0)
[ "$failed" -eq 0 ] || exit 1
echo "md-block-trim OK: inline Markdown block tags preserve newlines"
