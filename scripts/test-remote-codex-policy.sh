#!/usr/bin/env bash
# test-remote-codex-policy.sh — guard the remote second-model rule: ephemeral
# cloud environments never hold Codex credentials, and a persistent environment
# holds exactly one Codex login of its own (AGENTS.md § "Remote environments").
#
# The rule is easy to break without noticing: one line in a bootstrap, an env
# example, or an adapter guide that tells a throwaway VM to run a Codex login,
# restore a copied auth file, or export an OpenAI API key contradicts it, and
# nothing else in the repository reads those lines together. This scans the
# remote-environment surfaces that exist in the repository under test (this
# script is a verbatim twin, so it runs in generated repos too, where several
# root-only surfaces are absent) for the credential vocabulary below, and fails
# with file:line on any hit the allowlist does not explain.
#
# Case-sensitive on purpose: the lowercase forms are the commands and the file
# name; the prose "a Codex login" that states the rule is not a violation.
#
# Self-proving: a planted violation in a temporary copy of the surfaces must
# fail, for every token, so a scan that silently stopped matching cannot pass.
# No login of any kind is performed and nothing is written outside a temp dir.
#
# Offline and metadata-only. Run via `task test:remote-codex-policy`.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Credential vocabulary. Each one either performs a Codex login, names the file
# a login leaves behind, or is the API-credit path the rule excludes.
TOKENS=(
    'OPENAI_API_KEY'
    'auth.json'
    'codex login'
    '--device-auth'
    '--with-api-key'
    '--with-access-token'
)

# Remote-environment surfaces: directories are scanned recursively, files
# directly. Whatever does not exist in the repository under test is skipped.
SURFACE_DIRS=(
    'images/devcontainer'
    '.devcontainer'
)
SURFACE_FILES=(
    '.github/workflows/remote-bootstrap.yml'
    'scripts/setup-remote.sh'
    'AGENTS.md'
    'docs/guides/claude-code-web.md'
    'docs/guides/codex-cloud.md'
    'docs/guides/codex-review.md'
    'docs/guides/devcontainers.md'
    'docs/architecture/remote-environments.md'
)

# Allowlist: "file@@substring@@reason". A substring is removed from a hit line
# before the tokens are looked for again, so an entry excuses exactly the text
# it names and never a different violation that shares the line. Not scanned at
# all: docs/research/ (an assessment of rejected options, not guidance).
ALLOW=(
    # The operator's own machine, where Codex is the file's only user. Nothing
    # here tells an ephemeral environment to log in.
    'docs/guides/codex-review.md@@**Authenticate**: `codex login`@@operator-machine setup: browser OAuth on the operator'"'"'s own ChatGPT login'
    'docs/guides/codex-review.md@@printenv OPENAI_API_KEY | codex login --with-api-key@@operator-machine alternative (billed API usage), not a remote environment'
    'docs/guides/codex-review.md@@codex login status@@read-only status probe; it performs no login'
    'docs/guides/codex-review.md@@`codex login` or `task codex:gate:disable`@@operator-machine remedy for the stop-gate'"'"'s login check'
    'docs/guides/codex-review.md@@then `codex login` (or@@operator-machine troubleshooting: re-authenticate after expiry'
    'docs/guides/codex-review.md@@codex login --device-auth@@operator-machine troubleshooting on a host without a browser'
    # The rule itself, stated once per persistent-environment document.
    'docs/architecture/remote-environments.md@@runs `codex login` once, at provisioning@@the rule itself: a persistent environment holds exactly one login'
    'docs/architecture/remote-environments.md@@`~/.codex/auth.json` is never copied@@the rule itself: the refresh token is single-use, so the file never leaves its environment'
    'docs/guides/devcontainers.md@@runs `codex login` once, at provisioning@@the rule itself: a persistent environment holds exactly one login'
    'docs/guides/devcontainers.md@@`~/.codex/auth.json` is never copied@@the rule itself: the refresh token is single-use, so the file never leaves its environment'
)

# scan ROOT — print "file:line:text" for every unexplained hit under ROOT and
# "SCANNED n" as the last line. Always returns 0; the caller reads the output.
scan() {
    local root="$1" file line text rest entry efile esub tok allowed scanned=0
    local files=() hits pattern_args=()
    for tok in "${TOKENS[@]}"; do
        pattern_args+=(-e "$tok")
    done
    for d in "${SURFACE_DIRS[@]}"; do
        if [ -d "${root}/${d}" ]; then
            while IFS= read -r file; do
                files+=("${file#"${root}"/}")
            done < <(find "${root}/${d}" -type f | LC_ALL=C sort)
        fi
    done
    for f in "${SURFACE_FILES[@]}"; do
        [ -f "${root}/${f}" ] && files+=("$f")
    done
    for file in "${files[@]+"${files[@]}"}"; do
        scanned=$((scanned + 1))
        hits="$(cd "$root" && grep -nIF "${pattern_args[@]}" -- "$file" || true)"
        [ -n "$hits" ] || continue
        while IFS= read -r line; do
            text="${line#*:}"
            rest="$text"
            for entry in "${ALLOW[@]}"; do
                efile="${entry%%@@*}"
                [ "$efile" = "$file" ] || continue
                esub="${entry#*@@}"
                esub="${esub%%@@*}"
                rest="${rest//"$esub"/}"
            done
            allowed=1
            for tok in "${TOKENS[@]}"; do
                case "$rest" in *"$tok"*) allowed=0 ;; esac
            done
            [ "$allowed" -eq 1 ] || echo "${file}:${line}"
        done <<<"$hits"
    done
    echo "SCANNED ${scanned}"
}

# --- 1. The repository under test is clean ---
out="$(scan "$PWD")"
scanned="${out##*SCANNED }"
violations="${out%SCANNED *}"
[ "$scanned" -gt 0 ] || fail "no remote-environment surface was scanned; the guard would pass vacuously"
[ -z "$violations" ] ||
    fail "a remote-environment surface carries Codex credential vocabulary not explained by the allowlist:
${violations}
The rule (AGENTS.md § \"Remote environments\"): ephemeral clouds never hold Codex credentials; a persistent environment holds one login of its own. Remove the line, or — only if it is the rule itself or an operator-machine instruction — add a reasoned ALLOW entry."
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
[ "$(scan "$FIX" | tail -n 1)" = "SCANNED ${scanned}" ] ||
    fail "the fixture copy did not reproduce the scanned surface set"
[ "$(scan "$FIX" | sed '$d')" = "" ] || fail "the unmodified fixture copy must scan clean"

expect_hit() {
    # expect_hit DESCRIPTION EXPECTED_FILE — the fixture must now report EXPECTED_FILE.
    local out
    out="$(scan "$FIX" | sed '$d')"
    case "$out" in
    "${2}:"*) ;;
    *) fail "$1: expected a violation in ${2}, got: ${out:-<none>}" ;;
    esac
}

# Every token, planted in a file under a scanned directory.
mkdir -p "${FIX}/.devcontainer/agent"
for tok in "${TOKENS[@]}"; do
    planted=".devcontainer/agent/planted.sh"
    printf 'echo start\nrun %s now\n' "$tok" >"${FIX}/${planted}"
    expect_hit "token '${tok}' in a scanned directory" "$planted"
    case "$(scan "$FIX" | sed '$d')" in
    *"${planted}:2:"*) ;;
    *) fail "token '${tok}': the hit must name file:line (${planted}:2)" ;;
    esac
done
rm -f "${FIX}/.devcontainer/agent/planted.sh"

# A scanned file: a violating line that is not the allowlisted text.
for f in docs/guides/codex-review.md docs/architecture/remote-environments.md AGENTS.md; do
    [ -f "${FIX}/${f}" ] || continue
    cp "${FIX}/${f}" "${TMP}/saved"
    printf '\ncp ~/.codex/auth.json /tmp/seed.json\n' >>"${FIX}/${f}"
    expect_hit "an unexplained auth file in ${f}" "$f"
    # Sharing a line with allowlisted text must not excuse the violation.
    cp "${TMP}/saved" "${FIX}/${f}"
    case "$f" in
    docs/guides/codex-review.md)
        printf '\nRun `codex login status` then export OPENAI_API_KEY=sk-x\n' >>"${FIX}/${f}"
        ;;
    docs/architecture/remote-environments.md)
        printf '\nThe environment runs `codex login` once, at provisioning, and restores a seed auth.json\n' >>"${FIX}/${f}"
        ;;
    *) printf '\nrun codex login --device-auth per session\n' >>"${FIX}/${f}" ;;
    esac
    expect_hit "a violation sharing a line with allowlisted text in ${f}" "$f"
    cp "${TMP}/saved" "${FIX}/${f}"
done
[ "$(scan "$FIX" | sed '$d')" = "" ] || fail "restoring the fixture must scan clean again"

# A root with none of the surfaces scans nothing — which the caller rejects.
mkdir -p "${TMP}/empty"
[ "$(scan "${TMP}/empty" | tail -n 1)" = "SCANNED 0" ] || fail "an empty root must report SCANNED 0"

echo "remote codex policy OK: ${scanned} surface files clean; planted violations fail for all ${#TOKENS[@]} tokens"
