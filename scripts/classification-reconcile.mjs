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

/** Work-type label names from a parsed label-registry.json. */
export function workTypeLabels(registry) {
  const family = (registry?.families ?? []).find((f) => f.family === 'work-type')
  if (!family) throw new Error('label-registry.json has no work-type family')
  return (family.values ?? family.labels ?? []).map((v) => (typeof v === 'string' ? v : v.value ?? v.name))
}

/** Is `name` a label whose change can alter the Tier or "triaged"? */
export function isInputLabel(name, workTypes) {
  if (typeof name !== 'string') return false
  return INPUT_LABEL_PREFIXES.some((p) => name.startsWith(p)) || workTypes.includes(name)
}

/** The only labels this script may ever add or remove. */
export function assertWritable(label) {
  const ok = label === NEEDS_TRIAGE || TIER_VALUES.some((t) => label === `tier:${t}`)
  if (!ok) throw new Error(`refusing to write ${JSON.stringify(label)}: only tier:<value> and ${NEEDS_TRIAGE} are writable`)
  return label
}

function axisValue(issue, { axis, field, prefix }, reports) {
  const fromField = (issue.fields ?? {})[field] ?? null
  const fromLabels = [...new Set(issue.labels.filter((l) => l.startsWith(prefix)).map((l) => l.slice(prefix.length)))]
  if (fromField !== null) {
    if (fromLabels.some((v) => v !== fromField)) {
      reports.push({ code: 'field-label-conflict', message: `${field} field is ${fromField} but labels say ${fromLabels.join(', ')}; the field wins` })
    }
    return { present: true, value: fromField }
  }
  if (fromLabels.length === 0) return { present: false, value: null }
  if (fromLabels.length > 1) {
    reports.push({ code: 'ambiguous-input', message: `${fromLabels.length} ${axis} labels (${fromLabels.join(', ')}); no ${axis} value is read` })
    return { present: true, value: null }
  }
  return { present: true, value: fromLabels[0] }
}

/**
 * The decision function. Pure: no I/O.
 *
 * issue:  { labels: string[], issueType: string|null, fields: { Impact?, Risk?, Complexity? } }
 * ctx:    { workTypes: string[], derive: ((risk, complexity) => tier) | null, underivable: string|null }
 *
 * Returns { add: string[], remove: string[], reports: {code, message}[], tier, triaged }.
 */
export function decide(issue, ctx) {
  const labels = issue.labels
  const reports = []
  const add = []
  const remove = []
  const values = {}
  let inputsPresent = true
  for (const spec of FIELD_AXES) {
    const v = axisValue(issue, spec, reports)
    values[spec.axis] = v.value
    if (!v.present) inputsPresent = false
  }
  const hasType = Boolean(issue.issueType) || labels.some((l) => ctx.workTypes.includes(l))
  const familiesPresent = LABEL_FAMILY_PREFIXES.every((p) => labels.some((l) => l.startsWith(p)))
  const triaged = hasType && familiesPresent && inputsPresent

  // needs-triage is derived (D6), pinned or not.
  if (triaged && labels.includes(NEEDS_TRIAGE)) remove.push(NEEDS_TRIAGE)
  if (!triaged && !labels.includes(NEEDS_TRIAGE)) add.push(NEEDS_TRIAGE)

  const tierLabels = labels.filter((l) => TIER_VALUES.some((t) => l === `tier:${t}`))
  if (labels.includes(RETIRED_TIER_LABEL)) {
    reports.push({ code: 'tier-retired', message: `${RETIRED_TIER_LABEL} is retired and left for its migration (#1447)` })
  }

  let tier = null
  if (labels.includes(PIN_LABEL)) {
    // Nothing automated writes over a pinned Tier (D5).
    if (tierLabels.length > 1) {
      reports.push({ code: 'ambiguous-pin', message: `${PIN_LABEL} with ${tierLabels.join(', ')}: left for a human, never resolved by picking one` })
    } else if (tierLabels.length === 0) {
      reports.push({ code: 'pin-without-tier', message: `${PIN_LABEL} without a tier value: left for a human` })
    }
  } else if (values.risk === null || values.complexity === null) {
    if (tierLabels.length > 0) {
      reports.push({ code: 'cache-unverifiable', message: `${tierLabels.join(', ')} without both Risk and Complexity: left in place, never used as an input` })
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
  if (!existsSync(policyPath)) return { derive: null, underivable: 'no .devflow.toml', reader: readerPath }
  try {
    const reader = await import(pathToFileURL(readerPath).href)
    if (typeof reader.deriveTier !== 'function' || typeof reader.resolvePolicy !== 'function') {
      return { derive: null, underivable: `the reader at ${readerPath} has no deriveTier`, reader: readerPath }
    }
    const { parseToml } = await import(new URL('./lib/toml-lite.mjs', pathToFileURL(readerPath)).href)
    const resolved = reader.resolvePolicy(parseToml(readFileSync(policyPath, 'utf8')))
    const matrix = resolved?.tier_matrix ?? null
    if (matrix === null) return { derive: null, underivable: 'the policy has no [tier.matrix]', reader: readerPath }
    return { derive: (risk, complexity) => reader.deriveTier(matrix, { risk, complexity }), underivable: null, reader: readerPath }
  } catch (err) {
    return { derive: null, underivable: `the reader at ${readerPath} could not resolve the policy: ${err.message}`, reader: readerPath }
  }
}

// ---------------------------------------------------------------------------
// GitHub I/O
// ---------------------------------------------------------------------------

const ISSUE_FIELDS = `
  number
  url
  issueType { name }
  labels(first: 100) { nodes { name } }
  issueFieldValues(first: 50) {
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
    fields
  }
}

function makeClient(token) {
  const api = process.env.GITHUB_API_URL || 'https://api.github.com'
  const graphqlUrl = process.env.GITHUB_GRAPHQL_URL || `${api}/graphql`
  const headers = {
    authorization: `Bearer ${token}`,
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    // Issue fields are behind a GraphQL feature flag.
    'graphql-features': 'issue_fields',
    'user-agent': 'classification-reconcile'
  }
  async function graphql(query, variables) {
    const res = await fetch(graphqlUrl, { method: 'POST', headers, body: JSON.stringify({ query, variables }) })
    const body = await res.json().catch(() => ({}))
    if (!res.ok || body.errors) throw new Error(`GraphQL ${res.status}: ${JSON.stringify(body.errors ?? body)}`)
    return body.data
  }
  async function rest(method, path, payload) {
    const res = await fetch(`${api}${path}`, { method, headers, body: payload === undefined ? undefined : JSON.stringify(payload) })
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
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(r)) throw new Error(`not an owner/name repository: ${JSON.stringify(r)}`)
  }
  return repos
}

async function main() {
  const root = process.cwd()
  const dryRun = process.env.RECONCILE_DRY_RUN === 'true'
  const issueNumber = Number.parseInt(process.env.RECONCILE_ISSUE || '0', 10) || 0
  const repos = parseRepositories(process.env.RECONCILE_REPOSITORIES, process.env.GITHUB_REPOSITORY)
  if (repos.length === 0) throw new Error('no repository: set RECONCILE_REPOSITORIES or GITHUB_REPOSITORY')
  if (issueNumber > 0 && repos.length !== 1) throw new Error('RECONCILE_ISSUE needs exactly one repository')
  const token = process.env.GH_TOKEN
  if (!token) throw new Error('GH_TOKEN is not set')

  const workTypes = workTypeLabels(JSON.parse(readFileSync(resolvePath(root, 'label-registry.json'), 'utf8')))
  const derivation = await loadDerivation(root)
  const ctx = { workTypes, derive: derivation.derive, underivable: derivation.underivable }
  const client = makeClient(token)
  const summary = []
  const log = (line) => {
    console.log(line)
    summary.push(line)
  }
  if (derivation.derive === null) {
    console.log(`::warning title=classification reconcile::tier not derivable: ${derivation.underivable}; maintaining ${NEEDS_TRIAGE} only`)
    summary.push(`> **Tier not derivable:** ${derivation.underivable}. \`${NEEDS_TRIAGE}\` is still maintained; no Tier is written.`, '')
  }
  log(`| Issue | Added | Removed | Reports |`)
  log(`|---|---|---|---|`)

  let changed = 0
  let seen = 0
  for (const repo of repos) {
    const [owner, name] = repo.split('/')
    const issues = issueNumber > 0 ? [await fetchIssue(client, owner, name, issueNumber)].filter(Boolean) : openIssues(client, owner, name)
    for await (const issue of issues) {
      seen += 1
      let plan = decide(issue, ctx)
      if (!dryRun && (plan.add.length > 0 || plan.remove.length > 0)) {
        // Re-read immediately before writing: a human may have pinned or
        // re-classified since the walk read this issue.
        const fresh = await fetchIssue(client, owner, name, issue.number)
        plan = fresh ? decide(fresh, ctx) : { add: [], remove: [], reports: [] }
        const path = `/repos/${owner}/${name}/issues/${issue.number}/labels`
        if (plan.add.length > 0) await client.rest('POST', path, { labels: plan.add.map(assertWritable) })
        for (const l of plan.remove) await client.rest('DELETE', `${path}/${encodeURIComponent(assertWritable(l))}`)
      }
      // Ambiguity and pins are reported per issue; the run-wide "not
      // derivable" reason is reported once above.
      const reports = plan.reports.filter((r) => r.code !== 'tier-not-derivable')
      for (const r of reports) console.log(`::warning title=${repo}#${issue.number} ${r.code}::${r.message}`)
      if (plan.add.length > 0 || plan.remove.length > 0 || reports.length > 0) {
        if (plan.add.length > 0 || plan.remove.length > 0) changed += 1
        const cell = (xs) => xs.map((x) => `\`${x}\``).join(' ') || '—'
        log(`| ${repo}#${issue.number} | ${cell(plan.add)} | ${cell(plan.remove)} | ${reports.map((r) => `${r.code}: ${r.message}`).join('<br>') || '—'} |`)
      }
    }
  }
  log('')
  log(`${dryRun ? 'Dry run: would change' : 'Changed'} ${changed} of ${seen} open issue(s) in ${repos.join(', ')}.`)
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Classification reconcile\n\n${summary.join('\n')}\n`)
  }
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolvePath(process.argv[1])
if (isMain) {
  main().catch((err) => {
    console.error(`classification-reconcile: ${err.message}`)
    process.exitCode = 1
  })
}
