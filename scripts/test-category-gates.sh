#!/usr/bin/env bash
# test-category-gates.sh — no template file may be GATED on `skill_categories`
# (harmon-init#622; the instance that motivated it is #483 / PR #621).
#
# THE TRAP. `skill_categories` is recorded in `.copier-answers.yml` at scaffold
# time, but the documented way to change categories afterwards is to edit
# `.skills-sync.yaml` — said by the question's own help text ("edit later in
# .skills-sync.yaml") and by the generated manifest's header ("edit them
# freely"). That edit does NOT update the recorded answer, and copier's update
# is a three-way merge of the TEMPLATE's diff, so the consumer's manifest edit
# survives while the answer stays stale forever.
#
# The manifest is what `task sync:skills` reads, so the SKILLS vendor correctly.
# Only a template file gated on the ANSWER breaks — and it breaks silently and
# permanently: the file never renders, on this update or any future one, in a
# repo whose skills say it should.
#
# That is not hypothetical. `claim_release_available` was written as
# `use_skills_sync and 'universal' in skill_categories`, which would have left a
# repo that added `universal` the documented way vendoring the claim-writing
# skills with no claim-release workflow to release their markers — the exact
# stranding that workflow exists to prevent, reintroduced through its own gate.
#
# THE CONVENTION. Gate on `use_skills_sync` — whether the repo vendors skills at
# all, which is a real answer that cannot drift — and let the shipped file check
# at RUNTIME for the specific asset it needs. `claim-release.yml` is the worked
# example: it renders whenever skills sync is on and exits 0 with a notice when
# `release-claim.sh` is absent.
#
# WHAT IS BANNED is conditional use, not every mention. Iterating the answer to
# SEED a file is correct and is the whole point of the question — that is how
# `.skills-sync.yaml` gets its category list. Prose that names the answer is
# fine. What must not exist is a decision about whether a file or a block
# RENDERS, made from a value that goes stale.
#
# ROOT-ONLY: a generated repo has no template/ and never runs this check.
set -euo pipefail
cd "$(dirname "$0")/.."

ANSWER='skill_categories'
fail=0

# A missing scan target means the checks below quietly examine nothing. Same
# precedent as test-template-independence.sh, which fails on an absent target
# rather than reporting the invariant held over an empty search.
[ -d template ] || {
    echo "FAIL: template/ is missing — nothing was scanned" >&2
    exit 1
}

# ── 1. Filenames ────────────────────────────────────────────────────────────
# A conditional in a PATH is the strongest form of the gate: copier skips a file
# whose rendered name is empty, so the file simply never appears.
while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "FAIL: ${path}" >&2
    echo "      filename is gated on ${ANSWER} — use use_skills_sync and check for the asset at runtime" >&2
    fail=1
done < <(find template -name "*${ANSWER}*" -print 2>/dev/null || true)

# ── 2. Every mention under template/, minus an allowlist ────────────────────
# ALLOWLIST, NOT A PATTERN LIST — and that choice was made the expensive way.
# An earlier revision enumerated the banned FORMS and was evaded three times in
# three review rounds, each by ordinary Jinja an author would plausibly write:
#
#   [% if use_skills_sync
#      and 'universal' in skill_categories %]      wrapped across lines
#   [%+ if 'universal' in skill_categories %]      whitespace-control modifier
#   [% if('universal' in skill_categories) %]      parenthesised expression
#
# Each was fixed, and the next round found another. That is the shape of the
# problem, not bad luck: Jinja's grammar is open-ended, so an enumeration of
# what is forbidden can only ever be as complete as the last person's
# imagination — and it reports success over everything it failed to imagine,
# which is worse than not checking at all.
#
# So the polarity is inverted. EVERY occurrence of the answer under template/
# fails unless it is listed below with a reason. New legitimate uses cost one
# allowlist line; new evasions cost nothing, because there is nothing left to
# evade. Same "intentional divergences are allowlisted, WITH REASONS" pattern
# as scripts/audit-dogfood.sh and scripts/test-dogfood-structure.sh.
#
# Entries are `path|substring`, matched literally (grep -F) against the whole
# line — never a regex, so a metacharacter in an entry cannot silently widen
# it. Keep them narrow enough to be about the specific legitimate use: a
# too-broad entry re-opens the hole this design closes.
#
#   .skills-sync.yaml…jinja|[% for cat in skill_categories %]
#       Seeds the manifest's category list from the answer. This is the whole
#       purpose of the question, and it is ITERATION, not a gate: it decides
#       the file's CONTENTS, never whether the file renders. A consumer then
#       owns that list — which is precisely the drift the guard exists for.
#   .skills-sync.yaml…jinja|Categories came from the skill_categories
#       Header prose telling the consumer where the list came from.
#   CHECKLIST.md.jinja|from your `skill_categories` answer
#       Consumer-facing prose explaining the answer.
ALLOWLIST="
.skills-sync.yaml[% endif %].jinja|[% for cat in skill_categories %]
.skills-sync.yaml[% endif %].jinja|Categories came from the skill_categories
docs/CHECKLIST.md.jinja|from your \`skill_categories\` answer
"

# allowed PATH LINE — true only when NOTHING on the line is unaccounted for.
#
# It works by SUBTRACTION, not by matching. Each applicable entry removes one
# occurrence of its approved text from a working copy of the line; the line is
# allowed only if no `skill_categories` survives that. An earlier version
# returned true on the first entry that matched anywhere in the line, which
# accepted the whole line on the strength of its approved part — appending
# `[[ 'bad' if 'universal' in skill_categories else 'ok' ]]` to the allowlisted
# header passed the guard. Approving the prose on a line must not approve
# whatever else shares that line.
allowed() {
    _a_residue=$2
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        _a_path=${entry%%|*}
        _a_text=${entry#*|}
        case "$1" in
        *"$_a_path"*) ;;
        *) continue ;;
        esac
        # Strip ONE occurrence. Quoting inside the expansion keeps the text
        # literal, so a glob character in an entry cannot widen the match.
        case "$_a_residue" in
        *"$_a_text"*)
            _a_residue="${_a_residue%%"$_a_text"*}${_a_residue#*"$_a_text"}"
            ;;
        esac
    done <<EOF
${ALLOWLIST}
EOF
    # Anything left is unapproved.
    case "$_a_residue" in
    *"$ANSWER"*) return 1 ;;
    esac
    return 0
}

while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    # grep -n output: path:line:text — path may contain ':'? No: copier's
    # jinja names use [% %] and spaces, never a colon, so the first two
    # fields split cleanly.
    hit_path=${hit%%:*}
    hit_rest=${hit#*:}
    hit_line=${hit_rest%%:*}
    hit_text=${hit_rest#*:}
    if allowed "$hit_path" "$hit_text"; then
        continue
    fi
    echo "FAIL: ${hit_path}:${hit_line}" >&2
    echo "      ${hit_text}" >&2
    echo "      mentions ${ANSWER}; if this is a legitimate seed/prose use, add it" >&2
    echo "      to ALLOWLIST in scripts/test-category-gates.sh WITH a reason" >&2
    fail=1
done < <(grep -rn "${ANSWER}" template 2>/dev/null || true)

# ── 3. copier.yml: computed answers that GATE on it ─────────────────────────
# A `default:` derives one answer from another, and a `when:` decides whether a
# question is asked; either one reading `skill_categories` inherits its
# staleness and hands it to whatever the derived answer gates.
#
# Parsed with yq rather than grepped, because a folded scalar hides the answer
# from any line-based match — also verified: a `default: >-` wrapping before
# `and 'universal' in skill_categories` passed a grepped version of this check,
# while yq reports the joined value exactly. yq is already a hard dependency
# (Brewfile, and build.yml installs it), so requiring it here adds nothing; a
# MISSING yq is a hard failure rather than a skip, since a guard that silently
# stops guarding is worse than no guard.
#
# The question's OWN block needs no allowlist entry: its `default:` seeds from
# `project_type` and its `when:` reads `use_skills_sync`, so neither value
# mentions `skill_categories`. If that ever changes, firing on it is correct —
# a self-referential default is its own bug.
if ! command -v yq >/dev/null 2>&1; then
    echo "FAIL: yq is required to inspect copier.yml answers (brew bundle / see Brewfile)" >&2
    exit 1
fi

# A FAILED yq must not read as "no gates found". yq being present does not mean
# it is the right yq — build.yml already warns that `pip install yq` is a
# different tool (a jq wrapper) — and the wrong one exits non-zero on this
# expression. Swallowing that with `|| true` would leave the whole
# computed-answer check silently disabled while the guard printed OK, which is
# the exact failure this guard exists to prevent, one level up. Capture first,
# fail loudly, and only then iterate.
if ! answer_gates="$(yq -r "
    to_entries
    | map(select(.value | type == \"!!map\"))
    | map(select(
        ((.value.default // \"\") | tostring | contains(\"${ANSWER}\"))
        or ((.value.when // \"\") | tostring | contains(\"${ANSWER}\"))
      ))
    | .[]
    | .key + \": \" + ((.value.default // .value.when) | tostring)
" copier.yml 2>&1)"; then
    echo "FAIL: yq could not parse copier.yml — the computed-answer check did NOT run" >&2
    printf '      %s\n' "$answer_gates" >&2
    echo "      needs mikefarah/yq; 'pip install yq' is a different tool (a jq wrapper)" >&2
    exit 1
fi

while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "FAIL: copier.yml: ${hit}" >&2
    echo "      a computed answer gated on ${ANSWER} inherits its staleness" >&2
    fail=1
done <<EOF
${answer_gates}
EOF

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'MSG'

category gates: no template file may render conditionally on `skill_categories`.

  The answer is recorded at scaffold time and never updated when a consumer
  edits `.skills-sync.yaml` — the documented way to change categories — so a
  gate on it is permanently wrong for exactly the repos it is meant to serve.

  Instead: gate on `use_skills_sync`, and have the shipped file check for the
  asset it needs at runtime. See `.github/workflows/claim-release.yml` for the
  worked example, docs/conventions.md for the rule, and #622 for the analysis.
MSG
    exit 1
fi

echo "category gates OK: no filename, jinja conditional, or computed answer gates on ${ANSWER}"
