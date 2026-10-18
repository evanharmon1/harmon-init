# Tests

How testing works in Harmon Init.

## Layers

| Layer | Tool | Command |
|---|---|---|
| Lint / static analysis | shellcheck, yamllint, markdownlint, actionlint | `task check` |
| Tests | TODO: pick a test runner | `task test` |
| Application security | Semgrep CE locally; CodeQL in public CI | `task security:sast` |
| Optional second opinion | Snyk Code + Open Source, manual or weekly scheduled | `task security:sast:snyk` / `task security:sca:snyk` |
| Secrets | gitleaks | `task security:secrets` |
| Dependencies | package-manager audit; Node uses reviewed, expiring dev-only allowances ([security.md](security.md#unpatched-dev-only-advisory-allowances)) | `task security:audit` |

## Conventions

- Test files live in `tests/` at the repo root (or co-located per framework convention).
- `task verify` is the local merge gate; CI runs the same task targets.
  The `repo-guards` job calls `ci:repo-guards` for the instruction audit,
  shared `test:suite`, and network skills check; `check` and
  `devcontainer-permissions` run as separate jobs.
- TODO: document coverage expectations and fixtures as the suite grows.

## Parallel Task groups

Task runs the dependencies of `check` and `test:suite` concurrently by default.
Set Task's built-in `TASK_CONCURRENCY=1` environment variable to run dependencies
one at a time, for example `TASK_CONCURRENCY=1 task verify` or
`TASK_CONCURRENCY=1 task test:suite`. A generated Node profile can run ESLint
(measured around 3.8 GB RSS) alongside TypeScript checking (around 1.5 GB RSS),
so budget about 6 GB for parallel `task check` or use the serial setting on a
smaller runner.
