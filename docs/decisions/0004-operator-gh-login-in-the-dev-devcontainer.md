# 4. The dev devcontainer authenticates as the operator, not the bot

Date: 2026-08-03

## Status

Accepted

## Context

The dual-profile devcontainer has one rule that makes the whole arrangement
legible: **a profile authenticates as the identity it commits as**. The `dev/`
profile did not obey it. It set the commit identity to the operator
(`.devcontainer/dev/post-create.sh`) while passing `GH_TOKEN` in its
`init-env.sh` allow-list, so the bot's fine-grained PAT was written into
`.devcontainer/dev/devcontainer.env` and injected via `runArgs --env-file`.

`gh` prefers `GH_TOKEN` over any stored credential unconditionally and exposes
no precedence knob, so this was not a default that a human could override from
inside the container. Commits were authored as the operator and **pushed as the
bot**, and every `gh` call was the bot.

The second consequence was a ceiling. A fine-grained PAT has exactly one
resource owner, so that token could never reach `ponderousdev/*`,
`sommerlawn/*`, or `harmonops/*` — reading `ponderousdev/foreman` from the
"human" container returned 404. Meanwhile `docs/architecture/security.md`
claimed the operator had "full access from the human `dev/` devcontainer or
host". The docs described the intent; the implementation delivered something
narrower and confusingly labelled.

This is adjacent to but distinct from
[#362](https://github.com/evanharmon1/harmon-init/issues/362), which moves the
*autonomous* identity from a PAT to a GitHub App. That issue lists "acting on
behalf of the human operator" as an explicit non-goal, so the operator path was
unowned.

## Decision

The `dev/` profile carries **no `GH_TOKEN`** and authenticates as the operator
through an ordinary `gh auth login`. The bot profile is untouched — same PAT,
same restrictions, same denials.

Six forks came with that, each decided here:

1. **The gh credential is not persisted.** `~/.config/gh` gets no volume, so a
   rebuild costs a fresh login.

   *Not* a `gh-config-*` volume, which was the obvious convenience. The
   container has no keyring, so `gh` stores the token as plaintext
   `hosts.yml`; persisting it would leave a broad, long-lived, multi-org
   credential at rest on a docker volume — strictly worse at rest than the
   scoped PAT it replaces. Friction was accepted in exchange for
   nothing-at-rest, and paid down with an actionable post-create banner rather
   than with storage.

2. **Attach modes are uniform in identity, per-mode in mechanism.** Under VS
   Code Remote-Containers, `post-create-common.sh` unsets the in-container gh
   helpers and git uses VS Code's forwarded host credential; on Coder and the
   plain CLI, `gh auth login` + `gh auth setup-git` covers both. Documented as
   such.

   *Not* forced into one mechanism. The VS Code branch predates this change and
   already yields the operator's identity; the divergence it creates is in
   plumbing, and it stopped being an *identity* divergence the moment
   `GH_TOKEN` left.

3. **Unauthenticated is loud, never fatal.** Nothing in the dev profile hard-
   requires GitHub auth: `bootstrap-related-repos.sh` warns and exits 0,
   `fetch-related-repos.sh` is backgrounded to a log, and the skills sync
   clones public harmon-devkit over plain HTTPS. `post-create` prints the exact
   commands to run.

   *Not* a 1Password fallback, even though `op` exists in this profile.
   Non-interactive `op` needs `OP_SERVICE_ACCOUNT_TOKEN` — another long-lived
   secret at rest, which is the thing being removed. A fallback that
   reintroduces the problem is not a fallback.

4. **Unattended agents belong in the bot profile — by policy, in
   `security.md`.** A human-authed container hands any agent inside it the
   operator's full multi-org reach, and this change removes the ceiling that
   previously bounded that damage. `dev/` is for attended work.

   *Not* a code guard (e.g. a `DEVCONTAINER_PROFILE` marker that foreman
   refuses to dispatch under). That is new machinery across the configs and
   `scripts/foreman/`, needing its own tests and two-layer twins, to enforce a
   rule whose violation is already a deliberate act by the operator.

   Worth recording because it is easy to miss: foreman's `backend_environment`
   withholds `GH_TOKEN` from dispatch, CI-repair, rebase, and preflight agents,
   but `HOME` is in `BACKEND_ENV_ALLOWLIST` — so a gh-stored login makes that
   least-privilege gate **vacuous** in `dev/`. The gate is real only in the
   profile it was written for, which is another way of saying the same policy.

5. **Org OAuth-app restrictions are resolved by approving the app.** Where an
   org genuinely cannot, the documented fallback is `gh auth login --with-token`
   with an SSO-authorized **classic** PAT.

   *Not* a per-org fine-grained PAT. One resource owner per token is exactly
   the constraint this ADR exists to escape; solving an SSO edge case with the
   original problem would be circular.

6. **Template consumers get this unconditionally.** Every generated repo's dev
   profile drops `GH_TOKEN` on its next `copier update`.

   *Not* a copier answer. A consumer without a bot account loses nothing, and
   one with a bot account is in exactly this situation. An opt-out knob would
   grow the render matrix to encode "has not migrated yet".

## Consequences

- The dev container reaches every org the operator does, with no per-repo token
  curation — the stated intent of the "Operator" row in `security.md` is now
  what the code does.
- A rebuild costs a `gh auth login`. This is the change's ongoing cost, and it
  is deliberate; see decision 1 before "fixing" it with a volume.
- `scripts/devcontainer-assert.sh` now asserts `GH_TOKEN`'s **absence** from the
  dev profile in three places — the allow-list behaviour, the static
  `initializeCommand`, and the running container. Regression is caught by
  `task ci`, not by a human noticing that pushes are signed by the wrong
  account.
- Downstream repos inherit the behaviour change on `copier update` and will need
  a login in their dev containers; `docs/guides/devcontainers.md` carries the
  procedure.
- The blast radius of an agent running unattended in `dev/` is now the
  operator's full access. That is governed by written policy, not by a
  mechanism — see decision 4 if that trade ever needs revisiting.
