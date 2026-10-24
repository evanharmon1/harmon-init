#!/usr/bin/env bash
# Root-only: trim_blocks drops the newline after an inline Jinja block tag.
# Preserve it with +%] whenever prose precedes a line-ending block tag.
# Comment tags ([# ... #]) also trim newlines, but no Markdown template ends
# a prose line with one; this guard checks block tags only.
set -euo pipefail
cd "$(dirname "$0")/.."

select_files() {
    find "$1" -type f -name '*.md*.jinja' -print0
}

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
                printf "FAIL: %s:%d: inline block tag must close with +%%] or move to its own line\n", FILENAME, FNR
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
conditional_fixture="$fixtures/x.md[% endif %].jinja"
printf '%s\n' 'Prose[% endif %]' 'Next line' >"$conditional_fixture"
selected=0
while IFS= read -r -d '' file; do
    [ "$file" = "$conditional_fixture" ] || continue
    selected=1
    if scan_file "$file" >"$fixtures/conditional.log"; then
        echo "FAIL: md-block-trim self-test accepted the conditional-name must-fail fixture" >&2
        exit 1
    fi
done < <(select_files "$fixtures")
if [ "$selected" -ne 1 ]; then
    echo "FAIL: md-block-trim self-test did not select the conditional-name fixture" >&2
    exit 1
fi
echo "md-block-trim selection self-test OK: selected and rejected the conditional-name fixture"
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
done < <(select_files template)
[ "$failed" -eq 0 ] || exit 1
echo "md-block-trim OK: inline Markdown block tags preserve newlines"
