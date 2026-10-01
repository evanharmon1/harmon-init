#!/usr/bin/env bash
# test-remote-codex-policy.sh — guard the remote second-model rule: ephemeral
# cloud environments never hold Codex credentials, and a persistent environment
# holds exactly one Codex login of its own (AGENTS.md § "Remote environments").
#
# The rule is easy to break without noticing: one line in a bootstrap, an env
# example, a workflow, or an adapter guide that tells a throwaway VM to run a
# Codex login, restore a copied auth file, or export an OpenAI API key
# contradicts it, and nothing else in the repository reads those lines together.
# This scans the remote-environment surfaces that exist in the repository under
# test (this script is a verbatim twin, so it runs in generated repos too, where
# several root-only surfaces are absent) for the credential vocabulary below,
# and fails with file:line on any hit the allowlist does not explain.
#
# Case-sensitive on purpose: the lowercase forms are the commands and the file
# names; the prose "a Codex login" that states the rule is not a violation.
# A backslash-continued command is joined before matching, so `codex \` followed
# by `login` is one line, reported at the line it starts on.
#
# What counts as a login is the invariant, not a literal: the word `codex`, then
# any option words (each starting with `-`, with an optional value), then the
# word `login`, on one normalised line — so `codex --no-alt-screen login` is
# caught like `codex login`. The same shape split across two lines (a folded
# YAML step) is caught too and reported as `file:L1-L2: <line 1> / <line 2>`; a
# folded hit cannot be allowlisted, the source has to be rewritten.
#
# OPENAI_API_KEY alone is legitimate application configuration (a generated
# project may use it for its own app), so only its Codex use is the rule's
# subject: the key is reported on a line that also mentions `codex`, in any case.
#
# The allowlist excuses a line only when its COMPLETE text equals an entry for
# that file — never a substring — compared in the normalised form (runs of
# blanks collapsed) on both sides — so a prescriptive sentence that quotes an
# excused phrase still fails, and editing an excused line re-opens it for review.
#
# Residual: this is a textual, best-effort control. It cannot catch every
# spelling (a variable holding the command name, an encoded path, a login driven
# by a tool it does not scan). It stops the plain and the accidental ones, and
# the self-test below proves it does that for every token and both pattern
# rules. Two more, stated plainly:
#   - An allowlisted line is excused by its exact text anywhere in its file, so
#     moving an operator-only line verbatim into a remote-lane section is not
#     caught. Review catches that; the guard does not.
#   - Only the `~/.codex` and trailing-slash `.codex/` spellings are matched, so
#     `$HOME/.codex` or `/home/vscode/.codex` without a slash is not. A bare
#     `.codex` token is deliberately not used: the agent devcontainer mounts that
#     directory legitimately, and the persistent login lives in it.
# A full YAML or shell parser is out of scope.
#
# Self-proving: a planted violation in a temporary copy of the surfaces must
# fail, for every token, so a scan that silently stopped matching cannot pass.
# No login of any kind is performed and nothing is written outside a temp dir.
#
# Offline and metadata-only. Run via `task test:remote-codex-policy`.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
# A self-test case may chmod a copy unreadable; restore access (the search bit
# too) before removing, and never let a failed chmod skip the removal.
trap 'chmod -R u+rwX "${TMP}" 2>/dev/null || :; rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Plain credential vocabulary: each names a login flag, or the file or directory a
# login leaves behind. Two pattern rules complement it inside the awk matcher: a
# Codex login (the invariant above) and OPENAI_API_KEY on a line that mentions
# `codex`.
TOKENS=(
    'auth.json'
    '--device-auth'
    '--with-api-key'
    '--with-access-token'
    '~/.codex'
    '.codex/'
)

# Scope rule: remote-environment configuration and documentation are scanned.
# Directories are scanned recursively, files directly; whatever does not exist in
# the repository under test is skipped. All of docs/ is scanned (so a new adapter
# page is covered the day it is added) except docs/research/, which assesses
# rejected options rather than guiding anyone. scripts/ is excluded because its
# Codex scripts are operator-machine tooling that legitimately logs in locally —
# so a NEW remote setup script must be added to SURFACE_FILES to be covered.
SURFACE_DIRS=(
    'images/devcontainer'
    '.devcontainer'
    '.github/workflows'
    '.github/actions'
    'docs'
)
EXCLUDE_DIRS=(
    'docs/research'
)
SURFACE_FILES=(
    'scripts/setup-remote.sh'
    'AGENTS.md'
)

# Allowlist: "file@@complete line@@reason".
ALLOW=(
    '.devcontainer/config/claude-hooks/protect-files.sh@@    ".codex/config.toml"@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-managed-config.toml@@# silently outranks `-c`, ~/.codex/config.toml and a trusted project@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-managed-config.toml@@# .codex/config.toml. (The explicit `-m` flag still beat a pinned `model`,@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# `-c` flags, ~/.codex/config.toml and a project'"'"'s .codex/config.toml alike --@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# and a trusted project .codex/config.toml. Pinning model_reasoning_effort@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# first: ~/.codex/config.toml, a trusted project .codex/config.toml, then `-c`@@configuration path in a comment or protected-path list, not a credential'
    'docs/guides/codex-review.md@@2. **Authenticate**: `codex login` (browser OAuth against a ChatGPT account —@@operator-machine setup: browser OAuth on the operator'"'"'s own ChatGPT login'
    'docs/guides/codex-review.md@@   `printenv OPENAI_API_KEY | codex login --with-api-key` (billed API usage).@@operator-machine alternative (billed API usage), not a remote environment'
    'docs/guides/codex-review.md@@   Confirm with `codex login status`.@@read-only status probe; it performs no login'
    'docs/guides/codex-review.md@@   `.codex/config.toml` raises the project-instruction budget to 64 KiB. Review@@configuration path, not a credential'
    'docs/guides/codex-review.md@@`task codex:gate:enable` refuses to arm the gate unless `codex login status`@@read-only status probe in the stop-gate'"'"'s login check'
    'docs/guides/codex-review.md@@`codex login` or `task codex:gate:disable` (disable/status never require@@operator-machine remedy for the stop-gate'"'"'s login check'
    'docs/guides/codex-review.md@@- **Auth expired** — `codex login status`, then `codex login` (or@@operator-machine troubleshooting: re-authenticate after expiry'
    'docs/guides/codex-review.md@@  `codex login --device-auth` without a browser).@@operator-machine troubleshooting on a host without a browser'
    'docs/guides/codex-review.md@@  `~/.codex/config.toml`, and a trusted project `.codex/config.toml` alike,@@configuration path, not a credential'
    'docs/copier-options.md@@| 18 | `use_shared_agents` | bool | **yes** | `use_skills_sync` | Also vendors devkit subagents into `.claude/agents` + `.codex/agents/implementer.toml` |@@the repository'"'"'s own .codex/agents/ configuration path, not a credential'
    'docs/copier-options.md@@| `use_skills_sync and use_shared_agents` | `.codex/agents/implementer.toml` |@@the repository'"'"'s own .codex/agents/ configuration path, not a credential'
    # The next entry and the one for (harmon-init#1406) are the root and template wording of the same sentence.
    'docs/guides/devcontainers.md@@environment persists one (#1406), lives in the `~/.codex` volume, not the@@where the persistent login lives: the volume, not the env-file'
    'docs/guides/devcontainers.md@@The environment runs `codex login` once, at provisioning, and its@@the rule itself: a persistent environment holds exactly one login, and its file never leaves it'
    'docs/guides/devcontainers.md@@`~/.codex/auth.json` is never copied to another machine (the refresh token is@@the rule itself: a persistent environment holds exactly one login, and its file never leaves it'
    'docs/guides/devcontainers.md@@  - Substring patterns: `.claude/settings.json`, `.codex/config.toml`, `/etc/claude-code/`, `/etc/codex/`@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@is an unoverridable requirement that beats `-c`, `~/.codex/config.toml` and a@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@trusted project `.codex/config.toml` without saying so. Only the sandbox and@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@persist regardless, in the `~/.claude`, `~/.codex`, `~/.local/share/opencode`,@@the list of persisted home directories'
    'docs/architecture/remote-environments.md@@| **agents** | yes | The Codex CLI at the image'"'"'s pin. Used only where an environment persists and holds its own login (#1406); ephemeral clouds install it and never log in. A persistent environment runs `codex login` once, at provisioning, and its `~/.codex/auth.json` is never copied to another machine: the refresh token is single-use, so a copy would invalidate both holders |@@the rule itself: a persistent environment holds exactly one login, and its file never leaves it'
    'docs/guides/devcontainers.md@@environment persists one (harmon-init#1406), lives in the `~/.codex` volume, not the@@where the persistent login lives: the volume, not the env-file'
)

# norm TEXT — collapse every run of blanks (spaces and tabs) to one space, so
# `codex  login` and a tab-separated form read like `codex login`. Tokens are
# matched, and the allowlist compared, on this normalised form on both sides.
norm() {
    local s="${1//$'\t'/ }"
    while [[ "$s" == *"  "* ]]; do
        s="${s//  / }"
    done
    printf '%s' "$s"
}

# The allowlist in compare form, computed once: normalising inside the scan loop
# forks per entry per hit, and the self-test scans many times.
ALLOW_FILES=()
ALLOW_TEXTS=()
for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    ALLOW_FILES+=("${entry%%@@*}")
    etext="${entry#*@@}"
    ALLOW_TEXTS+=("$(norm "${etext%%@@*}")")
done

# scan ROOT — print "file:line:text" for every unexplained hit under ROOT (text
# normalised, backslash-continued lines joined and numbered by the physical line
# they start on), then "SCANNED n". A file that cannot be read prints
# "GUARD-ERROR ..." instead and no SCANNED line. Always returns 0; the caller
# reads the output.
#
# One grep classifies every file (text vs empty/binary) and one awk matches the
# tokens across all the text files, so a scan costs two processes, not three per
# file — the self-test runs it many times.
scan() {
    local root="$1" file line text entry efile etext tokstr rc hits allowed listing d f k scanned=0
    local files=() textfiles=() prune_args=() x
    for x in "${EXCLUDE_DIRS[@]}"; do
        prune_args+=(-path "${root}/${x}" -prune -o)
    done
    for d in "${SURFACE_DIRS[@]}"; do
        if [ -d "${root}/${d}" ]; then
            # find's own exit status must be seen: a directory it cannot list
            # would otherwise drop out of the scan and still pass. The listing
            # lives under TMP, removed by the EXIT trap.
            listing="$(mktemp "${TMP}/listing.XXXXXX")"
            if ! find "${root}/${d}" "${prune_args[@]}" -type f -print >"$listing" 2>/dev/null ||
                ! LC_ALL=C sort -o "$listing" "$listing" 2>/dev/null; then
                echo "GUARD-ERROR guard could not list ${d}"
                return 0
            fi
            while IFS= read -r file; do
                files+=("${file#"${root}"/}")
            done <"$listing"
        fi
    done
    for f in "${SURFACE_FILES[@]}"; do
        [ -f "${root}/${f}" ] && files+=("$f")
    done
    for file in "${files[@]+"${files[@]}"}"; do
        if [ ! -r "${root}/${file}" ]; then
            echo "GUARD-ERROR guard could not read ${file}"
            return 0
        fi
        scanned=$((scanned + 1))
    done
    [ "$scanned" -gt 0 ] || {
        echo "SCANNED 0"
        return 0
    }
    # grep -Il: 0/1 = ran (1 = no text file at all), 2+ = error.
    rc=0
    hits="$(cd "$root" && grep -Il . -- "${files[@]}" 2>/dev/null)" || rc=$?
    if [ "$rc" -ge 2 ]; then
        echo "GUARD-ERROR guard could not read the surface files"
        return 0
    fi
    if [ -n "$hits" ]; then
        while IFS= read -r file; do
            textfiles+=("./${file}")
        done <<<"$hits"
        tokstr="$(printf '%s\037' "${TOKENS[@]}")"
        rc=0
        hits="$(cd "$root" && awk -v tokens="$tokstr" '
            function emit(f, s, t,   i, tt, hit) {
                gsub(/[ \t]+/, " ", t)
                tt = t
                sub(/^ /, "", tt)
                # A Codex command folded across two lines (a YAML `>-` step):
                # `codex` and options end one line, options and `login` open the
                # next non-blank line. Reported with both real lines.
                if (pend != "" && tt != "") {
                    if (tt ~ FOLDTAIL) print pfile ":" pline "-" s ": " pend " / " tt
                    pend = ""
                }
                hit = 0
                for (i = 1; i <= n; i++) {
                    if (T[i] != "" && index(t, T[i])) {
                        print substr(f, 3) ":" s ":" t
                        hit = 1
                        break
                    }
                }
                # The key alone is application configuration; only its Codex use
                # is the rule'"'"'s subject.
                if (!hit && index(t, "OPENAI_API_KEY") && tolower(t) ~ /codex/) {
                    print substr(f, 3) ":" s ":" t
                    hit = 1
                }
                if (!hit && t ~ LOGIN) {
                    print substr(f, 3) ":" s ":" t
                    hit = 1
                }
                if (!hit && t ~ FOLDHEAD) {
                    pend = t
                    pfile = substr(f, 3)
                    pline = s
                }
            }
            BEGIN {
                n = split(tokens, T, "\037")
                W = "(^|[^A-Za-z0-9_-])codex( -[^ ]+( [^ -][^ ]*)?)*"
                LOGIN = W " login([^A-Za-z0-9_-]|$)"
                FOLDHEAD = W " ?$"
                FOLDTAIL = "^(-[^ ]+ ([^ -][^ ]* )?)*login([^A-Za-z0-9_-]|$)"
            }
            FNR == 1 {
                if (cont) { emit(pf, start, buf); buf = ""; cont = 0 }
                pf = FILENAME
                pend = ""
            }
            {
                line = $0
                if (line ~ /\\$/) {
                    if (!cont) start = FNR
                    sub(/\\$/, "", line)
                    buf = buf line
                    cont = 1
                    next
                }
                if (cont) { emit(FILENAME, start, buf line); buf = ""; cont = 0 }
                else emit(FILENAME, FNR, line)
            }
            END { if (cont) emit(pf, start, buf) }' "${textfiles[@]}" 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "GUARD-ERROR guard could not scan the surface files"
            return 0
        fi
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            file="${line%%:*}"
            text="${line#*:}"
            text="${text#*:}"
            allowed=0
            for ((k = 0; k < ${#ALLOW_FILES[@]}; k++)); do
                [ "${ALLOW_FILES[k]}" = "$file" ] || continue
                [ "$text" = "${ALLOW_TEXTS[k]}" ] && allowed=1
            done
            [ "$allowed" -eq 1 ] || echo "$line"
        done <<<"$hits"
    fi
    echo "SCANNED ${scanned}"
}

# split_scan OUTPUT — set SCAN_ERR (a GUARD-ERROR line or empty), SCAN_HITS and
# SCAN_COUNT from scan's output.
split_scan() {
    SCAN_ERR="" SCAN_HITS="" SCAN_COUNT=""
    # scan emits a guard error as a line that BEGINS with the marker; a hit line
    # begins with its file path, so a surface line quoting the marker is a hit.
    if SCAN_ERR="$(printf '%s\n' "$1" | grep '^GUARD-ERROR ')" && [ -n "$SCAN_ERR" ]; then
        return 0
    fi
    SCAN_ERR=""
    SCAN_COUNT="${1##*SCANNED }"
    SCAN_HITS="${1%SCANNED *}"
    SCAN_HITS="${SCAN_HITS%$'\n'}"
}

# --- 1. The repository under test is clean ---
split_scan "$(scan "$PWD")"
[ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
scanned="$SCAN_COUNT"
[ "$scanned" -gt 0 ] || fail "no remote-environment surface was scanned; the guard would pass vacuously"
[ -z "$SCAN_HITS" ] ||
    fail "a remote-environment surface carries Codex credential vocabulary not explained by the allowlist:
${SCAN_HITS}
The rule (AGENTS.md § \"Remote environments\"): ephemeral clouds never hold Codex credentials; a persistent environment holds one login of its own. Remove the line, or — only if it is the rule itself, a configuration path, or an operator-machine instruction — add a reasoned ALLOW entry holding the complete line."
echo "==> clean: ${scanned} surface files scanned, no unexplained Codex credential vocabulary"

# --- 2. Load-bearing: planted violations in a temporary copy must fail ---
FIX="${TMP}/fixture"
mkdir -p "$FIX"
for d in "${SURFACE_DIRS[@]}"; do
    if [ -d "$d" ]; then
        mkdir -p "${FIX}/$(dirname "$d")"
        cp -R "$d" "${FIX}/$d"
    fi
done
for f in "${SURFACE_FILES[@]}"; do
    if [ -f "$f" ]; then
        mkdir -p "${FIX}/$(dirname "$f")"
        cp "$f" "${FIX}/$f"
    fi
done

fixture_hits() {
    split_scan "$(scan "$FIX")"
    [ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
}

fixture_hits
[ "$SCAN_COUNT" = "$scanned" ] || fail "the fixture copy did not reproduce the scanned surface set"
[ -z "$SCAN_HITS" ] || fail "the unmodified fixture copy must scan clean"

expect_hit() {
    # expect_hit DESCRIPTION EXPECTED_FILE [EXPECTED_LINE] — the fixture must now
    # report a hit in EXPECTED_FILE (at EXPECTED_LINE, when given).
    fixture_hits
    case "$SCAN_HITS" in
    "${2}:${3:-}"*) ;;
    *) fail "$1: expected a violation in ${2}${3:+ at line ${3}}, got: ${SCAN_HITS:-<none>}" ;;
    esac
}

# Every token, planted in a file under a scanned directory, reported at its line.
mkdir -p "${FIX}/.devcontainer/agent"
planted=".devcontainer/agent/planted.sh"
for tok in "${TOKENS[@]}"; do
    printf 'echo start\nrun %s now\n' "$tok" >"${FIX}/${planted}"
    expect_hit "token '${tok}' in a scanned directory" "$planted" "2:"
done

# A command split across physical lines by a backslash is still one command.
printf 'echo start\ncodex \\\n    login --device-flow\n' >"${FIX}/${planted}"
expect_hit "a backslash-continued codex login" "$planted" "2:"
rm -f "${FIX}/${planted}"

# Runs of blanks do not hide the command: two spaces, and a tab, still match.
printf 'echo start\ncodex  login\n' >"${FIX}/${planted}"
expect_hit "codex login with two spaces" "$planted" "2:"
printf 'echo start\ncodex\tlogin\n' >"${FIX}/${planted}"
expect_hit "codex login separated by a tab" "$planted" "2:"
printf 'echo start\nrun  --device-auth  now\n' >"${FIX}/${planted}"
expect_hit "a token flanked by doubled blanks" "$planted" "2:"
rm -f "${FIX}/${planted}"

# The login is an invariant, not a literal: options between the words do not hide it.
printf 'echo start\ncodex --no-alt-screen login\n' >"${FIX}/${planted}"
expect_hit "codex with an option before login" "$planted" "2:"
printf 'echo start\ncodex -c x=y login\n' >"${FIX}/${planted}"
expect_hit "codex with a valued option before login" "$planted" "2:"
printf 'echo start\ncodex -c x=y login --device-auth\n' >"${FIX}/${planted}"
expect_hit "codex with options around login" "$planted" "2:"
printf 'echo start\ncodex review --base main\n' >"${FIX}/${planted}"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a codex subcommand other than login must not match, got: ${SCAN_HITS}"
rm -f "${FIX}/${planted}"

# OPENAI_API_KEY alone is application configuration; paired with codex it is not.
mkdir -p "${FIX}/.github/workflows" "${FIX}/docs/guides"
printf 'jobs:\n  a:\n    env:\n      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}\n' >"${FIX}/.github/workflows/app.yml"
printf '# App\n\nSet OPENAI_API_KEY for the app.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "an application's own OPENAI_API_KEY must not be reported, got: ${SCAN_HITS}"
rm -f "${FIX}/.github/workflows/app.yml" "${FIX}/docs/guides/planted-app.md"
printf 'echo start\nOPENAI_API_KEY=$K codex exec review\n' >"${FIX}/${planted}"
expect_hit "OPENAI_API_KEY paired with codex" "$planted" "2:"
printf 'echo start\nCODEX_HOME=x OPENAI_API_KEY=$K node app.js\n' >"${FIX}/${planted}"
expect_hit "OPENAI_API_KEY paired with CODEX_HOME (any case)" "$planted" "2:"
rm -f "${FIX}/${planted}"

# A YAML-folded command: `codex` ends one line, `login` opens the next; options
# may sit on either side of the fold. Reported with both real lines.
mkdir -p "${FIX}/.github/workflows"
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a YAML-folded codex / login" ".github/workflows/folded.yml" "6-7: "
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex --no-alt-screen\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a folded codex with an option, then login" ".github/workflows/folded.yml" "6-7: "
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex\n          --no-alt-screen login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a folded codex, then an option and login" ".github/workflows/folded.yml" "6-7: "
printf 'jobs:\n  a:\n    steps:\n      - run: echo codex\n        login-check: x\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "codex followed by a login-prefixed word must not match, got: ${SCAN_HITS}"
rm -f "${FIX}/.github/workflows/folded.yml"

# A surface line that merely contains the guard-error marker is a violation (it
# carries a token), never mistaken for a guard error.
printf 'echo start\nGUARD-ERROR auth.json leaked\n' >"${FIX}/${planted}"
expect_hit "a surface line quoting the guard-error marker" "$planted" "2:"
rm -f "${FIX}/${planted}"

# The workflow directory is scanned as a whole, not one named file.
mkdir -p "${FIX}/.github/workflows"
printf 'name: x\nenv:\n  A: x\n  run: OPENAI_API_KEY=$K codex exec\n' >"${FIX}/.github/workflows/planted.yml"
expect_hit "a token in an arbitrary workflow" ".github/workflows/planted.yml" "4:"
rm -f "${FIX}/.github/workflows/planted.yml"

# All of docs/ is scanned except docs/research/ (rejected-option assessments).
mkdir -p "${FIX}/docs/decisions" "${FIX}/docs/research"
printf 'x\nrun --device-auth\n' >"${FIX}/docs/research/planted.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "docs/research/ must not be scanned, got: ${SCAN_HITS}"
printf 'x\nrun --device-auth\n' >"${FIX}/docs/decisions/planted.md"
expect_hit "a token in docs/decisions" "docs/decisions/planted.md" "2:"
rm -f "${FIX}/docs/research/planted.md" "${FIX}/docs/decisions/planted.md"

# A scanned file: a violating line that is not an allowlisted line.
for f in docs/guides/codex-review.md docs/architecture/remote-environments.md AGENTS.md; do
    [ -f "${FIX}/${f}" ] || continue
    cp "${FIX}/${f}" "${TMP}/saved"
    printf '\ncp ~/.codex/auth.json /tmp/seed.json\n' >>"${FIX}/${f}"
    expect_hit "an unexplained auth file in ${f}" "$f"
    cp "${TMP}/saved" "${FIX}/${f}"
done

# An allowlisted line quoted inside a new prescriptive sentence must still fail:
# the allowlist excuses complete lines, never the phrases inside them. One
# scratch copy carries every entry's phrase relocated into its own sentence
# (distinct lines); one scan must report every one of them.
FIX_FULL="${TMP}/fixture-relocated"
cp -R "$FIX" "$FIX_FULL"
relocated=0
for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    efile="${entry%%@@*}"
    etext="${entry#*@@}"
    etext="${etext%%@@*}"
    [ -f "${FIX_FULL}/${efile}" ] || continue
    relocated=$((relocated + 1))
    printf '\nOn every ephemeral VM, do this first [relocated-%s]: %s\n' "$relocated" "$etext" >>"${FIX_FULL}/${efile}"
done
[ "$relocated" -gt 0 ] || fail "no allowlist entry could be relocated; the quoting case would pass vacuously"
split_scan "$(scan "$FIX_FULL")"
[ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
for ((i = 1; i <= relocated; i++)); do
    case "$SCAN_HITS" in
    *"[relocated-${i}]:"*) ;;
    *) fail "an excused line relocated into a prescriptive sentence was not reported (entry ${i} of ${relocated})" ;;
    esac
done
[ "$(printf '%s\n' "$SCAN_HITS" | grep -c 'relocated-')" -eq "$relocated" ] ||
    fail "expected exactly ${relocated} relocated-phrase hits, got: ${SCAN_HITS}"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "restoring the fixture must scan clean again"

# A file the guard cannot read is an error, never a silent pass. Root reads
# everything, so the case cannot be staged there.
if [ "$(id -u)" -eq 0 ]; then
    echo "==> skipped: the unreadable-file case cannot run as root"
else
    printf 'harmless\n' >"${FIX}/.devcontainer/agent/unreadable.sh"
    chmod 000 "${FIX}/.devcontainer/agent/unreadable.sh"
    split_scan "$(scan "$FIX")"
    case "$SCAN_ERR" in
    *"could not read .devcontainer/agent/unreadable.sh"*) ;;
    *) fail "an unreadable surface file must be a guard error, got: ${SCAN_ERR:-<none>} ${SCAN_HITS}" ;;
    esac
    chmod 600 "${FIX}/.devcontainer/agent/unreadable.sh"
    rm -f "${FIX}/.devcontainer/agent/unreadable.sh"
fi

# A surface directory the guard cannot list is an error too: find's failure must
# not let the directory drop out of the scan. Root lists everything.
if [ "$(id -u)" -eq 0 ]; then
    echo "==> skipped: the unlistable-directory case cannot run as root"
else
    mkdir -p "${FIX}/.devcontainer/unlistable"
    printf 'harmless\n' >"${FIX}/.devcontainer/unlistable/file.sh"
    chmod 000 "${FIX}/.devcontainer/unlistable"
    split_scan "$(scan "$FIX")"
    case "$SCAN_ERR" in
    *"could not list .devcontainer"*) ;;
    *) fail "an unlistable surface directory must be a guard error, got: ${SCAN_ERR:-<none>} ${SCAN_HITS}" ;;
    esac
    chmod 755 "${FIX}/.devcontainer/unlistable"
    rm -rf "${FIX}/.devcontainer/unlistable"
fi

# A root with none of the surfaces scans nothing — which the caller rejects.
mkdir -p "${TMP}/empty"
[ "$(scan "${TMP}/empty" | tail -n 1)" = "SCANNED 0" ] || fail "an empty root must report SCANNED 0"

echo "remote codex policy OK: ${scanned} surface files clean; planted violations fail for all ${#TOKENS[@]} plain tokens and both pattern rules"
