#!/usr/bin/env bash
# Validate the records attached to Renovate allowedVersions rules.
set -euo pipefail
root=${1:-.}
cd "$root"

# The template contains Jinja, so extract each simple package-rule object before
# parsing it. Renovate config validation separately checks the rendered JSON.
holds() {
    jq -Rsc '[scan("\\{[^{}]*\\\"allowedVersions\\\"[^{}]*\\}") | fromjson]' "$1"
}
check() {
    local file=$1 exemptions=$2 count extracted
    count=$(jq -Rsc '[scan("\"allowedVersions\"[[:space:]]*:")] | length' "$file")
    extracted=$(holds "$file")
    if [[ $(jq 'length' <<<"$extracted") != "$count" ]]; then
        echo "$file: cannot inspect every allowedVersions rule" >&2
        return 1
    fi
    jq -e --argjson exemptions "$exemptions" '
    all(.[];
      if (.matchPackageNames == ["joshmedeski/sesh"] or .matchPackageNames == ["XAMPPRocky/tokei"]) and $exemptions then true
      else (.description | type == "string" and
        test("^Reason: [^;]*[^[:space:];][^;]*; Upstream: https://github[.]com/[^ /;]+/[^ /;]+/(issues|pull)/[0-9]+; Remove when: [^;]*[^[:space:];][^;]*; Canary: https://github[.]com/[^ /;]+/[^ /;]+$")) end)' <<<"$extracted" >/dev/null || {
        echo "$file: allowedVersions rule needs Reason, upstream issue/PR, Remove when, and Canary" >&2
        return 1
    }
}

if [[ ! -f renovate.json ]]; then
    echo 'renovate.json: missing' >&2
    exit 1
fi
jq -e . renovate.json >/dev/null
if [[ -f renovate/default.json && -f template/renovate.json.jinja ]]; then
    jq -e . renovate/default.json >/dev/null
    check renovate.json true
    check renovate/default.json false
    check template/renovate.json.jinja false
    # Until preset adoption, every shared hold must match the rendered template
    # and its root copy. Root may also carry repository-specific holds.
    shared=$(holds renovate/default.json | jq -c 'sort_by(.matchPackageNames)')
    templated=$(holds template/renovate.json.jinja | jq -c 'sort_by(.matchPackageNames)')
    [[ $shared == "$templated" ]] || {
        echo 'template holds differ from preset' >&2
        exit 1
    }
    actual=$(holds renovate.json)
    jq -en --argjson shared "$shared" --argjson actual "$actual" \
        'all($shared[]; . as $hold | [$actual[] | select(. == $hold)] | length == 1)' >/dev/null || {
        echo 'root is missing a shared hold or differs from the preset' >&2
        exit 1
    }

else
    check renovate.json false
fi
