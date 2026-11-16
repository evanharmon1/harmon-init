#!/usr/bin/env bash
# Check or refresh reviewer copies from the canonical marked partial.
set -euo pipefail
mode=${1:---check}
case "$mode" in
--check | --write) ;;
*)
    echo 'Usage: render-review-guidelines.sh [--check|--write]' >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
    echo 'Usage: render-review-guidelines.sh [--check|--write]' >&2
    exit 2
fi
cd "$(dirname "$0")/.."

# Require exactly one ordered, nonempty marker pair; malformed input must not
# silently generate an empty copy (or make a hand-edited copy look current).
extract() {
    awk -v begin="<!-- BEGIN $2 REVIEW GUIDELINES -->" \
        -v end="<!-- END $2 REVIEW GUIDELINES -->" '
        $0 == begin { starts++; if (inside || ends) bad=1; inside=1; next }
        $0 == end { ends++; if (!inside) bad=1; inside=0; next }
        inside { lines++; print }
        END { if (bad || starts != 1 || ends != 1 || inside || !lines) exit 1 }
    ' "$1"
}
shared=$(extract docs/review-guidelines.md SHARED) || {
    echo 'Invalid shared review-guidelines markers' >&2
    exit 1
}
# Subheadings keep the generated defaults inside AGENTS Review guidelines.
shared=$(printf '%s\n' "$shared" | sed 's/^## /### /')
[ -n "$shared" ] || {
    echo 'Empty shared review guidelines' >&2
    exit 1
}
files=(AGENTS.md)
if [ -f .gemini/config.yaml ] || [ -f .gemini/styleguide.md ]; then
    files+=(.gemini/styleguide.md)
fi
failed=0
# Copier includes this generated source artifact before consumer scripts exist.
# It lives outside _subdirectory: template, so it never ships to consumers.
if [ -f template/AGENTS.md.jinja ]; then
    partial=partials/shared-review-guidelines.md
    if [ "$mode" = --check ]; then
        if ! printf '%s\n' "$shared" | cmp -s "$partial" -; then
            echo "$partial: review guidelines drift; run task render:review-guidelines" >&2
            failed=1
        fi
    else
        mkdir -p partials
        printf '%s\n' "$shared" >"$partial"
    fi
fi
for file in "${files[@]}"; do
    actual=$(extract "$file" RENDERED) || {
        echo "Invalid rendered review-guidelines markers: $file" >&2
        exit 1
    }
    if [ "$mode" = --check ]; then
        if [ "$actual" != "$shared" ]; then
            echo "$file: review guidelines drift; run task render:review-guidelines" >&2
            failed=1
        fi
    else
        scratch=$(mktemp -d "${TMPDIR:-/tmp}/review-guidelines.XXXXXX")
        trap 'rm -rf "$scratch"' EXIT
        printf '%s\n' "$shared" >"$scratch/partial"
        awk '
            FNR == NR { body=body $0 ORS; next }
            $0 == "<!-- BEGIN RENDERED REVIEW GUIDELINES -->" {
                print; printf "%s", body; inside=1; next
            }
            $0 == "<!-- END RENDERED REVIEW GUIDELINES -->" { inside=0 }
            !inside { print }
        ' "$scratch/partial" "$file" >"$scratch/rendered"
        cat "$scratch/rendered" >"$file"
        rm -rf "$scratch"
        trap - EXIT
    fi
done
exit "$failed"
