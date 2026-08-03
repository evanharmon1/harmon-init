#!/usr/bin/env bash
# test-template-independence.sh — keep generated output free of the maintainer's
# personal dotfiles repo (AGENTS.md, "Hard Rules"; harmon-init#551).
#
# harmon-init, harmon-devkit, and harmon-infra are independent of harmon-dotfiles
# and chezmoi. The permitted coupling is one-way and optional: harmon-dotfiles may
# pull from them at a pinned tag; they never point back. A consumer has no access
# to that repo, so a shipped mention of it is one of three failures — rationale
# they cannot read, a pointer that means nothing to them, or (worst) a claim that
# a personal repo is authoritative for content this template owns.
#
# This is a written invariant made enforceable. Intent that is only remembered
# drifts back: all five references this replaces were added in good faith.
#
# SCOPE IS DELIBERATE. It covers what reaches a consumer: template/, plus the
# consumer-facing text in copier.yml (question help, _message_after_copy, _tasks).
# It does NOT cover the whole repo, because root-only mentions ship to nobody and
# create no dependency — .devcontainer/related-repos.txt, managed-repositories.yml,
# the "related repos" tables, the sibling-repo grants in .claude/settings.json, and
# the Hard Rule's own text all name harmon-dotfiles legitimately. A repo-wide guard
# would fail on the rule that motivates it.
#
# ROOT-ONLY: a generated repo has no template/ and never runs this check.
set -euo pipefail
cd "$(dirname "$0")/.."

# Case-insensitive — a capitalized "Chezmoi" in prose ships just the same. No
# grep -P and no \b: BSD grep has neither, and these tokens need no anchors.
#
# The third alternative catches a hardcoded path into somebody's dotfiles
# CHECKOUT (~/.dotfiles/..., $HOME/.dotfiles/...) — the leak this guard first
# missed: the devcontainer guide named `~/.dotfiles/.functions` long after the
# repo name was gone, so the two names alone reported independence while a
# pointer to the maintainer's layout still shipped.
#
# It is deliberately the PATH and not the word "dotfiles". A generated project
# may legitimately discuss a consumer's own dotfiles, and banning the English
# word would fail on text that breaks no invariant. What must never ship is an
# absolute path into a particular person's dotfiles tree.
PATTERN='harmon-dotfiles|chezmoi|/\.dotfiles'

# What a consumer receives. Read as whole lines throughout: paths under template/
# carry jinja conditionals, so they contain spaces and brackets.
TARGETS="
template
copier.yml
"

fail=0
scanned=0
while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ -e "$target" ] || {
        echo "FAIL: expected scan target is missing: ${target}" >&2
        fail=1
        continue
    }
    scanned=$((scanned + 1))

    # Contents. -I skips binaries, -l prints each offending path once; the
    # follow-up grep shows the lines so the failure is actionable.
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        echo "FAIL: ${file} references harmon-dotfiles, chezmoi, or a personal dotfiles path" >&2
        grep -nEi "$PATTERN" "$file" | sed 's/^/      /' >&2
        fail=1
    done < <(grep -rlIEi "$PATTERN" "$target" 2>/dev/null || true)

    # Paths. Chezmoi machinery is named, not written: an empty .chezmoiignore or
    # .chezmoiexternal.toml has no contents for the scan above to match.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        echo "FAIL: ${path} — chezmoi/dotfiles machinery must not ship to consumers" >&2
        fail=1
    done < <(find "$target" \( -iname '*chezmoi*' -o -iname '*harmon-dotfiles*' \) -print)
done <<EOF
$TARGETS
EOF

if [ "$fail" -ne 0 ]; then
    echo "template independence: generated output must not reference harmon-dotfiles, chezmoi, or a personal dotfiles checkout" >&2
    echo "  state the rationale in harmon-init rather than citing that repo, and drop the name" >&2
    echo "  where it is only a pointer (AGENTS.md, \"Hard Rules\")" >&2
    exit 1
fi
echo "template independence OK: ${scanned} consumer-facing target(s) name no personal dotfiles repo, path, or chezmoi"
