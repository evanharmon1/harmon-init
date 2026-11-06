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
# part of `verify`/`ci`. Both modes ask for findings labelled on the P0–P3
# scale whose single normative statement is docs/review-guidelines.md
# ("Severity scale"); the prompt below carries the same lines, and
# test-codex-review.sh fails when the two differ. Only P0/P1 gate the local
# loop; everything else about adjudication is AGENTS.md's.
# The repository's own reviewer guidance — priorities, that scale, its
# invariants — is read from .devflow.toml [review_guidelines] and the file it
# names at the review's BASE revision (see "Review guidelines" below), so the
# change under review cannot rewrite the instructions that review it.
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

# ── Review guidelines (harmon-init#1530) ────────────────────────────────────
# The repository's reviewer instructions live in ONE file named by .devflow.toml
# [review_guidelines] (docs/review-guidelines.md by convention), so the local
# finders and the PR-side reviewers read the same copy. Both the table and the
# file are read from the review's BASE revision, never the working tree, so the
# change under review cannot rewrite the instructions that review it: the merge
# base for a branch-scoped review (explicit --base or the auto-detected union),
# the parent for --commit, HEAD for --uncommitted. The policy reader is
# materialized from that same revision — a branch editing the reader may not
# choose how its own policy is read (AGENTS.md "Rigor and Strategy") — and a
# reader that predates the table, or no reader at all, falls back to the
# conventional path at that revision. Nothing configured leaves the built-in
# instructions untouched, byte for byte.
guidelines_rev=""
case "$review_diff_spec" in
base:* | both:*)
    guidelines_rev="$(git merge-base "${review_diff_spec#*:}" HEAD 2>/dev/null || true)"
    ;;
commit:*)
    # Revision traversal hides parents at a shallow boundary. Read the commit
    # headers instead so missing history cannot masquerade as a genuine root.
    guidelines_commit="$(git cat-file -p "${review_diff_spec#commit:}^{commit}")" || {
        echo "could not read the reviewed commit for the review guidelines" >&2
        exit 2
    }
    guidelines_rev="$(sed -n '/^$/q; s/^parent //p' <<<"$guidelines_commit")"
    guidelines_rev="${guidelines_rev%%$'\n'*}"
    if [ -n "$guidelines_rev" ] && ! git cat-file -e "${guidelines_rev}^{commit}"; then
        echo "parent history unavailable at $guidelines_rev for the review guidelines; fetch the missing history before reviewing" >&2
        exit 2
    fi
    ;;
worktree)
    guidelines_rev="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
    ;;
esac

guidelines_tmp="$(mktemp -d "${TMPDIR:-/tmp}/harmon-review-guidelines.XXXXXX")" || {
    echo "could not create a scratch directory for the review guidelines" >&2
    exit 2
}
trap 'rm -rf "$guidelines_tmp"' EXIT
# Node resolves import.meta.url physically; its CLI entry-point check must see
# the same path in argv even when TMPDIR contains a symlink.
guidelines_tmp_physical="$(cd "$guidelines_tmp" && pwd -P)" || {
    echo "could not resolve the scratch directory for the review guidelines" >&2
    exit 2
}
guidelines_tmp="$guidelines_tmp_physical"

# Prove absence with a successful literal tree lookup before reading content.
# Failed tree/blob reads are fatal even inside conditional callers, where
# errexit is suppressed; only a genuinely absent path returns 1 for fallback.
# Writing content to a file preserves its exact bytes (including newlines).
show_at_rev() {
    local entry
    entry="$(git --literal-pathspecs ls-tree --full-tree "$1" -- "$2")" || {
        echo "could not inspect '$2' at $1 for the review guidelines" >&2
        exit 2
    }
    [ -n "$entry" ] || return 1
    case "$entry" in
    '100644 blob '* | '100755 blob '*) ;;
    *)
        echo "'$2' at $1 is not a regular file for the review guidelines" >&2
        exit 2
        ;;
    esac
    git show "${1}:${2}" >"$3" || {
        echo "could not read '$2' at $1 for the review guidelines" >&2
        exit 2
    }
}

# The merge-base copy of the policy reader, in the layouts a repository can
# carry it: this repository's own, then the vendored dev-flow-support skill.
# Both import only ./lib/toml-lite.mjs beside themselves, so the pair is the
# whole program.
materialize_policy_reader() {
    local rev="$1" dest="$2" candidate
    for candidate in scripts/devflow-policy.mjs \
        .claude/skills/dev-flow-support/assets/devflow-policy.mjs \
        .agents/skills/dev-flow-support/assets/devflow-policy.mjs; do
        mkdir -p "$dest/lib"
        if show_at_rev "$rev" "$candidate" "$dest/devflow-policy.mjs" &&
            show_at_rev "$rev" "${candidate%/*}/lib/toml-lite.mjs" "$dest/lib/toml-lite.mjs"; then
            return 0
        fi
    done
    rm -rf "$dest"
    return 1
}

# Globals the prompt assembly reads. Source is the human-readable provenance
# the prompt and the ledger name; text is the content; focus is the mode's
# configured default, used only when the CLI gave none.
guidelines_source=""
guidelines_text=""
guidelines_focus=""
resolve_review_guidelines() {
    local rev="$1" state=none policy="$guidelines_tmp/devflow.toml" reader="$guidelines_tmp/reader"
    local out="$guidelines_tmp/policy.json" err="$guidelines_tmp/reader.err" status=0 file
    [ -n "$rev" ] || {
        echo "==> Review guidelines: no base revision for this scope; built-in instructions only" >&2
        return 0
    }
    if show_at_rev "$rev" .devflow.toml "$policy"; then
        if ! command -v node >/dev/null 2>&1; then
            echo "Note: node is not installed, so .devflow.toml [review_guidelines] cannot be read; using the conventional path." >&2
        elif ! materialize_policy_reader "$rev" "$reader"; then
            echo "Note: no policy reader at $rev, so .devflow.toml [review_guidelines] cannot be read; using the conventional path." >&2
        else
            node "$reader/devflow-policy.mjs" resolve --policy "$policy" --json >"$out" 2>"$err" || status=$?
            # 3 is "resolved, cross-validation indeterminate" (no registry was
            # offered); the projection is complete either way.
            case "$status" in
            0 | 3)
                # Each projected value lands in its own file: `text` may span
                # lines, and a file keeps it intact without any quoting.
                node -e '
const fs = require("node:fs")
const [out, dir] = process.argv.slice(1)
const policy = JSON.parse(fs.readFileSync(out, "utf8"))
if (!Object.hasOwn(policy, "review_guidelines")) {
  fs.writeFileSync(`${dir}/state`, "unsupported")
} else if (policy.review_guidelines === null) {
  fs.writeFileSync(`${dir}/state`, "absent")
} else {
  fs.writeFileSync(`${dir}/state`, "table")
  for (const key of ["file", "text", "challenge_focus", "review_focus"]) {
    const value = policy.review_guidelines[key]
    if (typeof value === "string") fs.writeFileSync(`${dir}/${key}`, value)
  }
}
' "$out" "$guidelines_tmp" || {
                    echo "could not read the policy reader's output for [review_guidelines]" >&2
                    exit 2
                }
                state="$(cat "$guidelines_tmp/state")"
                ;;
            *)
                echo "Note: the policy reader at $rev refused .devflow.toml (exit ${status}); using the conventional path for the review guidelines." >&2
                sed 's/^/      /' "$err" >&2
                ;;
            esac
        fi
    fi
    case "$state" in
    table)
        if [ -f "$guidelines_tmp/file" ]; then
            file="$(cat "$guidelines_tmp/file")"
            # The reader already refused an unsafe path; a configured file that
            # does not exist at the base revision is a misconfiguration worth
            # failing on before the review is paid for.
            show_at_rev "$rev" "$file" "$guidelines_tmp/guidelines" || {
                echo ".devflow.toml [review_guidelines].file names '$file', which does not exist at $rev" >&2
                exit 2
            }
            guidelines_source="$file"
        elif [ -f "$guidelines_tmp/text" ]; then
            cp "$guidelines_tmp/text" "$guidelines_tmp/guidelines"
            guidelines_source=".devflow.toml [review_guidelines].text"
        fi
        if [ -f "$guidelines_tmp/${MODE}_focus" ]; then
            guidelines_focus="$(cat "$guidelines_tmp/${MODE}_focus")"
        fi
        ;;
    esac
    # No table, a reader that does not project it, or a table naming neither
    # source: the conventional path at the same revision, when it exists.
    if [ -z "$guidelines_source" ] && show_at_rev "$rev" docs/review-guidelines.md "$guidelines_tmp/guidelines"; then
        guidelines_source="docs/review-guidelines.md"
    fi
    if [ -n "$guidelines_source" ]; then
        guidelines_text="$(cat "$guidelines_tmp/guidelines")"
        echo "==> Review guidelines: ${guidelines_source} at $(git rev-parse --short "$rev")" >&2
    else
        echo "==> Review guidelines: none at $(git rev-parse --short "$rev"); built-in instructions only" >&2
    fi
}
resolve_review_guidelines "$guidelines_rev"

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

# The repository's guidelines come straight after the mode preamble, so the
# reviewer reads what THIS repository asks for before the scale that labels it.
# Their provenance is stated so a reader of the prompt (or of a ledger quoting
# it) can tell which revision's instructions governed.
if [ -n "$guidelines_source" ]; then
    instructions="${instructions}

Repository review guidelines (${guidelines_source}, read at $(git rev-parse --short "$guidelines_rev")). Apply them throughout this review:

${guidelines_text}"
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
elif [ -n "$guidelines_focus" ]; then
    # The policy's default focus for this mode stands in only when the CLI
    # gave none: an invoker's focus text is always the more specific ask.
    instructions="${instructions}

Default focus from the repository's review policy (.devflow.toml [review_guidelines].${MODE}_focus; weight it heavily): ${guidelines_focus}"
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
