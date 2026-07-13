"""Watch mode: `plan → dispatch → shepherd → sleep`, for days if needed.

Every tick is stateless and idempotent — all state re-derived from GitHub +
git, so kill/reboot/laptop-sleep loses nothing. A heartbeat line per tick
makes silence distinguishable from health. Stop conditions: milestone
complete, stop file (.foreman-stop), aggregate budget, N consecutive
failing ticks. For multi-day runs, cron invoking dispatch+shepherd is
equivalent — the live loop is a convenience, not a requirement.
"""

from __future__ import annotations

import re
import time
from pathlib import Path

from foreman import dispatch as dispatch_mod
from foreman import shepherd as shepherd_mod
from foreman.config import Config
from foreman.github import Gh, GitHub
from foreman.graph import detect_cycle, prepare_target
from foreman.util import ForemanError, append_line, error, info, utc_now_iso, warn

STOP_FILE = ".foreman-stop"
DEFAULT_INTERVAL_S = 300
MAX_CONSECUTIVE_FAILURES = 3


def parse_interval(text: str) -> int:
    match = re.fullmatch(r"(\d+)\s*([smh]?)", text.strip())
    if not match:
        raise ForemanError(f"bad --interval '{text}' (use e.g. 300, 5m, 1h)")
    value, unit = int(match.group(1)), match.group(2)
    seconds = value * {"": 1, "s": 1, "m": 60, "h": 3600}[unit]
    if seconds <= 0:
        raise ForemanError(f"--interval must be positive, got '{text}'")
    return seconds


def run_watch(
    cfg: Config,
    root: Path,
    *,
    milestone: str | None,
    issue: int | None,
    interval_s: int = DEFAULT_INTERVAL_S,
    budget_usd: float | None = None,
    max_failures: int = MAX_CONSECUTIVE_FAILURES,
) -> int:
    log_path = root / cfg.runtime_dir / "watch.log"
    stop_path = root / STOP_FILE
    consecutive = 0
    total_cost = 0.0
    tick = 0
    idle_notified = False

    def heartbeat(message: str) -> None:
        line = f"{utc_now_iso()} tick={tick} {message}"
        append_line(log_path, line)
        info(line)

    info(f"watch: interval={interval_s}s budget={budget_usd or 'none'} log={log_path}")
    while True:
        tick += 1
        if stop_path.exists():
            heartbeat("stop file present — exiting cleanly")
            return 0
        try:
            gh = GitHub(Gh(), cfg)  # fresh per tick: caches never go stale
            target = prepare_target(gh, cfg, milestone=milestone, issue=issue)
            cycle = detect_cycle(target)
            if cycle:
                error(
                    f"watch: dependency cycle {' -> '.join('#' + str(n) for n in cycle)}"
                )
                return 1
            open_units = [u for u in target.units.values() if u.open]
            if not open_units:
                heartbeat("milestone complete — all units closed")
                return 0

            outcomes = dispatch_mod.run_dispatch(gh, cfg, root, target)
            shep = shepherd_mod.run_shepherd(gh, cfg, root)
            tick_cost = sum(o.cost_usd or 0.0 for o in outcomes) + shep.cost_usd
            total_cost += tick_cost

            dispatched = sum(1 for o in outcomes if o.dispatched)
            waiting = sum(1 for o in outcomes if o.status == "waiting")
            failed = sum(1 for o in outcomes if o.status in ("failed", "blocked"))
            ready = len(shep.ready_order)
            heartbeat(
                f"open={len(open_units)} dispatched={dispatched} waiting={waiting} "
                f"failed={failed} prs-ready={ready} cost=${total_cost:.2f}"
            )
            if shep.ready_order and dispatched == 0 and not failed:
                if not idle_notified:
                    info(
                        "watch: idling by design — PRs are ready and nothing new is "
                        "dispatchable; waiting on human merges:\n"
                        + "\n".join(
                            f"  {n}. #{u} {url}"
                            for n, (u, url) in enumerate(shep.ready_order, 1)
                        )
                    )
                    idle_notified = True
            else:
                idle_notified = False
            consecutive = 0
            if budget_usd is not None and total_cost >= budget_usd:
                heartbeat(f"aggregate budget ${budget_usd:.2f} reached — stopping")
                return 0
        except ForemanError as exc:
            consecutive += 1
            warn(f"watch: tick failed ({consecutive}/{max_failures}): {exc}")
            heartbeat(f"TICK FAILED: {exc}")
            if consecutive >= max_failures:
                error("watch: too many consecutive failures — stopping")
                return 1
        time.sleep(interval_s)
