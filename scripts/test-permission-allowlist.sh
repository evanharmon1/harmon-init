#!/usr/bin/env bash
# test-permission-allowlist.sh — regression-guard the Claude Code Bash
# permission allowlist in .claude/settings.json and its template twin.
#
# The allowlist widens over successive PRs to cut prompt fatigue on
# read-only commands, and several entries were deliberately NARROWED during
# review (a wildcard grant found to allow an unsafe variant, cut down to an
# exact literal command with no arguments) or DROPPED entirely (a grant that
# allowed arbitrary code execution or a silent write, removed rather than
# narrowed). Nothing mechanically caught a future refactor re-widening one of
# those — this script does:
#
#   1. Each "narrowed to a bare literal" grant is still present as an EXACT
#      allow entry (no trailing arguments), and no wider variant of it has
#      reappeared.
#   2. Each "dropped entirely" command has no allow entry at all.
#   3. The two files' permissions.allow arrays are byte-identical — the
#      documented invariant for this dogfood pair (unlike most jinja twins,
#      neither file has a conditional inside the allow array itself, so nothing
#      excuses a divergence here; test:dogfood-parity does not cover this file
#      because it IS a jinja twin for the rest of its content).
#
# Run via `task test:permission-allowlist`.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

root_settings=".claude/settings.json"
template_settings="template/.claude/settings.json.jinja"

note_fail() {
    echo "FAIL: $*" >&2
    fail=1
}

# ---------------------------------------------------------------------------
# 1 & 2: exact-literal grants and dropped commands, checked in both files.
# ---------------------------------------------------------------------------

# Commands narrowed to a bare literal (no arguments) after a wider grant was
# found to allow an unsafe variant. Each entry: exact allow string, then the
# unsafe wider patterns that must never reappear.
narrowed_commands=(
    'Bash(gh auth status)|Bash(gh auth status *)|Bash(gh auth status:*)'
    'Bash(actionlint)|Bash(actionlint *)|Bash(actionlint:*)'
    'Bash(ps)|Bash(ps *)|Bash(ps:*)'
    'Bash(tree)|Bash(tree *)|Bash(tree:*)'
)

# Commands whose allow rule was dropped entirely (not narrowed) because no
# safe prefix shape existed — arbitrary-exec or silent-write escapes.
dropped_prefixes=(
    'Bash(git grep'
    'Bash(shfmt'
)

check_file() {
    local file="$1" content
    content="$(cat "$file")"

    for spec in "${narrowed_commands[@]}"; do
        IFS='|' read -r exact wide1 wide2 <<<"$spec"
        case "$content" in
        *"\"${exact}\""*) : ;;
        *) note_fail "$file: missing exact narrowed grant \"${exact}\"" ;;
        esac
        for wide in "$wide1" "$wide2"; do
            case "$content" in
            *"\"${wide}\""*) note_fail "$file: unsafe widened grant \"${wide}\" has reappeared" ;;
            esac
        done
    done

    for prefix in "${dropped_prefixes[@]}"; do
        case "$content" in
        *"\"${prefix}"*) note_fail "$file: dropped grant \"${prefix}...\" has reappeared" ;;
        esac
    done
}

check_file "$root_settings"
check_file "$template_settings"

# ---------------------------------------------------------------------------
# 3: the two permissions.allow arrays must be byte-identical.
# ---------------------------------------------------------------------------

extract_allow_block() {
    # Both files hold the allow array as a plain, non-conditional JSON list —
    # no jinja markers appear between "allow": [ and its closing "],". Extract
    # that span verbatim (including the bracket lines) so a byte diff catches
    # any divergence, including whitespace/ordering.
    sed -n '/"allow": \[/,/^\s*\],\?\s*$/p' "$1"
}

root_block="$(extract_allow_block "$root_settings")"
template_block="$(extract_allow_block "$template_settings")"

[ -n "$root_block" ] || note_fail "$root_settings: could not locate permissions.allow array"
[ -n "$template_block" ] || note_fail "$template_settings: could not locate permissions.allow array"

if [ "$root_block" != "$template_block" ]; then
    note_fail "permissions.allow arrays differ between $root_settings and $template_settings"
    diff <(printf '%s\n' "$root_block") <(printf '%s\n' "$template_block") >&2 || true
fi

if [ "$fail" -eq 0 ]; then
    echo "test-permission-allowlist: narrowed/dropped grants intact, allow arrays match"
fi

exit "$fail"
