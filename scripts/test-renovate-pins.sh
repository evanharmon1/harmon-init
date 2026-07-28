#!/usr/bin/env bash
# test-renovate-pins.sh — every `# renovate:`-annotated shell pin must actually
# be extractable by the manager that is supposed to manage it.
#
# Four ways a pin silently stops updating (or updates wrong), all of which look
# fine in review and produce NO error from Renovate — it just skips the
# dependency or splits it across PRs:
#   1. quoted value      FOO_VERSION="1.2.3"  -> currentValue is `"1.2.3"`,
#                        which pep440/semver reject
#   2. non-adjacent      a comment between `# renovate:` and the assignment
#                        breaks the `\s+` join
#   3. unmatched path    the file is not covered by any managerFilePatterns
#                        (template scripts carry jinja in the FILENAME)
#   4. split groups      the root and template/ copies of the same dep resolve
#                        to different packageRules groupNames, so Renovate opens
#                        two PRs that each update only one twin — and each PR
#                        fails test:dogfood-parity (PRs #405/#406/#407,
#                        2026-07-28)
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

for p in (
    sorted(pathlib.Path(".").glob(".github/actions/*/action.y*ml"))
    + sorted(pathlib.Path(".").glob("template/.github/actions/*/action.y*ml*"))
    # Workflows have the same two failure modes — and the template side is the
    # worst case again: conditional filenames (`…yml[% endif %].jinja`) fall out
    # of a manager pattern anchored at `\.ya?ml(\.jinja)?$` and every pin in the
    # file silently freezes.
    + sorted(pathlib.Path(".").glob(".github/workflows/*.y*ml"))
    + sorted(pathlib.Path(".").glob("template/.github/workflows/*"))
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

# ── Group consistency: a root file and its template twin must resolve to the
# SAME packageRules group for every dep they both pin ─────────────────────────
# packageRules are evaluated in order with later rules overriding earlier ones;
# matchFileNames is minimatch-style. Twins in different groups mean Renovate
# opens two PRs that each update only one copy — and each fails
# test:dogfood-parity. A dep pinned in a root file but not extractable from its
# twin is the same failure via rot: only the root copy ever gets bumped.
# (Cross-FILE splits — e.g. gitleaks pinned in both the Dockerfile [Devcontainer
# group] and the composite action [GitHub Actions group] — are intentional and
# parity-safe: each PR still updates both twins of the files it touches.)

def glob_to_re(pat):
    out, i = "", 0
    while i < len(pat):
        if pat[i : i + 2] == "**":
            out, i = out + ".*", i + 2
        elif pat[i] == "*":
            out, i = out + "[^/]*", i + 1
        else:
            out, i = out + re.escape(pat[i]), i + 1
    return re.compile("^" + out + "$")

def resolve_group(cfg, path, dep, datasource, manager="custom.regex"):
    group = None
    for rule in cfg.get("packageRules", []):
        if "matchManagers" in rule and manager not in rule["matchManagers"]:
            continue
        if "matchDatasources" in rule and datasource not in rule["matchDatasources"]:
            continue
        if "matchDepTypes" in rule:
            continue  # regex-managed pins carry no depType
        names = rule.get("matchPackageNames")
        if names and "*" not in names and dep not in names:
            continue
        globs = rule.get("matchFileNames")
        if globs and not any(glob_to_re(g).match(path) for g in globs):
            continue
        if "groupName" in rule:
            group = rule["groupName"]
    return group

def extract_pins(cfg, path, text):
    """(dep, datasource) pairs every custom manager in cfg extracts from path."""
    pins = set()
    for m in cfg.get("customManagers", []):
        pats = [re.compile(x.strip("/")) for x in m.get("managerFilePatterns", [])]
        if not any(rx.search(path) for rx in pats):
            continue
        for s in m.get("matchStrings", []):
            for mo in re.finditer(js_to_py(s), text):
                gd = mo.groupdict()
                pins.add((gd["depName"], gd.get("datasource") or m.get("datasourceTemplate")))
    return pins

def twin_name(path):
    """Root-layer path a template file is the twin of: strip the template/
    prefix, jinja conditionals in the name, and a trailing .jinja extension."""
    name = rendered(path)
    return name[: -len(".jinja")] if name.endswith(".jinja") else name

SWEEP = [".skills-sync.yaml", "Taskfile.yml", ".devcontainer", ".github", "scripts", "taskfiles", "template"]
file_pins = {}  # path -> {(dep, datasource), ...}
for top in SWEEP:
    base = pathlib.Path(top)
    files = [base] if base.is_file() else sorted(p for p in base.rglob("*") if p.is_file()) if base.is_dir() else []
    for p in files:
        text = p.read_text(errors="replace")
        if ANNOT.search(text):
            file_pins[str(p)] = extract_pins(root_cfg, str(p), text)

twin_of = {twin_name(p): p for p in file_pins if p.startswith("template/")}
for root_path, root_pins in sorted(file_pins.items()):
    if root_path.startswith("template/"):
        continue
    tmpl_path = twin_of.get(root_path)
    if not tmpl_path:
        continue
    for dep, ds in sorted(root_pins - file_pins[tmpl_path]):
        errors.append(
            f"{dep}: pinned in {root_path} but not extractable from its twin "
            f"{tmpl_path} — Renovate bumps only the root copy: a verbatim twin "
            f"then fails test:dogfood-parity, a .jinja twin silently ships the "
            f"stale pin downstream (check managerFilePatterns against the "
            f"jinja-carrying path)"
        )
    for dep, ds in sorted(root_pins & file_pins[tmpl_path]):
        g_root = resolve_group(root_cfg, root_path, dep, ds)
        g_tmpl = resolve_group(root_cfg, tmpl_path, dep, ds)
        if g_root != g_tmpl:
            errors.append(
                f"{dep}: {root_path} resolves to group {g_root!r} but its twin "
                f"{tmpl_path} resolves to {g_tmpl!r} — Renovate splits the bump "
                f"across two PRs, each updating only one twin (verbatim twins "
                f"then fail test:dogfood-parity)"
            )

# ── Template config: rendered packageRules route consumer pins correctly ────
# The generated repo has no parity gate, so the requirement is the opposite
# shape: devcontainer-coupled pins batch into the Devcontainer group (semgrep
# is pinned in BOTH the Dockerfile and run-semgrep.sh and must move in one PR),
# while unrelated script pins (markdownlint-cli2, pip-audit) stay out of it.

def render_template_config(answers):
    raw = pathlib.Path("template/renovate.json.jinja").read_text()
    rendered = re.sub(
        r"\[%[-+]?\s*if (\w+)\s*%\](.*?)\[%[-+]?\s*endif\s*[-+]?%\]",
        lambda m: m.group(2) if answers.get(m.group(1)) else "",
        raw,
        flags=re.S,
    )
    return json.loads(rendered)

ALL_ON = dict.fromkeys(
    ["use_skills_sync", "devcontainer", "include_ansible", "use_node", "include_terraform", "use_foreman"], True
)
try:
    tmpl_on = render_template_config(ALL_ON)
    tmpl_off = render_template_config({**ALL_ON, "devcontainer": False})
except json.JSONDecodeError as exc:
    tmpl_on = tmpl_off = None
    errors.append(f"template/renovate.json.jinja does not render to valid JSON: {exc}")

if tmpl_on:
    for path, dep, ds, want in [
        ("scripts/devcontainer-assert.sh", "@devcontainers/cli", "npm", "Devcontainer"),
        ("scripts/devcontainer-smoke.sh", "@devcontainers/cli", "npm", "Devcontainer"),
        ("scripts/run-semgrep.sh", "semgrep", "pypi", "Devcontainer"),
        (".devcontainer/Dockerfile", "semgrep", "pypi", "Devcontainer"),
        ("scripts/markdownlint.sh", "markdownlint-cli2", "npm", None),
        ("scripts/python-audit.sh", "pip-audit", "pypi", None),
    ]:
        got = resolve_group(tmpl_on, path, dep, ds)
        if got != want:
            errors.append(
                f"template config (devcontainer=true): {dep} in {path} resolves to "
                f"group {got!r}, expected {want!r}"
            )
if tmpl_off and resolve_group(tmpl_off, "scripts/run-semgrep.sh", "semgrep", "pypi") is not None:
    errors.append(
        "template config (devcontainer=false): semgrep in scripts/run-semgrep.sh "
        "should be ungrouped when no Devcontainer rule is rendered"
    )

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    print(f"test-renovate-pins: {len(errors)} issue(s) found", file=sys.stderr)
    sys.exit(1)
print("renovate pins: every annotated shell pin is extractable and in scope")
print("renovate pins: every composite-action pin (both layers) is extractable and in scope")
print("renovate pins: root files and their template twins resolve to the same group")
print("renovate pins: rendered template rules route consumer pins to the right groups")
PY
