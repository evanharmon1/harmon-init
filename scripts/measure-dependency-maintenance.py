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
    start, end = timestamp(pr["created_at"]), timestamp(pr["merged_at"])
    interventions = force_pushes = 0
    for event in timeline:
        if not isinstance(event, dict):
            raise ValueError("timeline entry must be a JSON object")
        kind = event.get("event")
        if kind not in {"commented", "reviewed", "head_ref_force_pushed"}:
            continue
        identity = event.get("user") if kind == "reviewed" else event.get("actor")
        human = (identity or {}).get("type") == "User"
        when = event.get("submitted_at") if kind == "reviewed" else event.get("created_at")
        if not when:
            if human:
                interventions = None
            if kind == "head_ref_force_pushed":
                force_pushes = None
            continue
        if not start <= timestamp(when) <= end:
            continue
        if human and interventions is not None:
            interventions += 1
        if kind == "head_ref_force_pushed" and force_pushes is not None:
            force_pushes += 1
    attempts = 0
    for run in runs:
        if run["run_attempt"] == 1:
            continue
        created = timestamp(run["created_at"]) if run.get("created_at") else None
        updated = timestamp(run["updated_at"]) if run.get("updated_at") else None
        started = timestamp(run["run_started_at"]) if run.get("run_started_at") else None
        if (created and created > end) or (updated and updated < start):
            continue
        if not all((created, updated, started)) or created < start or updated > end or started < start or started > end:
            attempts = None
        elif attempts is not None:
            attempts += max(0, run["run_attempt"] - 1)
    age = (end - start).total_seconds() / 86400
    return interventions, attempts, age, force_pushes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub OWNER/REPO")
    parser.add_argument("--cycle", required=True, help="cycle label")
    parser.add_argument("--start", required=True, help="inclusive UTC date YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="exclusive UTC date YYYY-MM-DD")
    parser.add_argument("--pr", required=True, type=int, action="append", help="dependency PR number; repeat for every merged update")
    args = parser.parse_args()
    try:
        start = dt.datetime.combine(dt.date.fromisoformat(args.start), dt.time.min, tzinfo=dt.timezone.utc)
        end = dt.datetime.combine(dt.date.fromisoformat(args.end), dt.time.min, tzinfo=dt.timezone.utc)
        if start >= end or len(set(args.pr)) != len(args.pr):
            raise ValueError("cycle dates must increase and PR numbers must be unique")
        rows = []
        for number in args.pr:
            # Objects are fetched separately from paginated collections.
            pr = json.loads(subprocess.run(
                ["gh", "api", f"repos/{args.repo}/pulls/{number}"],
                check=True, capture_output=True, text=True,
            ).stdout)
            if not isinstance(pr, dict):
                raise ValueError(f"PR #{number} response must be a JSON object")
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
        print("PR | human timeline actions (proxy) | observed rerun attempts (partial proxy) | age at merge (days) | force-push events (proxy)")
        print("---|---:|---:|---:|---:")
        for number, actions, reruns, age, pushes in rows:
            actions, reruns, pushes = (
                "unknown" if value is None else value for value in (actions, reruns, pushes)
            )
            print(f"#{number} | {actions} | {reruns} | {age:.2f} | {pushes}")
        print("Evidence limits: selected PRs only; human actions are an observable proxy, not all interventions. "
              "Reruns exclude unavailable/deleted runs and commits absent from the final PR commit list; runs on the same SHA may include unrelated workflows. "
              "Force pushes are not confirmed rebases; rebases without a visible force-push event are unknown.")
    except (OSError, TypeError, ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        detail = f": {exc.stderr.strip()}" if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else ""
        print(f"Unable to measure: {exc}{detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
