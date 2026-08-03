# Devcontainers

Harmon Init ships a **dual-profile** devcontainer. Both profiles share
one `Dockerfile` and the baked `.devcontainer/config/` tree; they differ in
which secrets and capabilities they allow.

| Profile | Path | For | GitHub auth | Tailscale |
|---|---|---|---|---|
| **Bot** | `.devcontainer/devcontainer.json` | AI agents (Claude Code, Codex, Gemini) | the bot's PAT via `GH_TOKEN` | no |
| **Dev** | `.devcontainer/dev/devcontainer.json` | humans | the operator's own `gh auth login` | yes (`TS_AUTHKEY`, `--device=/dev/net/tun`) |

Each profile authenticates as the identity it commits as, and the omissions are
what make that true: the bot profile leaves `TS_AUTHKEY` off its allow-list so a
tailnet key never reaches an agent container, and the dev profile leaves
`GH_TOKEN` off so a bot credential never reaches a human one.

**Claude permission mode differs by profile.** The **bot** defaults to
`bypassPermissions` (Claude runs tools without per-action prompts — the container
is the isolation boundary); the **dev** profile keeps the normal prompt-on-action
default so a human stays in the loop. The shared managed settings
(`config/claude-settings.json`) deliberately omit `defaultMode`; the bot opts in
at create time via `scripts/enable-claude-bypass.sh`. `bypassPermissions` is only
safe because it is container-scoped — it is never set on the host.

## Run it locally

- **VS Code:** "Dev Containers: Reopen in Container" → pick the **Dev** profile
  (`.devcontainer/dev/`) for human use.
- **CLI:** `devcontainer up --workspace-folder . --config .devcontainer/dev/devcontainer.json`

Prebuilt images are pulled from GHCR as a build cache
(`ghcr.io/evanharmon1/harmon-init-devcontainer` / `ghcr.io/evanharmon1/harmon-init-devcontainer-dev`), so a warm rebuild
is fast. A cache miss is non-fatal — it just rebuilds from the `Dockerfile`.

## Claude Code settings in the container

Everything is sourced from `.devcontainer/config/` and baked into the **image**,
so a volume wipe can never leave the container without its policy, hooks, or
status line:

| What | Lives at | Source | Overridable |
|---|---|---|---|
| Managed settings | `/etc/claude-code/managed-settings.json` (image) | `config/claude-settings.json` | no (policy) |
| Hook scripts | `/etc/claude-code/hooks/` (image) | `config/claude-hooks/` | no |
| Status line | `/etc/claude-code/statusline.sh` (image) | `config/claude-statusline.sh` | yes |
| User defaults | `~/.claude/settings.json` (**volume**) | `config/claude-user-defaults.json` | yes |

The last row is the one exception, and deliberately so: `~/.claude/settings.json`
is volume-backed because Claude Code writes your in-app changes there. Every
`post-create` **seed-merges** the image copy into it — existing values win, so
`/model` and friends stick, and a wiped volume gets the defaults back. What the
volume never holds is the code those settings point at.

`config/claude-statusline.sh` renders the same four-line status line as a host
session, so a container session reads identically:

```text
📁 ~/git/harmon-init  🌿 main  PR #512 ✓  ▪ session name  · a1b2c3d4
🧠 ▕████░░░░░░░░░░░░▏ 24%  760k left  🤖 Opus 5 1M · medium · ⚡ · 💭  📟 v2.1.220
💰 $0.43  ✎ +120/-45  ⏱ 11m session
🚦 5h ▕█░░░░░░▏ ⧖ 2h13m   ·   7d ▕░░░░░░░▏ ⧖ 4d20h
```

Reading down: where you are, how much room and horsepower are left, what the
session has cost, and how close the 5-hour and 7-day subscription limits are to
biting (`⧖` is time until that window resets). Segments that would say nothing
are omitted rather than shown empty — the PR only appears on a branch that has
one, `⚡` and `💭` only when fast mode and extended thinking are on, and the
launch directory only when it differs from the one you are in. Unknown is not
empty: a payload carrying no context percentage renders `🧠 context n/a`, never
a 0% bar over a window that may be nearly full.

Both gauges fill as they are consumed and shift mint → peach → coral past 60%
and 80%; the limit bars run the same scale at under half the width in a muted
palette, so they read as the same thing at lower priority. `NO_COLOR` is
honored, and `STATUSLINE_CTX_WIDTH`, `STATUSLINE_RL_WIDTH`, `STATUSLINE_RL_PCT`
(exact limit percentages) and `STATUSLINE_HYPERLINK` (the OSC-8 link behind the
PR number) tune the rest.

It is built to be cheap, because it re-renders constantly: two forks per render
(`jq` and `date`), no `git` subprocess — the branch is read from `.git/HEAD`
directly, worktrees included — and nothing written to disk.

To use your own instead, point `statusLine.command` in `~/.claude/settings.json`
at it — the seed merge will not overwrite it.

## Secrets — 1Password Environments (the standard)

Don't hand-write or copy `devcontainer.env`. The standard is **1Password
Environments**, which mounts a virtual `.env` over a UNIX pipe — the values are
**never written to disk or committed** (the path is gitignored anyway).

1. In the **1Password** app → **Developer** → **Environments**, create an
   environment for this repo (import an existing `.env` or add the variables
   below, each referencing a vault item).
2. Set the destination to **Local .env file** and point the mount at
   `.devcontainer/devcontainer.env` (bot). Add a second destination at
   `.devcontainer/dev/devcontainer.env` for the dev profile.
3. Authorize access when prompted. The container's `--env-file` then reads it
   like any `.env`.

Variables per profile:

| Variable | Bot | Dev | What it's for |
|---|---|---|---|
| `GH_TOKEN` | ✅ | — | the **bot's** `gh` CLI / API (dev logs in as you instead) |
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ | ✅ | Claude Code |
| `AGENT_DECK_TELEGRAM_KEY` | ✅ | ✅ | agent-deck bridge (optional) |
| `TS_AUTHKEY` | — | ✅ | Tailscale (dev only) |
| `KIMI_API_KEY` / `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY` | ✅ | ✅ | alt-model wrappers (opt-in: `use_alternative_claude_providers`) |

`ANTHROPIC_API_KEY` is deliberately **forbidden** — it silently overrides
`CLAUDE_CODE_OAUTH_TOKEN`, so `init-env.sh` strips it from the env-file.

### Operator GitHub login (dev profile)

The dev profile ships no `GH_TOKEN`, so `gh` and `git` are unauthenticated until
you log in as yourself:

```sh
gh auth login --hostname github.com --git-protocol https \
  --web --scopes "workflow,project"
gh auth setup-git
```

`--scopes` is *additive* to gh's defaults (`repo`, `read:org`, `gist`). `project`
is what Projects V2 writes need — without it `task status:gh` reports the board
as unreachable — and `workflow` lets you edit `.github/workflows/`, which the bot
is deliberately denied. `--web` opens a browser when there is one and otherwise
prints a device code, so it works over a plain terminal. `gh auth setup-git` is
the separate step that bridges the login into git's credential helper; the
`post-create` that normally does it has already run by the time you log in, so
run it yourself.

**You will do this again after every rebuild.** `~/.config/gh` is on no volume —
[architecture/security.md](../architecture/security.md) explains why that is the
trade rather than an oversight.

Nothing fails hard before you log in. `post-create` prints the commands above,
sibling repos are skipped with a warning (re-run
`bash .devcontainer/scripts/bootstrap-related-repos.sh` afterwards), and
`task verify` is unaffected — the skills sync clones the public harmon-devkit
over plain HTTPS. What does not work is anything that talks to GitHub *as you*:
`git push`, `gh pr`, `gh api`.

Under **VS Code Remote-Containers** this differs in mechanism, not identity:
`post-create-common.sh` unsets the in-container gh credential helpers and lets
VS Code forward the host's, so *git* already acts as you on attach while `gh`
still needs its own login. Run `gh auth login` there but **not**
`gh auth setup-git` — re-adding the helper fights the one VS Code manages, which
is why post-create unset it. On Coder and the plain CLI, where nothing else
manages git's credential, both commands apply.

**If an org restricts third-party OAuth apps** (or enforces SAML SSO), the GitHub
CLI app needs that org's approval before your login reaches its repos. Approving
the app is the fix. Where an org genuinely cannot, the fallback is
`gh auth login --with-token` with an SSO-authorized **classic** PAT — not a
fine-grained one. A fine-grained PAT has exactly one resource owner, so using one
here would reintroduce the single-org ceiling this arrangement exists to remove.

### Alternative model providers (`claude-kimi` / `claude-deepseek` / `claude-glm`)

Opt in with the `use_alternative_claude_providers` Copier answer (default off;
asked only when `devcontainer=true`) to ship the `claude-kimi`, `claude-deepseek`,
and `claude-glm` shell functions. They mirror the host wrappers in harmon-dotfiles:
each launches `claude` in a subshell with `ANTHROPIC_BASE_URL` +
`ANTHROPIC_AUTH_TOKEN` pointed at a provider's native Anthropic-compatible
`/anthropic` endpoint (Moonshot Kimi K3, DeepSeek V4, Z.AI GLM-5.2 — no proxy),
plus the per-tier `ANTHROPIC_*_MODEL` vars. The functions live in
`.devcontainer/config/claude-providers.sh` and are sourced from `shell-aliases.sh`.

The provider API keys flow through the same env-file pipeline as everything else
(`init-env.sh` allow-list → `devcontainer.env` → `--env-file`), so add them to your
1Password Environments mount. **Both profiles** receive the keys when opted in. The
bot runs `bypassPermissions`, so be aware a headless agent in the bot can read them —
this is a deliberate extension of the bot's posture, not an oversight. The wrappers
themselves are interactive (you type `claude-glm`); a default `agent-deck`/foreman
launch still invokes plain `claude`.

Two container-specific details differ from the host wrappers:

- Each wrapper `unset`s `CLAUDE_CODE_OAUTH_TOKEN` in its launch subshell (in addition
  to `ANTHROPIC_API_KEY`). The container sets the OAuth token via its env-file; left
  set, it would compete with the provider's `ANTHROPIC_AUTH_TOKEN`. Unsetting it
  guarantees the provider auth wins for that launch only.
- The `op run` key fallback (used when the env var is absent) re-sources the
  image-baked `/usr/local/share/devcontainer-config/claude-providers.sh`, not
  `~/.dotfiles/.functions`. It works only in the dev profile (the bot has no
  1Password CLI); in the bot the env-file is the only key source.

### What `init-env.sh` does

On container init the devcontainer runs `.devcontainer/scripts/init-env.sh` on
the **host**. It enforces the per-profile allow-list (e.g. evicts `TS_AUTHKEY`
and `ANTHROPIC_API_KEY` from the bot env-file, and `GH_TOKEN` from the dev one,
on every rebuild) and, in
environments where the 1Password app isn't present (**Coder / Codespaces**),
captures the same variables from the **host environment**, where they arrive as
workspace/template parameters. It does **not** call `op` itself — 1Password
Environments is what supplies the values locally.

## Run it in Coder

The devcontainers are Coder-ready: the `CODER` env is passed through, the
`config/` tree is baked to `/usr/local/share/devcontainer-config/` so it
survives Coder's `/tmp` mount shadowing, and `init-env.sh` reads secrets from
the host environment (above).

What Coder needs is a **workspace template** that clones this repo and builds the
devcontainer — that template is **org-level infrastructure, not part of this
repo** (one template serves every repo). To stand this repo up in Coder:

1. Use your org's Coder "devcontainer" template (the canonical example is
   `terraform/coder/devcontainer/` in
   [harmonops/harmon-infra](https://github.com/harmonops/harmon-infra)). It uses
   the Coder `git-clone` + `devcontainers-cli` modules.
2. Create a workspace from it and set the parameters:
   - **repo** → `https://github.com/evanharmon1/harmon-init`
   - secrets → `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`, and
     `GH_TOKEN` **for a bot workspace only** — a dev workspace runs
     `gh auth login` instead (+ `TS_AUTHKEY` if you want Tailscale);
     `KIMI_API_KEY`/`MOONSHOT_API_KEY`,
     `DEEPSEEK_API_KEY`, `ZAI_API_KEY` for the alt-model wrappers. Coder passes these
     into the workspace's host environment, where `init-env.sh` picks them up.
3. The build pulls `ghcr.io/evanharmon1/harmon-init-devcontainer` from GHCR as a cache. If that
   package is private, give the Coder builder a read token (or make the package
   public); a cache miss only makes the first build slower.

> This repo's `Dockerfile` is a thin overlay on the **public** shared
> `ghcr.io/evanharmon1/harmon-devcontainer` toolchain image (pinned by
> immutable `tag@digest`), so no registry credential is needed for the base —
> only the repo's own `-devcontainer` cache image matters.

## Working on related repos

To work across several repos in one container, list them in
`.devcontainer/related-repos.txt` (one `owner/repo` per line; `@branch`, full
URLs, and ssh URLs also work — ssh URLs are rewritten to https by the
container gitconfig, which `post-create-common.sh` sets up so in-container
git operations never depend on an SSH agent). They are:

- **cloned** into `/workspaces/`, beside this repo, on container **create**
  (`scripts/bootstrap-related-repos.sh`) — so a rebuilt or persistence-lost
  container re-populates them;
- **fetched** non-destructively on container **start**
  (`scripts/fetch-related-repos.sh`).

Both are safe to re-run: an already-cloned sibling is **never clobbered** —
clone skips it, and start runs `git fetch` only (never pull / merge / checkout),
so uncommitted work, local commits, and the checked-out branch stay put. The
list is preserved across `copier update` (an empty list is a no-op).

To let Claude read and search the cloned siblings, add them to
`.claude/settings.json` in **two** places — `permissions.additionalDirectories`
(Claude's own Read/Grep/Glob tools) and `sandbox.filesystem.allowRead` (the Bash
sandbox):

```json
{
  "permissions": {
    "additionalDirectories": ["../sibling-repo"]
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["../sibling-repo"]
    }
  }
}
```

## See also

- [architecture/security.md](../architecture/security.md) — full secret strategy.
- [troubleshooting.md](troubleshooting.md) — devcontainer issues.
- `.github/workflows/devcontainer-build.yml` — the GHCR prebuild.
