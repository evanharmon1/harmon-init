# Branch Protection: Protecting `main` from AI Agents

## Purpose

This document explains the branch protection ruleset applied to `main` and how it ensures that AI coding agents (e.g., Claude Code running in a dev container) cannot push to or merge into `main` without explicit human approval. The ruleset works in combination with a dedicated machine user account (`evanharmon1-bot`) that has Write collaborator access and a scoped fine-grained PAT.

## Applying the Ruleset

An importable copy of the ruleset ships in this repo at
`.github/Branch Protection Ruleset - Protect Main.json`. Import it via the UI
(Settings → Rules → Rulesets → Import a ruleset) or the API:

```bash
gh api "repos/evanharmon1/harmon-init/rulesets" \
  --method POST \
  --input ".github/Branch Protection Ruleset - Protect Main.json"
```

## Dependabot and Renovate

Version updates are owned by **Renovate** (`renovate.json`) — do not add a
`dependabot.yml`, it would duplicate Renovate's PRs. Dependabot still has a
role as a GitHub-native security layer; enable these in
Settings → Advanced Security:

- Dependabot alerts
- Dependabot security updates (optional — alerts may be enough since Renovate
  proposes the same bumps)
- Private vulnerability reporting (used by `.github/SECURITY.md`)

## Security Model Overview

Three independent layers enforce the boundary between AI agent work and production code:

1. **Fine-grained PAT** — Scoped to `contents: write` and `pull_requests: write` on specific repos. This is the token the AI agent uses in the dev container. It cannot modify repo settings, branch protection, or workflows.
2. **Repository ruleset on `main`** — Server-side enforcement that blocks direct pushes, requires PR reviews from a code owner, and mandates passing status checks before merge.
3. **CODEOWNERS file** — Designates the human owner as the required reviewer for all file changes, ensuring the bot's PRs always require human approval.

No single layer is sufficient alone. The PAT controls _what operations the token can attempt_. The ruleset controls _what operations GitHub allows on `main`_. The CODEOWNERS file controls _whose approval counts_.

## Prerequisites

### CODEOWNERS File

The `require_code_owner_review` rule in the ruleset **only works if a `CODEOWNERS` file exists** in the repo. Without it, the rule is silently unenforced. Create one at the repo root or `.github/CODEOWNERS`:

```text
# All files require the repo owner's approval
* @evanharmon1
```

Replace `@evanharmon1` with the GitHub username of the human who should approve all changes.

### Bot Account PAT Permissions

The machine user account's fine-grained PAT should have these permissions and nothing more:

| Permission      | Level          | Purpose                              |
| --------------- | -------------- | ------------------------------------ |
| Contents        | Read and write | Clone, push, create branches, commit |
| Pull requests   | Read and write | Open PRs, update PRs, comment        |
| Metadata        | Read-only      | Required by all tokens               |
| Actions         | Read-only      | View CI workflow run status          |
| Checks          | Read-only      | View check runs on PRs               |
| Commit statuses | Read-only      | View status checks on commits        |

## Ruleset Configuration

```json
{
  "id": 14110902,
  "name": "Protect Main",
  "target": "branch",
  "source_type": "Repository",
  "source": "evanharmon1/harmon-init",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "exclude": [],
      "include": ["~DEFAULT_BRANCH", "refs/heads/main"]
    }
  },
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "creation"
    },
    {
      "type": "required_linear_history"
    },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "required_reviewers": [],
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {
            "context": "secrets",
            "integration_id": 15368
          },
          {
            "context": "validate",
            "integration_id": 15368
          },
          {
            "context": "build-homepage",
            "integration_id": 15368
          },
          {
            "context": "security",
            "integration_id": null
          }
        ]
      }
    }
  ],
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ]
}
```

## Rule-by-Rule Explanation

### Target and Conditions

The ruleset targets branches matching `~DEFAULT_BRANCH` and `refs/heads/main`. The `~DEFAULT_BRANCH` is a GitHub alias that always resolves to whatever the repo's default branch is, so even if the default branch name changes, the ruleset follows. Including `refs/heads/main` explicitly is belt-and-suspenders.

### `bypass_actors: []`

**No one can bypass these rules.** This is intentional. Even the repo owner must go through the full PR process. If you later need an emergency bypass (e.g., for a hotfix), you would temporarily add yourself as a bypass actor, but the default posture is zero exceptions.

### `deletion`

Prevents deleting the `main` branch. Without this, anyone with write access could delete and recreate `main`, potentially losing branch protection in the process.

### `non_fast_forward`

Blocks force pushes (`git push --force`) to `main`. Force pushes rewrite history and can silently remove commits, including security fixes. This ensures `main`'s history is append-only.

### `creation`

Prevents creating a branch matching the pattern. Since `main` already exists, this blocks scenarios where someone deletes `main` and recreates it (bypassing protection that was on the original branch).

### `required_linear_history`

Enforces a linear commit history on `main` — no merge commits. Combined with `allowed_merge_methods: ["squash", "rebase"]`, this means every PR becomes either a single squashed commit or a rebased series of commits. This makes `git log` on `main` clean and easy to reason about, and simplifies `git bisect` for debugging.

### `pull_request`

This is the core rule that prevents the AI agent from pushing directly to `main`. All changes must come through a pull request. The parameters enforce multiple safeguards:

| Parameter                           | Value                  | Effect                                                                                                                                                                                                                        |
| ----------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `required_approving_review_count`   | `1`                    | At least one approving review required before merge                                                                                                                                                                           |
| `require_code_owner_review`         | `true`                 | The approving review **must** come from a designated code owner (see CODEOWNERS file). A review from the bot or any non-code-owner does not satisfy this.                                                                     |
| `require_last_push_approval`        | `true`                 | The person who pushed the most recent commit cannot be the one to approve it. Since the bot pushes, the bot cannot self-approve — even if it could submit reviews. A human code owner must approve after the bot's last push. |
| `dismiss_stale_reviews_on_push`     | `true`                 | If the bot pushes new commits after a human approves, the approval is dismissed and the human must re-review. Prevents a pattern where the bot gets approval, then pushes different code and merges.                          |
| `required_review_thread_resolution` | `true`                 | All review comments must be resolved before merge. Prevents merging while a human reviewer still has open concerns.                                                                                                           |
| `allowed_merge_methods`             | `["squash", "rebase"]` | Only squash and rebase merges allowed. No merge commits, consistent with `required_linear_history`.                                                                                                                           |

### `required_status_checks`

All specified CI checks must pass before the PR can merge. The `strict_required_status_checks_policy: true` setting means the PR branch must be up-to-date with `main` before merging — if `main` advances after the checks ran, the checks must re-run. The `do_not_enforce_on_create: true` setting skips enforcement when the branch is first created (before any CI has had a chance to run).

The required checks for this repo are:

| Check                | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `secrets`            | Scans for leaked secrets (Gitleaks)      |
| `validate-compose`   | Validates Docker Compose configuration   |
| `validate`           | General validation (linting, formatting) |
| `validate-templates` | Validates infrastructure templates       |
| `build-homepage`     | Ensures the homepage builds successfully |

## What the AI Agent Can and Cannot Do

| Operation                               | Allowed? | Enforced by                                     |
| --------------------------------------- | -------- | ----------------------------------------------- |
| Clone the repo                          | ✅       | PAT `contents: read`                            |
| Create feature branches                 | ✅       | No ruleset on non-main branches                 |
| Push commits to feature branches        | ✅       | PAT `contents: write` + no protection           |
| Open PRs targeting main                 | ✅       | PAT `pull_requests: write`                      |
| Update PRs with new commits             | ✅       | Push to PR source branch                        |
| View CI status on PRs                   | ✅       | PAT `actions: read`, `checks: read`             |
| Push directly to main                   | ❌       | `pull_request` rule requires PR                 |
| Self-approve its own PR                 | ❌       | `require_last_push_approval` blocks it          |
| Merge after non-code-owner approves     | ❌       | `require_code_owner_review` blocks it           |
| Merge after approval then push new code | ❌       | `dismiss_stale_reviews_on_push` resets approval |
| Force push to main                      | ❌       | `non_fast_forward` rule                         |
| Delete main                             | ❌       | `deletion` rule                                 |
| Modify branch protection rules          | ❌       | Write collaborator role has no settings access  |

## Applying This Ruleset to Other Repos

This ruleset ships with every repo generated from harmon-init. To replicate manually:

1. Create a `CODEOWNERS` file with `* @evanharmon1`
2. Create a branch ruleset targeting `~DEFAULT_BRANCH` with the same rules
3. Add the bot as a Write collaborator
4. Update the `required_status_checks` to match that repo's CI checks
5. Verify by attempting a direct push to main from the bot account — it should be rejected

If repos move to the `ponderous` organization in the future, consider creating an **org-level ruleset** (requires GitHub Team plan) that applies these rules across all repos automatically, eliminating the need to configure each repo individually.

## Future Considerations

- **GitHub App migration**: If the team grows or token rotation becomes burdensome, replacing the machine user PAT with a GitHub App provides automatic 1-hour token expiry and eliminates the seat cost on paid plans. The ruleset works identically with GitHub App tokens.
- **Terraform management**: The GitHub Terraform provider supports `github_repository_ruleset` resources. Codifying the ruleset in Terraform ensures consistency as repos multiply.
- **Additional status checks**: As the CI pipeline matures, add checks for E2E tests (Playwright), accessibility (axe-core), and performance (Lighthouse CI) to the required list.
