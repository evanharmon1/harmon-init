"""Agent backend adapter seam. Adapters are `backends/<name>.sh` — the entire
vendor surface. Foreman shells out; no vendor SDKs in core.

Adapter contract:
  argv:  <adapter> run | resume <session-ref> | capabilities
  cwd:   the unit's worktree
  env:   FOREMAN_PROMPT_FILE, FOREMAN_RESULT_FILE, FOREMAN_SESSION_FILE,
         FOREMAN_LOG_FILE, FOREMAN_TIMEOUT_MIN, FOREMAN_PERMISSION_MODE,
         FOREMAN_BILLING, FOREMAN_MAX_TURNS (0 = uncapped)
  out:   exit 0/non-zero; session file line `SESSION_REF=<id>` written as
         EARLY as the backend allows (killed agents emit no final event —
         resume depends on this), later `COST_USD=<x>` when known.
  caps:  `capabilities` prints tokens, e.g. `resume cost`.

Timeouts are enforced HERE (portable), not in the adapters.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from foreman import signatures as signatures_mod
from foreman.config import Config
from foreman.util import ForemanError, run, tail, utc_now_iso, write_text

BACKENDS_DIR = Path(__file__).resolve().parent / "backends"

RESULT_STATUSES = ("completed", "blocked")


@dataclass
class BackendResult:
    returncode: int
    timed_out: bool = False
    session_ref: str | None = None
    cost_usd: float | None = None
    quota_wait: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out


def adapter_path(name: str) -> Path:
    path = BACKENDS_DIR / f"{name}.sh"
    if not path.exists():
        available = sorted(p.stem for p in BACKENDS_DIR.glob("*.sh"))
        raise ForemanError(
            f"unknown backend '{name}' (available: {', '.join(available)})"
        )
    return path


def capabilities(adapter: Path) -> set[str]:
    proc = run([str(adapter), "capabilities"], check=False)
    return set(proc.stdout.split()) if proc.returncode == 0 else set()


def assert_backend_version(cfg: Config) -> None:
    """Pin check: headless behavior drifts between agent-CLI releases."""
    if not cfg.backend_version or cfg.backend != "claude":
        return
    proc = run(["claude", "--version"], check=False)
    version = (
        proc.stdout.strip().split()[0] if proc.returncode == 0 and proc.stdout else ""
    )
    if not version.startswith(cfg.backend_version):
        raise ForemanError(
            f"backend version mismatch: claude CLI is '{version or 'missing'}', "
            f"config pins '{cfg.backend_version}'"
        )


def unit_dir(cfg: Config, root: Path, number: int) -> Path:
    path = root / cfg.runtime_dir / "units" / str(number)
    path.mkdir(parents=True, exist_ok=True)
    return path


def run_backend(
    cfg: Config,
    adapter: Path,
    *,
    cwd: Path,
    unit_run_dir: Path,
    prompt_file: Path,
    timeout_min: int,
    resume_ref: str | None = None,
) -> BackendResult:
    session_file = unit_run_dir / "session"
    log_file = unit_run_dir / "agent.log"
    result_file = unit_run_dir / "result.json"
    stdout_file = unit_run_dir / "adapter-stdout.log"
    if result_file.exists():
        result_file.unlink()

    env = os.environ.copy()
    env.update(
        {
            "FOREMAN_PROMPT_FILE": str(prompt_file),
            "FOREMAN_RESULT_FILE": str(result_file),
            "FOREMAN_SESSION_FILE": str(session_file),
            "FOREMAN_LOG_FILE": str(log_file),
            "FOREMAN_TIMEOUT_MIN": str(timeout_min),
            "FOREMAN_PERMISSION_MODE": cfg.resolved_permission_mode(),
            "FOREMAN_BILLING": cfg.billing,
            "FOREMAN_MAX_TURNS": str(cfg.max_turns),
        }
    )
    if cfg.billing == "api" and not env.get("FOREMAN_ANTHROPIC_API_KEY"):
        raise ForemanError("billing=api but FOREMAN_ANTHROPIC_API_KEY is not set")

    argv = [str(adapter), "resume", resume_ref] if resume_ref else [str(adapter), "run"]
    timed_out = False
    with stdout_file.open("a", encoding="utf-8") as out_fh:
        out_fh.write(f"\n--- {utc_now_iso()} {' '.join(argv)} ---\n")
        out_fh.flush()
        proc = subprocess.Popen(
            argv,
            cwd=str(cwd),
            env=env,
            stdout=out_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            proc.wait(timeout=timeout_min * 60)
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill_group(proc)

    result = BackendResult(returncode=proc.returncode, timed_out=timed_out)
    _read_session_file(session_file, result)
    log_tail = tail(log_file, 80) + "\n" + tail(stdout_file, 40)
    sig = signatures_mod.match(log_tail, signatures_mod.load())
    if sig is not None and sig.action == "quota_wait":
        result.quota_wait = True
    return result


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.2)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def _read_session_file(session_file: Path, result: BackendResult) -> None:
    if not session_file.exists():
        return
    for line in session_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("SESSION_REF=") and not result.session_ref:
            result.session_ref = line.split("=", 1)[1].strip() or None
        elif line.startswith("COST_USD="):
            try:
                result.cost_usd = float(line.split("=", 1)[1])
            except ValueError:
                pass


# ── result contract ──────────────────────────────────────────────────


@dataclass
class ResultContract:
    status: str
    summary: str = ""
    handoff: str = ""
    human_tasks: list[str] = field(default_factory=list)
    proposed_pr_title: str = ""
    ac_test_map: list[dict] = field(default_factory=list)
    blocked_question: str | None = None


def read_result(
    unit_run_dir: Path, worktree: Path
) -> tuple[ResultContract | None, list[str]]:
    """Validate the sidecar result contract; BLOCKED.md is the fallback signal."""
    result_file = unit_run_dir / "result.json"
    blocked_md = worktree / "BLOCKED.md"
    if not result_file.exists():
        if blocked_md.exists():
            question = blocked_md.read_text(encoding="utf-8").strip()
            return ResultContract(status="blocked", blocked_question=question), []
        return None, ["agent exited without writing the result contract"]
    try:
        data = json.loads(result_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, [f"result.json is not valid JSON: {exc}"]

    errors: list[str] = []
    if not isinstance(data, dict):
        return None, ["result.json must be a JSON object"]
    if data.get("schema") != 1:
        errors.append("result.json: schema must be 1")
    status = data.get("status")
    if status not in RESULT_STATUSES:
        errors.append(f"result.json: status must be one of {RESULT_STATUSES}")
        return None, errors

    contract = ResultContract(status=status)
    contract.summary = _expect_str(
        data, "summary", errors, required=(status == "completed")
    )
    contract.handoff = _expect_str(
        data, "handoff", errors, required=(status == "completed")
    )
    contract.proposed_pr_title = _expect_str(
        data, "proposed_pr_title", errors, required=False
    )
    contract.blocked_question = data.get("blocked_question") or None
    if status == "blocked" and not contract.blocked_question:
        if blocked_md.exists():
            contract.blocked_question = blocked_md.read_text(encoding="utf-8").strip()
        else:
            errors.append("result.json: blocked status requires blocked_question")
    tasks = data.get("human_tasks", [])
    if not isinstance(tasks, list) or not all(isinstance(t, str) for t in tasks):
        errors.append("result.json: human_tasks must be a list of strings")
    else:
        contract.human_tasks = tasks
    ac_map = data.get("ac_test_map", [])
    if not isinstance(ac_map, list):
        errors.append("result.json: ac_test_map must be a list")
    else:
        for entry in ac_map:
            if (
                not isinstance(entry, dict)
                or "criterion" not in entry
                or "tests" not in entry
            ):
                errors.append(
                    "result.json: ac_test_map entries need {criterion, tests}"
                )
                break
        else:
            contract.ac_test_map = ac_map
    if status == "completed" and not contract.ac_test_map:
        errors.append("result.json: completed status requires a non-empty ac_test_map")
    return (contract, errors) if not errors else (None, errors)


def _expect_str(data: dict, key: str, errors: list[str], *, required: bool) -> str:
    value = data.get(key, "")
    if not isinstance(value, str):
        errors.append(f"result.json: {key} must be a string")
        return ""
    if required and not value.strip():
        errors.append(f"result.json: {key} is required")
    return value


def write_resume_state(unit_run_dir: Path, worktree: Path, note: str) -> Path:
    """Deterministic resume-state so a later resume needs no archaeology."""
    status = run(
        ["git", "-C", str(worktree), "status", "--porcelain", "-b"], check=False
    ).stdout
    log = run(
        ["git", "-C", str(worktree), "log", "--oneline", "-5"], check=False
    ).stdout
    session = (
        (unit_run_dir / "session").read_text(encoding="utf-8")
        if (unit_run_dir / "session").exists()
        else ""
    )
    body = (
        f"# Resume state — {utc_now_iso()}\n\n{note}\n\n"
        f"## Worktree\n\n`{worktree}`\n\n```text\n{status}```\n\n"
        f"## Recent commits\n\n```text\n{log}```\n\n"
        f"## Session\n\n```text\n{session}```\n\n"
        f"## Agent log tail\n\n```text\n{tail(unit_run_dir / 'agent.log', 40)}\n```\n"
    )
    path = unit_run_dir / "resume-state.md"
    write_text(path, body)
    return path
