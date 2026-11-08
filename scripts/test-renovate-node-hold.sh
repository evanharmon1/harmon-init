#!/usr/bin/env bash
# test-renovate-node-hold.sh — prove the Node runtime hold in a rendered
# renovate.json selects exactly the runtime pins (#2013).
#
# Usage: ./scripts/test-renovate-node-hold.sh <rendered-repo-dir>
#
# Renovate itself extracts the dependencies (`--platform=local
# --dry-run=extract`, no token, no lookups), so the test sees the manager,
# depName and datasource Renovate really assigns to each pin, including
# setup-node's `node-version` input, which only the github-actions manager's
# known-actions table turns into a `node` dependency. The hold's matchers are
# literal (`matchManagers`, `matchDepNames`, `matchDatasources`), so applying
# them to the extracted dependencies is exact: Renovate reports a custom
# manager as `regex`, which `custom.regex` in matchManagers selects.
#
# The rendered tree is copied first and negative fixtures are added to the
# copy: a package.json with engines.node and @types/node, a Dockerfile FROM
# node, and a workflow whose job container and service are node images. The
# workflow images matter most: the github-actions manager extracts them as
# depName `node` too, with datasource docker, so only the hold's datasource
# matcher keeps them out. None is the CI runtime; the hold must select none.
#
# Network: npx resolves the pinned Renovate from npm, so this runs only in the
# network-bound `renovate-config` scope of test-template.sh, never in verify.
set -euo pipefail

src="${1:?usage: $0 <rendered-repo-dir>}"
[ -f "$src/renovate.json" ] || {
    echo "FAIL: $src has no renovate.json" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$src" "$work/repo"
cd "$work/repo"

cat >node-hold-fixture.package.json <<'JSON'
{
  "name": "node-hold-fixture",
  "private": true,
  "engines": { "node": ">=24" },
  "devDependencies": { "@types/node": "24.0.0" }
}
JSON
mkdir -p node-hold-fixture
mv node-hold-fixture.package.json node-hold-fixture/package.json
printf 'FROM node:24.11.0-bookworm\n' >node-hold-fixture/Dockerfile
mkdir -p .github/workflows
cat >.github/workflows/node-hold-fixture.yml <<'YAML'
name: node-hold-fixture
on: push
jobs:
  fixture:
    runs-on: ubuntu-latest
    container: node:24.11.0-bookworm
    services:
      cache:
        image: node:24.11.0-slim
    steps:
      - run: "true"
YAML

# Renovate's local platform reads the file list from git. The copy is a
# throwaway fixture repository with no hooks of its own; an empty hooks path
# keeps a user-level core.hooksPath from running against it.
rm -rf .git
git init -q
git add -A >/dev/null
git -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm fixture

# renovate: datasource=npm depName=renovate
RENOVATE_VALIDATOR_VERSION=44.216.2
# Renovate's exit status is not the signal: it exits non-zero on a host whose
# Node it does not support even after a complete extraction. The logged
# packageFiles are the evidence, and the analysis below fails when they are
# missing or incomplete.
LOG_LEVEL=debug LOG_FORMAT=json RENOVATE_CONFIG_FILE="$PWD/renovate.json" \
    npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate --platform=local --dry-run=extract \
    --enabled-managers=github-actions,custom.regex,npm,dockerfile \
    >"$work/extract.log" 2>&1 || true

python3 -I - renovate.json "$work/extract.log" <<'PY' || {
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
holds = [r for r in config["packageRules"] if r.get("matchDepNames") == ["node"]]
if len(holds) != 1:
    sys.exit(f"expected exactly one Node runtime hold, found {len(holds)}")
hold = holds[0]
expected = {"matchManagers": ["github-actions", "custom.regex"], "matchDepNames": ["node"], "matchDatasources": ["node-version", "github-releases"], "allowedVersions": "<25"}
if {k: v for k, v in hold.items() if k != "description"} != expected:
    sys.exit(f"Node runtime hold has unexpected matchers: {hold}")

package_files = None
for line in open(sys.argv[2], encoding="utf-8"):
    try:
        record = json.loads(line)
    except ValueError:
        continue
    if isinstance(record, dict) and isinstance(record.get("packageFiles"), dict):
        package_files = record["packageFiles"]
if package_files is None:
    sys.exit("renovate extract logged no packageFiles; Renovate did not complete an extraction")


def selected(manager, dep):
    name = "custom." + manager if manager == "regex" else manager
    return (name in hold["matchManagers"] and dep.get("depName") in hold["matchDepNames"]
            and dep.get("datasource") in hold["matchDatasources"])


runtime, rejected = [], []
for manager, files in package_files.items():
    for package_file in files:
        for dep in package_file.get("deps", []):
            where = f"{manager}:{package_file.get('packageFile')}:{dep.get('depName')}"
            if selected(manager, dep):
                runtime.append((manager, dep.get("datasource"), dep.get("currentValue"), where))
            elif "node" in (dep.get("depName") or "") or "node" in (dep.get("packageName") or ""):
                rejected.append((manager, dep.get("depType"), dep.get("depName"), where))

kinds = {(m, d) for m, d, _, _ in runtime}
for want in (("regex", "node-version"), ("github-actions", "github-releases")):
    if want not in kinds:
        sys.exit(f"hold selects no {want[0]} / {want[1]} Node runtime pin; selected: {sorted(kinds)}")
for manager, datasource, value, where in runtime:
    if (manager, datasource) not in (("regex", "node-version"), ("github-actions", "github-releases")):
        sys.exit(f"hold selects a non-runtime dependency: {where} ({datasource})")
    if not str(value).startswith("24"):
        sys.exit(f"selected runtime pin is not on the held 24 major: {where} = {value}")

seen = {(m, t, n) for m, t, n, _ in rejected}
for want in (("npm", "engines", "node"), ("npm", "devDependencies", "@types/node"), ("dockerfile", "final", "node"),
             ("github-actions", "container", "node"), ("github-actions", "service", "node")):
    if want not in seen:
        sys.exit(f"negative fixture {want} was not extracted, so the test proves nothing about it; extracted: {sorted(seen)}")

print(f"Node runtime hold selects {len(runtime)} runtime pins "
      f"({', '.join(sorted(f'{m}/{d}' for m, d in kinds))}) and none of: "
      + ", ".join(sorted(f"{m}/{t}/{n}" for m, t, n in seen)))
PY
    echo "FAIL: Node runtime hold check failed; last lines of the Renovate extract log:" >&2
    tail -20 "$work/extract.log" >&2
    exit 1
}
