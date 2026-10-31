#!/usr/bin/env bash
# codex-review.sh — second-model review of the current change via the OpenAI
# Codex CLI (`codex exec review`). Two modes:
#
#   review    — verification checkpoint: double-check the implementation,
#               consistency with repo conventions, and test coverage.
#   challenge — adversarial review: actively try to break the change
#               (architecture, authz, data loss, rollback, races, hidden
#               coupling, operational failure modes, overdesign).
#
# Usage: codex-review.sh <review|challenge> [--repo-root <path>] [--profile standardize --release <release> --frozen-render <bundle>] [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# Target selection when no explicit flag is given: whatever exists is in
# scope. Commits beyond the default base AND a dirty working tree are reviewed
# together as one change; either alone is reviewed on its own. The explicit
# flags stay narrow on purpose — --base is committed history only, and
# --uncommitted is the worktree only — so they remain escapes you opt into.
# The CLI's --base/--uncommitted/--commit flags are mutually exclusive with
# custom instructions ("custom review instructions" is its own review mode),
# so the resolved scope is written INTO the instructions instead.
# Codex reviews read-only; findings are advisory hypotheses for the primary
# agent/human to adjudicate (AGENTS.md "Second-Model Review") — this is never
# part of `verify`/`ci`. Both modes ask for P0/P1/P2/P3-labelled findings;
# only P0/P1 gate the local loop and P2s are reported and deferred to the PR
# stage. A label is a hypothesis and the ADJUDICATED severity is the verdict,
# P3 included; the sidecar records only what is left unresolved AND carried
# forward, so fixing one in place defers nothing and owes no entry.
# A finding badged off that scale, or not badged at all, is adjudicated as at
# least a P2, never dropped for being unrecognized.
# No target path may invoke Codex with an empty scope; every one of them
# refuses and exits non-zero instead (see refuse_empty_scope).
# Requires an authenticated Codex CLI (`codex login`);
# see docs/guides/codex-review.md.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/lib/review-scope.sh
. "$script_dir/lib/review-scope.sh"

usage() {
    echo "usage: $0 <review|challenge> [--repo-root <path>] [--profile standardize --release <release> --frozen-render <bundle>] [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
}

MODE="${1:-}"
case "$MODE" in
review | challenge) shift ;;
*)
    usage
    exit 2
    ;;
esac

# Ordinarily the trusted runner lives inside the checkout it reviews. A
# confidence-stage launcher can instead hold these runner/library bytes fixed
# and point them at a separate candidate checkout. Strip only this runner-owned
# option; review-scope.sh receives every remaining argument unchanged.
repo_root="$script_dir/.."
repo_root_seen=false
review_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo-root)
        if [ "$repo_root_seen" = true ] || [ "$#" -lt 2 ] || [ -z "$2" ]; then
            echo "--repo-root requires exactly one non-empty path" >&2
            usage
            exit 2
        fi
        repo_root="$2"
        repo_root_seen=true
        shift 2
        ;;
    *)
        review_args+=("$1")
        shift
        ;;
    esac
done

if [ ! -d "$repo_root" ]; then
    echo "--repo-root is not a directory: $repo_root" >&2
    exit 2
fi
repo_root="$(cd "$repo_root" && pwd -P)"
git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$git_root" ]; then
    echo "--repo-root is not a Git worktree: $repo_root" >&2
    exit 2
fi
git_root="$(cd "$git_root" && pwd -P)"
if [ "$git_root" != "$repo_root" ]; then
    echo "--repo-root must name the Git worktree root (got: $repo_root; root: $git_root)" >&2
    exit 2
fi
cd "$repo_root"

if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI not found. Install it (brew install --cask codex, or npm install -g @openai/codex)," >&2
    echo "authenticate with 'codex login', then re-run. See docs/guides/codex-review.md." >&2
    exit 1
fi

# Per-line ceiling for the CLI's stderr (see bound_stderr_lines at the bottom).
# Validated here rather than at the point of use so a typo fails before the
# git work and the review, not after them. 0 disables the bound.
#
# The 18-digit ceiling is about what `test -eq` can compare, not a view on
# useful line lengths: a value past INT64_MAX makes it fail with "integer
# expression expected" on stderr — leaking a confusing line into the stream
# this whole change exists to keep clean — and then fall through to an
# effectively unbounded run. 18 digits is the widest that always fits.
MAX_STDERR_BYTES="${CODEX_REVIEW_MAX_STDERR_BYTES:-1024}"
case "$MAX_STDERR_BYTES" in
'' | *[!0-9]*)
    echo "CODEX_REVIEW_MAX_STDERR_BYTES must be a non-negative integer (got: '${MAX_STDERR_BYTES}')" >&2
    exit 2
    ;;
[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
    echo "CODEX_REVIEW_MAX_STDERR_BYTES is implausibly large (got: '${MAX_STDERR_BYTES}'); use 0 to disable the bound" >&2
    exit 2
    ;;
esac

# Bash 3.2/4.3 treats an empty array as unset under `set -u`, so expanding
# "${review_args[@]}" directly aborts the ordinary no-extra-arguments path.
if [ "${#review_args[@]}" -eq 0 ]; then
    resolve_review_scope
else
    resolve_review_scope "${review_args[@]}"
fi
review_scope_apply_profile

if [ "$MODE" = "challenge" ]; then
    instructions="${scope}

Run an ADVERSARIAL review: your job is to break confidence in this change,
not to validate it. Challenge the architecture and the chosen approach, not
just the diff hunks. Actively hunt for: authorization bypasses and trust
boundary gaps; data-loss or corruption paths; unsafe rollback and migration
behavior; race conditions, ordering and idempotency gaps; hidden coupling and
assumptions that stop holding under stress; operational failure modes (empty
state, timeouts, retries, partial failure, degraded dependencies); and
unnecessarily complex design choices where a simpler alternative would do.
Report EVERY materially defensible finding tied to concrete files and lines —
do not stop at the first strong one. No style nits, no speculation you cannot
support from the code. If the change looks safe, say so directly."
else
    instructions="${scope}

Run a VERIFICATION-CHECKPOINT review of this change: double-check that the
implementation actually does what it claims, is internally consistent and
consistent with this repository's existing conventions and docs, handles
errors and edge cases, and has adequate test coverage (including regression
tests for anything it fixes). Flag docs the change should have updated.
Report only material, defensible findings tied to concrete files and lines —
no style nits. If the change holds up, say so directly."
fi

if [ "$review_profile" = standardize ]; then
    standardize_instructions="$script_dir/lib/review-instructions/standardize.txt"
    [ -r "$standardize_instructions" ] || {
        echo "missing review instructions: $standardize_instructions" >&2
        exit 2
    }
    instructions="${instructions}

$(cat "$standardize_instructions")"
fi

# Severity is defined HERE rather than inherited from the Codex CLI's own
# review output: its priority labels are an undocumented convention that can
# change under us, and the local dev loop gates on this scale (AGENTS.md
# "Second-Model Review"). Stating it in the prompt keeps the gate meaningful.
# The scale is closed at four levels, but the CLOUD reviewer is not driven by
# this prompt and has been seen emitting off-scale badges (a P3 on #918, back
# when the scale stopped at P2), so the unrecognized-badge invariant below is
# written for both audiences: an unknown or missing badge is worth at least a
# P2 of adjudication.
instructions="${instructions}

Label EVERY finding with a priority, as the first token of the finding:

  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.
  P3 — cosmetic or purely informational: a naming or wording choice that
       will mislead a reader, an observation with no defect behind it.
       Never gating. The no-style-nits rule above still binds — P3 is the
       floor for findings worth stating, not a licence to report nits.

Only P0 and P1 decide whether this review passes. Still report P2s in full —
they are triaged later, once the pull request is open — but do not let them
hold the stage open. Do not inflate a P2 to P1 to make it heard, and do not
withhold or soften a P2 because it is non-gating: a P2 reported here is
carried into the pull request description, so an unreported one is lost
outright. The same holds one level down: report a P3 as a P3 rather than
inflating it to P2 or dropping it for being small. Use these four labels and
no others — a finding that arrives off this scale, or with no label at all,
is adjudicated as at least a P2. Every label you apply is a hypothesis the
reader adjudicates on evidence, P3 included; none of them decides its own
disposition. If there are no P0 or P1 findings, say so
explicitly and in those terms."

if [ -n "$focus" ]; then
    instructions="${instructions}

Additional focus from the invoker (weight it heavily): ${focus}"
fi

# Custom review instructions bypass the CLI's native diff-target modes (the
# two are mutually exclusive), leaving diff collection to the model. Anchor it
# with an authoritative, git-generated file manifest so nothing in scope —
# untracked files included — can be silently skipped. Unconditional: the
# backstop above guarantees a non-empty manifest, so a "if we have one" test
# here would be dead code implying an empty-manifest run is reachable.
instructions="${instructions}

Authoritative changed-file manifest from git for this scope (status + path;
cover EVERY entry, including untracked files, collecting the diffs yourself
with git):

${manifest}"

# Codex puts the verdict on stdout and everything else — progress narration
# and errors alike — on stderr, so a caller capturing both (the documented
# `task challenge > log 2>&1`) interleaves them. Harmless until the CLI logs
# an error that inlines an entire API payload: one `codex_models_manager`
# decode failure emits the whole models JSON as a single ~195 KiB line, and it
# retries, so eleven lines carried 2.1 MB of a 2.2 MB log and buried the
# verdict the run exists to produce. Bound the LINE LENGTH rather than
# matching that message: nothing upstream bounds it, and any future decode
# error dumps its payload the same way.
#
# stderr only. The verdict is on stdout, where a long line is legitimate
# prose; truncating it would corrupt the very output this protects.
bound_stderr_lines() {
    if [ "$MAX_STDERR_BYTES" -eq 0 ]; then
        cat
        return
    fi
    # LC_ALL=C makes length()/substr() count bytes rather than characters, so
    # the ceiling holds whatever encoding the payload turns out to be in.
    # fflush() per line keeps the narration live: a round runs 5-15 minutes and
    # callers are told to read growing output as "still running, not hung"
    # (docs/guides/codex-review.md), which a block-buffered filter would break.
    LC_ALL=C awk -v max="$MAX_STDERR_BYTES" '
        {
            if (length($0) > max) {
                printf "%s... [%d-byte line truncated by codex-review.sh; set CODEX_REVIEW_MAX_STDERR_BYTES=0 for the full text]\n", substr($0, 1, max), length($0)
            } else {
                print
            }
            fflush()
        }
    '
}

# Feed the prompt through stdin (`review -`): a single argv element is
# capped (~128 KiB per arg on Linux), and cap_manifest bounds entry count,
# not bytes — 200 deep paths plus instructions can exceed the argv limit.
#
# The fd dance routes ONLY stderr through the filter: `3>&1` on the group
# parks the real stdout on fd3, `2>&1` puts stderr on the pipe, `1>&3` gives
# codex the real stdout back, and `3>&-` keeps the spare descriptor out of the
# child. A pipeline rather than `2> >(...)` is deliberate — the shell waits for
# a pipeline, so the tail of the narration cannot be lost to the script exiting
# first. Under pipefail the filter exits 0, leaving codex's own status as the
# rightmost non-zero, so a failed review still fails the task.
{ printf '%s\n' "$instructions" | codex exec review \
    --model gpt-6.1-sol \
    --config model_reasoning_effort=high \
    - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>&1
