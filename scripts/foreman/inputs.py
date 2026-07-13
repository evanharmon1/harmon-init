"""Resolve human inputs per unit: arming, backend, holds, overrides, type.

Primary mechanism is the org-level `foreman` issue custom field (issue fields
are org-only as of their 2026-07 GA); the fallback for personal-account repos
is `foreman:*` labels. `inputs = auto` probes availability once per run.
Two disagreeing sources on one issue fail loud — never guess.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from foreman.config import Config
from foreman.github import GitHub
from foreman.util import warn

LABEL_PREFIX = "foreman:"
# Values with fixed meaning; anything else is treated as a backend name
# (e.g. `claude`, `mock`), which implies approval for that backend.
HOLD = "hold"
APPROVED = "approved"
SATISFIED = "satisfied"  # human override: treat this issue as a satisfied dependency
EXTERNAL = "external"  # human marker: not foreman-managed; closed == satisfied
_MEANINGS = {HOLD, APPROVED, SATISFIED, EXTERNAL}

FIELD_NAME = "foreman"
FIELD_BUDGET = "foreman-budget-usd"
FIELD_TIMEOUT = "foreman-timeout-min"

TYPE_LABEL_PREFIX = "type:"


@dataclass
class UnitInputs:
    mode: str = "labels"
    armed: bool = False
    backend: str | None = None  # None = repo default
    hold: bool = False
    satisfied_override: bool = False
    external: bool = False
    budget_usd: float | None = None
    timeout_min: int | None = None
    commit_type: str = "feat"
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def detect_mode(gh: GitHub, cfg: Config) -> str:
    """auto probes org issue-field availability once; explicit modes win."""
    if cfg.inputs in ("fields", "labels"):
        return cfg.inputs
    if gh.gh.ok(["api", f"orgs/{gh.owner()}/issue-fields"]):
        return "fields"
    return "labels"


def field_values(gh: GitHub, issue_number: int) -> dict[str, object]:
    """Field name -> value for one issue; tolerant of shape drift, warns once."""
    rc_ok = gh.gh.ok(
        ["api", f"repos/{gh.repo_slug()}/issues/{issue_number}/field-values"]
    )
    if not rc_ok:
        return {}
    raw = gh.gh.json(
        ["api", f"repos/{gh.repo_slug()}/issues/{issue_number}/field-values"]
    )
    values: dict[str, object] = {}
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or (item.get("field") or {}).get("name")
        value = item.get("value")
        if isinstance(value, dict):
            value = value.get("name") or value.get("value")
        if name:
            values[str(name)] = value
    return values


def _foreman_values_from_labels(labels: list[str]) -> list[str]:
    return [
        name[len(LABEL_PREFIX) :]
        for name in labels
        if name.startswith(LABEL_PREFIX) and name != LABEL_PREFIX
    ]


def resolve(gh: GitHub, cfg: Config, issue: dict, mode: str) -> UnitInputs:
    out = UnitInputs(mode=mode)
    number = issue["number"]
    labels = [entry["name"] for entry in issue.get("labels") or []]
    label_values = _foreman_values_from_labels(labels)

    if mode == "fields":
        if label_values:
            out.errors.append(
                f"#{number}: dual-sourced input — foreman:* labels present in fields mode "
                f"({', '.join(sorted(label_values))}); remove one source"
            )
        values = field_values(gh, number)
        raw = values.get(FIELD_NAME)
        arm_values = [str(raw)] if raw else []
        budget = values.get(FIELD_BUDGET)
        timeout = values.get(FIELD_TIMEOUT)
        if budget is not None:
            try:
                out.budget_usd = float(budget)  # type: ignore[arg-type]
            except (TypeError, ValueError):
                out.errors.append(
                    f"#{number}: {FIELD_BUDGET} is not a number: {budget!r}"
                )
        if timeout is not None:
            try:
                out.timeout_min = int(timeout)  # type: ignore[arg-type]
            except (TypeError, ValueError):
                out.errors.append(
                    f"#{number}: {FIELD_TIMEOUT} is not a number: {timeout!r}"
                )
    else:
        arm_values = label_values

    backends = sorted({v for v in arm_values if v not in _MEANINGS})
    if len(backends) > 1:
        out.errors.append(
            f"#{number}: conflicting backend selections: {', '.join(backends)}"
        )
    out.backend = backends[0] if len(backends) == 1 else None
    out.hold = HOLD in arm_values
    out.satisfied_override = SATISFIED in arm_values
    out.external = EXTERNAL in arm_values
    approved = APPROVED in arm_values or out.backend is not None
    out.armed = (approved or not cfg.require_approval) and not out.hold
    if cfg.require_approval and not approved and not out.hold:
        out.warnings.append(f"#{number}: not armed (no foreman approval input)")

    out.commit_type = _resolve_type(cfg, issue, labels, out)
    return out


def _resolve_type(cfg: Config, issue: dict, labels: list[str], out: UnitInputs) -> str:
    number = issue["number"]
    native = (issue.get("issueType") or {}).get("name")
    native_mapped = None
    if native:
        native_mapped = cfg.type_map.get(native)
        if native_mapped is None:
            out.warnings.append(
                f"#{number}: issue type '{native}' has no type_map entry; using default"
            )
    label_types = [
        name[len(TYPE_LABEL_PREFIX) :]
        for name in labels
        if name.startswith(TYPE_LABEL_PREFIX)
    ]
    if len(label_types) > 1:
        out.errors.append(
            f"#{number}: multiple type: labels: {', '.join(sorted(label_types))}"
        )
    label_type = label_types[0] if len(label_types) == 1 else None

    if native_mapped and label_type and native_mapped != label_type:
        out.errors.append(
            f"#{number}: issue type '{native}' (-> {native_mapped}) disagrees with "
            f"label 'type:{label_type}' — remove one source"
        )
        return native_mapped
    resolved = native_mapped or label_type
    if not resolved:
        out.warnings.append(
            f"#{number}: no issue type or type: label; defaulting to '{cfg.default_type}'"
        )
        return cfg.default_type
    return resolved


def describe_mode(mode: str, cfg: Config) -> str:
    arming = (
        "explicit approval required"
        if cfg.require_approval
        else "default-armed (holds exclude)"
    )
    return f"inputs={mode} ({arming})"


def warn_all(units_inputs: list[UnitInputs]) -> None:
    for inp in units_inputs:
        for message in inp.warnings:
            warn(message)
