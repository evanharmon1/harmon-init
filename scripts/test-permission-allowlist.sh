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
# found to allow an unsafe variant. Once narrowed, the command may NEVER carry
# arguments again — any allow entry that starts with the bare command followed
# by a space (arguments) or a colon (the "cmd:*" wildcard idiom) reintroduces
# the escape, regardless of what comes after. Checking only the two specific
# spellings seen so far (" *" / ":*") would miss e.g. a new exact rule such as
# `Bash(gh auth status --show-token)` added straight back in.
narrowed_commands=(
    'Bash(gh auth status)'
    'Bash(actionlint)'
    'Bash(ps)'
    'Bash(tree)'
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

    for exact in "${narrowed_commands[@]}"; do
        case "$content" in
        *"\"${exact}\""*) : ;;
        *) note_fail "$file: missing exact narrowed grant \"${exact}\"" ;;
        esac
        # Strip the trailing ")" to get the bare "Bash(<command>" prefix: any
        # entry starting with that prefix followed by a space (an argument) or
        # a colon (the "cmd:*" wildcard idiom) reintroduces the escape,
        # whatever text follows.
        prefix="${exact%)}"
        case "$content" in
        *"\"${prefix} "* | *"\"${prefix}:"*)
            note_fail "$file: an argument-bearing or wildcard form of the narrowed grant \"${exact}\" has reappeared"
            ;;
        esac
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
    # any divergence, including whitespace/ordering. POSIX bracket expressions
    # and -E (not GNU's \s / \? escapes) so this works under BSD sed too —
    # without -E, macOS sed silently fails to match the closing line and the
    # extraction runs to EOF instead, producing a false parity failure.
    sed -E -n '/"allow": \[/,/^[[:space:]]*\],?[[:space:]]*$/p' "$1"
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
