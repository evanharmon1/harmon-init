#!/usr/bin/env bash
# lint-shell-robustness.sh — guard the two shell idioms whose EXIT STATUS LIES.
#
# 1. `PRODUCER | grep -q PATTERN` under `set -o pipefail` (#689). # shell-robustness: ok — this line names the shape the guard forbids
#    `grep -q` exits the moment it matches. The producer is usually still
#    writing, so it takes SIGPIPE and dies 141; `pipefail` then reports the
#    whole pipeline as FAILED even though grep MATCHED. Measured here: 0/100
#    false failures at 150 B, 1/100 at 1.5 kB, 94/100 at 84 kB, 200/200 at
#    349 kB. Seen in production, not just tests — the triage skill's
#    `axes_active()` silently dropped a classification axis this way.
#
#      grep -qF "$needle" <<<"$haystack"          # a string
#      grep -q PATTERN < <(some-command --args)   # a command
#      out="$(cmd)" && grep -q PATTERN <<<"$out"  # when cmd's success is
#                                                 # itself part of the check
#
# 2. A test reporter (`ok`, `bad`, `pass`, …) that does not end in `return 0`.
#    Assertions are written `check && ok "…" || bad "…"`, so the reporter's own
#    status sits inside the branch: if its `echo` fails on the grouped-output
#    pipe `task` runs suites under, a PASSING assertion reports as a failure.
#
#      ok() {
#          pass=$((pass + 1))
#          echo "  ✓ $*" || true
#          return 0
#      }
#
# WHY THIS IS DELIBERATELY OVER-EAGER, AND HAS NO PARSER
#
# The first version of this guard parsed shell: it tracked quote, here-doc and
# command-substitution state so it could tell code from text. Four adversarial
# review rounds found ELEVEN ways to make that lexer report a file clean while
# the forbidden construct was plainly present — a herestring read as a here-doc
# opener, an apostrophe in a comment, a multi-line command substitution, a
# quote closing mid-line, several here-docs on one line, `<<EOF-X`, backticks,
# continued option lines, a brace on its own line, and more. Shell grammar is
# much larger than any subset a guard can afford to model, so that list was
# never going to close.
#
# A guard that reports a dirty tree CLEAN is worse than no guard, because
# people trust it. So this version does not try to be clever: it matches TEXT,
# flags everything that looks like the forbidden shape — inside comments, inside
# here-doc bodies, inside quoted strings, everywhere — and makes each genuine
# exception state itself out loud:
#
#   … code …                # shell-robustness: ok — why this one is fine
#
#   # shell-robustness: begin-exempt — why this whole region is fine
#   … lines, e.g. a here-doc whose body must stay byte-exact …
#   # shell-robustness: end-exempt
#
#   # shell-robustness: exempt-file — why every match in this file is deliberate
#
# Every form REQUIRES a reason after the em dash (or `--`); a marker without one
# is itself an error, so the escape hatch cannot be used silently. False
# positives are loud and cost a reviewer one annotation. False negatives were
# invisible and cost four review rounds.
#
# TWO KNOWN LIMITATIONS, both accepted deliberately. Closing either needs the
# parsing this guard exists to avoid, and each fails in a bounded way:
#
#   * A here-doc fixture containing a well-formed `begin-exempt` … `end-exempt`
#     pair exempts the real code between those fixtures. Telling a marker in
#     fixture text from a marker in code needs here-doc tracking — the lexer
#     that produced a bypass in every review round. Mitigations: `exempt-file`,
#     which disables a WHOLE file, is restricted to the file header where
#     fixture text cannot reach; both markers must carry a reason; and an
#     unclosed block is itself reported.
#
# Known coverage gap in the pipeline half: the `grep` token itself is matched
# literally, so a path-qualified (`/usr/bin/grep`), escaped (`\grep`) or quoted
# spelling is not seen. No such spelling exists in this tree today; the
# remaining forms are enumerated in #848 to be closed in one change rather than
# one review round at a time.
#
# The two halves are not equally strong, and the header says so rather than
# leaving a reader to assume otherwise. The PIPELINE check above is a stateless
# text match and is the deliverable of #689. The REPORTER check below is
# structural — it finds a definition and scans its block — and is therefore
# BEST-EFFORT: its remaining corners (the `function NAME {` stop-condition
# spelling, and its siblings) are enumerated and tracked in #838 rather than
# closed one per review round. It exists to stop the reporter defect returning
# in the obvious form, not to prove path-completeness.
#
#   * The reporter check asks whether an executable `return 0` is PRESENT in
#     the block, so one inside an `if` satisfies it even though the ordinary
#     path may still end on a failing `echo`. Answering "does every path end
#     safely" is body and path analysis, which was deleted from this guard
#     after producing a finding in every round. The `return 0` sweep in the
#     change that introduced this guard already removed the defect tree-wide;
#     this check exists to stop it returning in the obvious form.
#
# Scope: the same root shell surface as lint-shell.sh — every tracked *.sh and
# *.bash outside template/ — plus shell scripts under template/scripts/, whose
# conditional Jinja filenames do not literally end in the shell extension.
# Other template paths are rendered and linted by test:template. The reporter
# check additionally applies only to test-*.sh / test-*.bash suites.
#
# Usage: ./scripts/lint-shell-robustness.sh [file ...]
#   With no arguments, checks every tracked file in scope.
set -euo pipefail

REPO_ONLY=0
files=()
if [ $# -gt 0 ]; then
    files=("$@")
    for f in "$@"; do
        [ -f "$f" ] || {
            # A path the caller NAMED and that is not there is an error, never
            # a clean file: this guard must not report on what it never read.
            echo "lint-shell-robustness: no such file: $f" >&2
            exit 1
        }
    done
else
    REPO_ONLY=1
    cd "$(git rev-parse --show-toplevel)"
    # Enumerate the whole index once, then apply the authoritative shell-scope
    # invariant: every tracked root *.sh/*.bash outside template/, plus the
    # template/scripts convention including conditional Jinja suffixes. A list
    # of root directories would drift whenever another shell surface is added.
    #
    # NUL-delimited: a tracked filename may legally contain a newline, and
    # splitting one into nonexistent pieces would silently shrink the scan.
    # Captured, not process-substituted: `< <(git …)` discards git's exit
    # status, so a partial index read would silently shrink the scan and the
    # guard would call the remainder clean. That is this PR's own defect class.
    _list="$(mktemp)"
    if ! git ls-files -z -- >"$_list"; then
        rm -f "$_list"
        echo "lint-shell-robustness: could not enumerate tracked shell files" >&2
        exit 1
    fi
    while IFS= read -r -d '' f; do
        case "$f" in
        template/scripts/*.sh | template/scripts/*.bash | \
            template/scripts/*.sh'[% endif %]' | template/scripts/*.bash'[% endif %]')
            files+=("$f")
            ;;
        template/*) ;;
        *.sh | *.bash) files+=("$f") ;;
        esac
    done <"$_list"
    rm -f "$_list"
fi

[ ${#files[@]} -gt 0 ] || {
    echo "lint-shell-robustness: no shell scripts in scope" >&2
    exit 1
}

findings="$(mktemp)"
trap 'rm -f "${findings}"' EXIT

for f in "${files[@]}"; do
    # Byte-oriented so token normalization remains deterministic when a
    # fixture or generated asset contains malformed locale input.
    LC_ALL=C awk -v FILE="$f" '
    # The reason must follow the MARKER. Matching a dash anywhere on the line
    # let an earlier `--option` stand in for it, so
    # `producer | grep --quiet x # shell-robustness: ok` passed with no reason
    # at all — silently, which is the one thing this design exists to prevent.
    function reason_ok(s,   t) {
        t = s
        if (!sub(/^.*shell-robustness:[[:space:]]*(ok|begin-exempt|exempt-file)[[:space:]]*/, "", t)) return 0
        return (t ~ /^(—|--)[[:space:]]*[^[:space:]]/)
    }

    # Match the invariant, not a list of syntax combinations: either shell
    # pipe operator, then an optional compound-command opener, then a grep
    # invocation carrying a quiet flag. Adding another operator/wrapper cross
    # product must not require another regex branch.
    # Quoted grep operands are still one token when they contain whitespace or
    # shell separators. Mask only those quoted boundaries before applying the
    # deliberately textual matcher; this is token normalization, not an attempt
    # to classify code versus comments/here-docs/strings.
    function token_boundary(c) {
        return (c ~ /[[:space:]|);&]/ || c == "]")
    }
    function mask_quoted_token_boundaries(s,   out, i, c, quote, escaped, sq) {
        out = ""
        quote = ""
        escaped = 0
        sq = sprintf("%c", 39)
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (quote != "") {
                if (escaped) {
                    out = out (token_boundary(c) ? "_" : c)
                    escaped = 0
                }
                else if (quote == "\"" && c == "\\") {
                    out = out "_"
                    escaped = 1
                }
                else if (c == quote) {
                    out = out "_"
                    quote = ""
                }
                else {
                    out = out (token_boundary(c) ? "_" : c)
                }
            }
            else if (c == sq || c == "\"") {
                out = out "_"
                quote = c
            }
            else {
                out = out c
            }
        }
        return out
    }
    function quiet_grep_rhs(s) {
        s = mask_quoted_token_boundaries(s)
        return (s ~ /^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec|time|timeout|nice)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]+[^[:space:]|)\];&]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
    }
    function hazardous_quiet_grep_pipeline(s,   rest, pos, before, after, rhs) {
        rest = s
        while ((pos = index(rest, "|")) > 0) {
            before = (pos > 1 ? substr(rest, pos - 1, 1) : "")
            after = substr(rest, pos + 1)
            # `||` is an or-list, not a pipeline. Advance past either half.
            if (substr(after, 1, 1) == "|") {
                rest = substr(after, 2)
                continue
            }
            if (before == "|") {
                rest = after
                continue
            }
            if (substr(after, 1, 1) == "&") after = substr(after, 2)
            rhs = after
            sub(/^[[:space:]]*/, "", rhs)
            sub(/^[({][[:space:]]*/, "", rhs)
            if (quiet_grep_rhs(rhs)) return 1
            rest = after
        }
        return 0
    }

    # Exemption markers. Each needs a reason; a bare marker is itself reported.
    # Header state, updated BEFORE the exemption rules below. Computing it
    # after them rejected a declaration on line 1 of a sourced fragment, and
    # then advised moving it above the first line of code — where it already was.
    { if (FNR == 1) in_header = 1
      if (in_header && $0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/ && $0 !~ /^#!/) in_header = 0 }

    # A file-level exemption is only honoured in the file HEADER — the comment
    # block before the first line of code. Otherwise a here-doc fixture that
    # merely CONTAINS a well-formed marker would switch the gate off for the
    # rest of the file, and this scanner reads here-doc text on purpose.
    /shell-robustness:[[:space:]]*exempt-file/ {
        if (!in_header) {
            # Not a live claim inside an already-exempt region: there it is
            # fixture text, which is exactly what this rule exists to ignore.
            if (!exempt_file && !block)
                printf "%s:%d: `exempt-file` outside the file header is ignored — move it above the first line of code\n", FILE, FNR
        }
        else if (reason_ok($0)) exempt_file = 1
        else printf "%s:%d: `exempt-file` marker with no reason after the dash\n", FILE, FNR
        next
    }
    /shell-robustness:[[:space:]]*begin-exempt/ {
        if (reason_ok($0)) { block = 1; block_line = FNR } else { printf "%s:%d: `begin-exempt` marker with no reason after the dash\n", FILE, FNR }
        next
    }
    /shell-robustness:[[:space:]]*end-exempt/ {
        if (!block) printf "%s:%d: `end-exempt` with no open `begin-exempt`\n", FILE, FNR
        block = 0
        block_line = 0
        next
    }

    {
        # The header is the leading run of blank, shebang and comment lines.

        line = $0
        inline_ok = 0
        if (line ~ /shell-robustness:[[:space:]]*ok/) {
            if (reason_ok(line)) inline_ok = 1
            # A reasonless marker is a finding — but not inside a region that
            # is already exempt, where the marker is fixture text rather than
            # a live claim.
            else if (!exempt_file && !block) printf "%s:%d: `ok` marker with no reason after the dash\n", FILE, FNR
        }
        skip = (exempt_file || block || inline_ok)

        # R1 — `|` or `|&`, optionally followed by `(` or `{`, feeding a grep
        # that carries a quiet flag. Every combination has the same hazard.
        if (!skip && hazardous_quiet_grep_pipeline(line))
            printf "%s:%d: `| grep -q` / `|& grep -q`; optional compound-command RHS does not prevent SIGPIPE from turning a MATCH into a failure\n", FILE, FNR
        # R2 — a pipe feeding a grep whose options continue on the next line.
        else if (!skip && line ~ /(^|[^|])\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]+[^[:space:]|)\];&]+)*[[:space:]]*\\[[:space:]]*$/)
            printf "%s:%d: `| grep \\` — options continue on the next line; a quiet flag here would be the SIGPIPE shape\n", FILE, FNR
        # R3a — the previous line ends with a SINGLE pipe (not `||`, which is
        # an or-list, and not `\`, which continues an argument list) and this
        # line leads with a quiet grep.
        else if (!skip && prev ~ /(^|[^|])\|[[:space:]]*\\?[[:space:]]*$/ &&
                 line ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]+[^[:space:]|)\];&]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: continued `| grep -q` pipeline — same SIGPIPE shape, split across lines\n", FILE, FNR
        # R3b — this line itself leads with the pipe (`producer \` then `| grep -q`).
        else if (!skip && line ~ /^[[:space:]]*\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]+[^[:space:]|)\];&]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: continued `| grep -q` pipeline — same SIGPIPE shape, split across lines\n", FILE, FNR
        # R3c — BOTH continuations at once: `producer |`, then `grep \`, then
        # `-q pattern` on a third line. R3a wants the flag on the grep line and
        # R2 wants the pipe and grep to share one, so neither sees this alone.
        else if (!skip && grep_cont &&
                 line ~ /(^|[[:space:]])(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: continued `| grep -q` pipeline — the quiet flag continues onto a third line\n", FILE, FNR

        # One bit of state: a PIPED grep whose option list is still open across
        # backslash continuations. This is the only cross-line state the guard
        # keeps, and it tracks a formatting fact rather than shell grammar.
        if (line ~ /\\[[:space:]]*$/ &&
            (grep_cont ||
             (prev ~ /(^|[^|])\|[[:space:]]*\\?[[:space:]]*$/ && line ~ /^[[:space:]]*\|?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]|$)/) ||
             line ~ /(^|[^|])\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]|]*[[:space:]]+)*((command|env|exec)[[:space:]]+([^[:space:]|)\];&]+[[:space:]]+)*)?grep([[:space:]]|$)/))
            grep_cont = 1
        else
            grep_cont = 0

        prev = $0
    }

    # An unclosed block would suppress every later finding in the file, so the
    # typo must be the error rather than a silent licence.
    END {
        if (block) printf "%s:%d: `begin-exempt` is never closed — everything after it would be silently exempt\n", FILE, block_line
    }
    ' <"$f"
done >>"$findings"

# ── reporter helpers (test suites only) ─────────────────────────────────────
for f in "${files[@]}"; do
    case "${f##*/}" in
    test-*.sh | test-*.bash | test-*.sh'[% endif %]' | test-*.bash'[% endif %]' | \
        '[% if '*'%]test-'*.sh'[% endif %]' | '[% if '*'%]test-'*.bash'[% endif %]') ;;
    *) continue ;;
    esac
    # The file arrives on STDIN, never as an awk operand: awk reads an operand
    # matching `name=value` as a variable assignment, so a tracked file legally
    # named `x=y.sh` would be silently skipped while the guard reported clean.
    awk -v FILE="$f" '
    function reason_ok(s,   t) {
        t = s
        if (!sub(/^.*shell-robustness:[[:space:]]*(ok|begin-exempt|exempt-file)[[:space:]]*/, "", t)) return 0
        return (t ~ /^(—|--)[[:space:]]*[^[:space:]]/)
    }
    function definition_line(s) {
        return (s ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?([[:space:]]*\{.*)?[[:space:]]*$/ &&
                s ~ /(^[[:space:]]*function[[:space:]]|\(\))/)
    }
    function finish_reporter() {
        if (!reporter_active) return
        if ((reporter_named || reporter_counts) && !reporter_found)
            printf "%s:%d: reporter `%s()` — no `return 0` in its block, so its own status is read as the assertion s. Add `return 0`, or annotate it if it always exits.\n", FILE, reporter_open, reporter_name
        reporter_active = 0
    }
    function inspect_reporter_line(s) {
        if (s ~ /shell-robustness:[[:space:]]*ok/ && reason_ok(s)) reporter_found = 1
        else if (s !~ /^[[:space:]]*#/ &&
                 s ~ /(^|;)[[:space:]]*return 0[[:space:]]*;?[[:space:]]*(\}[[:space:]]*)?$/) reporter_found = 1
        if (s !~ /^[[:space:]]*#/ && s ~ /[A-Za-z_][A-Za-z0-9_]*=\$\(\([A-Za-z_]/) reporter_counts = 1
    }
    function start_reporter(s,   name) {
        name = s
        sub(/^[[:space:]]*function[[:space:]]+/, "", name)
        sub(/[[:space:]]*\(\).*$/, "", name)
        sub(/[[:space:]]*\{.*$/, "", name)
        gsub(/[[:space:]]/, "", name)
        reporter_active = 1
        reporter_name = name
        reporter_named = (name ~ /^(ok|bad|pass|fail|failed|good|note|warn|skip|skipped|report|expect|start)$/)
        reporter_open = FNR
        reporter_counts = 0
        reporter_found = 0
        inspect_reporter_line(s)
    }
    { if (FNR == 1) in_header = 1
      if (in_header && $0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/ && $0 !~ /^#!/) in_header = 0 }
    /shell-robustness:[[:space:]]*exempt-file/ { if (in_header && reason_ok($0)) exempt_file = 1; next }
    /shell-robustness:[[:space:]]*begin-exempt/ { if (reason_ok($0)) block = 1; next }
    /shell-robustness:[[:space:]]*end-exempt/ { block = 0; next }
    exempt_file || block { next }

    # A reporter-named definition, in any of bash s four spellings and whether
    # or not the opening brace shares the line. Its block is then scanned for
    # the PRESENCE of `return 0` — nothing more.
    #
    # This deliberately does not parse the body. Earlier versions matched
    # braces, classified `exit` as terminating or not, and special-cased
    # one-line definitions; every review round found another corner in that
    # analysis, the last being a standalone `}` inside a here-doc that
    # generates shell fixture text. Presence-of-`return 0` has no corners: the
    # block ends at the first top-level `}`, the next definition, or EOF, and
    # stopping early can only produce a LOUD false positive that one
    # annotation answers.
    {
        if (definition_line($0)) {
            # Every input record is examined by the AWK outer loop. Finalize the
            # previous function before starting this one; `getline` consumed
            # exactly the reporter definition it was meant to protect.
            finish_reporter()
            start_reporter($0)
            if ($0 ~ /\}[[:space:]]*$/) finish_reporter()
            next
        }
        if (!reporter_active) next
        inspect_reporter_line($0)
        if ($0 ~ /^\}/) finish_reporter()
        next
    }
    END { finish_reporter() }
    ' <"$f"
done >>"$findings"

if [ -s "$findings" ]; then
    sort -t: -k1,1 -k2,2n "$findings" >&2
    echo >&2
    echo "lint-shell-robustness: $(wc -l <"${findings}" | tr -d ' ') finding(s)." >&2
    echo "  Fixed shapes and the exemption markers are documented at the top of" >&2
    echo "  scripts/lint-shell-robustness.sh. This guard is deliberately over-eager:" >&2
    echo "  if a match is genuinely fine, say so inline with a reason." >&2
    exit 1
fi

if [ "$REPO_ONLY" -eq 1 ]; then
    echo "lint-shell-robustness: ${#files[@]} tracked file(s) clean"
else
    echo "lint-shell-robustness: ${#files[@]} file(s) clean"
fi
