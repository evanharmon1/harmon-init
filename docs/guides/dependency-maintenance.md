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

Without reviewed evidence, actual interventions, CI reruns and rebases are shown
as unknown because these API sources cannot establish their completeness. A numeric zero in a proxy
column means no matching event was observed, not that the actual measure is zero.
Human timeline comments, reviews and force pushes are observable action counts,
not a complete count of maintainer interventions or a measure of active time.
When relevant timeline timestamps are missing, the affected proxy is unknown.
Observed reruns are unknown when run timing cannot establish that all attempts
belong to the PR lifetime, including a latest attempt after merge or an earlier
attempt before creation. Runs wholly outside the lifetime are excluded. CI
reruns otherwise sum additional attempts of workflow runs found for commits still in
the PR; deleted runs, removed commits and unavailable evidence can make this an
undercount, while unrelated workflows on the same commit can inflate it. The age uses PR creation and merge timestamps, not the upstream
release date. Timeline force pushes are possible rebases, not proof of a rebase:
other force pushes count too, and not all rebases are visible. Review the PR
and available run records to establish actual interventions and rebases; where
that is impossible, record them as unknown rather than treating the proxy as a
confirmed count. The operator is responsible for selecting every relevant PR;
the script does not discover omitted updates.

To include reviewed actual counts, pass `--evidence path/to/evidence.json`:

```json
{
  "repo": "OWNER/REPO",
  "cycle": "2026-10",
  "pull_requests": [{
    "number": 123,
    "interventions": {"complete": true, "records": ["run-record:cycle-1#intervention-1"]},
    "rebases": {"complete": false, "records": []},
    "reruns": {"complete": true, "records": []}
  }]
}
```

Each record is a distinct, traceable reference to one confirmed event in a run
record or PR timeline. Inspect and retain those sources; the script counts
references but cannot independently verify their contents or the operator's
completeness declaration. Set `complete` only after checking all relevant
sources for that PR and measure. A complete empty list explicitly records a
confirmed zero; omit a measure or mark it incomplete to report unknown. The
repository, cycle, and PR numbers must match the command. The evidence file is
not a substitute for checking whether the selected PR population is complete.
