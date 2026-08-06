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

# ── 2. Mention-lines under template/ must match EXPECTED exactly ────────────
# PIN THE LINES, DO NOT JUDGE THEM — and that choice was made the expensive
# way. Five earlier revisions each tried to decide whether a given occurrence
# was acceptable, and review defeated every one with something it had not
# modelled: a denylist of Jinja forms (beaten by a wrapped conditional, then
# `[%+ if`, then `[% if(...)`), a per-line allowlist (beaten by a lookalike
# path, then by a gate appended to an approved line), and a mention count
# (beaten by trading one approved mention for another).
#
# The common thread is the question itself. "Is this occurrence close enough to
# an approved one?" has an endless supply of edge cases, and every answer that
# is not exhaustive reports success over the cases it missed — worse than not
# checking, because `verify` going green then means less than it did.
#
# EXPECTED is the complete, byte-for-byte list of lines that may mention the
# answer, grouped by the file they live in. Not patterns, not counts — the
# literal lines. A file's mention-lines must equal its block exactly, in order.
#
# This replaces four earlier mechanisms (a per-line allowlist, literal
# subtraction of approved text, a per-file mention cap, and a separate
# exact-block pin for the seed loop), each of which was defeated in review by
# something the previous one did not model: a lookalike path, a gate appended
# to an approved line, a duplicated approved line, and finally trading one
# approved mention for another so the totals still matched. Every one of those
# is a way of asking "is this occurrence close enough to an approved one?" —
# a question with an endless supply of edge cases.
#
# Comparing the whole set removes the question. Adding a mention, removing one,
# editing one, reordering them, or swapping one for another all change the set,
# so all of them fail without anything here having to anticipate them.
#
# Editing these files deliberately costs one edit to EXPECTED, which is the
# point: these lines are the entire licensed use of the answer in template
# content, and a change to them deserves the review that updating this forces.
#
# Two consequences worth stating, because they are features and not oversights:
#   - Reformatting an approved line fails until EXPECTED is updated. Whitespace
#     included; the comparison is byte-exact.
#   - A file with NO mentions and no EXPECTED block is fine — it is check 2's
#     job to reject unapproved mentions, and it does that by finding any file
#     whose mention-lines are not empty and not in EXPECTED.
EXPECTED_SEED_FILE='template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja'
EXPECTED_SEED='# harmon-devkit, pinned to a tag. Categories came from the skill_categories
[% for cat in skill_categories %]'

EXPECTED_CHECKLIST_FILE='template/docs/CHECKLIST.md.jinja'
EXPECTED_CHECKLIST='      skill categories this repo gets (from your `skill_categories` answer). Set'

# expected_for PATH — echo the approved mention-lines for PATH, or nothing.
expected_for() {
    case "$1" in
    "$EXPECTED_SEED_FILE") printf '%s\n' "$EXPECTED_SEED" ;;
    "$EXPECTED_CHECKLIST_FILE") printf '%s\n' "$EXPECTED_CHECKLIST" ;;
    *) : ;;
    esac
}

# Every file under template/ that mentions the answer at all must match its
# expected block exactly. Files with no expected block must have no mentions.
while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    _actual=$(grep "${ANSWER}" "$tf" 2>/dev/null) || continue
    _want=$(expected_for "$tf")
    [ "$_actual" = "$_want" ] && continue
    echo "FAIL: ${tf}" >&2
    if [ -z "$_want" ]; then
        echo "      mentions ${ANSWER}, which no template file may do unless its" >&2
        echo "      exact lines are listed in EXPECTED (scripts/test-category-gates.sh):" >&2
    else
        echo "      its ${ANSWER} lines do not match EXPECTED exactly." >&2
        echo "      expected:" >&2
        printf '%s\n' "$_want" | sed 's/^/        /' >&2
        echo "      found:" >&2
    fi
    printf '%s\n' "$_actual" | sed 's/^/        /' >&2
    fail=1
done < <(find template -type f -print 2>/dev/null || true)

# ── 2b. The seed loop's BODY must be exactly the known block ────────────────
# Check 2 pins the lines that MENTION the answer, which cannot see the lines
# that do not. `[% for cat in skill_categories %]` binds the answer to a loop
# variable, so a conditional in the body gates on it while naming only `cat`:
#
#   [% for cat in skill_categories %]   <- pinned by check 2
#   [% if cat == 'universal' %]         <- no `skill_categories`, invisible there
#     - [[ cat ]]
#   [% endif %]
#   [% endfor %]
#
# So the whole three-line block is pinned too. Both checks are load-bearing and
# neither subsumes the other: check 2 catches changes to the mention-lines
# themselves (edits, duplicates, removals, trades), this catches changes around
# them. Dropping this one while rewriting check 2 silently reintroduced the
# body-conditional hole, which the attack matrix caught before it shipped.
SEED_BLOCK='[% for cat in skill_categories %]
  - [[ cat ]]
[% endfor %]'

if [ -f "$EXPECTED_SEED_FILE" ]; then
    # Flattened and compared with a quoted `case` — a literal substring test.
    # NOT `grep -F`: it reads newlines in the PATTERN as pattern separators, so
    # a multi-line -F pattern means "any ONE of these lines" and matches a
    # tampered block as happily as the real one. That version of this check was
    # silently inert against every attack below.
    _seed_actual=$(tr '\n' '\001' <"$EXPECTED_SEED_FILE")
    _seed_want=$(printf '%s' "$SEED_BLOCK" | tr '\n' '\001')
    case "$_seed_actual" in
    *"$_seed_want"*) : ;;
    *)
        echo "FAIL: ${EXPECTED_SEED_FILE}" >&2
        echo "      the ${ANSWER} seed loop is not the exact expected block:" >&2
        printf '%s\n' "$SEED_BLOCK" | sed 's/^/        /' >&2
        echo "      anything else inside it can gate output on the stale answer." >&2
        echo "      If reformatted deliberately, update SEED_BLOCK to match." >&2
        fail=1
        ;;
    esac
fi

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
