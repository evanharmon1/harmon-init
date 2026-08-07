#!/usr/bin/env bash
# audit-dogfood.sh — REPORT root<->template drift for jinja twins.
#
# `task test:dogfood-parity` byte-compares VERBATIM twins (template files with no
# .jinja suffix). That leaves the jinja twins — AGENTS.md, Taskfile.yml, the
# workflows, docs — completely unchecked, and that is exactly where drift lands:
# you edit template/ to ship a fix to consumers, nothing fails, and the root copy
# silently falls behind.
#
# This renders template/ at HEAD with .dogfood-answers.yml (the answers the root
# layer is maintained against) and diffs each rendered file against its root twin.
#
# It is a REPORT, NOT A GATE, and exits 0 even when it finds differences. The root
# legitimately diverges in prose (harmon-init-specific sections, root-only tooling,
# template/ lint exclusions), so a hard gate here would fail constantly and train
# everyone to ignore it. Read the output; reconcile what is real drift. The
# structural subset that CAN be gated lives in test-dogfood-structure.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# Git hooks export GIT_DIR/GIT_WORK_TREE; left set, copier's `git init` in the
# temp render re-targets THIS repo. Same sanitation as test-template.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Wholly root-owned files: the root copy is not a render of the template copy at
# all, so a diff is 100% noise rather than signal. Keep this list SHORT. Files
# with PARTIAL divergence (AGENTS.md, Taskfile.yml, .gitignore, build.yml, ...)
# are deliberately NOT here — they are where drift actually hides, so they must
# be reported even though their diffs always contain some intentional lines.
SKIP="
CHANGELOG.md
README.md
DESIGN.md
LICENSE
.release-please-manifest.json
.copier-answers.yml
todo.md
.github/CODEOWNERS
.github/SECURITY.md
docs/README.md
docs/CHECKLIST.md
docs/project-management.md
docs/architecture/README.md
docs/architecture/branch-protection.md
docs/architecture/ci-cd.md
docs/architecture/security.md
docs/architecture/tests.md
docs/guides/README.md
docs/guides/bot-account.md
.devcontainer/related-repos.txt
# sync-harmon-devkit root/template twins: root variants are harmon-init-
# specific supersets (twin manifests, repository_dispatch, copier verify);
# the template renders simpler downstream twins (single manifest, schedule-
# only, offline verify) that legitimately differ from root.
.github/workflows/sync-harmon-devkit.yml
scripts/sync-devkit-release.sh
scripts/test-sync-devkit-release.sh
"

have() { command -v "$1" >/dev/null 2>&1; }
if ! have copier; then
    echo "SKIP: copier is not installed — cannot render the template." >&2
    exit 0
fi

dest="$(mktemp -d -t harmon-init-dogfood-XXXXXX)"
trap 'rm -rf "$dest"' EXIT

# --vcs-ref=HEAD is load-bearing: without it copier renders the latest TAG and
# every uncommitted/untagged change is invisible (see AGENTS.md).
copier copy . "$dest" --trust --vcs-ref=HEAD --defaults --quiet \
    --data-file .dogfood-answers.yml \
    --data git_init=false \
    --data github_remote_create=false \
    --data github_release_init=false \
    --data run_task_install=false \
    --data bunch_add=false \
    --data obsidian_project_add=false >/dev/null 2>&1

only_summary=0
[ "${1:-}" = "--summary" ] && only_summary=1

differ=0
same=0
skipped=0
missing=0
report=""

while IFS= read -r rendered; do
    rel="${rendered#"$dest"/}"
    case "
$SKIP
" in *"
$rel
"*)
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    # *.code-workspace is generated once then owned by the consumer; the root
    # gitignores it entirely. Same for the .meta scratch dir.
    case "$rel" in *.code-workspace | .meta/*) skipped=$((skipped + 1)) && continue ;; esac

    if [ ! -e "$rel" ]; then
        missing=$((missing + 1))
        report="${report}
ABSENT AT ROOT  ${rel}"
        continue
    fi
    if diff -q "$rendered" "$rel" >/dev/null 2>&1; then
        same=$((same + 1))
    else
        differ=$((differ + 1))
        n=$(diff -u "$rel" "$rendered" | grep -cE '^[+-][^+-]' || true)
        report="${report}
DIFFERS (${n} lines)  ${rel}"
    fi
done < <(find "$dest" -type f ! -path "$dest/.git/*" | sort)

echo "── dogfood audit (root vs template rendered with .dogfood-answers.yml) ──"
echo "identical: ${same}   differing: ${differ}   absent at root: ${missing}   skipped (root-owned): ${skipped}"
[ -n "$report" ] && printf '%s\n' "$report"

if [ "$only_summary" -eq 0 ] && [ "$differ" -gt 0 ]; then
    echo
    echo "── diffs (left = root, right = rendered template) ──"
    while IFS= read -r line; do
        case "$line" in "DIFFERS "*)
            f="${line##*)  }"
            echo
            echo "═══ $f ═══"
            diff -u "$f" "$dest/$f" || true
            ;;
        esac
    done <<EOF
$report
EOF
fi

echo
echo "Report only — differences here are NOT automatically failures. The root"
echo "layer intentionally diverges (harmon-init-specific content, root-only"
echo "tooling, template/ lint exclusions). Reconcile what is real drift, and"
echo "edit BOTH layers in lockstep (AGENTS.md)."
