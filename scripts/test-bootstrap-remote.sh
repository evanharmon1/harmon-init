#!/usr/bin/env bash
# test-bootstrap-remote.sh — the remote bootstrap installs what the shared
# image installs, from the pins the shared image reads, and pins nothing of
# its own.
#
# That invariant is the whole point of images/devcontainer/versions.env and
# images/devcontainer/install/: bumping a version in one place has to update
# the devcontainer and every remote environment together. It is also the
# invariant that rots silently — a `TASK_VERSION=3.53.1` typed into a tier
# script installs a perfectly working tool, and nothing else in the repository
# notices that the two paths have started to drift.
#
# Offline and metadata-only: no container, no network, no Docker daemon. The
# behaviour these files have when they RUN is proved by
# .github/workflows/remote-bootstrap.yml (a stock ubuntu:24.04 container) and
# by images/devcontainer/smoke.sh (the built image).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys

errors = []


def fail(msg):
    errors.append(msg)


IMG = pathlib.Path("images/devcontainer")
VERSIONS = IMG / "versions.env"
INSTALL = IMG / "install"
BOOTSTRAP = IMG / "bootstrap-remote.sh"
DOCKERFILE = IMG / "Dockerfile"
SHARE = "/usr/local/share/harmon-devcontainer"

for required in (VERSIONS, INSTALL, BOOTSTRAP, DOCKERFILE):
    if not required.exists():
        fail(f"{required} is missing")
if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

versions_text = VERSIONS.read_text()
versions_lines = versions_text.splitlines()
bootstrap_text = BOOTSTRAP.read_text()
dockerfile_text = DOCKERFILE.read_text()
tier_scripts = sorted(p.name for p in INSTALL.glob("*.sh"))

ASSIGN = re.compile(r"^(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<val>[^\s#]+)(?:\s+# pin-pair: [A-Za-z0-9._-]+)?\s*$")
ANNOT = re.compile(r"^# renovate: datasource=(?P<ds>\S+) depName=(?P<dep>\S+)")

# ── 1. versions.env is a plain, sourceable, unquoted pin file ───────────────
# Quoting is the classic silent Renovate failure: the quotes end up inside
# currentValue and pep440/semver reject the result with no error anywhere.
pins = {}
for i, line in enumerate(versions_lines, 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    m = ASSIGN.match(line)
    if not m:
        fail(f"{VERSIONS}:{i}: not a plain unquoted `NAME=value` assignment: {line!r}")
        continue
    var, val = m["var"], m["val"]
    if var in pins:
        fail(f"{VERSIONS}:{i}: {var} is assigned twice (first at line {pins[var]})")
    pins[var] = i
    if val[0] in "\"'":
        fail(f"{VERSIONS}:{i}: {var} value is quoted; the quotes end up inside Renovate's currentValue")

# ── 2. every pin is Renovate-annotated, adjacent ────────────────────────────
for var, line_no in sorted(pins.items()):
    if not (var.endswith("_VERSION") or var.endswith("_sha256")):
        fail(f"{VERSIONS}:{line_no}: {var} is neither a `*_VERSION` nor a `*_sha256` pin")
        continue
    previous = versions_lines[line_no - 2] if line_no >= 2 else ""
    if var.endswith("_VERSION") and not ANNOT.match(previous):
        fail(
            f"{VERSIONS}:{line_no}: {var} is not directly under a `# renovate: datasource=… depName=…` "
            "annotation, so Renovate would never bump it (a comment in between breaks the match)"
        )

# ── 3. Renovate's own managers extract every annotated pin ──────────────────
# Runs the regexes the repository actually ships rather than restating them,
# so this check cannot drift from renovate.json.
cfg = json.loads(pathlib.Path("renovate.json").read_text())
extracted = set()
for manager in cfg.get("customManagers", []):
    patterns = [re.compile(p.strip("/")) for p in manager.get("managerFilePatterns", [])]
    if not any(p.search(str(VERSIONS)) for p in patterns):
        continue
    for match_string in manager.get("matchStrings", []):
        for mo in re.finditer(match_string.replace("(?<", "(?P<"), versions_text):
            extracted.add(mo.group(0).splitlines()[-1].split("=")[0].strip())
annotated = sum(1 for line in versions_lines if line.startswith("# renovate:"))
if len(extracted) < annotated:
    missing = sorted(set(pins) - extracted)
    fail(
        f"{VERSIONS}: {annotated} '# renovate:' annotation(s) but only {len(extracted)} pin(s) are "
        f"extractable by renovate.json's managerFilePatterns — not extractable: {missing}"
    )

# ── 4. the hand-verified Node digests name the pinned Node ──────────────────
# nodejs.org publishes SHASUMS256.txt rather than release attachments, so
# Renovate cannot recompute these. Same trust shape as the oh-my-pi marker:
# the guard proves the marker moved with the version, and PR review is what
# proves somebody actually re-read SHASUMS256.txt.
VERIFIED_FOR = re.compile(r"^# verified-for: (?P<tag>\S+)$")
node_version = next(
    (line.split("=", 1)[1].split()[0] for line in versions_lines if line.startswith("NODE_VERSION=")), None
)
for digest_var in ("node_amd64_sha256", "node_arm64_sha256"):
    marker = None
    for i, line in enumerate(versions_lines, 1):
        if line.startswith(f"{digest_var}=") and i >= 2:
            m = VERIFIED_FOR.match(versions_lines[i - 2])
            marker = m.group("tag") if m else None
    if marker is None:
        fail(f"{VERSIONS}: no '# verified-for: <version>' marker directly above {digest_var}=")
    elif marker != node_version:
        fail(
            f"{VERSIONS}: NODE_VERSION ({node_version}) has moved past the release {digest_var} was "
            f"hand-verified for ({marker}). Read https://nodejs.org/dist/v{node_version}/SHASUMS256.txt, "
            f"copy the linux-x64 and linux-arm64 .tar.xz digests, and move BOTH '# verified-for:' markers."
        )

# ── 5. THE invariant: nothing but versions.env declares a pin ───────────────
PIN_DECL = re.compile(r"^\s*(?:export\s+|ARG\s+)?(?P<var>[A-Za-z_][A-Za-z0-9_]*(?:_VERSION|_SHA256|_sha256))=")
# A pin can also be typed straight into a download URL, where no variable is
# declared at all: `.../download/v3.53.1/task_linux_amd64.tar.gz` installs a
# working tool and PIN_DECL never sees it. So a URL-bearing line may carry a
# semver-shaped literal only as part of a variable expansion — `v${X_VERSION}`
# is composed from versions.env, `v3.53.1` is a second pin owner.
URL_LINE = re.compile(r"https?://")
URL_PIN = re.compile(r"(?<![A-Za-z0-9_{}$.])v?[0-9]+\.[0-9]+\.[0-9]+(?![0-9])")


def url_inlined_pin(line):
    if not URL_LINE.search(line):
        return None
    stripped = re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*", "", line)
    m = URL_PIN.search(stripped)
    return m.group(0) if m else None


# The detector's own contract, asserted here because the files it scans
# contain no offending line to prove it against (a negative fixture).
assert url_inlined_pin('curl "https://github.com/go-task/task/releases/download/v3.53.1/task.tar.gz"') == "v3.53.1"
assert url_inlined_pin('    "https://nodejs.org/dist/v24.21.0/node.tar.xz" \\') == "v24.21.0"
assert url_inlined_pin('wget https://example.com/tool-1.2.3-linux.tgz') == "1.2.3"
assert url_inlined_pin('    "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${arch}.tar.gz" |') is None
assert url_inlined_pin('    "https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}"') is None
assert url_inlined_pin('    "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/x.tar.gz" |') is None
assert url_inlined_pin('tar -xzf "${tmp}/node-1.2.3.tar.xz"') is None  # not a URL line

for path in [BOOTSTRAP] + sorted(INSTALL.glob("*.sh")):
    for i, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = PIN_DECL.match(line)
        if m:
            fail(
                f"{path}:{i}: declares the pin {m['var']} — every version and checksum must come from "
                f"{VERSIONS}, or the remote bootstrap and the shared image drift apart silently"
            )
        literal = url_inlined_pin(line)
        if literal:
            fail(
                f"{path}:{i}: a download URL carries the literal version {literal!r} instead of a "
                f"`${{…_VERSION}}` from {VERSIONS} — a pin typed into a URL is a second pin owner"
            )

# ── 4b. checksum pins move WITH their version pin ───────────────────────────
# The `# pin-pair: <tool>` convention from scripts/test-tool-pin-pairs.sh,
# applied to versions.env. The check lives here rather than in that script
# because that script is a VERBATIM dogfood twin shipped to generated
# repositories, which have no images/devcontainer/ at all — a scan of this path
# there would be dead weight in a consumer-facing file, and editing it would
# break `test:dogfood-parity`. Same semantics, root-only home.
#
# Bump `UV_VERSION` and leave its digests behind and the install downloads the
# new tarball, checks it against the OLD release's hash, and fails closed —
# during an image build or a remote provision, not here. This is the fast
# check that Renovate (or a hand edit) actually moved both.
PAIR_MEMBER = re.compile(
    r"^(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<val>\S+)\s+# pin-pair: (?P<tool>[A-Za-z0-9._-]+)\s*$"
)
# A hash line's tag comes from its Renovate digest annotation — or, for the
# Node digests that Renovate cannot recompute (nodejs.org publishes
# SHASUMS256.txt, not release attachments), from the hand-written
# `# verified-for:` marker. Either way the guard below proves the tag moved
# with the version.
DIGEST_ANNOT = re.compile(
    r"^# renovate: datasource=github-release-attachments depName=(?P<dep>\S+) digestVersion=(?P<tag>\S+)\s*$"
    r"|^# verified-for: (?P<vtag>\S+)\s*$"
)


def pin_pairs(lines):
    """{tool: {"version": (line, var, val), "hashes": [(line, var, val, tag)]}}"""
    out = {}
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        m = PAIR_MEMBER.match(line)
        if not m:
            if "# pin-pair:" in line:
                yield_err = f"{VERSIONS}:{i}: '# pin-pair:' marker on a line that is not `NAME=value # pin-pair: <tool>`"
                out.setdefault("__errors__", []).append(yield_err)
            continue
        entry = out.setdefault(m["tool"], {"version": None, "hashes": []})
        if m["var"].endswith("_VERSION"):
            if entry["version"]:
                out.setdefault("__errors__", []).append(
                    f"{VERSIONS}:{i}: pin-pair '{m['tool']}' has a second version line"
                )
            entry["version"] = (i, m["var"], m["val"])
        else:
            ann = DIGEST_ANNOT.match(lines[i - 2]) if i >= 2 else None
            entry["hashes"].append((i, m["var"], m["val"], (ann["tag"] or ann["vtag"]) if ann else None))
    return out


head_pairs = pin_pairs(versions_lines)
for err in head_pairs.pop("__errors__", []):
    fail(err)
for tool, entry in sorted(head_pairs.items()):
    if not entry["version"]:
        fail(f"{VERSIONS}: pin-pair '{tool}' has hash lines but no `*_VERSION=… # pin-pair: {tool}` line")
        continue
    vline, vvar, vval = entry["version"]
    if not entry["hashes"]:
        fail(f"{VERSIONS}:{vline}: pin-pair '{tool}' has a version line but no `*_sha256=… # pin-pair: {tool}` lines")
        continue
    for line_no, var, val, tag in entry["hashes"]:
        if not re.fullmatch(r"[a-z0-9_]+_sha256", var):
            fail(f"{VERSIONS}:{line_no}: pin-pair '{tool}' hash {var} must be lowercase `[a-z0-9_]+_sha256`")
        if not re.fullmatch(r"[0-9a-f]{64}", val):
            fail(f"{VERSIONS}:{line_no}: pin-pair '{tool}' hash {var} is not 64 lowercase hex digits")
        if tag is None:
            fail(
                f"{VERSIONS}:{line_no}: pin-pair '{tool}' hash {var} is not directly under a "
                "`# renovate: datasource=github-release-attachments depName=… digestVersion=<tag>` "
                "annotation (or, for a hand-verified digest, a `# verified-for: <version>` marker), "
                "so nothing ties it to the release it was taken from"
            )
        elif tag.removeprefix("v") != vval.removeprefix("v"):
            fail(
                f"{VERSIONS}:{line_no}: pin-pair '{tool}': {var} is annotated for {tag} but {vvar} is "
                f"{vval} (line {vline}) — the hash belongs to a different release"
            )

# Drift, against the merge-base: a version that moved with a hash that did not
# is what a hand edit leaves, and the annotation check above cannot see it
# because both annotations moved together. Skipped (with a notice) where there
# is no merge-base — a shallow checkout or a clone with no remote.
base_ref = os.environ.get("PIN_PAIRS_BASE") or (
    f"origin/{os.environ['GITHUB_BASE_REF']}" if os.environ.get("GITHUB_BASE_REF") else None
)
candidates = [base_ref] if base_ref else ["origin/HEAD", "origin/main", "origin/master"]
merge_base = None
for candidate in candidates:
    probe = subprocess.run(["git", "merge-base", candidate, "HEAD"], capture_output=True, text=True)
    if probe.returncode == 0:
        merge_base = probe.stdout.strip()
        break
if merge_base is None:
    drift_note = "drift check skipped: no merge-base (shallow checkout or no remote)"
elif os.environ.get("GITHUB_BASE_REF") and base_ref is None:
    drift_note = "drift check skipped"
else:
    drift_note = f"drift checked against {merge_base[:12]}"
    shown = subprocess.run(
        ["git", "show", f"{merge_base}:{VERSIONS}"], capture_output=True, text=True
    )
    if shown.returncode == 0:
        base_pairs = pin_pairs(shown.stdout.splitlines())
        base_pairs.pop("__errors__", None)
        for tool, entry in sorted(head_pairs.items()):
            old = base_pairs.get(tool)
            if not old or not old["version"] or old["version"][2] == entry["version"][2]:
                continue
            old_hashes = {h[2] for h in old["hashes"]}
            stale = [str(h[0]) for h in entry["hashes"] if h[2] in old_hashes]
            if stale:
                fail(
                    f"{VERSIONS}: pin-pair '{tool}': {entry['version'][1]} changed "
                    f"{old['version'][2]} -> {entry['version'][2]} since the merge base but these "
                    f"paired hash lines did not: {', '.join(stale)}"
                )

# ── 5b. one version per DEPENDENCY, across the whole root layer ─────────────
# A pin can be duplicated without being duplicated in versions.env: semgrep,
# copier and markdownlint-cli2 are each ALSO pinned by the scripts/ helper that
# runs them, because those helpers are dogfood twins shipped to generated
# repositories that have no images/devcontainer/ to read. Renovate's
# Devcontainer group keeps the copies in one PR; this proves they actually
# agree, matched on the Renovate DEPENDENCY rather than the variable name, so
# a rename on either side cannot quietly opt out of the check.
def annotated_pins(text):
    found = {}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = ANNOT.match(line.strip())
        if not m or i + 1 >= len(lines):
            continue
        assign = re.match(r"^\s*(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<val>[^\s#\"']+)", lines[i + 1])
        if assign:
            found[m["dep"]] = (assign["var"], assign["val"], i + 2)
    return found


versions_pins = annotated_pins(versions_text)
for helper in sorted(pathlib.Path("scripts").glob("*.sh")):
    for dep, (var, val, line_no) in annotated_pins(helper.read_text()).items():
        if dep not in versions_pins:
            continue
        their_var, their_val, their_line = versions_pins[dep]
        if their_val != val:
            fail(
                f"{helper}:{line_no}: {var}={val} but {VERSIONS}:{their_line} has {their_var}={their_val} "
                f"for the same dependency ({dep}) — the shared image and the tool's own runner would "
                "install different versions"
            )

# ── 5c. every pin in versions.env is actually used by an install script ─────
# The invariant runs both ways. A pin nobody reads is a promise the file is no
# longer keeping: it looks like shared state, Renovate keeps bumping it, and a
# reader has no way to tell it apart from a live one. The Dockerfile counts as
# a reader too — the manifest layer records versions the image installs through
# these scripts.
readers = "\n".join(p.read_text() for p in sorted(INSTALL.glob("*.sh"))) + dockerfile_text
for var, line_no in sorted(pins.items()):
    if not re.search(r"\$\{?" + re.escape(var) + r"\b", readers):
        fail(
            f"{VERSIONS}:{line_no}: {var} is read by no install script and by no Dockerfile layer — "
            "either wire it up or delete it; an unread pin is not a shared pin"
        )

# ── 6. …and the Dockerfile does not re-declare a moved pin ──────────────────
docker_args = set(re.findall(r"^ARG ([A-Za-z0-9_]+)=", dockerfile_text, re.M))
overlap = sorted(docker_args & set(pins))
if overlap:
    fail(
        f"{DOCKERFILE}: re-declares pins that live in {VERSIONS}: {overlap} — two owners for one "
        "version is exactly the drift this file exists to prevent"
    )

# ── 7. the standalone fetch list matches what is on disk ────────────────────
# Without this, adding a tier script leaves the piped one-liner fetching an
# incomplete set — and failing only on a remote VM nobody is watching.
listed = re.search(r'HARMON_REMOTE_ASSETS="\n(.*?)\n"', bootstrap_text, re.S)
if not listed:
    fail(f"{BOOTSTRAP}: HARMON_REMOTE_ASSETS is missing or not a newline-separated literal")
else:
    declared = set(listed.group(1).split())
    # generate-manifest.sh is in the set because the VM writes the same
    # manifest the image does, with the same generator.
    on_disk = {"versions.env", "generate-manifest.sh"} | {f"install/{name}" for name in tier_scripts}
    if declared != on_disk:
        fail(
            f"{BOOTSTRAP}: HARMON_REMOTE_ASSETS does not match images/devcontainer/ — "
            f"missing {sorted(on_disk - declared)}, stale {sorted(declared - on_disk)}"
        )

# ── 8. every declared tier has a script, and core is one of them ────────────
order = re.search(r'HARMON_TIER_ORDER="([^"]+)"', bootstrap_text)
if not order:
    fail(f"{BOOTSTRAP}: HARMON_TIER_ORDER is missing")
else:
    tiers = order.group(1).split()
    if "core" not in tiers:
        fail(f"{BOOTSTRAP}: HARMON_TIER_ORDER does not contain the core tier")
    for tier in tiers:
        if f"install-{tier}.sh" not in tier_scripts:
            fail(f"{BOOTSTRAP}: tier '{tier}' has no images/devcontainer/install/install-{tier}.sh")
    for name in tier_scripts:
        m = re.fullmatch(r"install-([a-z0-9-]+)\.sh", name)
        if m and m.group(1) not in tiers:
            fail(f"{INSTALL}/{name}: no tier named '{m.group(1)}' in HARMON_TIER_ORDER, so it never runs")

# ── 9. the never-installed set ──────────────────────────────────────────────
NEVER = {"op", "brew", "tailscale", "tailscaled"}
NEVER_PREFIXES = {"/home/linuxbrew", "/opt/homebrew"}
declared_never = re.search(r'HARMON_NEVER_INSTALL="([^"]+)"', bootstrap_text)
if not declared_never or set(declared_never.group(1).split()) != NEVER:
    fail(f"{BOOTSTRAP}: HARMON_NEVER_INSTALL must be exactly {sorted(NEVER)}")
declared_prefixes = re.search(r'HARMON_NEVER_PREFIXES="([^"]+)"', bootstrap_text)
if not declared_prefixes or set(declared_prefixes.group(1).split()) != NEVER_PREFIXES:
    fail(f"{BOOTSTRAP}: HARMON_NEVER_PREFIXES must be exactly {sorted(NEVER_PREFIXES)}")
# The bootstrap is scanned as well as the tier scripts: it is the one file
# that runs on every remote VM, and the only lines allowed to name the
# forbidden set are the two declarations the closing check iterates.
FORBIDDEN_TOKEN = re.compile(r"\b(1password|homebrew|linuxbrew|tailscale)\b", re.I)
NEVER_DECL = re.compile(r"^\s*readonly HARMON_NEVER_(INSTALL|PREFIXES)=")
for path in [BOOTSTRAP] + sorted(INSTALL.glob("*.sh")):
    for i, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#") or NEVER_DECL.match(line):
            continue
        if FORBIDDEN_TOKEN.search(line):
            fail(f"{path}:{i}: the bootstrap must never install 1Password, Homebrew, or Tailscale")

# ── 10. the denied hosts are gone from BOTH paths ───────────────────────────
# deb.nodesource.com and astral.sh are denied on the Claude Code on the web VM,
# so an image that still used them could not share its install scripts at all.
DENIED = ("deb.nodesource.com", "astral.sh")
for label, text in ((str(DOCKERFILE), dockerfile_text),) + tuple(
    (str(p), p.read_text()) for p in sorted(INSTALL.glob("*.sh"))
):
    for host in DENIED:
        for i, line in enumerate(text.splitlines(), 1):
            if host in line and not line.lstrip().startswith("#"):
                fail(f"{label}:{i}: contacts {host}, which the remote adapter's network level denies")

# ── 11. the image really runs the shared scripts ────────────────────────────
for script in tier_scripts:
    if script == "lib.sh":
        continue  # sourced by the others, never run
    if f"{SHARE}/install/{script}" not in dockerfile_text:
        fail(f"{DOCKERFILE}: does not run {SHARE}/install/{script} — the image would install its own copy")
if f"COPY versions.env {SHARE}/versions.env" not in dockerfile_text:
    fail(f"{DOCKERFILE}: does not COPY versions.env to {SHARE}/versions.env")
if f". {SHARE}/versions.env" not in dockerfile_text:
    fail(f"{DOCKERFILE}: the manifest layer does not source {SHARE}/versions.env, so it could record a stale version")

# ── 12. the build context allows what the image needs, and nothing more ─────
ignore = (IMG / ".dockerignore").read_text().split()
for needed in ("!versions.env", "!install"):
    if needed not in ignore:
        fail(f"{IMG}/.dockerignore: missing `{needed}`, so the COPY above would fail")
if "!bootstrap-remote.sh" in ignore:
    fail(f"{IMG}/.dockerignore: bootstrap-remote.sh must stay out of the build context; the image never runs it")

# ── 13. verify actually runs this guard ─────────────────────────────────────
# `task --dry` prints its plan on stderr, so merge the streams rather than
# reading stdout and concluding the task is missing.
plan = subprocess.run(
    ["task", "--dry", "verify"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
)
if plan.returncode != 0:
    fail("`task --dry verify` failed, so this guard's own wiring cannot be checked")
elif "./scripts/test-bootstrap-remote.sh" not in plan.stdout:
    fail("`task verify` does not run scripts/test-bootstrap-remote.sh")

# ── 14. the standalone trust root: only a release tag is accepted ───────────
# The ref is validated before the tier check and before the sudo re-exec, so
# these run unprivileged and touch nothing: a refused ref exits 1 with the
# reason, and an accepted-under-override ref gets past the ref check (to fail
# on the deliberately bogus tier instead) while naming itself in a warning.
def run_bootstrap(args, env_extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("HARMON_")}
    env.update(env_extra or {})
    return subprocess.run(["bash", str(BOOTSTRAP), *args], capture_output=True, text=True, env=env)


for bad_ref in ("main", "feature/x", "1.2.3", "v1.2", "v1.2.3-rc1", "8b8e60f"):
    r = run_bootstrap(["--ref", bad_ref, "--tiers", "no-such-tier"])
    if r.returncode != 1 or "not a release tag" not in r.stderr:
        fail(f"{BOOTSTRAP}: --ref {bad_ref!r} must be refused as 'not a release tag' (exit {r.returncode}: {r.stderr.strip()[:120]!r})")
r = run_bootstrap(["--tiers", "no-such-tier"], {"HARMON_INIT_REF": "main"})
if r.returncode != 1 or "not a release tag" not in r.stderr:
    fail(f"{BOOTSTRAP}: HARMON_INIT_REF=main must be refused the same way --ref main is")
r = run_bootstrap(["--ref", "v1.2.4", "--tiers", "no-such-tier"], {"HARMON_INIT_REF": "v1.2.3"})
if r.returncode != 1 or "disagree" not in r.stderr:
    fail(f"{BOOTSTRAP}: --ref and HARMON_INIT_REF naming different tags must be refused as a disagreement")
r = run_bootstrap(["--ref", "v1.2.3", "--tiers", "no-such-tier"])
if r.returncode != 1 or "unknown tier" not in r.stderr or "not a release tag" in r.stderr:
    fail(f"{BOOTSTRAP}: --ref v1.2.3 must pass the ref check (and fail on the bogus tier instead)")
r = run_bootstrap(["--ref", "main", "--tiers", "no-such-tier"], {"HARMON_ALLOW_UNPINNED_REF": "1"})
if r.returncode != 1 or "unknown tier" not in r.stderr or "WARNING" not in r.stderr or "main" not in r.stderr:
    fail(f"{BOOTSTRAP}: HARMON_ALLOW_UNPINNED_REF=1 must let --ref main through with a WARNING naming the ref")

# ── 15. the manifest is what the tiers installed, under the image's keys ────
# The VM manifest is serialised from the run record, which the lib.sh helpers
# append `name=version` to for every pinned tool a tier installs or verifies —
# so there is no manifest list to drift, and this proves the two things that
# would let one drift back in. Both sides are DERIVED, nothing is listed here:
#   (a) every `*_VERSION` pin a tier script consumes reaches the record through
#       one of the recording helpers (a pin read by a hand-rolled `if` would
#       install fine and vanish from the manifest);
#   (b) the key each tier records for a pin is the key the Dockerfile's manifest
#       layer gives the same pin, so image and VM manifests share a key space.
RECORDERS = re.compile(
    r'\bharmon_needs\s+(?P<key1>[a-z0-9-]+)\s+"\$(?P<var1>[A-Z0-9_]+_VERSION)"'
    r'|\bharmon_(?:npm_global|uv_tool)\s+\S+\s+"\$(?P<var2>[A-Z0-9_]+_VERSION)"\s+(?P<key2>[a-z0-9-]+)\b'
)
CONSUMED = re.compile(r"\$\{?(?P<var>[A-Z][A-Z0-9_]*_VERSION)\b")
image_keys = {var: key for key, var in re.findall(r'"([a-z0-9-]+)=\$\{([A-Z0-9_]+)\}"', dockerfile_text)}
default_tiers = re.search(r'HARMON_DEFAULT_TIERS="([^"]+)"', bootstrap_text)
default_tiers = set(default_tiers.group(1).split(",")) if default_tiers else set()
recorded_by_default = set()
consumed_by_default = set()
for name in tier_scripts:
    m = re.fullmatch(r"install-([a-z0-9-]+)\.sh", name)
    if not m:
        continue
    tier, text = m.group(1), (INSTALL / name).read_text()
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    consumed = set(CONSUMED.findall(code))
    recorded = {}
    for mo in RECORDERS.finditer(code):
        key, var = mo["key1"] or mo["key2"], mo["var1"] or mo["var2"]
        if var in recorded:
            fail(f"{INSTALL}/{name}: {var} is recorded twice (as {recorded[var]} and {key}); the manifest would carry a duplicate key")
        recorded[var] = key
    unrecorded = sorted(consumed - set(recorded))
    if unrecorded:
        fail(
            f"{INSTALL}/{name}: {unrecorded} are read by the tier but reach the manifest through no recording helper "
            "(harmon_needs / harmon_npm_global / harmon_uv_tool) — the VM would install them and not record them"
        )
    for var, key in sorted(recorded.items()):
        if var not in image_keys:
            fail(f"{INSTALL}/{name}: records {key}={var} but {DOCKERFILE}'s manifest layer has no entry for {var}")
        elif image_keys[var] != key:
            fail(f"{INSTALL}/{name}: records {var} as {key!r} but the image's manifest names it {image_keys[var]!r}")
    if tier in default_tiers:
        recorded_by_default |= set(recorded)
        consumed_by_default |= consumed
if consumed_by_default != recorded_by_default:
    fail(f"default tiers {sorted(default_tiers)}: pins consumed {sorted(consumed_by_default)} != pins recorded {sorted(recorded_by_default)}")
if not recorded_by_default:
    fail(f"{INSTALL}: no tier records any pin — the recording-helper regex no longer matches the call sites")

for e in errors:
    print(f"FAIL: {e}", file=sys.stderr)
if errors:
    print(f"test-bootstrap-remote: {len(errors)} issue(s) found", file=sys.stderr)
    sys.exit(1)

print(f"bootstrap-remote OK: {len(pins)} pin(s) in {VERSIONS}, all Renovate-extractable")
print(f"bootstrap-remote OK: {len(tier_scripts)} shared install script(s) declare no pin of their own")
print(f"bootstrap-remote OK: {len(head_pairs)} checksum pin-pair(s) agree with their version pin; {drift_note}")
print("bootstrap-remote OK: the image runs the same scripts, from the same versions file")
print("bootstrap-remote OK: no denied host, no 1Password/Homebrew/Tailscale, fetch list matches disk")
print("bootstrap-remote OK: a non-release-tag ref is refused; the override warns and names it")
print(f"bootstrap-remote OK: the default tiers record {len(recorded_by_default)} pin(s) for the manifest, under the image's keys")
PY
