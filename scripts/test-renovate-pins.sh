#!/usr/bin/env bash
# test-renovate-pins.sh — every `# renovate:`-annotated shell pin must actually
# be extractable by the manager that is supposed to manage it.
#
# Three ways a pin silently stops updating, all of which look fine in review and
# produce NO error from Renovate — it just skips the dependency:
#   1. quoted value      FOO_VERSION="1.2.3"  -> currentValue is `"1.2.3"`,
#                        which pep440/semver reject
#   2. non-adjacent      a comment between `# renovate:` and the assignment
#                        breaks the `\s+` join
#   3. unmatched path    the file is not covered by any managerFilePatterns
#                        (template scripts carry jinja in the FILENAME)
#
# Rather than re-describe the rules, this runs the regexes the repo actually
# ships, so the test cannot drift from the config.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
import json, re, sys, pathlib

def load_shell_manager(path):
    raw = pathlib.Path(path).read_text()
    # The template config is jinja-templated, so it is not always valid JSON;
    # pull the manager out textually and fall back to a JSON parse when clean.
    try:
        cfg = json.loads(raw)
        mgrs = cfg.get("customManagers", [])
    except json.JSONDecodeError:
        mgrs = []
        for m in re.finditer(r'\{[^{}]*"matchStrings"\s*:\s*\[[^\]]*\][^{}]*\}', raw, re.S):
            try:
                mgrs.append(json.loads(m.group(0)))
            except json.JSONDecodeError:
                pass
    for m in mgrs:
        if any("_VERSION=" in s for s in m.get("matchStrings", [])):
            return m
    return None

def js_to_py(rx):
    return rx.replace("(?<", "(?P<")

errors = []

root_mgr = load_shell_manager("renovate.json")
tmpl_mgr = load_shell_manager("template/renovate.json.jinja")
if not root_mgr:
    errors.append("renovate.json: no shell-variable custom manager found")
if not tmpl_mgr:
    errors.append("template/renovate.json.jinja: no shell-variable custom manager found")

ANNOT = re.compile(r"^\s*#\s*renovate:\s*datasource=", re.M)

def rendered(path):
    """Path as it appears in a GENERATED repo: no `template/` prefix, no jinja
    in the filename. The template config's patterns are anchored at the
    generated repo root, so they must be tested against this form."""
    return re.sub(r"\[%.*?%\]", "", path).removeprefix("template/")

for p in sorted(pathlib.Path(".").glob("scripts/*.sh")) + sorted(
    pathlib.Path("template/scripts").iterdir() if pathlib.Path("template/scripts").is_dir() else []
):
    if not p.is_file():
        continue
    text = p.read_text(errors="replace")
    if not ANNOT.search(text):
        continue

    is_template = str(p).startswith("template/")
    mgr = tmpl_mgr if is_template else root_mgr
    # The root config must ALSO see template sources — that is how harmon-init
    # gets bump PRs for the pins it ships downstream.
    configs = [("template/renovate.json.jinja", mgr, rendered(str(p)))] if is_template else []
    configs.append(("renovate.json", root_mgr, str(p)))

    n_annot = len(ANNOT.findall(text))

    # Quoting is a property of the FILE, not of any one config, so check it once
    # — otherwise a template file (checked against both configs) reports twice.
    for cfg_name, m, _ in configs:
        if m:
            for mo in re.finditer(js_to_py(m["matchStrings"][0]), text):
                val = mo.group("currentValue")
                if val.startswith('"') or val.startswith("'"):
                    errors.append(
                        f"{p}: pin value {val} is quoted; quotes end up inside currentValue"
                    )
            break

    for cfg_name, m, path_for_match in configs:
        if not m:
            continue
        matched = len(re.findall(js_to_py(m["matchStrings"][0]), text))
        if matched < n_annot:
            errors.append(
                f"{p}: {n_annot} '# renovate:' annotation(s) but {matched} extractable by "
                f"{cfg_name} — check adjacency (no comment between annotation and "
                f"assignment) and that the value is unquoted"
            )
        pats = [re.compile(x.strip("/")) for x in m.get("managerFilePatterns", [])]
        if pats and not any(rx.search(path_for_match) for rx in pats):
            errors.append(
                f"{p}: not matched by any managerFilePatterns in {cfg_name} "
                f"(tested as {path_for_match!r}) — the pin is invisible to Renovate"
            )

# ── Composite actions: `<tool>_version:` inputs and `uses:` SHA pins ────────
# Same silent-rot failure mode, different syntax — and the template's
# action.yml.jinja is the worst case: the NATIVE github-actions manager cannot
# parse the .jinja extension, so a pin no customManager matches is frozen
# forever with nothing reporting it. Checked against the ROOT config, which is
# the one Renovate runs here; the rendered side is asserted by
# scripts/test-template.sh.
try:
    root_cfg = json.loads(pathlib.Path("renovate.json").read_text())
except json.JSONDecodeError as exc:
    root_cfg = {"customManagers": []}
    errors.append(f"renovate.json does not parse: {exc}")

USES_SHA = re.compile(r"uses: \S+@[0-9a-f]{40} # v[0-9]")

def lines_of(rx, text):
    return {text[: mo.start()].count("\n") + 1 for mo in rx.finditer(text)}

for p in sorted(pathlib.Path(".").glob(".github/actions/*/action.y*ml")) + sorted(
    pathlib.Path(".").glob("template/.github/actions/*/action.y*ml*")
):
    text = p.read_text(errors="replace")
    rel = str(p)
    seen = set()
    for m in root_cfg.get("customManagers", []):
        pats = [re.compile(x.strip("/")) for x in m.get("managerFilePatterns", [])]
        if not any(rx.search(rel) for rx in pats):
            continue
        for s in m.get("matchStrings", []):
            seen |= lines_of(re.compile(js_to_py(s)), text)

    for line in sorted(lines_of(ANNOT, text) - seen):
        errors.append(
            f"{p}:{line}: '# renovate:' pin is not extractable by any customManager "
            f"in renovate.json — it will never be updated"
        )
    # Only .jinja files need a customManager for `uses:` SHAs; Renovate's native
    # github-actions manager already reads plain action.yml.
    if rel.endswith(".jinja"):
        for line in sorted(lines_of(USES_SHA, text) - seen):
            errors.append(
                f"{p}:{line}: SHA-pinned `uses:` is invisible to renovate.json — the "
                f"native github-actions manager cannot read .jinja, so nothing updates it"
            )

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    print(f"test-renovate-pins: {len(errors)} issue(s) found", file=sys.stderr)
    sys.exit(1)
print("renovate pins: every annotated shell pin is extractable and in scope")
print("renovate pins: every composite-action pin (both layers) is extractable and in scope")
PY
