#!/usr/bin/env bash
# Root-only render guard (harmon-init#1727). The spec tables own assignments.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
repo="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$repo/specs/runner-routing-classes.md" ] || {
    echo "FAIL: routing assignment spec is missing" >&2
    exit 1
}
command -v copier >/dev/null || {
    echo "FAIL: copier not found — run task install" >&2
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/runner-routing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"
# Avoid auto-gc racing Copier's temporary local clones, as in test-template.sh.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=gc.autoDetach GIT_CONFIG_VALUE_1=false

# Both project types in both routing modes: Astro supplies Lighthouse and
# render-parity; web-app supplies its distinct secret-bearing lint branch.
# Maximal workflow options cover every conditional workflow filename.
for runner in ubuntu-latest self-hosted; do
    for project in web-astro web-app; do
        profile="$runner-$project"
        echo "Rendering routing fixture: $profile"
        if ! copier copy --trust --defaults --skip-tasks --vcs-ref=HEAD \
            --data project_name="Routing Test" \
            --data project_type="$project" \
            --data ci_runner="$runner" \
            --data ci_runner_labels="self-hosted,linux,x64,routing-test" \
            --data github_org=routing-test-org \
            --data author_git_provider_username=routing-test-author \
            --data project_management=github \
            --data include_terraform=true \
            --data devcontainer=true \
            --data use_codeql=true \
            --data use_release_please=true \
            --data use_skills_sync=true \
            --data deploy_cloudflare_workers=true \
            --data snyk_scan_schedule=weekly \
            --data release_content_paths=src \
            --data github_remote_create=false \
            --data github_release_init=false \
            --data run_task_install=false \
            --data bunch_add=false \
            --data obsidian_project_add=false \
            "$repo" "$work/$profile" >"$work/$profile.log" 2>&1; then
            cat "$work/$profile.log" >&2
            exit 1
        fi
    done
done

python3 - "$repo" "$work" <<'PY'
import json
import pathlib
import re
import sys

repo, work = map(pathlib.Path, sys.argv[1:])


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def assignments(heading):
    text = (repo / "specs/runner-routing-classes.md").read_text()
    marker = "### " + heading + "\n"
    require(marker in text, f"missing spec heading: {heading}")
    section = text.split(marker, 1)[1].split("\n### ", 1)[0]
    rows = {}
    for line in section.splitlines():
        if not line.startswith("| `"):
            continue
        workflow, job, cls, note = [cell.strip().strip("`") for cell in line.split("|")[1:-1]]
        key = (workflow, job)
        require(key not in rows, f"duplicate spec row {key}")
        require(cls in variables, f"unknown spec class {cls}")
        rows[key] = (cls, note)
    require(rows, f"no assignment rows in {heading}")
    return rows


variables = {
    "default": ("CI_RUNS_ON",),
    "multicore": ("MULTICORE_RUNS_ON", "CI_RUNS_ON"),
    "browser": ("BROWSER_RUNS_ON", "CI_RUNS_ON"),
    "image-build": ("IMAGE_BUILD_RUNS_ON", "CI_RUNS_ON"),
    "isolated": ("ISOLATED_RUNS_ON",),
}
template_rows = assignments("Template job assignment")
root_rows = assignments("Root-only job assignment")
require(not template_rows.keys() & root_rows.keys(), "root-only rows overlap template rows")


def expression(cls, default):
    fallback = '"ubuntu-latest"' if cls == "isolated" else default
    chain = " || ".join("vars." + var for var in variables[cls])
    return "${{ fromJSON(" + chain + " || '" + fallback + "') }}"


def placement(cls, note, default):
    ordinary = expression(cls, default)
    if "hard-coded `ubuntu-latest`" in note:
        return "ubuntu-latest"
    if "`merge_group` → `ubuntu-latest` ternary" in note:
        return "${{ github.event_name == 'merge_group' && 'ubuntu-latest' || " + ordinary[4:-3] + " }}"
    return ordinary


def resolve(value, values, merge_group=False):
    """Evaluate only the pinned placement grammar, without executing code."""
    if value == "ubuntu-latest":
        return value
    body = value.removeprefix("${{ ").removesuffix(" }}")
    prefix = "github.event_name == 'merge_group' && 'ubuntu-latest' || "
    if body.startswith(prefix):
        if merge_group:
            return "ubuntu-latest"
        body = body[len(prefix):]
    require(body.startswith("fromJSON(") and body.endswith(")"), f"unsupported expression {value}")
    args = body[len("fromJSON("):-1].split(" || ")
    for arg in args[:-1]:
        require(re.fullmatch(r"vars\.[A-Z_]+", arg), f"unsupported tier {arg}")
        if values.get(arg[5:]):
            return json.loads(values[arg[5:]])
    return json.loads(args[-1].strip("'"))


def check_tree(directory, rows, default):
    seen = set()
    runners = 0
    workflows = sorted((directory / ".github/workflows").glob("*.y*ml"))
    require(workflows, f"no workflows in {directory}")
    for path in workflows:
        text = path.read_text()
        # Deliberately require the repository's job/key indentation. An
        # unsupported shape fails rather than disappearing from enumeration.
        require("\njobs:\n" in text, f"missing jobs block: {path}")
        jobs_text = text.split("\njobs:\n", 1)[1]
        jobs = list(re.finditer(r"^  ([A-Za-z_][\w-]*):\s*$", jobs_text, re.M))
        require(jobs, f"no jobs: {path}")
        matched_runs = 0
        for i, match in enumerate(jobs):
            job = match[1]
            key = (path.name, job)
            require(key in rows, f"unassigned job {path.name}:{job}")
            seen.add(key)
            cls, note = rows[key]
            block = jobs_text[match.end():jobs[i + 1].start() if i + 1 < len(jobs) else len(jobs_text)]
            runs = re.findall(r"^    runs-on: (.+)$", block, re.M)
            callers = re.findall(r"^    uses: (.+)$", block, re.M)
            if not runs:
                require(len(callers) == 1 and "no `runs-on`" in note,
                        f"{path.name}:{job} has neither placement nor documented reusable call")
                # A reusable caller must resolve to the local callee's class.
                callee = callers[0].removeprefix("./.github/workflows/")
                require(callers[0].startswith("./.github/workflows/"), f"unknown callee {callers[0]}")
                require((callee, job) in rows and rows[(callee, job)][0] == cls,
                        f"{path.name}:{job} callee class mismatch")
                require((directory / ".github/workflows" / callee).is_file(), f"missing callee {callee}")
                continue
            require(len(runs) == 1 and not callers, f"ambiguous runs-on in {path.name}:{job}")
            actual = runs[0]
            expected = placement(cls, note, default)
            require(actual == expected,
                    f"{path.name}:{job} ({cls})\n  expected: {expected}\n  actual:   {actual}")
            no_vars = resolve(actual, {})
            pinned = actual == "ubuntu-latest"
            target = "ubuntu-latest" if cls == "isolated" or pinned else json.loads(default)
            require(no_vars == target, f"{path.name}:{job} unset variables resolve to {no_vars!r}")
            # Empty variables must take the same fallback as missing variables.
            require(resolve(actual, {v: "" for vs in variables.values() for v in vs}) == target,
                    f"{path.name}:{job} empty-variable fallback")
            require(resolve(actual, {"CI_RUNS_ON": '["default-pool"]'}) ==
                    ("ubuntu-latest" if cls == "isolated" or pinned else ["default-pool"]),
                    f"{path.name}:{job} CI_RUNS_ON precedence or isolation")
            if not pinned:
                override = {
                    var: '["class-pool"]' if var == variables[cls][0] else '["default-pool"]'
                    for var in {"CI_RUNS_ON", variables[cls][0]}
                }
                require(resolve(actual, override) == ["class-pool"], f"{path.name}:{job} class override")
            if "`merge_group`" in note:
                require(resolve(actual, {v: '["other"]' for vs in variables.values() for v in vs}, True)
                        == "ubuntu-latest", f"{path.name}:{job} lost merge-group pin")
            matched_runs += 1
        require(matched_runs == len(re.findall(r"^\s*runs-on:", text, re.M)),
                f"unparsed runs-on in {path}")
        runners += matched_runs
    print(f"runner routing OK: {directory.name}: {len(seen)} jobs, {runners} runs-on")
    return seen


def applicable(note, project):
    # Parenthesized project restrictions in the spec distinguish the Astro
    # browser/render jobs; prose such as lint's temporary web-app secret does
    # not restrict the job to that project type.
    projects = re.search(r"\((web-(?:astro|app)(?:/web-(?:astro|app))*)\)", note)
    return not note.startswith("Future ") and (not projects or project in projects[1].split("/"))


template_workflows = {
    re.sub(r"\[%.*?%\]", "", path.name).removesuffix(".jinja")
    for path in (repo / "template/.github/workflows").iterdir() if path.is_file()
}
require(template_workflows, "no template workflow files found")
for directory in sorted(p for p in work.glob("*-web-*") if p.is_dir()):
    profile = re.fullmatch(r"(ubuntu-latest|self-hosted)-(web-astro|web-app)", directory.name)
    require(profile, f"unknown fixture profile: {directory.name}")
    default = (json.dumps(["self-hosted", "linux", "x64", "routing-test"])
               if profile[1] == "self-hosted" else '"ubuntu-latest"')
    seen = check_tree(directory, template_rows, default)
    workflows = {p.name for p in (directory / ".github/workflows").glob("*.y*ml")}
    require(template_workflows <= workflows,
            f"{directory.name}: template workflows missing from fixture: "
            f"{sorted(template_workflows - workflows)}")
    required = {key for key, (_, note) in template_rows.items()
                if key[0] in workflows and applicable(note, profile[2])}
    require(required <= seen,
            f"{directory.name}: spec jobs missing from rendered workflows: {sorted(required - seen)}")
root_seen = check_tree(repo, template_rows | root_rows, '"ubuntu-latest"')
require(root_rows.keys() <= root_seen, f"root-only rows not exercised: {root_rows.keys() - root_seen}")
print(f"runner routing: per-fixture spec jobs and all {len(template_workflows)} template workflows covered; "
      "hosted/self-hosted fallbacks and merge-group pins verified")
PY
