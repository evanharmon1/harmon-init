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
self="${repo}/scripts/test-validate-toolchain-floors.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-floors-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fx="${work}/fx"
out="${work}/out.txt"

# The real tree runs FIRST, with the caller's own Git configuration: a devcontainer
# bind mount can depend on a global safe.directory entry, and only the throwaway
# fixture below may discard it.
# The nested run (below) has the scrubbed Git config; the outer run already checked the real tree.
if [ -z "${TOOLCHAIN_FLOORS_TEST_NESTED:-}" ]; then
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
    # The published pnpm locator, applied to representative packageManager values.
    pnpm_pointer="$(node -e 'const f=JSON.parse(require("fs").readFileSync("toolchain-floors.json","utf8")).floors.find((x)=>x.tool==="pnpm");process.stdout.write(f.pins[0].json_pointer)')"
    [ "$pnpm_pointer" = "/packageManager" ] || fail "the pnpm pin must locate /packageManager, got ${pnpm_pointer}"
    for value in 'pnpm@11.2.0' 'pnpm@11.2.0+sha512.abc123'; do
        major="$(node -e 'const f=JSON.parse(require("fs").readFileSync("toolchain-floors.json","utf8")).floors.find((x)=>x.tool==="pnpm");const m=new RegExp(f.pins[0].pattern).exec(process.argv[1]);process.stdout.write(m?m[1]:"")' "$value")"
        [ "$major" = "11" ] || fail "the pnpm pattern captured '${major}' from ${value}, want 11"
    done
    for value in 'npm@10.0.0' 'yarn@4.0.0' 'pnpm-ish@11.0.0'; do
        major="$(node -e 'const f=JSON.parse(require("fs").readFileSync("toolchain-floors.json","utf8")).floors.find((x)=>x.tool==="pnpm");const m=new RegExp(f.pins[0].pattern).exec(process.argv[1]);process.stdout.write(m?m[1]:"")' "$value")"
        [ -z "$major" ] || fail "the pnpm pattern matched ${value}"
    done
fi

# Keep the fixture's git independent of the caller: hooks export GIT_DIR /
# GIT_WORK_TREE / GIT_INDEX_FILE, which would retarget every fixture command at
# the caller's real repository (scripts/test-worktree.sh does the same).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
    GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
for _i in 0 1 2 3 4 5 6 7 8 9; do unset "GIT_CONFIG_KEY_${_i}" "GIT_CONFIG_VALUE_${_i}"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
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
floors() { printf '{"schema_version":1,"floors":[%s]}\n' "$1" >"${fx}/toolchain-floors.json"; }
NODE_PATTERN="$(node -e 'const f=JSON.parse(require("fs").readFileSync("toolchain-floors.json","utf8")).floors.find((x)=>x.tool==="node");process.stdout.write(JSON.stringify(f.pins[0].pattern))')"
NODE_PIN='{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":'"${NODE_PATTERN}"'}'
TASK_PATTERN="$(node -e 'const f=JSON.parse(require("fs").readFileSync("toolchain-floors.json","utf8")).floors.find((x)=>x.tool==="task");process.stdout.write(JSON.stringify(f.pins[0].pattern))')"
TASK_PIN='{"path":".github/actions/setup/action.yml","template_path":"template/.github/actions/setup/action.yml.jinja","pattern":'"${TASK_PATTERN}"'}'
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

# A bare `version:` of another action must not stand in for the task pin.
cp "${fx}/template/.github/actions/setup/action.yml.jinja" "${work}/action.bak"
python3 - "${fx}/template/.github/actions/setup/action.yml.jinja" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("        version: 3.51.1\n", "")
open(path, "w").write(text)
PY
floors "$(task_floor 3.51.1)"
expect "another action's version: cannot satisfy the task pin" 1 "pattern matches nothing"
cp "${work}/action.bak" "${fx}/template/.github/actions/setup/action.yml.jinja"
floors "$(task_floor 3.51.1)"
expect "the task pin is read from its own step" 0 ": 3.51.1 >= 3.51.1"
grep -F "9.0.0" "$out" >/dev/null && fail "the pnpm action's version leaked into the task comparison"
grep -F "1.0.0" "$out" >/dev/null && fail "a later action's version leaked into the task comparison"

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
    printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"%s","pins":[%s]}]}\n' "$ok" "$NODE_PIN" >"${fx}/toolchain-floors.json"
    expect "when ${ok} (type: bool with a trailing comment) passes" 0 "when ${ok}"
done
printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"help_trap","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "when naming a question whose help text quotes type: bool fails" 1 'when "help_trap" is not a boolean answer'
printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"24","compare":"major","when":"hash_bool","pins":[%s]}]}\n' "$NODE_PIN" >"${fx}/toolchain-floors.json"
expect "type: bool#note is not the scalar bool" 1 'when "hash_bool" is not a boolean answer'

# A relative --floors resolves against --root, not the caller's directory.
mkdir -p "${work}/elsewhere"
printf '{"schema_version":1,"floors":[{"tool":"node","minimum":"99","compare":"major","pins":[%s]}]}\n' "$NODE_PIN" >"${work}/elsewhere/toolchain-floors.json"
floors "$(node_floor 24)"
echo "==> a relative --floors resolves against --root"
rc=0
(cd "${work}/elsewhere" && "$validator" --root "$fx" --floors toolchain-floors.json >"$out" 2>&1) || rc=$?
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
GIT_DIR="$decoy" GIT_INDEX_FILE="${decoy}/index" "$validator" --root "$fx" >"$out" 2>&1 || rc=$?
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
"$validator" --root "$shallow" >"$out" 2>&1 || rc=$?
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

# Every setup-node step is held to the floor, whatever its quoting.
cat >"${fx}/template/two-node.yml.jinja" <<'EOF'
    - uses: actions/setup-node@0000 # v7
      with:
        node-version: "24"
    - uses: actions/setup-node@0000 # v7
      with:
        node-version: '22'
EOF
TWO_NODE='{"path":"w.yml","template_path":"template/two-node.yml.jinja","pattern":'"${NODE_PATTERN}"'}'
floors "$(node_floor 24 "$TWO_NODE")"
expect "a single-quoted node-version below the floor is caught" 1 "pinned 22 is below the floor 24"
printf '    - uses: actions/setup-node@0000\n      with:\n        node-version: "24"\n    - uses: actions/setup-node@0000\n      with:\n        node-version: ${{ inputs.node }}\n' >"${fx}/template/two-node.yml.jinja"
expect "an uninterpretable node-version fails even beside a valid one" 1 "is not a major version"
rm -f "${fx}/template/two-node.yml.jinja"

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

# The whole suite must leave a caller's repository alone when a hook has exported
# GIT_DIR / GIT_INDEX_FILE: run it once more under a decoy and prove the decoy is untouched.
if [ -z "${TOOLCHAIN_FLOORS_TEST_NESTED:-}" ]; then
    echo "==> the suite ignores a caller's GIT_DIR and leaves that repository untouched"
    rc=0
    TOOLCHAIN_FLOORS_TEST_NESTED=1 GIT_DIR="$decoy" GIT_INDEX_FILE="${decoy}/index" GIT_WORK_TREE="$work" \
        "$self" >"$out" 2>&1 || rc=$?
    [ "$rc" = 0 ] || {
        cat "$out" >&2
        fail "the suite failed under an inherited GIT_DIR"
    }
    [ -z "$(git --git-dir="$decoy" for-each-ref)" ] || fail "the suite wrote a ref into the caller's repository"
    git --git-dir="$decoy" rev-parse --verify -q HEAD >/dev/null && fail "the suite committed into the caller's repository"
    [ ! -e "${decoy}/index" ] || fail "the suite wrote the caller's index"
fi

echo "OK: validate-toolchain-floors"
