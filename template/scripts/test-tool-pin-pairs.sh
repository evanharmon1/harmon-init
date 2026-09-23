#!/usr/bin/env bash
# test-tool-pin-pairs.sh — a tool's version pin and its checksum pins move
# together, or the bump is dead on arrival.
#
# A raw release download is verified against a hard-coded per-architecture
# hash (`shfmt_sha256=…`). Bump the `SHFMT_VERSION=` line without the hashes
# and CI downloads the new binary, checks it against the OLD release's hash,
# and fails closed. Renovate keeps them together through a
# `github-release-attachments` annotation on each hash line; this guard is the
# fast local check that it (or a hand edit) actually did.
#
# Pairs are declared, never inferred: a trailing `# pin-pair: <tool>` marks
# every member line — exactly one `*_VERSION=` line and one or more
# `*_sha256=` lines per tool per file:
#
#     SHFMT_VERSION=3.14.1 # pin-pair: shfmt
#     # renovate: datasource=github-release-attachments depName=mvdan/sh digestVersion=v3.14.1
#     shfmt_sha256=76e7… # pin-pair: shfmt
#
# Two checks, both on tracked files under `.github/` (either layer):
#   1. static  — every hash member sits directly under its Renovate
#                annotation, and that annotation's tag is the version line's
#                value (with or without a leading `v`);
#   2. drift   — when a `*_VERSION` value differs from the merge-base, every
#                paired hash must differ too. A tag bumped without its hash is
#                what Renovate leaves when it cannot find the release asset.
# The drift check needs a merge-base; with none (a shallow CI checkout, no
# remote) it is skipped with a notice, and the action's own `sha256sum -c`
# remains the fail-closed backstop.
#
# Base ref: PIN_PAIRS_BASE if set, else origin/$GITHUB_BASE_REF on a pull
# request, else origin/HEAD, origin/main, origin/master — first that resolves.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref=
for candidate in "${PIN_PAIRS_BASE:-}" "${GITHUB_BASE_REF:+origin/${GITHUB_BASE_REF}}" origin/HEAD origin/main origin/master; do
    [ -n "$candidate" ] || continue
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
        base_ref="$candidate"
        break
    fi
done
if [ -n "${PIN_PAIRS_BASE:-}" ] && [ "$base_ref" != "$PIN_PAIRS_BASE" ]; then
    echo "pin-pairs: PIN_PAIRS_BASE=${PIN_PAIRS_BASE} does not resolve to a commit" >&2
    exit 1
fi
merge_base=
if [ -n "$base_ref" ]; then
    merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
fi

# git grep exits 1 for "no match" and 2+ for a real failure; only the former
# may read as "nothing to check".
rc=0
listing="$(git grep -l -F '# pin-pair: ' -- '.github/**' '*/.github/**')" || rc=$?
if [ "$rc" -gt 1 ]; then
    echo "pin-pairs: git grep failed (exit ${rc})" >&2
    exit 1
fi
files=()
while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
done <<<"$listing"

if [ "${#files[@]}" -eq 0 ]; then
    echo "pin-pairs OK: no '# pin-pair:' markers under .github/"
    exit 0
fi

python3 - "$base_ref" "$merge_base" "${files[@]}" <<'PY'
import re
import subprocess
import sys

base_ref, merge_base, files = sys.argv[1], sys.argv[2], sys.argv[3:]

MEMBER = re.compile(
    r"^\s*(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<val>\S+)\s+# pin-pair: (?P<tool>[A-Za-z0-9._-]+)\s*$"
)
MARKER = re.compile(r"# pin-pair:")
ANNOTATION = re.compile(
    r"^\s*# renovate: datasource=github-release-attachments depName=(?P<dep>\S+) digestVersion=(?P<tag>\S+)\s*$"
)


def parse(path, text, errors):
    """{tool: {"version": (line, var, val) | None, "hashes": [(line, var, val, dep, tag)]}}"""
    pairs = {}
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        # A comment-only line may talk about the marker; only code carries one.
        if not MARKER.search(line) or line.lstrip().startswith("#"):
            continue
        m = MEMBER.match(line)
        if not m:
            errors.append(f"{path}:{i}: '# pin-pair:' marker on a line that is not `NAME=value # pin-pair: <tool>`")
            continue
        tool, var, val = m["tool"], m["var"], m["val"]
        entry = pairs.setdefault(tool, {"version": None, "hashes": []})
        if var.endswith("_VERSION"):
            if entry["version"]:
                errors.append(f"{path}:{i}: pin-pair '{tool}' has a second version line (first at line {entry['version'][0]})")
                continue
            entry["version"] = (i, var, val)
        elif var.lower().endswith("_sha256"):
            if not re.fullmatch(r"[0-9a-f]{64}", val):
                errors.append(f"{path}:{i}: pin-pair '{tool}' hash {var} is not 64 lowercase hex digits")
            ann = ANNOTATION.match(lines[i - 2]) if i >= 2 else None
            if not ann:
                errors.append(
                    f"{path}:{i}: pin-pair '{tool}' hash {var} is not directly under a "
                    "`# renovate: datasource=github-release-attachments depName=<owner/repo> digestVersion=<tag>` "
                    "annotation, so Renovate will never update it"
                )
                entry["hashes"].append((i, var, val, None, None))
            else:
                entry["hashes"].append((i, var, val, ann["dep"], ann["tag"]))
        else:
            errors.append(f"{path}:{i}: pin-pair '{tool}' member {var} is neither a *_VERSION nor a *_sha256 line")
    return pairs


errors = []
checked = 0
for path in files:
    with open(path, encoding="utf-8", errors="replace") as fh:
        head = parse(path, fh.read(), errors)
    base = None
    if merge_base:
        shown = subprocess.run(
            ["git", "show", f"{merge_base}:{path}"], capture_output=True, text=True
        )
        if shown.returncode == 0:
            base = parse(path, shown.stdout, [])
    for tool, entry in sorted(head.items()):
        checked += 1
        if not entry["version"]:
            errors.append(f"{path}: pin-pair '{tool}' has hash lines but no `*_VERSION=… # pin-pair: {tool}` line")
            continue
        if not entry["hashes"]:
            errors.append(f"{path}:{entry['version'][0]}: pin-pair '{tool}' has a version line but no `*_sha256=… # pin-pair: {tool}` lines")
            continue
        vline, vvar, version = entry["version"]
        for line, var, _, dep, tag in entry["hashes"]:
            if tag is not None and tag.removeprefix("v") != version.removeprefix("v"):
                errors.append(
                    f"{path}:{line}: pin-pair '{tool}': {var} is annotated for {tag} but {vvar} is {version} "
                    f"(line {vline}) — the hash belongs to a different release.\n"
                    f"    fix: set digestVersion to the release tag of {version} and the hash to that release asset's sha256:\n"
                    f"         curl -fsSL https://github.com/{dep}/releases/download/<tag>/<asset> | sha256sum\n"
                    f"         (<asset> is the file this step downloads for that architecture)"
                )
        old = (base or {}).get(tool)
        if not old or not old["version"] or old["version"][2] == version:
            continue
        old_hashes = {h[2] for h in old["hashes"]}
        stale = [h for h in entry["hashes"] if h[2] in old_hashes]
        if stale:
            dep = next((h[3] for h in entry["hashes"] if h[3]), "<owner/repo>")
            lines_ = ", ".join(str(h[0]) for h in stale)
            errors.append(
                f"{path}: pin-pair '{tool}': {vvar} changed {old['version'][2]} -> {version} since {base_ref} "
                f"but these paired hash lines did not: {lines_}.\n"
                f"    fix: on a Renovate PR, retry it from the Dependency Dashboard so Renovate recomputes the hashes;\n"
                f"         by hand, replace each hash with the sha256 of that architecture's asset for the new release:\n"
                f"         curl -fsSL https://github.com/{dep}/releases/download/<tag>/<asset> | sha256sum\n"
                f"         (<asset> is the file this step downloads for that architecture)"
            )

for e in errors:
    print(f"FAIL: {e}", file=sys.stderr)
if errors:
    sys.exit(1)
drift = f"drift checked against {base_ref}" if merge_base else "drift check skipped: no merge-base (shallow checkout or no remote)"
print(f"pin-pairs OK: {checked} pair(s) in {len(files)} file(s); {drift}")
PY
