# Route agent-posture API reads through a GET-only wrapper

Date: 2026-10-10

## Status

Accepted — maintainer decision of 2026-10-09, recorded on
[#1549](https://github.com/evanharmon1/harmon-init/issues/1549).
Amends [ADR 2026-09-29 (three postures)](2026-09-29-agent-posture-three-posture-model.md)
for the agent posture's `gh api` rules only.

## Context

The agent posture denied `gh api` with argument patterns: the method, input and
every form-field flag (`-f`, `-F`, `--field`, `--raw-field`) in any position.
Bundled short flags evade argument matching: `-iXPOST` contains neither a word
starting with `-X` nor any of the denied field or method patterns. An allow for
raw `gh api` therefore also admits spellings of writes denied by command name,
including releases and workflow dispatch.

The safe read probe `gh api -iXGET repos/evanharmon1/harmon-init` returned
HTTP 200 outside the posture, verifying the bundled-flag spelling offline. No
write probe is needed to establish the parsing gap. The postured-session probe
remains #1549's pending human check.

## Decision

The agent managed settings deny both bare `gh api` and `gh api *`, remove the
superseded argument-pattern API denies, and allow only the REST read front door
`/usr/local/bin/gh-api-read`.

- The wrapper has one source under `.devcontainer/config/agent/` and its
  template twin; it depends on no skill.
- Both the agent devcontainer and web bootstrap install and verify that source
  as an executable at the same absolute path. The wrapper always replaces a
  stale or differing copy at mode 0755; unlike platform-owned managed policy,
  it is ours and is named by the managed allow rule. Identical executable bytes
  need no reinstall.
- The wrapper pins a system PATH before running `gh`, so a caller cannot
  substitute a binary from a user-writable search directory.
- The wrapper accepts exactly one relative REST endpoint, pagination and
  client-side output flags. Every method, field, input, header (including
  `X-HTTP-Method-Override`), bundled flag, unknown flag, absolute URL and
  GraphQL endpoint is refused. Accepted requests execute
  `gh api --method GET` with only vetted arguments.
- Recording-stub tests cover the write spellings and verify the pinned method;
  a scratch mutation removing the pin must fail the outgoing-request contract.

## Not

- **An allow for raw `gh api`.** It admits the bundled-flag spellings of writes
  that are otherwise denied by command name.
- **The argument-pattern denies** as the way to keep `gh api` to reads. They
  match only the spelling they name, and bundled short flags evade them.

## Consequences

- This supersedes the earlier description of API argument-pattern denies in
  ADR 2026-09-29's Consequences. Argument-pattern denies are defence in depth,
  not the write boundary: allowed scripts and Taskfile targets still run beyond
  those rules, and Codex carries no command-level deny list.
- The boundary remains the bot's collaborator grants, the agent PAT's scopes and
  the repository branch rulesets, with the residual release and approved-merge
  permissions already disclosed in ADR 2026-09-29.
- The blanket API deny closes this direct Claude command path; it does not
  change that boundary.
