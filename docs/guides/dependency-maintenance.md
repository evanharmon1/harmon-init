# Measuring dependency maintenance

Record a baseline for two cycles before proposing a weekly time target. Select
all merged dependency-update PRs for each repository and cycle, then run, for
example:

```sh
python3 scripts/measure-dependency-maintenance.py --repo OWNER/REPO \
  --cycle 2026-10 --start 2026-10-01 --end 2026-11-01 --pr 123 --pr 124
```

Dates are UTC, with an inclusive start and exclusive end. Cycle bounds select
PRs by merge time; observable activity is bounded to each selected PR’s lifetime
from creation through merge, inclusive. A PR created before the cycle start
still contributes its lifetime activity. The authenticated
`gh` CLI needs access to the repository's pull requests, timelines and Actions
runs. The table reports each selected PR separately, allowing comparison within
and across cycles. Retain the output, selection and any run records alongside
the baseline; this command does not create a target or record the human cycles.

The selected PRs must cover every merged dependency update in the cycle; compare
the selection with the repository PR list and record any missing PRs. The script
does not establish completeness. PR creation and merge timestamps supply age.
The issue timeline supplies human action and force-push proxies; workflow runs
looked up by each commit in the final PR commit list supply observed rerun
attempts. Run records and manual examination can provide additional evidence.

The baseline reports human timeline actions, observed rerun attempts and
force-push events as proxies, plus age at merge. A numeric zero means no
matching event was observed in the available sources, not that the actual
measure is zero. Human means GitHub identity type `User`, including machine users and agents using
personal tokens, and excludes `Bot` accounts. Human comments, reviews and force pushes are not a complete
count of maintainer interventions or a measure of active time. When relevant
timeline timestamps are missing, the affected proxy is unknown.

A run with one attempt has zero additional attempts regardless of timing.
For multi-attempt runs, observed reruns are unknown when run timing cannot establish that all attempts
belong to the PR lifetime, including a latest attempt after merge or an earlier
attempt before creation. Runs wholly outside the lifetime are excluded. The
count sums additional attempts of workflow runs found for commits still in the
PR; deleted runs, removed commits and unavailable evidence can make this an
undercount, while unrelated workflows on the same commit can inflate it. The
age uses PR creation and merge timestamps, not the upstream release date.
Force-push events do not establish rebases: other force pushes count too, and
not all rebases are visible. Historical API data may omit deleted or unavailable
sources; failed API reads stop the command rather than reporting zero.
