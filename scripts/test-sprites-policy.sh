#!/usr/bin/env bash
# test-sprites-policy.sh — prove a Fly.io Sprite's network policy is generated
# from the shared egress allowlist and cannot differ from it (harmon-init#1411).
#
# The policy is never checked in: `sprites/network-policy.sh generate` derives
# it at provisioning from `.devcontainer/scripts/egress-allowlist.sh hosts`, the
# one parser of the allowlist format. This test holds that generator to the
# list:
#   1. every entry `hosts` prints reaches the policy as an allow rule, in order,
#      except @github-meta, which is a named limitation announced on stderr;
#      the policy has nothing else but the closing `*` deny;
#   2. the comparison is load-bearing: a policy with a planted missing, extra,
#      or changed rule, or without the closing deny, fails it;
#   3. the per-repo .local list reaches the policy too, and an entry kind the
#      policy cannot express (an IPv4 address or CIDR) or a refused list fails
#      generation loudly rather than being dropped;
#   4. `apply` sends exactly the generated policy to the documented endpoint
#      with the token on curl's stdin — never in its arguments — runs curl with
#      -q first (no ~/.curlrc), and fails when the API refuses it (curl is
#      stubbed; nothing leaves the machine);
#   5. the generator reads the lists of the checkout it lives in, whatever the
#      parser's list-path overrides are set to in the caller's environment.
#
# Usage: scripts/test-sprites-policy.sh [<dir holding network-policy.sh>]
# The directory defaults to this repository's sprites/; test-template.sh passes
# a rendered project's, whose own .devcontainer lists are then the ones read.
# Offline. Run via `task test:sprites-policy`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN_DIR="$(cd "${1:-${REPO_ROOT}/sprites}" && pwd)"
GEN="${GEN_DIR}/network-policy.sh"
ALLOWLIST_SH="${GEN_DIR}/../.devcontainer/scripts/egress-allowlist.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
pass() { echo "  ok: $*"; }

[ -f "$GEN" ] || fail "no generator at ${GEN}"
[ -f "$ALLOWLIST_SH" ] || fail "no egress allowlist parser at ${ALLOWLIST_SH}"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# check_policy POLICY_FILE HOSTS_FILE — succeed only when the policy is exactly
# the hosts' allow rules (in order, @github-meta excluded) followed by the
# closing `*` deny; print the first difference otherwise.
check_policy() {
    local want got
    want="$(grep -vx '@github-meta' "$2" | jq -R '{domain: ., action: "allow"}' | jq -s -c '. + [{domain: "*", action: "deny"}]')"
    got="$(jq -c '[.rules[] | {domain, action} + (if has("include") then {include} else {} end)]' "$1")" || {
        echo "policy is not valid JSON with a rules array"
        return 1
    }
    if [ "$want" != "$got" ]; then
        diff <(jq '.[]' <<<"$want") <(jq '.[]' <<<"$got") | head -5
        return 1
    fi
}

# A fixture checkout with the generator's own layout: the generator, the
# parser, and the two lists beside it. The generator ignores the parser's
# list-path environment overrides on purpose, so fixtures go in by tree.
FX="${TMP}/fixture"
mkdir -p "${FX}/sprites" "${FX}/.devcontainer/scripts"
cp "$GEN" "${FX}/sprites/network-policy.sh"
cp "$ALLOWLIST_SH" "${FX}/.devcontainer/scripts/egress-allowlist.sh"

# generate_with SHARED [LOCAL] — install the lists into the fixture tree (no
# LOCAL: no .local list) and run its generator; stdout to policy.json, stderr
# to err.
generate_with() {
    cp "$1" "${FX}/.devcontainer/egress-allowlist.txt"
    rm -f "${FX}/.devcontainer/egress-allowlist.local.txt"
    [ -z "${2:-}" ] || cp "$2" "${FX}/.devcontainer/egress-allowlist.local.txt"
    env -u EGRESS_ALLOWLIST_SHARED -u EGRESS_ALLOWLIST_LOCAL \
        bash "${FX}/sprites/network-policy.sh" generate >"${TMP}/policy.json" 2>"${TMP}/err"
}

echo "==> 1. the generated policy carries every allowlist entry"
env -u EGRESS_ALLOWLIST_SHARED -u EGRESS_ALLOWLIST_LOCAL bash "$ALLOWLIST_SH" hosts >"${TMP}/hosts" ||
    fail "the allowlist parser refused the lists"
env -u EGRESS_ALLOWLIST_SHARED -u EGRESS_ALLOWLIST_LOCAL bash "$GEN" generate >"${TMP}/real.json" 2>"${TMP}/real.err" ||
    fail "generate failed: $(cat "${TMP}/real.err")"
out="$(check_policy "${TMP}/real.json" "${TMP}/hosts")" || fail "policy differs from the allowlist: ${out}"
pass "$(grep -cvx '@github-meta' "${TMP}/hosts") hostnames, in order, then the closing deny"
if grep -qx '@github-meta' "${TMP}/hosts"; then
    grep -q 'NOTE: @github-meta' "${TMP}/real.err" || fail "@github-meta was dropped without its NOTE"
    pass "@github-meta announced as a named limitation, not dropped silently"
fi

echo "==> 2. a policy that differs from the list fails the comparison"
mutate() {
    jq "$2" "${TMP}/real.json" >"${TMP}/mutant.json"
    if check_policy "${TMP}/mutant.json" "${TMP}/hosts" >/dev/null; then
        fail "a policy with $1 passed the comparison"
    fi
    pass "$1 is caught"
}
mutate "a missing rule" 'del(.rules[0])'
mutate "an extra rule" '.rules = [{domain: "evil.example", action: "allow"}] + .rules'
mutate "a changed domain" '.rules[0].domain = "github.example"'
mutate "a changed action" '.rules[0].action = "deny"'
mutate "no closing deny" 'del(.rules[-1])'
mutate "the defaults preset" '.rules = [{include: "defaults"}] + .rules'

echo "==> 3. fixture lists: the .local list, and entries the policy cannot express"
printf '# shared\n@github-meta\ngithub.com\napi.example.com # trailing comment\n' >"${TMP}/shared.txt"
printf 'extra.example.org\n' >"${TMP}/local.txt"
generate_with "${TMP}/shared.txt" "${TMP}/local.txt" || fail "generate failed on fixture lists: $(cat "${TMP}/err")"
printf 'github.com\napi.example.com\nextra.example.org\n' >"${TMP}/want-hosts"
out="$(check_policy "${TMP}/policy.json" "${TMP}/want-hosts")" || fail "fixture policy is wrong: ${out}"
pass "shared and .local entries both reach the policy"

printf '203.0.113.7\n' >"${TMP}/local-ip.txt"
if generate_with "${TMP}/shared.txt" "${TMP}/local-ip.txt"; then
    fail "an IPv4 entry was accepted into a domain-only policy"
fi
grep -q "203.0.113.7" "${TMP}/err" || fail "the IPv4 refusal does not name the entry"
[ ! -s "${TMP}/policy.json" ] || fail "a refused list still printed a policy"
pass "an IPv4 entry fails loudly, naming it"

printf '198.51.100.0/24\n' >"${TMP}/local-cidr.txt"
generate_with "${TMP}/shared.txt" "${TMP}/local-cidr.txt" && fail "a CIDR entry was accepted into a domain-only policy"
pass "a CIDR entry fails loudly"

printf 'not a host!\n' >"${TMP}/local-bad.txt"
generate_with "${TMP}/shared.txt" "${TMP}/local-bad.txt" && fail "a malformed entry was accepted"
[ ! -s "${TMP}/policy.json" ] || fail "a malformed list still printed a policy"
pass "a list the parser refuses generates nothing"

printf '@github-meta\n' >"${TMP}/meta-only.txt"
generate_with "${TMP}/meta-only.txt" && fail "a list with no hostname produced a deny-everything policy"
pass "a list with no hostname is refused"

# A stale export of the parser's list-path overrides must not replace the
# policy: the generator reads the lists of the checkout it lives in.
EGRESS_ALLOWLIST_SHARED="${TMP}/shared.txt" EGRESS_ALLOWLIST_LOCAL="${TMP}/local.txt" \
    bash "$GEN" generate >"${TMP}/exported.json" 2>/dev/null || fail "generate failed with the overrides exported"
cmp -s "${TMP}/exported.json" "${TMP}/real.json" || fail "exported EGRESS_ALLOWLIST_* overrides replaced the checkout's policy"
pass "exported list-path overrides are ignored"

echo "==> 4. apply: the documented endpoint, the token on stdin only"
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_DIR}/argv"
cat >"${STUB_DIR}/config"
cat <&3 >"${STUB_DIR}/body"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "${TMP}/bin/curl"
token="tok-$$-secret"
printf '%s\n' "$token" | PATH="${TMP}/bin:${PATH}" STUB_DIR="$TMP" bash "$GEN" apply my-sprite 2>"${TMP}/apply.err" ||
    fail "apply failed against a stub API: $(cat "${TMP}/apply.err")"
grep -qF "$token" "${TMP}/argv" && fail "the token reached curl's arguments"
[ "$(head -n 1 "${TMP}/argv")" = "-q" ] || fail "curl's first argument is not -q, so the operator's ~/.curlrc is read"
grep -qxF "https://api.sprites.dev/v1/sprites/my-sprite/policy/network" "${TMP}/argv" || fail "apply did not target the documented endpoint"
grep -qxF -- "POST" "${TMP}/argv" || fail "apply did not POST"
grep -qxF "header = \"Authorization: Bearer ${token}\"" "${TMP}/config" || fail "the token did not reach curl's stdin config"
cmp -s <(jq -S . "${TMP}/body") <(jq -S . "${TMP}/real.json") || fail "apply sent a body other than the generated policy"
pass "POST to /v1/sprites/<name>/policy/network, generated body, token only on stdin, -q first"

printf '%s\n' "$token" | PATH="${TMP}/bin:${PATH}" STUB_DIR="$TMP" STUB_EXIT=22 bash "$GEN" apply my-sprite 2>/dev/null &&
    fail "apply reported success when the API refused the policy"
pass "an API refusal fails apply"

printf '%s\n' "$token" | PATH="${TMP}/bin:${PATH}" STUB_DIR="$TMP" bash "$GEN" apply 'Bad;Name' 2>/dev/null &&
    fail "apply accepted a malformed Sprite name"
printf '' | PATH="${TMP}/bin:${PATH}" STUB_DIR="$TMP" bash "$GEN" apply my-sprite 2>/dev/null &&
    fail "apply ran with no token on stdin"
pass "a malformed name and a missing token are refused"

echo "test-sprites-policy: PASS (${GEN})"
