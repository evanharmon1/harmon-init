#!/usr/bin/env bash
# security-audit-fix.sh — turn high/critical `pnpm audit` advisories into
# bounded security floors, and (in CI) into ONE rolling remediation PR.
#
# Raw `pnpm audit --fix` is not safe to commit as-is. Under pnpm 11 it writes
# one override per advisory into pnpm-workspace.yaml, keyed by the advisory's
# vulnerable range (`pkg@<1.2.3: ^1.2.3`):
#   - the selector spans every major below the patch, so it is not a floor
#     bounded to the major you resolve, and
#   - when the patch exists only in the next major it forces that major
#     (`pkg@<=8.5.1: ^9.0.0`) onto every dependent that asked for the old one.
# It can also re-indent or drop comments in the overrides map — including the
# template-owned floor markers.
#
# So this script runs `--fix` to learn which patched version pnpm picked; a
# floor can also come from the advisory's own published patched_versions on
# the installed line. It restores the workspace file byte-for-byte and writes
# its own entries through yq — it never parses or edits YAML text itself:
#
#   pkg@<major>: '>=x.y.z <next-major'      (0.x: pkg@0.m: '>=0.m.p <0.(m+1)')
#
# with a `# pkg@<major>: GHSA-….` comment, below the template-owned floor block
# (never inside it), then re-resolves the lockfile and re-audits. A narrower
# explicit cap on an existing local override for the package (`'>=1.5.0
# <1.8.0'`) is kept in place of <next-major. A fix it cannot express that way
# is REFUSED: crossing a major, an advisory with no patched version, a floor
# the template block owns (raise that upstream), a patched version at or above
# a kept local cap, an existing override for the package (bare `pkg`,
# `pkg@<major>`, any `pkg@<selector>`) whose cap the script cannot read — an
# exact pin, `~`, an x-range, a hyphen range, `||`, `^0.x`, a prerelease or
# build suffix, a `v` prefix — one placed after the key the script would
# rewrite (pnpm applies the last matching override), or any parent-scoped
# `parent>pkg` override, whatever its value (pnpm prefers it to `pkg@<major>`
# in either order; remove it). An exact `pkg@N` (N >= 1) or `pkg@0.M` key on
# another line is exempt by its key alone from every per-entry rule (the
# unreadable-cap refusal, the narrowest cap, the later-override refusal).
#
# Usage:
#   security-audit-fix.sh fix [--skip-refused] [--report FILE]
#       Strict by default: any refusal writes nothing (the workspace file and
#       lockfile keep their exact bytes) and exits 3. --skip-refused applies
#       every fix that is not refused and lists the refusals in the report
#       (the scheduled workflow's mode). A clean or already-remediated tree is
#       a no-op that exits 0.
#   security-audit-fix.sh publish DIR
#       CI only: apply DIR/changes.patch to the base branch, then force-push the
#       bot branch and open or update exactly ONE draft PR with DIR/report.md as
#       its body. Never merges, never writes the base branch. When GITHUB_SHA
#       (the commit the audit ran on) is set and the base has moved past it,
#       publishes nothing and exits 0: the next run re-audits.
#
# Exit codes: 0 done (clean, no-op, or applied), 1 operational failure
# (including an unsupported or unparseable pnpm version), 3 refused (strict fix only).
# Exit 3 also covers a pnpm-workspace.yaml yq cannot parse or write, and a
# template floor block with only one of its two marker lines.
# Depends on: pnpm 10–12, jq, yq (mikefarah v4); publish also needs git and gh.
# Fix reads pnpm --version once: 10 uses --fix, 11/12 use --fix=override.
# Malformed or unsupported versions fail before auditing or changing files.
# Unit-tested by harmon-init's scripts/test-security-audit-fix.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# Byte-order sorting: comm and the floor order must not depend on the locale.
export LC_ALL=C

WORKSPACE="pnpm-workspace.yaml"
LOCKFILE="pnpm-lock.yaml"
MANIFEST="package.json"
BLOCK_START='# --- harmon-init security floors (template-owned; updated by copier update) ---'
BLOCK_END='# --- end harmon-init security floors; repository-local floors go below this line ---'
BASE_BRANCH="main"
# One deterministic branch -> one rolling PR (see the force-push in cmd_publish).
FIX_BRANCH="bot/security-audit-fix"
PR_TITLE="fix(deps): raise security floors for high-severity advisories"

TAB="$(printf '\t')"
WORK=""
GT_TMP=""
SNAPSHOT_TAKEN=0
# cleanup — on ANY non-zero exit (a die, an unexpected command failure under
# set -e, an interrupt) put the pre-run bytes back before the snapshot is
# deleted; only a successful run keeps what it wrote.
cleanup() {
    _cl_rc=$?
    [ "$_cl_rc" -eq 0 ] || restore
    [ -n "$WORK" ] && rm -rf "$WORK"
    [ -n "$GT_TMP" ] && rm -f "$GT_TMP"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die() {
    echo "security-audit-fix: $*" >&2
    exit 1
}

note() {
    echo "security-audit-fix: $*"
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# ── Version helpers ─────────────────────────────────────────────────
# These work on clean scalars only — a value yq returned, a version pnpm
# reported — never on YAML text.

# floor_lower V [PLAIN] — the x.y.z lower bound V admits, or nothing when V is not a
# readable range. V is a version or a range: `^`, `~`, `=`, `v`, `>=`, strict
# `>` (completed as semver does: `>1.3.8` -> 1.3.9, `>1.3` -> 1.4.0, `>1` ->
# 2.0.0), an x-range, a hyphen range (`a - b`), a conjunction (the highest of
# its lower bounds), and `||` alternatives (the lowest lower bound across
# them); whitespace after an operator is allowed. An upper bound alone admits
# everything (0.0.0). PLAIN=1 rejects prerelease/build suffixes on lower bounds.
floor_lower() {
    printf '%s\n' "$1" | awk -v plain="${2:-0}" '
        # norm V STRICT — x.y.z from a full or partial version (x-range parts
        # count as omitted). STRICT bumps the last GIVEN part and zeroes the
        # rest, as semver completes `>1.3` (>=1.4.0) and `>1` (>=2.0.0).
        function norm(v, strict,   n, p, i, given) {
            if (plain && v ~ /[-+]/) return ""
            sub(/[-+].*$/, "", v)
            n = split(v, p, ".")
            if (n < 1 || n > 3) return ""
            given = 0
            for (i = 1; i <= 3; i++) {
                if (i > n || p[i] ~ /^[xX*]$/) { p[i] = 0; continue }
                if (p[i] !~ /^[0-9]+$/) return ""
                if (given == i - 1) given = i
            }
            if (strict) {
                if (given == 0) return ""
                p[given] = p[given] + 1
                for (i = given + 1; i <= 3; i++) p[i] = 0
            }
            return (p[1] + 0) "." (p[2] + 0) "." (p[3] + 0)
        }
        function lower(alt,   n, t, i, tok, v, best) {
            gsub(/>=[[:space:]]+/, ">=", alt); gsub(/<=[[:space:]]+/, "<=", alt)
            gsub(/>[[:space:]]+/, ">", alt); gsub(/<[[:space:]]+/, "<", alt)
            gsub(/\^[[:space:]]+/, "^", alt); gsub(/~[[:space:]]+/, "~", alt)
            gsub(/=[[:space:]]+/, "=", alt)
            if (index(alt, " - ")) alt = substr(alt, 1, index(alt, " - ") - 1)
            n = split(alt, t, /[[:space:]]+/); best = "0.0.0"
            for (i = 1; i <= n; i++) {
                tok = t[i]
                if (tok == "" || tok ~ /^</) continue
                if (tok ~ /^>=/) v = norm(substr(tok, 3), 0)
                else if (tok ~ /^>/) v = norm(substr(tok, 2), 1)
                else { sub(/^(\^|~|=|v)/, "", tok); v = norm(tok, 0) }
                if (v == "") return ""
                if (less(best, v)) best = v
            }
            return best
        }
        function less(a, b,   x, y, i) {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++) { if (x[i] + 0 != y[i] + 0) return x[i] + 0 < y[i] + 0 }
            return 0
        }
        {
            n = split($0, alts, /\|\|/); low = ""
            for (j = 1; j <= n; j++) {
                a = alts[j]; sub(/^[[:space:]]+/, "", a); sub(/[[:space:]]+$/, "", a)
                if (a == "") exit
                l = lower(a)
                if (l == "") exit
                if (low == "" || less(l, low)) low = l
            }
            if (low != "") print low
        }'
}

# floor_upper V — what the script can PROVE about the upper bound of an
# existing override V: "exclusive-x.y.z<TAB>token" for its tightest cap
# (`<1.8.0`, `<1.8` -> 1.8.0, `<=1.8.0` -> 1.8.1, `<=1.8` -> 1.9.0, `^1.4.0`
# -> 2.0.0), keeping the token for writing back; `-` when V provably has no
# cap; nothing when V is unreadable. V is read only when every token is a
# comparator (`>=`, `>`, `<`, `<=`) or a `^` on major 1+, each on a plain
# numeric version — any other shape (an exact or `=` pin, `~`, an x-range, a
# hyphen range, `||`, `^0.x`, a tag) carries an implicit cap this reader does
# not compute, so the caller refuses rather than widen it. Acceptance is
# positive: a version with a prerelease or build suffix, a `v` prefix or any
# trailing text is unreadable too, and so is any `||` — even unspaced, where
# it would otherwise glue two alternatives into one comparator token.
floor_upper() {
    printf '%s\n' "$1" | awk '
        # excl V INCL — x.y.z of a plain numeric version (1-3 parts and
        # nothing else), bumped past V when INCL; nothing otherwise.
        function excl(v, incl,   n, p, i) {
            if (v !~ /^[0-9]+$/ && v !~ /^[0-9]+\.[0-9]+$/ && v !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) return ""
            n = split(v, p, ".")
            for (i = n + 1; i <= 3; i++) p[i] = 0
            if (incl) { p[n] = p[n] + 1; for (i = n + 1; i <= 3; i++) p[i] = 0 }
            return (p[1] + 0) "." (p[2] + 0) "." (p[3] + 0)
        }
        function less(a, b,   x, y, i) {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++) { if (x[i] + 0 != y[i] + 0) return x[i] + 0 < y[i] + 0 }
            return 0
        }
        index($0, "||") { exit }
        {
            s = $0
            gsub(/>=[[:space:]]+/, ">=", s); gsub(/<=[[:space:]]+/, "<=", s)
            gsub(/>[[:space:]]+/, ">", s); gsub(/<[[:space:]]+/, "<", s)
            gsub(/\^[[:space:]]+/, "^", s)
            sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
            if (s == "") exit
            n = split(s, t, /[[:space:]]+/); best = ""; tok = ""
            for (i = 1; i <= n; i++) {
                if (t[i] ~ /^>=/) { if (excl(substr(t[i], 3), 0) == "") exit; continue }
                if (t[i] ~ /^>/) { if (excl(substr(t[i], 2), 0) == "") exit; continue }
                if (t[i] ~ /^<=/) v = excl(substr(t[i], 3), 1)
                else if (t[i] ~ /^</) v = excl(substr(t[i], 2), 0)
                else if (t[i] ~ /^\^/) {
                    v = excl(substr(t[i], 2), 0)
                    if (v == "" || v ~ /^0\./) exit
                    split(v, p, "."); v = (p[1] + 1) ".0.0"
                } else exit
                if (v == "") exit
                if (best == "" || less(v, best)) { best = v; tok = t[i] }
            }
            if (best != "") print best "\t" tok
            else print "-"
        }'
}

# major_key V — the semver-breaking line V belongs to: "4" for 4.17.21,
# "0.27" for 0.27.3 (a 0.x minor is a breaking boundary).
major_key() {
    awk -v v="$1" 'BEGIN { split(v, p, "."); if (p[1] == 0) print "0." p[2]; else print p[1] }'
}

# next_bound KEY — the exclusive upper bound of a major key: 4 -> 5, 0.27 -> 0.28.
next_bound() {
    awk -v k="$1" 'BEGIN { n = split(k, p, "."); if (n == 2) print "0." p[2] + 1; else print p[1] + 1 }'
}

# next_bound_start KEY — the first version of a major key's line: 4 -> 4.0.0,
# 0.27 -> 0.27.0.
next_bound_start() {
    awk -v k="$1" 'BEGIN { n = split(k, p, "."); if (n == 2) print "0." p[2] ".0"; else print p[1] ".0.0" }'
}

# version_ge A B — true when x.y.z A >= x.y.z B.
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit 0
    }'
}

# ── pnpm-workspace.yaml (through yq only) ────────────────────────────

# refuse MESSAGE — a whole-run refusal: restore the pre-run bytes, exit 3.
refuse() {
    echo "security-audit-fix: refused — $*" >&2
    restore
    exit 3
}

# overrides_tsv FILE — one "key<TAB>value" row per entry of the `overrides`
# map, read by yq. A file yq cannot parse, or an `overrides` that is not a
# map, is a refusal.
overrides_tsv() {
    _ot_type="$(yq '.overrides | type' "$1" 2>"$WORK/yq.err")" ||
        refuse "yq cannot parse $1: $(head -n 1 "$WORK/yq.err")"
    case "$_ot_type" in
    '!!map' | '!!null') ;;
    *) refuse "$1: overrides is $_ot_type, not a map" ;;
    esac
    yq -o=json -I=0 '.overrides // {}' "$1" 2>"$WORK/yq.err" |
        jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' ||
        refuse "yq cannot read the overrides of $1: $(head -n 1 "$WORK/yq.err")"
}

# check_markers — HAVE_MARKERS=1 when the workspace file carries the
# template-owned block's two marker lines exactly once each, start before end
# (the two fixed-string searches are the only place this script looks at line
# numbers); 0 when it carries neither. Anything else is a refusal: without
# both there is no telling where template floors end.
check_markers() {
    _cm_s="$(grep -cF -- "$BLOCK_START" "$WORKSPACE" || true)"
    _cm_e="$(grep -cF -- "$BLOCK_END" "$WORKSPACE" || true)"
    HAVE_MARKERS=0
    [ "$_cm_s" -eq 0 ] && [ "$_cm_e" -eq 0 ] && return 0
    [ "$_cm_s" -eq 1 ] && [ "$_cm_e" -eq 1 ] ||
        refuse "$WORKSPACE must carry both template floor markers exactly once (start: $_cm_s, end: $_cm_e)"
    [ "$(grep -nF -- "$BLOCK_START" "$WORKSPACE" | cut -d: -f1)" -lt \
        "$(grep -nF -- "$BLOCK_END" "$WORKSPACE" | cut -d: -f1)" ] ||
        refuse "$WORKSPACE has the template floor end marker above its start marker"
    HAVE_MARKERS=1
}

# marker_region — the exact text from the start-marker line through the
# end-marker line, inclusive (fixed-string matches; empty without markers).
marker_region() {
    awk -v bs="$BLOCK_START" -v be="$BLOCK_END" '
        index($0, bs) { on = 1 }
        on { print }
        on && index($0, be) { exit }
    ' "$WORKSPACE"
}

# template_keys — the keys the template-owned block holds: the text strictly
# between the two marker lines, comments dropped and the common indentation
# stripped, read by yq. No line numbers involved.
template_keys() {
    [ "$HAVE_MARKERS" -eq 1 ] || return 0
    marker_region | sed '1d;$d' | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' >"$WORK/block.txt" || true
    [ -s "$WORK/block.txt" ] || return 0
    _tk_ind="$(awk '{ match($0, /^[[:space:]]*/); if (min == "" || RLENGTH < min) min = RLENGTH } END { print min + 0 }' "$WORK/block.txt")"
    cut -c "$((_tk_ind + 1))-" "$WORK/block.txt" >"$WORK/block.yaml"
    yq -e 'type == "!!map"' "$WORK/block.yaml" >/dev/null 2>&1 ||
        refuse "yq cannot read the template floor block in $WORKSPACE as a map of floors"
    yq -o=json -I=0 'keys' "$WORK/block.yaml" | jq -r '.[]'
}

# own_tag KEY — the prefix of this script's advisory comment on KEY. The tag
# is what lets a rewrite drop only the script's own previous comment and keep
# every consumer comment, including one that happens to start with the key.
own_tag() {
    printf 'security-audit-fix: %s —' "$1"
}

# write_floor KEY FLOOR UPPER IDS — yq sets overrides[KEY] to
# '>=FLOOR UPPER' (single-quoted; UPPER is `<next-major` or a narrower local
# cap kept from the existing entry) with a tagged advisory head comment on the
# key. yq owns quoting, indentation, scalar style and every other comment. The
# key's existing head comment is kept except for this script's own tagged
# line: yq attaches the template end marker to the first key below it, so the
# marker can live there.
#
# Region-identity invariant, checked on every write: both marker lines still
# present once each and in order, the marker-to-marker text byte-identical to
# what it was before the write, and the written value readable back by yq.
# A key yq placed inside the block, a marker it moved or dropped, or a template
# floor it touched all break the identity — refusal, never a repair.
write_floor() {
    _wf_key="$1" _wf_val=">=$2 $3"
    _wf_tag="$(own_tag "$_wf_key")"
    _wf_head="$(K="$_wf_key" yq '.overrides[strenv(K)] | key | head_comment' "$WORKSPACE" 2>/dev/null || true)"
    _wf_comment="$(printf '%s\n' "$_wf_head" | awk -v own="$_wf_tag" 'index($0, own) != 1' | sed '/./,$!d')"
    _wf_comment="${_wf_comment:+$_wf_comment
}$_wf_tag $4"
    marker_region >"$WORK/region.before"
    K="$_wf_key" V="$_wf_val" C="$_wf_comment" yq -i '
        .overrides[strenv(K)] = strenv(V)
        | .overrides[strenv(K)] style = "single"
        | with(.overrides[strenv(K)] | key; . head_comment = strenv(C))
    ' "$WORKSPACE" 2>"$WORK/yq.err" || refuse "yq could not write $_wf_key to $WORKSPACE: $(head -n 1 "$WORK/yq.err")"
    check_region "writing $_wf_key"
    [ "$(K="$_wf_key" yq '.overrides[strenv(K)]' "$WORKSPACE" 2>/dev/null)" = "$_wf_val" ] ||
        refuse "$WORKSPACE does not read back '$_wf_val' for $_wf_key"
}

# check_region WHAT — the region-identity invariant after a yq edit, against
# $WORK/region.before: markers still present (once each, in order) when they
# were before, and the marker-to-marker text byte-identical. A difference in
# indentation only means yq re-indented the whole file (it writes two-space
# YAML), which would rewrite the template block — said as such.
check_region() {
    _cr_had="$HAVE_MARKERS"
    check_markers
    [ "$HAVE_MARKERS" = "$_cr_had" ] || refuse "$1 removed the template floor markers from $WORKSPACE"
    marker_region >"$WORK/region.after"
    cmp -s "$WORK/region.before" "$WORK/region.after" && return 0
    if [ "$(sed 's/^[[:space:]]*//' "$WORK/region.before")" = "$(sed 's/^[[:space:]]*//' "$WORK/region.after")" ]; then
        refuse "$1: $WORKSPACE is not two-space indented; yq would rewrite the template block — keep the template's two-space indentation with the markers indented inside overrides"
    fi
    refuse "$1 changed the template floor block in $WORKSPACE (yq placed it inside the block or moved a marker — keep the end marker indented inside overrides, as the template renders it)"
}

# release_age_excludes FILE — the minimumReleaseAgeExclude entries, one per
# line, read by yq (nothing when the key is absent or not a list).
release_age_excludes() {
    yq -o=json -I=0 '.minimumReleaseAgeExclude // []' "$1" 2>/dev/null |
        jq -r 'if type == "array" then .[] | tostring else empty end' || true
}

# carry_release_age_excludes — when a patched release is younger than pnpm's
# minimumReleaseAge, `--fix` also adds it to minimumReleaseAgeExclude, and the
# re-resolve needs that entry. The byte restore dropped it, so write each
# addition back with yq (outside the marker region; the invariant checks it).
carry_release_age_excludes() {
    release_age_excludes "$WORK/orig.$WORKSPACE" | sort -u >"$WORK/rae.before"
    release_age_excludes "$WORK/postfix.yaml" | sort -u | comm -13 "$WORK/rae.before" - >"$WORK/rae.added"
    [ -s "$WORK/rae.added" ] || return 0
    cut -f2 "$WORK/applied.tsv" | sort -u >"$WORK/applied-pkgs.txt"
    # The release lines floored this run: pkg@<major key of the installed
    # version> (a package can be floored on one line and refused on another).
    awk -F '\t' '{ v = $4; sub(/[-+].*$/, "", v); split(v, p, ".")
        print $2 "@" (p[1] == 0 ? "0." p[2] : p[1]) }' "$WORK/applied.tsv" | sort -u >"$WORK/applied-lines.txt"
    mv "$WORK/rae.added" "$WORK/rae.proposed"
    : >"$WORK/rae.added"
    while IFS= read -r _ra; do
        # An entry is `pkg@version` (or a bare name); only a release line this
        # run floors needs its young release — one for a refused fix is
        # dropped. A plain x.y.z version is joined on its release line; a bare
        # name or any other version form falls back to the package.
        _ra_pkg="$_ra" _ra_ver=""
        case "$_ra" in ?*@*) _ra_pkg="${_ra%@*}" _ra_ver="${_ra##*@}" ;; esac
        if grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$_ra_ver"; then
            _ra_set="$WORK/applied-lines.txt" _ra_want="$_ra_pkg@$(major_key "$_ra_ver")"
        else
            _ra_set="$WORK/applied-pkgs.txt" _ra_want="$_ra_pkg"
        fi
        if ! grep -qxF -- "$_ra_want" "$_ra_set"; then
            echo "$_ra" >>"$WORK/rae.dropped"
            note "dropped pnpm's minimumReleaseAgeExclude entry $_ra (no floor applied for $_ra_want)"
            continue
        fi
        echo "$_ra" >>"$WORK/rae.added"
        marker_region >"$WORK/region.before"
        X="$_ra" yq -i '.minimumReleaseAgeExclude = ((.minimumReleaseAgeExclude // []) + [strenv(X)])' "$WORKSPACE" 2>"$WORK/yq.err" ||
            refuse "yq could not add $_ra to minimumReleaseAgeExclude in $WORKSPACE: $(head -n 1 "$WORK/yq.err")"
        check_region "adding $_ra to minimumReleaseAgeExclude"
        note "kept pnpm's minimumReleaseAgeExclude entry $_ra (a patched release younger than the cooldown)"
    done <"$WORK/rae.proposed"
}

# ── fix ─────────────────────────────────────────────────────────────

snapshot() {
    for _sn in "$WORKSPACE" "$LOCKFILE" "$MANIFEST"; do
        cp -p "$_sn" "$WORK/orig.$_sn"
    done
    SNAPSHOT_TAKEN=1
}

restore() {
    [ "$SNAPSHOT_TAKEN" -eq 1 ] || return 0
    for _rs in "$WORKSPACE" "$LOCKFILE" "$MANIFEST"; do
        cmp -s "$WORK/orig.$_rs" "$_rs" || cat "$WORK/orig.$_rs" >"$_rs"
    done
}

# fail MESSAGE — restore the pre-run bytes, then die.
fail() {
    restore
    die "$*"
}

# audit_rows OUT — one row per vulnerable installed version of every
# high/critical advisory: id, package, severity, vulnerable range, installed
# version, the direct dependency that pulls it in, and the patched range. An
# advisory without a GHSA id (pnpm emits "") gets the synthetic npm-<number>.
audit_rows() {
    _ar_json="$WORK/audit.json"
    pnpm audit --audit-level=high --json >"$_ar_json" 2>"$WORK/audit.err" || true
    jq -e '.advisories | type == "object"' "$_ar_json" >/dev/null 2>&1 || {
        cat "$WORK/audit.err" >&2
        fail "pnpm audit did not return an advisory report (registry or network failure?)"
    }
    ./scripts/security-audit.sh filter "$_ar_json" "$WORK/filtered.json" ||
        fail "security audit allowances could not be verified"
    jq -r '
        .advisories[]
        | select(.severity == "high" or .severity == "critical")
        | . as $a
        | .findings[]
        | [ (if ($a.github_advisory_id // "") == "" then "npm-" + ($a.id | tostring)
             else $a.github_advisory_id end),
            $a.module_name, $a.severity, $a.vulnerable_versions, .version,
            ((.paths[0] // ".") | split(">") | .[1] // $a.module_name),
            ($a.patched_versions // "") ]
        | @tsv
    ' "$WORK/filtered.json" | sort -u >"$1"
}

# major_rows ID_COL PKG_COL VERSION_COL — "id pkg@major" for each TSV row on
# stdin, sorted unique (major as in major_key).
major_rows() {
    awk -F '\t' -v ic="$1" -v pc="$2" -v vc="$3" '{
        v = $vc; sub(/[-+].*$/, "", v); split(v, p, ".")
        print $ic " " $pc "@" (p[1] == 0 ? "0." p[2] : p[1])
    }' | sort -u
}

# advisory_need RANGE PATCHED INSTALLED — the lowest version that fixes an
# advisory for INSTALLED. A patched range with `||` contributes the lowest
# plain-release lower bound on the installed line strictly above INSTALLED;
# no such alternative prints `none`: the advisory has no patch on that line.
# Otherwise it is the patched range's lower
# bound, else the version the vulnerable range stops at (`<x.y.z` -> x.y.z,
# `<=x.y.z` -> the next patch); empty if neither says.
advisory_need() {
    case "$2" in
    *"||"*)
        _an_pick="none"
        _an_rest="$2||"
        while [ -n "$_an_rest" ]; do
            _an_alt="${_an_rest%%||*}"
            _an_rest="${_an_rest#*||}"
            _an_l="$(floor_lower "$_an_alt" 1)"
            if [ -n "$_an_l" ] && [ "$(major_key "$_an_l")" = "$(major_key "$3")" ] &&
                ! version_ge "$3" "$_an_l"; then
                if [ "$_an_pick" = none ] || version_ge "$_an_pick" "$_an_l"; then
                    _an_pick="$_an_l"
                fi
            fi
        done
        echo "$_an_pick"
        return 0
        ;;
    esac
    _an="$(floor_lower "$2")"
    if [ -n "$_an" ] && [ "$_an" != 0.0.0 ]; then
        echo "$_an"
        return 0
    fi
    printf '%s\n' "$1" | awk '{
        n = split($0, t, /[[:space:]]+/)
        for (i = n; i >= 1; i--) {
            if (t[i] ~ /^<=[0-9]/) { split(substr(t[i], 3), p, "."); print (p[1] + 0) "." (p[2] + 0) "." (p[3] + 1); exit }
            if (t[i] ~ /^<[0-9]/) { split(substr(t[i], 2), p, "."); print (p[1] + 0) "." (p[2] + 0) "." (p[3] + 0); exit }
        }
    }'
}

# published_patch PATCHED INSTALLED — print the concrete published patch selected
# by advisory_need, or fail when there is none. With no vulnerable range to
# infer from, an upper-bound-only alternative cannot masquerade as a patch;
# a union still selects the installed line's own alternative.
published_patch() {
    _pp="$(advisory_need "" "$1" "$2")"
    case "$_pp" in
    "" | none | 0.0.0) return 1 ;;
    esac
    printf '%s\n' "$_pp"
}

# covering_floor PKG RANGE PATCHED INSTALLED — the floor of a pnpm proposal that
# fixes this advisory row, matched by package and coverage rather than by
# pnpm's selector key: pnpm prunes an advisory whose range another advisory on
# the same package already covers, so one proposal can fix several. The
# proposals are pnpm's whole post-fix map, so an entry pnpm re-emitted
# identical to an existing one still counts. A proposal covers the row when
# its floor is at least what the advisory needs. Among covering proposals the
# lowest on the installed line wins. If none covers there but the advisory
# gives a concrete patched version on that line, use that as the floor;
# the lockfile re-resolve and re-audit must still prove it clears the row.
# Otherwise use the lowest proposal at all (a crossing the caller refuses);
# empty when none covers; `none` when no patched alternative is on that line.
covering_floor() {
    _cf_from="$(major_key "$4")"
    _cf_need="$(advisory_need "$2" "$3" "$4")"
    if [ "$_cf_need" = none ]; then
        echo none
        return 0
    fi
    _cf_in="" _cf_out=""
    while IFS="$TAB" read -r _cf_key _cf_val; do
        [ "${_cf_key%@*}" = "$1" ] || continue
        _cf_f="$(floor_lower "$_cf_val")"
        [ -n "$_cf_f" ] || continue
        if [ -n "$_cf_need" ]; then
            version_ge "$_cf_f" "$_cf_need" || continue
        elif [ "$_cf_key" != "$1@$2" ]; then
            continue
        fi
        if [ "$(major_key "$_cf_f")" = "$_cf_from" ]; then
            if [ -z "$_cf_in" ] || version_ge "$_cf_in" "$_cf_f"; then _cf_in="$_cf_f"; fi
        elif [ -z "$_cf_out" ] || version_ge "$_cf_out" "$_cf_f"; then
            _cf_out="$_cf_f"
        fi
    done <"$WORK/after.tsv"
    # A boundary inferred from the vulnerable range is not a published patch:
    # e.g. <=8.5.1 can need 8.5.2 while pnpm correctly proposes 9.0.0.
    _cf_published="$(published_patch "$3" "$4" || true)"
    if [ -z "$_cf_in" ] && [ -n "$_cf_published" ] && [ "$(major_key "$_cf_published")" = "$_cf_from" ]; then
        _cf_in="$_cf_published"
    fi
    echo "${_cf_in:-$_cf_out}"
}

# add_refusal ID PKG SEV VERSION REASON
add_refusal() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$WORK/refused.tsv"
}

# targets_of PKG [KEY] — "row<TAB>key<TAB>parent<TAB>value" (row = map
# order, from overrides_tsv rows on stdin; parent = 1 for a parent-scoped
# key) for every override whose target package is PKG: `pkg`,
# `pkg@<anything>`, and the last segment of a parent-scoped `parent>pkg…`.
# A `>` is a parent separator only when a package name follows it directly
# (a letter, digit, `@` or `_`) and it does not follow `@`, `|` or a space,
# so `pkg@>=1.2.0`, `pkg@<2 >1` and `pkg@<1||>2` stay selectors.
# Scoped names keep their leading `@`. With KEY (the `pkg@<major-key>` being
# written), a key of exactly that form for ANOTHER major key (`pkg@N`, or
# `pkg@0.M` on 0.x) is left out by its key alone, whatever its value: the key
# selects a line disjoint from KEY's, so it can neither cap KEY's line nor
# outrank KEY. Every other form stays in.
targets_of() {
    awk -F '\t' -v pkg="$1" -v key="${2:-}" '
        function target(k,   i, c, prev, next_c, t, j) {
            t = k; parent = 0
            for (i = length(k); i > 1; i--) {
                c = substr(k, i, 1); prev = substr(k, i - 1, 1); next_c = substr(k, i + 1, 1)
                if (c == ">" && prev != "@" && prev != "|" && prev != " " && next_c ~ /[A-Za-z0-9@_]/) { t = substr(k, i + 1); parent = 1; break }
            }
            if (substr(t, 1, 1) == "@") { j = index(substr(t, 2), "@"); return j ? substr(t, 1, j) : t }
            j = index(t, "@"); return j ? substr(t, 1, j - 1) : t
        }
        function disjoint(k,   m) {
            if (key == "" || k == key || index(k, pkg "@") != 1) return 0
            m = substr(k, length(pkg) + 2)
            return m ~ /^[1-9][0-9]*$/ || m ~ /^0\.[0-9]+$/
        }
        target($1) == pkg && !disjoint($1) { print NR "\t" $1 "\t" parent "\t" $2 }'
}

# refuse_key KEY REASON — refuse every candidate advisory row for KEY.
refuse_key() {
    awk -F '\t' -v k="$1" '$1 == k { print $3 "\t" $4 "\t" $5 "\t" $6 }' "$WORK/candidates.tsv" |
        while IFS="$TAB" read -r _rk_id _rk_pkg _rk_sev _rk_ver; do
            add_refusal "$_rk_id" "$_rk_pkg" "$_rk_sev" "$_rk_ver" "$2"
        done
}

cmd_fix() {
    _skip_refused=0 _report=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --skip-refused) _skip_refused=1 ;;
        --report)
            [ $# -ge 2 ] || die "--report needs a file"
            _report="$2"
            shift
            ;;
        *) die "unknown fix option '$1'" ;;
        esac
        shift
    done
    need_bin pnpm
    _pnpm_version="$(pnpm --version)" || die "could not read pnpm version: $_pnpm_version"
    [[ "$_pnpm_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
        die "unparseable pnpm version '$_pnpm_version' (supported majors: 10–12)"
    _pnpm_major="${_pnpm_version%%.*}"
    case "$_pnpm_major" in
    10) _pnpm_fix=--fix ;;
    11 | 12) _pnpm_fix=--fix=override ;;
    *) die "unsupported pnpm version '$_pnpm_version' (supported majors: 10–12)" ;;
    esac
    need_bin jq
    # Every pnpm-workspace.yaml read and write goes through yq; without it the
    # script cannot touch the file safely, so it refuses before doing anything.
    command -v yq >/dev/null 2>&1 || {
        echo "security-audit-fix: refused — yq (mikefarah v4) is required to edit $WORKSPACE; in CI the" \
            ".github/actions/setup action installs the pinned yq with lint-tools: \"true\"" >&2
        exit 3
    }
    for _f in "$WORKSPACE" "$LOCKFILE" "$MANIFEST"; do
        [ -f "$_f" ] || die "$_f not found — run from a pnpm project with a committed lockfile"
    done
    WORK="$(mktemp -d)"
    : >"$WORK/refused.tsv"
    : >"$WORK/applied.tsv"
    : >"$WORK/new-rows.tsv"
    : >"$WORK/rae.added"
    : >"$WORK/rae.dropped"
    snapshot

    audit_rows "$WORK/rows.tsv"
    if [ ! -s "$WORK/rows.tsv" ]; then
        note "no high or critical advisories — nothing to fix"
        [ -z "$_report" ] || write_report "$_report" "$WORK/rows.tsv"
        return 0
    fi
    check_markers
    overrides_tsv "$WORKSPACE" >/dev/null
    template_keys | sort -u >"$WORK/template-keys.txt"

    note "running pnpm audit $_pnpm_fix to learn the patched versions"
    pnpm audit "$_pnpm_fix" --audit-level=high >"$WORK/fix.log" 2>&1 || {
        cat "$WORK/fix.log" >&2
        fail "pnpm audit $_pnpm_fix failed"
    }
    # What pnpm proposed = the entries whose value differs from the original
    # map, both read by yq.
    overrides_tsv "$WORKSPACE" | sort -u >"$WORK/after.tsv"
    cp "$WORKSPACE" "$WORK/postfix.yaml"
    # --fix's own edit is never kept: it can reformat or drop comments,
    # including the template-owned markers.
    restore
    : >"$WORK/rae.added"
    overrides_tsv "$WORKSPACE" >"$WORK/current.tsv"

    # Each advisory row -> a candidate floor "key<TAB>floor<TAB>id", or a refusal.
    : >"$WORK/candidates.tsv"
    while IFS="$TAB" read -r _id _pkg _sev _range _ver _direct _patched; do
        _have="$(floor_lower "$_ver")"
        if [ -z "$_have" ]; then
            add_refusal "$_id" "$_pkg" "$_sev" "$_ver" "could not read the installed version $_ver"
            continue
        fi
        _from="$(major_key "$_have")"
        _floor="$(covering_floor "$_pkg" "$_range" "$_patched" "$_have")"
        if [ "$_floor" = none ]; then
            add_refusal "$_id" "$_pkg" "$_sev" "$_ver" "no patched range on major $_from (patched: $_patched) — upgrade \`$_direct\` deliberately"
            continue
        fi
        if [ -z "$_floor" ]; then
            if published_patch "$_patched" "$_have" >/dev/null; then
                add_refusal "$_id" "$_pkg" "$_sev" "$_ver" "pnpm audit --fix made no proposal on major $_from that covers it (patched: $_patched) — upgrade \`$_direct\` deliberately"
            else
                add_refusal "$_id" "$_pkg" "$_sev" "$_ver" "pnpm audit --fix proposed no override that covers it (no patched version published for $_range)"
            fi
            continue
        fi
        _to="$(major_key "$_floor")"
        if [ "$_from" != "$_to" ]; then
            add_refusal "$_id" "$_pkg" "$_sev" "$_ver" "the fix ($_floor) crosses from major $_from to major $_to; direct dependency \`$_direct\` resolves the $_from line — upgrade it deliberately"
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_pkg@$_from" "$_floor" "$_id" "$_pkg" "$_sev" "$_ver" >>"$WORK/candidates.tsv"
    done <"$WORK/rows.tsv"

    # One floor per key: the highest patched version any advisory needs.
    sort -t "$TAB" -k1,1 "$WORK/candidates.tsv" | cut -f1 | uniq >"$WORK/keys.txt"
    _relock=0
    while IFS= read -r _key; do
        [ -n "$_key" ] || continue
        _floor="" _ids=""
        while IFS="$TAB" read -r _k _f _id _rest; do
            [ "$_k" = "$_key" ] || continue
            if [ -z "$_floor" ] || ! version_ge "$_floor" "$_f"; then _floor="$_f"; fi
            case ", $_ids," in *", $_id,"*) ;; *) _ids="${_ids:+$_ids, }$_id" ;; esac
        done <"$WORK/candidates.tsv"
        if grep -qxF -- "$_key" "$WORK/template-keys.txt"; then
            refuse_key "$_key" "\`$_key\` is a template-owned floor — raise it upstream in harmon-init, not locally"
            continue
        fi
        _bound="$(next_bound "${_key##*@}")"
        _line_start="$(next_bound_start "${_key##*@}")"
        _next_start="$(next_bound_start "$_bound")"
        # There is no keep-as-is branch: every floor this script touches is
        # written as '>=LOWER UPPER' for its own major, so a floor can never
        # express a crossing. One rule covers every existing override whose
        # target package is this one — bare `pkg`, `pkg@<major>`, any
        # `pkg@<selector>`, or a parent-scoped `parent>pkg…` — because pnpm 11
        # applies the LAST matching override in map order, selector keys
        # included (probed on pnpm 11.28.5), so any of them can cap this line:
        #   - each value must be readable by floor_upper (an exact pin, `~`, an
        #     x-range, a hyphen range, `||`, `^0.x`, a suffixed version… are
        #     not), or the key is refused: <next-major would widen its cap;
        #   - LOWER is max(proposal, KEY's own entry's lower bound on this
        #     major) — never lowered. No other entry's lower bound raises it
        #     (see below);
        #   - UPPER is <next-major unless one provably caps this line lower:
        #     the narrowest such cap is kept, and the fix refused when the
        #     patched version is at or above it;
        #   - one placed AFTER an existing key outranks the rewrite, which is
        #     refused. (A new key is appended at the end of the map by yq.)
        #   - a parent-scoped `parent>pkg…` entry outranks `pkg@<major>` for
        #     that parent's dependency in EITHER map order (probed on pnpm
        #     11.28.5: `make-dir>semver` beat `semver@7` both ways), so the
        #     written floor is not provably effective: refused, wherever the
        #     entry sits, before any of the checks above.
        # Selectors are not matched against versions. For CAPS and refusals an
        # entry is judged as if it applied to the whole line, which can only
        # refuse more, never less — so an earlier entry's narrower cap is
        # honoured even when its selector does not reach this line
        # (`pkg@<1.2.0: '>=1.0.0 <1.2.0'` caps a pkg@1 floor). For the LOWER
        # bound only KEY's own entry counts: a selector need not apply to the
        # installed version. KEY never sits before a non-exempt entry for the
        # package (a later one is refused, a new KEY is appended last), so
        # it wins under last-match and supersedes an earlier selector's lower
        # bound on this line — deliberately: the floor is still at or above
        # the patched version, which the re-audit verifies. The one exception
        # is by key: an entry whose key is another line's exact
        # `pkg@<major-key>` is left out (targets_of), whatever its value.
        _upper="<$_bound" _cap_v="" _cap_span="" _blocked=""
        targets_of "${_key%@*}" "$_key" <"$WORK/current.tsv" >"$WORK/targets.tsv"
        _parent="$(awk -F '\t' '$3 == 1 { print $2; exit }' "$WORK/targets.tsv")"
        if [ -n "$_parent" ]; then
            refuse_key "$_key" "a parent-scoped \`$_parent\` override for \`${_key%@*}\` outranks \`$_key\` — remove it deliberately"
            continue
        fi
        _key_row="$(awk -F '\t' -v k="$_key" '$2 == k { print $1; exit }' "$WORK/targets.tsv")"
        if [ -n "$_key_row" ]; then
            _later="$(awk -F '\t' -v r="$_key_row" '$1 + 0 > r + 0 { print $2; exit }' "$WORK/targets.tsv")"
            if [ -n "$_later" ]; then
                refuse_key "$_key" "a later \`$_later\` override for \`${_key%@*}\` takes precedence over \`$_key\` — reorder or remove it deliberately"
                continue
            fi
        fi
        while IFS="$TAB" read -r _ _ek _ _existing; do
            _span="\`$_ek: '$_existing'\`"
            _cap="$(floor_upper "$_existing")"
            if [ -z "$_cap" ]; then
                _blocked="the local override $_span has a cap the script cannot read — raise it deliberately"
                break
            fi
            _old=""
            [ "$_ek" != "$_key" ] || _old="$(floor_lower "$_existing")"
            if [ -n "$_old" ] && [ "$(major_key "$_old")" = "${_key##*@}" ] && version_ge "$_old" "$_floor"; then
                _floor="$_old"
            fi
            [ "$_cap" != - ] || continue
            _v="${_cap%%"$TAB"*}"
            # Only a cap inside this line narrows it: one at or past the next
            # major is the canonical bound, one at or below the line's start
            # lies in another major.
            if version_ge "$_v" "$_next_start" || version_ge "$_line_start" "$_v"; then
                continue
            fi
            if [ -z "$_cap_v" ] || ! version_ge "$_v" "$_cap_v"; then
                _cap_v="$_v" _upper="${_cap#*"$TAB"}" _cap_span="$_span"
            fi
        done <"$WORK/targets.tsv"
        if [ -z "$_blocked" ] && [ -n "$_cap_v" ] && version_ge "$_floor" "$_cap_v"; then
            _blocked="the local override $_cap_span caps \`${_key%@*}\` below the patched version $_floor — widen it deliberately"
        fi
        if [ -n "$_blocked" ]; then
            refuse_key "$_key" "$_blocked"
            continue
        fi
        write_floor "$_key" "$_floor" "$_upper" "$_ids"
        # An advisory is still reported against this key, so the lockfile is
        # out of step with the floor either way: always re-resolve.
        _relock=1
        _outcome="floor \`$_key: '>=$_floor $_upper'\`"
        awk -F '\t' -v k="$_key" -v o="$_outcome" '$1 == k { print $3 "\t" $4 "\t" $5 "\t" $6 "\t" o }' \
            "$WORK/candidates.tsv" >>"$WORK/applied.tsv"
    done <"$WORK/keys.txt"

    if [ -s "$WORK/refused.tsv" ]; then
        sort -u -o "$WORK/refused.tsv" "$WORK/refused.tsv"
        while IFS="$TAB" read -r _id _pkg _sev _ver _why; do
            echo "security-audit-fix: refused $_id ($_pkg $_ver, $_sev): $_why" >&2
        done <"$WORK/refused.tsv"
        if [ "$_skip_refused" -eq 0 ]; then
            restore
            : >"$WORK/applied.tsv"
            [ -z "$_report" ] || write_report "$_report" "$WORK/rows.tsv"
            echo "security-audit-fix: refused — nothing written (rerun with --skip-refused to apply the rest)" >&2
            exit 3
        fi
    fi

    if [ "$_relock" -eq 1 ]; then
        carry_release_age_excludes
        note "re-resolving $LOCKFILE"
        pnpm install --lockfile-only --ignore-scripts >"$WORK/install.log" 2>&1 || {
            cat "$WORK/install.log" >&2
            fail "pnpm install --lockfile-only failed with the new floors — nothing kept"
        }
        audit_rows "$WORK/after-rows.tsv"
        # Cleared is judged per (advisory, package, major): one advisory can
        # span two installed majors, and a row left standing on a REFUSED major
        # says nothing about the floor written for the other one.
        major_rows 1 2 4 <"$WORK/applied.tsv" >"$WORK/applied-pairs.txt"
        major_rows 1 2 5 <"$WORK/after-rows.tsv" | comm -12 - "$WORK/applied-pairs.txt" >"$WORK/still.txt"
        [ ! -s "$WORK/still.txt" ] ||
            fail "the new floors did not clear: $(tr '\n' ' ' <"$WORK/still.txt")— nothing kept"
        # An advisory that appears only after the re-resolve is not this run's
        # to fix, but the PR body must not hide it.
        major_rows 1 2 5 <"$WORK/rows.tsv" >"$WORK/before-pairs.txt"
        while IFS="$TAB" read -r _id _pkg _sev _range _ver _direct _patched; do
            _pair="$(printf '%s\t%s\t%s\n' "$_id" "$_pkg" "$_ver" | major_rows 1 2 3)"
            grep -qxF "$_pair" "$WORK/before-pairs.txt" ||
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_id" "$_pkg" "$_sev" "$_range" "$_ver" "$_direct" >>"$WORK/new-rows.tsv"
        done <"$WORK/after-rows.tsv"
        note "$WORKSPACE floors in place and $LOCKFILE re-resolved"
    fi
    [ -z "$_report" ] || write_report "$_report" "$WORK/rows.tsv"
    return 0
}

# cell TEXT — TEXT safe inside a Markdown table cell: `|` (a `||` patched
# range in a refusal reason, say) is escaped so it cannot split the row.
cell() {
    printf '%s' "$1" | sed 's/|/\\|/g'
}

# write_report FILE ROWS — the remediation PR body: every advisory with the
# floor applied or the reason it was refused. Package names are code spans so
# a scoped name (@scope/pkg) never renders as a mention.
write_report() {
    _wr_file="$1" _wr_rows="$2"
    {
        echo "## Dependency audit remediation"
        echo
        echo "Opened by the scheduled \`security-audit-fix\` workflow from \`task security:audit:fix\`."
        echo "Each floor is bounded to the major the lockfile already resolves, and sits below the"
        echo "template-owned floor block in \`$WORKSPACE\`. This PR is never merged automatically."
        echo
        if [ ! -s "$_wr_rows" ]; then
            echo "No high or critical advisories."
            return 0
        fi
        echo "| Advisory | Package | Severity | Installed | Outcome |"
        echo "|---|---|---|---|---|"
        while IFS="$TAB" read -r _id _pkg _sev _range _ver _direct _patched; do
            _out="$(awk -F '\t' -v i="$_id" -v p="$_pkg" -v v="$_ver" \
                '$1 == i && $2 == p && $4 == v { print $5; exit }' "$WORK/applied.tsv")"
            [ -n "$_out" ] || _out="$(awk -F '\t' -v i="$_id" -v p="$_pkg" -v v="$_ver" \
                '$1 == i && $2 == p && $4 == v { print "**refused:** " $5; exit }' "$WORK/refused.tsv")"
            [ -n "$_out" ] || _out="not applied (another fix in this run was refused)"
            printf '| %s | `%s` | %s | %s | %s |\n' "$(cell "$_id")" "$(cell "$_pkg")" "$(cell "$_sev")" \
                "$(cell "$_ver")" "$(cell "$_out")"
        done <"$_wr_rows"
        if [ -s "$WORK/rae.added" ]; then
            echo
            echo "Kept from \`pnpm audit --fix\` in \`minimumReleaseAgeExclude\` (patched releases younger than"
            echo "pnpm's release-age cooldown, needed to resolve the floors):"
            echo
            while IFS= read -r _ra; do
                printf -- '- `%s`\n' "$_ra"
            done <"$WORK/rae.added"
        fi
        if [ -s "$WORK/rae.dropped" ]; then
            echo
            echo "Dropped from \`pnpm audit --fix\`'s \`minimumReleaseAgeExclude\` additions (their fix was refused,"
            echo "so nothing here needs the young release):"
            echo
            while IFS= read -r _ra; do
                printf -- '- `%s`\n' "$_ra"
            done <"$WORK/rae.dropped"
        fi
        if [ -s "$WORK/new-rows.tsv" ]; then
            echo
            echo "Advisories that appeared only after the lockfile re-resolve:"
            echo
            while IFS="$TAB" read -r _id _pkg _sev _range _ver _direct; do
                printf -- '- %s — `%s` %s (%s): new, not fixed by this run\n' "$_id" "$_pkg" "$_ver" "$_sev"
            done <"$WORK/new-rows.tsv"
        fi
        if [ -s "$WORK/refused.tsv" ]; then
            echo
            echo "Refused fixes were not applied: they need a deliberate upgrade or an upstream"
            echo "template fix, and \`task security:audit\` keeps failing until they land."
        fi
    } >"$_wr_file"
}

# ── publish (CI only) ──────────────────────────────────────────────

# git_remote ARGS… — a git command that talks to origin, authenticated with
# GH_TOKEN through a mode-600 file read by a one-shot credential helper, so the
# token reaches neither argv nor .git/config.
git_remote() {
    if [ -n "${GH_TOKEN:-}" ]; then
        GT_TMP="$(mktemp)"
        chmod 600 "$GT_TMP"
        printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN" >"$GT_TMP"
        _gr_rc=0
        env -u GH_TOKEN -u GITHUB_TOKEN \
            git -c credential.helper= -c credential.helper="!f() { cat \"$GT_TMP\"; }; f" "$@" || _gr_rc=$?
        rm -f "$GT_TMP"
        GT_TMP=""
        return $_gr_rc
    fi
    git "$@"
}

# configure_identity — commit as the CI GitHub App (no-op without GH_APP_SLUG).
configure_identity() {
    _ci_slug="${GH_APP_SLUG:-}"
    [ -n "$_ci_slug" ] || return 0
    case "$_ci_slug" in
    *[!a-zA-Z0-9-]*) die "refusing unexpected GitHub App slug '$_ci_slug'" ;;
    esac
    _ci_uid="$(gh api "/users/${_ci_slug}[bot]" --jq '.id')" ||
        die "could not resolve the user id for '${_ci_slug}[bot]'"
    case "$_ci_uid" in
    "" | *[!0-9]*) die "unexpected user id '$_ci_uid' for '${_ci_slug}[bot]'" ;;
    esac
    git config user.name "${_ci_slug}[bot]"
    git config user.email "${_ci_uid}+${_ci_slug}[bot]@users.noreply.github.com"
}

open_pr_number() {
    _pn="$(gh pr list --head "$FIX_BRANCH" --base "$BASE_BRANCH" --state open \
        --json number,isCrossRepository \
        --jq 'map(select(.isCrossRepository == false)) | .[0].number // empty')" ||
        die "could not list open PRs for $FIX_BRANCH"
    case "$_pn" in
    *[!0-9]*) die "unexpected PR number '$_pn' for $FIX_BRANCH" ;;
    esac
    printf '%s\n' "$_pn"
}

# pr_state N — "<headRefOid> <isDraft>" for PR N.
pr_state() {
    gh pr view "$1" --json headRefOid,isDraft \
        --jq '[.headRefOid, (.isDraft | tostring)] | join(" ")' 2>/dev/null
}

# ensure_pr_draft N [HEAD] — fail closed unless PR N is draft (converting it
# back when a human had promoted an older head) and, when HEAD is given,
# points at exactly that commit.
ensure_pr_draft() {
    _ed_pr="$1" _ed_expected="${2:-}"
    _ed_state="$(pr_state "$_ed_pr")" || die "could not read the state of PR #$_ed_pr"
    if [ "${_ed_state#* }" = "false" ]; then
        note "returning PR #$_ed_pr to draft"
        gh pr ready --undo "$_ed_pr" || die "could not return PR #$_ed_pr to draft"
        _ed_state="$(pr_state "$_ed_pr")" || die "could not confirm PR #$_ed_pr became draft"
    fi
    [ "${_ed_state#* }" = "true" ] || die "PR #$_ed_pr is not a draft (state '$_ed_state')"
    # GitHub can report the previous head for a few seconds after a push:
    # poll a bounded number of times, then fail closed.
    _ed_try=1
    while [ -n "$_ed_expected" ] && [ "${_ed_state%% *}" != "$_ed_expected" ]; do
        [ "$_ed_try" -lt 6 ] ||
            die "PR #$_ed_pr points at ${_ed_state%% *}, not the pushed head $_ed_expected (after $_ed_try reads)"
        sleep 5
        _ed_try=$((_ed_try + 1))
        _ed_state="$(pr_state "$_ed_pr")" || die "could not read the state of PR #$_ed_pr"
        [ "${_ed_state#* }" = "true" ] || die "PR #$_ed_pr is not a draft (state '$_ed_state')"
    done
}

# remote_fix_tree — the tree the pushed bot branch holds, or empty when the
# branch does not exist. ls-remote tells "absent" (2) from "unreachable".
remote_fix_tree() {
    _rt_rc=0
    git_remote ls-remote --exit-code --heads origin "$FIX_BRANCH" >/dev/null 2>&1 || _rt_rc=$?
    case "$_rt_rc" in
    0) ;;
    2) return 0 ;;
    *) die "could not reach origin to look for $FIX_BRANCH (git exit $_rt_rc)" ;;
    esac
    git_remote fetch --quiet origin "+refs/heads/$FIX_BRANCH:refs/remotes/origin/$FIX_BRANCH" ||
        die "could not fetch $FIX_BRANCH"
    git rev-parse --verify --quiet "refs/remotes/origin/$FIX_BRANCH^{tree}"
}

cmd_publish() {
    _dir="${1:-}"
    [ -n "$_dir" ] || die "usage: security-audit-fix.sh publish DIR"
    need_bin git
    need_bin gh
    [ -s "$_dir/changes.patch" ] || die "$_dir/changes.patch is missing or empty — nothing to publish"
    [ -s "$_dir/report.md" ] || die "$_dir/report.md is missing — refusing to open a PR without its advisory list"
    [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
    _head="$(git rev-parse --abbrev-ref HEAD)"
    [ "$_head" = "$BASE_BRANCH" ] || die "HEAD is '$_head', not '$BASE_BRANCH'"
    # Publish only onto the commit the audit job ran on: the patch was
    # verified against GITHUB_SHA, not against whatever the base holds now.
    # Unset (a local run): no audited commit to compare against.
    if [ -n "${GITHUB_SHA:-}" ]; then
        _base_sha="$(git rev-parse HEAD)"
        if [ "$_base_sha" != "$GITHUB_SHA" ]; then
            _moved="$BASE_BRANCH moved since the audit ($GITHUB_SHA -> $_base_sha) — nothing published; the next run re-audits"
            note "$_moved"
            # Under Actions, also an annotation, so the skip shows on the run.
            [ "${GITHUB_ACTIONS:-}" != true ] || echo "::notice::security-audit-fix: $_moved"
            return 0
        fi
    fi

    # The patch was produced by a job that ran package tooling; accept it only
    # when it touches exactly the two files a floor change may touch.
    _paths="$(git apply --numstat "$_dir/changes.patch" | cut -f3 | sort -u)" ||
        die "changes.patch is not a valid patch"
    while IFS= read -r _p; do
        case "$_p" in
        "$WORKSPACE" | "$LOCKFILE") ;;
        *) die "changes.patch touches '$_p' — only $WORKSPACE and $LOCKFILE may change" ;;
        esac
    done <<EOF
$_paths
EOF

    configure_identity
    env -u GH_TOKEN -u GITHUB_TOKEN git checkout -B "$FIX_BRANCH" "$BASE_BRANCH" >/dev/null
    git apply --index "$_dir/changes.patch" || die "changes.patch does not apply to $BASE_BRANCH"
    # The numstat above reads the patch; this reads what it actually staged:
    # only in-place modifications of the two files, same mode — no rename,
    # copy, add, delete or mode change.
    git diff --cached --raw --no-renames >"$_dir/staged.raw" || die "could not read the staged change"
    [ -s "$_dir/staged.raw" ] || die "changes.patch staged nothing"
    while IFS="$TAB" read -r _st_meta _st_path; do
        read -r _st_old _st_new _ _ _st_status <<EOF
$_st_meta
EOF
        # Raw format: ":<old mode> <new mode> <old sha> <new sha> <status>".
        if [ "$_st_status" != M ] || [ "${_st_old#:}" != 100644 ] || [ "$_st_new" != 100644 ] ||
            { [ "$_st_path" != "$WORKSPACE" ] && [ "$_st_path" != "$LOCKFILE" ]; }; then
            die "changes.patch staged '$_st_meta $_st_path' — only in-place modifications of $WORKSPACE and $LOCKFILE are allowed"
        fi
    done <"$_dir/staged.raw"
    env -u GH_TOKEN -u GITHUB_TOKEN git commit -m "$PR_TITLE" >/dev/null

    _open="$(open_pr_number)"
    _tree="$(git rev-parse 'HEAD^{tree}')"
    # A plain assignment, so a die inside remote_fix_tree stops the run.
    _remote_tree=""
    if [ -n "$_open" ]; then
        _remote_tree="$(remote_fix_tree)"
    fi
    if [ -n "$_open" ] && [ "$_remote_tree" = "$_tree" ]; then
        # Same floors already on the open PR: refresh its body (advisory list),
        # but do not push — that would reset review and re-run CI for nothing.
        note "PR #$_open already carries these floors — refreshing its body only"
        gh pr edit "$_open" --title "$PR_TITLE" --body-file "$_dir/report.md" ||
            die "could not update PR #$_open"
        return 0
    fi

    # Demote before replacing the head so an unreviewed revision is never
    # exposed as ready-for-review during the push.
    [ -z "$_open" ] || ensure_pr_draft "$_open"
    # Force-push: the bot branch is rebuilt from the base every run and owned
    # solely by this workflow. Only $FIX_BRANCH is written — never the base.
    git_remote push --force origin "HEAD:refs/heads/$FIX_BRANCH" || die "could not push $FIX_BRANCH"
    _pushed="$(git rev-parse HEAD)"
    if [ -n "$_open" ]; then
        note "updating PR #$_open"
        gh pr edit "$_open" --title "$PR_TITLE" --body-file "$_dir/report.md" ||
            die "could not update PR #$_open"
        ensure_pr_draft "$_open" "$_pushed"
    else
        note "opening the remediation PR"
        gh pr create --draft --base "$BASE_BRANCH" --head "$FIX_BRANCH" \
            --title "$PR_TITLE" --body-file "$_dir/report.md" ||
            die "could not open the remediation PR"
        _new="$(open_pr_number)"
        [ -n "$_new" ] || die "could not resolve the newly created PR"
        ensure_pr_draft "$_new" "$_pushed"
    fi
    note "done — merging $FIX_BRANCH stays a human decision"
}

case "${1:-}" in
fix)
    shift
    cmd_fix "$@"
    ;;
publish)
    shift
    cmd_publish "$@"
    ;;
*)
    echo "usage: security-audit-fix.sh fix [--skip-refused] [--report FILE] | publish DIR" >&2
    exit 1
    ;;
esac
