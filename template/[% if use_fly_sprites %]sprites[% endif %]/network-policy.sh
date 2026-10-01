#!/usr/bin/env bash
set -euo pipefail

# network-policy.sh — derive a Fly.io Sprite's egress network policy from the
# shared egress allowlist, and apply it to a Sprite from OUTSIDE the VM.
#
#   bash sprites/network-policy.sh generate
#       Print the policy JSON. The entries come from
#       `.devcontainer/scripts/egress-allowlist.sh hosts` — the one parser of
#       the allowlist format, reading the shared list and the optional
#       per-repo .local list — so the policy cannot drift from the list it is
#       generated from; harmon-init's own scripts/test-sprites-policy.sh
#       proves that every entry the policy can express reaches it, and that
#       the other kinds are a named limitation or a refusal (below).
#
#   <token source> | bash sprites/network-policy.sh apply <sprite-name>
#       Generate the policy and set it on the named Sprite through the Sprites
#       API (POST /v1/sprites/<name>/policy/network). The API token is read
#       from STDIN — never an argument, never an environment variable, never a
#       file — and handed to curl on its stdin as a config line, so it appears
#       in no process listing; curl runs with -q, so no ~/.curlrc is read.
#       Run it from the operator's checkout, never from inside the Sprite: the
#       policy is read-only there by design.
#
# How each allowlist entry kind maps (Sprites network policy, docs read
# 2026-10-01: https://docs.fly.io/sprites/concepts/networking/). The policy is
# DNS-based and expresses domains only:
#   <hostname>      → {"domain": "<hostname>", "action": "allow"}
#   @github-meta    → no rule, by design, and said so on stderr. It exists for
#                     the devcontainer's address-based filter (GitHub's
#                     published IP ranges). A DNS-based policy has no address
#                     rules and needs none: connections to addresses resolved
#                     from an allowed domain pass, and the GitHub hostnames are
#                     listed beside it.
#   <a.b.c.d>[/n]   → a hard failure. A Sprite refuses raw-IP connections that
#                     no allowed domain resolved to, so an address entry cannot
#                     be honoured; replace it with the hostname it serves.
# The policy ends with {"domain": "*", "action": "deny"}, and never includes
# the platform's "defaults" preset: the shared list is the only source.
#
# Guide: docs/guides/sprites.md in harmon-init
# (https://github.com/evanharmon1/harmon-init/blob/main/docs/guides/sprites.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST_SH="${SCRIPT_DIR}/../.devcontainer/scripts/egress-allowlist.sh"
SPRITES_API_URL="https://api.sprites.dev"

IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
NAME_RE='^[a-z0-9][a-z0-9-]{0,62}$'

fail() {
    echo "sprites-network-policy: $*" >&2
    exit 1
}

usage() {
    echo "usage: $0 generate | apply <sprite-name>  (apply reads the Sprites API token on stdin)" >&2
    exit 2
}

cmd_generate() {
    local entries entry sep="" rules=""
    [ -f "$ALLOWLIST_SH" ] || fail "egress allowlist script not found at ${ALLOWLIST_SH}"
    # The parser runs under env -i (PATH only, no startup files), so it reads
    # only this checkout's lists whatever EGRESS_ALLOWLIST_* or BASH_ENV the
    # caller exports. Trust boundary: the operator's own shell — its PATH,
    # BASH_ENV and functions, which act before this line — is trusted, as for
    # any script the operator runs.
    entries="$(env -i PATH="$PATH" bash --noprofile --norc "$ALLOWLIST_SH" hosts)" ||
        fail "the egress allowlist was refused (see above); no policy generated"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [ "$entry" = "@github-meta" ]; then
            echo "sprites-network-policy: NOTE: @github-meta has no Sprite policy rule — the policy is DNS-based; the GitHub hostnames in the list carry GitHub" >&2
        elif [[ "$entry" =~ $IPV4_RE ]]; then
            fail "'${entry}' is an IPv4 address/CIDR, which a Sprite network policy cannot express (it is domain-only and refuses raw-IP connections); list the hostname instead"
        else
            # egress-allowlist.sh has validated it as a hostname: letters,
            # digits, hyphens and dots only, so it needs no JSON escaping.
            rules="${rules}${sep}    {\"domain\": \"${entry}\", \"action\": \"allow\"}"
            sep=$',\n'
        fi
    done <<<"$entries"
    [ -n "$rules" ] || fail "the allowlist yields no domain rule; refusing to generate a deny-everything policy"
    printf '{\n  "rules": [\n%s,\n    {"domain": "*", "action": "deny"}\n  ]\n}\n' "$rules"
}

cmd_apply() {
    local name="${1:-}" token policy out code body
    [[ "$name" =~ $NAME_RE ]] || fail "'${name}' is not a Sprite name (lowercase letters, digits and hyphens)"
    [ ! -t 0 ] || fail "pipe the Sprites API token on stdin, e.g. from a secret store read; it is never taken as an argument"
    IFS= read -r token || [ -n "$token" ] || fail "no token on stdin"
    [ -n "$token" ] || fail "empty token on stdin"
    case "$token" in *'"'* | *'\'* | *[[:cntrl:]]*) fail "the token contains a quote, backslash or control character; refusing to build a curl config from it" ;; esac
    policy="$(cmd_generate)"
    # The token goes to curl on its stdin as a config line; the policy goes as
    # the request body on file descriptor 3. `-q` must be curl's FIRST argument
    # (it is ignored anywhere else): it skips the operator's ~/.curlrc, where a
    # trace, verbose, url or proxy line would print or redirect the header.
    # One call returns the response body, then the HTTP status on a last line
    # of its own (-w). A non-zero curl exit is a transport failure (no answer:
    # timeout, refused connection, empty reply); any answer but a 2xx is a
    # refusal, reported with its status and body. curl follows no redirect, so
    # a 3xx is a refusal too.
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
        curl -q --config - -sS --max-time 60 -w '\n%{http_code}' \
            -X POST -H 'Content-Type: application/json' \
            --data-binary @/dev/fd/3 \
            "${SPRITES_API_URL}/v1/sprites/${name}/policy/network" 3<<<"$policy")" ||
        fail "could not reach the Sprites API for '${name}' (curl transport failure, see above); the policy was not applied"
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
    case "$code" in
    2??) ;;
    *)
        [ -z "$body" ] || printf '%s\n' "$body" >&2
        fail "the Sprites API refused the policy for '${name}' with HTTP ${code}; it was not applied"
        ;;
    esac
    echo "sprites-network-policy: applied to ${name}; check it with: sprite exec -s ${name} -- cat /.sprite/policy/network.json" >&2
}

case "${1:-}" in
generate) cmd_generate ;;
apply)
    shift
    cmd_apply "$@"
    ;;
*) usage ;;
esac
