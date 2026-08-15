#!/usr/bin/env bash
# test-dogfood-parity.sh — guard the root ↔ template dogfood for VERBATIM twins.
#
# Template files without a .jinja suffix are copied into generated repos byte-
# for-byte, so the root dogfood copy of each must be identical to the template
# copy. A fix applied to only one side ships stale content downstream (or stops
# dogfooding it) — and `task test:template` cannot catch that, because it
# validates the rendered template against itself, not against the root copy.
# Jinja-templated files are exempt (the root copy is a render, not a copy);
# ALLOW_DIVERGE lists intentional root-only divergences.
set -euo pipefail
cd "$(dirname "$0")/.."

# Intentional root-only divergences (the template copy is what consumers get):
#   .yamllint — root adds the template/ exclusion (jinja YAML is not valid YAML
#               until rendered) and trims artifact dirs harmon-init never makes.
#   .devcontainer/related-repos.txt — harmon-init's curated sibling-repo list;
#               generated repositories begin with an empty, consumer-owned list.
#   label-registry.json — the root manifest carries harmon-init's own
#               vocabulary (the area:* subsystems and the tier:*/method:*
#               strategy families seeded on this repo); the template twin
#               ships the generic starter set. test-label-registry.sh gates
#               BOTH layers against their own reviewed lockfiles, so the
#               divergence is checked, just not byte-checked.
#   (.claude/settings.json is a jinja twin now — root additionally grants the
#   sibling-repo read permissions/sandbox dirs, reconciled by hand.)
ALLOW_DIVERGE=".yamllint .devcontainer/related-repos.txt label-registry.json scripts/sync-devkit-release.sh scripts/test-sync-devkit-release.sh"

fail=0
checked=0
while IFS= read -r tfile; do
    # Map the template path to its root twin: strip jinja conditionals from
    # path segments ("[% if … %]name[% endif %]" -> "name").
    rel=$(printf '%s' "${tfile#template/}" | sed -E 's/\[% if [^%]*%\]//g; s/\[% endif %\]//g')
    case " ${ALLOW_DIVERGE} " in *" ${rel} "*) continue ;; esac
    # Root does not dogfood every profile's files (e.g. python/node-only ones).
    [ -f "$rel" ] || continue
    checked=$((checked + 1))
    if ! diff -q "$tfile" "$rel" >/dev/null; then
        echo "FAIL: ${rel} differs from its verbatim template twin (${tfile})" >&2
        fail=1
    fi
done < <(find template -type f ! -name '*.jinja')

if [ "$fail" -ne 0 ]; then
    echo "dogfood parity: divergent verbatim twins — edit both copies in lockstep (see AGENTS.md)" >&2
    exit 1
fi
echo "dogfood parity OK: ${checked} verbatim root<->template twins are identical"
