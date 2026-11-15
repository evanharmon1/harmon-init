#!/usr/bin/env bash
# Prove drift detection and repair without changing the checkout under test.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
# Verified against github-mcp-server v0.17.1 (the image claude-code-action v1.0.269 starts) on 2026-11-15: get_pull_request returns the PR JSON including base.sha, and get_file_contents takes the commit in `sha`, not `ref`. These tool semantics are not checkable offline; re-verify them when a claude-code-action bump changes the pinned server image.
if [ -f .github/workflows/claude-review.yml ]; then
    python3 - .github/workflows/claude-review.yml <<'PYTOOLS'
import re, shlex, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
attempts = re.findall(
    r'(?m)^( +)claude_args: "([^"\n]*)"\n\1prompt: \|\n((?:(?:\1  [^\n]*)?\n)+)', text)
if len(attempts) != 2:
    raise ValueError("expected exactly two Claude review attempts with prompts")
for _, command, prompt in attempts:
    args = shlex.split(command)
    if args.count("--allowedTools") != 1:
        raise ValueError("expected exactly one allowlist per attempt")
    value = args[args.index("--allowedTools") + 1]
    if value != "mcp__github__get_file_contents,mcp__github__get_pull_request":
        raise ValueError("Claude review must allow exactly the two required read tools")
    for tool in value.split(","):
        if tool not in prompt:
            raise ValueError(f"allowlisted tool missing from the same attempt's prompt: {tool}")
        if set(tool.rsplit("__", 1)[-1].split("_")) & {"create", "update", "merge", "delete", "push", "add", "fork"}:
            raise ValueError(f"write tool is not allowed for review: {tool}")
    if args.count("--disallowedTools") != 1:
        raise ValueError("expected exactly one disallowed-tools setting per attempt")
    index = args.index("--disallowedTools")
    if args[index + 1:index + 4] != ["Edit", "Write", "Bash"]:
        raise ValueError("Claude review must disallow Edit Write Bash in each attempt")
print("Claude review per-attempt read-only tool invariants passed")
PYTOOLS
fi

# Check the real reviewer carriers before the synthetic drift fixtures below.
for file in docs/review-guidelines.md AGENTS.md .gemini/styleguide.md; do
    [ -f "$file" ] || continue
    grep -Eq '^###? Standardize profile$' "$file" || {
        echo "$file: missing standardize profile" >&2
        exit 1
    }
    grep -Fq 'standardize` profile, apply this profile; otherwise the default guidance applies.' "$file"
    grep -Fq '## Review scope' "$file"
    grep -Fq 'Treat template content as given when reviewing its application.' "$file"
    grep -Fq '**filed upstream**' "$file"
    grep -Fq 'A confirmed P0 or P1' "$file"
done
for file in .coderabbit.yaml .greptile/config.json; do
    [ -f "$file" ] || continue
    grep -Fq 'docs/review-guidelines.md' "$file"
    grep -Fq '## Review scope' "$file"
    grep -Fq 'standardize profile' "$file"
done

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
# Mutate by marker location, so legitimate prose/heading changes cannot make
# these regressions silently stop editing the fixture.
mutate_block() {
    awk -v marker="$2" '
        /^<!-- END (SHARED|RENDERED) REVIEW GUIDELINES -->$/ { print marker }
        { print }
    ' "$1"
}
for file in AGENTS.md .gemini/styleguide.md; do
    cp "$file" "$scratch/before"
    mutate_block "$scratch/before" review-guidelines-copy-mutation >"$file"
    cp "$file" "$scratch/edited"
    reject "hand edit to $file"
    cmp "$file" "$scratch/edited" # check never repairs silently
    bash scripts/render-review-guidelines.sh --write
    check
    cmp "$file" "$scratch/before"
done
cp docs/review-guidelines.md "$scratch/canonical"
mutate_block "$scratch/canonical" review-guidelines-canonical-mutation >docs/review-guidelines.md
reject 'canonical update without re-render'
bash scripts/render-review-guidelines.sh --write
check
grep -q 'review-guidelines-canonical-mutation' AGENTS.md
grep -q 'review-guidelines-canonical-mutation' .gemini/styleguide.md
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
# Source-only regression: render the real Jinja blocks against adversarial
# Markdown, then compare both copies with the consumer renderer. Generated
# consumers have no template tree and therefore need no Copier dependency.
if [ -f "$repo/template/AGENTS.md.jinja" ]; then
    source_dir="$scratch/jinja-source"
    render_dir="$scratch/jinja-render"
    mkdir -p "$source_dir/template/docs" "$source_dir/template/.gemini"
    cp "$repo/copier.yml" "$source_dir/"
    for file in AGENTS.md.jinja '.gemini/styleguide.md.jinja'; do
        input="$repo/template/$file"
        if [ "$file" = '.gemini/styleguide.md.jinja' ]; then
            input="$repo/template/[% if use_gemini_code_assist %].gemini[% endif %]/styleguide.md.jinja"
        fi
        awk '
            /^<!-- BEGIN RENDERED REVIEW GUIDELINES -->$/ { inside=1 }
            inside { print }
            /^<!-- END RENDERED REVIEW GUIDELINES -->$/ { inside=0 }
        ' "$input" >"$source_dir/template/$file"
    done
    cat >"$source_dir/template/docs/review-guidelines.md" <<'MARKDOWN'
<!-- BEGIN SHARED REVIEW GUIDELINES -->
## First heading
A sentence with inline ## stays unchanged.
### Existing third-level heading
## Another second-level heading
<!-- END SHARED REVIEW GUIDELINES -->
MARKDOWN
    copier copy --trust --defaults --skip-tasks \
        --data project_name='Review heading fixture' "$source_dir" "$render_dir" \
        >"$scratch/jinja-render.log" 2>&1 || {
        cat "$scratch/jinja-render.log" >&2
        exit 1
    }
    mkdir -p "$render_dir/scripts"
    cp "$repo/scripts/render-review-guidelines.sh" "$render_dir/scripts/"
    bash "$render_dir/scripts/render-review-guidelines.sh" --check
    cp "$render_dir/AGENTS.md" "$scratch/jinja-before"
    cp "$render_dir/.gemini/styleguide.md" "$scratch/jinja-gemini-before"
    bash "$render_dir/scripts/render-review-guidelines.sh" --write
    cmp "$render_dir/AGENTS.md" "$scratch/jinja-before"
    cmp "$render_dir/.gemini/styleguide.md" "$scratch/jinja-gemini-before"
    grep -Fxq 'A sentence with inline ## stays unchanged.' "$render_dir/AGENTS.md"
    grep -Fxq '### Existing third-level heading' "$render_dir/AGENTS.md"
    grep -Fxq '### First heading' "$render_dir/AGENTS.md"
fi
echo 'review-guidelines drift and re-render tests passed'
