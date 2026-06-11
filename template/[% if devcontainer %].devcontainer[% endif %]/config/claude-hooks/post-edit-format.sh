#!/usr/bin/env bash
# post-edit-format.sh — PostToolUse hook for Edit|Write|MultiEdit.
#
# Auto-formats the just-written file so AI-generated code matches repo
# conventions before it ever reaches git. Adapted for IaC: black for Python,
# shfmt for shell, terraform fmt for Terraform.
#
# Always exits 0: this hook fixes, never blocks the tool call.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0
[[ -f "$file_path" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

case "$file_path" in
*.py)
    black --quiet "$file_path" 2>/dev/null || true
    ;;
*.sh | *.bash)
    shfmt -w "$file_path" 2>/dev/null || true
    ;;
*.tf | *.tfvars)
    terraform fmt "$file_path" 2>/dev/null || true
    ;;
*.md | *.mdx)
    npx --yes markdownlint-cli2 --fix "$file_path" 2>/dev/null || true
    ;;
esac

exit 0
