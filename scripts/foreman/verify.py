"""Deterministic verification gate. Foreman runs the repo's configured
verify_command (default: full `task ci`) in the unit's worktree itself —
the agent's self-report is never trusted.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from foreman.config import Config
from foreman.util import tail, utc_now_iso

VERIFY_TIMEOUT_MIN = 120


def run_verify(cfg: Config, worktree: Path, unit_run_dir: Path) -> tuple[bool, str]:
    """Run verify_command in the worktree; returns (ok, log tail)."""
    log_path = unit_run_dir / "verify.log"
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(f"\n--- {utc_now_iso()} {' '.join(cfg.verify_command)} ---\n")
        fh.flush()
        try:
            proc = subprocess.run(
                cfg.verify_command,
                cwd=str(worktree),
                stdout=fh,
                stderr=subprocess.STDOUT,
                timeout=VERIFY_TIMEOUT_MIN * 60,
                check=False,
            )
            code = proc.returncode
        except subprocess.TimeoutExpired:
            fh.write(f"\nverify timed out after {VERIFY_TIMEOUT_MIN} minutes\n")
            code = 124
        except FileNotFoundError:
            fh.write(f"\nverify command not found: {cfg.verify_command[0]}\n")
            code = 127
    return code == 0, tail(log_path, 40)
