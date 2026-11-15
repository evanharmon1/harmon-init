#!/usr/bin/env bash
# Prove drift detection and repair without changing the checkout under test.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-review-guidelines.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/scripts" "$scratch/docs" "$scratch/.gemini"
cp scripts/render-review-guidelines.sh "$scratch/scripts/"
cp docs/review-guidelines.md "$scratch/docs/"
cp AGENTS.md "$scratch/"
# Exercise Gemini even in a consumer that opted out of the integration.
cp AGENTS.md "$scratch/.gemini/styleguide.md"
cd "$scratch"
check() { bash scripts/render-review-guidelines.sh --check; }
reject() {
    if check >"$scratch/rejection.log" 2>&1; then
        echo "FAIL: accepted $1" >&2
        exit 1
    fi
}
check
for file in AGENTS.md .gemini/styleguide.md; do
    cp "$file" "$scratch/before"
    sed 's/P0 —/P0 changed —/' "$scratch/before" >"$file"
    cp "$file" "$scratch/edited"
    reject "hand edit to $file"
    cmp "$file" "$scratch/edited" # check never repairs silently
    bash scripts/render-review-guidelines.sh --write
    check
    cmp "$file" "$scratch/before"
done
cp docs/review-guidelines.md "$scratch/canonical"
sed 's/Correctness and contracts/Correctness and changed contracts/' \
    "$scratch/canonical" >docs/review-guidelines.md
reject 'canonical update without re-render'
bash scripts/render-review-guidelines.sh --write
check
grep -q 'Correctness and changed contracts' AGENTS.md
grep -q 'Correctness and changed contracts' .gemini/styleguide.md
for file in AGENTS.md docs/review-guidelines.md; do
    cp "$file" "$scratch/before"
    sed '/<!-- END .* REVIEW GUIDELINES -->/d' "$scratch/before" >"$file"
    reject "missing end marker in $file"
    cp "$scratch/before" "$file"
    cat "$scratch/before" >>"$file"
    reject "duplicate markers in $file"
    cp "$scratch/before" "$file"
done
rm .gemini/styleguide.md
check # Gemini opted out
printf 'code_review:\n' >.gemini/config.yaml
reject 'missing styleguide with Gemini enabled'
echo 'review-guidelines drift and re-render tests passed'
