#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d -t agent-skill-links-XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"

mkdir -p .claude/skills/shared .claude/skills/local .agents/skills/native
printf '%s\n' shared >.claude/skills/shared/SKILL.md
printf '%s\n' local >.claude/skills/local/SKILL.md
printf '%s\n' native >.agents/skills/native/SKILL.md

"$repo_root/scripts/link-agent-skills.sh" sync
[ "$(readlink .agents/skills/shared)" = "../../.claude/skills/shared" ]
[ "$(readlink .agents/skills/local)" = "../../.claude/skills/local" ]
[ -f .agents/skills/native/SKILL.md ]
"$repo_root/scripts/link-agent-skills.sh" verify

rm -rf .claude/skills/shared
if "$repo_root/scripts/link-agent-skills.sh" verify >/dev/null 2>&1; then
    echo "test-agent-skill-links: verify accepted a stale compatibility link" >&2
    exit 1
fi
"$repo_root/scripts/link-agent-skills.sh" sync
[ ! -e .agents/skills/shared ] && [ ! -L .agents/skills/shared ]

mkdir -p .claude/skills/native
printf '%s\n' claude >.claude/skills/native/SKILL.md
if "$repo_root/scripts/link-agent-skills.sh" sync >/dev/null 2>&1; then
    echo "test-agent-skill-links: accepted divergent same-name skills" >&2
    exit 1
fi
[ ! -L .agents/skills/native ]
[ "$(cat .agents/skills/native/SKILL.md)" = native ]

# A tool-managed skill declared in .link-ignore (same name in both trees, with
# deliberately divergent content) is left alone: sync succeeds, the portable
# dir is untouched, and no compatibility link is created for it.
printf '%s\n' '# codex-target variants owned by another tool' >.agents/skills/.link-ignore
printf '%s\n' native >>.agents/skills/.link-ignore
"$repo_root/scripts/link-agent-skills.sh" sync
[ ! -L .agents/skills/native ]
[ "$(cat .agents/skills/native/SKILL.md)" = native ]
[ "$(cat .claude/skills/native/SKILL.md)" = claude ]
"$repo_root/scripts/link-agent-skills.sh" verify

# An UNdeclared divergent skill still refuses — the ignore list is opt-in and
# never a blanket "accept any same-name dir".
mkdir -p .claude/skills/other .agents/skills/other
printf '%s\n' claude >.claude/skills/other/SKILL.md
printf '%s\n' native >.agents/skills/other/SKILL.md
if "$repo_root/scripts/link-agent-skills.sh" sync >/dev/null 2>&1; then
    echo "test-agent-skill-links: accepted an undeclared divergent skill" >&2
    exit 1
fi
[ "$(cat .agents/skills/other/SKILL.md)" = native ]

# The env-var form declares the same way; the file and the env var compose.
AGENT_SKILLS_LINK_IGNORE=other "$repo_root/scripts/link-agent-skills.sh" sync
[ ! -L .agents/skills/other ]
[ "$(cat .agents/skills/other/SKILL.md)" = native ]

echo "test-agent-skill-links: PASS"
