#!/usr/bin/env bash
# test-validate-toolchain-floors.sh — unit-test validate-toolchain-floors.sh
# against a throwaway fixture repository: the real tree passes, and every way a
# floor can fail (a pin below it, a missing or unmatched template_path, a copier
# floor above _min_copier_version, an ancestor floor the pinned commit does not
# descend from or that git cannot see) fails closed. Run via
# `task test:validate-toolchain-floors`.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd -P)"
validator="${repo}/scripts/validate-toolchain-floors.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Keep the fixture's git independent of the caller's identity, hooks and config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

work="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-floors-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fx="${work}/fx"
out="${work}/out.txt"

JINJA_DIR='template/[% if devcontainer %].devcontainer[% endif %]'

mkdir -p "${fx}/template/.github/actions/setup" "${fx}/${JINJA_DIR}"
git -C "$fx" init -q
write_dockerfile() {
    printf 'FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-%s@sha256:0000\n' "$1" >"${fx}/${JINJA_DIR}/Dockerfile"
}
commit() {
    git -C "$fx" add -A
    git -C "$fx" commit -q --allow-empty -m "$1"
    git -C "$fx" rev-parse HEAD
}
write_dockerfile 0000000000000000000000000000000000000000
base="$(commit base)"
child="$(commit child)"
git -C "$fx" checkout -q -b side "$base"
sibling="$(commit sibling)"
git -C "$fx" checkout -q -
absent=ffffffffffffffffffffffffffffffffffffffff

cat >"${fx}/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"

use_node:
  type: bool
  default: "[[ true ]]"
  when: false

devcontainer:
  type: bool
  default: yes

not_a_bool:
  type: str
EOF
cat >"${fx}/template/.github/actions/setup/action.yml.jinja" <<'EOF'
      with:
        node-version: "24"
        version: 3.51.1
EOF
cp toolchain-floors.schema.json "${fx}/toolchain-floors.schema.json"

# floors JSON -> write the fixture declaration with the given floor objects.
floors() { printf '{"schema_version":1,"floors":[%s]}\n' "$1" >"${fx}/toolchain-floors.json"; }
NODE_PIN='{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^\\s*node-version: \"([0-9]+)\"$"}'
TASK_PIN='{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^\\s*version: ([0-9]+\\.[0-9]+\\.[0-9]+)$"}'
IMAGE_PIN='{"path":".devcontainer/Dockerfile","template_path":"'"${JINJA_DIR}"'/Dockerfile","pattern":"^FROM ghcr\\.io/evanharmon1/harmon-devcontainer:sha-([0-9a-f]{40})@"}'
node_floor() { printf '{"tool":"node","minimum":"%s","compare":"major","pins":[%s]}' "$1" "${2:-$NODE_PIN}"; }
task_floor() { printf '{"tool":"task","minimum":"%s","compare":"version","pins":[%s]}' "$1" "${2:-$TASK_PIN}"; }
image_floor() { printf '{"tool":"devcontainer-image","minimum":"%s","compare":"ancestor","pins":[%s]}' "$1" "${2:-$IMAGE_PIN}"; }

# expect NAME STATUS PATTERN [ARGS...] — run the validator on the fixture; it
# must exit STATUS and its combined output must contain PATTERN (fixed string).
expect() {
    name="$1" want="$2" pattern="$3"
    shift 3
    echo "==> ${name}"
    rc=0
    "$validator" --root "$fx" "$@" >"$out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || {
        cat "$out" >&2
        fail "${name}: exit ${rc}, want ${want}"
    }
    grep -F -- "$pattern" "$out" >/dev/null || {
        cat "$out" >&2
        fail "${name}: output lacks: ${pattern}"
    }
}

echo "==> the real tree passes and names its consumer-checked pin"
rc=0
"$validator" >"$out" 2>&1 || rc=$?
[ "$rc" = 0 ] || {
    cat "$out" >&2
    fail "the current template violates its own floors"
}
grep -E 'consumer-checked +package.json' "$out" >/dev/null || fail "pnpm pin is not reported as consumer-checked"
tools="$(sed -n 's/^toolchain-floors: \([a-z-]*\) (.*/\1/p' "$out" | sort | tr '\n' ' ')"
[ "$tools" = "copier devcontainer-image node pnpm task " ] || fail "declared tools differ: ${tools}"

floors "$(node_floor 24),$(task_floor 3.51.1)"
expect "pins at the floor pass" 0 "toolchain-floors: ok"

floors "$(node_floor 25)"
expect "a major pin below the floor fails" 1 "pinned 24 is below the floor 25"
floors "$(task_floor 3.51.2)"
expect "a version pin below the floor fails" 1 "pinned 3.51.1 is below the floor 3.51.2"
floors "$(task_floor 3.9.0)"
expect "versions compare numerically, not as text" 0 "toolchain-floors: ok"
floors "$(task_floor 3.51.1.1)"
expect "a longer minimum outranks a shorter pin" 1 "is below the floor 3.51.1.1"

floors "$(node_floor 24 '{"path":"a","template_path":"template/missing.jinja","pattern":"(x)"}')"
expect "a template_path that does not exist fails" 1 "template/missing.jinja does not exist"
floors "$(node_floor 24 '{"path":"a","template_path":"../outside","pattern":"(x)"}')"
expect "a template_path leaving the repository fails" 1 "leaves the repository"
floors "$(node_floor 24 '{"path":"a","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^nothing-here: ([0-9]+)$"}')"
expect "a pattern with no match fails" 1 "pattern matches nothing"
floors "$(node_floor 24 '{"path":"a","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^\\s*node-version: \"[0-9]+\"$"}')"
expect "a pattern with no capture group fails" 1 "no capture group 1"
floors "$(node_floor 24 '{"path":"a","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"("}')"
expect "a pattern that does not compile fails" 1 "pattern does not compile"
floors "$(node_floor 24 '{"path":"a","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^(\\s*)node-version"}')"
expect "a non-numeric capture fails" 1 "is not a major version"
floors "$(node_floor 24 '{"path":"a","template_path":"template/.github/actions/setup/action.yml.jinja","json_pointer":"/x","pattern":"(x)"}')"
expect "json_pointer on a template pin fails" 1 "json_pointer needs a consumer file"

floors "$(node_floor 24 '{"path":"package.json","template_path":null,"json_pointer":"/packageManager","pattern":"^pnpm@([0-9]+)\\."}')"
expect "a repository-owned pin is accepted and named consumer-checked" 0 "consumer-checked  package.json (/packageManager)"
floors "$(node_floor 24 '{"path":"package.json","template_path":null,"pattern":"^pnpm@([0-9]+)\\."}')"
expect "a repository-owned pin needs no file in the template" 0 "toolchain-floors: ok"

floors '{"tool":"copier","minimum":"9.4.0","compare":"version","pins":[]}'
expect "a copier floor equal to _min_copier_version passes" 0 "_min_copier_version 9.4.0 >= floor 9.4.0"
floors '{"tool":"copier","minimum":"9.4.1","compare":"version","pins":[]}'
expect "a copier floor above _min_copier_version fails" 1 "floor 9.4.1 exceeds _min_copier_version 9.4.0"
floors '{"tool":"copier","minimum":"9.10.0","compare":"version","pins":[]}'
expect "copier versions compare numerically" 1 "exceeds _min_copier_version"
floors '{"tool":"copier","minimum":"9","compare":"major","pins":[]}'
expect "a copier floor must compare by version" 1 "copier: must compare by version"

floors "$(image_floor "$base")"
write_dockerfile "$child"
expect "an ancestor floor the pinned commit descends from passes (Jinja path)" 0 "descends from ${base}"
write_dockerfile "$sibling"
floors "$(image_floor "$child")"
expect "an ancestor floor the pinned commit does not descend from fails" 1 "does not descend from the floor commit ${child}"
write_dockerfile "$base"
expect "a pin older than its floor fails" 1 "does not descend from the floor commit ${child}"
write_dockerfile "$child"
floors "$(image_floor "$absent")"
expect "a floor commit absent from local history fails closed" 1 "unknown — commit ${absent} is not in the local git history"
floors "$(image_floor "$base")"
write_dockerfile "$absent"
expect "a pinned commit absent from local history fails closed" 1 "unknown — commit ${absent} is not in the local git history"
write_dockerfile 'not-a-commit'
expect "a pin value that is not a commit matches nothing and fails" 1 "pattern matches nothing"
write_dockerfile "$child"

# `when` must name a boolean answer in copier.yml.
printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"use_node","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "when naming a boolean answer passes" 0 "node (major >= 24, when use_node)"
for bad in not_a_bool no_such_answer; do
    printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"%s","pins":[%s]}]}\n' "$bad" "$NODE_PIN" >"${fx}/toolchain-floors.json"
    expect "when ${bad} fails" 1 "when \"${bad}\" is not a boolean answer in copier.yml"
done
floors "$(node_floor 24),$(node_floor 24)"
expect "a tool declared twice fails" 1 "node: declared more than once"

# Schema: structural violations fail before any pin is read.
floors '{"tool":"node","minimum":"24","compare":"semver","pins":[]}'
expect "an unknown compare fails the schema" 1 "does not match its schema"
floors '{"tool":"node","minimum":"24.1","compare":"major","pins":[]}'
expect "a major minimum must be an integer" 1 "does not match its schema"
floors '{"tool":"devcontainer-image","minimum":"6018a312","compare":"ancestor","pins":[]}'
expect "an ancestor minimum must be a full commit" 1 "does not match its schema"
floors '{"tool":"node","minimum":"24","compare":"major"}'
expect "a floor without pins fails the schema" 1 "does not match its schema"
floors '{"tool":"node","minimum":"24","compare":"major","pins":[{"path":"a","pattern":"(x)"}]}'
expect "a pin must say whether it is repository-owned" 1 "does not match its schema"
printf '{"schema_version":2,"floors":[]}\n' >"${fx}/toolchain-floors.json"
expect "an unsupported schema_version fails" 1 "does not match its schema"
printf '{not json\n' >"${fx}/toolchain-floors.json"
expect "unreadable JSON fails" 1 "cannot read valid JSON"

# Fail closed outside a git repository: no history means ancestry is unknown.
nogit="${work}/nogit"
cp -R "$fx" "$nogit"
rm -rf "${nogit}/.git"
floors "$(image_floor "$base")"
cp "${fx}/toolchain-floors.json" "${nogit}/toolchain-floors.json"
rc=0
"$validator" --root "$nogit" >"$out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "ancestry outside a git repository must fail, got exit ${rc}"
grep -F "unknown" "$out" >/dev/null || fail "ancestry outside a git repository must be unknown"

echo "==> usage errors exit 2"
rc=0
"$validator" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unknown argument: exit ${rc}, want 2"

echo "OK: validate-toolchain-floors"
