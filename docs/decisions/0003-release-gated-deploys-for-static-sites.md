# 3. Release-gated production deploys for static sites (not web apps)

Date: 2026-07-14

## Status

Accepted

## Context

The template can scaffold two deploy-capable project types, and they want
opposite things from the `main` → production relationship:

- **`web-astro`** — a marketing/content site served as **static assets** from a
  Cloudflare Worker. Stateless: no database, no schema, no auth, no payments.
  A deploy is a content swap; rollback is "re-serve the previous bundle."
- **`web-app`** — a stateful application (e.g. the TanStack/React + Convex +
  Clerk + Stripe pattern in `omator`). Deploys carry **schema migrations,
  auth, and money movement**; rollback can be lossy or impossible once a
  migration has run or a charge has settled.

Both are also scaffolded alongside automation that can land commits on `main`
without a human writing them: the `claude-*` actions, GitHub Copilot's coding
agent, Renovate, and foreman-driven agent PRs (see
[0002](0002-foreman-deterministic-supervisor.md)). So "what does a merge to
`main` do?" is a safety question, not just an ergonomics one.

A single default (deploy-on-merge everywhere, or release-gate everywhere) is
wrong for one of the two. This ADR records why the template splits them.

## Decision

**`web-astro` sites are release-gated. `web-app` projects are not.**

- **`web-astro` → release-gated production.** A normal merge to `main` only
  *stages*. Production ships when the **release-please release PR is merged** (a
  deliberate human act that cuts the tag + CHANGELOG), and `release.yml`'s
  `deploy-production` job deploys the **tagged commit**. `workflow_dispatch`
  stays as the bootstrap/rollback escape hatch. This is wired via the
  `deploy_cloudflare_workers` question, which defaults `true` for `web-astro`.
- **`web-app` → deploy-on-merge.** Merging to `main` deploys production
  directly (gated only by a one-time `DEPLOY_APP` enablement switch), then
  smoke-tests the live URL. The release-please PR maintains the CHANGELOG but
  does **not** trigger deploys. The template does not ship a `web-app` deploy
  workflow yet; such projects hand-roll one (tracked as a follow-up).

The rationale each way:

**Why release-gate `web-astro`:**

- **Intentional releases.** Decouple *integrated* (merged) from *shipped*
  (deployed): batch several merges into one release, review the accumulated
  CHANGELOG, and choose when to ship independently of when you merge.
- **Automation-merge safety.** If `main` → prod were automatic, any
  agent-merged or Renovate-merged PR would ship the instant it lands. The
  release gate makes `main` a staging line that automation can reach but
  **cannot ship from**; only a human merging the release PR ships.
- **Staging for free.** Per-PR preview URLs (`deploy-preview.yml`) are the
  validation surface and `main` is the soak buffer — no separate staging
  environment or long-lived branch required.
- **Versioned + revertable.** Prod deploys a **tag**, not a moving `main` HEAD,
  so releases are versioned, changelog'd, and rollback is "redeploy the
  previous tag." Cheap and safe *because the site is stateless*.

**Why NOT release-gate `web-app` (the explicit "not"):**

- **Small, frequent, attributable deploys are safer for stateful systems.**
  Batching many merged PRs into one release means multiple schema/data changes
  ship together — a bigger, harder-to-attribute, harder-to-roll-back blast
  radius. Deploy-on-merge keeps each production change small and tied to one
  PR, with an immediate post-deploy smoke test.
- **The tag-rollback property doesn't hold.** With migrations, Stripe state,
  and user data, "redeploy the old tag" can be lossy or impossible; the
  discipline that actually protects a web app is expand/contract migrations and
  forward-fix, not a release gate.
- **The automation-safety concern is already covered elsewhere.** For web apps
  the guard is the **human-merge-only** rule from
  [0002](0002-foreman-deterministic-supervisor.md) — branch protection,
  code-owner review, no auto-merge, and a bot token without bypass or
  `workflows` write. `main` is human-gated even though it deploys, so
  release-gating would trade away the frequent-deploy benefit **without adding
  safety the app doesn't already have.**

## Consequences

- `web-astro`: `deploy_cloudflare_workers` defaults `true`, so `release.yml`
  renders the `deploy-production` job (deploy the tag on release; dispatch for
  bootstrap/rollback) and `deploy-preview.yml` provides per-PR previews. No
  action needed to get the release-gated behavior.
- `web-app`: opts out of the static Cloudflare deploy (`deploy_cloudflare_workers`
  is offered but not defaulted on) and supplies its own deploy-on-merge
  workflow. A first-class `web-app` deploy template (Convex + Cloudflare,
  distilled from `omator`) is a deliberate follow-up, not shipped here.
- Both keep `workflow_dispatch` so an emergency/manual deploy never depends on
  the normal path — important for a stateful web app during an incident.
- Revisit if a `web-astro` site ever grows server-side state (forms with
  storage, edge KV, auth): at that point it has moved toward the `web-app`
  profile and this ADR's split should be re-evaluated for it.
