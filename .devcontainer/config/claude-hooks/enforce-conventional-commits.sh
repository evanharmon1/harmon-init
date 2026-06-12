#!/usr/bin/env bash
# enforce-conventional-commits.sh — PreToolUse hook for Bash.
#
# Enforces Conventional Commits at the AI boundary. Lefthook's commit-msg
# hook already enforces this for human commits, but Claude Code can bypass
# git hooks via --no-verify (which is separately blocked by block-no-verify.sh).
# Belt-and-suspenders: refuse non-conforming `git commit -m` messages here too.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Only police `git commit` invocations.
printf '%s' "$command" | grep -qE 'git[[:space:]]+commit\b' || exit 0

# Extract the -m / --message argument. Supports single and double quotes,
# and the heredoc form `git commit -m "$(cat <<'EOF' ... EOF)"`.
# We grep for the first plausible message body.
msg=""

# Heredoc form: capture first line after the heredoc opener.
if printf '%s' "$command" | grep -q "<<'EOF'"; then
    msg="$(printf '%s' "$command" | awk "/<<'EOF'/{flag=1; next} /^EOF\$/{flag=0} flag" | head -n1)"
fi

# Plain -m "..." or -m '...' form.
if [[ -z "$msg" ]]; then
    msg="$(printf '%s' "$command" | grep -oE -- "-m[[:space:]]+\"[^\"]+\"" | head -n1 | sed -E 's/^-m[[:space:]]+"(.*)"$/\1/')"
fi
if [[ -z "$msg" ]]; then
    msg="$(printf '%s' "$command" | grep -oE -- "-m[[:space:]]+'[^']+'" | head -n1 | sed -E "s/^-m[[:space:]]+'(.*)'\$/\1/")"
fi

# If we couldn't parse a message, don't block — let git itself error out.
[[ -n "$msg" ]] || exit 0

# Allow merge / revert / fixup commits that git itself generates.
case "$msg" in
"Merge "* | "Revert "* | "fixup!"* | "squash!"*) exit 0 ;;
esac

if ! printf '%s' "$msg" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|chore|ci|build|change|remove|revert)(\([a-zA-Z0-9_.,/-]+\))?!?: .+'; then
    {
        echo "enforce-conventional-commits: commit message does not match Conventional Commits."
        echo "  got:      $msg"
        echo "  expected: type(scope): description"
        echo "  types:    feat fix docs style refactor perf test chore ci build change remove revert"
    } >&2
    exit 2
fi

exit 0
