#!/usr/bin/env bash
# Prove drift detection and repair without changing the checkout under test.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
# Offline compatibility catalog: claude-code-action's install-mcp-server.ts at
# the action SHA below pins github-mcp-server v0.17.1 (image sha-23fa0dd).
# Tool names: github/github-mcp-server, tag v0.17.1, pkg/github/{repos,pullrequests}.go.
# An action bump must revisit this catalog, not merely accept a new SHA.
if [ -f .github/workflows/claude-review.yml ]; then
    python3 - .github/workflows/claude-review.yml <<'PYTOOLS'
import re, shlex, sys
from pathlib import Path

action_pin = "61a9c274fa7110a66dfafc1bbbced03833eb25fe"
server_version = "v0.17.1"
known_tools = ("get_file_contents", "get_pull_request")
expected = ",".join("mcp__github__" + tool for tool in known_tools)

def validate(text):
    pins = re.findall(r"uses: anthropics/claude-code-action@([a-f0-9]+)", text)
    if pins != [action_pin, action_pin]:
        raise ValueError("Claude action changed: revisit the pinned GitHub MCP tool catalog")
    attempts = re.findall(r'^ +claude_args: "([^"\n]*)"$', text, re.M)
    if len(attempts) != 2:
        raise ValueError("expected exactly two Claude review attempts")
    for attempt in attempts:
        args = shlex.split(attempt)
        if args.count("--allowedTools") != 1:
            raise ValueError("expected exactly one allowlist per attempt")
        value = args[args.index("--allowedTools") + 1]
        for tool in value.split(","):
            if tool not in {"mcp__github__" + name for name in known_tools}:
                raise ValueError(f"unknown tool for github-mcp-server {server_version}: {tool}")
        if value != expected:
            raise ValueError("Claude review allowlist must contain exactly the two required read tools")

text = Path(sys.argv[1]).read_text()
validate(text)
# Exercise the catalog and the exact-value check, not only the happy path.
for invalid in [text.replace(expected, expected + ",mcp__github__unknown_tool", 1),
                text.replace(expected, expected.split(",")[0], 1),
                text.replace(action_pin, "0" * 40, 1)]:
    try:
        validate(invalid)
    except ValueError:
        continue
    raise SystemExit("FAIL: accepted an incompatible Claude tool catalog fixture")
print(f"Claude review allowlists match the pinned {server_version} read-tool catalog")
PYTOOLS
fi

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
