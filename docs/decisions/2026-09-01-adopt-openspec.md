# Adopt OpenSpec for spec-driven changes at the repo root

Date: 2026-09-01

## Status

Accepted

## Context

`specs/` has always been a plain template (`_template.md`) plus
`issue-strategy.md` — a place to write a spec, not a workflow that drives one.
Nothing enforced that a change had a spec, tracked its status, or gave a pane
worker a shared vocabulary for proposing, applying, and archiving one.

harmon-init#1137 widened the set of harnesses this repo dogfoods bot access
for — Claude Code, Codex, OpenCode, GitHub Copilot, Antigravity, Pi, and Oh My
Pi. Multi-harness pane workers need one shared spec-driven-change vocabulary
that behaves the same regardless of which harness is driving a given pane,
rather than each harness growing its own ad hoc propose/apply/archive
convention. A single spec-of-record location that any harness can read and
act on consistently is worth adopting deliberately rather than improvising
per-harness.

## Decision

Adopt [OpenSpec](https://github.com/Fission-AI/OpenSpec) `1.11.0` as this
repository's own spec-driven change process, **at the repo root only**:

- The CLI is pinned via a Renovate-annotated Taskfile var
  (`OPENSPEC_VERSION`) and fetched through `npx` via `scripts/openspec.sh` —
  never installed, since the repo has no `package.json`.
- `openspec init` was run with seven tool integrations:
  `claude,codex,opencode,github-copilot,antigravity,pi,oh-my-pi`, generating
  `openspec/config.yaml`, `.claude/commands/opsx/*`,
  `.claude/skills/openspec-*`, `.agents/**`, `.opencode/**`,
  `.github/prompts/**`, `.github/skills/**`, `.pi/**`, and `.omp/**`.
- `openspec/changes/<name>/` is the spec of record for an in-flight change;
  archived changes update `openspec/specs/`, the accumulated capability
  specs. `specs/` at the repo root is unaffected — it keeps
  `issue-strategy.md` and the Claude Design handoff bundles (see
  `specs/README.md`).
- `task spec:validate` (`openspec validate --all`) is wired into `task
  verify`'s fast-guard section, so an invalid change proposal or spec fails
  local verification and CI the same way any other guard does.
- `openspec/config.yaml`'s `context:` carries a short description of this
  repo's two-layer architecture, Conventional Commits, `task verify` as the
  gate, and the `template/`-changes-need-`fix:`/`feat:` rule, so an
  AI-authored proposal starts from an accurate model of the repo. A
  `rules.proposal` entry requires every proposal to carry a "Non-goals"
  section.

**Not:** shipped to consumers via the template. No copier answer was added,
nothing changed under `template/`, and `copier.yml` is untouched. This is
Evan's explicit decision (2026-09-01): the root dogfoods the workflow first;
whether and how to offer it to generated repos is a separate, later decision
with its own review, not a side effect of this one.

**Not:** a `package.json`. The repo has none and this change doesn't add one
for a single dependency — the CLI is pinned and fetched via `npx` instead,
the same shape already used for `@devcontainers/cli` and `markdownlint-cli2`.

**Not:** Gemini CLI as a tool integration, even though OpenSpec supports a
`gemini` target. Gemini CLI is being removed from the devcontainer in favor
of Antigravity (harmon-init#1137), so adding Gemini-flavored generated files
here would be dead configuration on arrival.

**Not:** any change proposal created by this PR. Landing the tooling and
landing the first proposal are separate, reviewable units of work; the first
proposal is a follow-up PR.

## Consequences

- `task spec:validate` introduces a new class of local/CI failure — an
  invalid `openspec/changes/*` proposal or `openspec/specs/*` capability spec
  — that did not exist before. It is a no-op success on a tree with no
  changes present, which is the state this PR leaves the repo in.
- Generated markdown under `.agents/workflows/`, `.github/prompts/`,
  `.github/skills/`, `.opencode/`, `.pi/`, and `.omp/` follows OpenSpec's own
  upstream conventions rather than this repo's, so `.markdownlint-cli2.jsonc`
  gained ignore entries for them — the same reasoning already applied to
  `.claude/**` and `.agents/skills/**`. None of those trees contain YAML, so
  `.yamllint` needed no matching entries; `openspec/` itself is deliberately
  **not** ignored by either linter.
- `.claude/skills/openspec-*` and `.agents/skills/openspec-*` are legitimately
  different per-harness files (OpenSpec writes a Claude-specific invocation
  hint into one and a generic one into the other), not an accidental
  same-name clobber, so they are declared in the new
  `.agents/skills/.link-ignore` — the escape hatch `scripts/link-agent-skills.sh`
  already provides for exactly this situation.
- `task spec:update` (`openspec update`) is how this tree stays current with
  future OpenSpec releases and tool-support changes; bumping
  `OPENSPEC_VERSION` is how this repo takes a new OpenSpec release, the same
  pattern `FOREMAN_VERSION` already establishes for the pinned Foreman CLI.
- `task spec:validate` runs through `scripts/spec-validate.sh`, not the CLI
  directly: `task verify` is documented and relied on to run offline, but
  `scripts/openspec.sh` execs through `npx`, which needs the network on a
  cold cache even to report "nothing to validate." The wrapper skips the CLI
  entirely when `openspec/changes/` and `openspec/specs/` are both empty —
  the state this PR leaves the repo in — so the common case never touches
  the network. Once a change or archived spec exists (the permanent steady
  state from that point on), the CLI has to run; a failure whose output
  matches npm/npx's own network-error codes is then treated as indeterminate
  (exit 0, warned) rather than an invalid change, so a network-denied
  checkout is never blocked by a check it cannot run — but an actual invalid
  item, once the CLI can reach the registry, still fails the gate normally.
- The generated `/opsx:*` skills invoke a bare `openspec` command. Hand-
  editing that generated content was rejected — `task spec:update` would
  silently overwrite it on the next run — so `scripts/install-openspec.sh`
  (`task spec:install`) instead installs the pinned CLI user-locally
  (`npm install -g --prefix ~/.local`); `~/.local/bin` is already first on
  `PATH` in the devcontainer. The root-only `post-create.sh` and
  `dev/post-create.sh` call it on every container build; anyone working
  outside the devcontainer runs `task spec:install` themselves. This adds one
  intentional-divergence line to each post-create script — neither has a
  template twin to update, since generated repos never receive OpenSpec
  (noted in `scripts/audit-dogfood.sh`, which already reports both files as
  differing from their template renders for unrelated, pre-existing reasons).
