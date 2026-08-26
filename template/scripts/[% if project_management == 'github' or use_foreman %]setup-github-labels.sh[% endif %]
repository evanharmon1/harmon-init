#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set, report labels outside the registry, and retire them safely when asked.
# The vocabulary is NOT listed here: every family, value, color, and description
# lives in label-registry.json (the machine-readable taxonomy manifest — see
# docs/project-management.md for the human-facing table, which is generated from
# the same file), and this script provisions whatever
# scripts/label-registry-render.mjs renders from it. The agent families
# (suggest:/claim:/foreman:<adapter>) come from agent-registry.json via the same
# renderer, so provisioning, inventory, docs, and both registries cannot fork
# (test-label-registry.sh and test-registry-drift.sh gate them together).
#
# Labels are REPO-level in GitHub — there's no shared org label pool. Run this in
# each repo; org "default labels" (Settings → Repository, UI-only, no API) only
# seed NEW repos and don't touch existing ones. Non-destructive: `--force`
# creates-or-updates and it never deletes labels, so GitHub's defaults stay
# unless you explicitly run a maintenance mode. The maintenance modes report
# live labels outside the active/adopted/tool-owned registry inventory and can
# prune them only after a prompt and a fresh zero-association check.
# `--migrate OLD=NEW` attempts to move OLD associations for matching issues and
# pull requests returned by the paginated snapshot before the guarded prune.
# Retired values are intentionally reportable. The move is best-effort at
# GitHub's non-atomic API boundary and requires a quiescent maintenance window.
# Destructive maintenance assumes the operator has paused label/issue/PR writers
# for a quiescent window; GitHub cannot atomically bind the final association
# read to the subsequent label DELETE request.
#
# Usage:
#   setup-github-labels.sh --repo <owner/repo> [--foreman] [--release-please]
#   setup-github-labels.sh --repo <owner/repo> --report-unregistered [flags]
#   setup-github-labels.sh --repo <owner/repo> --prune [--migrate OLD=NEW] [--yes] [flags]
# Needs: gh authed with repo write; node (the renderer); jq for maintenance.
#
# --foreman additionally provisions the families the manifest gates on foreman
# (the arming selectors rendered from the agent registry, and foreman's own
# workflow-state protocol labels — human inputs the foreman CLI reads but never
# auto-creates). The flag is passed by the Taskfile target when the repo uses
# foreman, keeping this script identical across repos that do and don't.
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test maintenance modes against a stub.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage:
  setup-github-labels.sh --repo <owner/repo> [--foreman] [--release-please]
  setup-github-labels.sh --repo <owner/repo> --report-unregistered [flags]
  setup-github-labels.sh --repo <owner/repo> --prune [--migrate OLD=NEW] [--yes] [flags]

The default invocation only creates or updates registry-provisioned labels.
--report-unregistered is read-only. --prune requires operator confirmation of
a quiescent maintenance window. After any requested migration, it refuses
deletion when associations remain in its latest API snapshot, but GitHub has
no atomic read/delete boundary and a concurrent writer can still race the
request. --yes is the explicit noninteractive confirmation of that window and
of this best-effort boundary.
USAGE
}

repo=""
foreman=0
release_please=0
migrate_specs=()
report_unregistered=0
prune=0
assume_yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --help)
        usage
        exit 0
        ;;
    --repo)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
            echo "--repo requires a non-empty owner/repo value" >&2
            exit 2
        fi
        repo="${2:-}"
        shift 2
        ;;
    --foreman)
        foreman=1
        shift
        ;;
    --release-please)
        release_please=1
        shift
        ;;
    --report-unregistered)
        report_unregistered=1
        shift
        ;;
    --prune)
        prune=1
        shift
        ;;
    --yes)
        assume_yes=1
        shift
        ;;
    --migrate)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
            echo "--migrate requires OLD=NEW" >&2
            exit 2
        fi
        migrate_specs+=("$2")
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "--repo <owner/repo> is required" >&2
    usage
    exit 2
fi
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid repository '$repo' (expected owner/repo)" >&2
    exit 2
fi
if [ "$report_unregistered" = 1 ] && [ "$prune" = 1 ]; then
    echo "--report-unregistered and --prune are mutually exclusive" >&2
    exit 2
fi
if [ "${#migrate_specs[@]}" -gt 0 ] && [ "$prune" != 1 ]; then
    echo "--migrate requires --prune" >&2
    exit 2
fi
if [ "$assume_yes" = 1 ] && [ "$prune" != 1 ]; then
    echo "--yes requires --prune" >&2
    exit 2
fi

for tool in gh node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done
if [ "$report_unregistered" = 1 ] || [ "$prune" = 1 ]; then
    # GitHub label names are case-insensitive. Keep every local membership and
    # collision check aligned with the API so a differently-cased live label
    # cannot be reported or pruned as though it were unregistered.
    shopt -s nocasematch
    if ! command -v jq >/dev/null 2>&1; then
        echo "Required tool not found for maintenance mode: jq" >&2
        exit 1
    fi
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
renderer="$script_dir/label-registry-render.mjs"
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "$script_dir/lib/output.sh"

die() {
    output_emit 'ERROR: %s\n' "$*"
    exit 1
}

render_args=(labels)
if [ "$foreman" = 1 ]; then
    render_args+=(--foreman)
fi
if [ "$release_please" = 1 ]; then
    render_args+=(--release-please)
fi

if [ "$report_unregistered" = 1 ] || [ "$prune" = 1 ]; then
    action_banner clean "GitHub label retirement" "Read, migrate, and prune only with explicit maintenance flags"
    kv "Repository" "$repo"

    maintenance_tmp="$(mktemp -d)"
    trap 'rm -rf "$maintenance_tmp"' EXIT
    live_pages="$maintenance_tmp/live-pages.json"
    live_labels_json="$maintenance_tmp/live-labels.json"
    association_pages="$maintenance_tmp/association-pages.json"
    associations_json="$maintenance_tmp/associations.json"

    read_live_labels() {
        if ! gh api --paginate --slurp "repos/$repo/labels?per_page=100" >"$live_pages"; then
            die "could not read the complete label list; refusing maintenance"
        fi
        if ! jq -e '
            if type != "array" or any(.[]; type != "array") then
                error("expected paginated label arrays")
            else
                [.[][] |
                    if type != "object" or (.name | type) != "string" or (.name | length) == 0 or (.name | test("[\\n\\r]")) then
                        error("label response contains an invalid name")
                    else .name end
                ]
            end
        ' "$live_pages" >"$live_labels_json"; then
            die "label response was invalid or incomplete; refusing maintenance"
        fi
    }

    read_associations() {
        if ! gh api --paginate --slurp "repos/$repo/issues?state=all&per_page=100" >"$association_pages"; then
            die "could not read the complete issue and pull-request list; refusing maintenance"
        fi
        if ! jq -e '
            if type != "array" or any(.[]; type != "array") then
                error("expected paginated issue arrays")
            else
                [.[][] |
                    if type != "object" then
                        error("issue response contains a non-object")
                    elif (.number | type) != "number" then
                        error("issue response contains an invalid number")
                    elif has("pull_request") and (.pull_request | type) != "object" then
                        error("issue response contains an invalid pull-request marker")
                    elif (.labels | type) != "array" then
                        error("issue response contains no labels array")
                    elif any(.labels[]; type != "object" or ((.name | type) != "string") or ((.name | length) == 0) or (.name | test("[\\n\\r]"))) then
                        error("issue response contains an invalid label")
                    else
                        {number, pull_request: has("pull_request"), labels: [.labels[].name]}
                    end
                ]
            end
        ' "$association_pages" >"$associations_json"; then
            die "issue or pull-request response was invalid; refusing maintenance"
        fi
    }

    protected_exact=()
    protected_prefixes=()
    load_inventory() {
        local inventory kind name extra
        if ! inventory="$(node "$renderer" inventory "${render_args[@]:1}")"; then
            die "registry inventory rendering failed; refusing maintenance"
        fi
        while IFS='|' read -r kind name extra; do
            [ -z "$kind" ] && continue
            [ -n "$name" ] || die "registry inventory contained an empty label"
            [ -z "$extra" ] || die "registry inventory contained a malformed record"
            case "$kind" in
            exact)
                protected_exact+=("$name")
                ;;
            prefix)
                protected_prefixes+=("$name")
                ;;
            *)
                die "registry inventory contained unknown record type '$kind'"
                ;;
            esac
        done <<<"$inventory"
    }

    is_protected_label() {
        local name="$1" exact prefix
        for exact in "${protected_exact[@]}"; do
            [[ "$name" == "$exact" ]] && return 0
        done
        for prefix in "${protected_prefixes[@]}"; do
            case "$name" in
            "$prefix"*) return 0 ;;
            esac
        done
        return 1
    }

    live_label_name() {
        local wanted="$1" name
        while IFS= read -r -d '' name; do
            if [[ "$name" == "$wanted" ]]; then
                printf '%s' "$name"
                return 0
            fi
        done < <(jq -j '.[] | . + "\u0000"' "$live_labels_json")
        return 1
    }

    live_label_exists() {
        live_label_name "$1" >/dev/null
    }

    candidate_label_name() {
        local wanted="$1" name
        for name in "${candidates[@]}"; do
            if [[ "$name" == "$wanted" ]]; then
                printf '%s' "$name"
                return 0
            fi
        done
        return 1
    }

    association_counts() {
        local label="$1"
        jq -r --arg label "$label" '
            reduce .[] as $item ({issues: 0, prs: 0};
                if any($item.labels[]; ascii_downcase == ($label | ascii_downcase)) then
                    if $item.pull_request then .prs += 1 else .issues += 1 end
                else . end)
            | "\(.issues)\t\(.prs)"
        ' "$associations_json"
    }

    candidates=()
    candidate_issues=()
    candidate_prs=()
    collect_candidates() {
        local name counts issue_count pr_count
        while IFS= read -r -d '' name; do
            if is_protected_label "$name"; then
                continue
            fi
            counts="$(association_counts "$name")"
            IFS=$'\t' read -r issue_count pr_count <<<"$counts"
            candidates+=("$name")
            candidate_issues+=("$issue_count")
            candidate_prs+=("$pr_count")
        done < <(jq -j '.[] | . + "\u0000"' "$live_labels_json")
    }

    print_report() {
        local i
        if [ "${#candidates[@]}" -eq 0 ]; then
            output_emit '%s\n' 'No unregistered labels found.'
            return 0
        fi
        for i in "${!candidates[@]}"; do
            printf -v quoted_name '%q' "${candidates[$i]}"
            output_emit 'Unregistered label: %s (issues: %s, PRs: %s)\n' \
                "$quoted_name" "${candidate_issues[$i]}" "${candidate_prs[$i]}"
        done
    }

    migration_old=()
    migration_new=()
    parse_migrations() {
        local spec old new i
        [ "${#migrate_specs[@]}" -gt 0 ] || return 0
        for spec in "${migrate_specs[@]}"; do
            case "$spec" in
            *=*)
                old="${spec%%=*}"
                new="${spec#*=}"
                ;;
            *)
                echo "Invalid migration '$spec' (expected OLD=NEW)" >&2
                exit 2
                ;;
            esac
            if [ -z "$old" ] || [ -z "$new" ] ||
                [[ "$old" == *$'\n'* || "$old" == *$'\r'* || "$new" == *$'\n'* || "$new" == *$'\r'* ]]; then
                echo "Invalid migration '$spec' (labels must be non-empty and single-line)" >&2
                exit 2
            fi
            if [[ "$old" == "$new" ]]; then
                echo "Invalid migration '$spec' (OLD and NEW must differ)" >&2
                exit 2
            fi
            for i in "${!migration_old[@]}"; do
                if [[ "$old" == "${migration_old[$i]}" ]]; then
                    echo "Duplicate migration source '$old'" >&2
                    exit 2
                fi
            done
            migration_old+=("$old")
            migration_new+=("$new")
        done
    }

    is_migration_source() {
        local wanted="$1" old
        [ "${#migration_old[@]}" -gt 0 ] || return 1
        for old in "${migration_old[@]}"; do
            [[ "$old" == "$wanted" ]] && return 0
        done
        return 1
    }

    is_broker_migration_source() {
        case "$1" in
        agent:github-copilot | agent:github-copilot:* | suggest:copilot | suggest:copilot:* | claim:copilot | claim:copilot:*) return 0 ;;
        esac
        return 1
    }

    validate_migrations() {
        local i old new canonical_old canonical_new
        for i in "${!migration_old[@]}"; do
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            if ! canonical_old="$(candidate_label_name "$old")"; then
                die "migration source '$old' is not one of the reported unregistered labels"
            fi
            if is_broker_migration_source "$canonical_old"; then
                die "migration source '$canonical_old' is broker-derived and has no trustworthy single destination; re-express or remove each matching record manually using its confirmed family/model, then rerun --prune"
            fi
            if ! canonical_new="$(live_label_name "$new")"; then
                die "migration destination '$new' is not a live label; provision it first"
            fi
            if ! is_protected_label "$canonical_new"; then
                die "migration destination '$new' is not covered by the registry inventory"
            fi
            migration_old[i]="$canonical_old"
            migration_new[i]="$canonical_new"
        done
    }

    print_migration_plan() {
        local i old new counts issue_count pr_count
        for i in "${!migration_old[@]}"; do
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            counts="$(association_counts "$old")"
            IFS=$'\t' read -r issue_count pr_count <<<"$counts"
            printf -v quoted_old '%q' "$old"
            printf -v quoted_new '%q' "$new"
            output_emit 'Migration: %s -> %s (issues: %s, PRs: %s)\n' \
                "$quoted_old" "$quoted_new" "$issue_count" "$pr_count"
        done
    }

    confirm_prune() {
        local answer
        if [ "$assume_yes" = 1 ]; then
            output_emit '%s\n' 'Prune confirmed by explicit --yes: operator confirms a quiescent maintenance window and accepts the unavoidable GitHub final-read/delete API race.'
            return 0
        fi
        if [ ! -t 0 ]; then
            output_emit '%s\n' 'Prune cancelled: interactive confirmation requires a TTY; pass --yes explicitly for noninteractive use.'
            return 1
        fi
        if ! read -r -p 'Confirm a quiescent maintenance window (pause label/issue/PR writers) and accept the unavoidable GitHub final-read/delete API race; proceed? [y/N] ' answer </dev/tty; then
            output_emit '%s\n' 'Prune cancelled: confirmation was unavailable.'
            return 1
        fi
        case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
        *)
            output_emit '%s\n' 'Prune cancelled; no labels were changed.'
            return 1
            ;;
        esac
    }

    read_item_labels() {
        local kind="$1" number="$2"
        if [ "$kind" = pr ]; then
            gh pr view "$number" --repo "$repo" --json labels
        else
            gh issue view "$number" --repo "$repo" --json labels
        fi
    }

    migration_labels_present() {
        local labels_json="$1" old="$2" new="$3"
        jq -e --arg old "$old" --arg new "$new" '
            (.labels | type) == "array" and
            any(.labels[]?; ((.name | ascii_downcase) == ($old | ascii_downcase))) and
            any(.labels[]?; ((.name | ascii_downcase) == ($new | ascii_downcase)))
        ' <<<"$labels_json" >/dev/null
    }

    migration_result_valid() {
        local labels_json="$1" old="$2" new="$3"
        jq -e --arg old "$old" --arg new "$new" '
            (.labels | type) == "array" and
            any(.labels[]?; ((.name | ascii_downcase) == ($new | ascii_downcase))) and
            all(.labels[]?; ((.name | ascii_downcase) != ($old | ascii_downcase)))
        ' <<<"$labels_json" >/dev/null
    }

    verify_migration_before_remove() {
        local kind="$1" number="$2" old="$3" new="$4" phase="$5" labels_json
        if ! labels_json="$(read_item_labels "$kind" "$number")"; then
            die "could not read labels on $kind #$number $phase; refusing further maintenance"
        fi
        if ! migration_labels_present "$labels_json" "$old" "$new"; then
            die "could not verify '$old' and '$new' on $kind #$number $phase; refusing further maintenance"
        fi
    }

    verify_migration_after_remove() {
        local kind="$1" number="$2" old="$3" new="$4" labels_json
        if ! labels_json="$(read_item_labels "$kind" "$number")"; then
            die "could not re-read labels on $kind #$number after removing '$old'; refusing further maintenance"
        fi
        if ! migration_result_valid "$labels_json" "$old" "$new"; then
            die "migration verification failed on $kind #$number; '$new' must remain and '$old' must be absent"
        fi
    }

    # GitHub exposes no conditional mutation that means "remove OLD only while
    # NEW is still present." Keep the safe ordering explicit: add NEW, verify
    # both labels, re-read both labels immediately before removing OLD, remove
    # OLD, then verify the result. A concurrent writer can still change labels
    # between that final read and the remove request; the API has no transaction
    # or compare-and-swap token for this boundary, so the post-remove check can
    # detect a bad result but cannot undo a successful concurrent removal.
    apply_migrations() {
        local i old new number kind
        for i in "${!migration_old[@]}"; do
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            while IFS=$'\t' read -r -d '' number kind; do
                if [ "$kind" = pr ]; then
                    gh pr edit "$number" --repo "$repo" --add-label "$new" ||
                        die "could not add '$new' to pull request #$number; refusing further maintenance"
                    verify_migration_before_remove pr "$number" "$old" "$new" "after adding '$new'"
                    verify_migration_before_remove pr "$number" "$old" "$new" "immediately before removing '$old'"
                    gh pr edit "$number" --repo "$repo" --remove-label "$old" ||
                        die "could not remove '$old' from pull request #$number; refusing further maintenance"
                else
                    gh issue edit "$number" --repo "$repo" --add-label "$new" ||
                        die "could not add '$new' to issue #$number; refusing further maintenance"
                    verify_migration_before_remove issue "$number" "$old" "$new" "after adding '$new'"
                    verify_migration_before_remove issue "$number" "$old" "$new" "immediately before removing '$old'"
                    gh issue edit "$number" --repo "$repo" --remove-label "$old" ||
                        die "could not remove '$old' from issue #$number; refusing further maintenance"
                fi
                verify_migration_after_remove "$kind" "$number" "$old" "$new"
                printf -v quoted_old '%q' "$old"
                printf -v quoted_new '%q' "$new"
                output_emit 'Migrated %s -> %s on %s #%s\n' "$quoted_old" "$quoted_new" "$kind" "$number"
            done < <(
                jq -j --arg old "$old" '
                    .[] | select(any(.labels[]; ascii_downcase == ($old | ascii_downcase))) |
                    [(.number | tostring), (if .pull_request then "pr" else "issue" end)] |
                    join("\t") + "\u0000"
                ' "$associations_json"
            )
        done
    }

    parse_migrations
    read_live_labels
    load_inventory
    read_associations
    collect_candidates
    print_report

    if [ "$report_unregistered" = 1 ]; then
        exit 0
    fi

    validate_migrations
    if [ "${#candidates[@]}" -eq 0 ]; then
        exit 0
    fi

    safe_candidate_count=0
    associated_candidate_found=0
    for i in "${!candidates[@]}"; do
        if [ "${candidate_issues[$i]}" -eq 0 ] && [ "${candidate_prs[$i]}" -eq 0 ]; then
            safe_candidate_count=$((safe_candidate_count + 1))
        elif ! is_migration_source "${candidates[$i]}"; then
            printf -v quoted_name '%q' "${candidates[$i]}"
            output_emit 'Refused: %s (issues: %s, PRs: %s)\n' "$quoted_name" \
                "${candidate_issues[$i]}" "${candidate_prs[$i]}"
            associated_candidate_found=1
        fi
    done
    print_migration_plan

    if [ "$associated_candidate_found" -ne 0 ] && [ "${#migration_old[@]}" -eq 0 ]; then
        output_emit '%s\n' 'No labels deleted because the report contained associated labels.'
        exit 1
    fi
    if [ "$safe_candidate_count" -eq 0 ] && [ "${#migration_old[@]}" -eq 0 ]; then
        exit 1
    fi
    if ! confirm_prune; then
        exit 1
    fi

    if [ "${#migration_old[@]}" -gt 0 ]; then
        apply_migrations
    fi

    # The report is only a plan. First preflight every label that could be
    # deleted after migration, before deleting any one of them. An initially
    # associated non-migration label remains refused by name even if it later
    # becomes empty; only labels that were safe in the report (or were made safe
    # by a requested migration) enter prune_candidates.
    read_live_labels
    for name in "${candidates[@]}"; do
        if ! live_label_exists "$name"; then
            die "label '$name' disappeared during preflight; refusing all label deletion"
        fi
    done
    read_associations
    prune_candidates=()
    refused=0
    for i in "${!candidates[@]}"; do
        name="${candidates[$i]}"
        counts="$(association_counts "${candidates[$i]}")"
        IFS=$'\t' read -r issue_count pr_count <<<"$counts"
        if { [ "${candidate_issues[$i]}" -ne 0 ] || [ "${candidate_prs[$i]}" -ne 0 ]; } &&
            ! is_migration_source "$name"; then
            printf -v quoted_name '%q' "$name"
            output_emit 'Refused: %s (issues: %s, PRs: %s)\n' "$quoted_name" \
                "${candidate_issues[$i]}" "${candidate_prs[$i]}"
            refused=1
            continue
        fi
        if [ "$issue_count" -ne 0 ] || [ "$pr_count" -ne 0 ]; then
            die "association drift detected for '$name' before deletion; refusing all label deletion"
        fi
        prune_candidates+=("$name")
    done

    if [ "${#prune_candidates[@]}" -eq 0 ]; then
        exit 1
    fi
    if [ "$refused" -ne 0 ]; then
        output_emit '%s\n' 'No labels deleted because the preflight contained refused labels.'
        exit 1
    fi

    # GitHub label deletion is not conditional on the association count. Before
    # each DELETE, refresh the live label list and all associations, then check
    # every remaining prune candidate from that fresh snapshot. This catches a
    # new association or a failed read before the next deletion. A concurrent
    # writer can still add an association after the final read and before the
    # DELETE request; GitHub offers no transaction/compare-and-swap primitive,
    # so that narrow TOCTOU boundary is unavoidable and documented here.
    for name in "${prune_candidates[@]}"; do
        read_live_labels
        if ! live_label_exists "$name"; then
            die "label '$name' disappeared before deletion; refusing all further label deletion"
        fi
        read_associations
        for check_name in "${prune_candidates[@]}"; do
            counts="$(association_counts "$check_name")"
            IFS=$'\t' read -r issue_count pr_count <<<"$counts"
            if [ "$issue_count" -ne 0 ] || [ "$pr_count" -ne 0 ]; then
                die "association drift detected for '$check_name' before deleting '$name'; refusing all further label deletion"
            fi
        done
        if ! gh label delete "$name" --repo "$repo" --yes; then
            die "could not delete '$name'; refusing further maintenance"
        fi
        printf -v quoted_name '%q' "$name"
        output_emit 'Deleted: %s\n' "$quoted_name"
    done

    output_emit '%s\n' 'Label retirement complete.'
    exit 0
fi

action_banner setup "GitHub labels" "Registry-driven taxonomy with non-destructive updates"
kv "Repository" "$repo"

# Render first, then provision: the renderer fails closed (bad manifest, name
# or description over GitHub's limits, registry color drift) BEFORE any label
# reaches GitHub, so a bad vocabulary never half-provisions.
labels="$(node "$renderer" "${render_args[@]}")"

while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    if gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force >/dev/null; then
        checkline ok "Label" "$name"
    else
        rc=$?
        checkline no "Label" "$name (exit $rc)"
        exit "$rc"
    fi
done < <(printf '%s\n' "$labels")

output_summary "Label provisioning"
output_done "Starter labels are ready on $repo (existing labels left as-is)"
