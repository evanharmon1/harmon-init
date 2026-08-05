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

# ── 1. Filenames ────────────────────────────────────────────────────────────
# A conditional in a PATH is the strongest form of the gate: copier skips a file
# whose rendered name is empty, so the file simply never appears.
while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "FAIL: ${path}" >&2
    echo "      filename is gated on ${ANSWER} — use use_skills_sync and check for the asset at runtime" >&2
    fail=1
done < <(find template -name "*${ANSWER}*" -print 2>/dev/null || true)

# ── 2. Jinja conditionals under template/ ───────────────────────────────────
# `[% if %]` / `[% elif %]` decide whether a BLOCK renders — same staleness, at
# a finer grain. `[% for %]` is deliberately absent from this pattern: iterating
# the answer to seed a file is the legitimate use.
#
# No grep -P (BSD grep lacks it). `[%` needs no escaping inside a bracket
# expression, and the delimiters are copier's, set by _envops in copier.yml.
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "FAIL: ${hit}" >&2
    fail=1
done < <(grep -rnE "\[%-? *(el)?if [^%]*${ANSWER}" template 2>/dev/null || true)

# ── 3. copier.yml: computed answers that GATE on it ─────────────────────────
# A `default:` derives one answer from another, and a `when:` decides whether a
# question is asked; either one reading `skill_categories` inherits its
# staleness and hands it to whatever the derived answer gates.
#
# The question's OWN block is not an exception that needs allowlisting: its
# `default:` seeds from `project_type` and its `when:` reads `use_skills_sync`,
# so neither line mentions `skill_categories`. If that ever changes, this guard
# firing on it is correct — a self-referential default is its own bug.
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "FAIL: copier.yml:${hit}" >&2
    echo "      a computed answer gated on ${ANSWER} inherits its staleness" >&2
    fail=1
done < <(grep -nE "^[[:space:]]*(default|when):.*${ANSWER}" copier.yml 2>/dev/null || true)

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
