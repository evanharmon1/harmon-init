#!/usr/bin/env bash
# test-template-update.sh — verify `copier update` on a generated repo is safe.
#
# Asserts that, going from one template version to the next:
#   - template improvements are delivered (incl. a NEW README section merging in),
#   - a repo's own edits to a template file survive (three-way merge), so repos
#     can be customized normally without an extension-file dance,
#   - _skip_if_exists files (CHANGELOG.md, release-please-owned) are NOT merged,
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

# 1. Tagged old template source from the last release before use_coderabbit.
#    Keep this fixed migration fixture: a moving merge base would stop
#    representing legacy answers as soon as this change lands on main.
mkdir -p "$tmpl"
legacy_ref=v4.4.0
legacy_commit=617a309bdf1743cb3e258eaf75deae234178a52d
if git -C "$repo_root" rev-parse --verify --quiet "$legacy_ref^{commit}" >/dev/null; then
    legacy_source="$legacy_ref"
elif git -C "$repo_root" rev-parse --verify --quiet "$legacy_commit^{commit}" >/dev/null; then
    legacy_source="$legacy_commit"
else
    echo "FAIL: legacy migration fixture $legacy_ref ($legacy_commit) is unavailable" >&2
    exit 1
fi
git -C "$repo_root" archive --format=tar --output="$work/main.tar" "$legacy_source"
tar -xf "$work/main.tar" -C "$tmpl"
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
    --data bunch_add=false --data obsidian_project_add=false >"$work/copy.log" 2>&1 ||
    {
        echo "FAIL: copier copy failed — output follows" >&2
        cat "$work/copy.log" >&2
        exit 1
    }
[ -f "$gen/.coderabbit.yaml" ] || {
    echo "FAIL: use_coderabbit=true did not render .coderabbit.yaml" >&2
    exit 1
}
! grep -q '^use_coderabbit:' "$gen/.copier-answers.yml" || {
    echo "FAIL: legacy answers unexpectedly contain use_coderabbit" >&2
    exit 1
}
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
echo "- repo-owned changelog entry" >>"$gen/CHANGELOG.md"
gitq "$gen" add -A
gitq "$gen" commit -qm customize
before="$(git -C "$gen" rev-list --count HEAD)"

# 4. Replace the source with the current working tree and ship it as v0.0.2.
#    devcontainer.env is local-only; __pycache__/.foreman are runtime artifacts.
#    Then improve a template-owned file, ADD a README section (should flow in
#    via three-way merge — README is NOT skip_if_exists), and change CHANGELOG
#    (must NOT flow — it is _skip_if_exists).
rsync -a --delete \
    --exclude=.git --exclude=.task --exclude=.venv --exclude=node_modules \
    --exclude=.worktrees --exclude=dist --exclude=__pycache__ \
    --exclude=.foreman --exclude=devcontainer.env "$repo_root/" "$tmpl/"
printf '\n# update-test marker\n' >>"$tmpl/template/scripts/lint-hygiene.sh"
printf '\n## Template Added Section\n\nnew template content\n' >>"$tmpl/template/README.md.jinja"
printf '\ntemplate-changed-changelog\n' >>"$tmpl/template/CHANGELOG.md.jinja"
gitq "$tmpl" add -A
gitq "$tmpl" commit -qm v0.0.2
git -C "$tmpl" tag v0.0.2

# 5. Update the generated repo.
# Keep copier's own output: when this fails in CI, "copier update failed" alone
# is not enough to diagnose it, and the failure is not always reproducible
# locally (copier version, git config, and checkout differences all matter).
if ! (cd "$gen" && copier update --trust --defaults) >"$work/update.log" 2>&1; then
    err "copier update failed — output follows"
    sed 's/^/    /' "$work/update.log" >&2
fi

# 6. Assertions.
after="$(git -C "$gen" rev-list --count HEAD)"
[ "$before" = "$after" ] || err "spurious commit on update (before=$before after=$after) — first-run _tasks re-ran"
grep -q 'update-test marker' "$gen/scripts/lint-hygiene.sh" || err "template improvement to a template-owned file was not delivered"
grep -q 'project-specific task added in the repo' "$gen/Taskfile.yml" || err "repo's own edit to Taskfile.yml was lost on update"
grep -q 'Template Added Section' "$gen/README.md" || err "new template README section did not merge into the repo"
grep -q 'repo-owned changelog entry' "$gen/CHANGELOG.md" || err "CHANGELOG.md lost the repo's content"
grep -q 'template-changed-changelog' "$gen/CHANGELOG.md" && err "CHANGELOG.md received a template change despite _skip_if_exists"
[ ! -f "$gen/.coderabbit.yaml" ] || err ".coderabbit.yaml remained after use_coderabbit=false update"
! grep -Fq 'Install the [CodeRabbit app]' "$gen/docs/CHECKLIST.md" ||
    err "CHECKLIST retained CodeRabbit setup after use_coderabbit=false update"
grep -Fq 'Confirm CodeRabbit has no access' "$gen/docs/CHECKLIST.md" ||
    err "CHECKLIST omitted CodeRabbit App-access confirmation after opt-out"
! grep -Fq 'coderabbitai[bot]' "$gen/.github/workflows/claude-review.yml" ||
    err "Claude review retained CodeRabbit trust after use_coderabbit=false update"
markers="$(grep -rl '^<<<<<<<' "$gen" 2>/dev/null | grep -v '/\.git/' || true)"
[ -z "$markers" ] || err "conflict markers left in: $markers"
rejs="$(find "$gen" -name '*.rej' -not -path '*/.git/*' || true)"
[ -z "$rejs" ] || err "copier .rej files left: $rejs"

if [ "$fail" -ne 0 ]; then
    echo "test-template-update: FAILED" >&2
    exit 1
fi
echo "test-template-update: PASS"
