# Claude Code on the web

One cloud environment, for every repo, that runs the dev loop from the shared
bootstrap — and what is known, and not yet known, about how the loop's `gh`
calls behave behind the platform's GitHub proxy.

Read this when creating or editing the environment at
[claude.ai/code](https://claude.ai/code), when a cloud session fails in a way
that looks like an auth problem, or when deciding what to send to the cloud.
The contract the setup script honours (every tool installed by the same script,
from the same pin, as the shared image) is
[architecture/remote-environments.md](../architecture/remote-environments.md);
this is the Claude-Code-specific *procedure* and record.

## How to read the evidence in this guide

Every platform fact carries where it came from, because the platform changes and
some facts here have not been seen by a person yet:

| Tag | Meaning |
| --- | --- |
| **docs, 2026-09-29** | Stated by the platform docs ([cloud environments](https://code.claude.com/docs/en/cloud-environments), [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)), re-read on that date. Where they differ from what was observed, the docs win as the *documented* behaviour and this guide says so |
| **observed 2026-09-27** | Seen in a real Claude Code on the web session (a full dev loop on several harmon-devkit PRs), recorded in the [evidence comment on #1407](https://github.com/evanharmon1/harmon-init/issues/1407#issuecomment-5860625937) |
| **observed 2026-10-06** / **2026-10-07** | Seen by the maintainer in a live walkthrough of the `harmon-remote` environment (network **Trusted**; setup script the recipe at `v5.2.0`, with the interim `sudo env …` line from 23:19Z on 2026-10-06, then the recipe unchanged at `v5.2.1` on 2026-10-07). Claude Code on the VM was 2.1.292; the local CLI used for `--cloud` was 2.1.284 |
| **REST since #1430** | A harmon-init script moved off GraphQL-backed `gh` subcommands onto the bounded REST helpers in `scripts/lib/gh-rest.sh`. Tested hermetically; not yet run in a cloud session |
| **expected, not yet observed** | Derived from the docs or from how a script is written. **Not** an observation |
| **pending** | A `[HUMAN]` observation that still needs a live session run by the maintainer. Each has a row marked open in [Pending observations](#pending-observations) |

Nothing marked *expected* or *pending* should be relied on as fact.

## The environment

Environments are personal to the claude.ai account (Team and Enterprise Owners
can share one — *docs, 2026-09-29*). Create it from the environment selector at
claude.ai/code → **Add cloud environment**. There is no settings page or URL for
it. One environment serves every repository, because nothing in it is per-repo.

| Field | Value |
| --- | --- |
| **Name** | `harmon-remote` |
| **Network access** | **Trusted**; **Custom** with `semgrep.dev` added only if a session itself runs `task security` before its PR is opened — see [Network](#network) |
| **Environment variables** | see [Environment variables](#environment-variables); none is a secret |
| **Setup script** | the block below |

Select it for CLI-started sessions with `/remote-env` (saved as
`remote.defaultEnvironmentId` in user settings — *docs, 2026-09-29*), so
`claude --cloud` uses it without a flag.

### Setup script

The script is the entrypoint from
[architecture/remote-environments.md § The entrypoint](../architecture/remote-environments.md#the-entrypoint),
unchanged. It runs as root before Claude Code starts, and the platform snapshots
the filesystem when it finishes inside about five minutes (*docs, 2026-09-29*).

```bash
#!/bin/bash
HARMON_INIT_REF=vX.Y.Z   # the release tag, written once
harmon_bootstrap_dir="$(mktemp -d)" && chmod 0700 "$harmon_bootstrap_dir" \
  && curl -fsSL "https://raw.githubusercontent.com/evanharmon1/harmon-init/${HARMON_INIT_REF}/images/devcontainer/bootstrap-remote.sh" \
    -o "${harmon_bootstrap_dir}/bootstrap-remote.sh" \
  && sudo bash "${harmon_bootstrap_dir}/bootstrap-remote.sh" --ref "$HARMON_INIT_REF"
```

Rules for this script, each with its reason:

- **Pin a release tag, never `main`.** The bootstrap refuses anything that is not
  `vX.Y.Z`. The tag is the trust root, and the environment moves only when you
  edit the tag — which also rebuilds the cache (*docs, 2026-09-29*: a changed
  setup script re-runs it).
- **`vX.Y.Z` is the release tag you want, `v5.2.1` or later** — `v5.2.1`
  (published 2026-10-07) is the first release that carries the trust-store
  fix; `v4.48.0` (published 2026-10-03) is the first that carries the bootstrap.
  **A release older than `v5.2.1` fails behind the platform's TLS-intercepting
  proxy** — observed 2026-10-06, Claude Code 2.1.292, network **Trusted**: at
  `v5.2.0` the setup script exits 2 at `==> semgrep 1.178.0` with `invalid peer
  certificate: UnknownIssuer`, because the VM's proxy CA is seeded into the
  system trust store and `sudo` resets the environment that names it. Until you
  pin a release that carries the fix, run the recipe's last line with `env` after `sudo`
  — `sudo env UV_SYSTEM_CERTS=1 NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt bash`
  and then the same script path and `--ref` arguments as before. With that, the
  unchanged `v5.2.0` bootstrap completed with `tiers core,agents, 20 new
  install(s)` and exit 0. That line is verified at `v5.2.0` only: releases
  `v4.48.0` through `v5.2.0` all need it, and the release that carries the fix
  will not (observed 2026-10-07: the unchanged recipe at `v5.2.1` started a
  session, below). Why the fix is in the bootstrap rather than in the
  recipe:
  [architecture/remote-environments.md § The network the bootstrap may use](../architecture/remote-environments.md#the-network-the-bootstrap-may-use).
- **Do not append `|| true`.** The platform fails the session start when the
  script exits non-zero (*docs, 2026-09-29*). Here that is the wanted outcome: a
  session that starts without the pinned toolchain would run the dev loop
  against the platform's stock tools and pass or fail for the wrong reasons — the
  Python `yq` on the VM's `PATH` is the documented example.
- **Keep the download its own command.** Piping `curl` into a shell exits 0 when
  the download fails. `scripts/test-bootstrap-remote.sh` checks that shape in
  every copy of the recipe, and holds this one equal to the architecture
  document's line for line; the leading `#!/bin/bash` and the pinned tag are the
  only differences it allows.
- **The default tiers only** (`core,agents`). The browsers tier is larger than
  everything else together and would put the five-minute cache budget at risk.
- **No `--tiers` flag, no other install lines.** Anything the loop needs belongs
  in the shared scripts, so the image and every other remote adapter get it too.

**Observed (criterion 1), 2026-10-06, Claude Code 2.1.292
on the VM:** with the trust store named as above, the bootstrap completed in 86
seconds, and in 48 seconds on a second fresh VM — well inside the
platform's five-minute cache budget. Without it, the same script fails at
`semgrep`, as the release-tag rule above describes. CI's `remote-bootstrap` job
cannot see that failure: its stock `ubuntu:24.04` container has a direct network
and no intercepting proxy (in the same image, a local run of this recipe
completed in 43 seconds), and it runs the checkout's own bootstrap rather than
the recipe's download at a tag. Both runs were the platform running the environment's setup script,
with the recipe's last line in the interim form.

**Observed (criterion 1, the unchanged recipe), 2026-10-07:** the environment's
setup script was set to the recipe above **unchanged** at
`HARMON_INIT_REF=v5.2.1` — no interim `sudo env` line and no diagnostic wrapper
— and the session started. `/usr/local/share/harmon-remote-env/manifest.json`
reports `harmon-remote-env` at revision `v5.2.1`. `semgrep 1.178.0` and `copier`
are at `/usr/local/bin`; `markdownlint-cli2` and `codex` are at `/opt/node22/bin`
(the platform's npm prefix, #1429; see [Other behaviour worth
knowing](#other-behaviour-worth-knowing)); `task` is 3.53.1. So `v5.2.1`
carries the trust-store fix: the unchanged recipe completes behind the
platform's proxy.

**Caching works (observed 2026-10-07, criterion 1's cache half).** A session
created at 18:01:28Z booted at 18:01:31Z while its
`/var/tmp/harmon-bootstrap.log` showed a run from 04:35:08Z to 04:36:04Z (file
modification time 04:36:04Z): a snapshot about 13.5 hours old, reused across the
GitHub-connection changes made in between ([Whose identity GitHub
sees](#whose-identity-github-sees)). That run is close to, but not the
same as, the 04:34Z session's own run (04:35:09Z to 04:36:08Z), so the snapshot
appears to come from a separate build of the setup script at the same time;
which run the platform snapshots is not established. An
uncached session took about three minutes from VM boot to ready.

Two earlier sessions had not shown it. The session started at 23:28Z on
2026-10-06 (VM booted 23:28:14Z) ran the setup script again (log 23:30:08Z to
23:30:56Z, 48 s), after an environment-variable edit. The session started at 04:34:53Z on 2026-10-07 also ran it (log
04:35:09Z to 04:36:08Z, 59 s), with no edit to the environment's variables,
script or network level in between. Why that one re-ran is not established.

**The cache after a script change (observed 2026-10-07, the same day).** After
the setup script was changed to the unchanged recipe at `v5.2.1`, the first
session ran the script and cloned the repository (cloned 20:07:37 to 20:07:40Z).
The next session was ready about 4.5 s after it was created: the VM booted at
20:18:06Z, the environment manager started in resume-cached mode, the repository
was updated to the latest commit at 20:18:10Z, and the session's branch was
checked out at 20:18:11.6Z. An uncached session took about three minutes (above).
So a cached start resumes an existing checkout and fetches it forward rather
than cloning again; that the checkout is stored in the setup-script snapshot
is the likely reading, not something these timestamps show. What that means for where
per-checkout preparation runs is an open design question,
[#1548](https://github.com/evanharmon1/harmon-init/issues/1548) (see [When
per-checkout preparation runs](#when-per-checkout-preparation-runs)).

### Network

Choose **Trusted** (the platform default). The bootstrap's
[allowed hosts](../architecture/remote-environments.md#the-network-the-bootstrap-may-use)
were probed on 2026-09-27 and every one of them is on the platform's Trusted list
(*docs, 2026-09-29*) except `cdn.playwright.dev`, which only the opt-in browsers
tier contacts and which this guide does not enable. `ports.ubuntu.com` is the
arm64 archive; the cloud VM is x86-64, so it is never contacted, and `*.ubuntu.com`
is on the list anyway.

**Added domains: none**, for sessions that end at a pushed branch, which is what
a cloud lane does ([What runs where](#what-runs-where)). That list is
provisional, and it is empty on purpose: the rule is that a domain is added only
after a *recorded denial* under Trusted while the bootstrap, `task verify`, or —
in a session that runs the pre-PR gate itself — `task security` ran. The PR is
opened by the orchestrator as a draft after that gate ([What runs where](#what-runs-where)),
so a lane does not normally run it. The denials recorded so far, and the
one that a session running the gate itself needs:

| Host | Denied for | Added? | Reason |
| --- | --- | --- | --- |
| `semgrep.dev` | `task security`'s Semgrep step — observed 2026-09-27, under a network level presumed, but not recorded, to be Trusted | **Only where the session runs the pre-PR gate itself**, which makes the level **Custom** | `task security` must pass before the draft PR (`AGENTS.md`), and this host is what its Semgrep step needs. A lane that stops at a pushed branch leaves the gate to the machine that opens the PR — see [Long-running gates](#long-running-gates). Never skip the gate instead |
| `api.openai.com`, `auth.openai.com`, `chatgpt.com` | the Codex CLI (#1406) | No | Ephemeral clouds never hold a Codex login (#1408 decision 4): the orchestrator reviews the lane's pushed branch from its own pane, and the lane's PR records it (`AGENTS.md` § Remote environments) |
| `deb.nodesource.com`, `astral.sh`, `keybase.io`, `ppa.launchpadcontent.net`, `cli.github.com`, `dl.google.com` | installer hosts (#1403) | No | The bootstrap no longer contacts them; the denied table in the architecture document is guarded so they cannot return |
| `cafe.github.com` | `gh` telemetry | No | Harmless |
| `cdn.playwright.dev` | Playwright Chromium | No | Browsers tier only, off by default; not on the Trusted list |

The session that recorded these denials did not record which network level it
ran under; it is presumed to be the default, Trusted.

**Observed (criterion 8), 2026-10-06, Claude Code 2.1.292, network Trusted:**
the bootstrap, with the interim `sudo env …` line, completed, and `task verify`
completed with `GATE-EXIT=0`, run detached in the form under [Long-running
gates](#long-running-gates). A case-insensitive scan of the verify log for
`403|denied|blocked|Could not resolve|Connection refused|CONNECT|proxy|certificate|UnknownIssuer|ENOTFOUND|ECONNREFUSED`
found no network denial; the only hits were test names. No domain had to be
added for the bootstrap and `task verify`, so the table above stands unchanged.
`task security` was not run in that session, so the `semgrep.dev` row still
rests on the 2026-09-27 observation. Two things the docs say could have
failed, and what was seen:

- *Release-asset scope.* The GitHub proxy limits "GitHub API and release-asset
  requests" to repositories attached to the session, and says a setup script
  downloading release assets from an unattached repository gets a 403 (*docs,
  2026-09-29*). **Observed 2026-10-06 under Trusted: the downloads from
  repositories not attached to the session succeeded** — go-task, cli/cli,
  gitleaks, lychee, shfmt, actionlint, hadolint, yq, lefthook and uv — and the
  bootstrap installed all of them. The documented 403 did not apply to the
  setup script, so the shared-script contract needs no decision.
- *Custom instead of Trusted.* The list is per environment and there is no
  organization-wide allowlist (*docs, 2026-09-29*); if a domain does have to be
  added, the level becomes **Custom** with **Also include default list of common
  package managers** checked.

Other levels: **None** breaks every install, and **Full** gives up the
allowlist the platform's proxy audit trail is meant to give you.

### Environment variables

The environment needs none for the bootstrap, and it holds no secret: every
variable, and the setup script, is readable by anyone who uses the environment
(*docs, 2026-09-29*).

| Variable | Value | Why | Status |
| --- | --- | --- | --- |
| `LANG` | `C.UTF-8` | The VM's locale is POSIX (observed 2026-09-27). The bootstrap fixes `/etc/environment` and login shells, but a process Claude Code launches may read neither, and a non-UTF-8 locale silently changes what Unicode checks accept | value observed present in the session, 2026-10-06 |
| `BASH_DEFAULT_TIMEOUT_MS` | `600000` | The Bash tool waits two minutes by default; the platform documents these two variables for raising it | value observed present, 2026-10-06; whether the ten-minute wait is honoured was not exercised (the long gate ran detached) |
| `BASH_MAX_TIMEOUT_MS` | `600000` | The documented ceiling is ten minutes; whether a larger value is honoured has not been tried, so this guide does not ask for one | value observed present, 2026-10-06; the ceiling was not exercised |

**Enter each variable on its own line, and check what the session saw.**
Observed 2026-10-06: on the first save, the three variables were entered on
separate lines, but the session saw `BASH_DEFAULT_TIMEOUT_MS` holding
`600000 BASH_MAX_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS` unset. After
deleting the variables and **retyping** them one per line, the session saw all
three exactly. Check in a new session:

```bash
env | grep -E '^(LANG|BASH_DEFAULT_TIMEOUT_MS|BASH_MAX_TIMEOUT_MS)=' | cat -vet
```

Each line must end in `$` straight after its value, with nothing else on it.

Do **not** set `GH_TOKEN` or `GITHUB_TOKEN`. With neither set, both read as the
placeholder `proxy-injected` and the proxy substitutes the real credential on
GitHub requests; a token you set is passed through as a plain variable, is
visible to everyone who uses the environment, and does not lift the proxy's
GraphQL restriction (*docs, 2026-09-29*). A script that reads `GITHUB_TOKEN`
directly, rather than letting `gh` do it, gets the placeholder.

## Identity and secrets

The policy, in order of precedence:

1. **No 1Password, and no other credential store.** The bootstrap never installs
   `op`, and a shared remote VM must not hold a credential-bearing tool. Nothing
   in a cloud session writes to a password manager.
2. **GitHub goes through the platform's connection, and nothing else.** The
   credential stays encrypted on the platform's servers and never enters the VM;
   the git client holds a scoped credential the proxy swaps for the real token
   (*docs, 2026-09-29*).
3. **Any other credential an unattended run needs is an API credential where the
   platform has them, else an environment variable.** API credentials are Pro and
   Max only: an admin-role user adds a key and the list of hosts it applies to
   from an *existing* environment's editor, and the agent proxy attaches it to
   requests to those hosts after they leave the VM, so the key never reaches the
   session. The proxy never attaches one to GitHub, the Anthropic API, or the
   public package registries, or to setup-script requests (*docs, 2026-09-29*).
   On Team and Enterprise there is no API credential yet, so the only place is an
   environment variable, **which every user of the environment can read**. No
   step of the dev loop needs one today; add one only for a documented reason and
   say in the table above which visibility applies.
4. **The session itself needs no token from you.** It is authenticated by the
   platform. The agent-posture decisions ([#1408](https://github.com/evanharmon1/harmon-init/issues/1408))
   keep `ANTHROPIC_API_KEY` out and admit no Codex login to an ephemeral cloud.

### Whose identity GitHub sees

Cloud sessions act as the bot account, `evanharmon1-bot`, through **one classic
personal access token** with the `repo` scope and **no** `workflow` scope,
handed to the platform by running `/web-setup`, with the account's GitHub
connection to the Claude GitHub App removed. That is the documented route. It is
what #1408 decision 3 decided on 2026-09-27, and it was proven on 2026-10-07 on
`evanharmon1/harmon-init` and on `ponderousdev/foreman`. It is one token because
`/web-setup` holds a single token across both owners (evanharmon1 and
ponderousdev); what the bot may touch is bounded by its per-repo collaborator
grants, as in [bot-account.md](bot-account.md). A classic `repo` token reaches
every repository the bot can, so the limit is the grants, not a
selected-repository list. Beyond the missing `workflow` scope, which refuses
pushes that create or change a workflow file, the token does not limit what
`gh` may write: the agent posture's denies and the proxy refused the `gh` write
forms tried, but the denies match argument patterns, so they are defence in depth (bundled short
flags are untested,
[#1549](https://github.com/evanharmon1/harmon-init/issues/1549)), and the
boundary is the bot's grants and the rulesets. The operator's own token was the
planned fallback if the platform refused a token whose GitHub user differs from
the claude.ai account; it was not needed (the platform accepted the bot's token,
2026-10-07). An alternative, with a real cost, is [authorizing the App as the
bot](#the-alternative-authorize-the-app-as-the-bot). The token's own lifecycle
(expiry, rotation, revocation) is in [bot-account.md](bot-account.md).

**The account pitfall.** `/web-setup` stores the token on, and `claude --cloud`
creates the session under, **whichever claude.ai account the local CLI is
signed in to**. That is not necessarily the account you are looking at in the
browser. Check it before either command: `/status` inside Claude Code, or
`claude auth status` in a shell. On 2026-10-06 and 2026-10-07, two `/web-setup`
runs were made from a CLI signed in to a different account than the one the
cloud sessions ran under, so the token was stored on the other account and the
sessions kept acting as the operator (`gh api user` returned `evanharmon1`, with
`admin: true` on `evanharmon1/harmon-init` and `ponderousdev/foreman`). That was
first misread as an App authorization overriding the `/web-setup` token; it was
not. With both on the **same** account — the PAT stored by `/web-setup` first,
then the App connection added from the connectors page, both as the bot —
git pushes still went out on the PAT: a workflow-file push was refused with the
same `refusing to allow a Personal Access Token … without workflow scope`
error, and an ordinary push succeeded as `evanharmon1-bot` (observed
2026-10-07). So adding an App connection as the bot afterwards did not reopen
workflow pushes; adding one as the operator was not tried. Because both credentials were the bot, which one served the
session's API calls is not distinguishable, and the reverse order (App first,
then `/web-setup`) is not observed.

**The procedure** (observed 2026-10-07, on the main account, Claude Code
2.1.292, on both owners):

1. At [claude.ai/customize/connectors](https://claude.ai/customize/connectors),
   disconnect GitHub.
2. Start the local CLI with the bot's classic PAT (scope `repo`, no `workflow`)
   in `GH_TOKEN`, **read from your secret store by command substitution, never
   typed**, and run `/web-setup`:

   ```bash
   (
     t="$(<your secret store's read command>)" && [ -n "$t" ] \
       && d="$(mktemp -d)" && [ -n "$d" ] || exit 1
     trap 'cd / && rm -rf -- "$d"' EXIT
     cd "$d" && GH_TOKEN="$t" claude
   )
   ```

   It **fails closed**: if the read fails or returns nothing, or `mktemp` fails,
   the subshell exits before `claude` starts. Without that, an empty `GH_TOKEN`
   makes `gh` — and so `/web-setup` — fall back to your own stored login, which
   would become the cloud identity. The subshell keeps the token out of your
   interactive shell and leaves that shell where it was, and its `EXIT` trap
   removes the empty directory when `claude` exits. Start from an **empty
   directory**, as above, never from
   a repository checkout: that `claude` process holds the token in its
   environment, and a checkout's own Claude Code settings (hooks, MCP servers,
   allowed commands) would run inside it and could read it. If `/web-setup`
   reports anything other than `Connected as evanharmon1-bot`, disconnect
   GitHub at the connectors page before starting any session, then repeat this
   step.

   Mint the token with an expiry (180 days at most, as for the agent PAT), and
   rotate it by minting a new one and re-running `/web-setup`. Never paste a
   token on a command line: it lands in shell history. The token
   goes to this one `claude` process through `GH_TOKEN`, not into `gh`'s store,
   because `gh auth login --with-token` refuses a `repo`-only classic token
   (`error validating token: missing required scope 'read:org'`). `/web-setup`
   warns "Your GitHub CLI token doesn't have the workflow scope. Without it,
   GitHub rejects pushes that change GitHub Actions workflow files, and pushes
   to very large repositories can be rejected while GitHub checks for them."
   Continue past it: that is the boundary this route is for. Expect `Connected as
   evanharmon1-bot`.
3. `/exit`. The browser may then show "Two steps to work in your repository —
   Connect your GitHub account / Install the Claude GitHub App". It is not
   needed for this route; skip it.
4. Start a new session, have it run `task setup:remote` first (`AGENTS.md`
   requires that on any fresh checkout; it installs the git hooks), and verify the
   identity, for one repository of each owner (start a ponderousdev session
   from the browser, see [Bridges](#bridges-between-the-terminal-and-the-cloud)):
   `gh api user` must return `evanharmon1-bot`, and `gh api repos/{owner}/{repo}`
   must show a `permissions` object of `push: true, admin: false, maintain:
   false` — the write role, without admin or maintain. Do not trust `gh auth
   status` for this: see [the `gh` call inventory](#the-gh-call-inventory).
5. Verify the boundary itself, because the App-as-bot route below returns the
   same identity and permissions: in that session, on a throwaway branch,
   append a comment line to `.github/workflows/remote-bootstrap.yml`, commit,
   and push the branch. GitHub must refuse it with `refusing to allow a
   Personal Access Token to create or update workflow … without workflow
   scope`. That workflow runs only on pull requests and on pushes to `main`, so
   the branch push starts nothing even if it is accepted. If it is accepted,
   the session is on an App connection, or on a token minted **with** the
   `workflow` scope (step 2's missing-scope warning not appearing is the early
   sign of the second). Delete the branch from a local checkout (the session
   cannot — the proxy rejects branch deletions, *docs, 2026-09-29*), open no
   pull request from it, and redo this procedure; in the second case, re-mint
   the token without `workflow` first.

**Observed result, 2026-10-07** (session created 16:07:34Z, cloned normally,
platform branch `claude/platform-probe-…`): `gh api user` returned
`evanharmon1-bot`, and `permissions` on `evanharmon1/harmon-init` were
`push: true, admin: false, maintain: false` (the write role, without admin or
maintain). An ordinary branch push succeeded,
and GitHub's activity log shows the pusher as `evanharmon1-bot`. A commit that
edits `.github/workflows/remote-bootstrap.yml` was **refused by GitHub**:

```text
! [remote rejected] … (refusing to allow a Personal Access Token to create or update workflow `.github/workflows/remote-bootstrap.yml` without `workflow` scope)
```

There was no permission prompt or block in the session. So on this route the
2026-09-27 property holds: a cloud session cannot push workflow changes (the App
alternative below can). Route a change that touches workflows to a local lane
run as the operator; the bot's own tokens have no Workflows permission either.
The boundary is narrow: the `workflow` scope blocks edits under
`.github/workflows/` only. A same-repository PR from a session's branch still
runs the repository's existing `pull_request` workflows on that branch's code,
as every bot PR does, so this route brings the web in line with the bot
devcontainer rather than beyond it.

**The same on a ponderousdev repository** (observed 2026-10-07, about 18:29Z, a
session started from the browser on `ponderousdev/foreman`): `origin` was
`https://github.com/ponderousdev/foreman`, `gh api user` returned
`evanharmon1-bot`, and `permissions` were `admin: false, maintain: false,
push: true` (the write role). An ordinary push landed (`d4786c6`, pusher
`evanharmon1-bot`), and a commit editing `.github/workflows/snyk-scheduled.yml`
was refused:

```text
! [remote rejected] ccweb-probe-foreman-wf -> ccweb-probe-foreman-wf (refusing to allow a Personal Access Token to create or update workflow .github/workflows/snyk-scheduled.yml without workflow scope)
```

**With no GitHub connection at all, a session cannot push.** Observed
2026-10-07, with the App connection removed and no `/web-setup` token on the
account: a session reported `gh: No linked GitHub account. Connect your GitHub
account at https://claude.ai/customize/connectors… (HTTP 403)`, and
`claude --cloud` **uploaded a bundle of the local checkout** instead of cloning
it (no `origin`, a `worktree/<name>` branch), so nothing could be pushed. That
is the docs' "send local repositories without GitHub" path.

**Authorship.** Observed 2026-10-07: the VM's git identity is
`user.name = Claude` and `user.email = noreply@anthropic.com`, which GitHub links
to its `claude` user, so commits are authored and committed as Claude. GitHub's
activity log records the push actor as `evanharmon1-bot`, and, on an earlier
probe branch (`ccweb-probe-2026-10-07b`, since deleted), the branch creation as
well. A PR opened through a session's built-in GitHub tools is authored by the
bot too (observed 2026-10-07, [What runs where](#what-runs-where)). The comment
replies the platform posts on your behalf are posted under the connected
account's username and labelled as coming from Claude Code (*docs,
2026-09-29*).

#### The alternative: authorize the App as the bot

Observed 2026-10-07, on the same main account: disconnect GitHub at the
connectors page, then connect it again while github.com is signed in as
`evanharmon1-bot`. The page reported "Connected to GitHub". New sessions then
reported `gh api user` → `evanharmon1-bot`, and the permissions on
`evanharmon1/harmon-init` and, after attaching it to the session,
`ponderousdev/foreman` were `push: true, admin: false, maintain: false` —
exactly the bot's collaborator and member grants. Authorship was as above.

It costs:

- **A session can push workflow files.** Observed 2026-10-07: a session pushed a
  commit that edits `.github/workflows/remote-bootstrap.yml`, and GitHub
  accepted it. The Claude GitHub App's installation permissions, seen on GitHub
  on 2026-10-07, include read and write access to workflows, which is why. By
  GitHub's documented behaviour, a workflow pushed to a branch
  of the same repository runs on that repository's `push` and `pull_request`
  triggers **with the repository's Actions secrets before any review**. That is
  the escalation [branch-protection.md](../architecture/branch-protection.md)
  names as the reason the bot never gets Workflows. This is documented
  behaviour, not an observation: no secret-reading workflow was run. By
  inference from how App permissions work, an App connection as the operator has
  the same property; that is expected, not observed. A required review and
  checks before `main` do not stop it, because the run comes first.
- Linking the organizations `sommerlawn`, `harmonops` and `ponderousdev` failed
  ("You need to be an owner of this organization on GitHub to link it"), because
  the bot is not an owner.
- "A few features, like automatic code review, aren't available for those
  repositories": Anthropic's automatic code review is unavailable on the
  `evanharmon1`-owned repositories, which the bot does not own.

The auto-fix and project-thread features depend on the App's *installation*,
which the docs say disconnecting the user connection does not change. That was
not exercised in the walkthrough, so it is not observed.

**To switch routes**, disconnect GitHub at the connectors page, then connect the
other way: the procedure above for the PAT, or a reconnect with github.com
signed in as the bot (or as the operator) for the App. The docs say
disconnecting deletes every GitHub credential cloud sessions use, a `/web-setup`
token included (*docs, 2026-09-29*); that it removes a stored PAT was not
observed, and a PAT left in place would keep governing pushes (above).

## What the GitHub proxy does to the loop

Every GitHub operation from an Anthropic-hosted VM goes through a proxy,
whatever the network level (*docs, 2026-09-29*). It is the single biggest
difference from the devcontainer, and the docs and the 2026-09-27 session
disagree in places. Where they do, this is the guide's position:

| Topic | Docs, 2026-09-29 | Observed 2026-09-27 | Position |
| --- | --- | --- | --- |
| GraphQL | The proxy serves "a pinned set of GraphQL operations for pull-request workflows" and 403s everything else with `This GraphQL query is not enabled for this session`; a `GH_TOKEN` you set gets the same 403 | **Every** GraphQL request refused, with `GitHub GraphQL is not available from Claude Code sessions; use the REST API` | Treat every GraphQL-backed `gh` subcommand as failing until a live session shows otherwise. The pinned set may have changed since 2026-09-27, or the operations tried were outside it. Projects v2 is GraphQL-only and documented as unreachable |
| The failure looks like | a 403 naming the REST fallback `gh api repos/{owner}/{repo}/…` | a 403 that can read as an auth problem | A 403 from `gh pr …`, `gh issue …` or `gh label …` is the proxy, not a bad token; do not re-authenticate |
| Pushes | `git push` works only against "the session's current working branch" | The assigned branch, **and** four new `claude/*` branches pushed successfully | Plan on the session's branch. The platform assigns each session a `claude/<slug>` branch, and that assignment is not enforced: pushes to other branch names were accepted in the 2026-09-27 session (`claude/*`) and in three sessions on 2026-10-07. The docs do not promise it; do not depend on it without re-checking |
| Repository scope | API and release-asset requests reach only repositories attached to the session | Release-asset downloads allowed; repository not named | API access is scoped per session: a read of a repository not attached returns `HTTP 403: GitHub access to this repository is not enabled for this session.` (observed 2026-10-06). Attaching it in the session (the agent's `add_repo`, access `push`) fixes that, and the platform then shallow-clones it to `/home/user/<repo>`. In an unattended `claude --cloud` session the attach was refused by the auto-mode classifier (`Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Permission Grant]`) and the 403 stood; in the maintainer's interactive browser session the same attach worked (2026-10-07). So the per-session scope does not limit the agent here: a session can attach, when a human approves, any repository the bot can push to. Release-asset downloads from unattached repositories succeeded for the setup script under Trusted (observed 2026-10-06; see [Network](#network)) |
| Search | not stated | `gh api search/issues` 403 `sessions are bound to their configured repositories` | Page through `repos/{o}/{r}/issues?state=all` |
| Pagination | not stated | `gh api --paginate` returns page 1, then fails on the next-page link with `Numeric-ID repository paths (repositories/{id}/...) are not supported`. Again 2026-10-06: GitHub's `Link: next` uses numeric-ID paths, which the proxy refuses | Loop `&page=N` explicitly; the REST helpers in `scripts/lib/gh-rest.sh` do, and bound the walk |
| Written text | PR bodies get the session URL on its own line; comment replies are labelled as Claude Code | **Every** comment and body write, including an issue-body edit, gets a `Generated by Claude Code` footer appended (again on built-in tool writes, 2026-10-07) | Any exact-match check of a body or comment (a marker line, a tick-criteria round trip) can be broken by it. Compare by containment or prefix, not equality |
| REST routes the proxy adds | not stated | Named in the 403: `GET /repos/{o}/{r}/pulls/{n}/ccr/review_threads`, `POST …/ccr/comments/{id}/resolve` (and `/unresolve`), `PUT\|DELETE …/ccr/auto_merge`, `POST …/ccr/ready_for_review`, `POST …/ccr/convert_to_draft` | These are the REST substitutes for review-thread reads, thread resolution, auto-merge, ready-for-review and convert-to-draft |

Also observed 2026-09-27: `gh api repos/…` (plain REST) and `gh api user` work;
the GitHub MCP tools work and are repository-scoped, and `issue_read` also
returns `closed_by_pull_requests`, which is otherwise the one readiness
condition only GraphQL can read; and GitHub release-asset downloads,
`raw.githubusercontent.com`, npm, PyPI, `proxy.golang.org`, `nodejs.org`,
`archive.ubuntu.com` and `releases.hashicorp.com` were reachable.

### What runs where

A cloud lane completes its **role**, not the PR (#1408, 2026-09-27): a remote
implementer returns its work — a pushed branch — to the orchestrator, and the
orchestrator's normal review and integration loop, run from a machine that has
GraphQL, owns the PR. So the integration-side scripts in the inventory below
(the readiness gate, the Codex cloud-review checker, the lane watcher) are not
expected to run inside the VM at all. They are listed because the acceptance
criterion asks for every call the loop makes, and because a session that is
asked to integrate anyway will hit them.

**Under the agent posture, the `gh` routes tried for PR and issue writes were
refused** (observed 2026-10-07): the proxy refuses GraphQL, so `gh pr create`,
`edit`, `ready` and `comment` fail, and the posture's managed settings deny
`gh api` written with a separate write flag (`-X`, `--method`, `-f`, `-F`,
`--field`, `--raw-field`, `--input`) — a `gh api -i -X POST …/pulls` was
refused. Those denies match argument patterns, so they are defence in depth,
not the write boundary: a bundled short flag such as `gh api -iX POST …` is
expected to match none of them and only the `gh api *` allow rule (untested;
[#1549](https://github.com/evanharmon1/harmon-init/issues/1549)). The boundary
is the bot's collaborator grants and the repository rulesets, as for the bot's
PATs — and that boundary covers merges, not draft promotion or auto-merge. The
proxy offers REST routes for both (`POST …/ccr/ready_for_review`,
`POST …/ccr/convert_to_draft`, `PUT|DELETE …/ccr/auto_merge`, quoted under
[the `gh` call inventory](#the-gh-call-inventory)); a write grant permits them,
and the rulesets gate only the merge. So a session is expected to be able to
mark a draft ready without the readiness gate (that requests review and merges
nothing by itself), and only the repository's own **Allow auto-merge** setting
would stop it enabling auto-merge — off on `evanharmon1/harmon-init` and
`ponderousdev/foreman` (read 2026-10-07). Expected from the routes the proxy
names, not yet observed: no session has called either.
A merge into a protected branch still needs code-owner approval and the
required checks.

**The session's built-in GitHub tools are not covered by the posture** (observed
2026-10-07, about 18:03Z, in a postured session). `mcp__github__create_pull_request`
with `draft: true` opened draft PR #1546 as `evanharmon1-bot`;
`mcp__github__add_issue_comment` commented as the bot; and
`mcp__github__update_pull_request` with `state: closed` closed the PR (not
merged). There was no prompt and no block. The server appended a `Generated by
Claude Code` footer to the body and to the comment, and the platform subscribed
the session to the PR's activity automatically and unsubscribed it on close. So
the posture's denies refused the `gh` write forms tried but do not reach these
tools, and a session can technically open a draft PR itself. The denies are
defence in depth, not the write boundary (see above): the boundary is the bot's
grants and the rulesets.

**The lifecycle does not change.** A cloud lane ends at a pushed branch. The
orchestrator's order is `task security`, then open the draft PR and verify it,
then the integration stage and its readiness gate, then promote (`AGENTS.md`
§ Policy invariants, draft-first). Those gates are the orchestrator's, and a
draft a session opens with its built-in tools skips them. The platform's **Create PR** button is not
an alternative to that lifecycle, and what it does about drafts is not
recorded.

### The `gh` call inventory

One row per call the dev-loop skills and scripts make, found by searching the
vendored `claim`, `implement`, `review`, `integrate`, `track-work`, `orchestrate`
and `dev-flow-support` skills (harmon-devkit `v0.47.0`, with the `settle-wait.sh` row added at `v0.51.0`, the pin now) and their `assets/` for
`gh` subcommands. **Result** is the
evidence tag from [the table at the top](#how-to-read-the-evidence-in-this-guide),
never a guess. **Follow-up** names where a failure is tracked or the workaround
that exists today.

Most vendored scripts abort at their first failing call, so their later calls
are not reached through the proxy until that one works; a few tolerate a failed
read and carry on (`release-claim.sh`'s paginated comments read, for one). The
live observation therefore records, for each script, every call the run
actually reached and its result — a GraphQL refusal, or a paginated REST read
that fails after page 1 — and marks a call unobserved only when an earlier
failure aborted the script before it. Making every helper reach its later calls
is harmon-devkit#1207's work, not a gap in this table. Where a script has more
than one row, each row's **Result** records the calls that row names.

The rows tagged *observed 2026-10-06* were run by hand in one session with the
bootstrap's posture. Every GraphQL-backed `gh` subcommand got the same 403,
quoted here once and referred to below as *the GraphQL 403*:

> `HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the
> REST API (gh api repos/{owner}/{repo}/...). For review threads, auto-merge,
> and draft/ready-for-review use the CCR routes on api.github.com: GET
> /repos/{owner}/{repo}/pulls/{n}/ccr/review_threads, POST
> /repos/{owner}/{repo}/pulls/{n}/ccr/comments/{comment_id}/resolve (or
> /unresolve), PUT or DELETE /repos/{owner}/{repo}/pulls/{n}/ccr/auto_merge,
> POST /repos/{owner}/{repo}/pulls/{n}/ccr/ready_for_review, POST
> /repos/{owner}/{repo}/pulls/{n}/ccr/convert_to_draft.`

| Call | Made by | Result through the proxy | Follow-up / workaround |
| --- | --- | --- | --- |
| `gh pr list`, `gh pr view`, `gh pr checks`, `gh pr ready`, `gh issue view`, `gh issue edit`, `gh issue comment`, `gh label list` | any of the scripts below, or by hand | **fail, 403** — observed 2026-09-27; `gh issue view`, `gh pr list`, `gh pr view`, `gh pr checks` and `gh label list` again 2026-10-06 (the GraphQL 403) | `gh api repos/{o}/{r}/…` over REST for reads; the REST writes and `POST …/ccr/ready_for_review` written with a separate write flag are denied under the agent posture, and those denies are defence in depth, not the boundary (see above; bundled flags untested, #1549), so the lifecycle uses them only outside a postured session. The helper scripts: [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207) |
| `claim-transaction.sh` (`/claim`): `gh issue view/edit/comment`, `gh api user`, `gh api --paginate --slurp` | claim skill (vendored) | **fail** on the GraphQL issue calls — observed 2026-09-27. The script aborts at its first `gh issue view`, so its paginated `comments` and `timeline` reads (page 1 expected to work, later pages to fail) are not reached | harmon-devkit#1207. The 2026-09-27 session used a session-local `gh` shim mapping the subcommands to REST — a stopgap, not a fix |
| `tick-criteria-core.sh`: `gh issue view`, `gh issue edit`, `gh api user` | track-work skill (vendored) | **fail** — observed 2026-09-27 | harmon-devkit#1207. The write also gets the footer (above) |
| `check-closing-keywords.sh` (the vendored copy): `gh issue view`, `gh pr view`; `gh repo view` when no `--repo` or `GH_REPO` is given | track-work skill (vendored) | **fail** — observed 2026-09-27; the `gh repo view` fallback expected to fail, not yet observed (GraphQL-backed) | harmon-devkit#1207. Pass `--repo` so the fallback never runs |
| `gh pr create --draft`, then `gh pr view --json headRefOid,isDraft` to confirm it | implement skill (vendored), the draft-first step `AGENTS.md` requires; the orchestrate skill's lane brief | **not reachable under the posture** — `gh pr create` is GraphQL-backed and fails, and the REST `POST …/pulls` was refused 2026-10-07: `Permission to use Bash with command … gh api -i -X POST repos/evanharmon1/harmon-init/pulls … has been denied.` | The built-in GitHub create-PR tool opened a draft under the posture (`draft: true`, draft PR #1546 as the bot, observed 2026-10-07; [What runs where](#what-runs-where)). harmon-devkit#1207. A cloud lane still leaves the PR to the orchestrator, after its gates |
| `gh pr edit --body-file` (ticking `## Deferred findings`, and `render-dev-flow.mjs publish`, which then re-reads the body with `gh pr view`) | integrate skill; dev-flow-support package (vendored) | expected to fail, not yet observed — GraphQL-backed; under the posture `gh pr edit` fails, and the REST `PATCH` is denied as a `gh api` write form (observed 2026-10-07 for the REST `POST …/pulls`) | REST `PATCH repos/{o}/{r}/pulls/{n}` with `body` is not reachable from a postured session, and `mcp__github__update_pull_request` is not covered by the posture (observed 2026-10-07, closing a PR); the orchestrator edits the body. `publish` also compares the re-read body's fingerprint with what it wrote, which the footer (below) would break — expected, not yet observed. harmon-devkit#1207 |
| `gh repo view <remote-url> --json nameWithOwner` | implement and review skills (vendored), resolving the target repository; the claim skill's entry gate | **fail, 403** (the GraphQL 403) — observed 2026-10-06 | Derive `owner/repo` from `git remote get-url`, or read it from REST `repos/{o}/{r}` (plain REST works — observed 2026-09-27). harmon-devkit#1207 |
| `gh issue list`, `gh issue create`, `gh issue close` | track-work skill (duplicate search, filing and closing issues); integrate skill (filing follow-ups); claim skill (open-issue scan) | `gh issue list`: **fail, 403** (the GraphQL 403) — observed 2026-10-06. `gh issue create` and `gh issue close`: expected to fail, not yet observed — GraphQL-backed, like the `gh issue` calls in the first row | REST `repos/{o}/{r}/issues`: `GET` with `state=all`, paged (see Search, above); `POST` to create; `PATCH` with `state` and `state_reason` to close — the two writes denied under the agent posture (see above). harmon-devkit#1207 |
| `gh run list --commit`, `gh run view --log-failed`, `gh run rerun --failed` | integrate skill (vendored), CI remediation | `gh run list`: **works** (REST Actions) — observed 2026-10-06. `gh run view --log-failed` and `gh run rerun --failed`: expected, not yet observed — they use the same REST Actions API | — |
| `trusted-registry.sh`: `gh pr view --json baseRefOid`, `gh api repos/…/contents` | integrate skill (vendored), sourced by `check-codex-cloud-review.sh` and `gh-write-broker.sh` | expected to fail on `gh pr view`, not yet observed — GraphQL-backed; the `contents` read is plain REST | REST `repos/{o}/{r}/pulls/{n}` returns `base.sha`. harmon-devkit#1207 |
| `gh auth git-credential` (the forced credential-helper push in `AGENTS.md` and the integrate skill) | a push on an unprovisioned host | expected, not yet observed; not needed — a plain `git push` to the session's branch works (observed 2026-09-27), because the platform configures git itself | Push with plain `git push` in a cloud session |
| `release-claim.sh`, `check-issue-metadata.sh`: `gh issue edit/comment`, `gh label list`, `gh api --paginate --slurp` | track-work skill (vendored) | expected, not yet observed — the same GraphQL-backed subcommands as the first row | harmon-devkit#1207 |
| `release-claim.sh`: `gh api repos/{o}/{r}/issues/{n}` (the issue, read twice), and `gh api --paginate --slurp` over the issue's `timeline` and `comments` | track-work skill (vendored) | expected to work for the plain issue reads, and for page 1 of the paginated reads, which then fail on the proxy's rejected next-page link; not yet observed. Record which read failed before the script reaches its GraphQL writes | harmon-devkit#1207 (explicit `page=N` pagination) |
| `check-issue-metadata.sh`: `gh api repos/{o}/{r}` (owner type) and, for an organization owner only, `gh api orgs/{owner}/issue-types` | track-work skill (vendored) | expected to work (plain REST), not yet observed; the organization call is skipped for a personal-account owner | — |
| `set-issue-status.sh`: `gh api graphql` (Projects v2) | track-work skill (vendored) | expected to fail, not yet observed — Projects v2 is GraphQL-only and documented as unreachable. A direct `gh api graphql …` probe was not reached 2026-10-06: the session's auto-mode classifier blocked it before it ran | No REST route is known. The skills treat Project status as a non-authoritative view, so the loop does not need it. Tracked in [harmon-devkit#1207](https://github.com/evanharmon1/harmon-devkit/issues/1207), which either finds a REST route or makes the helper refuse with its exit 2; until then it can only fail behind the proxy |
| `readiness-gate.sh`: `gh pr view`, `gh api graphql --paginate --slurp` (review threads), `gh api repos/…`, `gh api user`, `gh pr ready` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27 | Conditions were checked by hand over REST (`…/ccr/review_threads`, `…/ccr/ready_for_review`). harmon-devkit#1207; orchestrator-side, see [What runs where](#what-runs-where) |
| `check-codex-cloud-review.sh`: `gh pr view`, `gh api --paginate --slurp` | integrate skill (vendored) | **fail** on `gh pr view` — observed 2026-09-27; the pagination fails past page 1 — observed 2026-09-27 | The current-head cycle was checked by hand over REST. harmon-devkit#1207 |
| `gh-ro.sh`, `gh-write-broker.sh`: `gh api` with a pinned method | integrate skill (vendored) | plain REST reads and writes work — observed 2026-09-27 for `gh api repos/…`, before the agent posture existed; under the posture the write forms are denied (see above); these two wrappers themselves not yet observed | GET refuses `graphql` by design |
| `round-push.sh`: `gh api --hostname …` | review skill (vendored) | expected, not yet observed | — |
| `lane-watch.sh`: `gh pr list`, `gh api --paginate --slurp`, `gh pr ready --undo` | orchestrate skill (vendored) | expected to fail, not yet observed — GraphQL-backed subcommands | Orchestrator-side; not run in a cloud lane |
| `settle-wait.sh`: `gh api repos/{o}/{r}/pulls/{n}`, `gh api repos/{o}/{r}/actions/runs?head_sha=…&per_page=…&page=…` (its own explicit paging) and `gh api repos/{o}/{r}/actions/runs/{id}` | orchestrate skill (vendored) | expected to work, not yet observed — plain REST reads with explicit `page=N`, which the proxy serves (the Actions runs list worked, observed 2026-10-06) | Orchestrator-side; not run in a cloud lane |
| `scripts/status.sh`, `scripts/check-closing-keywords.sh`, `scripts/guard-closing-keywords.sh`, `scripts/audit-session-artifacts.sh` | harmon-init's own | **REST since #1430** for the calls that go through the bounded `gh_rest_*` helpers, with a page ceiling. `status.sh` also makes the calls in the next row, which do not | `task status` itself has not been run in a cloud session; the next row records its `gh` calls individually. A script that probes `gh auth status` reports `gh` as broken there |
| `status.sh` outside the `gh_rest_*` helpers: `gh auth status`, `gh run list`; raw `gh api` for `repos/{o}/{r}`, `…/rulesets`, `…/vulnerability-alerts`, `…/private-vulnerability-reporting`, the app installations (`orgs/{o}/installations` or `user/installations`) and the GHCR package; `gh secret list`, `gh variable list`, `gh variable get`; `gh auth token` | harmon-init's own (`task status`) | `gh auth status`: **exit 1** with `X Failed to log in to github.com using token (GH_TOKEN)` while `gh api` works — a **false negative** (`GH_TOKEN` is the placeholder `proxy-injected`; `GITHUB_TOKEN` is also set) — observed 2026-10-06. `gh run list`: works — observed 2026-10-06. `gh api repos/{o}/{r}`: works — observed 2026-10-06; the other raw `gh api` reads: expected to work (plain REST), not yet observed. `gh variable list`: **fail, 403** `Access to this GitHub Actions path is not permitted through this proxy.` (the Actions variables path is refused although runs are allowed) — observed 2026-10-06. `gh secret list`: not reached 2026-10-06, the auto-mode classifier blocked it; `gh variable get`: expected, not yet observed. `gh auth token`: local, no network call | Probe `gh` with `gh api user`, not `gh auth status`. `status.sh` does not abort on any of these — each call has a fallback. The latest-release read moved off the GraphQL-backed `gh release list` onto `gh_rest_api` (`repos/{o}/{r}/releases?per_page=1`, the row above) in #1437, and a failed read now renders the **Release published** line as unavailable instead of a false *no* with the `task release:init` remedy |
| `task foreman:plan`, `foreman:dispatch`, `foreman:watch` | the pinned Foreman CLI, run through `uvx` from a git URL | expected, not yet observed — the calls Foreman makes are in its own repository, not enumerated here. Dispatch refuses on the local runner for public repos by design | Orchestrator-side; not run in a cloud lane |
| `gh api repos/{o}/{r}/…` (REST), `gh api user`, an explicit `…?per_page=2&page=2` read | anything | **works** — observed 2026-09-27 and 2026-10-06. For a repository not attached to the session: **fail, 403** `GitHub access to this repository is not enabled for this session.` — observed 2026-10-06 | Attach the repository in the session (the agent's `add_repo`, access `push`); an unattended `--cloud` session's attach was refused by the auto-mode classifier (observed 2026-10-07) |
| `gh api search/issues` | ad hoc | **fail, 403** — observed 2026-09-27; not reached 2026-10-06, the auto-mode classifier blocked it before it ran | `repos/{o}/{r}/issues?state=all`, paged |
| `gh api --paginate` | ad hoc | **page 1 only**, then a hard error — observed 2026-09-27 and 2026-10-06: `HTTP 403: Numeric-ID repository paths (repositories/{id}/...) are not supported through this proxy. Use repos/{owner}/{repo}/... endpoints instead.` GitHub's `Link: next` uses numeric-ID paths, which the proxy refuses | Explicit `&page=N` loop |
| GitHub MCP tools (issue and PR read, create PR, subscribe to PR activity) | the session's built-in tools | **work**, repository-scoped — observed 2026-09-27. Under the agent posture they are not blocked either: `mcp__github__create_pull_request` (draft), `add_issue_comment` and `update_pull_request` (closed a PR) all worked as the bot, with the footer appended — observed 2026-10-07 | `issue_read` returns `closed_by_pull_requests` |
| Any comment or body write | any | **succeeds with a footer appended** — observed 2026-09-27 | Compare by containment, not equality |

**Observed (criterion 7), 2026-10-06 and 2026-10-07:** the read half is run
through the proxy in a session with the bootstrap's posture, and the rows above
carry the result. Every failing row has a follow-up or a workaround in its last
column. The write half is observed in part: the `gh` forms tried for PR and
issue writes were refused, the session's built-in GitHub tools are not covered
by the posture ([What runs where](#what-runs-where)), and REST-backed writes
outside the deny list (`gh run rerun`, `gh run cancel`) and bundled-flag
`gh api` writes were not run. The rows still tagged *expected* were not run;
they stay unobserved rather than assumed.

## Bridges between the terminal and the cloud

These need the Claude Code CLI signed in with a **claude.ai account** — not an
API key, and not a Bedrock or Vertex configuration — and the organization's
`allow_remote_sessions` policy on (*docs, 2026-09-29*).

- **Terminal → cloud.** `claude --cloud "<task>"` creates a new cloud session for
  the current repository. With a GitHub connection on the account it clones the
  GitHub remote at your **current branch**, not your local checkout, so **push
  first**; with none, it uploads a bundle of the local checkout instead
  (observed 2026-10-07, below). One repository at a time, in the
  environment chosen by `/remote-env`. The task then runs while you keep working.
  Each invocation is its own session, so several run in parallel, and they share
  your plan's rate limits — there is no separate compute charge.
- **Following up.** `claude -p "<message>" --cloud <session-id>` queues a message
  into a running session and exits without waiting; `--output-format json`
  returns `{ok, session_id, url}`. That is the scriptable steering path.
- **Cloud → terminal.** `claude --teleport [<session-id>]`, `/teleport` inside a
  session, or `/tasks` then `t`, pulls a cloud session's branch and transcript
  into a local checkout of the same repository (not a fork), with a clean
  working tree, authenticated as the same account. The local copy is its own
  session: work you do there does not appear in the cloud session. A local Herdr
  pane can run this command like any other; see
  [herdr.md](herdr.md).
- **Why Herdr cannot attach to the cloud VM.** Herdr attaches to a terminal
  session, and a cloud session does not expose one: "you don't get a shell into
  the session VM; Claude runs every command for you" (*docs, 2026-09-29*). Steering
  goes through the web UI or `claude -p … --cloud <id>`, and the result comes back
  as a pushed branch. Teleporting is the only way to *see* the work in a local pane,
  and it copies the session rather than attaching to it.
- **Not to be confused with** `--remote-control`, which steers a *local* session
  from claude.ai; and `--remote`, the deprecated spelling of `--cloud`.

**Observed (criterion 4), 2026-10-06 and 2026-10-07, local CLI 2.1.284:**
`claude --cloud "<task>"` ran to a pushed branch with no permission prompt and
no human step.

- **It needs a TTY.** With stdout piped it refuses: `Error: --cloud requires an
  interactive terminal. Non-interactive invocations (piped stdout, --init-only,
  --sdk-url) run locally and would silently ignore --cloud.` Run interactively,
  it returns at once, printing `Created cloud session: <title>`, a `View:` URL
  and `Resume with: claude --teleport <session-id>`. This version prints no live
  setup checklist.
- **The account is whichever one the local CLI is signed in to.** The same holds
  for `/web-setup`, which stores its token on that account ([Whose identity
  GitHub sees](#whose-identity-github-sees)). A `--cloud` session is created in
  that account's environment and GitHub connection; a CLI signed in to a second
  account sent the task there, and the browser then reported the session
  "couldn't be found". Check `/status` inside Claude Code, or `claude auth
  status` in a shell, before `/web-setup` or `--cloud`.
- **An account with no GitHub connection uploads the checkout.** Observed
  2026-10-07: with the GitHub connection removed entirely, `claude --cloud`
  uploaded a bundle of the local checkout instead of cloning (no `origin`, a
  `worktree/<name>` branch), so nothing could be pushed.
- **Following up works.** `claude -p "<message>" --cloud <session-id>` queued a
  follow-up (`Sent to cloud session.`).
- **The probe task ran unattended.** The session created at 04:34:53Z on
  2026-10-07 did environment reads, made a new branch, two commits and two
  pushes (`78d2be2`, `81acea1`, the second touching a workflow file, accepted because the account was on the
  App-as-bot route — see [the alternative](#the-alternative-authorize-the-app-as-the-bot)), with no
  permission prompt and no human step. It stopped where the posture denied the
  REST PR create ([What runs where](#what-runs-where)). Criterion 4 is met as
  "returns a pushed branch with no human step".
- **Branch names.** The platform assigns each session its own branch name
  (`claude/platform-probe-2026-10-07-<suffix>`, in general `claude/<slug>`), but
  that is not enforced: pushes to other branch names were accepted in three
  sessions on 2026-10-07.
- **The permission mode** was auto mode, by the session's own context note
  ("auto mode is active"); the session had no tool to report the mode, so it is
  not shown by a tool. The docs say the mode is picked from the session's mode
  dropdown at creation.
- **Start `ponderousdev` sessions from the browser.** Observed 2026-10-07:
  `claude --cloud` from a `ponderousdev/foreman` checkout uploaded a bundle (no
  `origin`) although the Claude GitHub App is installed on that repository (its
  installation on `ponderousdev` selects seven repositories, `foreman` among
  them). The likely cause is that the account's GitHub connection is the bot, for
  which claude.ai's organization linking of `ponderousdev` failed ("You need to
  be an owner of this organization on GitHub to link it"); that is likely, not
  established. A session started from the browser on the same repository cloned
  it normally ([Whose identity GitHub sees](#whose-identity-github-sees)).
- **Git hooks were not installed** in that session, because no `task
  setup:remote` was run there — consistent with [When per-checkout preparation
  runs](#when-per-checkout-preparation-runs).

## The agent posture

The setup script's bootstrap installs the agent posture
([#1408](https://github.com/evanharmon1/harmon-init/issues/1408)) on the VM,
from the same release tag as the toolchain
([architecture](../architecture/remote-environments.md#the-agent-posture)).
What that does and does not establish here:

| Axis | In Claude Code on the web | Status |
| --- | --- | --- |
| Permissions | The bootstrap writes the agent Claude Code settings to `/etc/claude-code/managed-settings.json`, creating the directory, which did not exist on the VM. The refusals observed in a session are consistent with the managed deny rules being enforced (below), but a listing of the rules cannot be had on the web, so this is inferred from behaviour. The platform also supplies its own settings overlay (`CCR_SETTINGS_JSON_OVERLAY`), and a server-side auto-mode classifier approves or denies each action on top of whatever loads — a second refusal layer. If a later platform change ignores the file, the fallback is the repository's `.claude/settings.json`, which a session reads only in a single-repository session, or the platform overlay. Should the platform ever supply its own `/etc/claude-code/managed-settings.json`, the bootstrap leaves it in place and reports the posture as not applied for it, unless the environment's setup script sets `HARMON_AGENT_POSTURE_REPLACE=1` | VM: observed 2026-09-27. Delivery: observed in part, 2026-10-06, Claude Code 2.1.292 (#1404 criterion 2, below) |
| Refused harnesses | Not refused. The bootstrap never changes a harness executable's mode on a platform VM; the platform starts Claude Code and nothing else, and its classifier sits above the session | expected, not yet observed |
| Hooks | Not delivered. The settings name the agent image's hook scripts under `/etc/claude-code/hooks/`, which the bootstrap does not install; it warns naming each one (observed 2026-10-06: it warned that the eight hook commands it names are not installed). A missing hook command is expected to surface as a non-blocking hook error each time the hook fires | warning observed 2026-10-06; the hook error expected, not yet observed |

**Observed in part (#1404 criterion 2), 2026-10-06/07, Claude Code 2.1.292**, in
a session in the environment whose setup script ran the bootstrap. The criterion
asks for a listing of the deny rules, which cannot be done on the web as
worded; the enforcement half is inferred from the refusals:

- The bootstrap installed and verified `/etc/claude-code/managed-settings.json`
  and `/etc/codex/managed_config.toml` on the VM (`==> agent-autonomy: verify
  passed`).
- **The refusals are consistent with the managed deny rules being enforced.**
  `sudo …` was refused ("the session's permission settings blocked"). `gh pr
  merge 1` was refused **without a prompt**; the session attributed it to the
  repository's permission settings, and that repository's `.claude/settings.json`
  has an *ask* rule for `gh pr merge` while the managed file has a *deny* rule,
  so a refusal with no prompt is consistent with the deny. The `gh api` write
  forms were refused too ([What runs where](#what-runs-where)). The refusals
  carried the permission-rule message form ("Permission to use Bash with command
  … has been denied", "the session's permission settings blocked") and came
  without a prompt, unlike the classifier's refusals below.
- **`/permissions` cannot be used on the web.** Typing it opens the session's
  permission-mode menu (Auto, Accept edits, Plan) instead of listing rules, so
  which source refused an action is inferred from behaviour, not shown by a
  listing.
- **The auto-mode classifier is a second, separate refusal layer, and it is not
  consistent across sessions.** It refused to print `$GH_TOKEN` and the proxy
  variables in one session, while an earlier session printed
  `GH_TOKEN=proxy-injected`. It refused reading the managed settings file
  together with environment variable names ("an attempt to get around auto
  mode's restrictions"). It refused `gh api search/issues`, `gh secret list` and
  `gh api graphql` before they ran. It also refused an unattended session's
  attach of a repository with push access ([The GitHub
  proxy](#what-the-github-proxy-does-to-the-loop)). The posture does not cover
  the session's built-in GitHub tools ([What runs where](#what-runs-where)).

## Memory

None of your local memory reaches a cloud session, and none of what the session
writes survives it.

- **Local auto-memory is not loaded.** There is no `~/.claude/CLAUDE.md` in the
  session (*docs, 2026-09-29*), and no auto-memory (observed 2026-09-27).
- **Anything the session writes to memory is lost with the VM.** A session that
  goes idle is reclaimed and reopened on a fresh VM with its conversation
  history, not its files (*docs, 2026-09-29*).
- **Durable lessons therefore belong in the repository**: `AGENTS.md`, or a doc it
  links. The repository's own `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`,
  `.claude/agents/` and `.claude/commands/` are part of the clone and do load
  (*docs, 2026-09-29*), which is why they are the right home. A rule that
  matters to the next session goes in a commit, not in memory.

## Account preferences, account skills, and what does not carry over

The session's `~/.claude` exists but the platform fills it (`plugins/`,
`launcher-settings.json`, `session-env/`), so what reaches a cloud session is:

| Source | In the session? | Note |
| --- | --- | --- |
| Repo `CLAUDE.md`, `.claude/rules/`, skills, agents, commands | yes | part of the clone |
| Repo `.claude/settings.json` (hooks, permissions) and `.mcp.json` | **only in a single-repository session** | a multi-repository session starts above the clones and reads neither (*docs, 2026-09-29*) |
| claude.ai **account skills** | yes | synced in automatically — `CLAUDE_CODE_SYNC_SKILLS` was observed 2026-09-27 |
| claude.ai **account preferences** | yes | injected into the session's instructions (observed 2026-09-27) |
| `~/.claude/CLAUDE.md`, user skills, agents, commands, user-scope MCP servers, user-scope plugins | **no** | they live on your machine (*docs, 2026-09-29*) |
| Plugins a repo enables in `.claude/settings.json` | **no** | a cloud session does not install `enabledPlugins` |
| Organization server-managed settings | yes | fetched at session start; MDM-deployed managed files do not apply |

Account preferences are the only channel for a rule that has to hold in **every**
repo a session might open, including one with no `AGENTS.md` of this shape. Put
there: the small set of cross-project rules that are safety or communication
rules rather than repository facts — never write to a password manager or
credential store unless that exact write was requested, and even then restate
what will be written and get confirmation before running it; never terminate a
process without approval; never merge or cut a release, because both are the
maintainer's decisions and an agent acts on one only with explicit, per-merge
(or per-release) approval; and the reply-style
preferences. Keep them short: they are injected into every session. Everything
that is true of a repository — commands, gates, the dev loop, conventions —
belongs in that repository's `AGENTS.md`, where it is versioned and reviewable.

Copying the rules into account preferences is a step only the operator can do;
nothing in this repository writes to the account.

## Long-running gates

A full `task verify` takes about **10–12 minutes on the 4-core VM** (observed
2026-09-27), which is over the Bash tool's ceiling: it waits two minutes by
default and can be asked for at most ten (*docs, 2026-09-29*). The platform does
not kill a command at that limit; Claude Code moves it to the background instead
(*docs, 2026-09-29*), so the risk is a session that treats "moved to the
background" as "finished". The supported ways to run it:

1. **Detached, then poll the log** — the form this repository's lane briefs use:

   ```bash
   log="$(mktemp -d)/verify.log"
   nohup bash -c 'task verify; echo GATE-EXIT=$?' > "$log" 2>&1 & disown
   echo "$log"
   ```

   then read `$log` (the path the last line printed) until it contains
   `GATE-EXIT=<code>`. The log is per run, so an older detached run's exit line
   cannot satisfy this poll. That line, not the absence of output, is the
   result. The single quotes are load-bearing:
   inside double quotes the *calling* shell expands `$?` before `bash -c` starts,
   so the line would report the status of whatever ran before — and a failed
   verify could print `GATE-EXIT=0`.
2. **Its component tasks**, each under the limit: every entry
   `task --summary verify` lists, in order — `check`, the `audit:*` guard, and
   each `test:*` target. Running a subset is not a verify.
3. **Raise the ceiling** with `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`
   in the environment ([Environment variables](#environment-variables)). This
   only moves the limit to ten minutes; a gate longer than that still needs the
   first form. The variables were observed present on 2026-10-06, but whether
   the ten-minute wait is honoured was not exercised: the long gate ran
   detached, as in the first form, and `task verify` completed with
   `GATE-EXIT=0`.

**`task security` is owed before the draft PR, in the cloud as anywhere else**
(`AGENTS.md`), and it is never skipped. Its Semgrep step contacts `semgrep.dev`,
which was denied on 2026-09-27 under a network level presumed, but not
recorded, to be Trusted (see [Network](#network)). Meet the gate one of two ways:

- **In the session:** add `semgrep.dev` under **Custom** network access, with the
  default package-manager list kept, so the full `task security` runs there.
- **Outside it**, where the environment cannot be changed: the session stops at
  a pushed branch, and the draft PR is opened only after `task security` has
  passed on a machine that can run it. That is already the shape of a cloud lane
  ([What runs where](#what-runs-where)): the orchestrator runs the gate before it
  opens the PR.

`task security:secrets` on its own is the per-push secret scan, not a substitute
for the pre-PR gate.

## Other behaviour worth knowing

- **The platform's Stop hook** (`stop-hook-git-check.sh`) blocks when any linked
  worktree has uncommitted changes, including a subagent's in-progress edits
  (observed 2026-09-27). Commit before finishing.
- **The session runs as root.** Git configuration is injected through
  `GIT_CONFIG_COUNT` (observed 2026-09-27), so do not assume a `~/.gitconfig`.
- **`/usr/bin/yq` is the Python yq.** The bootstrap puts the pinned mikefarah yq
  first on `PATH`; see
  [architecture/remote-environments.md](../architecture/remote-environments.md#what-the-environment-actually-is).
- **One repository per session** if the session should read the repo's
  `.claude/settings.json`, `.mcp.json` and hooks.
- **Resources:** about 4 vCPUs, 16 GB RAM and 30 GB disk (*docs, 2026-09-29*).
- **Session link:** commits carry a `Claude-Session:` trailer and PR bodies carry
  the session URL; `CLAUDE_CODE_REMOTE_SESSION_ID` holds the ID.
- **npm-installed tools resolve from the platform's prefix.** Observed
  2026-10-06: `markdownlint-cli2` and `codex`, which the bootstrap installs with
  npm, resolve from `/opt/node22/bin`, the platform's npm prefix. It precedes
  the bootstrap's prefix on `PATH`, while the bootstrap pinned Node 24.21.0.
  npm prefix handling is tracked by #1429.
- **The setup-script output panel truncates at varying points.** Observed
  2026-10-06: two failing runs appeared to stop at `lychee` and `actionlint`
  while the real failure was later. Debug a failing setup run from a
  timestamped log written with `tee`, not from the panel.

## When per-checkout preparation runs

The setup script provisions the **VM**: the platform snapshots the filesystem
after it, and a session starts from that snapshot without running the script again
until the script or the network hosts change, or the cache expires after about
seven days (*docs, 2026-09-29*). The repository is a **fresh clone per session**
(*docs, 2026-09-29*), and the 2026-09-27 session, which had no setup script,
already had it at `/home/user/harmon-devkit` when it started.

The docs do not say whether that clone exists when the setup script runs.
**Observed (criterion 11), 2026-10-06: the repository is cloned before the setup
script runs** — a probe line in the setup script wrote
`/home/user/harmon-init/.git`. A script served from the cache still cannot
depend on that session's own clone, because the snapshot was taken before it.
A cached start does resume an existing checkout and fetch it forward rather than
clone afresh ([Setup script](#setup-script), observed 2026-10-07), which the
docs' "fresh clone per session" does not describe; where that checkout is kept,
and which run built it, is not established.
Whether the setup script should therefore prepare the checkout is an open design
question, [#1548](https://github.com/evanharmon1/harmon-init/issues/1548). Until
it is decided, the rule that holds:

- **Setup script**: machine-level, repository-independent — the bootstrap, and
  nothing that reads a checkout.
- **Per-checkout preparation** — installing the git hooks, and anything that reads
  the clone — runs when the session starts, not in the setup script. The
  platform's mechanism for that is a `SessionStart` hook in the repository's
  `.claude/settings.json`, guarded on `CLAUDE_CODE_REMOTE=true` so it does nothing
  locally, and it runs only in a single-repository session (*docs, 2026-09-29*).
  This repository has deliberately **not** adopted that hook (its
  `.claude/settings.json` is unchanged), so nothing triggers the preparation by
  itself: the agent runs the task below once.

`task setup:remote` (`scripts/setup-remote.sh`,
[#1405](https://github.com/evanharmon1/harmon-init/issues/1405)) is that
preparation as one task, which the agent runs once on a fresh checkout —
`AGENTS.md` tells it to, because the repository ships no hook that would. It runs `lefthook install` (when
lefthook is on `PATH`), frozen `pnpm` / `uv` installs from the lockfiles that
exist, and the same sibling clones the devcontainer makes
(`.devcontainer/related-repos.txt`), into the checkout's **parent** directory:
the layout observed on 2026-09-27 (`/home/user/<repo>`), so the `../harmon-devkit`
entries in `additionalDirectories` and `sandbox.filesystem.allowRead` resolve. It
is idempotent, never prompts (git terminal prompts are disabled, ssh runs with
`BatchMode=yes` unless the caller already set `GIT_SSH_COMMAND`, in which case the
caller's value governs, and pnpm runs with `CI=true`), skips a missing tool with a note, warns and continues past a
repository it cannot clone, and exits non-zero only when a step that could run
failed. It prints where it cloned, because a platform that does not clone one
level below a writable directory would otherwise show only as a missing sibling.

Siblings are **reference context**: a session may push only to its own repository
and branch (the *Pushes* row above), so a change to a sibling cannot be pushed
from here. The pre-push hook that `lefthook install` sets up is not a substitute
for `task verify`, so run that yourself. Public siblings clone anonymously through the
session's git proxy; a private sibling, or one that needs GitHub API calls, must
be attached to the session (*observed 2026-09-27*,
[evidence on #1405](https://github.com/evanharmon1/harmon-init/issues/1405#issuecomment-5860625784)).
Attaching a repository in the session (the agent's `add_repo`, access `push`) is
a second path to a sibling: the platform itself **shallow-clones** it to
`/home/user/<repo>`, beside the full anonymous clones `task setup:remote` makes
(observed 2026-10-06).
The task's behaviour is tested in a fixture repository
(`scripts/test-setup-remote.sh`).

**Observed (#1405 criterion 6, siblings readable), 2026-10-06:** `task
setup:remote` on the VM exited 0. `lefthook install` synced `commit-msg`,
`pre-push` and `pre-commit`; the three related repositories cloned anonymously
into `/home/user` (`3 cloned, 0 skipped, 0 failed`); the dependency steps were
skipped because the repository has no lockfiles. This was observed on
`evanharmon1/harmon-init`; the criterion names `ponderousdev/omator`, where
siblings readable and `task verify` runnable in a live session are still
**pending**, criterion 6 of #1405.

## Pending observations

The live walkthrough of 2026-10-06 and 2026-10-07 (Claude Code 2.1.292 on the
VM) settled criterion 1 (the bootstrap with the interim line, the cache, and,
on 2026-10-07, the unchanged recipe at `v5.2.1`), 3 in part (identity and pushes
on both owners; a PR through a session was seen only on
`evanharmon1/harmon-init`), 4, 8
and 11, and the read half of 7, of
[#1407](https://github.com/evanharmon1/harmon-init/issues/1407), criterion 2 of
[#1404](https://github.com/evanharmon1/harmon-init/issues/1404) in part (the
agent posture), and the unnumbered row (release-asset downloads from
repositories not attached to the session). **Still open**, marked *Open* in the
table: criterion 6 of
[#1405](https://github.com/evanharmon1/harmon-init/issues/1405) on
`ponderousdev/omator`, a PR through a session on a ponderousdev repository,
which other built-in GitHub tools a session has, the reverse credential order
(an App connection first, then a `/web-setup` token), bundled-flag `gh api`
writes ([#1549](https://github.com/evanharmon1/harmon-init/issues/1549)), the
design question of where per-checkout preparation runs
([#1548](https://github.com/evanharmon1/harmon-init/issues/1548)), and the
listing half of #1404 criterion 2, which cannot be done on the web. The `gh` inventory rows still tagged *expected, not
yet observed* are open too (row 7). A settled row stays as the record of what
was seen and where it landed. Each result goes in the section named, with the
date and the Claude Code version.

| # | What has to be seen | Where the result lands |
| --- | --- | --- |
| 1 | Seen 2026-10-06: `v4.48.0` is the first release carrying the bootstrap; at `v5.2.0` the setup script fails at `semgrep`, and with the interim `sudo env …` line it completes in 86 s (48 s on a second VM). Seen 2026-10-07: the recipe unchanged, with `sudo bash` and no interim `env`, at `v5.2.1` started a session; the manifest reports `harmon-remote-env` at revision `v5.2.1`, `semgrep 1.178.0` and `copier` are at `/usr/local/bin`, `markdownlint-cli2` and `codex` at `/opt/node22/bin`, and `task` is 3.53.1 | [Setup script](#setup-script) |
| 1 (cache) | Seen 2026-10-07: the setup-script cache works; a session booted 13.5 h after the run it started from, across GitHub-connection changes. Two earlier sessions had re-run the script (why the second is not established). Seen 2026-10-07 after the script change to `v5.2.1`: the next session was ready about 4.5 s after creation in resume-cached mode, against about three minutes uncached, and the cached start resumes an existing checkout and fetches it forward (where that checkout is kept is not established). *Open:* what that means for where per-checkout preparation runs ([#1548](https://github.com/evanharmon1/harmon-init/issues/1548)) | [Setup script](#setup-script) |
| — | Seen 2026-10-07: the session's built-in GitHub tools are not covered by the agent posture; a draft PR was opened, commented on and closed as the bot (PR #1546). The `gh` write forms tried stay refused (defence in depth, not the boundary; [#1549](https://github.com/evanharmon1/harmon-init/issues/1549)). *Open:* which other built-in tools exist (merge, workflow runs, releases) was not asked; a merge into a protected branch still needs code-owner approval and the required checks | [What runs where](#what-runs-where) |
| — | Seen 2026-10-07: with a `/web-setup` PAT stored first and an App connection added afterwards on the same account, git pushes still use the PAT (workflow push refused). *Open:* the reverse order, and which credential serves API calls | [Whose identity GitHub sees](#whose-identity-github-sees) |
| 3 | Seen 2026-10-07, on `evanharmon1/harmon-init` and `ponderousdev/foreman`: the PAT-only route gives `gh api user` → `evanharmon1-bot`, the write role without admin or maintain (`push: true, admin: false, maintain: false`), the bot as push actor, the commit author Claude, and a refused workflow push; the App-as-bot route gives the same identity but accepts a workflow push. A PR opened through a session's built-in tools is authored by the bot (seen on `evanharmon1/harmon-init` only). *Open:* a PR through a session on a ponderousdev repository | [Whose identity GitHub sees](#whose-identity-github-sees) |
| 4 | Seen 2026-10-07: `claude --cloud "<task>"` needs a TTY, ran prompt-free and returned a pushed branch with no human step. The permission mode was auto mode by the session's own context note, not shown by a tool | [Bridges between the terminal and the cloud](#bridges-between-the-terminal-and-the-cloud) |
| 7 | Seen 2026-10-06/07: the read half is run and tagged per row; the write half in part — the `gh` forms tried for PR and issue writes were refused, and the built-in GitHub tools are not covered by the posture. *Open:* bundled-flag `gh api` writes ([#1549](https://github.com/evanharmon1/harmon-init/issues/1549)) and REST writes outside the deny list (`gh run rerun`, `cancel`), and the inventory rows still tagged *expected, not yet observed* (for example `gh issue create` and `close`, `gh run view` and `rerun`, `trusted-registry.sh`, `release-claim.sh`, `check-issue-metadata.sh`, `round-push.sh`, `lane-watch.sh`, Foreman) | [The `gh` call inventory](#the-gh-call-inventory) |
| 8 | Seen 2026-10-06: the bootstrap and `task verify` under **Trusted** completed with no network denial; no domain added | [Network](#network) |
| 11 | Seen 2026-10-06: the repository is cloned before the setup script runs | [When per-checkout preparation runs](#when-per-checkout-preparation-runs) |
| #1405-6 | Seen 2026-10-06 on `evanharmon1/harmon-init`: `task setup:remote` exits 0 and clones the siblings. *Open:* siblings readable and `task verify` runnable in a live session on `ponderousdev/omator`, which the criterion names | [When per-checkout preparation runs](#when-per-checkout-preparation-runs) |
| #1404-2 | In part, 2026-10-06/07: `gh pr merge` was refused without a prompt, consistent with the managed deny rules being enforced, inferred from the refusals. *Open:* the listing half, which cannot be done on the web because `/permissions` opens the permission-mode menu instead | [The agent posture](#the-agent-posture) |
| — (the unnumbered row) | Seen 2026-10-06: release-asset downloads from repositories not attached to the session succeed under **Trusted** | [Network](#network) |

## Reusing this structure

The [Codex cloud](codex-cloud.md) and [Fly.io Sprites](sprites.md) guides are
this guide's siblings: each opens by saying how to read its evidence and closes
with a pending-observations register. A new adapter guide should cover: **how to
read the evidence**, **the environment** (name, setup script at a pinned tag,
network level and each added domain's reason, variables), **identity and
secrets**, **what the platform's GitHub path does to `gh`** with a call
inventory, **bridges** to and from a local terminal, **the agent posture**,
**memory**, **long gates**, **when per-checkout preparation runs**, and a
**pending observations** register that ties every unobserved fact to the
criterion that will prove it.
The contract and the shared network tables stay in
[architecture/remote-environments.md](../architecture/remote-environments.md).
