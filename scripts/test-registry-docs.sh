#!/usr/bin/env bash
# test-registry-docs.sh — GATE the human-facing agent-registry tables in
# docs/project-management.md against the machine-readable registry.
#
# ADR 0005 D10 makes that document the human authority for the agent
# vocabulary, and D11 says the registry has executable teeth. A markdown table
# maintained by hand satisfies neither: it drifts the moment a family or
# harness is added, and nothing fails. So the tables are GENERATED —
# `node scripts/agent-registry-labels.mjs docs-tables` — and pasted between
# markers, and this check regenerates them and fails on any difference.
#
#   <!-- registry-tables:begin -->
#   ...generated tables...
#   <!-- registry-tables:end -->
#
# Checked in BOTH layers when both are present: the root/generated
# docs/project-management.md, and — in the template repository only — the
# jinja twin that ships it. The twin is deliberately covered here rather than
# by the dogfood checks: test-dogfood-parity.sh skips it (it is a .jinja file)
# and test-dogfood-structure.sh SKIPs docs/project-management.md outright
# (its root copy is not a render of the template copy), so without this the
# generated tables could ship stale to every consumer while the root copy
# stayed current. The registry itself is a verbatim twin, so the two layers
# render byte-identical tables and one expected value serves both.
#
# The document is generated only for `project_management: github`; a profile
# without it is skipped loudly rather than failed.
#
# To fix a failure: regenerate and paste the block, keeping the markers.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

registry="${1:-agent-registry.json}"
renderer="scripts/agent-registry-labels.mjs"
doc="docs/project-management.md"
begin='<!-- registry-tables:begin -->'
end='<!-- registry-tables:end -->'

for required in "$registry" "$renderer"; do
    [ -f "$required" ] || {
        echo "TEST FAIL: missing required registry asset: $required" >&2
        exit 1
    }
done
command -v node >/dev/null 2>&1 || {
    echo "TEST FAIL: node is required to render the registry documentation tables" >&2
    exit 1
}

expected="$(node "$renderer" docs-tables "$registry")"

# `docs/project-management.md` is the GitHub Projects document — but a repository
# generated for a different tracker renders a DIFFERENT document at the same
# path (the Linear one), which carries no GitHub label taxonomy and no registry
# tables. Read the answer Copier used to pick the file rather than sniffing its
# prose; a template repository has no answers file of its own, so it falls
# through and both layers below are checked.
for candidate in .copier-answers.yml .copier-answers.yaml; do
    [ -f "$candidate" ] || continue
    tracker="$(sed -n 's/^project_management:[[:space:]]*//p' "$candidate" |
        tr -d "\"'" | head -n1)"
    if [ -n "$tracker" ] && [ "$tracker" != "github" ]; then
        echo "note: project_management=$tracker — $doc is not the GitHub Projects document; skipping it" >&2
        doc=""
    fi
    break
done

# The files that MUST carry the generated block. The template twin is matched
# on the `github` in its jinja-conditional filename so the `linear` variant is
# not swept in either.
targets=""
if [ -n "$doc" ] && [ -f "$doc" ]; then
    targets="$doc
"
fi
for twin in template/docs/*project-management.md*.jinja; do
    [ -f "$twin" ] || continue
    case "$twin" in
    *github*)
        targets="$targets$twin
"
        ;;
    esac
done

if [ -z "$targets" ]; then
    echo "note: no project-management document in this profile — skipping the registry documentation check" >&2
    echo "test-registry-docs: nothing to check."
    exit 0
fi

fails=0
checked=0
while IFS= read -r target; do
    [ -n "$target" ] || continue
    checked=$((checked + 1))

    # Exactly one marker pair. Zero means the block was dropped (or never
    # added); more than one means an ambiguous region this check cannot
    # regenerate deterministically.
    begins="$(grep -cxF "$begin" "$target" || true)"
    ends="$(grep -cxF "$end" "$target" || true)"
    if [ "$begins" != 1 ] || [ "$ends" != 1 ]; then
        echo "FAIL: $target must contain exactly one '$begin' line and one '$end' line (found $begins and $ends)" >&2
        fails=$((fails + 1))
        continue
    fi

    actual="$(awk -v b="$begin" -v e="$end" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0 }
        inside' "$target")"

    if [ "$actual" != "$expected" ]; then
        echo "FAIL: the registry tables in $target do not match agent-registry.json:" >&2
        diff -u <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") >&2 || true
        fails=$((fails + 1))
    fi
done <<EOF
$targets
EOF

if [ "$fails" -ne 0 ]; then
    echo "test-registry-docs: $fails document(s) drifted from agent-registry.json." >&2
    echo "Regenerate with: node $renderer docs-tables $registry" >&2
    echo "and replace the lines between the markers, in every layer that carries them." >&2
    exit 1
fi

echo "test-registry-docs: registry tables in $checked document(s) match agent-registry.json."
