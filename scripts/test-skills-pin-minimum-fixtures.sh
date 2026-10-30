#!/usr/bin/env bash
# Exercise the skills-pin minimum guard against isolated repository fixtures.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${repo_root}/scripts/test-skills-pin-minimum.sh"
fixture="$(mktemp -d)"
output="${fixture}/guard-output.log"
template_manifest='template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja'
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "skills-pin-minimum-fixtures: $*" >&2
    exit 1
}

write_fixture() {
    local root_pin="$1" template_pin="$2" include_template="${3:-true}"

    mkdir -p "${fixture}/template"
    cat >"${fixture}/copier.yml" <<'EOF'
_min_harmon_devkit_skills: "v0.58.0"
EOF
    printf 'ref: "%s"\n' "$root_pin" >"${fixture}/.skills-sync.yaml"
    if [ "$include_template" = true ]; then
        printf 'ref: "%s"\n' "$template_pin" >"${fixture}/${template_manifest}"
    else
        rm -f -- "${fixture}/${template_manifest}"
    fi
}

expect_pass() {
    local label="$1" root_pin="$2" template_pin="$3"

    write_fixture "$root_pin" "$template_pin"
    if ! SKILLS_PIN_REPO_ROOT="$fixture" "$guard" >"$output" 2>&1; then
        fail "${label} unexpectedly failed: $(cat "$output")"
    fi
    printf 'skills-pin-minimum-fixtures: %s passed\n' "$label"
}

expect_fail() {
    local label="$1" expected="$2" root_pin="$3" template_pin="$4"
    local include_template="${5:-true}"

    write_fixture "$root_pin" "$template_pin" "$include_template"
    if SKILLS_PIN_REPO_ROOT="$fixture" "$guard" >"$output" 2>&1; then
        fail "${label} unexpectedly passed"
    fi
    if ! grep -Fq -- "$expected" "$output"; then
        fail "${label} failed without expected message '${expected}': $(cat "$output")"
    fi
    printf 'skills-pin-minimum-fixtures: %s failed as expected\n' "$label"
}

expect_fail "below minimum" "below the declared minimum" "v0.57.9" "v0.58.0"
expect_pass "equal to minimum" "v0.58.0" "v0.58.0"
expect_pass "above minimum" "v0.59.0" "v0.59.0"
expect_fail "prerelease pin" "invalid stable harmon-devkit tag" "v0.58.0-rc.1" "v0.58.0"
expect_fail "unprefixed pin" "invalid stable harmon-devkit tag" "0.58.0" "v0.58.0"
expect_fail "empty pin" "could not read ref from .skills-sync.yaml" "" "v0.58.0"
expect_fail "missing template manifest" "skills-sync manifest not found: ${template_manifest}" "v0.58.0" "v0.58.0" false
