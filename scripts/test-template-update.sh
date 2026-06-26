#!/usr/bin/env bash
# test-template-update.sh — verify `copier update` on a generated repo is safe.
#
# Asserts that, going from one template version to the next:
#   - template improvements are delivered,
#   - a repo's own edits to a template file survive (three-way merge), so repos
#     can be customized normally without an extension-file dance,
#   - one-time seeds (_skip_if_exists, e.g. README) are not clobbered,
#   - first-run _tasks do NOT re-run (no spurious scaffold commit / re-init),
#   - no merge conflicts or .rej files are left behind.
#
# Like test-template.sh, this tests the CURRENT working tree: it builds a throwaway
# tagged git "template source" from the working tree (copier update needs the
# recorded _commit to be a resolvable version tag, so HEAD/dirty refs won't do).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d -t harmon-init-update-XXXXXX)"
trap 'rm -rf "$work"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
for t in copier git rsync; do
    if ! have "$t"; then
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "FAIL: required tool '$t' is not installed in CI" >&2
            exit 1
        fi
        echo "SKIP: '$t' not installed — skipping update test"
        exit 0
    fi
done

fail=0
err() {
    echo "FAIL: $*" >&2
    fail=1
}

tmpl="$work/template"
gen="$work/gen"
gitq() { git -C "$1" -c user.email=t@t.co -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# 1. Tagged template source from the working tree (excluding heavy/vcs dirs).
mkdir -p "$tmpl"
rsync -a \
    --exclude=.git --exclude=.task --exclude=.venv --exclude=node_modules \
    --exclude=.worktrees --exclude=dist "$repo_root/" "$tmpl/"
git -C "$tmpl" init -q
gitq "$tmpl" add -A
gitq "$tmpl" commit -qm base
git -C "$tmpl" tag v0.0.1

# 2. Generate a repo from v0.0.1. git_init=false so copier's own init+commit
#    _tasks don't run — the test controls git state itself.
copier copy "$tmpl" "$gen" --vcs-ref=v0.0.1 --trust --defaults \
    --data project_name="Update Test" --data project_slug="update-test" \
    --data github_org="someorg" --data project_type="iac" \
    --data git_init=false --data github_remote_create=false \
    --data github_release_init=false --data run_task_install=false \
    --data bunch_add=false --data obsidian_project_add=false >/dev/null 2>&1
git -C "$gen" init -q
gitq "$gen" add -A
gitq "$gen" commit -qm "initial scaffold"

# 3. Customize the repo the NORMAL way: edit a template-owned file in place
#    (add a project task) and a one-time seed (README).
cat >>"$gen/Taskfile.yml" <<'YAML'

  deploy:
    desc: project-specific task added in the repo
    cmds:
      - echo deploying
YAML
echo "REPO-OWNED README" >>"$gen/README.md"
gitq "$gen" add -A
gitq "$gen" commit -qm customize
before="$(git -C "$gen" rev-list --count HEAD)"

# 4. Ship a template-owned change (a DIFFERENT file, so the merge is clean) as v0.0.2.
printf '\n# update-test marker\n' >>"$tmpl/template/scripts/lint-hygiene.sh"
gitq "$tmpl" add -A
gitq "$tmpl" commit -qm v0.0.2
git -C "$tmpl" tag v0.0.2

# 5. Update the generated repo.
(cd "$gen" && copier update --trust --defaults) >/dev/null 2>&1 || err "copier update failed"

# 6. Assertions.
after="$(git -C "$gen" rev-list --count HEAD)"
[ "$before" = "$after" ] || err "spurious commit on update (before=$before after=$after) — first-run _tasks re-ran"
grep -q 'update-test marker' "$gen/scripts/lint-hygiene.sh" || err "template improvement was not delivered"
grep -q 'project-specific task added in the repo' "$gen/Taskfile.yml" || err "repo's own edit to Taskfile.yml was lost on update"
grep -q 'REPO-OWNED README' "$gen/README.md" || err "README.md (_skip_if_exists) was clobbered"
markers="$(grep -rl '^<<<<<<<' "$gen" 2>/dev/null | grep -v '/\.git/' || true)"
[ -z "$markers" ] || err "conflict markers left in: $markers"
rejs="$(find "$gen" -name '*.rej' -not -path '*/.git/*' || true)"
[ -z "$rejs" ] || err "copier .rej files left: $rejs"

if [ "$fail" -ne 0 ]; then
    echo "test-template-update: FAILED" >&2
    exit 1
fi
echo "test-template-update: PASS"
