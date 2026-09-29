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
import base64
import json
import os
import pathlib
import re
import subprocess
import sys

errors = []


def fail(msg):
    errors.append(msg)


def run_lifted(script, args=(), limit=120):
    """Run a harness built from code lifted out of the scripts under test.

    Bounded on purpose, and the bound is not optional: § 20 lifts a `while` loop
    out of the bootstrap, so an edit that stopped advancing it would HANG `task
    verify` rather than fail it — and a gate that hangs is worse than one that is
    wrong, because nothing reports it and the process outlives the run. Every
    harness in this file that executes lifted or sourced product code goes
    through here for that reason. A timeout comes back as None and reads as
    "could not run".
    """
    try:
        return subprocess.run(
            ["bash", "-s", *args], input=script, capture_output=True, text=True, timeout=limit
        )
    except subprocess.TimeoutExpired:
        return None


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
# A pin can also be typed straight into a command, where no variable is
# declared at all — `.../download/v3.53.1/task.tar.gz`, `npm install -g
# pkg@1.2.3`, `uv tool install pkg==1.2.3` each install a working tool and
# PIN_DECL never sees them. One invariant, with no version grammar per call
# shape: no non-comment line may carry a version-shaped literal (v?N.N.N, or a
# 64-hex digest) at all. Every such value arrives through a `${…}` expansion of
# a versions.env name, so the expansions are erased first and whatever version
# shape survives is a second pin owner.
VERSION_LITERAL = re.compile(
    r"(?<![A-Za-z0-9_.])v?[0-9]+\.[0-9]+\.[0-9]+(?![0-9])|(?<![0-9A-Za-z])[0-9a-f]{64}(?![0-9A-Za-z])"
)


def inlined_pin(line):
    if line.lstrip().startswith("#"):
        return None
    stripped = re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*", "", line)
    m = VERSION_LITERAL.search(stripped)
    return m.group(0) if m else None


# The detector's own contract, asserted here because the files it scans
# contain no offending line to prove it against (negative fixtures): a URL, an
# npm @version, a uv ==version, a digest — and the composed forms of each.
assert inlined_pin('curl "https://github.com/go-task/task/releases/download/v3.53.1/task.tar.gz"') == "v3.53.1"
assert inlined_pin('    "https://nodejs.org/dist/v24.21.0/node.tar.xz" \\') == "v24.21.0"
assert inlined_pin("npm install -g @openai/codex@0.155.1") == "0.155.1"
assert inlined_pin("uv tool install --force semgrep==1.177.0") == "1.177.0"
assert inlined_pin('harmon_verify_sha256 "$f" fa82fd8dde8e8eefdecada6aa0889666556cfceb690d06e0c3bca49eb3070a63') == (
    "fa82fd8dde8e8eefdecada6aa0889666556cfceb690d06e0c3bca49eb3070a63"
)
assert inlined_pin('    "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${arch}.tar.gz" |') is None
assert inlined_pin('    "https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}"') is None
assert inlined_pin('        npm install -g "${1}@${2}"') is None
assert inlined_pin('        uv tool install --force "${1}==${2}"') is None
assert inlined_pin('    harmon_verify_sha256 "${tmp}/${node_tarball}" "$node_sha"') is None
assert inlined_pin("# a comment may name v3.53.1: documentation, not a pin") is None
assert inlined_pin("    ubuntu 24.04, bash 3.2, git 2.43: two-part numbers are not versions here") is None

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
        literal = inlined_pin(line)
        if literal:
            fail(
                f"{path}:{i}: carries the version-shaped literal {literal!r} instead of a `${{…}}` "
                f"expansion of a {VERSIONS} name — a version typed into a URL, an npm @version, "
                "a uv ==version or a digest is a second pin owner"
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
# Without this, adding a tier script leaves the standalone recipe fetching an
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

# ── 8b. every archive is extracted in staging, never into the live prefix ───
# The install invariant (lib.sh harmon_install_archive_bin): download to
# staging, verify, extract IN staging, and move the binary into HARMON_BIN
# last. `curl … | tar -C "$HARMON_BIN"` violates it twice — a stream that dies
# mid-archive has already truncated the live tool — and it was removed from
# four sites after being fixed at one, so the rule is checked mechanically:
#   (a) no tar reads from a pipe (an archive is a file in staging first);
#   (b) every extracting tar names a -C target, and that target is a STAGING
#       directory: `$tmp`, `$HARMON_TMPDIR`, or a variable the same file
#       assigns from one of those (or from `mktemp -d`) — never HARMON_BIN,
#       HARMON_PREFIX, an absolute path, or the working directory.
# Shell lines are joined the way the shell reads them (a trailing `\`, `|`,
# `&&`, `||` continues the command) so a `-C` on a continuation line is seen
# with its tar.
# What this does NOT detect, by design (r5-6): a dashless `tar xzf`, an
# `unzip -d`, or a `curl -o` straight onto the live path — for those forms the
# invariant is enforced by routing every archive through the one install
# helper, and is reviewed rather than proved here.
STAGING_ASSIGN = re.compile(
    r'^\s*(?P<var>[A-Za-z_][A-Za-z0-9_]*)=["\']?(?:\$\{?(?P<src>tmp|HARMON_TMPDIR)\b|\$\(mktemp -d\))'
)
TAR_WORD = re.compile(r"(?:^|[\s;(])tar\s")
TAR_PIPED = re.compile(r"(?<!\|)\|(?!\|)\s*tar\s")
TAR_TARGET = re.compile(r"(?:\s-C\s+|\s--directory[= ])(?P<target>\"[^\"]*\"|'[^']*'|\S+)")
TAR_EXTRACTS = re.compile(r"\star\s+(?:\S+\s+)*?(?:-[A-Za-z]*x[A-Za-z]*|--extract|--get)\b")


def logical_lines(text):
    """Yield (first_line_no, joined_line) with comments dropped and continuations joined."""
    buf, start = "", None
    for i, raw in enumerate(text.splitlines(), 1):
        if raw.lstrip().startswith("#"):
            continue
        line = raw.rstrip()
        if start is None:
            start = i
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        if buf.rstrip().endswith(("|", "&&")) or re.search(r"(?<!\|)\|\|$", buf.rstrip()):
            buf += " "
            continue
        yield start, buf
        buf, start = "", None
    if buf:
        yield start, buf


def extraction_faults(text):
    """Every tar in `text` that streams from a pipe or extracts outside staging: (line, kind, why)."""
    staging = {"tmp", "HARMON_TMPDIR"}
    for _, line in logical_lines(text):
        m = STAGING_ASSIGN.match(line)
        if m:
            staging.add(m["var"])
    faults = []
    for line_no, line in logical_lines(text):
        if not TAR_WORD.search(" " + line):
            continue
        if TAR_PIPED.search(line):
            faults.append((line_no, "pipe", "tar reads from a pipe; download the archive into staging first"))
            continue
        if not TAR_EXTRACTS.search(" " + line):
            continue
        t = TAR_TARGET.search(line)
        if not t:
            faults.append((line_no, "no-target", "tar extracts with no -C, into whatever the working directory is"))
            continue
        target = t["target"].strip("\"'")
        v = re.match(r"^\$\{?(?P<var>[A-Za-z_][A-Za-z0-9_]*)(?::[^}]*)?\}?(?:/|$)", target)
        if not v or v["var"] not in staging:
            faults.append((line_no, "target", f"tar extracts into {target!r}, which is not a staging directory"))
    return faults


def fault_kinds(text):
    return [kind for _, kind, _ in extraction_faults(text)]


# The detector's own contract, proved against fixtures because the files it
# scans contain no offending line: the four removed sites, the two prefix
# forms, a bare extraction, and the staged shapes that must pass.
assert fault_kinds(
    'curl "${HARMON_CURL_OPTS[@]}" \\\n    "https://x/task.tar.gz" |\n    tar -xz -C "$HARMON_BIN" task\n'
) == ["pipe"]
assert fault_kinds(
    'curl "$u" |\n    tar -xz --strip-components=1 -C "$HARMON_BIN" \\\n        "lychee-x/lychee"\n'
) == ["pipe"]
assert fault_kinds('tar -xzf "${tmp}/a.tgz" -C "$HARMON_BIN" task') == ["target"]
assert fault_kinds('tar -xJf "$f" -C "${HARMON_PREFIX}" --strip-components=1') == ["target"]
assert fault_kinds("tar -xzf a.tgz -C /usr/local/bin gitleaks") == ["target"]
assert fault_kinds('tar --extract --file "$a" --directory "$HARMON_BIN"') == ["target"]
assert fault_kinds('tar -xzf "$a" -C "$cwd_of_choice"') == ["target"]
assert fault_kinds('tar -xzf "${tmp}/a.tgz" task') == ["no-target"]
assert fault_kinds('tar -xzf "${tmp}/gh.tar.gz" -C "$tmp" "${gh_dir}/bin/gh"') == []
assert fault_kinds('tar -xzf "$a" -C "${HARMON_TMPDIR}/x" --no-same-owner "$m"') == []
assert fault_kinds(
    'node_stage="${tmp}/node-${NODE_VERSION}"\nmkdir -p "$node_stage"\n'
    'tar -xJf "${tmp}/${node_tarball}" -C "$node_stage" \\\n    --strip-components=1 --no-same-owner\n'
) == []
assert fault_kinds('_s="${HARMON_TMPDIR:?first}/${_n}.stage"\ntar -xf "${_s}/archive" -C "$_s" --no-same-owner "$_m"\n') == []
assert fault_kinds('scratch="$(mktemp -d)"\ntar -xzf "$a" -C "$scratch"') == []
assert fault_kinds('tar -tzf "$a" | head -1') == []  # listing, not extracting
assert fault_kinds('# tar -xz -C "$HARMON_BIN" task: a comment') == []
assert fault_kinds('false || tar -xzf "$a" -C "$tmp"') == []  # `||` is not a pipe

for path in [BOOTSTRAP] + sorted(INSTALL.glob("*.sh")):
    for line_no, _kind, why in extraction_faults(path.read_text()):
        fail(
            f"{path}:{line_no}: {why} — every archive install goes through lib.sh "
            "harmon_install_archive_bin (stage, verify, extract in staging, move into HARMON_BIN last)"
        )

# ── 8c. every getent lookup survives a miss under pipefail ──────────────────
# HOME and the invoking user's home are read from passwd through
# `$(getent … | cut …)`. Under `set -euo pipefail` a miss (getent exits 2 for
# a uid or name with no entry) fails the pipeline, the substitution, and with
# it the script, so the `${…:-/root}` written on the next line never runs.
# Fixed once (challenge r1-7), reintroduced by round 4, refixed (r5-5), then
# found a fourth time in lib.sh's cache cleanup (review r1-3) because this
# check read the bootstrap alone: every getent substitution in the bootstrap
# AND in the shared install scripts must end in `|| true` so the fallback it
# is paired with is reachable.
for path in [BOOTSTRAP] + sorted(INSTALL.glob("*.sh")):
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#") or "$(getent" not in line:
            continue
        if "|| true)" not in line:
            fail(
                f"{path}:{line_no}: getent substitution without `|| true` — under pipefail a "
                "miss aborts the script before its :-/root fallback runs (r1-7/r5-5/review r1-3)"
            )

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
# The denied set is READ OUT of the network section's denied table in
# remote-environments.md, by the same parser that reads the allowed table for
# 10b, so the guard and the document cannot drift. It used to be a two-host
# tuple typed out here while the table listed six rows, which made the
# document's claim — that no denied host may appear in the install scripts or
# the Dockerfile — untrue of four of them (review r3 verification-1).
#
# Those hosts are denied on the Claude Code on the web VM, so an image that
# still used one could not share its install scripts at all. Two of them moved
# the image as well (Node now comes from nodejs.org, uv from its GitHub
# release); the rest have no call site left to move.
DOC = pathlib.Path("docs/architecture/remote-environments.md")
UNREACHED_MARKER = "no tier reaches it today"
HOST_CELL = re.compile(r"`([A-Za-z0-9.-]+)`")
doc_text = DOC.read_text() if DOC.exists() else ""
section = re.search(r"^### The network the bootstrap may use\n(.*?)(?=^## |^### |\Z)", doc_text, re.M | re.S)
doc_tables = re.split(r"\n\s*\n", section.group(1)) if section else ()
if not section:
    fail(f"{DOC}: no '### The network the bootstrap may use' section to read the host tables from")


def doc_hosts(first_column):
    """host -> the rest of the row, for one table of the network section.

    Both tables are read through this one parser, so neither can acquire its own
    notion of a well-formed row: a first column that is not a single backticked
    hostname FAILS rather than being dropped from the map (review r3
    verification-2 — a dropped row is a host the guard silently stops
    enforcing), the same strictness apt-mirrors.txt is read with below.
    """
    rows = {}
    table = next((t for t in doc_tables if t.lstrip().startswith(f"| {first_column} |")), None)
    if table is None:
        fail(f"{DOC}: the network section has no table whose first column is '{first_column}'")
        return rows
    for row in table.splitlines()[2:]:
        if not row.startswith("|"):
            continue
        cells = row.split("|")
        m = HOST_CELL.fullmatch(cells[1].strip())
        if not m:
            fail(
                f"{DOC}: the '{first_column}' table row {row.strip()!r} does not name one backticked "
                "hostname in its first column, so the guard cannot enforce it"
            )
            continue
        rows[m.group(1)] = "|".join(cells[2:]).strip().rstrip("|").strip()
    return rows


# host -> the rest of the row, because 10b's reverse direction is decided by the
# Why cell it carries.
allowed = doc_hosts("Allowed host")
denied = doc_hosts("Denied host")
if section and not denied:
    fail(f"{DOC}: the denied table names no host, so this section would enforce nothing")
for host in sorted(denied):
    if host in allowed:
        fail(f"{DOC}: {host} is listed as allowed but the remote adapter's network level denies it")

# One exemption, named here and enforced in BOTH directions. keybase.io is a
# denied row AND live code in the Dockerfile: it fetches HashiCorp's PGP key for
# the Terraform install, and Terraform is image-only, so the host is contacted
# at image build time and never on a VM. The exemption is scoped to the
# Dockerfile, so keybase.io still fails in the shared path — the bootstrap or
# install/*.sh, which is what would actually break a VM — and it fails when it
# goes STALE too: if nothing contacts the host any more, this entry and the
# paragraph the doc states the exception in are both wrong.
DENIED_EXEMPT = {"keybase.io": str(DOCKERFILE)}
denied_seen = {}
for label, text in (
    (str(DOCKERFILE), dockerfile_text),
    (str(BOOTSTRAP), bootstrap_text),
) + tuple((str(p), p.read_text()) for p in sorted(INSTALL.glob("*.sh"))):
    for host in sorted(denied):
        for i, line in enumerate(text.splitlines(), 1):
            if host not in line or line.lstrip().startswith("#"):
                continue
            denied_seen.setdefault(host, f"{label}:{i}")
            if DENIED_EXEMPT.get(host) == label:
                continue
            fail(f"{label}:{i}: contacts {host}, which the remote adapter's network level denies")
for host, where in sorted(DENIED_EXEMPT.items()):
    if host not in denied:
        fail(f"{DOC}: {host} is exempted here, but the denied table no longer lists it — drop the exemption")
    elif host not in denied_seen:
        fail(
            f"{where}: no longer contacts {host}, so its exemption above is stale — delete the exemption, "
            f"and the paragraph in {DOC} that states the exception"
        )

# ── 10b. the documented allowlist IS the host set the tiers reach ────────────
# Both directions of 10. The allowlist in remote-environments.md is what an
# adapter's network policy is configured from, so a host the scripts contact and
# the table omits is an install that fails only on the VM — and the omissions
# are the indirect ones: github.com (the 302 origin of every release download;
# release-assets.githubusercontent.com is only the target),
# files.pythonhosted.org (uv downloads wheels there; pypi.org is metadata only)
# and cdn.playwright.dev (the browsers tier's Chromium). Literal URL hosts are
# extracted from the scripts; the hosts a package manager reaches on the
# script's behalf are derived from the command that invokes it.
#
# The reverse direction is what stops this guard certifying an INCOMPLETE table
# (review r2-2): while the apt implication was a tuple typed out here, the table
# and the tuple agreed on one mirror and were wrong together, and a check that
# only asks "is everything reached listed?" cannot see that. So a listed host
# nothing reaches now fails too — it is either a host the doc invented or one
# whose call site was deleted, and an allowlist wider than the installs justify
# is a policy nobody can audit. A host deliberately allowed with no caller says
# so in its own Why column (UNREACHED_MARKER), and the guard then requires it
# NOT to be reached, so that exemption cannot hide a live call site either.
URL_HOST = re.compile(r"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
# The apt mirrors are written ONCE — images/devcontainer/install/apt-mirrors.txt
# — and derived from there by both consumers: this implication and, through the
# two directions below, the documented table. Enumerating them at this line
# missed a host three times (security.ubuntu.com serves amd64's security pocket
# from its own host; ports.ubuntu.com serves every arm64 pocket), so lengthening
# a tuple here is not the fix — the file is.
#
# `apt-get update` counts as much as `apt-get install`: a bare update contacts
# every mirror the VM's sources name, which is how noble-security is reached
# with no package installed at all.
APT_MIRRORS = INSTALL / "apt-mirrors.txt"
apt_mirrors = ()
if not APT_MIRRORS.exists():
    fail(f"{APT_MIRRORS}: missing — section 10b derives the apt implication from this file")
else:
    apt_mirrors = tuple(
        line.strip()
        for line in APT_MIRRORS.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )
    if not apt_mirrors:
        fail(f"{APT_MIRRORS}: names no mirror, so `apt-get` would imply no host at all")
    for mirror in apt_mirrors:
        if not re.fullmatch(r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}", mirror):
            fail(f"{APT_MIRRORS}: {mirror!r} is not a bare hostname (one host per line, `#` for comments)")
IMPLIED_HOSTS = (
    (re.compile(r"\bapt-get\s+(?:\S+\s+)*(?:install|update)\b"), apt_mirrors),
    (re.compile(r"\bnpm\s+install\b"), ("registry.npmjs.org",)),
    (re.compile(r"\buv\s+tool\s+install\b"), ("pypi.org", "files.pythonhosted.org")),
    (re.compile(r"\bplaywright\S*\s+install\b"), ("cdn.playwright.dev",)),
    (re.compile(r"github\.com/[^/\s\"']+/[^/\s\"']+/releases/download/"), ("release-assets.githubusercontent.com",)),
)


def implied_by(line):
    """The hosts section 10b derives from one script line — the real extractor,
    shared with the scenario cases below so they cannot test a stale copy."""
    hosts = set()
    for pattern, hosts_for in IMPLIED_HOSTS:
        if pattern.search(line):
            hosts.update(hosts_for)
    return hosts


reached = {}
for path in [BOOTSTRAP] + sorted(INSTALL.glob("*.sh")):
    for i, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for host in URL_HOST.findall(line):
            reached.setdefault(host, f"{path}:{i}")
        for host in implied_by(line):
            reached.setdefault(host, f"{path}:{i}")
if not reached:
    fail(f"{INSTALL}: no host reached by any install script — the host extractor no longer matches the call sites")
# The allowed map was parsed in 10, by the one parser the two tables share; the
# denied table's own direction is enforced there.
for host, where in sorted(reached.items()):
    if host not in allowed:
        fail(
            f"{where}: reaches {host}, which the allowed-host table in {DOC} does not list — an "
            "adapter configured from that table would block the install"
        )
    elif UNREACHED_MARKER in allowed[host]:
        fail(
            f"{DOC}: the {host} row claims '{UNREACHED_MARKER}', but {where} reaches it — the row is "
            "stale, and the exemption below is only sound while its claim is true"
        )
for host, why in sorted(allowed.items()):
    if host in reached or UNREACHED_MARKER in why:
        continue
    fail(
        f"{DOC}: lists {host} as allowed, but no install script and not the bootstrap reaches it — an "
        f"allowlist wider than the installs need; delete the row, or write '{UNREACHED_MARKER}' in its "
        "Why column the way the probed-but-unused rows do"
    )
# The two scenarios this restructure exists for, as explicit cases. Each is run
# through implied_by() — the extractor itself — so the file above and the
# documented table are both proved to cover it, and neither can regress quietly.
for scenario, script_line, host in (
    (
        "a bare `apt-get update` on stock noble refreshes the security pocket from its own host",
        "apt-get update",
        "security.ubuntu.com",
    ),
    (
        "arm64 apt traffic is served by ports, not by archive/security (arm64 is a declared target)",
        "apt-get install -y --no-install-recommends $packages",
        "ports.ubuntu.com",
    ),
):
    if host not in implied_by(script_line):
        fail(f"{APT_MIRRORS}: `{script_line}` does not imply {host} — {scenario}")
    elif host not in allowed:
        fail(f"{DOC}: the allowed-host table does not list {host} — {scenario}")

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

# ── 13. verify AND ci actually run this guard ───────────────────────────────
# Nothing anywhere enumerates this guard's inputs. A workflow path filter that
# tried to was wrong twice — it missed scripts/** and Taskfile.yml, then missed
# docs/architecture/remote-environments.md once section 10 began deriving the
# host tables from that document — so the list was deleted rather than extended
# a third time. What replaces it is this: the guard proves it runs at all, on
# both paths, and a filter it could fall behind no longer exists.
#
# Local. `task --dry` prints its plan on stderr, so merge the streams rather
# than reading stdout and concluding the task is missing.
plan = subprocess.run(
    ["task", "--dry", "verify"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
)
if plan.returncode != 0:
    fail("`task --dry verify` failed, so this guard's own wiring cannot be checked")
elif "./scripts/test-bootstrap-remote.sh" not in plan.stdout:
    fail("`task verify` does not run scripts/test-bootstrap-remote.sh")

# CI. The `lint` job specifically, not build.yml as a whole: lint is the job
# with no path filter, so it is the one placement that sees a PR touching any
# input the guard reads. The job's own block is sliced out by indentation so
# the step cannot satisfy this check from some other, filtered job.
BUILD = pathlib.Path(".github/workflows/build.yml")
build_lines = BUILD.read_text().splitlines()
if "jobs:" not in build_lines:
    fail(f"{BUILD}: no top-level `jobs:` key, so this guard's CI wiring cannot be checked")
else:
    lint_steps = []
    in_lint = False
    for line in build_lines[build_lines.index("jobs:") + 1 :]:
        job = re.fullmatch(r"  (?P<name>[A-Za-z0-9_-]+):\s*", line)
        if job:
            in_lint = job["name"] == "lint"
        elif in_lint:
            lint_steps.append(line)
    if not lint_steps:
        fail(f"{BUILD}: no `lint:` job found under `jobs:`, so this guard's CI wiring cannot be checked")
    elif not re.search(r"^\s*(?:- )?run: task test:bootstrap-remote\s*$", "\n".join(lint_steps), re.M):
        fail(
            f"{BUILD}: the lint job does not run `task test:bootstrap-remote`. That job is the only one with no "
            "path filter, so without this step a pull request editing an input this guard reads runs it in no CI job"
        )

# ── 14. the standalone trust root: only a release tag is accepted ───────────
# The ref is validated before the tier check and before the sudo re-exec, so
# these run unprivileged and touch nothing: a refused ref exits 1 with the
# reason, and an accepted-under-override ref gets past the ref check (to fail
# on the deliberately bogus tier instead) while naming itself in a warning.
def run_bootstrap(args, env_extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("HARMON_")}
    env.update(env_extra or {})
    # Bounded like run_lifted, and for the same reason: this runs the product
    # script itself, and a validation edit that stopped terminating would hang
    # `task verify` instead of failing it. These cases are all refusals, so the
    # bound is generous and still bounded.
    return subprocess.run(
        ["bash", str(BOOTSTRAP), *args], capture_output=True, text=True, env=env, timeout=120
    )


# The last two carry an embedded NEWLINE, which is the case a line-oriented
# `printf '%s' "$ref" | grep -Eq '^…$'` waved through: grep matches per LINE, so
# a value whose first line is a release tag passed as one. The check is a
# whole-string match now, as the install-prefix check already was.
for bad_ref in ("main", "feature/x", "1.2.3", "v1.2", "v1.2.3-rc1", "8b8e60f", "v1.2.3\nx", "v1.2.3\n"):
    r = run_bootstrap(["--ref", bad_ref, "--tiers", "no-such-tier"])
    if r.returncode != 1 or "not a release tag" not in r.stderr:
        fail(f"{BOOTSTRAP}: --ref {bad_ref!r} must be refused as 'not a release tag' (exit {r.returncode}: {r.stderr.strip()[:120]!r})")
for bad_env in ("main", "v1.2.3\nx"):
    r = run_bootstrap(["--tiers", "no-such-tier"], {"HARMON_INIT_REF": bad_env})
    if r.returncode != 1 or "not a release tag" not in r.stderr:
        fail(f"{BOOTSTRAP}: HARMON_INIT_REF={bad_env!r} must be refused the same way --ref {bad_env!r} is")
r = run_bootstrap(["--ref", "v1.2.4", "--tiers", "no-such-tier"], {"HARMON_INIT_REF": "v1.2.3"})
if r.returncode != 1 or "disagree" not in r.stderr:
    fail(f"{BOOTSTRAP}: --ref and HARMON_INIT_REF naming different tags must be refused as a disagreement")
r = run_bootstrap(["--ref", "v1.2.3", "--tiers", "no-such-tier"])
if r.returncode != 1 or "unknown tier" not in r.stderr or "not a release tag" in r.stderr:
    fail(f"{BOOTSTRAP}: --ref v1.2.3 must pass the ref check (and fail on the bogus tier instead)")
r = run_bootstrap(["--ref", "main", "--tiers", "no-such-tier"], {"HARMON_ALLOW_UNPINNED_REF": "1"})
if r.returncode != 1 or "unknown tier" not in r.stderr or "WARNING" not in r.stderr or "main" not in r.stderr:
    fail(f"{BOOTSTRAP}: HARMON_ALLOW_UNPINNED_REF=1 must let --ref main through with a WARNING naming the ref")

# The same recipe must also PROPAGATE A FAILED DOWNLOAD, which the tag check
# above cannot help with: a pipeline's exit status is its LAST command's, and the
# caller's shell has no pipefail, so `curl … | sudo bash` exits 0 when the
# download 404s or the transfer truncates. Every adapter copying it would then
# report a successful setup having installed nothing — and a truncated script has
# already run as root. The recipe therefore downloads to a file and runs it only
# on a successful download, which is a property of its SHAPE and so is checked
# here rather than remembered. Every copy is checked: they are copies of each
# other and one can be fixed alone. The third copy is the Claude Code on the web
# guide's setup script — the text a person pastes into the platform — which the
# guide says is the entrypoint "unchanged"; that claim is held below, not
# trusted.
#
# Comment markers are stripped and backslash continuations joined first, so the
# recipe is read as the one command it is — the pipe lives on a continuation
# line, where a line-by-line scan would not see it beside the URL.
RECIPE_URL = re.compile(r"raw\.githubusercontent\.com/evanharmon1/harmon-init/\S*bootstrap-remote\.sh")
PIPE_TO_SHELL = re.compile(r"\|\s*(?:sudo\b[^|]*?\s)?(?:ba|da|z|k)?sh\b")


def recipe_commands(text):
    joined, buf = [], ""
    for raw_line in text.splitlines():
        buf += re.sub(r"^\s*#\s?", "", raw_line)
        if buf.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1]
            continue
        joined.append(buf)
        buf = ""
    if buf:
        joined.append(buf)
    return [c for c in joined if RECIPE_URL.search(c)]


GUIDE = pathlib.Path("docs/guides/claude-code-web.md")
if not GUIDE.exists():
    fail(f"{GUIDE} is missing, so its copy of the standalone recipe cannot be checked — move this check with it")
guide_text = GUIDE.read_text() if GUIDE.exists() else ""

for label, text in ((BOOTSTRAP, bootstrap_text), (DOC, doc_text), (GUIDE, guide_text)):
    commands = recipe_commands(text)
    if not commands:
        fail(
            f"{label}: no documented standalone recipe found (nothing fetches bootstrap-remote.sh from the raw "
            "URL), so this check enforces nothing — move the recipe back or move this check to where it went"
        )
    for command in commands:
        shown = " ".join(command.split())[:160]
        if PIPE_TO_SHELL.search(command):
            fail(
                f"{label}: the documented standalone recipe pipes the download straight into a shell. A pipeline "
                "reports its LAST command's status, so a failed or truncated download exits 0 and an adapter "
                f"reports a setup that installed nothing: {shown!r}"
            )
        if not re.search(r"(?:^|\s)-o(?:\s|=)", command):
            fail(
                f"{label}: the documented standalone recipe does not download to a file (`curl … -o <file>`), so "
                f"nothing can short-circuit the run when the download fails: {shown!r}"
            )
        # …and that file goes in a PRIVATE directory. A bare `mktemp` put the
        # script in shared /tmp, which makes /tmp the script's own directory —
        # where any local user could pre-create a /tmp/install/lib.sh for a root
        # process to source. § 19 is the other, independent half and the one that
        # holds without the recipe: given a --ref, which this recipe always
        # passes, the script reads nothing beside itself, so that planted file is
        # never consulted. This half is still asserted because a recipe adapters
        # copy must not create the condition in the first place. The mode is
        # asserted as well as the `-d`, because "mktemp -d defaults to 0700" is a
        # fact about an implementation and not a promise the recipe makes.
        if re.search(r"\$\(\s*mktemp\s*\)|`\s*mktemp\s*`", command) or not re.search(r"mktemp\s+-d", command):
            fail(
                f"{label}: the documented standalone recipe does not download into a private directory "
                f"(`mktemp -d`). A bare `mktemp` lands in shared /tmp, which becomes the script's own directory "
                f"and makes /tmp/install/lib.sh a sibling asset any local user can plant: {shown!r}"
            )
        if not re.search(r"chmod\s+0?700\b", command):
            fail(
                f"{label}: the documented standalone recipe does not state the temporary directory's mode "
                f"(`chmod 0700`), so its privacy rests on mktemp's default rather than on the recipe: {shown!r}"
            )

# The shape checks above prove each copy SAFE; they do not prove the guide's copy
# is the SAME recipe — a guide that added an install line, dropped `--ref`, or
# pinned a different variable would still pass them. So the guide's fenced block
# must equal the architecture document's, line for line. Two differences are
# allowed, and both are spelled out here rather than tolerated by a looser match:
# a single `#!/bin/bash` as the first line, because the platform's setup-script
# field is a script file of its own; and the HARMON_INIT_REF= value (below).
# Anything else — a second leading line, a different interpreter, an edit
# anywhere inside — fails.
GUIDE_SHEBANG = "#!/bin/bash"


def recipe_blocks(text):
    blocks, current = [], None
    for line in text.splitlines():
        if re.match(r"^\s*```", line):
            if current is None:
                current = []
            else:
                blocks.append(current)
                current = None
        elif current is not None:
            current.append(line)
    return [b for b in blocks if RECIPE_URL.search("\n".join(b))]


doc_recipes, guide_recipes = recipe_blocks(doc_text), recipe_blocks(guide_text)
if len(doc_recipes) != 1:
    fail(f"{DOC}: expected exactly one fenced standalone recipe to compare the guide against, found {len(doc_recipes)}")
if len(guide_recipes) != 1:
    fail(f"{GUIDE}: expected exactly one fenced setup-script recipe, found {len(guide_recipes)}")
# The one value the two copies may legitimately disagree on is the tag. The
# architecture document keeps the placeholder, while the guide tells its reader to
# pin the first release that carries the bootstrap — so the HARMON_INIT_REF= value
# is compared as a slot, and the guide's value must be the placeholder or a
# concrete release tag (never a branch such as main).
REF_LINE = re.compile(r"^(\s*HARMON_INIT_REF=)(\S+)(.*)$")
GUIDE_REF_OK = re.compile(r"^(vX\.Y\.Z|v[0-9]+\.[0-9]+\.[0-9]+)$")


def ref_slot(block):
    out, values = [], []
    for line in block:
        m = REF_LINE.match(line)
        if m:
            values.append(m.group(2))
            line = f"{m.group(1)}<tag>{m.group(3)}"
        out.append(line)
    return out, values


if len(doc_recipes) == 1 and len(guide_recipes) == 1:
    guide_body = guide_recipes[0]
    if guide_body[:1] == [GUIDE_SHEBANG]:
        guide_body = guide_body[1:]
    guide_body, guide_refs = ref_slot(guide_body)
    doc_body, doc_refs = ref_slot(doc_recipes[0])
    for value in doc_refs:
        if value != "vX.Y.Z":
            fail(f"{DOC}: HARMON_INIT_REF={value!r} must stay the generic placeholder vX.Y.Z; only the guide pins a release tag")
    for value in guide_refs:
        if not GUIDE_REF_OK.match(value):
            fail(f"{GUIDE}: HARMON_INIT_REF={value!r} must be the placeholder vX.Y.Z or a release tag vMAJOR.MINOR.PATCH")
    if guide_body != doc_body:
        first = next(
            (i for i, (g, d) in enumerate(zip(guide_body, doc_body)) if g != d),
            min(len(guide_body), len(doc_body)),
        )
        got = guide_body[first] if first < len(guide_body) else "<end of block>"
        want = doc_body[first] if first < len(doc_body) else "<end of block>"
        fail(
            f"{GUIDE}: the setup-script recipe is not the architecture document's recipe (only a leading "
            f"{GUIDE_SHEBANG!r} may differ). First difference at recipe line {first + 1}: {got!r}, expected {want!r}"
        )

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
    r'\bharmon_needs(?:_all)?\s+(?P<key1>[a-z0-9-]+)\s+"\$(?P<var1>[A-Z0-9_]+_VERSION)"'
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
            "(harmon_needs / harmon_needs_all / harmon_npm_global / harmon_uv_tool) — the VM would install them "
            "and not record them"
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

# ── 15b. the manifest revision names the assets that were actually run ──────
# write_manifest() read the local checkout's HEAD whenever `self_dir` merely
# existed, while the tiers use local assets only when `asset_dir == self_dir`
# (review r2-3). Run the standalone entry from inside an unrelated repository
# with --ref and the manifest attested that repository's commit for bytes it
# never supplied — an image-to-VM diff then compares against a revision with no
# connection to what is installed.
#
# The function is EXECUTED, not pattern-matched, and its text is lifted from
# bootstrap-remote.sh so this case cannot pass against a stale copy of it. Both
# sides of the gate are asserted: a fetched install must name the ref, and a
# local-checkout install must still name HEAD — a gate that simply never took
# the checkout branch would satisfy the first on its own.
wm_start = bootstrap_text.find("write_manifest() {")
wm_end = bootstrap_text.find("\n}\n", wm_start)
tag_re_decl = re.search(r"^readonly HARMON_RELEASE_TAG_RE='([^']+)'", bootstrap_text, re.M)
if wm_start < 0 or wm_end < 0:
    fail(f"{BOOTSTRAP}: no write_manifest() function to exercise — the manifest provenance case cannot run")
elif not tag_re_decl:
    fail(f"{BOOTSTRAP}: HARMON_RELEASE_TAG_RE is not a single-quoted literal, so the harness cannot reuse it")
elif not order:
    fail(f"{BOOTSTRAP}: HARMON_TIER_ORDER is not a double-quoted literal, so the harness cannot reuse it")
else:
    harness = r"""
set -euo pipefail
# Stubs for the run-record helpers only; nothing the revision is decided by.
warn() { printf 'warn: %s\n' "$*" >&2; }
harmon_skip() { :; }
harmon_changed() { :; }
harmon_arch() { printf 'amd64\n'; }
tab="$(printf '\t')"
HARMON_RELEASE_TAG_RE='@TAG_RE@'
HARMON_TIER_ORDER='@TIER_ORDER@'
tiers=core,agents
ref=v9.9.9
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
change_log="${root}/record"
printf 'tool%stask=3.45.4\n' "$tab" >"$change_log"

new_repo() { # a real git checkout, committed clean, with nothing else in it
    mkdir -p "$1"
    git -C "$1" init -q >/dev/null 2>&1
    printf 'unrelated\n' >"$1/README.md"
    git -C "$1" add README.md >/dev/null 2>&1
    git -C "$1" -c user.name=t -c user.email=t@e -c commit.gpgsign=false \
        commit -q -m init >/dev/null 2>&1
    git -C "$1" rev-parse --verify HEAD
}

@WRITE_MANIFEST@
}

# (1) the standalone entry sits in a FOREIGN repo; the assets were fetched.
foreign_head="$(new_repo "${root}/foreign")"
fetched="${root}/fetched"
mkdir -p "$fetched"
cp '@GENERATOR@' "${fetched}/generate-manifest.sh"
self_dir="${root}/foreign"
asset_dir="$fetched"
assets_local=0
manifest_dir="${root}/m-foreign"
write_manifest
printf 'FOREIGN_HEAD %s\n' "$foreign_head"
printf 'FOREIGN_REVISION %s\n' "$(jq -r .image.revision "${manifest_dir}/manifest.json")"

# (2) the assets came from the checkout beside this file.
local_head="$(new_repo "${root}/local")"
cp '@GENERATOR@' "${root}/local/generate-manifest.sh"
git -C "${root}/local" add generate-manifest.sh >/dev/null 2>&1
git -C "${root}/local" -c user.name=t -c user.email=t@e -c commit.gpgsign=false \
    commit -q -m gen >/dev/null 2>&1
local_head="$(git -C "${root}/local" rev-parse --verify HEAD)"
self_dir="${root}/local"
asset_dir="$self_dir"
assets_local=1
manifest_dir="${root}/m-local"
write_manifest
printf 'LOCAL_HEAD %s\n' "$local_head"
printf 'LOCAL_REVISION %s\n' "$(jq -r .image.revision "${manifest_dir}/manifest.json")"
# The tier field is the ONE canonical value `tiers` holds, not a second
# derivation from the caller's string.
printf 'LOCAL_TIERS %s\n' "$(jq -r '.image.tiers // "none"' "${manifest_dir}/manifest.json")"

# (3) the same checkout, DIRTY: the commit is still named, suffixed, because the
# cleanliness read SUCCEEDED and said the tree had changed.
printf 'uncommitted\n' >>"${root}/local/README.md"
manifest_dir="${root}/m-dirty"
write_manifest
printf 'DIRTY_REVISION %s\n' "$(jq -r .image.revision "${manifest_dir}/manifest.json")"

# (4) the cleanliness read FAILS. `git status --porcelain` prints nothing both
# when a checkout is clean and when the command failed outright, so an empty
# answer from a FAILED read must not be attested as a clean commit — and must
# not fall through to the release tag either, since the assets came from the
# checkout and the tag supplied none of them. No manifest at all is the only
# honest outcome, and this stub makes the failure happen without breaking the
# rev-parse beside it.
git() {
    case " $* " in
    *" status "*) return 128 ;;
    esac
    command git "$@"
}
manifest_dir="${root}/m-unreadable"
write_manifest
unset -f git
if [ -f "${manifest_dir}/manifest.json" ]; then
    printf 'UNREADABLE_STATUS %s\n' "$(jq -r .image.revision "${manifest_dir}/manifest.json")"
else
    printf 'UNREADABLE_STATUS none\n'
fi
"""
    harness = (
        harness.replace("@TAG_RE@", tag_re_decl.group(1))
        .replace("@TIER_ORDER@", order.group(1))
        .replace("@WRITE_MANIFEST@", bootstrap_text[wm_start:wm_end])
        .replace("@GENERATOR@", str(IMG / "generate-manifest.sh"))
    )
    run = run_lifted(harness)
    out = {} if run is None else dict(
        line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
    )
    if run is None or run.returncode != 0 or len(out) != 7:
        fail(
            f"{BOOTSTRAP}: the manifest provenance case could not run "
            f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
            f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
        )
    else:
        if out["DIRTY_REVISION"] != f"{out['LOCAL_HEAD']}-dirty":
            fail(
                f"{BOOTSTRAP}: write_manifest recorded revision {out['DIRTY_REVISION']!r} for a checkout with "
                f"uncommitted changes at {out['LOCAL_HEAD'][:12]} — a successful status read that reports a dirty "
                "tree must still suffix the commit, or restructuring the read has dropped the `-dirty` marker"
            )
        if out["UNREADABLE_STATUS"] != "none":
            fail(
                f"{BOOTSTRAP}: the cleanliness probe failed and write_manifest still attested revision "
                f"{out['UNREADABLE_STATUS']!r}. `git status --porcelain` prints nothing when it FAILS as well as "
                "when the tree is clean, so a manifest written off that read attests a clean commit for bytes "
                "nobody checked — absence and cleanliness are claims that need a successful read"
            )
        if out["LOCAL_TIERS"] != "core,agents":
            fail(
                f"{BOOTSTRAP}: the manifest recorded tiers {out['LOCAL_TIERS']!r} for a run whose canonical "
                "selection was 'core,agents' — the manifest field must consume the one canonical value, not a "
                "second parse of the caller's string"
            )
        if out["FOREIGN_REVISION"] != "v9.9.9":
            fail(
                f"{BOOTSTRAP}: write_manifest recorded revision {out['FOREIGN_REVISION']!r} for an install "
                f"whose assets were FETCHED at --ref v9.9.9 while the script sat in an unrelated checkout "
                f"(HEAD {out['FOREIGN_HEAD'][:12]}) — the revision must name the ref the bytes came from"
            )
        if out["LOCAL_REVISION"] != out["LOCAL_HEAD"]:
            fail(
                f"{BOOTSTRAP}: write_manifest recorded revision {out['LOCAL_REVISION']!r} for an install that "
                f"ran the assets beside it, whose checkout is at {out['LOCAL_HEAD'][:12]} — gating the revision "
                "on the local assets must not stop a local run naming its commit"
            )

# ── 16. a version number is not a completeness check ────────────────────────
# A block that publishes SEVERAL executables can be interrupted after the one the
# gate reads as its version witness and before the rest. A gate that consults the
# version alone then skips that block on every later run, so the prefix keeps a
# pinned witness beside a missing sibling and re-running never repairs it: the
# run dies on the missing npm, or on a uvx the Semgrep and Foreman wrappers
# invoke directly. lib.sh's harmon_needs_all is the conjunction that fixes it —
# EXECUTED here, because a pattern match cannot tell whether the conjunction is
# the right way round.
completeness = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HARMON_PREFIX="$root"
export HARMON_BIN="${root}/bin"
. '@LIB@'
harmon_ensure_bin
PATH="${HARMON_BIN}:${PATH}"

stub() { # stub <name> <what its version command prints>
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" >"${HARMON_BIN}/$1"
    chmod 0755 "${HARMON_BIN}/$1"
}
verdict() { # verdict <label> <gate...>
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then printf '%s needs\n' "$label"; else printf '%s skips\n' "$label"; fi
}

# Node: the pinned version witness present, a sibling missing — what an
# interrupted FIRST install leaves behind, where there is no older node for the
# version comparison to catch.
stub node "v9.9.9"
verdict NODE_NPM_ABSENT harmon_needs_all node 9.9.9 npm npx corepack -- node --version
stub npm "9.9.9"
stub npx "9.9.9"
stub corepack "9.9.9"
verdict NODE_COMPLETE harmon_needs_all node 9.9.9 npm npx corepack -- node --version
rm -f "${HARMON_BIN}/npx"
verdict NODE_NPX_ABSENT harmon_needs_all node 9.9.9 npm npx corepack -- node --version

# uv: the tarball carries uv AND uvx while the version command reads uv alone.
stub uv "uv 8.8.8"
verdict UV_UVX_ABSENT harmon_needs_all uv 8.8.8 uvx -- uv --version
stub uvx "uvx 8.8.8"
verdict UV_COMPLETE harmon_needs_all uv 8.8.8 uvx -- uv --version

# The version half is untouched: a complete prefix at the WRONG version still
# installs, or this would have traded one blind spot for another.
stub node "v1.1.1"
verdict NODE_WRONG_VERSION harmon_needs_all node 9.9.9 npm npx corepack -- node --version
"""
run = run_lifted(completeness.replace("@LIB@", str(INSTALL / "lib.sh")))
verdicts = {} if run is None else dict(
    line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
)
expected = {
    "NODE_NPM_ABSENT": "needs",
    "NODE_COMPLETE": "skips",
    "NODE_NPX_ABSENT": "needs",
    "UV_UVX_ABSENT": "needs",
    "UV_COMPLETE": "skips",
    "NODE_WRONG_VERSION": "needs",
}
if run is None or run.returncode != 0 or len(verdicts) != len(expected):
    fail(
        f"{INSTALL}/lib.sh: the completeness cases could not run "
        f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
        f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
    )
else:
    for case, want in expected.items():
        got = verdicts.get(case)
        if got != want:
            fail(
                f"{INSTALL}/lib.sh: harmon_needs_all {case} {got!r}, expected {want!r} — a block must re-run "
                "unless its version witness is at the pin AND every executable it publishes is present"
            )

# …and the two call sites that need it name every executable their block
# publishes, or the helper is correct and unused where it matters.
core_text = (INSTALL / "install-core.sh").read_text()
for gated, companions in (("node", ["corepack", "npm", "npx"]), ("uv", ["uvx"])):
    site = re.search(rf'^if harmon_needs_all {gated} "\$[A-Z0-9_]+_VERSION" (.+?) -- ', core_text, re.M)
    if not site:
        fail(
            f"{INSTALL}/install-core.sh: the {gated} block is not gated on harmon_needs_all with a companion "
            f"list — {gated}'s version alone is no evidence the rest of the block's executables landed"
        )
    elif sorted(site.group(1).split()) != companions:
        fail(
            f"{INSTALL}/install-core.sh: the {gated} gate names companions {sorted(site.group(1).split())}, "
            f"expected {companions} — every other executable that block publishes"
        )

# ── 17. `task check` runs the markdownlint the bootstrap installed ──────────
# The bootstrap's CI job runs `task check` last and claims it uses only what the
# bootstrap installed. scripts/markdownlint.sh is where that was false: `npx
# --yes markdownlint-cli2@<pin>` resolves a local or remote npm PACKAGE and never
# the global binary install-core.sh puts on PATH, so the gate re-downloaded what
# it had just been given — and an environment whose egress closes after setup
# could not run it at all. The dispatcher therefore prefers a PATH binary AT THE
# PIN, and the version match is the safety condition: preferring any PATH binary
# would silently downgrade every machine carrying an older global copy, the
# `latest` failure that pin exists to prevent, in reverse. Executed with stubs,
# because which binary a dispatcher CHOOSES is not visible in its text.
MARKDOWNLINT = pathlib.Path("scripts/markdownlint.sh")
pin_decl = re.search(r"^MARKDOWNLINT_VERSION=(\S+)$", MARKDOWNLINT.read_text(), re.M)
if not pin_decl:
    fail(f"{MARKDOWNLINT}: no MARKDOWNLINT_VERSION pin to compare a PATH binary against")
else:
    dispatch = r"""
set -euo pipefail
bash_bin="$(command -v bash)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export RECORD="${root}/record"
work="${root}/work"
mkdir -p "$work"

stub() { # stub <path> <label it records> <what --version prints> [<what --version exits>]
    mkdir -p "$(dirname "$1")"
    {
        printf '#!/bin/sh\n'
        printf 'if [ "$1" = "--version" ]; then printf "%%s\\n" "%s"; exit %s; fi\n' "$3" "${4:-0}"
        printf 'printf "%%s\\n" "%s" >>"$RECORD"\n' "$2"
    } >"$1"
    chmod 0755 "$1"
}
chose() { # chose <label> <stub dir>
    : >"$RECORD"
    (cd "$work" && PATH="$2" "$bash_bin" '@SCRIPT@' check README.md >/dev/null 2>&1) ||
        printf 'exited-non-zero\n' >>"$RECORD"
    printf '%s %s\n' "$1" "$(tr '\n' ',' <"$RECORD" | sed 's/,$//')"
}

matching="${root}/matching"
stub "${matching}/markdownlint-cli2" path 'markdownlint-cli2 v@PIN@ (markdownlint v0.41.1)'
stub "${matching}/npx" npx 'npx'
mismatched="${root}/mismatched"
stub "${mismatched}/markdownlint-cli2" path 'markdownlint-cli2 v0.0.1 (markdownlint v0.41.1)'
stub "${mismatched}/npx" npx 'npx'
neither="${root}/neither"
stub "${neither}/npx" npx 'npx'
# A damaged global install, or a wrapper whose runtime has moved: it prints the
# pinned banner and exits nonzero.
failing="${root}/failing"
stub "${failing}/markdownlint-cli2" path 'markdownlint-cli2 v@PIN@ (markdownlint v0.41.1)' 1
stub "${failing}/npx" npx 'npx'

chose MATCHING_PATH_BINARY "$matching"
chose MISMATCHED_PATH_BINARY "$mismatched"
chose FAILING_PATH_PROBE "$failing"
chose NO_PATH_BINARY "$neither"
stub "${work}/node_modules/.bin/markdownlint-cli2" local 'markdownlint-cli2 v@PIN@ (markdownlint v0.41.1)'
chose REPO_LOCAL_WINS "$matching"
"""
    run = run_lifted(
        dispatch.replace("@SCRIPT@", str(MARKDOWNLINT.resolve())).replace("@PIN@", pin_decl.group(1))
    )
    chosen = {} if run is None else dict(
        line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
    )
    expected = {
        "MATCHING_PATH_BINARY": "path",
        "MISMATCHED_PATH_BINARY": "npx",
        "FAILING_PATH_PROBE": "npx",
        "NO_PATH_BINARY": "npx",
        "REPO_LOCAL_WINS": "local",
    }
    if run is None or run.returncode != 0 or len(chosen) != len(expected):
        fail(
            f"{MARKDOWNLINT}: the dispatch cases could not run "
            f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
            f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
        )
    else:
        why = {
            "MATCHING_PATH_BINARY": "a PATH binary at the pin is what the bootstrap installed; npx would re-download it",
            "MISMATCHED_PATH_BINARY": "a PATH binary at the WRONG version must fall through, or the pin stops deciding",
            "FAILING_PATH_PROBE": "a read that can fail is not an answer: a binary that PRINTS the pinned banner "
            "and exits nonzero is a damaged install, not the pinned linter, and selecting it runs a broken "
            "executable where the npx fallback would have worked. The probe's status decides before its output",
            "NO_PATH_BINARY": "with nothing on PATH the pinned npx fallback must still run",
            "REPO_LOCAL_WINS": "node_modules/.bin stays first, so hooks and CI match the lockfile",
        }
        for case, want in expected.items():
            got = chosen.get(case)
            if got != want:
                fail(f"{MARKDOWNLINT}: {case} ran {got!r}, expected {want!r} — {why[case]}")

# ── 18. the install prefix: refused at the door, quoted where it is rendered ─
# HARMON_BIN is interpolated into /etc/profile.d/harmon-remote-env.sh, which this
# root process sources and so does every login shell on the machine afterwards. A
# prefix carrying a quote, a `$`, a backtick or a newline writes a broken drop-in
# and breaks every later login, persistently — so the value is validated before
# anything else runs (unprivileged, like the ref check, which is why these cases
# can run at all) and quoted at the render site as well. Both halves are checked:
# the refusals below pin the ADMITTED set as tightly as the refused one, because a
# validator that quietly started accepting a space would put the corruption back.
for bad_prefix, why in (
    ("/opt/$(id -u)", "a command substitution the login shell would run"),
    ("/opt/`id -u`", "a backtick substitution the login shell would run"),
    ('/opt/"harmon"', "a double quote, which closes the quoting around it"),
    ("/opt/harmon bin", "a space"),
    ("/opt/a:b", "a colon, which cannot survive as a PATH entry"),
    ("opt/harmon", "a relative path, so nothing pins where the tools went"),
    ("/opt/harmon\nexport EVIL=1", "a newline — a line-oriented check would accept this"),
):
    r = run_bootstrap(["--tiers", "no-such-tier"], {"HARMON_PREFIX": bad_prefix})
    if r.returncode != 1 or "is not a safe absolute path" not in r.stderr:
        fail(
            f"{BOOTSTRAP}: HARMON_PREFIX {bad_prefix!r} must be refused as an unsafe path ({why}) before anything "
            f"else runs (exit {r.returncode}: {r.stderr.strip()[:160]!r})"
        )
for bad_bin in ("/opt/bin:/tmp/bin", "/opt/$(whoami)/bin", "/opt/bin\nPATH=/tmp"):
    r = run_bootstrap(["--tiers", "no-such-tier"], {"HARMON_BIN": bad_bin})
    if r.returncode != 1 or "is not a safe absolute path" not in r.stderr:
        fail(
            f"{BOOTSTRAP}: HARMON_BIN {bad_bin!r} must be refused as an unsafe path too. It is the value the "
            "drop-in renders, `sudo -E` carries it where the sudo re-exec does not, and validating only the "
            f"prefix it is usually derived from leaves that path open (exit {r.returncode}: "
            f"{r.stderr.strip()[:160]!r})"
        )
r = run_bootstrap(["--tiers", "no-such-tier"], {"HARMON_PREFIX": "/opt/harmon-remote_env.1+2@x"})
if r.returncode != 1 or "unknown tier" not in r.stderr or "safe absolute path" in r.stderr:
    fail(
        f"{BOOTSTRAP}: an ordinary absolute prefix of path characters must pass the prefix check (and fail on the "
        f"bogus tier instead), or a legitimate HARMON_PREFIX has been made unusable (exit {r.returncode}: "
        f"{r.stderr.strip()[:160]!r})"
    )

# The other half, in the heredoc that becomes the drop-in: every interpolation of
# the prefix must open its double quote immediately before the value. Validation
# stops a hostile prefix; the quoting is what keeps an awkward-but-admitted one
# from splitting a word in a file every login shell reads. A rendered COMMENT line
# is exempt — it cannot be split, only newline-terminated, which validation
# refuses.
profile_start = bootstrap_text.find('cat >"$tmp" <<PROFILE\n')
profile_end = bootstrap_text.find("\nPROFILE\n", profile_start)
if profile_start < 0 or profile_end < 0:
    fail(f"{BOOTSTRAP}: no PROFILE heredoc to check — the drop-in quoting case cannot run")
else:
    body = bootstrap_text[profile_start + len('cat >"$tmp" <<PROFILE\n'):profile_end]
    for line in body.splitlines():
        if "${HARMON_BIN}" not in line or line.lstrip().startswith("#"):
            continue
        if '"${HARMON_BIN}' not in line or line.count("${HARMON_BIN}") != line.count('"${HARMON_BIN}'):
            fail(
                f"{BOOTSTRAP}: the profile drop-in interpolates the prefix unquoted, so a prefix containing a "
                f"space would write a drop-in that breaks every login shell: {line.strip()[:120]!r}"
            )

# ── 19. with a ref, the assets come from the TAG and nowhere else ───────────
# The sibling-asset branch SOURCES ${self_dir}/install/lib.sh as root, and
# self_dir is wherever the caller put this file: a standalone recipe that
# downloaded it with a bare `mktemp` made that directory shared /tmp, where any
# unprivileged local user could pre-create /tmp/install/lib.sh for root to
# source. An ownership-and-permissions predicate on that directory was deleted
# rather than hardened a third time, because a check-then-source decision about
# a directory an attacker may own cannot be won: what holds instead is that the
# directory is NEVER CONSULTED when a ref was given. § 14 holds the recipe's
# shape, which is the second and independent reason; this holds the one that does
# not depend on every adapter copying the recipe correctly.
#
# EXECUTED, not pattern-matched: which directory the assets come from is a
# decision, and the block is lifted out of bootstrap-remote.sh and planted as a
# real file inside each candidate directory, because `BASH_SOURCE` is how that
# decision is made. curl is stubbed so the fetch is observable offline, and it
# writes a MARKER different from the planted sibling's, so "the tag was the
# source" is proved by the bytes the run would go on to execute rather than by
# a flag alone.
locate_start = bootstrap_text.find("# ---------- locate the install scripts ----------")
locate_end = bootstrap_text.find('export HARMON_VERSIONS_FILE="${asset_dir}/versions.env"')
if locate_start < 0 or locate_end < 0:
    fail(f"{BOOTSTRAP}: the asset-location block could not be lifted — the asset-directory cases cannot run")
else:
    worker = r"""set -euo pipefail
die() { printf 'bootstrap-remote: %s\n' "$*" >&2; exit 1; }
warn() { printf 'bootstrap-remote: WARNING: %s\n' "$*" >&2; }
HARMON_REPO_RAW='https://harmon-init.invalid'
HARMON_REMOTE_ASSETS='
versions.env
generate-manifest.sh
install/lib.sh
'
ref="${HARNESS_REF-v9.9.9}"
curl() {
    _dest=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -o)
            _dest="$2"
            shift 2
            ;;
        *) shift ;;
        esac
    done
    [ -n "$_dest" ] || return 1
    printf 'FETCHED\n' >"$_dest"
}
""" + bootstrap_text[locate_start:locate_end] + r"""
printf 'ASSETS_LOCAL %s\n' "$assets_local"
# The bytes the run would go on to source as root, named by their marker. This is
# the half a flag cannot prove: `assets_local=0` says the fetch branch was taken,
# while this says the lib.sh about to be sourced is the fetched one.
printf 'LIB_SOURCE %s\n' "$(cat "${asset_dir}/install/lib.sh")"
"""
    driver = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'chmod -R u+rwx "$root" >/dev/null 2>&1 || true; rm -rf "$root"' EXIT

plant() { # plant <dir> — the lifted block, as a real file, with a sibling asset
    mkdir -p "${1}/install"
    printf '%s' '@WORKER_B64@' | base64 -d >"${1}/bootstrap-remote.sh"
    printf 'SIBLING\n' >"${1}/install/lib.sh"
    printf 'SIBLING\n' >"${1}/versions.env"
}

run_case() { # run_case <label> <dir> -> <label> <local>:<lib-source>
    _label="$1"
    _dir="$2"
    _out=""
    _out="$(bash "${_dir}/bootstrap-remote.sh" 2>"${root}/${_label}.err")" || true
    _local="$(printf '%s\n' "$_out" | sed -n 's/^ASSETS_LOCAL //p')"
    _lib="$(printf '%s\n' "$_out" | sed -n 's/^LIB_SOURCE //p')"
    printf '%s %s:%s\n' "$_label" "${_local:-none}" "${_lib:-none}"
}

# A ref was given and perfectly ordinary private siblings sit beside the script:
# the tag still wins, because there is no preference to compute.
private="${root}/private"
plant "$private"
chmod 0700 "$private" "${private}/install"
run_case REF_WITH_PRIVATE_SIBLINGS "$private"

# The escalation shape itself: the script's own directory is world-writable, so
# any local user could have planted that install/lib.sh. Nothing beside the
# script is read, which is why its mode and owner no longer have to be judged.
shared="${root}/shared"
plant "$shared"
chmod 0777 "$shared"
chmod 0777 "${shared}/install"
run_case REF_WITH_WORLD_WRITABLE_SIBLINGS "$shared"

# No ref: the documented checkout form, where the siblings are the only thing
# there is to run — and the offline path the remote-bootstrap CI job takes.
checkout="${root}/checkout"
plant "$checkout"
chmod 0700 "$checkout" "${checkout}/install"
export HARNESS_REF=""
run_case NO_REF_USES_SIBLINGS "$checkout"

# No ref and no siblings: a hard failure naming the fix, never a run that
# installs nothing and exits 0.
bare="${root}/bare"
plant "$bare"
rm -rf "${bare}/install" "${bare}/versions.env"
run_case NO_REF_NO_SIBLINGS "$bare"
if grep -q 'not beside this file' "${root}/NO_REF_NO_SIBLINGS.err"; then
    printf 'NO_REF_NO_SIBLINGS_REASON named\n'
else
    printf 'NO_REF_NO_SIBLINGS_REASON silent\n'
fi
unset HARNESS_REF
""".replace("@WORKER_B64@", base64.b64encode(worker.encode()).decode())
    run = run_lifted(driver)
    got = {} if run is None else dict(
        line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
    )
    expected = {
        "REF_WITH_PRIVATE_SIBLINGS": "0:FETCHED",
        "REF_WITH_WORLD_WRITABLE_SIBLINGS": "0:FETCHED",
        "NO_REF_USES_SIBLINGS": "1:SIBLING",
        "NO_REF_NO_SIBLINGS": "none:none",
        "NO_REF_NO_SIBLINGS_REASON": "named",
    }
    why = {
        "REF_WITH_PRIVATE_SIBLINGS": "a ref names the ONLY source. Preferring siblings when they look safe is "
        "what made the trust root the directory rather than the tag, and it is the branch whose ownership "
        "predicate had to be deleted — a run given a tag must fetch from it even where the siblings are fine",
        "REF_WITH_WORLD_WRITABLE_SIBLINGS": "this is the root-privilege escalation: a world-writable directory "
        "beside the script is an install/lib.sh any local user can write, and the lifted block must source the "
        "FETCHED bytes instead. `assets_local=0` alone would not prove it — the marker is the proof",
        "NO_REF_USES_SIBLINGS": "with no ref there is nothing else to run: the documented checkout form and the "
        "CI job that exercises the working tree's own scripts both depend on the siblings being used",
        "NO_REF_NO_SIBLINGS": "no ref and no assets beside the file is a hard failure, never a run that reports "
        "success having installed nothing",
        "NO_REF_NO_SIBLINGS_REASON": "the failure has to name the fix (pass --ref), or the operator is left "
        "guessing at what a bootstrap that stopped immediately wanted",
    }
    if run is None or run.returncode != 0 or len(got) != len(expected):
        fail(
            f"{BOOTSTRAP}: the asset-source cases could not run "
            f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
            f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
        )
    else:
        for case, want in expected.items():
            if got.get(case) != want:
                fail(
                    f"{BOOTSTRAP}: asset-source case {case} gave {got.get(case)!r} "
                    f"(assets_local:lib-marker), expected {want!r} — {why[case]}"
                )

# ── 20. the tier selection is ONE canonical value ───────────────────────────
# Validation used to split on commas AND whitespace while every later membership
# check split on commas alone, so `--tiers 'core, agents'` validated and then
# installed core only — the run exiting 0 reporting a selection it had not
# installed. EXECUTED, because the canonical spelling is the whole point and a
# pattern match cannot see it.
canon_start = bootstrap_text.find('tiers_given="$tiers"')
canon_end = bootstrap_text.find("# ---------- privilege ----------")
default_decl = re.search(r'^readonly HARMON_DEFAULT_TIERS="([^"]+)"', bootstrap_text, re.M)
if canon_start < 0 or canon_end < 0 or not order or not default_decl:
    fail(f"{BOOTSTRAP}: the tier canonicalisation block could not be lifted — its cases cannot run")
else:
    # The trim's character class must not be one whose members the ambient locale
    # decides. This block runs long before set_locale forces C.UTF-8 — it has to,
    # so a refused selection costs nothing and can be proved without root — and a
    # POSIX [:space:] class there makes the canonical tier set depend on the
    # environment, in a file whose own header warns about that exact trap. The
    # cases below cannot see this: they pass under either spelling, because the
    # locale that would separate them is not the one the harness runs in.
    # COMMENTS are exempt, and deliberately: the comment that explains why the
    # class was replaced has to be able to name it, and a check that forbade that
    # would be enforced by deleting the explanation.
    canon_code = "\n".join(
        line
        for line in bootstrap_text[canon_start:canon_end].splitlines()
        if not line.lstrip().startswith("#")
    )
    if "[:space:]" in canon_code:
        fail(
            f"{BOOTSTRAP}: the tier canonicalisation trims with a POSIX [:space:] class, whose members the "
            "ambient locale decides, and it runs long before set_locale forces C.UTF-8. Trim with an explicit "
            "ASCII class (space and tab) instead, or move the canonicalisation after the locale is forced — "
            "which costs the pre-re-exec refusal this block is placed here for"
        )
    canon = (
        "set -euo pipefail\n"
        "HARMON_TIER_ORDER='" + order.group(1) + "'\n"
        "die() { printf 'REFUSED\\n'; exit 1; }\n"
        'tiers="$1"\n'
        + bootstrap_text[canon_start:canon_end]
        + "printf 'CANONICAL %s\\n' \"$tiers\"\n"
    )
    cases = [
        ("core,agents", "core,agents", "the ordinary spelling is unchanged"),
        ("core, agents", "core,agents", "whitespace after a comma was the original defect"),
        (" core ,\tagents ", "core,agents", "surrounding whitespace is trimmed, tabs included"),
        ("agents,core", "core,agents", "one selection spells itself one way, in tier order"),
        ("core,core", "core", "a repeated element collapses rather than being installed twice"),
        ("browsers,core", "core,browsers", "order comes from HARMON_TIER_ORDER, not the caller"),
        ("core,agents,browsers", "core,agents,browsers", "every tier at once still canonicalises to itself"),
        ("core,,agents", "REFUSED", "an empty element is a typo, not a tier"),
        ("core,agents,", "REFUSED", "a trailing comma is the same typo"),
        ("", "REFUSED", "an empty selection installs nothing and must say so"),
        ("core,nope", "REFUSED", "an unknown element is refused by name"),
        ("core agents", "REFUSED", "whitespace INSIDE an element is one unknown tier, never two"),
        ("c*", "REFUSED", "a glob must not match a run of the known names in a case pattern"),
        # These two are why membership is an equality test and not `case " $order
        # " in *" $tier "*`: in a case pattern the element is a GLOB and the known
        # tiers are one space-separated string, so `agents browsers` and `c*` both
        # matched a RUN of the known names, were accepted as a tier, and then
        # vanished from the canonical set — leaving `core` alone and a run that
        # exits 0 having installed less than was asked for. Exactly the defect
        # this section exists for, arriving through the validator instead.
        ("core,agents browsers", "REFUSED", "a multi-word element must not match a run of the known tiers"),
        ("core,c*", "REFUSED", "nor may a glob, which would silently reduce the selection to core"),
        ("agents", "REFUSED", "core is the base every other tier builds on"),
    ]
    cases.append((default_decl.group(1), default_decl.group(1), "the shipped default must already be canonical"))
    for given, want, because in cases:
        run = run_lifted(canon, (given,), limit=30)
        if run is None:
            fail(
                f"{BOOTSTRAP}: canonicalising --tiers {given!r} did not terminate. The loop must advance past a "
                "comma or break on every pass — a `continue` that skips the advance spins forever"
            )
            continue
        got = run.stdout.strip().splitlines()[-1] if run.stdout.strip() else ""
        got = got[len("CANONICAL "):] if got.startswith("CANONICAL ") else got
        if got != want:
            fail(
                f"{BOOTSTRAP}: --tiers {given!r} canonicalised to {got!r}, expected {want!r} — {because}"
            )

# …and nothing downstream re-derives it. The manifest's tier field was the second
# derivation, which is how an unnormalised selection could have been RECORDED as a
# tier set the install loop never ran.
if wm_start >= 0 and wm_end >= 0:
    wm_text = bootstrap_text[wm_start:wm_end]
    if 'HARMON_MANIFEST_TIERS="$tiers"' not in wm_text:
        fail(
            f"{BOOTSTRAP}: write_manifest does not pass the canonical `$tiers` as HARMON_MANIFEST_TIERS — the "
            "manifest field must consume the one canonical value rather than deriving its own"
        )
    if re.search(r"for \w+ in \$HARMON_TIER_ORDER", wm_text):
        fail(
            f"{BOOTSTRAP}: write_manifest loops over HARMON_TIER_ORDER again — a second parse of the tier "
            "selection is exactly what the canonical value replaced, and two parses will disagree again"
        )

# ── 21. abandoned staging files are reaped by LIVENESS, never by age ────────
# Putting the pid in the staging name closed the interleave race between two
# concurrent runs and, on its own, made every abandoned staging file permanently
# unreapable: a later run has a different pid, and a tool already at the pin never
# reaches harmon_install_bin at all. Both properties have to hold at once, which
# is why this is executed against real files rather than asserted about the name.
reap = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HARMON_PREFIX="$root"
export HARMON_BIN="${root}/bin"
. '@LIB@'
harmon_ensure_bin

# A writer that is GONE: a child this shell has already reaped.
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
: >"${HARMON_BIN}/.gone.${dead}.harmon-staging"
# A writer that is LIVE: this very process.
: >"${HARMON_BIN}/.live.$$.harmon-staging"
# A name with no pid field: not something this wrote, so not something it deletes.
: >"${HARMON_BIN}/.nopid.harmon-staging"

# The sweep every tier runs, whether or not it installs anything — which is the
# half that matters, since a tool already at the pin is skipped entirely.
harmon_ensure_bin

state() { # state <label> <path>
    if [ -e "$2" ]; then printf '%s kept\n' "$1"; else printf '%s reaped\n' "$1"; fi
}
state DEAD_WRITER "${HARMON_BIN}/.gone.${dead}.harmon-staging"
state LIVE_WRITER "${HARMON_BIN}/.live.$$.harmon-staging"
state NO_PID_FIELD "${HARMON_BIN}/.nopid.harmon-staging"

# And a publish that FAILS removes its own staging path rather than leaving one
# for a later sweep: the sweep is the fallback for interruptions no handler sees
# (a kill, a power loss), not the routine path.
printf 'x\n' >"${root}/src"
mv() { return 1; }
(harmon_install_bin "${root}/src" failtool) >/dev/null 2>&1 || true
unset -f mv
if [ -n "$(find "$HARMON_BIN" -maxdepth 1 -name '.failtool.*.harmon-staging' -print -quit)" ]; then
    printf 'FAILED_PUBLISH kept\n'
else
    printf 'FAILED_PUBLISH reaped\n'
fi
"""
run = run_lifted(reap.replace("@LIB@", str(INSTALL / "lib.sh")))
reaped = {} if run is None else dict(
    line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
)
expected = {
    "DEAD_WRITER": "reaped",
    "LIVE_WRITER": "kept",
    "NO_PID_FIELD": "kept",
    "FAILED_PUBLISH": "reaped",
}
why = {
    "DEAD_WRITER": "a staging file whose writer is gone is litter, and a later run has a different pid, so "
    "nothing but a liveness sweep will ever remove it",
    "LIVE_WRITER": "deleting a live writer's staging file is the exact race the pid in the name exists to "
    "prevent — reaping by age or by pattern alone would do it",
    "NO_PID_FIELD": "a name this code did not write is left alone rather than guessed at",
    "FAILED_PUBLISH": "a writer about to die should clean up after itself instead of relying on the sweep",
}
if run is None or run.returncode != 0 or len(reaped) != len(expected):
    fail(
        f"{INSTALL}/lib.sh: the staging-reap cases could not run "
        f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
        f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
    )
else:
    for case, want in expected.items():
        if reaped.get(case) != want:
            fail(f"{INSTALL}/lib.sh: staging case {case} was {reaped.get(case)!r}, expected {want!r} — {why[case]}")

# ── 21b. …and for the manifest, the toolchain's OTHER staged write ───────────
# generate-manifest.sh stages and renames for the same reason harmon_install_bin
# does, and on a VM the manifest it protects is the only record of what is
# installed there. It cannot call lib.sh's helper — both callers run it as its own
# PROCESS, which inherits no shell functions, and the image build copies this one
# file into /usr/local/sbin with no lib.sh to source — so the predicate is
# duplicated there, and a duplicate nothing exercises is a duplicate that drifts.
# Executed against the real generator and real files, as § 21 is.
manifest_reap = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HARMON_MANIFEST_DIR="${root}/share"
export HARMON_MANIFEST_NAME=harmon-remote-env
manifest="${HARMON_MANIFEST_DIR}/manifest.json"
gen() { bash '@GENERATOR@' "$1" amd64 task=3.45.4; }
gen 1111111111111111111111111111111111111111

# A writer that is GONE: a child this shell has already reaped.
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
: >"${manifest}.${dead}.harmon-staging"
# A writer that is LIVE: this very process.
: >"${manifest}.$$.harmon-staging"
# A name with no pid field: not something this wrote, so not something it deletes.
: >"${manifest}.harmon-staging"

# The same revision again, so the content is byte-identical and the staging
# branch is never reached — which is the run that must sweep anyway, and the
# overwhelmingly common one on a VM that re-runs the bootstrap.
gen 1111111111111111111111111111111111111111

state() { # state <label> <path>
    if [ -e "$2" ]; then printf '%s kept\n' "$1"; else printf '%s reaped\n' "$1"; fi
}
state MANIFEST_DEAD_WRITER "${manifest}.${dead}.harmon-staging"
state MANIFEST_LIVE_WRITER "${manifest}.$$.harmon-staging"
state MANIFEST_NO_PID_FIELD "${manifest}.harmon-staging"

# And a publish that FAILS removes its own staging path. The generator is a
# separate process, so `mv` is broken through PATH rather than a shell function,
# and every staging file planted above is cleared first so the only one this can
# find is the failed run's own.
rm -f "${manifest}".*.harmon-staging "${manifest}.harmon-staging"
shim="${root}/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' >"${shim}/mv"
chmod 0755 "${shim}/mv"
if PATH="${shim}:${PATH}" gen 2222222222222222222222222222222222222222 >/dev/null 2>&1; then
    printf 'MANIFEST_FAILED_PUBLISH_STATUS zero\n'
else
    printf 'MANIFEST_FAILED_PUBLISH_STATUS nonzero\n'
fi
if [ -n "$(find "$HARMON_MANIFEST_DIR" -maxdepth 1 -name 'manifest.json.*.harmon-staging' -print -quit)" ]; then
    printf 'MANIFEST_FAILED_PUBLISH kept\n'
else
    printf 'MANIFEST_FAILED_PUBLISH reaped\n'
fi
"""
run = run_lifted(manifest_reap.replace("@GENERATOR@", str(IMG / "generate-manifest.sh")))
staged = {} if run is None else dict(
    line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
)
expected = {
    "MANIFEST_DEAD_WRITER": "reaped",
    "MANIFEST_LIVE_WRITER": "kept",
    "MANIFEST_NO_PID_FIELD": "kept",
    "MANIFEST_FAILED_PUBLISH_STATUS": "nonzero",
    "MANIFEST_FAILED_PUBLISH": "reaped",
}
why = {
    "MANIFEST_DEAD_WRITER": "an abandoned manifest staging file is a full-size file in the prefix that nothing "
    "else will ever remove: a later run has a different pid, and the common run writes nothing here at all "
    "because the manifest has not changed — so the sweep cannot be conditional on the write",
    "MANIFEST_LIVE_WRITER": "deleting a live writer's staging file is the race the pid in the name exists to "
    "prevent, and two bootstraps on one VM are exactly that case",
    "MANIFEST_NO_PID_FIELD": "a name this code did not write is left alone rather than guessed at",
    "MANIFEST_FAILED_PUBLISH_STATUS": "a manifest that could not be published must fail the run; exiting 0 "
    "would report a VM whose record of what is installed was never written",
    "MANIFEST_FAILED_PUBLISH": "a writer about to die cleans up after itself instead of relying on the sweep",
}
if run is None or run.returncode != 0 or len(staged) != len(expected):
    fail(
        f"{IMG}/generate-manifest.sh: the manifest staging cases could not run "
        f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
        f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
    )
else:
    for case, want in expected.items():
        if staged.get(case) != want:
            fail(
                f"{IMG}/generate-manifest.sh: manifest staging case {case} was {staged.get(case)!r}, "
                f"expected {want!r} — {why[case]}"
            )

# ── 22. a version probe must SUCCEED as well as match ───────────────────────
# The helper preserved the probe's exit status and the comparison discarded it, so
# a binary that printed the pinned version and exited nonzero was accepted as
# healthy, recorded in the manifest, and skipped on every later run. Fixed in the
# shared helper, so the property holds for every pinned tool rather than the ones
# somebody remembered — and executed here for the same reason § 16 is.
probe = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HARMON_PREFIX="$root"
export HARMON_BIN="${root}/bin"
. '@LIB@'
harmon_ensure_bin
PATH="${HARMON_BIN}:${PATH}"

probe() { # probe <what it prints> <what it exits>
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" >"${HARMON_BIN}/tool"
    chmod 0755 "${HARMON_BIN}/tool"
}
probe_long_banner() { # a probe whose banner is far larger than a pipe buffer
    {
        printf '#!/bin/sh\n'
        printf 'printf "tool 9.9.9\\n"\n'
        printf "yes 'bundled 8.8.8' | head -20000\n"
    } >"${HARMON_BIN}/tool"
    chmod 0755 "${HARMON_BIN}/tool"
}
verdict() { # verdict <label>
    if harmon_needs tool 9.9.9 tool --version >/dev/null 2>&1; then
        printf '%s needs\n' "$1"
    else
        printf '%s skips\n' "$1"
    fi
}

probe "tool 9.9.9" 0
verdict MATCHES_AND_SUCCEEDS
probe "tool 9.9.9" 1
verdict MATCHES_BUT_FAILS
probe "tool 1.1.1" 0
verdict MISMATCHES
probe_long_banner
verdict MATCHES_WITH_LONG_BANNER
probe "no version anywhere" 0
verdict NOTHING_TO_PARSE
"""
run = run_lifted(probe.replace("@LIB@", str(INSTALL / "lib.sh")))
probed = {} if run is None else dict(
    line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
)
expected = {
    "MATCHES_AND_SUCCEEDS": "skips",
    "MATCHES_BUT_FAILS": "needs",
    "MISMATCHES": "needs",
    "MATCHES_WITH_LONG_BANNER": "skips",
    "NOTHING_TO_PARSE": "needs",
}
why = {
    "MATCHES_AND_SUCCEEDS": "a healthy tool at the pin is still skipped, or every run reinstalls everything",
    "MATCHES_BUT_FAILS": "a probe that printed the pinned version and exited nonzero is a broken tool, not a "
    "healthy one — accepting it records it in the manifest and skips it forever",
    "MISMATCHES": "the version half of the decision is untouched",
    "MATCHES_WITH_LONG_BANNER": "requiring the probe to succeed must not make the PARSE's status matter. A "
    "banner larger than a pipe buffer makes `head -1` close the pipe while grep is still writing, so grep dies "
    "of SIGPIPE — and under pipefail that would read as a failed probe and reinstall a perfectly healthy tool "
    "on every run. The banner is oversized on purpose: a short one fits the buffer and proves nothing",
    "NOTHING_TO_PARSE": "a tool that answered but said nothing version-shaped is a mismatch, which reinstalls",
}
if run is None or run.returncode != 0 or len(probed) != len(expected):
    fail(
        f"{INSTALL}/lib.sh: the version-probe cases could not run "
        f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
        f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
    )
else:
    for case, want in expected.items():
        if probed.get(case) != want:
            fail(f"{INSTALL}/lib.sh: probe case {case} {probed.get(case)!r}, expected {want!r} — {why[case]}")

# ── 23. the pnpm shim is what it IS, not what it is called — and it must WIN ──
# `corepack enable pnpm` publishes its shim into HARMON_BIN, and the step running
# it was gated on `command -v pnpm` matching that path — a test of the NAME, which
# any executable sitting there passes. The Node copy does not remove files it does
# not own, so a standalone pnpm a pre-provisioned VM had already installed there
# survived every run while the tier reported Corepack configured. The gate now asks
# what the file IS, and that is EXECUTED here for § 16's reason: which files a
# content test accepts is not visible in its text.
#
# The pathname test did assert one real thing the identity check cannot — that our
# prefix wins PATH precedence — so the block reports a pnpm that shadows the shim
# rather than dropping the property or gating on it (gating would re-run corepack
# and report a change every run for something re-running cannot fix). Both halves
# are covered below, on their own axes, and the marker's 4096-byte read bound is
# exercised from both sides: the bound is LIFTED from the block rather than
# restated, so tightening it there cannot leave this asserting the old edge.
core_start = core_text.find("# ---------- corepack")
core_end = core_text.find("# ---------- uv ")
corepack_block = core_text[core_start:core_end] if core_start != -1 and core_end > core_start else ""
read_bound = re.search(r"head -c ([0-9]+)", corepack_block)
if "corepack enable pnpm" not in corepack_block:
    fail(
        f"{INSTALL}/install-core.sh: the corepack block could not be lifted from between its own section "
        "header and the uv one — the shim gate would then be silently untested"
    )
elif not read_bound:
    fail(
        f"{INSTALL}/install-core.sh: the shim read has no `head -c <bytes>` bound this test can lift, so the "
        "boundary cases below cannot be built at the real edge — and an unbounded read would stream a packed "
        "multi-megabyte pnpm into a shell variable to learn it is not a shim"
    )
else:
    shim = r"""
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HARMON_PREFIX="$root"
export HARMON_BIN="${root}/bin"
export HARMON_CHANGE_LOG="${root}/changes"
export RAN="${root}/ran"
. '@LIB@'
harmon_ensure_bin
mkdir -p "${root}/stub"
# HARMON_BIN on PATH as it is on every real target (/usr/local/bin), so `pnpm`
# resolving from the prefix is TRUE throughout except where a case plants a shadow
# in ${root}/stub, which sits ahead of it: the pathname test this replaced would
# pass every other case below, which is the whole point of the cases.
PATH="${root}/stub:${HARMON_BIN}:${PATH}"

# What `corepack enable` writes, as corepack writes it TODAY — these are the bytes
# of corepack's own dist/pnpm.js. It requires `module` BEFORE it requires its own
# library, which is why a marker may not key on the first require. The real one
# symlinks this into corepack's dist/; reading the shim's path follows that symlink
# to exactly these bytes.
shim_req="require('./lib/corepack.cjs').runMain(['pnpm', ...process.argv.slice(2)]);"
{
    printf '#!/usr/bin/env node\n'
    printf "process.env.COREPACK_ENABLE_DOWNLOAD_PROMPT??='1'\n"
    printf "require('module').enableCompileCache?.();\n"
    printf '%s\n' "$shim_req"
} >"${root}/shim"

# The shape older corepacks wrote: the same handoff and nothing before it. Both
# must be accepted, or an image whose Node ships either corepack re-runs the step
# and reports a change on every run.
{
    printf '#!/usr/bin/env node\n'
    printf '%s\n' "$shim_req"
} >"${root}/legacy-shim"

# A corepack that records THAT IT RAN and republishes the shim. `rm -f` first,
# because the real one replaces the shim and a bare `>` would instead follow a
# dangling symlink to a target whose directory is gone.
{
    printf '#!/bin/sh\n'
    printf 'printf "ran\\n" >>"$RAN"\n'
    printf 'rm -f "${HARMON_BIN}/pnpm"\n'
    printf 'cp "%s" "${HARMON_BIN}/pnpm"\n' "${root}/shim"
    printf 'chmod 0755 "${HARMON_BIN}/pnpm"\n'
} >"${root}/stub/corepack"
chmod 0755 "${root}/stub/corepack"

# A standalone pnpm, loading pnpm's OWN dist: used both AT the shim's path and as
# a PATH shadow ahead of it.
printf '#!/bin/sh\nexec node /opt/pnpm/dist/pnpm.cjs "$@"\n' >"${root}/standalone"
chmod 0755 "${root}/standalone"

# The read bound, from both sides. The padding is computed so that the last byte
# the marker needs — the final character of the `corepack` inside the require's
# quoted module path — lands exactly ON the last byte the read returns, and then
# one byte past it. Derived from the fixtures' own lengths and the bound lifted
# from the block, so neither edge is a second magic number.
read_bound=@BOUND@
corepack_word=corepack
shim_pre="${shim_req%%${corepack_word}*}"
shim_shebang='#!/usr/bin/env node'
# What precedes the require line: the shebang and its newline, then '//' opening a
# comment, then the padding, then that line's newline.
pad_overhead=$((${#shim_shebang} + 1 + 2 + 1))
edge_pad=$((read_bound - ${#shim_pre} - ${#corepack_word} - pad_overhead))
write_padded() { # write_padded <pad-bytes>
    {
        printf '%s\n' "$shim_shebang"
        printf '//'
        printf "%${1}s" '' | tr ' ' x
        printf '\n%s\n' "$shim_req"
    } >"${HARMON_BIN}/pnpm"
    chmod 0755 "${HARMON_BIN}/pnpm"
}

gate() {
@BLOCK@
}
verdict() { # verdict <label>
    : >"$RAN"
    : >"$HARMON_CHANGE_LOG"
    : >"${root}/err"
    gate >/dev/null 2>"${root}/err"
    if grep -q '^install' "$HARMON_CHANGE_LOG"; then _v=changed; else _v=skipped; fi
    if [ -s "$RAN" ]; then _v="${_v},ran"; else _v="${_v},idle"; fi
    # The shadow report is its own axis: the step owes one exactly when `pnpm` does
    # not resolve to the shim, and owes silence when it does. Never a record and
    # never an exit code, so idempotence reads the same either way.
    if grep -q 'WARNING: pnpm resolves to' "${root}/err"; then
        _v="${_v},reported"
    else
        _v="${_v},silent"
    fi
    # Nothing ELSE on stderr: for a packed binary it is the SHELL, not head, that
    # warns about the NUL bytes a substitution drops, so an unredirected read is
    # noisy — and that noise has to stay distinguishable from the report above.
    if grep -v 'WARNING: pnpm resolves to' "${root}/err" | grep -q .; then
        _v="${_v},noisy"
    else
        _v="${_v},quiet"
    fi
    printf '%s %s\n' "$1" "$_v"
}

rm -f "${HARMON_BIN}/pnpm"
verdict NO_SHIM_AT_ALL
# NO_SHIM_AT_ALL left the stub's shim behind, so this is the genuine article and
# the one case that may report nothing changed.
verdict GENUINE_SHIM
# The same genuine shim with a pre-provisioned pnpm ahead of it on PATH: still a
# skip, because corepack cannot move PATH, but it must SAY SO.
cp "${root}/standalone" "${root}/stub/pnpm"
chmod 0755 "${root}/stub/pnpm"
verdict GENUINE_SHIM_SHADOWED
rm -f "${root}/stub/pnpm"
# The older corepack's two-line shim, unshadowed again.
cp "${root}/legacy-shim" "${HARMON_BIN}/pnpm"
chmod 0755 "${HARMON_BIN}/pnpm"
verdict LEGACY_SHIM
# A standalone pnpm AT the shim's own path — the case the pathname test skipped.
cp "${root}/standalone" "${HARMON_BIN}/pnpm"
chmod 0755 "${HARMON_BIN}/pnpm"
verdict STANDALONE_PNPM
# A node-shaped wrapper around pnpm that merely MENTIONS corepack, which a
# bare-word marker accepts and pnpm's own sources give every chance to occur.
{
    printf '#!/usr/bin/env node\n'
    printf '// corepack is not used here; corepack enable would install one\n'
    printf "require('/opt/pnpm/dist/pnpm.cjs');\n"
} >"${HARMON_BIN}/pnpm"
chmod 0755 "${HARMON_BIN}/pnpm"
verdict NODE_WRAPPER_MENTIONS_COREPACK
# …and the same defect packed as a binary, which is also the NUL-byte case.
{ printf '\177ELF'; head -c 4096 /dev/zero; } >"${HARMON_BIN}/pnpm"
chmod 0755 "${HARMON_BIN}/pnpm"
verdict PACKED_PNPM_BINARY
# A packed pnpm whose own bytes carry the handoff string: pnpm bundles
# corepack-aware code, so this is the realistic packed case rather than the empty
# one above, and only the shebang anchor rejects it.
{
    printf '\177ELF'
    head -c 2048 /dev/zero
    printf '%s' "$shim_req"
    head -c 2048 /dev/zero
} >"${HARMON_BIN}/pnpm"
chmod 0755 "${HARMON_BIN}/pnpm"
verdict PACKED_PNPM_NAMING_COREPACK
if [ "$edge_pad" -lt 1 ]; then
    # Reported rather than skipped: a bound too small to pad up to is a finding
    # about the block, not a reason for these two cases to quietly not exist.
    printf 'BOUND_FIXTURE_UNBUILDABLE pad=%s\n' "$edge_pad"
else
    write_padded "$edge_pad"
    verdict MARKER_AT_WINDOW_EDGE
    write_padded "$((edge_pad + 1))"
    verdict MARKER_PAST_WINDOW
fi
# A shim whose target went away with a moved prefix: unreadable is not a skip.
ln -sf "${root}/removed-node/pnpm.js" "${HARMON_BIN}/pnpm"
verdict DANGLING_SHIM
"""
    run = run_lifted(
        shim.replace("@LIB@", str(INSTALL / "lib.sh"))
        .replace("@BLOCK@", corepack_block)
        .replace("@BOUND@", read_bound.group(1))
    )
    shimmed = {} if run is None else dict(
        line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
    )
    expected = {
        "NO_SHIM_AT_ALL": "changed,ran,silent,quiet",
        "GENUINE_SHIM": "skipped,idle,silent,quiet",
        "GENUINE_SHIM_SHADOWED": "skipped,idle,reported,quiet",
        "LEGACY_SHIM": "skipped,idle,silent,quiet",
        "STANDALONE_PNPM": "changed,ran,silent,quiet",
        "NODE_WRAPPER_MENTIONS_COREPACK": "changed,ran,silent,quiet",
        "PACKED_PNPM_BINARY": "changed,ran,silent,quiet",
        "PACKED_PNPM_NAMING_COREPACK": "changed,ran,silent,quiet",
        "MARKER_AT_WINDOW_EDGE": "skipped,idle,silent,quiet",
        "MARKER_PAST_WINDOW": "changed,ran,silent,quiet",
        "DANGLING_SHIM": "changed,ran,silent,quiet",
    }
    why = {
        "NO_SHIM_AT_ALL": "with no pnpm at all the step must run, or the prefix never gets a shim",
        "GENUINE_SHIM": "the shim corepack just wrote must skip AND leave corepack unrun, or every run reports a "
        "change it did not make and the bootstrap's idempotence claim is false",
        "GENUINE_SHIM_SHADOWED": "the shim is right and PATH is not: corepack enable cannot move PATH, so the step "
        "must skip and RECORD NOTHING — but silence here is the pathname test's property lost, and the tier would "
        "report Corepack configured while the pnpm a caller gets is the VM's",
        "LEGACY_SHIM": "the handoff without corepack's newer preamble is still the handoff; rejecting it would "
        "re-run the step on every run against an older Node's corepack",
        "STANDALONE_PNPM": "a name that can lie is not an answer: an executable that is not the shim must be "
        "recreated, or a pre-provisioned VM's pnpm survives forever while the tier reports Corepack configured",
        "NODE_WRAPPER_MENTIONS_COREPACK": "the marker is the launcher's handoff, not the word: a wrapper that "
        "loads pnpm's own dist and only mentions corepack in a comment is not a shim, and accepting it is the "
        "identity check reduced to a substring search",
        "PACKED_PNPM_BINARY": "the same defect packed as a binary — and the read must stay quiet as well as "
        "bounded, since the shell warns about the NUL bytes it drops from a substitution",
        "PACKED_PNPM_NAMING_COREPACK": "a packed pnpm carries corepack-aware strings of its own, so the word "
        "alone cannot decide this: what rejects it is that its first line is no node shebang",
        "MARKER_AT_WINDOW_EDGE": "a handoff ending on the last byte the read returns is inside the window and "
        "must be accepted, or the bound is tighter than the block documents",
        "MARKER_PAST_WINDOW": "one byte further out is outside it: the read is bounded on purpose, and a shim it "
        "cannot see must be recreated rather than skipped on a guess",
        "DANGLING_SHIM": "a shim whose target is gone is no answer either, and the pathname test skipped it",
    }
    if run is None or run.returncode != 0 or len(shimmed) != len(expected):
        fail(
            f"{INSTALL}/install-core.sh: the pnpm shim cases could not run "
            f"({'timed out' if run is None else f'exit {run.returncode}'}) — "
            f"stdout: {'' if run is None else run.stdout.strip()[-300:]!r} "
            f"stderr: {'' if run is None else run.stderr.strip()[:300]!r}"
        )
    else:
        for case, want in expected.items():
            got = shimmed.get(case)
            if got != want:
                fail(f"{INSTALL}/install-core.sh: pnpm shim case {case} {got!r}, expected {want!r} — {why[case]}")

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
print("bootstrap-remote OK: no piped or live-prefix tar extraction in install/*.sh or bootstrap-remote.sh")
print("bootstrap-remote OK: every getent substitution in the bootstrap and install/*.sh reaches its :-/root fallback on a miss")
print(f"bootstrap-remote OK: all {len(reached)} host(s) the tiers reach are on the documented allowlist")
print("bootstrap-remote OK: a non-release-tag ref is refused; the override warns and names it")
print(f"bootstrap-remote OK: the default tiers record {len(recorded_by_default)} pin(s) for the manifest, under the image's keys")
print("bootstrap-remote OK: the manifest revision names the assets actually run — the checkout's HEAD only when the checkout supplied them")
print("bootstrap-remote OK: the documented standalone recipe downloads to a file and is never a bare pipe into a shell, in all three copies")
print("bootstrap-remote OK: a block publishing several executables re-runs unless every one of them is present at the pin")
print("bootstrap-remote OK: markdownlint-cli2 resolves to a PATH binary at the pin, node_modules/.bin first, npx only as the fallback")
print("bootstrap-remote OK: an unsafe HARMON_PREFIX is refused before anything runs, and the drop-in quotes the prefix it renders")
print("bootstrap-remote OK: given a ref the assets come from the tag and the script's own directory is never read; without one the siblings are used or the run stops")
print("bootstrap-remote OK: the tier selection canonicalises once; no downstream consumer re-parses it")
print("bootstrap-remote OK: a staging file whose writer is gone is reaped, a live writer's is not, and a failed publish cleans up after itself")
print("bootstrap-remote OK: the manifest's own staged write reaps by liveness too, and a failed publish fails the run without leaving litter")
print("bootstrap-remote OK: a version probe that prints the pin and exits nonzero is treated as needing the install")
print("bootstrap-remote OK: the corepack step recreates the pnpm shim unless the file at its path really is corepack's launcher, at either edge of its bounded read, and reports a pnpm that shadows it on PATH")
PY
