#!/usr/bin/env bash
# setup-ruleset.sh — add required status-check contexts the checked-in ruleset
# declares and the LIVE ruleset is missing. The write counterpart to
# audit-ruleset.sh, which only reports the same drift.
#
# Why this exists: the checked-in ruleset JSON is imported through the UI ONCE,
# and `copier update` never mutates a live ruleset. So a required check added to
# the template after a repo was set up never reaches that repo, and the gate it
# was supposed to provide silently does not exist. `closing-keywords` is the
# case that forced this (harmon-init#1328): it used to be enforced transitively
# through the aggregate `verify` check, and once it moved to its own workflow —
# `needs:` cannot cross workflows — only a live ruleset entry enforces it.
#
# ADDITIVE ONLY, deliberately. A context that live has and the file does not is
# reported and LEFT ALONE: removing a required check weakens a merge gate, and
# this tool never does that. It also never touches bypass actors, rule
# parameters, or any rule other than required_status_checks. Everything it
# declines to do, `task audit:ruleset` still reports.
#
# Usage:
#   setup-ruleset.sh [--repo owner/name] [--yes] [--dry-run]
#
#   --repo     target repository (default: derived from origin, as audit does)
#   --yes      skip the confirmation prompt (for non-interactive operators)
#   --dry-run  print the additions and exit without writing
#
# Exit: 0 = already in sync, or the additions were applied (or --dry-run);
#       1 = the write failed; 2 = unavailable (cannot determine the target,
#       no single live ruleset, malformed JSON, declined at the prompt).
set -euo pipefail

cd "$(dirname "$0")/.."

readonly ruleset_file="${RULESET_AUDIT_FILE:-.github/Branch Protection Ruleset - Protect Main.json}"
readonly fixture_list="${RULESET_AUDIT_LIVE_LIST:-}"
readonly fixture_detail="${RULESET_AUDIT_LIVE_DETAIL:-}"
readonly fixture_write="${RULESET_SETUP_WRITE_OUT:-}"

assume_yes=no
dry_run=no
repo_arg=""

die_unavailable() {
    echo "RULESET SETUP UNAVAILABLE: $1" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || die_unavailable "--repo needs a value"
        repo_arg="$2"
        shift 2
        ;;
    --yes) assume_yes=yes && shift ;;
    --dry-run) dry_run=yes && shift ;;
    *) die_unavailable "unknown argument: $1" ;;
    esac
done

[ -f "$ruleset_file" ] || die_unavailable "checked-in ruleset file is missing: $ruleset_file"
command -v jq >/dev/null 2>&1 || die_unavailable "jq is required"
ruleset_name="$(jq -er '.name' "$ruleset_file" 2>/dev/null)" ||
    die_unavailable "checked-in ruleset has no valid name"

if [ -n "$repo_arg" ]; then
    repo="$repo_arg"
elif [ -n "${RULESET_AUDIT_REPO:-}" ]; then
    repo="$RULESET_AUDIT_REPO"
else
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    case "$remote_url" in
    https://github.com/* | http://github.com/*) repo="${remote_url#*github.com/}" ;;
    git@github.com:*) repo="${remote_url#git@github.com:}" ;;
    ssh://git@github.com/*) repo="${remote_url#ssh://git@github.com/}" ;;
    ssh://git@github.com:*/*)
        repo="${remote_url#ssh://git@github.com:}"
        repo="${repo#*/}"
        ;;
    ssh://git@ssh.github.com/*) repo="${remote_url#ssh://git@ssh.github.com/}" ;;
    ssh://git@ssh.github.com:*/*)
        repo="${remote_url#ssh://git@ssh.github.com:}"
        repo="${repo#*/}"
        ;;
    *) die_unavailable "origin is not a GitHub repository" ;;
    esac
    repo="${repo%.git}"
fi
case "$repo" in
*/?*) ;;
*) die_unavailable "could not determine owner/repository from origin" ;;
esac

tmp_dir="$(mktemp -d -t harmon-init-ruleset-setup-XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -n "$fixture_list" ]; then
    cp "$fixture_list" "$tmp_dir/list.json" 2>/dev/null ||
        die_unavailable "ruleset list fixture cannot be read"
else
    gh api --paginate --slurp "repos/${repo}/rulesets?includes_parents=false&per_page=100" 2>/dev/null |
        jq 'add' >"$tmp_dir/list.json" || die_unavailable "gh cannot read repository rulesets"
fi

# Exactly once, same rule the audit uses: two rulesets of one name is the
# duplicate-import state, and guessing which one gates merges would be wrong.
ruleset_id="$(jq -er --arg name "$ruleset_name" \
    '[ .[] | select(.name == $name and .source_type == "Repository") ]
     | if length == 1 then .[0].id else empty end' "$tmp_dir/list.json" 2>/dev/null)" ||
    die_unavailable "live repository ruleset not found exactly once: ${ruleset_name} — import it first (see docs/architecture/branch-protection.md)"

if [ -n "$fixture_detail" ]; then
    cp "$fixture_detail" "$tmp_dir/live.json" 2>/dev/null ||
        die_unavailable "ruleset detail fixture cannot be read"
else
    gh api "repos/${repo}/rulesets/${ruleset_id}" >"$tmp_dir/live.json" 2>/dev/null ||
        die_unavailable "gh cannot read live ruleset ${ruleset_id}"
fi

jq -e . "$ruleset_file" >/dev/null 2>&1 || die_unavailable "checked-in ruleset is not valid JSON"
jq -e . "$tmp_dir/live.json" >/dev/null 2>&1 || die_unavailable "live ruleset is not valid JSON"

# One definition, used from both directions. `checks` yields the full check
# OBJECTS (a missing one has to be added with its integration_id, not just its
# name); `names` reduces them to context strings for the set comparison.
readonly jq_defs='
def checks: [ .rules[]? | select(.type == "required_status_checks")
              | .parameters.required_status_checks[]? ];
def names: checks | map(.context);
'

# Missing = declared in the file, absent from live, compared by context name.
jq --slurpfile live "$tmp_dir/live.json" "
  $jq_defs
  (\$live[0] | names) as \$have
  | [ checks[] | select(.context as \$c | \$have | index(\$c) | not) ]
" "$ruleset_file" >"$tmp_dir/missing.json" 2>/dev/null ||
    die_unavailable "could not compare required status checks"

# Reported, never removed: this tool only ever strengthens a merge gate.
jq --slurpfile file "$ruleset_file" "
  $jq_defs
  (\$file[0] | names) as \$want
  | [ names[] | select(. as \$c | \$want | index(\$c) | not) ]
" "$tmp_dir/live.json" >"$tmp_dir/extra.json" 2>/dev/null ||
    die_unavailable "could not compare required status checks"

# Same context name, different integration_id. GitHub uses integration_id to
# constrain WHICH app may satisfy a required check, so a same-named check from
# another source can satisfy the gate while the checked-in ruleset asks for the
# GitHub Actions one. Name-only matching would call that "already in sync".
# Detected, never silently repaired: changing an existing entry's integration
# would alter a check the repository already requires, and this tool only ever
# adds. Reported for a human, and exit 1 so it is not mistaken for clean.
jq --slurpfile live "$tmp_dir/live.json" "
  $jq_defs
  (\$live[0] | checks) as \$have
  | [ checks[]
      | . as \$want
      | \$have[]
      | select(.context == \$want.context and .integration_id != \$want.integration_id)
      | \"\(.context) (live integration_id \(.integration_id // \"null\"), expected \(\$want.integration_id // \"null\"))\" ]
" "$ruleset_file" >"$tmp_dir/mismatch.json" 2>/dev/null ||
    die_unavailable "could not compare required status checks"
mismatch_count="$(jq 'length' "$tmp_dir/mismatch.json")"

missing_count="$(jq 'length' "$tmp_dir/missing.json")"
extra_count="$(jq 'length' "$tmp_dir/extra.json")"

if [ "$extra_count" -gt 0 ]; then
    echo "RULESET SETUP NOTE: ${repo} requires $(jq -r 'join(", ")' "$tmp_dir/extra.json") — not in the checked-in ruleset, left alone (this tool never removes a required check)."
fi

if [ "$mismatch_count" -gt 0 ]; then
    echo "RULESET SETUP MISMATCH: ${repo} requires these contexts from a different integration than the checked-in ruleset asks for:" >&2
    jq -r '.[] | "  ! \(.)"' "$tmp_dir/mismatch.json" >&2
    echo "Fix these by hand — this tool only ADDS required checks, it never changes one the repository already requires." >&2
fi

if [ "$missing_count" -eq 0 ]; then
    if [ "$mismatch_count" -gt 0 ]; then
        echo "RULESET SETUP INCOMPLETE: nothing to add, but the mismatch above needs a human." >&2
        exit 1
    fi
    echo "RULESET SETUP CLEAN: ${ruleset_name} (${repo}) already requires every checked-in status check."
    exit 0
fi

echo "RULESET SETUP: ${ruleset_name} (${repo}) is missing $(jq -r 'length' "$tmp_dir/missing.json") required status check(s):"
jq -r '.[] | "  + \(.context)"' "$tmp_dir/missing.json"

if [ "$dry_run" = yes ]; then
    echo "(--dry-run: nothing written)"
    exit 0
fi

if [ "$assume_yes" != yes ]; then
    [ -t 0 ] || die_unavailable "refusing to change a merge gate non-interactively without --yes"
    printf 'Add these required status checks to the live ruleset? [y/N] '
    read -r reply
    case "$reply" in
    y | Y | yes | YES) ;;
    *) die_unavailable "declined" ;;
    esac
fi

# Re-read before writing. The snapshot above was taken before the prompt, and a
# PUT sends a whole `rules` array — so a rule another administrator changed
# while the prompt waited would be silently reverted to the stale snapshot.
# Abort rather than overwrite a concurrent security-setting change.
if [ -z "$fixture_detail" ]; then
    gh api "repos/${repo}/rulesets/${ruleset_id}" >"$tmp_dir/live.recheck.json" 2>/dev/null ||
        die_unavailable "gh cannot re-read live ruleset ${ruleset_id} before writing"
    if ! diff -q <(jq -S '.rules' "$tmp_dir/live.json") \
        <(jq -S '.rules' "$tmp_dir/live.recheck.json") >/dev/null 2>&1; then
        die_unavailable "the live ruleset changed while this was waiting — re-run and re-read the plan"
    fi
fi

# Send back LIVE's own rules with the required_status_checks contexts extended.
# PUT updates the existing ruleset in place — unlike POST, which creates a
# duplicate — and echoing live's other rules verbatim means a local
# customization outside this one array is preserved rather than reset.
#
# The `else` branch is load-bearing: a live ruleset may have NO
# required_status_checks rule at all (observed on a real repository whose only
# rule was copilot_code_review). Appending to a rule that is not there is a
# no-op, so the payload would equal live, the PUT would succeed, and this would
# report APPLIED having changed nothing — a false success on exactly the
# migration this command exists to perform. When the rule is absent it is
# CREATED, taking its parameters from the checked-in ruleset so the policy
# flags come from the file rather than being invented here.
jq --slurpfile missing "$tmp_dir/missing.json" --slurpfile file "$ruleset_file" '
  ([ .rules[]? | select(.type == "required_status_checks") ] | length > 0) as $has_rule
  | { rules: (
        if $has_rule then
          .rules | map(if .type == "required_status_checks"
                       then .parameters.required_status_checks += $missing[0]
                       else . end)
        else
          .rules + [ ($file[0].rules[] | select(.type == "required_status_checks"))
                     | .parameters.required_status_checks = $missing[0] ]
        end
      ) }
' "$tmp_dir/live.json" >"$tmp_dir/payload.json" ||
    die_unavailable "could not build the update payload"

# Every context that must be required once this lands: what live already had,
# plus what is being added. Used to prove the outcome rather than assume it.
jq -r --slurpfile live "$tmp_dir/live.json" "
  $jq_defs
  [ (\$live[0] | names[]), (.[] | .context) ] | unique | .[]
" "$tmp_dir/missing.json" | sort >"$tmp_dir/expected.txt"

# Assert the PAYLOAD carries them before sending. This catches a merge that
# silently did nothing, whatever the cause — the invariant, not one bug.
jq -r "$jq_defs names[]" "$tmp_dir/payload.json" | sort >"$tmp_dir/payload.txt"
payload_absent="$(comm -23 "$tmp_dir/expected.txt" "$tmp_dir/payload.txt" | tr '\n' ' ')"
case "$payload_absent" in
*[![:space:]]*)
    echo "RULESET SETUP FAILED: the update payload would not require: ${payload_absent}" >&2
    exit 1
    ;;
esac

if [ -n "$fixture_write" ]; then
    cp "$tmp_dir/payload.json" "$fixture_write"
    echo "RULESET SETUP APPLIED (fixture): ${ruleset_name} (${repo})"
    exit 0
fi

if ! gh api --method PUT "repos/${repo}/rulesets/${ruleset_id}" \
    --input "$tmp_dir/payload.json" >"$tmp_dir/result.json" 2>"$tmp_dir/err"; then
    cat "$tmp_dir/err" >&2
    echo "RULESET SETUP FAILED: could not update live ruleset ${ruleset_id} on ${repo}." >&2
    echo "Add the contexts above by hand: Settings → Rules → Rulesets → ${ruleset_name}." >&2
    echo "Do NOT re-import the JSON — GitHub creates a duplicate ruleset instead of updating this one." >&2
    exit 1
fi

# Prove the outcome. A 2xx says the request was accepted, not that the merge
# gate changed: read the ruleset back and require every expected context.
gh api "repos/${repo}/rulesets/${ruleset_id}" >"$tmp_dir/after.json" 2>/dev/null ||
    die_unavailable "the update was accepted but the ruleset could not be re-read to confirm it"
jq -r "$jq_defs names[]" "$tmp_dir/after.json" | sort >"$tmp_dir/after.txt"
absent="$(comm -23 "$tmp_dir/expected.txt" "$tmp_dir/after.txt" | tr '\n' ' ')"
case "$absent" in
*[![:space:]]*)
    echo "RULESET SETUP FAILED: the update was accepted but ${repo} still does not require: ${absent}" >&2
    echo "Add them by hand: Settings → Rules → Rulesets → ${ruleset_name}." >&2
    exit 1
    ;;
esac

echo "RULESET SETUP APPLIED: ${ruleset_name} (${repo}) now requires every checked-in status check."
echo "Confirm with: task audit:ruleset"
