#!/usr/bin/env bash
# test-dogfood-structure.sh — GATE the structural subset of root<->template drift.
#
# The three dogfood checks, in increasing looseness:
#   test-dogfood-parity.sh    byte-equality for VERBATIM twins        (hard gate)
#   this script               structure only, for JINJA twins         (hard gate)
#   audit-dogfood.sh          full diff of jinja twins                (report)
#
# Prose in a jinja twin legitimately differs (the root has harmon-init-specific
# sections and root-only tooling), so full-text equality can never be gated. But
# STRUCTURE can: if the rendered template grows a section or a task, the root copy
# should have gained one too. That catches the commonest drift — "template gained
# X, the root never got it" — which is the direction drift actually travels, since
# you edit template/ to ship a fix to consumers and nothing fails when the root
# copy is forgotten.
#
# Checked:
#   - every `##`..`######` heading in a rendered markdown twin exists in the root twin
#   - every top-level task name in the rendered Taskfile exists in the root Taskfile
#
# NOT checked: anything inside a section or task body. A rewritten task body or a
# changed step still needs `task audit:dogfood` and human eyes.
set -euo pipefail
cd "$(dirname "$0")/.."

# Git hooks export GIT_DIR/GIT_WORK_TREE; left set, copier's `git init` in the
# temp render re-targets THIS repo. Same sanitation as test-template.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Files whose root copy is NOT a render of the template copy — comparing their
# structure is meaningless. Same rationale (and largely the same list) as the
# SKIP block in audit-dogfood.sh.
SKIP_FILES="
CHANGELOG.md
README.md
DESIGN.md
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
"

# Structural elements the root DELIBERATELY does not mirror, as `path|element`.
# Every entry needs a reason. Keep this list short: each one is a place the gate
# has been told to look away.
#   AGENTS.md|## Commands
#       Root titles the section "## Common Commands" (it documents copier and the
#       template-render tasks, which no generated repo has).
#   AGENTS.md|## Definition of Done
#       Root folds these rules into "## Development Workflow", alongside the
#       two-layer rules (release-title guard, dogfood parity) that only apply here.
#   Taskfile.yml|validate
#       The template ships a placeholder echo. harmon-init's real validation is
#       the test:template render matrix, so a stub claiming "no validate steps"
#       would be actively wrong. See PR #378.
#   todo.md|<absent>
#       Per-project scratch file. The root gitignores it (`/todo.md`), so the
#       root layer having no copy is correct. `<absent>` is the sentinel for
#       "this rendered file is allowed to have no root twin at all".
ALLOW="
AGENTS.md|## Commands
AGENTS.md|## Definition of Done
Taskfile.yml|validate
todo.md|<absent>
"

have() { command -v "$1" >/dev/null 2>&1; }
if ! have copier; then
    # In CI a missing tool must FAIL, never skip: this is a gate, and a silent
    # skip reports green while checking nothing. Same rule as test-template.sh.
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "FAIL: copier is required in CI — the workflow must install it before this step." >&2
        exit 1
    fi
    echo "SKIP: copier is not installed — cannot render the template."
    exit 0
fi

dest="$(mktemp -d -t harmon-init-structure-XXXXXX)"
trap 'rm -rf "$dest"' EXIT

# --vcs-ref=HEAD is load-bearing: without it copier renders the latest TAG.
copier copy . "$dest" --trust --vcs-ref=HEAD --defaults --quiet \
    --data-file .dogfood-answers.yml \
    --data git_init=false \
    --data github_remote_create=false \
    --data github_release_init=false \
    --data run_task_install=false \
    --data bunch_add=false \
    --data obsidian_project_add=false >/dev/null 2>&1

allowed() {
    case "
$ALLOW
" in *"
$1|$2
"*) return 0 ;; esac
    return 1
}

fail=0
checked=0

# ── markdown headings ────────────────────────────────────────────────
while IFS= read -r rel; do
    # CLAUDE.md / GEMINI.md / copilot-instructions.md are symlinks to AGENTS.md;
    # checking them just reports every AGENTS.md finding four times. Tested
    # before the existence check below, since a symlink whose target is present
    # is not a missing file.
    [ -L "$rel" ] && continue
    case "
$SKIP_FILES
" in *"
$rel
"*) continue ;; esac

    # A rendered doc with NO root copy is the WORST case, not a skippable one:
    # the template gained a whole dogfooded file and the root never got it. An
    # early `continue` here would report green over exactly the drift this gate
    # exists to catch.
    if [ ! -e "$rel" ]; then
        checked=$((checked + 1))
        if ! allowed "$rel" "<absent>"; then
            echo "FAIL: ${rel} is rendered by the template but does not exist in the root layer" >&2
            fail=1
        fi
        continue
    fi

    while IFS= read -r heading; do
        [ -n "$heading" ] || continue
        checked=$((checked + 1))
        if ! grep -qxF "$heading" "$rel"; then
            allowed "$rel" "$heading" && continue
            echo "FAIL: ${rel} is missing a section the rendered template has: '${heading}'" >&2
            fail=1
        fi
    done < <(grep -E '^#{2,6} ' "$dest/$rel" 2>/dev/null || true)
done < <(cd "$dest" && find . -name '*.md' ! -path './.git/*' | sed 's|^\./||' | sort)

# ── Taskfile task names ──────────────────────────────────────────────
if [ -f "$dest/Taskfile.yml" ] && [ -f Taskfile.yml ]; then
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        checked=$((checked + 1))
        if ! grep -qE "^  ${task}:" Taskfile.yml; then
            allowed "Taskfile.yml" "$task" && continue
            echo "FAIL: Taskfile.yml is missing a task the rendered template has: '${task}'" >&2
            fail=1
        fi
    done < <(sed -nE 's/^  ([a-z][a-z0-9:_-]*):$/\1/p' "$dest/Taskfile.yml" | sort -u)
fi

if [ "$fail" -ne 0 ]; then
    echo "dogfood structure: the root layer is missing structure the template ships." >&2
    echo "Edit both layers in lockstep (AGENTS.md). If the omission is deliberate," >&2
    echo "add it to ALLOW in scripts/test-dogfood-structure.sh WITH a reason." >&2
    echo "Run 'task audit:dogfood' to see the full root<->template diff." >&2
    exit 1
fi
echo "dogfood structure OK: ${checked} rendered sections/tasks all present in the root layer"
