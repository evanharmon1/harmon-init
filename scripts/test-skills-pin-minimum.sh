#!/usr/bin/env bash
# test-skills-pin-minimum.sh — ensure the skills this release vendors satisfy
# the minimum that consumers and standardize-repo can read from copier.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

copier_manifest="copier.yml"
root_manifest=".skills-sync.yaml"
template_manifest='template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja'

fail() {
    echo "skills-pin-minimum: $*" >&2
    exit 1
}

read_minimum() {
    local minimum
    minimum="$(awk '
        /^_min_harmon_devkit_skills:[[:space:]]*/ {
            count++
            value = $2
            gsub(/"/, "", value)
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "$copier_manifest")" ||
        fail "expected exactly one non-empty _min_harmon_devkit_skills value in ${copier_manifest}"
    printf '%s\n' "$minimum"
}

read_pin() {
    local manifest="$1" count pin
    [ -f "$manifest" ] || fail "skills-sync manifest not found: ${manifest}"
    count="$(grep -c '^[[:space:]]*ref:' "$manifest" || true)"
    [ "$count" = 1 ] || fail "expected exactly one ref in ${manifest} (found ${count})"
    pin="$(awk '
        /^[[:space:]]*ref:/ {
            value = $2
            gsub(/"/, "", value)
            print value
        }
    ' "$manifest")"
    [ -n "$pin" ] || fail "could not read ref from ${manifest}"
    printf '%s\n' "$pin"
}

version_key() {
    local tag="$1" major minor patch
    [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
        fail "invalid stable harmon-devkit tag: ${tag}"
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    [ "${#major}" -le 5 ] && [ "${#minor}" -le 5 ] && [ "${#patch}" -le 5 ] ||
        fail "harmon-devkit version component is too large to compare: ${tag}"
    printf '%05d%05d%05d' "$major" "$minor" "$patch"
}

minimum="$(read_minimum)"
minimum_key="$(version_key "$minimum")"
checked=0
for manifest in "$root_manifest" "$template_manifest"; do
    [ -f "$manifest" ] || continue
    pin="$(read_pin "$manifest")"
    pin_key="$(version_key "$pin")"
    [[ "$pin_key" < "$minimum_key" ]] &&
        fail "${manifest} pins ${pin}, below the declared minimum ${minimum}"
    printf 'skills-pin-minimum: %s pins %s (minimum %s)\n' "$manifest" "$pin" "$minimum"
    checked=$((checked + 1))
done

[ "$checked" -gt 0 ] || fail "no skills-sync manifests were found"
