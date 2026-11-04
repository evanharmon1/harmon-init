#!/usr/bin/env python3
"""Measure selected dependency PRs using GitHub's timeline and workflow runs."""

import argparse
import datetime as dt
import json
import subprocess
import sys


def api(endpoint):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", endpoint],
        check=True, capture_output=True, text=True,
    )
    pages = json.loads(result.stdout)
    return [item for page in pages for item in page] if pages else []


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def measure(pr, timeline, runs):
    """Return observable counts; force pushes are only possible rebases."""
    human_events = {"commented", "reviewed", "head_ref_force_pushed"}
    interventions = sum(
        1 for event in timeline
        if event.get("event") in human_events
        and (event.get("actor") or {}).get("type") == "User"
    )
    force_pushes = sum(event.get("event") == "head_ref_force_pushed" for event in timeline)
    attempts = sum(max(0, run["run_attempt"] - 1) for run in runs)
    age = (timestamp(pr["merged_at"]) - timestamp(pr["created_at"])).total_seconds() / 86400
    return interventions, attempts, age, force_pushes


def load_evidence(data, repo, cycle, prs):
    """Count cited records only for explicitly complete, bound measures."""
    if data["repo"] != repo or data["cycle"] != cycle:
        raise ValueError("evidence repository or cycle does not match")
    result = {}
    for entry in data["pull_requests"]:
        number = entry["number"]
        if number not in prs or number in result:
            raise ValueError("evidence PR is unselected or duplicated")
        result[number] = {}
        for name in ("interventions", "reruns", "rebases"):
            if name not in entry:
                continue
            measure_data = entry[name]
            if not isinstance(measure_data["complete"], bool):
                raise ValueError("evidence completeness must be boolean")
            records = measure_data["records"]
            if not isinstance(records, list) or any(
                not isinstance(ref, str) or not ref.strip() for ref in records
            ):
                raise ValueError("every evidence record needs a source reference")
            if measure_data["complete"]:
                if len(set(records)) != len(records):
                    raise ValueError("duplicate evidence references")
                result[number][name] = len(records)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub OWNER/REPO")
    parser.add_argument("--cycle", required=True, help="cycle label")
    parser.add_argument("--start", required=True, help="inclusive UTC date YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="exclusive UTC date YYYY-MM-DD")
    parser.add_argument("--pr", required=True, type=int, action="append", help="dependency PR number; repeat for every merged update")
    parser.add_argument("--evidence", help="JSON file of reviewed, cited run records")
    args = parser.parse_args()
    try:
        start = dt.datetime.fromisoformat(args.start).replace(tzinfo=dt.timezone.utc)
        end = dt.datetime.fromisoformat(args.end).replace(tzinfo=dt.timezone.utc)
        if start >= end or len(set(args.pr)) != len(args.pr):
            raise ValueError("cycle dates must increase and PR numbers must be unique")
        evidence = {}
        if args.evidence:
            with open(args.evidence, encoding="utf-8") as handle:
                evidence = load_evidence(json.load(handle), args.repo, args.cycle, args.pr)
        rows = []
        for number in args.pr:
            # Objects are fetched separately from paginated collections.
            pr = json.loads(subprocess.run(
                ["gh", "api", f"repos/{args.repo}/pulls/{number}"],
                check=True, capture_output=True, text=True,
            ).stdout)
            if not pr.get("merged_at") or not start <= timestamp(pr["merged_at"]) < end:
                raise ValueError(f"PR #{number} was not merged within the cycle")
            timeline = api(f"repos/{args.repo}/issues/{number}/timeline?per_page=100")
            commits = api(f"repos/{args.repo}/pulls/{number}/commits?per_page=100")
            runs = {}
            for commit in commits:
                # --slurp wraps each Actions response object in a list.
                pages = json.loads(subprocess.run(
                    ["gh", "api", "--paginate", "--slurp", f"repos/{args.repo}/actions/runs?head_sha={commit['sha']}&per_page=100"],
                    check=True, capture_output=True, text=True,
                ).stdout)
                for page in pages:
                    for run in page["workflow_runs"]:
                        runs[run["id"]] = run
            rows.append((number, *measure(pr, timeline, runs.values())))
        print(f"Repository: {args.repo}  Cycle: {args.cycle} [{args.start}, {args.end})")
        print("PR | actual interventions | human timeline actions (proxy) | actual CI reruns | observed rerun attempts (partial) | age at merge (days) | actual rebases | force pushes (proxy)")
        print("---|---|---:|---|---:|---:|---|---:")
        for number, interventions, reruns, age, pushes in rows:
            actual = evidence.get(number, {})
            print(f"#{number} | {actual.get('interventions', 'unknown')} | {interventions} | "
                  f"{actual.get('reruns', 'unknown')} | {reruns} | {age:.2f} | "
                  f"{actual.get('rebases', 'unknown')} | {pushes}")
        print("Evidence limits: selected PRs only; human actions are an observable proxy, not all interventions. "
              "Reruns exclude unavailable/deleted runs and commits absent from the final PR commit list; runs on the same SHA may include unrelated workflows. "
              "Force pushes are not confirmed rebases; rebases without a visible force-push event are unknown.")
    except (OSError, TypeError, ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"Unable to measure: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
