"""Git worktree + branch lifecycle. Remote and default branch are discovered,
never hardcoded. One worktree per unit under cfg.worktrees_dir; branches are
namespaced `<prefix>/<type>/<n>-<slug>` so cleanup and doneness can identify
foreman's own branches deterministically.
"""

from __future__ import annotations

import re
from pathlib import Path

from foreman.config import Config
from foreman.graph import Unit
from foreman.util import ForemanError, run, slugify, warn


def remote(cfg: Config) -> str:
    if cfg.remote:
        return cfg.remote
    names = [line for line in run(["git", "remote"]).stdout.split() if line]
    if len(names) == 1:
        return names[0]
    if "origin" in names:
        warn(
            "multiple git remotes; using 'origin' (set `remote` in .foreman.toml to override)"
        )
        return "origin"
    raise ForemanError(
        f"cannot pick a remote from {names}; set `remote` in .foreman.toml"
    )


def fetch(remote_name: str) -> None:
    run(["git", "fetch", "--prune", remote_name])


def base_sha(remote_name: str, branch: str) -> str:
    return run(["git", "rev-parse", f"{remote_name}/{branch}"]).stdout.strip()


def branch_name(cfg: Config, unit: Unit) -> str:
    commit_type = unit.inputs.commit_type if unit.inputs else cfg.default_type
    return f"{cfg.branch_prefix}/{commit_type}/{unit.number}-{slugify(unit.title)}"


def attempt_branches(cfg: Config, remote_name: str, number: int) -> list[str]:
    """Local + remote branches that are attempts for this unit."""
    pattern = re.compile(rf"^{re.escape(cfg.branch_prefix)}/[^/]+/{number}-")
    found: set[str] = set()
    local = run(
        ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads/"]
    ).stdout
    for name in local.split():
        if pattern.match(name):
            found.add(name)
    remote_refs = run(["git", "ls-remote", "--heads", remote_name]).stdout
    for line in remote_refs.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].startswith("refs/heads/"):
            name = parts[1][len("refs/heads/") :]
            if pattern.match(name):
                found.add(name)
    return sorted(found)


def next_attempt_branch(base_name: str, existing: list[str]) -> str:
    if base_name not in existing:
        return base_name
    attempt = 2
    while f"{base_name}-r{attempt}" in existing:
        attempt += 1
    return f"{base_name}-r{attempt}"


def worktree_path(cfg: Config, root: Path, unit: Unit) -> Path:
    return root / cfg.worktrees_dir / f"{unit.number}-{slugify(unit.title)}"


def add(path: Path, branch: str, start_point: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "worktree", "add", "-b", branch, str(path), start_point])


def add_existing_branch(path: Path, branch: str) -> None:
    """Recreate a worktree for an existing branch (e.g. after a machine restart)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "worktree", "add", str(path), branch])


def remove(path: Path, *, force: bool = True) -> None:
    args = ["git", "worktree", "remove", str(path)]
    if force:
        args.insert(3, "--force")
    run(args, check=False)
    run(["git", "worktree", "prune"], check=False)


def delete_branch(cfg: Config, remote_name: str, branch: str) -> None:
    """Delete a branch foreman created — refuses anything outside its namespace."""
    if not branch.startswith(f"{cfg.branch_prefix}/"):
        raise ForemanError(f"refusing to delete non-foreman branch '{branch}'")
    run(["git", "branch", "-D", branch], check=False)
    run(["git", "push", remote_name, "--delete", branch], check=False)


def is_clean(path: Path) -> bool:
    out = run(["git", "-C", str(path), "status", "--porcelain"]).stdout.strip()
    return not out


def commits_ahead(path: Path, base_ref: str) -> int:
    out = run(
        ["git", "-C", str(path), "rev-list", "--count", f"{base_ref}..HEAD"]
    ).stdout.strip()
    return int(out or "0")


def push(path: Path, remote_name: str, branch: str, *, first: bool) -> None:
    args = ["git", "-C", str(path), "push"]
    if first:
        args += ["-u", remote_name, branch]
    else:
        args += ["--force-with-lease", remote_name, branch]
    run(args)


def merge_tree_conflicts(path: Path, base_ref: str) -> list[str]:
    """Deterministic conflict enumeration (dry run; the tree is untouched)."""
    head = run(["git", "-C", str(path), "rev-parse", "HEAD"]).stdout.strip()
    proc = run(
        [
            "git",
            "-C",
            str(path),
            "merge-tree",
            "--write-tree",
            "--name-only",
            base_ref,
            head,
        ],
        check=False,
    )
    if proc.returncode == 0:
        return []
    lines = [line for line in proc.stdout.splitlines()[1:] if line.strip()]
    return lines or ["<unknown conflict>"]


def rebase_onto(path: Path, base_ref: str) -> bool:
    proc = run(["git", "-C", str(path), "rebase", base_ref], check=False)
    if proc.returncode != 0:
        run(["git", "-C", str(path), "rebase", "--abort"], check=False)
        return False
    return True


def empty_commit(path: Path, message: str) -> None:
    run(["git", "-C", str(path), "commit", "--allow-empty", "-m", message])


def count_retrigger_commits(path: Path, base_ref: str, subject: str) -> int:
    out = run(
        ["git", "-C", str(path), "log", f"{base_ref}..HEAD", "--format=%s"], check=False
    ).stdout
    return sum(1 for line in out.splitlines() if line.strip() == subject)
