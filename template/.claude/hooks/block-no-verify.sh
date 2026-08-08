#!/usr/bin/env bash
# block-no-verify.sh — PreToolUse hook for Bash.
#
# Claude Code routinely appends `--no-verify` (or `-n`) to `git commit` to
# silence failing pre-commit hooks. That defeats lefthook + `task verify`.
# This hook intercepts those flags and refuses the command.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Only police git-related commands.
case "$command" in
*"git "*) ;;
*) exit 0 ;;
esac

if ! python3 -c '
import sys, shlex
try:
    args = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(0)
if "git" not in args:
    sys.exit(0)
is_commit = "commit" in args
for a in args:
    if a.startswith("--no-verify") or a == "--no-gpg-sign" or a == "--no-verify-signatures":
        sys.exit(1)
    if is_commit and a.startswith("-") and not a.startswith("--") and "n" in a:
        sys.exit(1)
sys.exit(0)
' "$command"; then
    echo "block-no-verify: refusing to bypass git hooks (--no-verify / --no-gpg-sign / -n)." >&2
    echo "If a hook is failing, fix the underlying issue rather than skipping it." >&2
    exit 2
fi

exit 0
