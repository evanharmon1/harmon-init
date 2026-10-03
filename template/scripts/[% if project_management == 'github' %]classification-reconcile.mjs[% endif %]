#!/usr/bin/env node
// scripts/classification-reconcile.mjs — materialize the derived Tier and
// `needs-triage` on open issues (ADR 2026-09-30 D4 "Reconcile drift" and D6,
// as amended by ADR 2026-10-01: the Tier is a `tier:<value>` label on every
// owner type).
//
// Run by .github/workflows/classification-reconcile.yml, on its schedule, on
// workflow_dispatch, and per issue from classification-event.yml. Agent
// writers (triage, track-work, breakdown) set the Tier and `needs-triage` in
// the same write that sets Risk or Complexity; this script repairs what they
// did not cover: a human editing an input in the GitHub UI, or drift from any
// other source.
//
// Inputs are read in both storage shapes. Impact, Risk and Complexity are
// organization issue fields on organization repositories and
// `impact:*`/`risk:*`/`complexity:*` labels on personal-account ones; a field
// wins over a label of the same axis, and a disagreement is reported.
//
// "Triaged" (D6) needs a Type (native, or a non-retired work-type label) and
// exactly one recognized, non-retired value of each of impact, risk,
// complexity, area, layer and domain, read from this repository's
// label-registry.json. A conflicted axis, a retired value, or an unknown one
// does not classify its axis. With the registry unreadable every axis is
// unverifiable, and `needs-triage` is left as it is.
//
// The derivation is the policy reader's `deriveTier` over the governing
// `.devflow.toml`'s [tier.matrix]. This script never re-implements the
// matrix: a reader that is missing, lacks `deriveTier`, or throws while
// resolving the policy (an older vendored reader meeting a [tier] table it
// does not know) leaves the Tier unwritten, `needs-triage` still maintained,
// and the reason reported. The job never fails on an old reader.
//
// Writers: ONLY `tier:<value>` (one of the five rungs) and `needs-triage`
// (assertWritable). Never over an issue carrying `tier:pinned`; an ambiguous
// pin (two or more tier values beside `tier:pinned`) is reported and left for
// a human. Never `tier:pinned`, `tier:adaptive`, `priority:*`,
// `priority-ai:*`, `rigor:*`, `strategy:*` or `claim:*`.
//
// Environment:
//   GH_TOKEN                   token for the GitHub API (required unless dry run)
//   RECONCILE_REPOSITORIES     newline/comma/space list of owner/name
//                              (default: GITHUB_REPOSITORY)
//   RECONCILE_ISSUE            one issue number (single-repository mode); 0 or
//                              empty walks every open issue
//   RECONCILE_DRY_RUN          "true" to report the plan and write nothing
//   GITHUB_API_URL, GITHUB_GRAPHQL_URL, GITHUB_STEP_SUMMARY (Actions-provided)

import { existsSync, readFileSync, appendFileSync } from 'node:fs'
import { resolve as resolvePath } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// The Tier ladder is vocabulary, not policy: specs/dev-flow-v2.md pins
// tier_order as local → economy → standard → frontier → apex. Only the
// [tier.matrix] cells are per-repository, and those come from the reader.
export const TIER_VALUES = Object.freeze(['local', 'economy', 'standard', 'frontier', 'apex'])
export const PIN_LABEL = 'tier:pinned'
export const RETIRED_TIER_LABEL = 'tier:adaptive'
export const NEEDS_TRIAGE = 'needs-triage'

// The three classification axes with an issue field on organization
// repositories (setup-github-issue-fields.sh) and a label family everywhere.
export const FIELD_AXES = Object.freeze([
  { axis: 'impact', field: 'Impact', prefix: 'impact:' },
  { axis: 'risk', field: 'Risk', prefix: 'risk:' },
  { axis: 'complexity', field: 'Complexity', prefix: 'complexity:' }
])
// Label-only required families (D6): one each, or that family's `none`.
export const LABEL_FAMILY_PREFIXES = Object.freeze(['area:', 'layer:', 'domain:'])
// Every family "triaged" requires (D6). Each is exclusive in the registry, so
// an axis counts only with exactly one recognized, non-retired value.
export const REQUIRED_FAMILIES = Object.freeze([
  ...FIELD_AXES.map((a) => a.axis),
  ...LABEL_FAMILY_PREFIXES.map((p) => p.slice(0, -1))
])

// The label prefixes that are INPUTS to the Tier or to "triaged". The event
// workflow's job-level `if` lists exactly these (plus the work-type labels);
// test-classification-reconcile.sh holds the two together. `tier:*` and
// `needs-triage` are deliberately absent: a Tier or pin edit never starts a
// job, so the two-step UI pin cannot be overwritten mid-pin (#1450 C1-F3).
export const INPUT_LABEL_PREFIXES = Object.freeze([
  ...FIELD_AXES.map((a) => a.prefix),
  ...LABEL_FAMILY_PREFIXES
])

// The event types the event workflow starts on. `edited` is deliberately
// absent (a title or body edit is never an input), and so are
// `field_added`/`field_removed` until actionlint knows them (#1485): an
// organization-repository field edit is repaired by the schedule.
export const EVENT_TYPES = Object.freeze(['opened', 'labeled', 'unlabeled', 'typed', 'untyped'])

/**
 * The active vocabulary of a parsed label-registry.json: the non-retired work
 * types and the recognized, non-retired values of every required family.
 * Throws when the registry lacks one of them.
 */
export function activeVocabulary(registry) {
  const families = registry?.families
  if (!Array.isArray(families)) throw new Error('label-registry.json has no families array')
  const active = (name) => {
    const family = families.find((f) => f.family === name)
    if (!family || !Array.isArray(family.values)) {
      throw new Error(`label-registry.json has no ${name} family values`)
    }
    return family.values.filter((v) => !v.retired).map((v) => v.value)
  }
  const recognized = {}
  for (const name of REQUIRED_FAMILIES) recognized[name] = active(name)
  return { workTypes: active('work-type'), recognized }
}

/** The only labels this script may ever add or remove. */
export function assertWritable(label) {
  const ok = label === NEEDS_TRIAGE || TIER_VALUES.some((t) => label === `tier:${t}`)
  if (!ok)
    throw new Error(
      `refusing to write ${JSON.stringify(label)}: only tier:<value> and ${NEEDS_TRIAGE} are writable`
    )
  return label
}

// One required family's state. `value` is the single value read (a field wins
// over a same-axis label), or null when absent or conflicted; `applied` is true
// only when that value is in the active taxonomy. `recognized` null means the
// registry is unreadable, so nothing can be applied.
function axisState(issue, family, recognized, reports) {
  const prefix = `${family}:`
  const spec = FIELD_AXES.find((a) => a.axis === family)
  const fieldValue = spec ? ((issue.fields ?? {})[spec.field] ?? null) : null
  const labelValues = issue.labels
    .filter((l) => l.startsWith(prefix))
    .map((l) => l.slice(prefix.length))
  let value
  if (fieldValue !== null) {
    if (labelValues.some((v) => v !== fieldValue)) {
      reports.push({
        code: 'field-label-conflict',
        message: `${spec.field} field is ${fieldValue} but labels say ${labelValues.join(', ')}; the field wins`
      })
    }
    value = fieldValue
  } else if (labelValues.length === 0) {
    return { value: null, applied: false }
  } else if (labelValues.length > 1) {
    reports.push({
      code: 'conflicted-axis',
      message: `${labelValues.length} ${family} labels (${labelValues.join(', ')}); ${family} is not classified`
    })
    return { value: null, applied: false }
  } else {
    value = labelValues[0]
  }
  if (recognized === null) return { value, applied: false }
  if (!recognized[family].includes(value)) {
    reports.push({
      code: 'unrecognized-value',
      message: `${family} ${JSON.stringify(value)} is not in the active taxonomy (retired or unknown); ${family} is not classified`
    })
    return { value, applied: false }
  }
  return { value, applied: true }
}

/**
 * The decision function. Pure: no I/O.
 *
 * issue:  { labels: string[], issueType: string|null, fields: { Impact?, Risk?, Complexity? },
 *           truncated?: string|null }
 * ctx:    { vocabulary: activeVocabulary(...) | null (registry unreadable),
 *           derive: ((risk, complexity) => tier) | null, underivable: string|null }
 *
 * Returns { add: string[], remove: string[], reports: {code, message}[], tier, triaged }.
 */
export function decide(issue, ctx) {
  const labels = issue.labels
  const reports = []
  const add = []
  const remove = []
  if (issue.truncated) {
    // A partial read could hide tier:pinned or an input: decide nothing.
    reports.push({
      code: 'truncated',
      message: `the issue's ${issue.truncated} exceed one page; skipped rather than decided on a partial read`
    })
    return { add, remove, reports, tier: null, triaged: null }
  }
  const vocabulary = ctx.vocabulary
  const states = {}
  for (const family of REQUIRED_FAMILIES) {
    states[family] = axisState(issue, family, vocabulary?.recognized ?? null, reports)
  }
  const values = { risk: states.risk.value, complexity: states.complexity.value }

  // needs-triage is derived (D6), pinned or not. With the registry unreadable
  // every axis is unverifiable, so needs-triage is left as it is.
  let triaged = null
  if (vocabulary) {
    const hasType = Boolean(issue.issueType) || labels.some((l) => vocabulary.workTypes.includes(l))
    triaged = hasType && REQUIRED_FAMILIES.every((f) => states[f].applied)
    if (triaged && labels.includes(NEEDS_TRIAGE)) remove.push(NEEDS_TRIAGE)
    if (!triaged && !labels.includes(NEEDS_TRIAGE)) add.push(NEEDS_TRIAGE)
  }

  const tierLabels = labels.filter((l) => TIER_VALUES.some((t) => l === `tier:${t}`))
  if (labels.includes(RETIRED_TIER_LABEL)) {
    reports.push({
      code: 'tier-retired',
      message: `${RETIRED_TIER_LABEL} is retired and left for its migration (#1447)`
    })
  }

  let tier = null
  if (labels.includes(PIN_LABEL)) {
    // Nothing automated writes over a pinned Tier (D5).
    if (tierLabels.length > 1) {
      reports.push({
        code: 'ambiguous-pin',
        message: `${PIN_LABEL} with ${tierLabels.join(', ')}: left for a human, never resolved by picking one`
      })
    } else if (tierLabels.length === 0) {
      reports.push({
        code: 'pin-without-tier',
        message: `${PIN_LABEL} without a tier value: left for a human`
      })
    }
  } else if (values.risk === null || values.complexity === null) {
    if (tierLabels.length > 0) {
      reports.push({
        code: 'cache-unverifiable',
        message: `${tierLabels.join(', ')} without both Risk and Complexity: left in place, never used as an input`
      })
    }
  } else if (ctx.derive === null) {
    reports.push({ code: 'tier-not-derivable', message: `tier not derivable: ${ctx.underivable}` })
  } else {
    try {
      tier = ctx.derive(values.risk, values.complexity)
    } catch (err) {
      reports.push({ code: 'invalid-input', message: `tier not derived: ${err.message}` })
    }
    if (tier !== null) {
      const want = `tier:${tier}`
      if (!tierLabels.includes(want)) add.push(want)
      for (const l of tierLabels) if (l !== want) remove.push(l)
    }
  }
  for (const l of [...add, ...remove]) assertWritable(l)
  return { add, remove, reports, tier, triaged }
}

// ---------------------------------------------------------------------------
// The policy reader, located at runtime
// ---------------------------------------------------------------------------

// First match wins: harmon-init's own reader, then the vendored dev-flow-support
// copy in either skills destination a repository can vendor to.
export const READER_CANDIDATES = Object.freeze([
  'scripts/devflow-policy.mjs',
  '.agents/skills/dev-flow-support/assets/devflow-policy.mjs',
  '.claude/skills/dev-flow-support/assets/devflow-policy.mjs'
])

/**
 * Load `deriveTier` and the [tier.matrix] from the repository at `root`.
 * Never throws: returns { derive, underivable, reader }.
 */
export async function loadDerivation(root, candidates = READER_CANDIDATES) {
  const readerPath = candidates.map((c) => resolvePath(root, c)).find((p) => existsSync(p))
  if (!readerPath) return { derive: null, underivable: 'no policy reader found', reader: null }
  const policyPath = resolvePath(root, '.devflow.toml')
  if (!existsSync(policyPath))
    return { derive: null, underivable: 'no .devflow.toml', reader: readerPath }
  try {
    const reader = await import(pathToFileURL(readerPath).href)
    if (typeof reader.deriveTier !== 'function' || typeof reader.resolvePolicy !== 'function') {
      return {
        derive: null,
        underivable: `the reader at ${readerPath} has no deriveTier`,
        reader: readerPath
      }
    }
    const { parseToml } = await import(
      new URL('./lib/toml-lite.mjs', pathToFileURL(readerPath)).href
    )
    const resolved = reader.resolvePolicy(parseToml(readFileSync(policyPath, 'utf8')))
    const matrix = resolved?.tier_matrix ?? null
    if (matrix === null)
      return { derive: null, underivable: 'the policy has no [tier.matrix]', reader: readerPath }
    return {
      derive: (risk, complexity) => reader.deriveTier(matrix, { risk, complexity }),
      underivable: null,
      reader: readerPath
    }
  } catch (err) {
    return {
      derive: null,
      underivable: `the reader at ${readerPath} could not resolve the policy: ${err.message}`,
      reader: readerPath
    }
  }
}

// ---------------------------------------------------------------------------
// GitHub I/O
// ---------------------------------------------------------------------------

const ISSUE_FIELDS = `
  number
  url
  issueType { name }
  labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
  issueFieldValues(first: 50) {
    pageInfo { hasNextPage }
    nodes {
      ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } }
    }
  }`

function normalizeIssue(node) {
  const fields = {}
  for (const v of node.issueFieldValues?.nodes ?? []) {
    const name = v?.field?.name
    if (name && FIELD_AXES.some((a) => a.field === name)) fields[name] = v.name
  }
  return {
    number: node.number,
    url: node.url,
    issueType: node.issueType?.name ?? null,
    labels: (node.labels?.nodes ?? []).map((l) => l.name),
    fields,
    // decide() skips an issue whose labels or field values span more than one
    // page: a partial read could hide tier:pinned or an input.
    truncated:
      [
        node.labels?.pageInfo?.hasNextPage ? 'labels' : null,
        node.issueFieldValues?.pageInfo?.hasNextPage ? 'issue field values' : null
      ]
        .filter(Boolean)
        .join(' and ') || null
  }
}

function makeClient(token, fetch, env) {
  const api = env.GITHUB_API_URL || 'https://api.github.com'
  const graphqlUrl = env.GITHUB_GRAPHQL_URL || `${api}/graphql`
  const headers = {
    authorization: `Bearer ${token}`,
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    // Issue fields are behind a GraphQL feature flag.
    'graphql-features': 'issue_fields',
    'user-agent': 'classification-reconcile'
  }
  async function graphql(query, variables) {
    const res = await fetch(graphqlUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({ query, variables })
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok || body.errors)
      throw new Error(`GraphQL ${res.status}: ${JSON.stringify(body.errors ?? body)}`)
    return body.data
  }
  async function rest(method, path, payload) {
    const res = await fetch(`${api}${path}`, {
      method,
      headers,
      body: payload === undefined ? undefined : JSON.stringify(payload)
    })
    if (method === 'DELETE' && res.status === 404) return null // already gone
    if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${await res.text()}`)
    return res.status === 204 ? null : res.json()
  }
  return { graphql, rest }
}

async function* openIssues(client, owner, name) {
  let after = null
  for (;;) {
    const data = await client.graphql(
      `query($owner: String!, $name: String!, $after: String) {
        repository(owner: $owner, name: $name) {
          issues(first: 50, after: $after, states: OPEN) {
            pageInfo { hasNextPage endCursor }
            nodes { ${ISSUE_FIELDS} }
          }
        }
      }`,
      { owner, name, after }
    )
    const conn = data.repository.issues
    for (const node of conn.nodes) yield normalizeIssue(node)
    if (!conn.pageInfo.hasNextPage) return
    after = conn.pageInfo.endCursor
  }
}

async function fetchIssue(client, owner, name, number) {
  const data = await client.graphql(
    `query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $number) { state ${ISSUE_FIELDS} } }
    }`,
    { owner, name, number }
  )
  const node = data.repository.issue
  return node && node.state === 'OPEN' ? normalizeIssue(node) : null
}

export function parseRepositories(raw, fallback) {
  const list = String(raw ?? '')
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean)
  const repos = list.length > 0 ? list : fallback ? [fallback] : []
  for (const r of repos) {
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(r))
      throw new Error(`not an owner/name repository: ${JSON.stringify(r)}`)
  }
  return repos
}

// Apply one issue's plan, re-read first (a human may have pinned or
// re-classified since the walk read the issue).
//
// Invariant: every Tier mutation is preceded by a read, made after the
// previous mutation, that shows no tier:pinned. On a pin, every remaining
// Tier write stops and the issue is reported. GitHub's label API has no
// compare-and-swap, so one round trip between that read and its write is the
// irreducible residual. `needs-triage` is maintained on pinned issues too, so
// its writes are unguarded and run after the Tier writes.
export async function applyPlan(client, owner, name, number, ctx) {
  const fresh = await fetchIssue(client, owner, name, number)
  if (!fresh) return { add: [], remove: [], reports: [] }
  const plan = decide(fresh, ctx)
  const path = `/repos/${owner}/${name}/issues/${number}/labels`
  const write = (method, label) =>
    method === 'POST'
      ? client.rest('POST', path, { labels: [assertWritable(label)] })
      : client.rest('DELETE', `${path}/${encodeURIComponent(assertWritable(label))}`)
  const isTier = (l) => l !== NEEDS_TRIAGE
  const tierWrites = [
    ...plan.add.filter(isTier).map((l) => ['POST', l]),
    ...plan.remove.filter(isTier).map((l) => ['DELETE', l])
  ]
  const applied = { add: [], remove: [] }
  const record = (method, label) => (method === 'POST' ? applied.add : applied.remove).push(label)
  let read = fresh // the decision read guards the first Tier write
  for (const [i, [method, label]] of tierWrites.entries()) {
    if (i > 0) read = await fetchIssue(client, owner, name, number)
    if (!read) return { ...plan, ...applied } // closed mid-write: stop everything
    if (read.truncated) {
      // A partial guard read cannot establish that the issue is unpinned.
      const skipped = tierWrites.slice(i).map(([m, l]) => `${m === 'POST' ? 'add' : 'remove'} ${l}`)
      plan.reports.push({
        code: 'pin-guard-indeterminate',
        message: `the guard read's ${read.truncated} exceed one page; ${skipped.join(', ')} not applied`
      })
      break
    }
    if (read.labels.includes(PIN_LABEL)) {
      const skipped = tierWrites.slice(i).map(([m, l]) => `${m === 'POST' ? 'add' : 'remove'} ${l}`)
      plan.reports.push({
        code: 'pin-appeared',
        message: `${PIN_LABEL} appeared during the write; ${skipped.join(', ')} not applied, left for a human`
      })
      break
    }
    await write(method, label)
    record(method, label)
  }
  for (const label of plan.add.filter((l) => !isTier(l))) {
    await write('POST', label)
    record('POST', label)
  }
  for (const label of plan.remove.filter((l) => !isTier(l))) {
    await write('DELETE', label)
    record('DELETE', label)
  }
  return { ...plan, ...applied }
}

/**
 * Run the reconciler as the workflow does, from an environment (see the
 * header). Returns the exit code: 1 when any repository failed, else 0.
 * `fetch`, `root` and `print` are injectable so the driver can be tested.
 */
export async function run(
  env,
  { fetch = globalThis.fetch, root = process.cwd(), print = console.log } = {}
) {
  const dryRun = env.RECONCILE_DRY_RUN === 'true'
  const issueNumber = Number.parseInt(env.RECONCILE_ISSUE || '0', 10) || 0
  const repos = parseRepositories(env.RECONCILE_REPOSITORIES, env.GITHUB_REPOSITORY)
  if (repos.length === 0)
    throw new Error('no repository: set RECONCILE_REPOSITORIES or GITHUB_REPOSITORY')
  if (issueNumber > 0 && repos.length !== 1)
    throw new Error('RECONCILE_ISSUE needs exactly one repository')
  const token = env.GH_TOKEN
  if (!token) throw new Error('GH_TOKEN is not set')

  const summary = []
  const log = (line) => {
    print(line)
    summary.push(line)
  }
  const warnRun = (headline, detail) => {
    print(`::warning title=classification reconcile::${headline}`)
    summary.push(`> **${detail}**`, '')
  }

  let vocabulary = null
  try {
    vocabulary = activeVocabulary(
      JSON.parse(readFileSync(resolvePath(root, 'label-registry.json'), 'utf8'))
    )
  } catch (err) {
    warnRun(
      `label-registry.json is unreadable (${err.message}); every axis is unverifiable and ${NEEDS_TRIAGE} is left as it is`,
      `label-registry.json is unreadable: ${err.message}. Every axis is unverifiable; \`${NEEDS_TRIAGE}\` is left as it is.`
    )
  }
  const derivation = await loadDerivation(root)
  if (derivation.derive === null) {
    warnRun(
      `tier not derivable: ${derivation.underivable}; no Tier is written`,
      `Tier not derivable: ${derivation.underivable}. No Tier is written.`
    )
  }
  const ctx = { vocabulary, derive: derivation.derive, underivable: derivation.underivable }
  const client = makeClient(token, fetch, env)
  log(`| Issue | Added | Removed | Reports |`)
  log(`|---|---|---|---|`)

  let changed = 0
  let seen = 0
  const failed = []
  // One repository's failure (renamed, inaccessible, rate-limited) never
  // stops the rest of the list; the run fails after the whole list.
  for (const repo of repos) {
    const [owner, name] = repo.split('/')
    try {
      const issues =
        issueNumber > 0
          ? [await fetchIssue(client, owner, name, issueNumber)].filter(Boolean)
          : openIssues(client, owner, name)
      for await (const issue of issues) {
        seen += 1
        let plan = decide(issue, ctx)
        if (!dryRun && (plan.add.length > 0 || plan.remove.length > 0)) {
          plan = await applyPlan(client, owner, name, issue.number, ctx)
        }
        // The run-wide "not derivable" reason is reported once above.
        const reports = plan.reports.filter((r) => r.code !== 'tier-not-derivable')
        for (const r of reports) {
          print(`::warning title=${repo}#${issue.number} ${r.code}::${r.message}`)
        }
        if (plan.add.length > 0 || plan.remove.length > 0 || reports.length > 0) {
          if (plan.add.length > 0 || plan.remove.length > 0) changed += 1
          const cell = (xs) => xs.map((x) => `\`${x}\``).join(' ') || '—'
          log(
            `| ${repo}#${issue.number} | ${cell(plan.add)} | ${cell(plan.remove)} | ${reports.map((r) => `${r.code}: ${r.message}`).join('<br>') || '—'} |`
          )
        }
      }
    } catch (err) {
      failed.push(repo)
      print(`::error title=classification reconcile ${repo}::${err.message}`)
      summary.push(`> **${repo} failed:** ${err.message}`, '')
    }
  }
  log('')
  log(
    `${dryRun ? 'Dry run: would change' : 'Changed'} ${changed} of ${seen} open issue(s) in ${repos.join(', ')}.`
  )
  if (failed.length > 0) log(`Failed: ${failed.join(', ')}.`)
  if (env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      env.GITHUB_STEP_SUMMARY,
      `## Classification reconcile\n\n${summary.join('\n')}\n`
    )
  }
  return failed.length > 0 ? 1 : 0
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolvePath(process.argv[1])
if (isMain) {
  run(process.env).then(
    (code) => {
      process.exitCode = code
    },
    (err) => {
      console.error(`classification-reconcile: ${err.message}`)
      process.exitCode = 1
    }
  )
}
