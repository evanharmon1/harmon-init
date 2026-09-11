#!/usr/bin/env bash
# Ban quiet-mode grep in production shell scripts.
#
# `producer | grep -q pattern` is unsafe under `set -o pipefail`: grep exits as
# soon as it matches, the producer can receive SIGPIPE, and the pipeline can
# report 141 even though the match succeeded. Trying to recognize only unsafe
# pipeline topologies grew into a partial shell parser with its own bypasses.
# The durable invariant is smaller: production scripts do not invoke grep in
# quiet mode at all. Capture or redirect ordinary grep output instead:
#
#   if grep -F "$needle" "$file" >/dev/null; then
#       ...
#   fi
#
# This guard is intentionally lexical, not a shell parser. It scans logical
# lines after a small sanitizer removes comments and quoted text, and it skips
# conventional heredoc bodies. Test suites (`test-*.sh` / `test-*.bash`) are
# outside the production invariant, so their fixture corpora are excluded by
# scope rather than interpreted. Shellcheck remains responsible for shell
# syntax; this guard owns only the quiet-grep token invariant.
#
# Scope with no arguments is every tracked production `*.sh` / `*.bash`, in
# both root and template, excluding test suites and the release-pinned vendored
# skill assets. Conditional template names ending in `.sh[% endif %]` or
# `.bash[% endif %]` are included.
#
# Usage: ./scripts/lint-shell-robustness.sh [file ...]
set -euo pipefail

repo_only=0
files=()

is_production_shell() {
    local path="$1" base
    base="${path##*/}"
    case "$base" in
    test-*.sh | test-*.bash | test-*.sh'[% endif %]' | test-*.bash'[% endif %]' | \
        '[% if '*'%]test-'*.sh'[% endif %]' | '[% if '*'%]test-'*.bash'[% endif %]')
        return 1
        ;;
    esac
    case "$path" in
    .claude/skills/* | template/.claude/skills/*)
        # Vendored, release-pinned assets are verified by verify:skills and
        # must be changed in harmon-devkit rather than rewritten here.
        return 1
        ;;
    *.sh | *.bash | *.sh'[% endif %]' | *.bash'[% endif %]')
        return 0
        ;;
    esac
    return 1
}

if [ $# -gt 0 ]; then
    for path in "$@"; do
        [ -f "$path" ] || {
            echo "lint-shell-robustness: no such file: $path" >&2
            exit 1
        }
        is_production_shell "$path" && files+=("$path")
    done
else
    repo_only=1
    cd "$(git rev-parse --show-toplevel)"
    list_file="$(mktemp)"
    trap 'rm -f "${list_file:-}" "${findings:-}"' EXIT
    if ! git ls-files -z -- >"$list_file"; then
        echo "lint-shell-robustness: could not enumerate tracked shell files" >&2
        exit 1
    fi
    while IFS= read -r -d '' path; do
        is_production_shell "$path" && files+=("$path")
    done <"$list_file"
    rm -f "$list_file"
    list_file=""
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "lint-shell-robustness: no production shell scripts in scope"
    exit 0
fi

findings="$(mktemp)"
trap 'rm -f "${list_file:-}" "${findings:-}"' EXIT

for path in "${files[@]}"; do
    LC_ALL=C awk -v FILE="$path" '
    # Return executable-looking text only. Quote contents and comments cannot
    # contain an invocation owned by this file; shellcheck validates syntax.
    function code_only(s,   out, i, c, previous) {
        out = ""
        previous = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (escaped) {
                escaped = 0
                previous = c
                continue
            }
            if (quote != "") {
                if (quote == "\"" && c == "\\") escaped = 1
                else if (c == quote) quote = ""
                previous = c
                continue
            }
            if (c == "\\") {
                escaped = 1
                out = out c
            }
            else if (c == "\"" || c == "\047") quote = c
            else if (c == "#" && (previous == "" || previous ~ /[[:space:];|&(){}]/)) break
            else out = out c
            previous = c
        }
        return out
    }

    # Recognize the conventional literal delimiters used by repository shell
    # scripts. Unusual/dynamic heredocs merely remain visible and can only make
    # this deliberately conservative guard louder, never hide production code.
    function heredoc_start(s,   value) {
        value = s
        if (value !~ /<<-?[[:space:]]*[\047\"]?[A-Za-z_][A-Za-z0-9_]*[\047\"]?/) return ""
        sub(/^.*<<-?[[:space:]]*/, "", value)
        sub(/[[:space:];|&].*$/, "", value)
        gsub(/^[\047\"]|[\047\"]$/, "", value)
        return value
    }

    # Split only on shell command separators. Once a literal grep token is
    # seen, any quiet option in that command violates the invariant. This
    # naturally covers command/env/time prefixes without parsing wrappers.
    function quiet_grep(s,   fields, count, i, token, grep_seen) {
        gsub(/[;|&(){}]/, " \034 ", s)
        count = split(s, fields, /[[:space:]]+/)
        grep_seen = 0
        for (i = 1; i <= count; i++) {
            token = fields[i]
            if (token == "\034") {
                grep_seen = 0
                continue
            }
            if (token == "grep" || token ~ /\/grep$/) {
                grep_seen = 1
                continue
            }
            if (!grep_seen) continue
            if (token == "--") {
                grep_seen = 0
                continue
            }
            if (token ~ /^--(quiet|silent)(=.*)?$/ || token ~ /^-[[:alnum:]]*q[[:alnum:]]*$/) return 1
        }
        return 0
    }

    {
        raw = $0
        if (heredoc != "") {
            end = raw
            if (strip_tabs) sub(/^\t+/, "", end)
            if (end == heredoc) {
                heredoc = ""
                strip_tabs = 0
            }
            next
        }

        code = code_only(raw)
        logical = logical code
        if (code ~ /\\[[:space:]]*$/) {
            # Backslash-newline consumes the newline, not the first character
            # on the following line. Keep quote state; clear the escape.
            escaped = 0
            sub(/\\[[:space:]]*$/, " ", logical)
            next
        }

        if (quiet_grep(logical))
            printf "%s:%d: quiet-mode grep is banned in production shell; use ordinary grep with output redirected to /dev/null\n", FILE, FNR
        logical = ""

        delimiter = heredoc_start(raw)
        if (delimiter != "") {
            heredoc = delimiter
            strip_tabs = (raw ~ /<<-/)
        }
    }
    END {
        if (logical != "" && quiet_grep(logical))
            printf "%s:%d: quiet-mode grep is banned in production shell; use ordinary grep with output redirected to /dev/null\n", FILE, FNR
    }
    ' <"$path"
done >"$findings"

if [ -s "$findings" ]; then
    sort -t: -k1,1 -k2,2n "$findings" >&2
    echo >&2
    echo "lint-shell-robustness: $(wc -l <"$findings" | tr -d ' ') finding(s)" >&2
    exit 1
fi

if [ "$repo_only" -eq 1 ]; then
    echo "lint-shell-robustness: ${#files[@]} tracked production file(s) clean"
else
    echo "lint-shell-robustness: ${#files[@]} production file(s) clean"
fi
