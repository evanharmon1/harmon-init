# Glossary

Term → one-line definition for the cross-cutting vocabulary of Harmon Init.
This is the **dictionary projection** of [the domain model](product/domain.md): it
points at the model for the real relationships and reasoning — it never restates
them. A flat lookup: scan for a term, don't read top-to-bottom.

Terms below are part of the harmon-init toolchain this repo is built on; add
project-specific (domain) terms as the model firms up.

| Term | Meaning |
|---|---|
| `verify` | The aggregate CI job in `build.yml` that rolls up the other jobs into one required status check (the merge gate). See [architecture/ci-cd.md](architecture/ci-cd.md). |
| `security` (check) | The required CI job running gitleaks + dependency audit, plus Semgrep CE when this job owns the SAST route. |
| `task` / Taskfile | go-task is the single source of truth for commands; lefthook hooks and CI both delegate to `task` targets so local and CI runs are identical. |
| release-please | Bot that maintains a rolling "release" PR from Conventional Commits; merging it cuts the tag, GitHub release, and CHANGELOG. Releases are intentional, never automatic on merge. |
| `evanharmon1-ci` (GitHub App) | The CI automation app that mints short-lived tokens for CI workflows (not a PAT). See [architecture/security.md](architecture/security.md). |
| bot / dev / agent posture | The three devcontainer postures, told apart by the `FOREMAN_DEVCONTAINER` marker (`bot`, unset, `agent`): `bot` (`.devcontainer/`, AI agents on controlled infrastructure, no Tailscale), `dev` (`.devcontainer/dev/`, human, with Tailscale), and `agent` (`.devcontainer/agent/`, unattended agents, never looser than bot: its own PAT, Claude Code and Codex only, allowlisted egress, no Docker by default). See [guides/devcontainers.md](guides/devcontainers.md). |
| 1Password Environments | How devcontainer/local secrets are supplied — a virtual `.env` mounted over a pipe, never written to disk or git. |
| bot vs operator | Two identities: the AI **bot** account (scoped; `main` needs code-owner approval and green checks, and though its `pull_requests: write` PAT can perform a merge a human has approved, merging stays the maintainer's decision) and the human **operator** (full access). See [architecture/security.md](architecture/security.md). |
| TODO: term | TODO: project-specific definition |

## Issue classification

Inherent attributes of an issue itself, distinct from the **execution policy**
(`.devflow.toml`: rigor, strategy, role tiers, budgets), which decides how the
factory runs an issue and may override any default the classification implies.
Impact, Risk, Complexity, Priority, Priority (AI), and Effort are issue fields on
organization repos and labels on personal-account repos; the Tier is a label on
every owner type; Type, `area:*`, `layer:*`, and `domain:*` keep their existing
storage.

| Term | Meaning |
|---|---|
| Impact | The expected significance of completing the issue for the product's users or the business, given current goals — core benefit versus marginal benefit, not common path versus uncommon path; a rarely triggered bug with severe consequences can be high impact. Scale: minimal, low, medium, high, massive. Avoid: value, importance, severity. |
| Risk | How consequential a failure could be if the change is implemented incorrectly. For a bug fix, the danger of the fix belongs here; the harm it prevents belongs in Impact. Scale: trivial, low, medium, high, critical. Avoid: severity, blast radius. |
| Complexity | How difficult the work is to understand, design, implement, and verify correctly, including how likely it is to grow during implementation. On every issue; AI-settable. Scale: xs, s, m, l, xl. Avoid: size, effort, difficulty. |
| Tier | The model stratum the issue is suggested to run at — `local`, `economy`, `standard`, `frontier`, `apex` — derived by a pure function from Risk × Complexity (a risk-dominant matrix in `.devflow.toml`) and written by whoever writes the inputs; a materialized cache that readers recompute when absent. `local` is work a small self-hosted model can do and that may take a while. Avoid: suggest, model, family. |
| Tier pin | A human choosing the Tier from the GitHub UI: the Tier value plus the `tier:pinned` label. Nothing automated writes over a pinned Tier. In execution-policy resolution a pin sits below an operator instruction and above `rigor:*`, sets the implementer tier only, and any resolved role-tier invariant it breaks is disclosed in the PR body rather than corrected. |
| Effort | The human time estimate for work a human will do, on the modified Fibonacci ladder (1, 2, 3, 5, 8, 13, 20). Human tasks only, never agent work. Avoid: size, story points. |
| Priority | The human's ranking of when the issue should be worked: urgent, high, medium, low. Human-only and never required; unset means an agent does not start it without asking. It overrides the AI's suggested Priority (AI). Avoid: P0–P3 (review-finding severities). |
| Priority (AI) | The AI's suggested priority — `p0`, `p1`, `p2`, `p3`, `p4` — written by an agent or a human from what it knows at the time: an issue field on organization repos, a `priority-ai:<value>` label on personal-account repos. The human Priority overrides it, so the **effective priority** is Priority when set, else Priority (AI). Advisory and never required; it arms nothing. For a bug it reads as severity — how bad the defect is and how important it is to fix before merging or deploying: `p0` blocks a merge or deploy, `p1` is a real defect to fix next, `p2` is worth fixing but not blocking, `p3` is cosmetic or informational, `p4` is negligible. A review finding filed as an issue carries its adjudicated badge (P0→`p0`, P1→`p1`, P2→`p2`, P3→`p3`); nothing from a review maps to `p4`. Avoid: urgency, P0–P3 (the review-finding badges it is set from). |
| Family | A model lineage: claude, gpt, gemini, qwen… Distinct from a **harness** (the executable that runs it). |
| Claim | The marker recording which model family took the work: `claim:<family>[:<model>]`. A signal, not a lock; the harness and runtime are in the claim comment. |
| triaged | Every required classification is present: Type (or work-type label), one label from each of the `area:*`, `layer:*`, and `domain:*` families (or that family's explicit `none` value), Risk, Complexity, Impact. `needs-triage` is added at filing by whoever files an issue that is not fully classified, then derived from this and never cleared by hand. |
| Size | Retired: superseded by Effort (human tasks) and Complexity (every issue). |
| `suggest:*` | Retired: the family suggestion, superseded by Tier; its namespace is removed from the agent registry. |
| `tier:adaptive` | Retired 2026-10-01: no rung on the Tier scale. The label is removed and the issue resolves through its derived Tier. |
| `needs-review` | The issue's PR is waiting for human review; it keeps the issue out of the agent queue. The integration stage adds it at ready-for-review, when it removes `claim:*`, and removes it if review sends the work back, once harmon-devkit#1255 ships with a skills-pin bump. Until then a human adds it, and removes it on pull-back, by hand, as the Views section of [project-management.md](project-management.md#views) describes. |
