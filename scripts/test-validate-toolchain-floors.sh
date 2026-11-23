#!/usr/bin/env bash
# test-validate-toolchain-floors.sh — unit-test validate-toolchain-floors.sh
# against a throwaway fixture repository: rendered YAML fixtures and one Copier
# render cover workflow pins, and every way a
# floor can fail (a pin below it, a missing or unmatched template_path, a copier
# floor above _min_copier_version, an ancestor floor the pinned commit does not
# descend from or that git cannot see) fails closed. Run via
# `task test:validate-toolchain-floors`.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd -P)"
validator="${repo}/scripts/validate-toolchain-floors.sh"
self="${repo}/scripts/test-validate-toolchain-floors.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-floors-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fx="${work}/fx"
rendered="${work}/rendered"
out="${work}/out.txt"

# Run the published declaration checks and the end-to-end Copier fixture once; the
# nested invocation checks that the offline validator fixtures isolate Git.
if [ -z "${TOOLCHAIN_FLOORS_TEST_NESTED:-}" ]; then
    check_published_tools() {
        local tools
        tools="$(jq -ce '[.floors[].tool] | sort' "$1")" || return 1
        [ "$tools" = '["copier","devcontainer-image","node","pnpm","task"]' ]
    }
    check_published_tools toolchain-floors.json || fail "the published tool list differs from the expected tools"
    jq 'del(.floors[] | select(.tool == "copier"))' toolchain-floors.json >"$work/missing-tool.json"
    if check_published_tools "$work/missing-tool.json"; then
        fail "the published tool list check accepted a missing Copier entry"
    fi

    pnpm_pin="$(jq -ce '.floors[] | select(.tool == "pnpm") | .pins[] | select(.template_path == null and .path == "package.json")' toolchain-floors.json)"
    # The published pnpm locator, applied to representative packageManager values.
    pnpm_pointer="$(jq -r .json_pointer <<<"$pnpm_pin")"
    pnpm_pattern="$(jq -r .pattern <<<"$pnpm_pin")"
    [ "$pnpm_pointer" = "/packageManager" ] || fail "the pnpm pin must locate /packageManager, got ${pnpm_pointer}"
    capture_major() {
        node -e 'const m=new RegExp(process.argv[1]).exec(process.argv[2]);process.stdout.write(m?m[1]:"")' "$pnpm_pattern" "$1"
    }
    for value in 'pnpm@11.2.0' 'pnpm@11.2.0-rc.1' 'pnpm@11.2.0+sha512.abc123' 'pnpm@11.2.0-rc.1+sha512.abc123' 'pnpm@11.2.0-rc.01beta'; do
        major="$(capture_major "$value")"
        [ "$major" = "11" ] || fail "the pnpm pattern captured '${major}' from ${value}, want 11"
    done
    for value in 'npm@10.0.0' 'yarn@4.0.0' 'pnpm-ish@11.0.0' 'pnpm@11.' 'pnpm@11.not-a-version' \
        'pnpm@011.2.0' 'pnpm@11.02.0' 'pnpm@11.2.00' 'pnpm@11.2.0-01' 'pnpm@11.2.0-rc.01' \
        'pnpm@11.2.0+sha512.not-hex' 'pnpm@11.2.0-' 'pnpm@11.2.0+' 'pnpm@11.2.0+sha512..abc123' 'pnpm@11.2.0+sha512/abc123'; do
        major="$(capture_major "$value")"
        [ -z "$major" ] || fail "the pnpm pattern matched ${value}"
    done
fi

# Keep the fixture's git independent of the caller: hooks export GIT_DIR /
# GIT_WORK_TREE / GIT_INDEX_FILE, which would retarget every fixture command at
# the caller's real repository (scripts/test-worktree.sh does the same).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
for _i in 0 1 2 3 4 5 6 7 8 9; do unset "GIT_CONFIG_KEY_${_i}" "GIT_CONFIG_VALUE_${_i}"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# Commit ids are 40 hex characters whatever the caller's init.defaultObjectFormat / GIT_DEFAULT_HASH.
export GIT_DEFAULT_HASH=sha1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

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

commented_bool:
  type: bool # derived from project_type
  default: false

quoted_bool:
  type: 'bool'
  default: false

hash_bool:
  type: bool#note
  default: false

help_trap:
  type: str
  help: |
    prose that quotes a property line:
    type: bool
EOF
# Two unrelated actions carry a bare `version:` next to the setup-task one.
cat >"${fx}/template/.github/actions/setup/action.yml.jinja" <<'EOF'
runs:
  using: composite
  steps:
    - uses: pnpm/action-setup@0000 # v1
      with:
        version: 9.0.0
    - uses: actions/setup-node@0000 # v7
      with:
        node-version: "24"
    - uses: arduino/setup-task@0000 # v3.0.0
      with:
        version: 3.51.1
        repo-token: ${{ github.token }}
    - uses: other/action@0000 # v1
      with:
        version: 1.0.0
EOF
cp toolchain-floors.schema.json "${fx}/toolchain-floors.schema.json"

# floors JSON -> write the fixture declaration with the given floor objects.
floors() { printf '{"schema_version":2,"floors":[%s]}\n' "$1" >"${fx}/toolchain-floors.json"; }
ACTION_PATH='template/.github/actions/setup/action.yml.jinja'
NODE_WORKFLOW_PATH='template/.github/workflows/[% if devcontainer %]devcontainer-build.yml[% endif %].jinja'
TASK_WORKFLOW_PATH='template/.github/workflows/[% if use_release_please and release_content_paths %]release-content-guard.yml[% endif %].jinja'
declared_pin() {
    jq -ce --arg tool "$1" --arg file "$2" '.floors[] | select(.tool == $tool) | .pins[] | select(.template_path == $file)' toolchain-floors.json
}
NODE_PIN="$(declared_pin node "$ACTION_PATH")"
NODE_PATTERN="$(jq -c .pattern <<<"$NODE_PIN")"
TASK_PIN="$(declared_pin task "$ACTION_PATH")"
mkdir -p "$rendered/.github/actions/setup" "$rendered/.github/workflows"
ln -s "$fx/$ACTION_PATH" "$rendered/.github/actions/setup/action.yml"
ln -s "$fx/$NODE_WORKFLOW_PATH" "$rendered/.github/workflows/devcontainer-build.yml"
ln -s "$fx/$TASK_WORKFLOW_PATH" "$rendered/.github/workflows/release-content-guard.yml"
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
    "$validator" --rendered "$rendered" --root "$fx" "$@" >"$out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || {
        cat "$out" >&2
        fail "${name}: exit ${rc}, want ${want}"
    }
    grep -F -- "$pattern" "$out" >/dev/null || {
        cat "$out" >&2
        fail "${name}: output lacks: ${pattern}"
    }
}

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

floors "$(node_floor 24 '{"path":".github/action/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":'"${NODE_PATTERN}"'}')"
expect "a consumer path that is not what template_path renders to fails" 1 "path is not what template/.github/actions/setup/action.yml.jinja renders to (.github/actions/setup/action.yml)"
floors "$(node_floor 24 '{"path":"missing","template_path":"template/missing.jinja","pattern":"(x)"}')"
expect "a template_path that does not exist fails" 1 "template/missing.jinja does not exist"
unrendered_pin="$(jq -c '.path = "unused.yml" | .template_path = "template/unused.yml.jinja"' <<<"$NODE_PIN")"
cp "$fx/$ACTION_PATH" "$fx/template/unused.yml.jinja"
floors "$(node_floor 24 "$unrendered_pin")"
expect "a template source with no rendered output fails" 1 "template/unused.yml.jinja is absent from every checked render"
floors "$(node_floor 24 '{"path":"../outside","template_path":"../outside","pattern":"(x)"}')"
expect "a template_path leaving the repository fails" 1 "leaves the repository"
floors "$(node_floor 24 '{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^nothing-here: ([0-9]+)$"}')"
expect "a pattern with no match fails" 1 "pattern matches nothing"
floors "$(node_floor 24 '{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^\\s*node-version: \"[0-9]+\"$"}')"
expect "a pattern with no capture group fails" 1 "no capture group 1"
floors "$(node_floor 24 '{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"("}')"
expect "a pattern that does not compile fails" 1 "pattern does not compile"
floors "$(node_floor 24 '{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":"^(\\s*)node-version"}')"
expect "a non-numeric capture fails" 1 "is not a major version"
floors "$(node_floor 24 '{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","json_pointer":"/x","pattern":"(x)"}')"
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
printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"use_node","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "when naming a boolean answer passes" 0 "node (major >= 24, when use_node)"
for bad in not_a_bool no_such_answer; do
    printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"%s","pins":[%s]}]}\n' "$bad" "$NODE_PIN" >"${fx}/toolchain-floors.json"
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
printf '{"schema_version":1,"floors":[%s]}\n' "$(node_floor 24)" >"${fx}/toolchain-floors.json"
expect "schema v1 fails even with an otherwise valid declaration" 1 "does not match its schema"
jq '.properties.schema_version.const = 1' "$fx/toolchain-floors.schema.json" >"$work/schema-v1.json"
expect "a supplied schema cannot opt the validator back into v1" 1 "unsupported schema_version; expected 2" --schema "$work/schema-v1.json"
printf '{not json\n' >"${fx}/toolchain-floors.json"
expect "unreadable JSON fails" 1 "cannot read valid JSON"

# A bare `version:` of another action must not stand in for the task pin.
cp "${fx}/template/.github/actions/setup/action.yml.jinja" "${work}/action.bak"
python3 - "${fx}/template/.github/actions/setup/action.yml.jinja" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("        version: 3.51.1\n", "")
open(path, "w").write(text)
PY
floors "$(task_floor 3.51.1)"
expect "another action's version: cannot satisfy the task pin" 1 "needs exactly one version input (found 0)"
cp "${work}/action.bak" "${fx}/template/.github/actions/setup/action.yml.jinja"
floors "$(task_floor 3.51.1)"
expect "the task pin is read from its own step" 0 ": 3.51.1 >= 3.51.1"
grep -F "9.0.0" "$out" >/dev/null && fail "the pnpm action's version leaked into the task comparison"
grep -F "1.0.0" "$out" >/dev/null && fail "a later action's version leaked into the task comparison"
lookahead_node_pin="$(jq -c '.pattern += "(?!\\n\\s*- uses: arduino/)"' <<<"$NODE_PIN")"
floors "$(node_floor 24 "$lookahead_node_pin")"
expect "a whole-file locator whose lookahead excludes the real next line fails" 1 "needs exactly one recognized node-version version"

# An empty pins list enforces nothing; only copier has a separate check.
floors '{"tool":"node","minimum":"24","compare":"major","pins":[]}'
expect "an empty pins list fails for a non-copier tool" 1 "node: declares no pins"
floors '{"tool":"copier","minimum":"9.4.0","compare":"version","pins":[]}'
expect "an empty pins list is fine for copier" 0 "toolchain-floors: ok"

# A pattern is validated whoever owns the pin.
floors "$(node_floor 24 '{"path":"package.json","template_path":null,"pattern":"("}')"
expect "an uncompilable consumer-owned pattern fails" 1 "pattern does not compile"
floors "$(node_floor 24 '{"path":"package.json","template_path":null,"pattern":"^pnpm@[0-9]+"}')"
expect "a consumer-owned pattern needs a capture group" 1 "no capture group 1"

# `when`: a trailing comment is fine; a type: line quoted inside help text is not a type.
for ok in commented_bool quoted_bool; do
    printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"%s","pins":[%s]}]}\n' "$ok" "$NODE_PIN" >"${fx}/toolchain-floors.json"
    expect "when ${ok} (type: bool with a trailing comment) passes" 0 "when ${ok}"
done
printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"help_trap","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "when naming a question whose help text quotes type: bool fails" 1 'when "help_trap" is not a boolean answer'
printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"hash_bool","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "type: bool#note is not the scalar bool" 1 'when "hash_bool" is not a boolean answer'

# A relative --floors resolves against --root, not the caller's directory.
mkdir -p "${work}/elsewhere"
printf '{"schema_version":2,"floors":[{"tool":"node","minimum":"99","compare":"major","pins":[%s]}]}\n' "$NODE_PIN" >"${work}/elsewhere/toolchain-floors.json"
floors "$(node_floor 24)"
echo "==> a relative --floors resolves against --root"
rc=0
(cd "${work}/elsewhere" && "$validator" --rendered "$rendered" --root "$fx" --floors toolchain-floors.json >"$out" 2>&1) || rc=$?
[ "$rc" = 0 ] || {
    cat "$out" >&2
    fail "a relative --floors read the caller's directory instead of --root"
}

# Git runs against --root only, not the caller's GIT_DIR.
floors "$(image_floor "$base")"
decoy="${work}/decoy.git"
git init -q --bare "$decoy"
echo "==> a caller's GIT_DIR/GIT_INDEX_FILE does not retarget the ancestry check"
rc=0
GIT_DIR="$decoy" GIT_INDEX_FILE="${decoy}/index" "$validator" --rendered "$rendered" --root "$fx" >"$out" 2>&1 || rc=$?
[ "$rc" = 0 ] || {
    cat "$out" >&2
    fail "ancestry followed the caller's GIT_DIR"
}
# Shallow: both endpoints present but the connecting history cut is unknown, not a rollback.
git -C "$fx" config uploadpack.allowAnySHA1InWant true
shallow="${work}/shallow"
mkdir -p "$shallow"
(cd "$fx" && tar -cf - --exclude=.git .) | (cd "$shallow" && tar -xf -)
git -C "$shallow" init -q
git -C "$shallow" fetch -q --depth 1 "$fx" "$base"
git -C "$shallow" fetch -q --depth 1 "$fx" "$child"
echo "==> a shallow clone reports an unproven ancestry as unknown, not a rollback"
write_dockerfile "$child"
cp "${fx}/${JINJA_DIR}/Dockerfile" "${shallow}/${JINJA_DIR}/Dockerfile"
rc=0
"$validator" --rendered "$rendered" --root "$shallow" >"$out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a shallow negative must fail, got exit ${rc}"
grep -F "unknown — this clone is shallow" "$out" >/dev/null || {
    cat "$out" >&2
    fail "a shallow negative must be reported as unknown"
}
grep -F "does not descend" "$out" >/dev/null && fail "a shallow negative was reported as a proven rollback"

# An annotated tag's object id is not the commit it points at.
git -C "$fx" tag -a -m "annotated" annotated "$child"
tagobj="$(git -C "$fx" rev-parse annotated)"
floors "$(image_floor "$base")"
write_dockerfile "$tagobj"
expect "an annotated tag id is not accepted as the pinned commit" 1 "${tagobj} is a tag object, not a commit"
floors "$(image_floor "$tagobj")"
write_dockerfile "$child"
expect "an annotated tag id is not accepted as the floor commit" 1 "${tagobj} is a tag object, not a commit"
write_dockerfile "$child"

# A _min_copier_version that is not dotted numeric cannot be compared.
cp "${fx}/copier.yml" "${work}/copier.yml.bak"
sed 's/^_min_copier_version:.*/_min_copier_version: "9.4..0"/' "${work}/copier.yml.bak" >"${fx}/copier.yml"
floors '{"tool":"copier","minimum":"9.4.0","compare":"version","pins":[]}'
expect "a malformed _min_copier_version is unverifiable, not sufficient" 1 'is not a dotted numeric version, so the floor cannot be verified'
cp "${work}/copier.yml.bak" "${fx}/copier.yml"

# The setup action's node pin: quoting is tolerated, and anything that is not a
# verifiable major fails rather than passing unseen.
SETUP_NODE='{"path":"setup-node.yml","template_path":"template/setup-node.yml.jinja","pattern":'"${NODE_PATTERN}"'}'
node_step() { printf '    - uses: actions/setup-node@0000 # v7\n      with:\n        %s\n' "$1" >"${fx}/template/setup-node.yml.jinja"; }
floors "$(node_floor 24 "$SETUP_NODE")"
node_step "node-version: '22'"
expect "a single-quoted node-version below the floor is caught" 1 "pinned 22 is below the floor 24"
node_step 'node-version: ${{ inputs.node }}'
expect "an uninterpretable node-version fails" 1 "pattern matches nothing"
node_step "node-version: \${{ vars.NODE_VERSION || '22' }}"
expect "an expression containing apostrophes fails" 1 "pattern matches nothing"
node_step 'node-version-file: .nvmrc'
expect "a node-version-file step is not a pin and fails the setup action's check" 1 "pattern matches nothing"
rm -f "${fx}/template/setup-node.yml.jinja"

# Exercise the real workflow declarations against two jobs. A correct step
# cannot cover an invalid sibling even across separate steps lists.
WORKFLOW_DIR="${fx}/template/.github/workflows"
NODE_WORKFLOW="$fx/$NODE_WORKFLOW_PATH"
TASK_WORKFLOW="$fx/$TASK_WORKFLOW_PATH"
mkdir -p "$WORKFLOW_DIR"
two_jobs() {
    cat <<'EOF'
jobs:
  first:
    steps:
EOF
    printf '%s\n' "$1"
    cat <<'EOF'
  second:
    steps:
EOF
    printf '%s\n' "$2"
}
node_good='      - uses: actions/setup-node@0000
        with:
          node-version: "24"'
task_good='      - uses: arduino/setup-task@0000
        with:
          version: 3.51.1'
floors "$(node_floor 24 "$(declared_pin node "$NODE_WORKFLOW_PATH")")"
two_jobs "$node_good" "$node_good" >"$NODE_WORKFLOW"
expect "both Node workflow steps pass independently" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 24 >= 24' "$out")" = 2 ] || fail "both Node versions must be compared"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: "24.21.0" # supported exact version' >"$NODE_WORKFLOW"
expect "an exact Node pin contributes its major to the floor check" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 24 >= 24' "$out")" = 2 ] || fail "both the major and exact Node pins must be compared"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: 24
            || 22' >"$NODE_WORKFLOW"
expect "a continued Node scalar must be validated as a whole" 1 "needs exactly one recognized node-version version"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: 24.21.0
            || 22' >"$NODE_WORKFLOW"
expect "a continued exact Node scalar must be validated as a whole" 1 "needs exactly one recognized node-version version"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: "23.21.0"' >"$NODE_WORKFLOW"
expect "an exact Node pin below the major floor fails" 1 "pinned 23 is below the floor 24"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: "24 # main"' >"$NODE_WORKFLOW"
expect "a hash inside a quoted Node pin is part of the value" 1 "needs exactly one recognized node-version version"
[ "$(grep -Fc ': 24 >= 24' "$out")" = 1 ] || fail "only the valid Node pin should be compared"
two_jobs "$node_good" '      - uses: ./local-action
        with:
          node-version: "20"' >"$NODE_WORKFLOW"
expect "a Node locator match outside a setup step still has to meet the floor" 1 "pinned 20 is below the floor 24"
two_jobs '      - &setup_node
        uses: actions/setup-node@0000
        with:
          node-version: "24"' '      - *setup_node' >"$NODE_WORKFLOW"
expect "a Node step referenced by an alias is still counted" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 24 >= 24' "$out")" = 2 ] || fail "the Node step and its alias must both be compared"
two_jobs '      - uses: actions/setup-node@0000
        with: &node_inputs
          node-version: "24"' '      - uses: actions/setup-node@0000
        with: *node_inputs' >"$NODE_WORKFLOW"
expect "a Node version from the selected with alias is recognized" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 24 >= 24' "$out")" = 2 ] || fail "both steps using the anchored version must be compared"
cat >"$NODE_WORKFLOW" <<'EOF'
jobs:
  fixture:
    strategy:
      matrix:
        shared: &shared_steps
          - uses: actions/setup-node@v6
            with:
              node-version: "24"
    steps: *shared_steps
EOF
expect "an aliased steps list from a job matrix is recognized" 0 ": 24 >= 24"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version-file: .nvmrc' >"$NODE_WORKFLOW"
expect "one node-version-file step fails beside a valid Node step" 1 "needs exactly one node-version input (found 0)"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version:
            "24.21.0"' >"$NODE_WORKFLOW"
expect "a version on the line after its key is recognized at its value position" 0 '[rendered]:12:13: 24 >= 24'
for invalid in '024.21.0' '24.021.0' '24.21.00'; do
    two_jobs "$node_good" "      - uses: actions/setup-node@0000
        with:
          node-version: "$invalid"" >"$NODE_WORKFLOW"
    expect "Node rejects leading zero in $invalid" 1 "needs exactly one recognized node-version version"
done
two_jobs "$node_good" '      - uses: "actions/\x73etup-node@0000"
        with:
          node-version-file: .nvmrc' >"$NODE_WORKFLOW"
expect "an escaped action name still needs its own version" 1 "needs exactly one node-version input (found 0)"
two_jobs "$node_good" '      - uses: actions/setup-node/.@0000
        with:
          node-version-file: .nvmrc' >"$NODE_WORKFLOW"
expect "a repo-root action path still needs its own version" 1 "needs exactly one node-version input (found 0)"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with:
          node-version: ${{ vars.NODE_VERSION || '\''22'\'' }}' >"$NODE_WORKFLOW"
expect "a Node expression with apostrophes fails beside a valid Node step" 1 "needs exactly one recognized node-version version"
two_jobs "$node_good" '      - uses: actions/setup-node@0000
        with: {node-version: "24"}' >"$NODE_WORKFLOW"
expect "a flow-style input mapping fails beside a valid Node step" 1 "unsupported flow-style mapping"
two_jobs "$node_good" '      - {uses: actions/setup-node@0000, with: {node-version: "24"}}' >"$NODE_WORKFLOW"
expect "a flow-style step mapping fails beside a valid Node step" 1 "unsupported flow-style mapping"
two_jobs "$node_good" '      - name: Set up Node
        uses: actions/setup-node@0000' >"$NODE_WORKFLOW"
expect "a name-first Node step is still counted" 1 "needs exactly one node-version input (found 0)"
two_jobs '      - name: No setup action
        run: echo hello' '      - run: echo goodbye' >"$NODE_WORKFLOW"
expect "a workflow with no Node setup steps fails" 1 "no actions/setup-node steps found"

floors "$(task_floor 3.51.1 "$(declared_pin task "$TASK_WORKFLOW_PATH")")"
two_jobs "$task_good" "$task_good" >"$TASK_WORKFLOW"
expect "both Task workflow steps pass independently" 0 "toolchain-floors: ok"
two_jobs "$task_good" '      - name: Set up Task
        uses: arduino/setup-task@0000
        env:
          version: 1.0.0
        with:
          repo-token: token-value
          version: "3.51.1" # supported quoted version' >"$TASK_WORKFLOW"
expect "a name-first Task step uses its quoted with.version despite an earlier version" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 3.51.1 >= 3.51.1' "$out")" = 2 ] || fail "both Task versions must be compared"
two_jobs "$task_good" '      - name: Set up Task
        uses: arduino/setup-task@0000
        env:
          version: 9.0.0
        with:
          version: "3.50.0"' >"$TASK_WORKFLOW"
expect "a higher version elsewhere in the Task step does not mask a low with.version" 1 "pinned 3.50.0 is below the floor 3.51.1"
two_jobs "$task_good" '      - name: Set up Task
        uses: arduino/setup-task@0000
        with:
          version: 3.51.1
            || 1.0.0' >"$TASK_WORKFLOW"
expect "a continued Task scalar must be validated as a whole" 1 "needs exactly one recognized version version"
two_jobs "$task_good" '      - name: Set up Task
        uses: arduino/setup-task@0000
        with:
          repo-token: token-value
        env:
          version: 3.51.1' >"$TASK_WORKFLOW"
expect "a version after the Task with mapping cannot stand in for with.version" 1 "needs exactly one version input (found 0)"
[ "$(grep -Fc ': 3.51.1 >= 3.51.1' "$out")" = 1 ] || fail "only the valid Task input should be compared"
two_jobs "$task_good" "$task_good" >"$TASK_WORKFLOW"
adjacent_task_pin="$(declared_pin task "$TASK_WORKFLOW_PATH" | jq -c '.pattern = "^\\s*- uses: arduino/setup-task@[^\\n]*\\n\\s*version: ([0-9]+\\.[0-9]+\\.[0-9]+)$"')"
floors "$(task_floor 3.51.1 "$adjacent_task_pin")"
expect "a pattern requiring adjacent uses and version fails across the real with line" 1 "needs exactly one recognized version version"
floors "$(task_floor 3.51.1 "$(declared_pin task "$TASK_WORKFLOW_PATH")")"
two_jobs "$task_good" '      - uses: arduino/setup-task@0000
      - uses: other/action@0000
        with:
          version: 3.51.1' >"$TASK_WORKFLOW"
expect "one Task setup step without a version fails beside a valid step" 1 "needs exactly one version input (found 0)"
two_jobs "$task_good" '      - uses: arduino/setup-task@0000
        with:
          version: 3.51.1
          version: 3.51.1' >"$TASK_WORKFLOW"
expect "two versions in a single Task step fail" 1 "needs exactly one version input (found 2)"

# A job-level reusable-workflow input and a nested uses are not action steps.
floors "$(task_floor 3.51.1 "$(declared_pin task "$TASK_WORKFLOW_PATH")")"
cat >"$TASK_WORKFLOW" <<'EOF'
jobs:
  first:
    steps:
      - uses: arduino/setup-task@0000
        with:
          version: 3.51.1
  reusable:
    uses: owner/repo/.github/workflows/reusable.yml@main
    with:
      version: 1.0.0
EOF
expect "a reusable workflow input in a later job is not a Task pin" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 3.51.1 >= 3.51.1' "$out")" = 1 ] || fail "only the setup-task input should be compared"
two_jobs "$task_good" '      - name: Not a setup action
        env:
          uses: arduino/setup-task@0000
        with:
          version: 1.0.0' >"$TASK_WORKFLOW"
expect "a nested uses does not select a Task step" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 3.51.1 >= 3.51.1' "$out")" = 1 ] || fail "the nested uses must not select a Task input"
two_jobs '      - uses: arduino/setup-task@0000
        "with":
          version: 3.51.1' '      - uses: arduino/setup-task@0000
        with: &inputs
          version: 3.51.1' >"$TASK_WORKFLOW"
expect "quoted and anchored with mappings both select their Task input" 0 "toolchain-floors: ok"
[ "$(grep -Fc ': 3.51.1 >= 3.51.1' "$out")" = 2 ] || fail "both Task inputs should be compared"
partial_task_pin="$(declared_pin task "$TASK_WORKFLOW_PATH" | jq -c '.pattern = "^([0-9]+\\.[0-9]+)"')"
floors "$(task_floor 3.51 "$partial_task_pin")"
expect "compare version rejects a partial capture of an otherwise valid value" 1 "needs exactly one recognized version version"
grep -F ': 3.51 >= 3.51' "$out" >/dev/null || fail "fixture must capture a value that would meet the floor"

# Inventory uses rendered workflow names, parsed action identities and the
# exact input from the declaration.
floors "$(node_floor 24 "${NODE_PIN},$(declared_pin node "$NODE_WORKFLOW_PATH")"),$(task_floor 3.51.1 "${TASK_PIN},$(declared_pin task "$TASK_WORKFLOW_PATH")")"
two_jobs "$node_good" "$node_good" >"$NODE_WORKFLOW"
two_jobs "$task_good" "$task_good" >"$TASK_WORKFLOW"
printf '%s\n' 'uses: actions/setup-node@0000' 'not YAML' >"$rendered/.github/workflows/example.md"
expect "inventory ignores files that are not YAML workflows" 0 "toolchain-floors: ok" --inventory
two_jobs '      - uses: "actions/\x73etup-node@0000"
        with:
          node-version: "24"' '      - run: echo hello' >"$rendered/.github/workflows/undeclared.yaml"
two_jobs "$task_good" '      - run: echo hello' >"$rendered/.github/workflows/undeclared-task.yml"
expect "inventory parses an escaped action name in a rendered .yaml file" 1 "undeclared actions/setup-node step with input node-version" --inventory
grep -F 'undeclared arduino/setup-task step with input version' "$out" >/dev/null ||
    fail "the inventory missed the undeclared Task step"
rm "$rendered/.github/workflows/undeclared.yaml" "$rendered/.github/workflows/undeclared-task.yml"
wrong_node_pin="$(declared_pin node "$NODE_WORKFLOW_PATH" | jq -c '.step.input = "node-version-file"')"
floors "$(node_floor 24 "${NODE_PIN},${wrong_node_pin}"),$(task_floor 3.51.1 "${TASK_PIN},$(declared_pin task "$TASK_WORKFLOW_PATH")")"
expect "inventory rejects a declaration covering the wrong input" 1 "undeclared actions/setup-node step with input node-version" --inventory

if [ -z "${TOOLCHAIN_FLOORS_TEST_NESTED:-}" ]; then
    render_failure() {
        cat "$out" >&2
        fail "$1"
    }
    echo "==> Copier renders the fixture and the standalone guard checks each rendered step"
    e2e="$work/e2e"
    e2e_workflow='.github/workflows/render-regressions.yml'
    profile_workflow='.github/workflows/profile-specific.yml'
    mkdir -p "$e2e/template/.github/workflows"
    cp "$fx/toolchain-floors.schema.json" "$e2e"
    e2e_pin="$(jq -c --arg file "$e2e_workflow" '.path = $file | .template_path = ("template/" + $file + ".jinja")' <<<"$NODE_PIN")"
    profile_pin="$(jq -c --arg file "$profile_workflow" '.path = $file | .template_path = ("template/" + $file + ".jinja")' <<<"$NODE_PIN")"
    printf '{"schema_version":2,"floors":[%s]}\n' "$(node_floor 24 "$e2e_pin,$profile_pin")" >"$e2e/toolchain-floors.json"
    cat >"$e2e/copier.yml" <<'EOF'
_subdirectory: template
_envops:
  block_start_string: "[%"
  block_end_string: "%]"
  variable_start_string: "[["
  variable_end_string: "]]"
  comment_start_string: "[#"
  comment_end_string: "#]"
  trim_blocks: true
  lstrip_blocks: true
setup_name:
  type: str
  default: node
project_type:
  type: str
  default: base
EOF
    cat >"$e2e/template/$e2e_workflow.jinja" <<'EOF'
jobs:
  setup:
    steps:
      - uses: actions/setup-node@v6
        with: &valid_inputs
          node-version: "24"
      - name: Conditional uses
[% if setup_name == 'node' %]
        uses: actions/setup-node@v6
[% else %]
        uses: owner/local-action@v1
[% endif %]
      - name: Conditional alias
        uses: actions/setup-node@v6
[% if setup_name != 'node' %]
        with: *valid_inputs
[% endif %]
      - name: Substituted uses
        uses: actions/setup-[[ setup_name ]]@v6
      - name: Escaped uses
        uses: "actions/\x73etup-node@v6"
      - name: Commented pin
        uses: actions/setup-node@v6
        with:
          # [#
          node-version: "24"
          # #]
          node-version-file: .nvmrc
      - name: Trailing control
        uses: actions/setup-node@v6
        with: # [% if setup_name != 'node' %]
          node-version: "24"
[% endif %]

      - name: Repo-root uses
        uses: actions/setup-node/.@v6
      - uses: actions/setup-node@v6
        with:
          node-version:
            "24.21.0"
EOF
    cat >"$e2e/template/$profile_workflow.jinja" <<'EOF'
jobs:
  setup:
    steps:
      - run: echo setup
[% if project_type != 'web-app' %]
      - uses: actions/setup-node@v6
[% if project_type != 'iac' %]
        with:
          node-version: "24"
[% endif %]
[% endif %]
EOF
    iac_source="template/.github/workflows/[% if project_type == 'iac' %]iac-undeclared.yml[% endif %].jinja"
    absent_source='template/.github/workflows/[% if false %]never-rendered.yml[% endif %].jinja'
    cat >"$e2e/$iac_source" <<'EOF'
jobs:
  setup:
    steps:
      - uses: actions/setup-node@v6
EOF
    cp "$e2e/$iac_source" "$e2e/$absent_source"
    sample='template/.github/workflows/examples/sample.yml.jinja'
    mkdir -p "$(dirname "$e2e/$sample")"
    cp "$e2e/$iac_source" "$e2e/$sample"
    git -C "$e2e" init -q
    git -C "$e2e" add .
    git -C "$e2e" commit -qm fixture
    rc=0
    "$validator" --root "$e2e" >"$out" 2>&1 || rc=$?
    task_profiles="$(yq -r '.tasks."test:template:all".deps[] | select(. != "test:template:update") | sub("^test:template:", "")' Taskfile.yml | sort)" ||
        render_failure "could not enumerate the Taskfile's smoke profiles"
    checked_profiles="$(sed -nE 's|^  ok +node .github/workflows/render-regressions\.yml .*\[([^]]+)\]:.*24 >= 24$|\1|p' "$out" | sort -u)" ||
        render_failure "could not read the floor check's smoke profiles"
    [ "$task_profiles" = "$checked_profiles" ] || render_failure "the floor matrix must check the same render profiles as test:template:all"
    profile_count="$(wc -l <<<"$task_profiles")" || render_failure "could not count the Taskfile's smoke profiles"
    reg_errors="$(grep -Ec 'render-regressions\.yml .*needs exactly one node-version input \(found 0\)' "$out" || true)"
    profile_errors="$(grep -Ec '^toolchain-floors: node .github/workflows/profile-specific\.yml ' "$out" || true)"
    if [ "$rc" != 1 ] ||
        [ "$reg_errors" != "$((7 * profile_count))" ] ||
        [ "$profile_errors" != 1 ] ||
        ! grep -Eq 'profile-specific\.yml .*\[full\]:.+24 >= 24' "$out" ||
        ! grep -Eq 'profile-specific\.yml .*\[iac\]:.+needs exactly one node-version input' "$out" ||
        ! grep -Eq 'iac-undeclared\.yml \[iac\]:[0-9]+: undeclared actions/setup-node step' "$out" ||
        ! grep -Fq "$absent_source: workflow or action source does not render in any checked profile" "$out" ||
        grep -Fq 'examples/sample.yml' "$out"; then
        render_failure "the render matrix must distinguish absent sources, absent steps, unpinned steps and nested samples"
    fi

    mkdir "$work/copier-bin"
    printf 'trust: ["/"]\n' >"$work/ambient-copier.yml"
    cat >"$work/copier-bin/copier" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = --version ]; then
    echo 'copier fixture'
else
    [ "$(cat "$COPIER_SETTINGS_PATH")" = '{}' ]
    if [ "$RENDER_FIXTURE" = empty ]; then
        mkdir "${!#}"
    fi
fi
EOF
    chmod +x "$work/copier-bin/copier"
    for state in missing empty; do
        rc=0
        PATH="$work/copier-bin:$PATH" COPIER_SETTINGS_PATH="$work/ambient-copier.yml" RENDER_FIXTURE="$state" \
            "$validator" --root "$e2e" >"$out" 2>&1 || rc=$?
        [ "$rc" = 1 ] && grep -Fq 'full: Copier render directory is missing or empty' "$out" ||
            render_failure "the $state render must fail with the profile named and Copier settings isolated"
    done

    unsupported_sources=(
        'template/.github/workflows/[% if true %]a.yml[% else %]b.yml[% endif %].jinja'
        'template/.github/workflows/[[ setup_name ]].yml.jinja'
        'template/.github/[% if false %]workflows[% endif %]/conditional-dir.yml.jinja'
    )
    for file in "${unsupported_sources[@]}"; do
        mkdir -p "$(dirname "$e2e/$file")"
        cp "$e2e/$iac_source" "$e2e/$file"
        git -C "$e2e" add -- "$file"
    done
    rc=0
    "$validator" --root "$e2e" >"$out" 2>&1 || rc=$?
    [ "$rc" = 1 ] || render_failure "unsupported Jinja source names must fail closed"
    for file in "${unsupported_sources[@]}"; do
        grep -Fq "$file: unsupported Jinja in template source path" "$out" ||
            render_failure "the unsupported name diagnostic must identify $file"
    done
fi

# Fail closed outside a git repository: no history means ancestry is unknown.
nogit="${work}/nogit"
cp -R "$fx" "$nogit"
rm -rf "${nogit}/.git"
floors "$(image_floor "$base")"
cp "${fx}/toolchain-floors.json" "${nogit}/toolchain-floors.json"
rc=0
"$validator" --rendered "$rendered" --root "$nogit" >"$out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "ancestry outside a git repository must fail, got exit ${rc}"
grep -F "unknown" "$out" >/dev/null || fail "ancestry outside a git repository must be unknown"

echo "==> usage errors exit 2"
rc=0
"$validator" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unknown argument: exit ${rc}, want 2"

# The whole suite must leave a caller's repository alone when a hook has exported
# GIT_DIR / GIT_INDEX_FILE: run it once more under a decoy and prove the decoy is untouched.
if [ -z "${TOOLCHAIN_FLOORS_TEST_NESTED:-}" ]; then
    echo "==> the suite ignores a caller's GIT_DIR and leaves that repository untouched"
    rc=0
    : >"${work}/decoy.gitconfig"
    TOOLCHAIN_FLOORS_TEST_NESTED=1 GIT_CONFIG="${work}/decoy.gitconfig" GIT_DIR="$decoy" GIT_INDEX_FILE="${decoy}/index" GIT_WORK_TREE="$work" \
        "$self" >"$out" 2>&1 || rc=$?
    [ "$rc" = 0 ] || {
        cat "$out" >&2
        fail "the suite failed under an inherited GIT_DIR"
    }
    [ -z "$(git --git-dir="$decoy" for-each-ref)" ] || fail "the suite wrote a ref into the caller's repository"
    git --git-dir="$decoy" rev-parse --verify -q HEAD >/dev/null && fail "the suite committed into the caller's repository"
    [ ! -e "${decoy}/index" ] || fail "the suite wrote the caller's index"
    [ ! -s "${work}/decoy.gitconfig" ] || fail "the suite wrote the caller's GIT_CONFIG file"
fi

echo "OK: validate-toolchain-floors"
