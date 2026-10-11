# Catch a PR up to its base with GitHub update-branch

Date: 2026-10-11

## Status

Accepted. This records [#1621](https://github.com/evanharmon1/harmon-init/issues/1621).
Decision 2 was made by the maintainer on 2026-10-11 in a comment on #1621. The
skill half (the integrate skill's "Base reconciliation", `readiness-gate.sh`'s
`behind-base` message, and the integrator agent) is
[evanharmon1/harmon-devkit#1360](https://github.com/evanharmon1/harmon-devkit/issues/1360).
It reaches this repository through the skills pin.

## Context

Today a draft or ready PR that falls behind its base is caught up by a
**local** merge of the base into the feature branch. The agent then runs the
full round gate (`task verify`, or `task check` for docs) and
`task security:secrets`, pushes, and waits for CI. The vendored integrate skill
treats that reconciliation as an ordinary remediation round that spends
remediation budget. The readiness gate's `behind-base` failure tells the
operator to "merge the base into the branch, re-verify, push once".

When the merge has no conflicts, most of that work is repeated:

- **The merged tree is checked three times.** The local `task verify`, the
  `pre-push` hook (secret scan plus template tests, about 300 s here) and CI on
  the merge head all run. The readiness gate already refuses to promote without
  green required checks on that exact `headRefOid`.
- **The secret scan has nothing new to read.** A conflict-free base merge adds
  only base-branch content that the base's own CI already scanned. It adds no
  bytes written on the branch.
- **On a busy base the local gate loses the race.** On 2026-10-10/11, PR #1615
  (for #1611) needed three catch-up merges in one evening: one for #1609, one
  for #1613, #1584 and #1605, and one for #1619. Each local `task verify` took
  about five minutes. During two of them `main` moved again, so the branch was
  behind again when the push landed.

GitHub's update-branch (`gh pr update-branch <n>`, or REST
`PUT /repos/{owner}/{repo}/pulls/{n}/update-branch`) does the same merge on the
server. It merges the PR's own base into the PR branch and attributes the merge
commit to the caller. `pull_request: synchronize` then runs CI on exactly the
merged tree. No local tree is built and the agent pushes nothing.

## Decision

1. **A conflict-free catch-up runs on the server, without a local round gate or
   secret scan. CI on the merge head is the gate.** The standard path is:
   re-read `baseRefName` against the base the gate captured, then update-branch
   in merge mode. The resulting head is the catch-up only if it is a merge
   commit whose first parent is the captured head and whose other parent is
   the base tip the gate read. The endpoint merges asynchronously, but the
   agent does not need a polling procedure: any other head, whether a
   concurrent push or one still unmoved when a bounded wait ends, is a newer
   push under the readiness gate's existing "no newer push invalidated any
   result" condition, and the gate re-reads the PR and starts again. Then it fast-forwards every
   local checkout of the branch (`git pull --ff-only`) before any further local
   commit, lets CI run on the new head, and, where Codex cloud review is
   enabled, asks `carry` (#752). A merge can still break
   semantically: two changes that are each correct can combine into a tree that
   fails. That combined tree is untested until something builds it. A local
   `task verify` would test it once on one machine. CI tests it on the head that
   will be promoted, and the readiness gate's CI condition already requires
   green checks on that head. CI is therefore the only test the gate actually
   needs. The local run added time and nothing the gate relied on. The secret
   scan is skipped for the same reason: it scans authored bytes, and the merge
   adds none.
2. **A server-side catch-up spends no remediation round** (maintainer decision,
   2026-10-11). It adds no agent-authored code. The `remediation` cap bounds the
   integration stage's fix pushes, and a catch-up is not a fix. It is still a
   head move. It owes the `carry` check or a fresh current-head Codex cycle like
   any other head move. A carry spends nothing. A fresh cycle is charged to
   `integration` or `integration_exempt` exactly as today. CI must be green on
   the new head before the readiness gate can pass.
3. **"Every push passes its round gate, then a secret scan" governs pushes the
   agent authors.** That covers every commit the agent writes and pushes,
   including a local merge on the fallback path. A head move that GitHub makes
   at the agent's request authors no bytes. The readiness gate's CI condition on
   the new `headRefOid` governs it instead. `AGENTS.md` states both halves in
   the invariant, so a catch-up cannot be read as a push that skipped its gate,
   and a local merge cannot be read as exempt.
4. **Merge mode only, guarded by the expected head.** `--rebase` (REST
   `update_method: rebase`) is excluded because it rewrites the pushed branch.
   The Dev Loop forbids that at every stage, and it would also invalidate the
   reviewed commits that a carry and the review cycle are keyed to. The REST
   call takes the head the agent captured as `expected_head_sha`. If a
   concurrent push has moved the branch, the call refuses instead of merging
   onto a head nobody gated. That refusal is the moved-head case of decision
   1, never a reason to fall back to a local merge. `gh pr update-branch` has no flag for this, so the
   guarded form is the REST call, or a helper that compares the head it reads
   against the captured one. That helper is part of harmon-devkit#1360.
5. **The local merge stays as the fallback.** An agent uses it when:
   - update-branch genuinely refuses the merge: a conflict, a ruleset that
     rejects GitHub-made merge commits, or a fork PR without "allow edits by
     maintainers";
   - the base merge must ship in the same push as a fix (the integrate skill's
     rule for the last remediation push).

   The agent detects each refusal from the API's response. It does not predict
   them. An `expected_head_sha` refusal is not one of them (decision 4). A conflict resolution is authored work: the agent chooses the bytes
   that resolve it. So the fallback is an ordinary remediation round. It runs
   the full round gate and secret scan, pushes once, spends remediation budget,
   and owes a fresh Codex cycle charged as usual.
6. **The ledger and run record name the catch-up as a catch-up.** It is not a
   remediation push. The stage ledger's `Stage` and `Next` rows say
   `update-branch → CI → carry`, and the remediation counter does not advance.
   A carried head appears in the `+k carried` count as before. The merge commit
   is attributed to the account that requested it (the agent's GitHub identity),
   and the run record keeps the requested and resulting `headRefOid`.

What stays the same: catch-up goes from base to branch only, against the PR's
own `baseRefName`. It happens once, at the gate, never as soon as the branch is
seen to be behind. A promoted (ready-for-review) PR is caught up only when the
maintainer asks. Otherwise its drift is reported, never acted on, which matches
the integrate skill's post-promotion audit. When the maintainer does ask, the PR
is updated in place and its promotion is never undone. Cap and escalation rules do not change. When a carry applies is also
unchanged. The only change is who creates the merge commit.

## Not

- **Local merge with the full gate, as today.** This is kept, but only as the
  fallback. As the standard path it triples the checks, spends a remediation
  round on code nobody wrote, and loses the race against a busy base (#1615).
- **Local merge with a reduced gate** (skip `task verify`, keep the secret scan
  and push). This still needs a local checkout, a push and the `pre-push` hook.
  It also creates a second kind of agent push that has its own gate, which
  makes the invariant in decision 3 ambiguous. The server-side path removes the
  push instead.
- **`--rebase`.** It rewrites pushed history (decision 4).
- **A step-by-step poll for the asynchronous merge.** An earlier draft told the
  agent to poll until `headRefOid` left the captured SHA, to treat a poll that
  timed out as indeterminate, and to fall back to a local merge on any API
  refusal. Each step had its own edge cases, and none of them said what made
  the new head trustworthy. Decision 1 defines the catch-up head by its parents
  instead. That one rule covers a concurrent push, a head that never moved and
  an expected-head refusal, through the readiness gate's existing newer-push
  condition.
- **Charging the catch-up to `remediation`** (the recommended alternative to
  decision 2). The cap would then bound a busy base's merge rate rather than
  the agent's fixes. A PR could run out of remediation budget without one fix
  pushed. The maintainer rejected this.

## Consequences

- Policy text in `AGENTS.md`, `template/AGENTS.md.jinja`,
  `docs/guides/devflow.md` and `docs/guides/codex-review.md` (and their
  template twins) gives the order update-branch → CI → `carry`, plus the
  fallback triggers.
- Until the skills pin carries harmon-devkit#1360, the vendored integrate skill
  and readiness gate still describe the local merge. An agent following this
  file uses update-branch anyway. This file wins where a lagging skill states a
  different budget or procedure.
- The agent re-reads `baseRefName` before the call and stops if it changed,
  because the `base-retargeted` rule applies. A retarget between that re-read
  and GitHub processing the merge is still possible. A local merge has the same
  race, and the readiness gate's base check catches it.
- Every head move from update-branch costs a full CI run. That cost is the gate
  itself.
- A repository whose rulesets reject GitHub-made merge commits always takes
  the fallback.
