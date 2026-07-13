"""Shared helpers: subprocess, logging, hashing, small file utilities."""

from __future__ import annotations

import hashlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path


class ForemanError(RuntimeError):
    """Fatal, user-facing error — printed without a traceback."""


def info(msg: str) -> None:
    print(f"foreman: {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"foreman: WARN: {msg}", file=sys.stderr, flush=True)


def error(msg: str) -> None:
    print(f"foreman: ERROR: {msg}", file=sys.stderr, flush=True)


def run(
    argv: list[str],
    *,
    cwd: str | Path | None = None,
    input_text: str | None = None,
    check: bool = True,
    timeout: float | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Run a command (never a shell), capturing text output."""
    try:
        proc = subprocess.run(
            list(argv),
            cwd=str(cwd) if cwd else None,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            env=env,
            check=False,
        )
    except FileNotFoundError as exc:
        raise ForemanError(f"command not found: {argv[0]}") from exc
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ForemanError(
            f"command failed ({proc.returncode}): {' '.join(argv)}\n{detail}"
        )
    return proc


@lru_cache(maxsize=1)
def repo_root() -> Path:
    """Absolute path of the repository foreman was invoked in."""
    out = run(["git", "rev-parse", "--show-toplevel"]).stdout.strip()
    return Path(out)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def slugify(title: str, max_len: int = 32) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:max_len].rstrip("-") or "unit"


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def append_line(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line.rstrip("\n") + "\n")


def tail(path: Path, lines: int = 40) -> str:
    if not path.exists():
        return ""
    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(content[-lines:])
