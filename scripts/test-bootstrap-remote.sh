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
"""
    harness = (
        harness.replace("@TAG_RE@", tag_re_decl.group(1))
        .replace("@WRITE_MANIFEST@", bootstrap_text[wm_start:wm_end])
        .replace("@GENERATOR@", str(IMG / "generate-manifest.sh"))
    )
    run = subprocess.run(["bash", "-s"], input=harness, capture_output=True, text=True)
    out = dict(
        line.split(" ", 1) for line in run.stdout.splitlines() if line.count(" ") == 1
    )
    if run.returncode != 0 or len(out) != 4:
        fail(
            f"{BOOTSTRAP}: the manifest provenance case could not run (exit {run.returncode}) — "
            f"stderr: {run.stderr.strip()[:300]!r}"
        )
    else:
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
PY
