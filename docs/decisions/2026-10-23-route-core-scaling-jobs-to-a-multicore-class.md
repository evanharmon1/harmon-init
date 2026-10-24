# Route core-scaling jobs to a multicore class

Date: 2026-10-23

## Status

Accepted. Records the maintainer's 2026-10-22 decision in
[#1782](https://github.com/evanharmon1/harmon-init/issues/1782).
Amends [ADR 2026-10-18](2026-10-18-route-ci-jobs-by-class.md).

## Context

The default class puts general build, lint and test jobs on one runner size.
One consumer, omator, measured which jobs benefit from more cores before
choosing separate placement.

Method:
- Live-traffic flips of omator's repository `CI_RUNS_ON` and `E2E_RUNS_ON`: one window per size on Ubicloud standard runners (`ubicloud-standard-2`, `-4`, `-8`), 2026-10-18 → 2026-10-22.
- Measured with ponderousdev/omator’s [`scripts/ci-job-timings.sh`](https://github.com/ponderousdev/omator/blob/main/scripts/ci-job-timings.sh): latest attempt per run, means over successful jobs only, jobs with out-of-order GitHub timestamps excluded.
- Sources: [2 vCPU](https://github.com/ponderousdev/omator/issues/1612#issuecomment-6277786446),
  [4 vCPU](https://github.com/ponderousdev/omator/issues/1612#issuecomment-6313915791) and
  [8 vCPU](https://github.com/ponderousdev/omator/issues/1612#issuecomment-6354595025).

Mean run time in seconds:

| Job | 2 vCPU | 4 vCPU | 8 vCPU | 4→8 speed-up | 4→8 cost per job (2 ÷ speed-up) |
|---|---|---|---|---|---|
| build-test | 889.5 | 431.0 | 239.2 | **1.80×** | **1.11×** |
| e2e (browser) | 438.8 | 278.9 | 237.0 | 1.18× | 1.70× |
| check (lint + typecheck) | — | 278.9 | 246.4 | 1.13× | 1.77× |
| repo-guards | — | 292.4 | 235.1 | 1.24× | 1.61× |
| security | 137.4 | 116.2 | 104.5 | 1.11× | 1.80× |
| a11y (browser) | 64.7 | 62.4 | 62.0 | 1.01× | 1.98× |
| preview | 127.2 | 128.6 | 121.1 | 1.06× | 1.89× |
| devcontainer-permissions | — | 76.3 | 87.6 | 0.87× | 2.30× |
| devcontainer build (3 images) | failed: out of disk | 272–297 | 186–196 | 1.41–1.55× | 1.29–1.42× |

Sample sizes: 35–207 successful jobs per 8 vCPU cell, and ≥ 35 per 4 vCPU cell for the jobs above. `check` and `repo-guards` replaced `lint` partway through the 4 vCPU window (omator#1704), so they have no 2 vCPU figure.

**Findings**
1. **`build-test` is the only default-class job that pays for itself past 4 vCPU.** It is 2.06× faster from 2 to 4 vCPU and 1.80× from 4 to 8. That matches local profiling, where vitest averages 3.2–6.3 cores. With per-minute rounding, 431 s at 4 vCPU (8 min × 4) and 239 s at 8 vCPU (4 min × 8) both bill 32 vCPU-minutes. Whether the provider rounds per minute is unconfirmed.
2. **Every other default and browser job flattens at 4 vCPU.** They are 0.87–1.24× faster at 8 vCPU for 1.6–2.3× the cost.
3. **Splitting this way saves wall-clock time.** Default-class jobs run in parallel, so CI time is the slowest job. Moving `build-test` to 8 vCPU cuts CI from 431 s to about 292 s, with `repo-guards` (292 s at 4 vCPU) becoming the slowest job. That is about 2.3 min per run, at roughly the same cost: the split costs about 1.04× the all-4 baseline (≈4,970 vs ≈4,780 vCPU-seconds).
4. **Moving the whole default class to 8 vCPU** costs about 1.47× the split per run (≈7,300 vs ≈4,970 vCPU-seconds), or 1.53× the all-4 baseline. It buys about 46 s more than the split: the critical path becomes `check` at about 246 s. These sums cover the five measured default-class jobs running in parallel in Build & Validate: build-test, check, repo-guards, security and devcontainer-permissions. `changes` and `verify` are tiny and were not measured. The browser class (`a11y`) and `preview.yml` jobs (`preview`, `demo-seed` and `e2e`) are outside the sums.
5. **Memory is a separate floor from cores.** eslint peaks at 3.8 GB RSS in `check`. 2 vCPU cannot build devcontainer images at all (`no space left on device`). Neither changes this decision, but both belong in the record.
6. **Queue time stayed at 14–21 s at every size.**

**Limits of the evidence:** this is live traffic, not a controlled benchmark; different PRs ran each day. It covers one consumer (omator, web-app profile) on one provider. The class is defined by a property (core scaling) so that other consumers can measure their own jobs before moving them.

## Decision

Add a fifth class, **multicore**, selected by `MULTICORE_RUNS_ON`.
A job joins only when measurements on one provider show it keeps scaling past
its default size: wall-clock gain at roughly flat per-job cost is the bar.
Feeling heavy is not evidence; memory needs are a separate floor from core scaling.
The first and only template member is `build-test`.

Following ADR 2026-10-18, the name describes the reason a job needs its placement:
measured use of multiple cores. It does not prescribe a provider or runner size.

The fallback chain is `MULTICORE_RUNS_ON` → `CI_RUNS_ON` → rendered
`ci_runs_on_default`, expressed as
`fromJSON(vars.MULTICORE_RUNS_ON || vars.CI_RUNS_ON || '[[ ci_runs_on_default ]]')`.
Repository values shadow organization values of the same name before class
fallback. Isolated wins over every class. Jobs needing a browser or building
images stay in those classes; multicore applies only to otherwise-default work.

With linear vCPU pricing, per-job cost ratio = size ratio ÷ speed-up.
Parallel CI wall-clock time is the slowest job, not the sum of job durations.
The measured split puts `build-test` at 8 vCPU while keeping the other default
jobs at 4 vCPU: approximately 292 s instead of 431 s for the critical path,
at about 1.04× the all-4 baseline cost (≈4,970 vs ≈4,780 vCPU-seconds).
The totals cover the five measured default-class jobs running in parallel in
Build & Validate: `build-test`, `check`, `repo-guards`, `security` and
`devcontainer-permissions`. `changes` and `verify` are tiny and were not measured.
The browser class (`a11y`) and the separate `preview.yml` jobs (`preview`,
`demo-seed` and `e2e`) are outside these sums. Putting all five measured jobs at
8 vCPU costs about 1.47× the split (≈7,300 vs ≈4,970 vCPU-seconds), or 1.53×
the all-4 baseline. It saves about 46 s more than the split: `check` becomes
the critical path at about 246 s. Per-minute rounding could make `build-test`'s
cost identical, but that billing behavior is unconfirmed.

## Not

- **The whole default class at 8 vCPU.** About 1.47× the split cost
  (≈7,300 vs ≈4,970 vCPU-seconds over the five measured Build & Validate jobs),
  for about 46 s more saved. The critical path becomes `check` at about 246 s;
  most default-class jobs barely improve.
- **The whole class at 4 vCPU.** `build-test` remains the 431 s critical path.
- **A per-job variable (`BUILD_TEST_RUNS_ON` / `TEST_RUNS_ON`).** ADR 2026-10-18
  rejects one variable per job. Tests such as a11y and e2e do not keep scaling;
  being a test is not the placement requirement.
- **Vaguer names (`COMPUTE_RUNS_ON`, `CPU_RUNS_ON`, `LARGE_RUNS_ON`,
  `HEAVY_RUNS_ON`, `PARALLEL_RUNS_ON`).** All jobs compute and use a CPU;
  size and perceived weight do not establish scaling, and parallel jobs do not
  necessarily exploit more cores within a job.

## Consequences

An unset variable preserves existing routing for every consumer. A consumer gains
only by setting it; no provider or paid service becomes a template default.
Adding another job to multicore requires its own measurement against the
admission rule. Setup and status expose the fifth class with the same validation,
replacement and shadowing rules as browser placement; multicore may be self-hosted.
Public repositories retain exact GitHub-hosted safety overrides for every class
once `task setup:github` has been re-run after updating to the release that adds
`MULTICORE_RUNS_ON`. Until then, a visible organization value can route
`build-test` to its pool; `task status` reports the missing repository override.

[ponderousdev/omator#1614](https://github.com/ponderousdev/omator/issues/1614)
adopts the class with `ubicloud-standard-8`, the measured consumer's provider choice.
