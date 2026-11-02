# Check skills against the consumer contract before proposing a sync

Date: 2026-11-02
Status: accepted

## Context

Skills and consumer templates update independently. A valid released skills tag,
matching provenance and valid result schemas do not prove that an older consumer
can run the new helper. The root sync already runs `verify` before publication;
the generated sync runs narrower provenance, result-schema and secret checks.
Neither path previously explained which template update a contract failure needed.

The existing `_min_harmon_devkit_skills` declaration in `copier.yml` answers the
opposite question: does the selected skills pin meet this template's minimum?
`test:skills-pin-minimum` remains a separate lower-bound check. A newer skills
version satisfying that bound is not a compatibility promise.

## Evidence

The demonstrated boundary is:

- [harmon-init v5.13.3](https://github.com/evanharmon1/harmon-init/tree/362211f89b114eab65390eb013d2be8634c6e16c)
  with the cleanup helper from
  [harmon-devkit v0.65.0](https://github.com/evanharmon1/harmon-devkit/blob/0ec6bc2e7b381d59500792aebdfd641329bb1f35/ai/skills/universal/track-work/assets/clear-needs-review.sh).
- [harmon-init v5.14.0](https://github.com/evanharmon1/harmon-init/tree/22de4a12ea2c418d982846e33906558a0d2d581e)
  contains the repair in [PR 1872](https://github.com/evanharmon1/harmon-init/pull/1872),
  merged at `6c1e133cdce546f5c4afb08a70bcf500dd73ab73`.

In isolated copies of the two init revisions, substituting the released cleanup
helper and running `bash scripts/test-claim-release-merged.sh` exits 1 on v5.13.3:
`TEST FAIL: on-issue-closed cleanup failed`, a jq parse error, and
`needs-review cleanup: issue labels are not an array`. The same command exits 0
on v5.14.0, including both workflow counterparts. The helper now reads JSON and
clears labels on delivery PRs; the old test stub provided plain label names.
The repair also grants `pull-requests: write` in both workflow counterparts.

The reproduction was then extended by copying the complete v0.65.0 vendored skills
snapshot from init commit `20725afc94a18f7ab62fbdc74300125976b15bb8` into each
scratch consumer, setting its manifest to that pin, and adding the new guard.
The old consumer is rejected at its insufficient workflow permission; the fixed
consumer exercises the complete selected cleanup contract. This is an offline
contract check with stubbed GitHub calls, not a live token-permission test or a
full historical Copier rendering matrix.

## Decision

Use `test:skills-template-compatibility` as a focused consumer contract gate in
both sync scripts, after vendoring and scope validation but before commits,
pushes, PR creation, or metadata repair on an existing sync PR. Even an identical
tree may have been published by an older sync implementation, so metadata repair
must pass this gate rather than inheriting an unrecorded compatibility verdict.
An already-current root sync that publishes nothing keeps its early no-op.

The gate reads the requested pin from the consumer manifest. If a claim-release
workflow is present, its existing `test-claim-release-merged.sh` must exist and
pass. This executes the actual selected helper against the consumer's own tests;
missing test infrastructure or a test error is not success. A consumer without a
claim-release workflow has no cleanup integration to exercise. The existing
workflow and test support genuinely absent skills at runtime; the existing
provenance gate remains responsible for incomplete vendoring.

For v0.65.0 and subsequent stable versions, when the cleanup helper is present,
check the observed additional permission requirement in each workflow counterpart.
Job-level permissions replace workflow-level defaults. This only reads the
configuration: it never changes permissions or grants a token. A failure names
the requested version and failing consumer contract, directs the operator to
update the template or coordinate the contract change, and identifies v5.14.0
and PR 1872 as the repair for the known boundary. It never chooses an older tag.

### Alternatives

- **Compatibility declaration:** a general devkit-to-init version declaration
  would require a maintained producer/consumer metadata contract, including
  ownership and handling of customized consumers. One demonstrated boundary
  does not justify that infrastructure. The narrow permission floor here records
  one observed API requirement; behavior is checked against the actual consumer.
  No new Copier metadata or schema is introduced.
- **Focused consumer tests:** selected because the existing test reproduces the
  failure and passes with the repaired consumer. Add a separate permission check
  because offline API stubs cannot prove the workflow token grants. Keep the
  existing result-schema and secret gates, and root `verify`, intact.
- **Coordinated updates:** still the correct repair sequence when compatibility
  fails: land and intentionally release the consumer-template change before
  retrying the skills sync. Sequencing alone cannot prevent an old consumer from
  independently proposing an incompatible pin, so it is not the gate.

## Consequences and limits

The publication fixtures exercise real sync scripts and the real compatibility
gate with isolated Git remotes and mocked GitHub writes. Their small contract
fixture models the observed plain-text-to-JSON break without vendoring historical
skill versions. Negative cases cover missing tests and workflow/job permission
mismatches; corrected contracts publish successfully. Existing sync tests retain
coverage of version floors, no-op reconciliation, secrets and draft publication.

This protects the selected cleanup integration, not every behavior of every future
helper. Extend consumer contract coverage when another concrete boundary appears;
do not turn this into a broad version matrix. A future removal of the delivery-PR
write requirement would require revisiting the narrow permission floor.

An untouched v5.13.3 consumer cannot acquire this guard retroactively. It must
first adopt a template release containing the guard; the historical repair itself
is in v5.14.0. Customized consumers may coordinate the equivalent contract repair
instead of relying solely on a version string. Human template updates, merges
and releases retain their existing gates. No vendored skills, workflow permission
settings, paid services, artifact workflows or other lanes' smoke scripts change.
