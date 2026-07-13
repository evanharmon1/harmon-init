"""Environmental-failure signature catalog (signatures.toml).

The shepherd classifies red CI by signature BEFORE any LLM sees it:
`environment` failures get one retry then the human queue (an agent must
never "fix" an infra problem by weakening code); `quota_wait` failures mean
the backend's own usage window is exhausted — wait, don't burn retries.
An unmatched failure gets one bounded LLM diagnosis whose conclusion belongs
back in this catalog: the LLM diagnoses once, code recognizes forever.
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

from foreman.util import ForemanError

CATALOG = Path(__file__).resolve().parent / "signatures.toml"

ACTIONS = ("environment", "quota_wait")


@dataclass
class Signature:
    name: str
    pattern: re.Pattern
    action: str  # environment | quota_wait


def load(path: Path | None = None) -> list[Signature]:
    catalog_path = path or CATALOG
    with catalog_path.open("rb") as fh:
        data = tomllib.load(fh)
    signatures = []
    for entry in data.get("signature", []):
        action = entry.get("action", "environment")
        if action not in ACTIONS:
            raise ForemanError(
                f"signatures: unknown action '{action}' in '{entry.get('name')}'"
            )
        signatures.append(
            Signature(
                name=entry["name"],
                pattern=re.compile(entry["pattern"], re.I),
                action=action,
            )
        )
    return signatures


def match(text: str, signatures: list[Signature]) -> Signature | None:
    for signature in signatures:
        if signature.pattern.search(text or ""):
            return signature
    return None
