#!/usr/bin/env bash
# A reviewed allowance can ignore only a live, unpatched, dev-only GHSA for
# at most 90 days. Shared by the gate, scheduled workflow and fix helper.
# Usage: security-audit.sh [audit | filter REPORT_JSON OUTPUT_JSON]
# filter revalidates allowances against REPORT_JSON and a fresh --prod audit,
# then removes allowed advisories for the remediation helper. It never edits
# the allowance file. Missing/empty allowances preserve the ordinary audit.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE=.security-audit-allowances.json
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() {
    echo "security-audit: $*" >&2
    exit 1
}

# Registry/network failures must not look like an empty advisory set.
read_audit() {
    local output="$1"
    shift
    local rc=0
    pnpm audit --audit-level=high "$@" --json >"$output" 2>"$WORK/audit.err" || rc=$?
    if ! jq -e 'type == "object" and (.advisories | type == "object") and (has("error") | not)' "$output" >/dev/null 2>&1; then
        cat "$WORK/audit.err" >&2
        die "invalid audit report (pnpm exit $rc); allowances cannot be verified"
    fi
}

mode="${1:-audit}"
case "$mode" in
audit) [ $# -le 1 ] || die 'usage: security-audit.sh [audit | filter REPORT_JSON OUTPUT_JSON]' ;;
filter) [ $# -eq 3 ] || die 'filter needs an input and output report' ;;
*) die "unknown mode '$mode'" ;;
esac

if [ -e "$FILE" ]; then
    jq -e 'type == "object" and (.allowances | type == "array")' "$FILE" >/dev/null 2>&1 ||
        die "malformed allowance file: $FILE must contain an allowances array"
    cp "$FILE" "$WORK/allowances.json"
else
    printf '{"allowances":[]}\n' >"$WORK/allowances.json"
fi

if [ "$(jq '.allowances | length' "$WORK/allowances.json")" -eq 0 ]; then
    if [ "$mode" = audit ]; then
        pnpm audit --audit-level=high
    else
        cp "$2" "$3"
    fi
    exit 0
fi

if [ "$mode" = audit ]; then
    read_audit "$WORK/full.json"
else
    cp "$2" "$WORK/full.json"
fi
read_audit "$WORK/prod.json" --prod

# jq handles calendar arithmetic in UTC on both macOS and Linux. Round-trip
# dates to reject impossible calendar dates rather than normalizing them.
jq --arg today "$(date -u +%Y-%m-%d)" --slurpfile full "$WORK/full.json" --slurpfile prod "$WORK/prod.json" '
    def text: if type == "string" then test("\\S") else false end;
    def day:
        if (if type == "string" then test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") else false end) then
            . as $date | try (($date + "T00:00:00Z" | fromdateiso8601) as $n
                | if ($n | strftime("%Y-%m-%d")) == $date then $n else null end) catch null
        else null end;
    ($today | day) as $now
    | .allowances | to_entries | map(
        .key as $index | .value as $e
        | if ($e | type) != "object" then
            {id: ("entry " + ($index | tostring)), failures: ["malformed entry"]}
          else
            ($e.added | day) as $added | ($e.expires | day) as $expires
            | [$full[0].advisories[] | select(.github_advisory_id == $e.ghsa)] as $live
            | {id: ($e.ghsa // ("entry " + ($index | tostring))), failures: [
                if ($e.ghsa | type) != "string" then "malformed GHSA id"
                elif ($e.ghsa | test("^GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$") | not) then "malformed GHSA id" else empty end,
                if ($e.package | text | not) then "missing package" else empty end,
                if ($e.reason | text | not) then "missing reason" else empty end,
                if ($e.tracking_issue | type) != "string" then "missing tracking issue URL"
                elif ($e.tracking_issue | test("^https://[^/[:space:]]+/[^[:space:]]+/issues/[0-9]+$") | not) then "malformed tracking issue URL" else empty end,
                if $added == null or $expires == null then "malformed added/expires date"
                else
                    (if $added > $now then "added date is in the future" else empty end),
                    (if $expires < $now then "expired" else empty end),
                    (if $expires < $added then "expires precedes added" else empty end),
                    (if $expires - $added > 90 * 86400 then "expiry window exceeds 90 days" else empty end)
                end,
                if ($live | length) == 0 then "stale (no live advisory)" else
                    (if any($live[]; .module_name != $e.package) then "package does not match advisory" else empty end),
                    (if any($live[];
                        if has("patched_versions") and .patched_versions == null then (.vulnerable_versions | text | not)
                        else ((.patched_versions | type) != "string") or .patched_versions == "" end
                    ) then "patch status is unknown" else empty end)
                end,
                if any($prod[0].advisories[]; .github_advisory_id == $e.ghsa) then "production reachable (not dev-only)" else empty end
            ]}
          end)
' "$WORK/allowances.json" >"$WORK/validated.json" || die 'malformed allowance entries or audit report'
jq -r '.[] | .id as $id | .failures[] | "security-audit: \($id): \(.)"' "$WORK/validated.json" >&2
jq -e 'all(.[]; (.failures | length) == 0)' "$WORK/validated.json" >/dev/null ||
    die 'allowance validation failed; no advisories ignored'
jq '[.[].id] | unique' "$WORK/validated.json" >"$WORK/ids.json"

# npm can synthesize a patched range from the vulnerable range even when
# no such release exists (braces <=3.0.3 -> >=3.0.4). Ask the registry for
# published versions matching each patched range, across all release lines.
# Only pnpm's explicit, query-bound no-match response proves absence; a
# network failure, unrecognized response, or unknown range cannot allow it.
jq -c '.advisories[] | {id: .github_advisory_id, package: .module_name, patched: .patched_versions, vulnerable: .vulnerable_versions}' "$WORK/full.json" | sort -u >"$WORK/patches.jsonl"
patch_failed=0
while IFS= read -r advisory; do
    id="$(printf '%s' "$advisory" | jq -r '.id')"
    package="$(printf '%s' "$advisory" | jq -r '.package')"
    patched="$(printf '%s' "$advisory" | jq -r '.patched')"
    jq -e --arg id "$id" 'index($id) != null' "$WORK/ids.json" >/dev/null || continue
    if printf '%s' "$advisory" | jq -e '.patched == null' >/dev/null; then
        # pnpm 12 can report null for an unpublished OR deprecated patch.
        # Independently prove every published release is vulnerable. Support
        # only plain < / <= release bounds; richer ranges or prereleases are
        # unknown, never guessed. jq compares numeric version triples.
        vulnerable="$(printf '%s' "$advisory" | jq -r '.vulnerable')"
        rc=0
        : >"$WORK/proof.json"
        pnpm view "$package" versions --json >"$WORK/versions.json" 2>"$WORK/view.err" || rc=$?
        if [ "$rc" -eq 0 ]; then
            jq -e --arg range "$vulnerable" '
                def release:
                    if type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$") then
                        split(".") | map(tonumber)
                        | if all(.[]; . <= 9007199254740991) then . else error("unsafe version integer") end
                    else error("unknown release version") end;
                if type != "array" or length == 0 then error("unknown versions") else . end
                | map(release) as $versions
                | ($range | capture("^\\s*(?<op><=|<)\\s*(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)\\s*$")) as $bound
                | if $bound == null then error("unknown vulnerable range") else . end
                | ($bound.version | release) as $upper
                | all($versions[]; if $bound.op == "<=" then . <= $upper else . < $upper end)
            ' "$WORK/versions.json" >"$WORK/proof.json" 2>/dev/null || rc=$?
            # capture emits no value for a nonmatching range; require proof.
            if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/proof.json")" = true ]; then continue; fi
        fi
        if [ "$rc" -eq 1 ] && [ "$(cat "$WORK/proof.json" 2>/dev/null)" = false ]; then
            echo "security-audit: $id: patched version exists outside $vulnerable" >&2
        else
            echo "security-audit: $id: patch status is unknown; registry proof failed" >&2
            cat "$WORK/view.err" >&2
        fi
        patch_failed=1
        continue
    fi
    [ "$patched" != '<0.0.0' ] || continue
    query="$package@$patched"
    rc=0
    pnpm view "$query" version --json >"$WORK/versions.json" 2>"$WORK/view.err" || rc=$?
    if [ "$rc" -ne 0 ] && jq -e --arg message "No matching version found for $query" \
        '.error.code == "ERR_PNPM_PACKAGE_NOT_FOUND" and .error.message == $message' "$WORK/versions.json" >/dev/null 2>&1; then
        continue
    fi
    if [ "$rc" -eq 0 ] && jq -e '(type == "string" and length > 0) or (type == "array" and length > 0 and all(.[]; type == "string" and length > 0))' "$WORK/versions.json" >/dev/null 2>&1; then
        echo "security-audit: $id: patched version exists for $query" >&2
    else
        echo "security-audit: $id: patch lookup failed for $query; absence cannot be verified" >&2
        cat "$WORK/view.err" >&2
    fi
    patch_failed=1
done <"$WORK/patches.jsonl"
[ "$patch_failed" -eq 0 ] || die 'allowance validation failed; no advisories ignored'

if [ "$mode" = filter ]; then
    jq --slurpfile ids "$WORK/ids.json" '.advisories |= with_entries(select(.value.github_advisory_id as $id | $ids[0] | index($id) | not))' "$WORK/full.json" >"$3"
else
    # Register GHSAs directly: pnpm 10's audit --ignore writes ignoreCves,
    # which cannot match them. Edit only the private copy. uv ships to every
    # consumer; pin a YAML 1.2 parser rather than depend on the optional yq binary.
    mkdir "$WORK/project"
    for file in package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc; do
        [ ! -f "$file" ] || cp "$file" "$WORK/project/$file"
    done
    [ -f "$WORK/project/pnpm-lock.yaml" ] || die 'pnpm-lock.yaml is required to apply allowances'
    while IFS= read -r id; do
        echo "security-audit: allowing $id (unpatched, dev-only, within expiry)" >&2
    done < <(jq -r '.[]' "$WORK/ids.json")
    # renovate: datasource=pypi depName=ruamel.yaml
    YAML_VERSION=0.19.1
    uv run --no-project --with "ruamel.yaml==$YAML_VERSION" python - "$WORK/project/pnpm-workspace.yaml" "$WORK/ids.json" <<'PYTHON'
import json
import sys
from pathlib import Path

from ruamel.yaml import YAML

path = Path(sys.argv[1])
yaml = YAML(typ="safe", pure=True)
config = yaml.load(path.read_text()) if path.exists() else None
if config is None:
    config = {}
if not isinstance(config, dict):
    raise ValueError("workspace configuration must be a mapping")
ids = json.loads(Path(sys.argv[2]).read_text())
# Keep the legacy key for pnpm 10/11. If the project already uses pnpm 12's
# canonical audit.ignore, merge that too so it cannot shadow the legacy key.
for key, field in [("auditConfig", "ignoreGhsas")] + ([("audit", "ignore")] if "audit" in config else []):
    section = config.setdefault(key, {})
    if section is None:
        section = config[key] = {}
    if not isinstance(section, dict):
        raise ValueError("audit configuration must be a mapping")
    existing = section.get(field)
    if existing is None:
        existing = []
    if not isinstance(existing, list) or not all(isinstance(value, str) for value in existing):
        raise ValueError("audit ignores must be a list of strings")
    section[field] = list(dict.fromkeys(existing + ids))
yaml.dump(config, path)
PYTHON
    (
        cd "$WORK/project"
        pnpm audit --audit-level=high
    )
fi
