"""Load .foreman.toml (repo root) with defaults and FOREMAN_* env overrides.

Config is intent, not state: nothing here is written back by foreman.
Python 3.11+ (tomllib).
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from foreman.util import ForemanError, warn

CONFIG_FILE = ".foreman.toml"


@dataclass
class Config:
    backend: str = "claude"
    backend_version: str = ""  # expected CLI version prefix; "" = don't assert
    require_approval: bool = True  # strict arming: only foreman-approved units dispatch
    inputs: str = "auto"  # auto | fields | labels
    verify_command: list[str] = field(default_factory=lambda: ["task", "ci"])
    max_parallel: int = 3
    dispatch_budget_usd: float = 20.0
    shepherd_budget_usd: float = 10.0
    dispatch_timeout_min: int = 90
    shepherd_timeout_min: int = 30
    max_turns: int = 0  # 0 = uncapped (budget/timeout bind instead)
    comment_trust: list[str] = field(
        default_factory=lambda: ["OWNER", "MEMBER", "COLLABORATOR"]
    )
    branch_prefix: str = "foreman"
    worktrees_dir: str = ".worktrees/foreman"
    runtime_dir: str = ".foreman"
    type_map: dict[str, str] = field(
        default_factory=lambda: {
            "Feature": "feat",
            "Bug": "fix",
            "Task": "chore",
            "Research": "chore",
        }
    )
    default_type: str = "feat"
    expected_login: str = ""  # identity assertion before any write; "" = skip
    billing: str = "subscription"  # subscription | api
    sandboxed: bool = False  # true only inside the egress-limited bot devcontainer
    permission_mode: str = (
        ""  # "" = derived: bypassPermissions if sandboxed else acceptEdits
    )
    allow_not_planned: bool = False  # count closed-as-not-planned external deps as done
    remote: str = ""  # "" = auto-discover

    def resolved_permission_mode(self) -> str:
        if self.permission_mode:
            return self.permission_mode
        return "bypassPermissions" if self.sandboxed else "acceptEdits"


_ENV_OVERRIDES = {
    "FOREMAN_BACKEND": ("backend", str),
    "FOREMAN_INPUTS": ("inputs", str),
    "FOREMAN_MAX_PARALLEL": ("max_parallel", int),
    "FOREMAN_BILLING": ("billing", str),
    "FOREMAN_PERMISSION_MODE": ("permission_mode", str),
    "FOREMAN_SANDBOXED": ("sandboxed", lambda v: v.lower() in ("1", "true", "yes")),
}

_TABLES = {
    "budgets": {
        "dispatch_usd": "dispatch_budget_usd",
        "shepherd_usd": "shepherd_budget_usd",
    },
    "timeouts": {
        "dispatch_min": "dispatch_timeout_min",
        "shepherd_min": "shepherd_timeout_min",
    },
}


def load(root: Path) -> Config:
    cfg = Config()
    path = root / CONFIG_FILE
    if path.exists():
        with path.open("rb") as fh:
            try:
                data = tomllib.load(fh)
            except tomllib.TOMLDecodeError as exc:
                raise ForemanError(f"{CONFIG_FILE}: invalid TOML: {exc}") from exc
        _apply(cfg, data, path.name)
    for env_name, (attr, cast) in _ENV_OVERRIDES.items():
        raw = os.environ.get(env_name)
        if raw:
            setattr(cfg, attr, cast(raw))
    _validate(cfg)
    return cfg


def _apply(cfg: Config, data: dict, source: str) -> None:
    known = set(Config.__dataclass_fields__)
    for key, value in data.items():
        if key in _TABLES:
            if not isinstance(value, dict):
                raise ForemanError(f"{source}: [{key}] must be a table")
            for sub, attr in _TABLES[key].items():
                if sub in value:
                    setattr(cfg, attr, value.pop(sub))
            for leftover in value:
                warn(f"{source}: unknown key [{key}].{leftover} ignored")
        elif key in known:
            current = getattr(cfg, key)
            if isinstance(current, bool) and not isinstance(value, bool):
                raise ForemanError(f"{source}: '{key}' must be a boolean")
            setattr(cfg, key, value)
        else:
            warn(f"{source}: unknown key '{key}' ignored")


def _validate(cfg: Config) -> None:
    if cfg.inputs not in ("auto", "fields", "labels"):
        raise ForemanError(
            f"config: inputs must be auto|fields|labels, got '{cfg.inputs}'"
        )
    if cfg.billing not in ("subscription", "api"):
        raise ForemanError(
            f"config: billing must be subscription|api, got '{cfg.billing}'"
        )
    if not isinstance(cfg.verify_command, list) or not all(
        isinstance(part, str) for part in cfg.verify_command
    ):
        raise ForemanError("config: verify_command must be a list of strings")
    if not cfg.verify_command:
        raise ForemanError("config: verify_command must not be empty")
    if cfg.max_parallel < 1:
        raise ForemanError("config: max_parallel must be >= 1")
    if "/" in cfg.branch_prefix or not cfg.branch_prefix:
        raise ForemanError("config: branch_prefix must be a single path segment")
