#!/usr/bin/env node
// scripts/devflow-policy.mjs — the shared v2 `.devflow.toml` reader.
//
// Every Dev flow v2 consumer (the exit script, the round-push broker, the
// integrator, the stage skills) resolves policy through this one module
// rather than parsing TOML itself, so shape refusal and resolution never
// drift between consumers (design.md decision 13). See
// openspec/changes/dev-flow-v2/specs/config/spec.md for the normative
// contract this implements, and AGENTS.md "Round caps are resolved, not
// stated here" / "Tier and strategy" for the legacy-repo policy this
// repository's OWN live .devflow.toml still uses (never operated under by
// this module — see "Shape detection" below).
//
// Usable as a CLI (`node scripts/devflow-policy.mjs resolve|detect ...`)
// or as a library (`import { resolvePolicy, detectShape } from
// "./devflow-policy.mjs"`), notably by scripts/dev-flow-exit.mjs.

import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { parseToml, TomlError } from './lib/toml-lite.mjs'

export class PolicyError extends Error {}

const ROUND_KEYS = [
  'challenge',
  'review',
  'integration',
  'remediation',
  'min_rounds',
  'wall_clock_min'
]
const BREADTH_KEYS = ['max_agent_runs', 'max_parallel_agents']
const SPEND_KEYS = ['max_tokens', 'max_usd']
const TOP_LEVEL_REQUIRED_KEYS = [
  'schema_version',
  'default_rigor',
  'default_strategy',
  'rigor_order',
  'tier_order',
  'rigor',
  'rounds',
  'breadth',
  'gates',
  'convergence',
  'role',
  'stage',
  'strategy'
]
const TOP_LEVEL_OPTIONAL_KEYS = ['spend']
const GATE_KEYS = ['round_code', 'round_docs', 'secret_scan', 'pre_pr']
const ROLES = ['orchestrator', 'implementer', 'challenger', 'reviewer', 'integrator']
const CONFIDENCE_STAGES = ['challenge', 'review']
const STAGES = ['implement', 'challenge', 'review', 'integration']
const PRE_PR_STAGES = new Set(['implement', 'challenge', 'review'])
const PREDICATES = new Set([
  'no_gating_findings',
  'provenance_share',
  'count_rising',
  'repeat_after_fix'
])
// specs/dev-flow-v2.md "Convergence model v0" § Finding fields: `class ∈
// design | correctness | consistency | hardening | nit` — the same enum
// ai/schemas/result*.schema.json ships for `finding.class`.
const FINDING_CLASSES = new Set(['design', 'correctness', 'consistency', 'hardening', 'nit'])
const STRATEGY_REQUIRED_KEYS = new Set([
  'topology',
  'planning',
  'delegation',
  'human_gates',
  'description'
])
const STRATEGY_OPTIONAL_KEYS = new Set([
  'coordination',
  'selection',
  'synthesis',
  'min_agents',
  'distinct_families'
])
const STRATEGY_TOPOLOGIES = new Set([
  'single-agent',
  'lead-and-workers',
  'independent-proposals',
  'human-directed'
])
const STRATEGY_PLANNING = new Set(['inline', 'explicit', 'independent', 'collaborative'])
const STRATEGY_DELEGATION = new Set(['none', 'optional', 'required'])
const STRATEGY_HUMAN_GATES = new Set([
  'after-discovery',
  'after-plan',
  'before-delegation',
  'before-selection',
  'before-synthesis',
  'before-scope-expansion',
  'before-budget-escalation',
  'before-publication',
  'before-ready-for-review',
  'each-phase'
])

// A cap, floor, or breadth ceiling is read from branch-controlled TOML and
// used directly as a loop bound (challenge round 3, confirmed): unvalidated
// it accepts negatives (a negative cap reads as "reached before any round
// ran"), fractions, NaN, and Infinity. Every numeric policy value that gates
// a round or a resource ceiling must be a plain non-negative integer.
function requireNonNegativeInt(value, label, errorPath) {
  if (!Number.isInteger(value) || value < 0) {
    throw new PolicyError(
      `${errorPath}: "${label}" must be a non-negative integer, got ${JSON.stringify(value)}`
    )
  }
}

function requirePositiveInt(value, label, errorPath) {
  if (!Number.isInteger(value) || value < 1) {
    throw new PolicyError(
      `${errorPath}: "${label}" must be a positive integer, got ${JSON.stringify(value)}`
    )
  }
}

function requireClosedTable(table, requiredKeys, optionalKeys, errorPath) {
  if (table === null || typeof table !== 'object' || Array.isArray(table)) {
    throw new PolicyError(`${errorPath} must be a table`)
  }
  const allowed = new Set([...requiredKeys, ...optionalKeys])
  const missing = requiredKeys.filter((key) => !Object.hasOwn(table, key))
  const extra = Object.keys(table).filter((key) => !allowed.has(key))
  if (missing.length > 0 || extra.length > 0) {
    throw new PolicyError(
      `${errorPath} has invalid keys` +
        `${missing.length > 0 ? `; missing: ${missing.join(', ')}` : ''}` +
        `${extra.length > 0 ? `; unsupported: ${extra.join(', ')}` : ''}`
    )
  }
}

// Built-in defaults supplied only on the historical merge-base decode path
// (legacy/v1 → v2), per the 2026-09-02 lane addenda: the decoder's scope is
// an INVARIANT, not a field list — every merge-base-protected value
// (defaults, rounds, breadth, convergence, gates, roles, stages, strategy,
// tier_order) resolves from the older copy's own semantics (only `rounds`
// and the rigor level name qualify) or from these built-in defaults, NEVER
// from the branch's v2 copy. Where the older shape has no equivalent
// concept at all (breadth, convergence predicates, roles, stages), the
// built-in default below is the only admissible source — decodeHistoricalPolicy()
// never reads the BRANCH copy to fill the gap. A historical merge-base may,
// however, already carry directly compatible values under its older names
// (`budget`, three role tiers, and `strategy`); those are decoded from that
// trusted document before a built-in is considered.
// These are this module's own documented choice, not a value copied from
// any spec text except where cited — see "## Deferred findings" in the
// shipping PR.
const BUILTIN_GATE_DEFAULTS = {
  round_code: 'verify',
  round_docs: 'check',
  secret_scan: 'security:secrets',
  pre_pr: 'security',
  docs_only_paths: ['**/*.md', 'docs/**']
}
// Legacy/v1 shapes have no [rounds].remediation at all
// (remediation is a v2-only finer split of what legacy calls "shepherd";
// v1 stores wall_clock_min under its selected [budget.*] rather than
// [rounds.*]). Built-in fallbacks cover only truly absent historical values.
const BUILTIN_REMEDIATION_FALLBACK = (integrationCap) => integrationCap
const BUILTIN_WALL_CLOCK_MIN_FALLBACK = 240
// A legacy shape has no [breadth.*]. Schema v1 calls the same horizontal
// ceilings [budget.*], so decodeHistoricalPolicy maps them when present.
// This fallback covers older documents that predate those compatible fields.
const BUILTIN_BREADTH_DEFAULT = Object.freeze({
  policy: 'builtin-default',
  max_agent_runs: 8,
  max_parallel_agents: 3
})
// The no-policy fallback is the stable, deliberately small vocabulary promised
// by AGENTS.md: standard rigor plus plan strategy. Keep these values independent
// of the branch policy so deleting or weakening .devflow.toml cannot rewrite the
// fallback that a trusted copy of this reader applies.
const BUILTIN_ABSENT_ROUNDS = Object.freeze({
  policy: 'builtin:standard',
  challenge: 3,
  review: 3,
  integration: 4,
  remediation: 4,
  min_rounds: 1,
  wall_clock_min: 120,
  shared_budget: false
})
const BUILTIN_ABSENT_BREADTH = Object.freeze({
  policy: 'builtin:standard',
  max_agent_runs: 6,
  max_parallel_agents: 3
})
// tier_order is a spec-pinned constant (specs/dev-flow-v2.md § Configuration:
// "tier_order is local → economy → standard → frontier → apex and is the
// only definition of one-rung escalation"), not a per-repo choice — using it
// here is citing the spec, not inventing a default.
const BUILTIN_TIER_ORDER = Object.freeze(['local', 'economy', 'standard', 'frontier', 'apex'])
// The v0 predicate catalog exactly as specs/dev-flow-v2.md § "Convergence
// model v0" ships it as its own worked example — legacy/v1 have no
// [convergence] table at all, so this is the built-in default rather than
// something decoded from either older shape.
const BUILTIN_CONVERGENCE_DEFAULT = Object.freeze({
  converged: { kind: 'all', list: [{ predicate: 'no_gating_findings' }] },
  diverging: {
    kind: 'any',
    list: [
      { predicate: 'count_rising', increases: 2 },
      { predicate: 'repeat_after_fix' },
      { predicate: 'provenance_share', min: 0.5, exclude_classes: ['design'] }
    ]
  },
  overridden: false
})
// specs/dev-flow-v2.md § Configuration's own "shipped baselines" for roles
// that an older document cannot name. Schema v1 does name orchestrator,
// implementer, and reviewer tiers on each rigor profile; the historical
// decoder preserves those values and uses these defaults only for the two new
// roles (challenger inherits v1's reviewer tier because that role was split
// from reviewer; integrator has no historical counterpart). families and
// harnesses remain empty because the older policy carries neither catalog.
const BUILTIN_ROLE_TIER_DEFAULTS = Object.freeze({
  orchestrator: 'apex',
  implementer: 'standard',
  challenger: 'frontier',
  reviewer: 'standard',
  integrator: 'economy'
})
// No legacy/v1 equivalent of [stage.*] exists. An empty finder set is the
// built-in default; scripts/dev-flow-exit.mjs treats an empty resolved
// finders[] as "no configured authority" and falls back to the observed
// passes' own slots for logical-round assembly rather than trivially
// treating every round as complete.
function builtinStagesDefault() {
  const result = {}
  for (const stage of STAGES) result[stage] = { finders: [], finder_fallbacks: [], pool: null }
  return result
}
function builtinRolesDefault() {
  const result = {}
  for (const [role, tier] of Object.entries(BUILTIN_ROLE_TIER_DEFAULTS)) {
    result[role] = { tier, source: 'builtin-default', families: [], harnesses: [] }
  }
  return result
}
// The oldest legacy shape may have no [strategy.*]. Schema v1 does, with the
// same topology vocabulary, so the decoder preserves it when present. This is
// the fallback only when the merge-base genuinely has no strategy catalog.
const BUILTIN_STRATEGY_DEFAULT = Object.freeze({
  name: 'plan',
  topology: 'single-agent',
  planning: 'explicit',
  delegation: 'optional',
  human_gates: [],
  description: 'Built-in plan strategy'
})

/** Resolve the documented fallback used only when .devflow.toml is absent. */
export function resolveAbsentPolicy({ rigor: requestedRigor, strategy: requestedStrategy } = {}) {
  if (requestedRigor !== undefined && requestedRigor !== 'standard') {
    throw new PolicyError(
      `requested rigor ${JSON.stringify(requestedRigor)} is unavailable without .devflow.toml; the built-in fallback supports only "standard"`
    )
  }
  if (requestedStrategy !== undefined && requestedStrategy !== 'plan') {
    throw new PolicyError(
      `requested strategy ${JSON.stringify(requestedStrategy)} is unavailable without .devflow.toml; the built-in fallback supports only "plan"`
    )
  }

  const roles = builtinRolesDefault()
  roles.orchestrator.tier = 'frontier'
  roles.implementer.tier = 'standard'
  roles.challenger.tier = 'frontier'
  roles.reviewer.tier = 'standard'
  roles.integrator.tier = 'economy'

  return {
    source: 'built-in-fallback',
    rigor: { level: 'standard', order: ['standard'], tier_escalation: false },
    rounds: { ...BUILTIN_ABSENT_ROUNDS },
    breadth: { ...BUILTIN_ABSENT_BREADTH },
    spend: { policy: null, max_tokens: null, max_usd: null, status: 'UNENFORCED' },
    gates: { ...BUILTIN_GATE_DEFAULTS, source: 'builtin-default' },
    convergence: {
      converged: { ...BUILTIN_CONVERGENCE_DEFAULT.converged },
      diverging: { ...BUILTIN_CONVERGENCE_DEFAULT.diverging },
      overridden: false
    },
    tier_order: [...BUILTIN_TIER_ORDER],
    roles,
    stages: builtinStagesDefault(),
    strategy: { ...BUILTIN_STRATEGY_DEFAULT },
    // Empty role/stage preferences are intentional when no policy exists;
    // crossValidate uses this marker to distinguish them from a malformed v2
    // policy that silently omitted all executable actors.
    decodedFrom: 'absent'
  }
}

// ---------------------------------------------------------------------------
// Shape detection
// ---------------------------------------------------------------------------

/**
 * Detect which `.devflow.toml` shape a parsed document is, from controlling
 * markers only (never [tier.*], which can occur in either older shape).
 * Returns { shape: "v2"|"v1"|"legacy"|"mixed"|"unknown", markers: string[] }.
 */
export function detectShape(doc) {
  const hasV2 = doc.schema_version === 2

  const rigorTable = doc.rigor && typeof doc.rigor === 'object' ? doc.rigor : {}
  const rigorLevels = Object.keys(rigorTable)

  const hasRigorOrder = Array.isArray(doc.rigor_order)
  const hasReviewTables = !!(
    doc.review &&
    typeof doc.review === 'object' &&
    Object.keys(doc.review).length > 0
  )
  const hasReviewPointer = rigorLevels.some((l) => typeof rigorTable[l]?.review === 'string')
  const v1Markers = []
  if (hasRigorOrder) v1Markers.push('rigor_order')
  if (hasReviewTables) v1Markers.push('[review.*]')
  if (hasReviewPointer) v1Markers.push('[rigor.<level>].review pointer')
  const hasV1 = hasRigorOrder && hasReviewTables && hasReviewPointer

  const directCapFields = ['challenge', 'review', 'shepherd', 'min_rounds']
  const hasDirectCaps = rigorLevels.some((l) => {
    const level = rigorTable[l]
    return level && directCapFields.every((f) => typeof level[f] === 'number')
  })
  // Any ONE direct-cap field — not only a complete four-field set — is
  // itself a legacy marker for the mixed-with-v2 check below. Shepherd-
  // stage cloud finding (round 2, about round 1's own single-stray-marker
  // fix), confirmed: hasDirectCaps requires all four fields together, so a
  // lone `challenge = 99` under a v2 [rigor.standard] registered as no
  // marker at all — an incomplete legacy marker set at the level of
  // individual fields, exactly what specs/config/spec.md's "incomplete"
  // text already covers, not only a complete alternate-shape table.
  // Presence, not value type: a wrong-typed legacy cap (`challenge = "3"`)
  // is exactly as much a marker as a correctly-typed one — shepherd-stage
  // cloud finding (round 4), confirmed: requiring `typeof === "number"`
  // here meant `detect` reported pure v2 for a partially-migrated file
  // whose stray legacy field happened to be malformed, silently ignoring
  // it rather than refusing the file as mixed/incomplete. Value-type
  // validation for a GENUINE v2 field is a separate, already-enforced
  // concern (resolveRounds's own numeric-type checks); this is only about
  // whether the marker is present at all.
  const hasAnyDirectCapField = rigorLevels.some((l) => {
    const level = rigorTable[l]
    return level && directCapFields.some((f) => f in level)
  })
  const hasDefaultMethod = typeof doc.default_method === 'string'
  const hasMethodTable = !!(doc.method && typeof doc.method === 'object')
  const legacyMarkers = []
  if (hasAnyDirectCapField)
    legacyMarkers.push('[rigor.<level>] direct cap field(s) (challenge/review/shepherd/min_rounds)')
  if (hasDefaultMethod) legacyMarkers.push('default_method')
  if (hasMethodTable) legacyMarkers.push('[method]')
  const hasLegacy = hasDirectCaps && hasDefaultMethod && hasMethodTable

  // specs/config/spec.md: "A mixed OR INCOMPLETE marker set SHALL be
  // rejected... not guessed into either shape" — review round 3 closed the
  // COMPLETE-old-shape-alongside-v2 case, but a single coexisting older
  // marker is exactly the spec's "incomplete" case too, not only "every
  // marker of some other complete shape." Shepherd-stage cloud finding,
  // confirmed: checking hasV1/hasLegacy (each requiring ALL of that
  // shape's own markers) let a lone stray marker — e.g. `default_method`
  // alone, with neither direct caps nor a `[method]` table — coexist with
  // `schema_version = 2` and still resolve as pure v2, even though the
  // file literally carries markers from two different shape vocabularies
  // at once. `rigor_order` is the one exception: v2 itself REQUIRES it
  // (resolveRigorLevel), so its mere presence can never signal v1 the way
  // `[review.*]`/the `.review` pointer genuinely do — counting it here
  // would make every valid v2 policy "mixed" (self-caught in this same
  // fix: the hand-rolled test-dev-flow-exit.sh breadth-shortfall check
  // constructs a v2 policy and immediately hit exactly this).
  const hasV1ExclusiveMarker = hasReviewTables || hasReviewPointer
  if (hasV2 && (hasV1ExclusiveMarker || legacyMarkers.length > 0)) {
    return { shape: 'mixed', markers: ['schema_version = 2', ...v1Markers, ...legacyMarkers] }
  }
  if (hasV2) return { shape: 'v2', markers: ['schema_version = 2'] }
  if (hasV1 && hasLegacy) return { shape: 'mixed', markers: [...v1Markers, ...legacyMarkers] }
  if (hasV1) return { shape: 'v1', markers: v1Markers }
  if (hasLegacy) return { shape: 'legacy', markers: legacyMarkers }

  const partial = [...v1Markers, ...legacyMarkers]
  return { shape: 'unknown', markers: partial }
}

const MIGRATION_DIRECTION =
  'migrate to schema_version = 2 with [rounds.*], [breadth.*], [gates], [convergence], [role.*], and [stage.*] (harmon-init#1081 owns the template)'

export function shapeRefusalMessage(detection, { forOperating = true } = {}) {
  const markers = detection.markers.length > 0 ? detection.markers.join(', ') : 'none'
  const scope = forOperating ? 'the operating .devflow.toml' : 'this .devflow.toml'
  return `${scope} is not schema_version 2 (detected shape: ${detection.shape}; markers found: ${markers}) — ${MIGRATION_DIRECTION}`
}

/** Require a v2 shape for the *operating* policy; throws PolicyError otherwise. */
export function requireOperatingV2(doc) {
  const detection = detectShape(doc)
  if (detection.shape !== 'v2') {
    throw new PolicyError(shapeRefusalMessage(detection, { forOperating: true }))
  }
  return detection
}

// ---------------------------------------------------------------------------
// v2 resolution
// ---------------------------------------------------------------------------

function resolveRigorLevel(doc, requestedRigor) {
  const order = doc.rigor_order
  if (!Array.isArray(order) || order.length === 0) {
    throw new PolicyError('policy has no rigor_order ranking')
  }
  if (
    new Set(order).size !== order.length ||
    order.some((level) => typeof level !== 'string' || level.length === 0)
  ) {
    throw new PolicyError("policy's rigor_order must contain unique non-empty rigor level names")
  }
  if (doc.rigor === null || typeof doc.rigor !== 'object' || Array.isArray(doc.rigor)) {
    throw new PolicyError('policy has no [rigor.*] tables')
  }
  const rigorNames = Object.keys(doc.rigor)
  if (
    rigorNames.length !== order.length ||
    order.some((level) => !Object.hasOwn(doc.rigor, level))
  ) {
    throw new PolicyError(
      `policy's rigor_order must be an exact permutation of [rigor.*] tables; ` +
        `order=[${order.join(', ')}], tables=[${rigorNames.join(', ')}]`
    )
  }
  // default_rigor is a REQUIRED top-level v2 field (specs/dev-flow-v2.md
  // "Top level: schema_version = 2, default_rigor, default_strategy, and
  // two rankings"), not merely a fallback consulted only when no override
  // is given — post-merge cloud review, confirmed: `requestedRigor ||
  // doc.default_rigor` short-circuited on ANY override, so a policy with a
  // missing or invalid default_rigor resolved successfully under
  // `--rigor standard` and then failed as soon as a later run had no
  // override. Validated independently of whether this call happens to
  // carry an override.
  if (!doc.default_rigor) throw new PolicyError('policy has no default_rigor')
  if (!order.includes(doc.default_rigor)) {
    throw new PolicyError(
      `policy's default_rigor "${doc.default_rigor}" is not in rigor_order (${order.join(', ')})`
    )
  }
  const level = requestedRigor || doc.default_rigor
  if (!order.includes(level)) {
    throw new PolicyError(`rigor level "${level}" is not in rigor_order (${order.join(', ')})`)
  }
  const profile = doc.rigor?.[level]
  if (!profile || typeof profile !== 'object') {
    throw new PolicyError(`rigor level "${level}" has no [rigor.${level}] table`)
  }
  return { level, profile, order }
}

function validateRoundPolicy(policyName, table) {
  const errorPath = `[rounds.${policyName}]`
  requireClosedTable(table, ROUND_KEYS, [], errorPath)
  for (const key of ROUND_KEYS) {
    if (key === 'wall_clock_min') requirePositiveInt(table[key], key, errorPath)
    else requireNonNegativeInt(table[key], key, errorPath)
  }
  if (table.min_rounds > table.challenge || table.min_rounds > table.review) {
    throw new PolicyError(
      `${errorPath}.min_rounds (${table.min_rounds}) must be <= challenge (${table.challenge}) and review (${table.review})`
    )
  }
}

function validateBreadthPolicy(policyName, table) {
  const errorPath = `[breadth.${policyName}]`
  requireClosedTable(table, BREADTH_KEYS, [], errorPath)
  for (const key of BREADTH_KEYS) requirePositiveInt(table[key], key, errorPath)
}

function validateSpendPolicy(policyName, table) {
  const errorPath = `[spend.${policyName}]`
  requireClosedTable(table, [], SPEND_KEYS, errorPath)
  if (table.max_tokens !== undefined) requirePositiveInt(table.max_tokens, 'max_tokens', errorPath)
  if (
    table.max_usd !== undefined &&
    !(typeof table.max_usd === 'number' && Number.isFinite(table.max_usd) && table.max_usd > 0)
  ) {
    throw new PolicyError(
      `${errorPath}: "max_usd" must be a finite positive number, got ${JSON.stringify(table.max_usd)}`
    )
  }
}

function validatePolicyFamily(family, familyName, validateTable) {
  if (family === null || typeof family !== 'object' || Array.isArray(family)) {
    throw new PolicyError(`policy has no [${familyName}.*] tables`)
  }
  const entries = Object.entries(family)
  if (entries.length === 0) throw new PolicyError(`policy has no [${familyName}.*] tables`)
  for (const [policyName, table] of entries) validateTable(policyName, table)
}

function validatePolicyFamilies(doc) {
  validatePolicyFamily(doc.rounds, 'rounds', validateRoundPolicy)
  validatePolicyFamily(doc.breadth, 'breadth', validateBreadthPolicy)
  if (doc.spend !== undefined) validatePolicyFamily(doc.spend, 'spend', validateSpendPolicy)
}

function resolveRounds(doc, profile, levelName) {
  const policyName = profile.rounds
  if (typeof policyName !== 'string') {
    throw new PolicyError(`[rigor.${levelName}] has no "rounds" pointer`)
  }
  const table = doc.rounds?.[policyName]
  if (!table || typeof table !== 'object') {
    throw new PolicyError(`[rounds.${policyName}] is missing (pointed to by [rigor.${levelName}])`)
  }
  validateRoundPolicy(policyName, table)
  const rounds = { policy: policyName }
  // remediation/wall_clock_min are required v2 fields here, not optional —
  // BUILTIN_REMEDIATION_FALLBACK/BUILTIN_WALL_CLOCK_MIN_FALLBACK exist for
  // decodeLegacyRounds/decodeV1Rounds's OWN separately-constructed rounds
  // object (neither of which calls this function at all), not for this,
  // the operating-v2-only path — this function has exactly one call site,
  // resolveV2. Shepherd-stage cloud finding (round 3), confirmed: the
  // comment's stated intent (fallback for historical decoding) never
  // matched the actual call graph, so a v2 rounds table missing either
  // field silently got a historical-decoder default instead of being
  // rejected, letting a typo change how many fixes or how much runtime is
  // permitted with no validation error.
  for (const key of [
    'challenge',
    'review',
    'integration',
    'min_rounds',
    'remediation',
    'wall_clock_min'
  ]) {
    if (typeof table[key] !== 'number') {
      throw new PolicyError(`[rounds.${policyName}] is missing numeric "${key}"`)
    }
    rounds[key] = table[key]
  }
  // specs/config/spec.md: "The forensic rounds policy SHALL require at
  // least two rounds before the empty-round shortcut can end a confidence
  // stage" — review round 3, confirmed: forensic accepted min_rounds 0 or
  // 1 like any other level, letting its first empty round exit through the
  // shortcut the ladder's strongest level is specifically meant to forbid.
  if (
    levelName === 'forensic' &&
    rounds.challenge > 0 &&
    rounds.review > 0 &&
    rounds.min_rounds < 2
  ) {
    throw new PolicyError(
      `[rounds.${policyName}]: forensic rigor requires min_rounds >= 2 (got ${rounds.min_rounds})`
    )
  }
  return rounds
}

function resolveBreadth(doc, profile, levelName) {
  const policyName = profile.breadth
  if (typeof policyName !== 'string') {
    throw new PolicyError(`[rigor.${levelName}] has no "breadth" pointer`)
  }
  const table = doc.breadth?.[policyName]
  if (!table || typeof table !== 'object') {
    throw new PolicyError(`[breadth.${policyName}] is missing (pointed to by [rigor.${levelName}])`)
  }
  validateBreadthPolicy(policyName, table)
  const breadth = { policy: policyName }
  for (const key of BREADTH_KEYS) {
    if (typeof table[key] !== 'number') {
      throw new PolicyError(`[breadth.${policyName}] is missing numeric "${key}"`)
    }
    breadth[key] = table[key]
  }
  return breadth
}

function resolveSpend(doc, profile) {
  const policyName = profile.spend
  if (typeof policyName !== 'string') {
    return { policy: null, max_tokens: null, max_usd: null, status: 'UNENFORCED' }
  }
  const table = doc.spend?.[policyName]
  if (!table || typeof table !== 'object') {
    throw new PolicyError(`[spend.${policyName}] is missing (named by [rigor.*].spend)`)
  }
  validateSpendPolicy(policyName, table)
  // A present-but-invalid ceiling must not silently become `null` (read as
  // "absent") or be trusted as-is — shepherd-stage cloud finding (round 2,
  // about pre-existing code), confirmed: `status: "UNENFORCED"` today does
  // not make this a dead value; it is a shared resolved-policy field later
  // dispatchers already consume, so a negative/fractional/non-finite
  // zero/negative/fractional max_tokens or a non-positive/non-finite/non-number
  // max_usd must be rejected, not disappear, matching the portable schema.
  return {
    policy: policyName,
    max_tokens: typeof table.max_tokens === 'number' ? table.max_tokens : null,
    max_usd: typeof table.max_usd === 'number' ? table.max_usd : null,
    status: 'UNENFORCED'
  }
}

const GATE_SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*(?::[a-z0-9]+(?:-[a-z0-9]+)*)*$/

function resolveGates(doc, { allowMissing = false, fallback = null } = {}) {
  const gates = doc.gates
  if (!gates || typeof gates !== 'object') {
    if (allowMissing && fallback) return { ...fallback, source: 'built-in-default' }
    throw new PolicyError('policy has no [gates] table')
  }
  const resolved = { source: 'policy' }
  for (const key of GATE_KEYS) {
    const value = gates[key]
    if (typeof value !== 'string' || value.length === 0) {
      throw new PolicyError(`[gates] is missing string "${key}"`)
    }
    if (!GATE_SLUG_RE.test(value)) {
      throw new PolicyError(
        `[gates].${key} = "${value}" is not a bare Taskfile target slug (no spaces, slashes, or arguments allowed)`
      )
    }
    resolved[key] = value
  }
  const docsOnly = gates.docs_only_paths
  if (
    !Array.isArray(docsOnly) ||
    docsOnly.length === 0 ||
    docsOnly.some((p) => typeof p !== 'string')
  ) {
    throw new PolicyError('[gates].docs_only_paths must be a non-empty array of strings')
  }
  resolved.docs_only_paths = docsOnly
  return resolved
}

// specs/dev-flow-v2.md "Convergence model v0" example TOML: `count_rising`
// takes `increases`, `provenance_share` takes `min` (+ optional
// `exclude_classes`); `no_gating_findings`/`repeat_after_fix` take none.
// Unvalidated (challenge round 3, confirmed), a degenerate parameter — e.g.
// `provenance_share.min = 2` — parses cleanly but can never be satisfied,
// silently defeating a divergence predicate it was configured to catch, and
// `count_rising` with a non-positive `increases` drives undefined arithmetic
// in the evaluator.
const PREDICATE_PARAM_VALIDATORS = {
  count_rising(entry, errorPath) {
    if (!Number.isInteger(entry.increases) || entry.increases < 1) {
      throw new PolicyError(
        `${errorPath}: "increases" must be a positive integer, got ${JSON.stringify(entry.increases)}`
      )
    }
  },
  provenance_share(entry, errorPath) {
    if (
      typeof entry.min !== 'number' ||
      !Number.isFinite(entry.min) ||
      entry.min < 0 ||
      entry.min > 1
    ) {
      throw new PolicyError(
        `${errorPath}: "min" must be a number in [0, 1], got ${JSON.stringify(entry.min)}`
      )
    }
    if (entry.exclude_classes !== undefined) {
      const bad =
        !Array.isArray(entry.exclude_classes) ||
        entry.exclude_classes.length === 0 ||
        new Set(entry.exclude_classes).size !== entry.exclude_classes.length ||
        entry.exclude_classes.some((c) => !FINDING_CLASSES.has(c))
      if (bad) {
        throw new PolicyError(
          `${errorPath}: "exclude_classes" must be an array drawn from (${[...FINDING_CLASSES].join(', ')}), got ${JSON.stringify(entry.exclude_classes)}`
        )
      }
    }
  }
}
// Every catalog predicate's own allowed key set, `predicate` included —
// shepherd-stage cloud finding, confirmed: PREDICATE_PARAM_VALIDATORS only
// ever checked its OWN expected keys were present and valid, never that no
// OTHER keys were present, so e.g. `{predicate = "no_gating_findings",
// increases = 99}` resolved cleanly with `increases` silently ignored — a
// misspelled parameter (or one copied from the wrong predicate) can look
// like it tightens convergence while having no effect at all.
const PREDICATE_ALLOWED_KEYS = {
  no_gating_findings: new Set(['predicate']),
  provenance_share: new Set(['predicate', 'min', 'exclude_classes']),
  count_rising: new Set(['predicate', 'increases']),
  repeat_after_fix: new Set(['predicate'])
}

// Recursive: a composition list entry is either a leaf (`{predicate, ...}`)
// or a nested `{any: [...]} | {all: [...]}` node — specs/dev-flow-v2.md
// normatively incorporates "nested any or all composition" (exit-computation
// spec.md "Scenario: A policy composes predicates from the anchor catalog").
// Round 3 (confirmed): the prior flat-only shape rejected every nested
// composition outright, so no policy could actually use the grammar the spec
// requires every implementation to accept.
function validatePredicateExpr(expr, errorPath) {
  if (!expr || typeof expr !== 'object') throw new PolicyError(`${errorPath} must be an object`)
  const kinds = Object.keys(expr).filter((k) => k === 'all' || k === 'any')
  if (kinds.length !== 1) throw new PolicyError(`${errorPath} must have exactly one of "all"/"any"`)
  const kind = kinds[0]
  const extraCompositionKeys = Object.keys(expr).filter((key) => key !== kind)
  if (extraCompositionKeys.length > 0) {
    throw new PolicyError(
      `${errorPath} has unsupported composition key(s): ${extraCompositionKeys.join(', ')}`
    )
  }
  const list = expr[kind]
  if (!Array.isArray(list) || list.length === 0)
    throw new PolicyError(`${errorPath}.${kind} must be a non-empty array`)
  // A predicate name appearing twice in one composition list is rejected
  // outright, not silently collapsed. Shepherd-stage cloud finding (round
  // 2, about round 1's own checkTightenOnly rewrite — but the underlying
  // Map-based `new Map(list.map(e => [e.predicate, e]))` keying predates
  // it), confirmed: keying by predicate name silently kept only the LAST
  // occurrence of a repeated predicate, so checkTightenOnly's base/override
  // comparison never saw the earlier one at all — a base list carrying a
  // predicate twice with different parameters could have its override
  // compared against only one of them, hiding a genuine loosening in the
  // occurrence the comparison never looks at.
  const seenPredicates = new Set()
  for (const entry of list) {
    if (entry && typeof entry === 'object' && typeof entry.predicate === 'string') {
      if (seenPredicates.has(entry.predicate)) {
        throw new PolicyError(
          `${errorPath}.${kind} lists predicate "${entry.predicate}" more than once — each predicate may appear at most once per composition list`
        )
      }
      seenPredicates.add(entry.predicate)
    }
  }
  for (const [i, entry] of list.entries()) {
    const entryPath = `${errorPath}.${kind}[${i}]`
    if (!entry || typeof entry !== 'object') {
      throw new PolicyError(`${entryPath} must be an object`)
    }
    const nestedKinds = Object.keys(entry).filter((k) => k === 'all' || k === 'any')
    if (nestedKinds.length > 0) {
      if (typeof entry.predicate === 'string') {
        throw new PolicyError(
          `${entryPath} must not mix "predicate" with nested "any"/"all" composition`
        )
      }
      validatePredicateExpr(entry, entryPath) // recurse; throws on any nested problem
      continue
    }
    if (typeof entry.predicate !== 'string') {
      throw new PolicyError(
        `${entryPath} must be an object with a "predicate" string, or a nested "any"/"all" composition`
      )
    }
    if (!PREDICATES.has(entry.predicate)) {
      throw new PolicyError(
        `${entryPath}.predicate "${entry.predicate}" is not in the v0 catalog (${[...PREDICATES].join(', ')})`
      )
    }
    PREDICATE_PARAM_VALIDATORS[entry.predicate]?.(entry, entryPath)
    const allowedKeys = PREDICATE_ALLOWED_KEYS[entry.predicate]
    const extraKeys = Object.keys(entry).filter((k) => !allowedKeys.has(k))
    if (extraKeys.length > 0) {
      throw new PolicyError(
        `${entryPath}: predicate "${entry.predicate}" does not accept parameter(s) ${extraKeys.join(', ')}`
      )
    }
  }
  return { kind, list }
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map((entry) => canonicalJson(entry)).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(',')}}`
  }
  return JSON.stringify(value)
}

function checkTightenOnly(base, over, stageName, errorPath) {
  if (base.kind !== over.kind) {
    throw new PolicyError(
      `${errorPath}: rigor override changes composition from "${base.kind}" to "${over.kind}", which is not a defined tightening move`
    )
  }
  const kind = base.kind
  // A nested any/all node has no `.predicate` identity to key a tighten-only
  // comparison by (every nested node would collide under the same
  // `undefined` key), so it is matched between base and override by full
  // structural identity instead — specs/dev-flow-v2.md (the recursive
  // composition section): "adding a whole new nested subtree to a
  // converged all list or a diverging any list is exactly as well-defined
  // a tightening move as adding a flat leaf to either", and likewise for
  // removal; "what has no defined direction, and is refused, is an
  // override that changes the internal structure of a nested subtree the
  // base already carries." Shepherd-stage cloud finding, confirmed: this
  // lane's own earlier fix (round 2, closing the prior blanket "ANY nested
  // entry anywhere is refused" bug) stopped at "unchanged nested entries
  // don't count as added/removed" and never wired a genuinely added or
  // removed nested subtree into the SAME directional addTightens/
  // removeTightens check flat entries already get below — so it still
  // refused an added-in-a-tightening-position nested subtree outright.
  // Folding nested add/remove into the SAME added/removed arrays flat
  // entries use (keyed by structural identity instead of `.predicate`)
  // fixes that: a pure add is checked by addTightens like any flat leaf; a
  // pure remove is checked by removeTightens (never true for either stage
  // this catalog defines today, so removal stays refused, matching prior
  // behavior); a CHANGED subtree (present in base, replaced by a
  // different one in override) decomposes into a remove of the old shape
  // plus an add of the new one — its remove half is refused by the same
  // removeTightens=false rule, so it is refused overall without a special
  // case, matching the spec's "no defined direction" text.
  const isNested = (e) => !e || typeof e !== 'object' || typeof e.predicate !== 'string'
  const baseFlat = base.list.filter((e) => !isNested(e))
  const overFlat = over.list.filter((e) => !isNested(e))
  const baseNested = base.list.filter(isNested)
  const overNested = over.list.filter(isNested)
  const nestedKey = (e) => `nested:${canonicalJson(e)}`
  const baseNestedKeys = new Set(baseNested.map(nestedKey))
  const overNestedKeys = new Set(overNested.map(nestedKey))
  const nestedAdded = [...overNestedKeys].filter((k) => !baseNestedKeys.has(k))
  const nestedRemoved = [...baseNestedKeys].filter((k) => !overNestedKeys.has(k))

  const baseByName = new Map(baseFlat.map((e) => [e.predicate, e]))
  const overByName = new Map(overFlat.map((e) => [e.predicate, e]))
  const added = [...overByName.keys()].filter((k) => !baseByName.has(k)).concat(nestedAdded)
  const removed = [...baseByName.keys()].filter((k) => !overByName.has(k)).concat(nestedRemoved)

  // converged: all-add / any-remove tightens. diverging: any-add / all-remove tightens.
  const addTightens =
    (stageName === 'converged' && kind === 'all') || (stageName === 'diverging' && kind === 'any')
  const removeTightens =
    (stageName === 'converged' && kind === 'any') || (stageName === 'diverging' && kind === 'all')

  if (added.length > 0 && !addTightens) {
    throw new PolicyError(
      `${errorPath}: adding ${added.join(', ')} to a "${kind}"-composed ${stageName} list loosens it`
    )
  }
  if (removed.length > 0 && !removeTightens) {
    throw new PolicyError(
      `${errorPath}: removing ${removed.join(', ')} from a "${kind}"-composed ${stageName} list loosens it`
    )
  }

  // Per-parameter comparison for entries present in BOTH lists. Only a
  // verified numeric raise (converged) or lower (diverging) is a
  // recognized tightening move; every other kind of change — dropping a
  // parameter the base declared, adding one the base never had, or
  // changing a non-numeric value (e.g. widening exclude_classes) — has no
  // provably-safe direction, and "anything else is loosening" (the anchor
  // spec's own rule) means it is refused rather than silently accepted.
  // The comparison walks the UNION of base and override keys, not just the
  // override's own — a dropped key is otherwise invisible to a loop that
  // only iterates what the override still declares.
  for (const [name, overEntry] of overByName) {
    const baseEntry = baseByName.get(name)
    if (!baseEntry) continue
    const allKeys = new Set([...Object.keys(baseEntry), ...Object.keys(overEntry)])
    for (const key of allKeys) {
      if (key === 'predicate') continue
      const bv = baseEntry[key]
      const ov = overEntry[key]
      if (JSON.stringify(bv) === JSON.stringify(ov)) continue
      if (typeof bv === 'number' && typeof ov === 'number') {
        const raises = ov > bv
        const wantsRaise = stageName === 'converged'
        if (raises === wantsRaise) continue
        throw new PolicyError(
          `${errorPath}: ${name}.${key} moved from ${bv} to ${ov}, which loosens ${stageName}`
        )
      }
      throw new PolicyError(
        `${errorPath}: ${name}.${key} changed from ${JSON.stringify(bv)} to ${JSON.stringify(ov)} — only a verified numeric ${
          stageName === 'converged' ? 'raise' : 'lower'
        } is a recognized tightening move for a non-identical parameter`
      )
    }
  }
}

function resolveConvergence(doc, levelName) {
  const base = doc.convergence
  if (!base || typeof base !== 'object' || Array.isArray(base)) {
    throw new PolicyError('policy has no [convergence] table with converged/diverging')
  }
  requireClosedTable(base, ['converged', 'diverging'], [], '[convergence]')
  const baseConverged = validatePredicateExpr(base.converged, '[convergence].converged')
  const baseDiverging = validatePredicateExpr(base.diverging, '[convergence].diverging')

  const overrideTable = doc.rigor?.[levelName]?.convergence
  if (!overrideTable) {
    return { converged: baseConverged, diverging: baseDiverging, overridden: false }
  }
  requireClosedTable(
    overrideTable,
    [],
    ['converged', 'diverging'],
    `[rigor.${levelName}.convergence]`
  )
  if (!Object.hasOwn(overrideTable, 'converged') && !Object.hasOwn(overrideTable, 'diverging')) {
    throw new PolicyError(
      `[rigor.${levelName}.convergence] must override at least one of converged/diverging`
    )
  }
  const overConverged = overrideTable.converged
    ? validatePredicateExpr(overrideTable.converged, `[rigor.${levelName}.convergence].converged`)
    : baseConverged
  const overDiverging = overrideTable.diverging
    ? validatePredicateExpr(overrideTable.diverging, `[rigor.${levelName}.convergence].diverging`)
    : baseDiverging

  if (overrideTable.converged)
    checkTightenOnly(baseConverged, overConverged, 'converged', `[rigor.${levelName}.convergence]`)
  if (overrideTable.diverging)
    checkTightenOnly(baseDiverging, overDiverging, 'diverging', `[rigor.${levelName}.convergence]`)

  return { converged: overConverged, diverging: overDiverging, overridden: true }
}

function resolveRoles(doc, profile, levelName, tierOrder) {
  if (!doc.role || typeof doc.role !== 'object' || Array.isArray(doc.role)) {
    throw new PolicyError('policy has no [role.*] tables')
  }
  const missingRoles = ROLES.filter((role) => !Object.hasOwn(doc.role, role))
  const extraRoles = Object.keys(doc.role).filter((role) => !ROLES.includes(role))
  if (missingRoles.length > 0 || extraRoles.length > 0) {
    throw new PolicyError(
      '[role.*] tables must match the five-role catalog exactly' +
        `${missingRoles.length > 0 ? `; missing: ${missingRoles.join(', ')}` : ''}` +
        `${extraRoles.length > 0 ? `; unsupported: ${extraRoles.join(', ')}` : ''}`
    )
  }

  const result = {}
  for (const role of ROLES) {
    const profileKey = `${role}_tier`
    const roleTable = doc.role[role]
    const errorPath = `[role.${role}]`
    requireClosedTable(roleTable, ['tier', 'families'], ['harnesses'], errorPath)
    if (!tierOrder.includes(roleTable.tier)) {
      throw new PolicyError(
        `${errorPath}.tier must be a concrete tier in [${tierOrder.join(', ')}], got ${JSON.stringify(roleTable.tier)}`
      )
    }
    for (const key of ['families', 'harnesses']) {
      if (key === 'harnesses' && !Object.hasOwn(roleTable, key)) continue
      const values = roleTable[key]
      if (
        !Array.isArray(values) ||
        values.length === 0 ||
        values.some((value) => typeof value !== 'string' || value.length === 0)
      ) {
        throw new PolicyError(`${errorPath}.${key} must be a non-empty array of strings`)
      }
      if (new Set(values).size !== values.length) {
        throw new PolicyError(`${errorPath}.${key} must not contain duplicates`)
      }
    }
    const fromProfile = profile[profileKey]
    const tier = fromProfile !== undefined ? fromProfile : roleTable.tier
    if (typeof tier !== 'string') {
      throw new PolicyError(
        `role "${role}" has no resolvable tier: [rigor.${levelName}].${profileKey} and [role.${role}].tier are both absent`
      )
    }
    if (Array.isArray(tierOrder) && !tierOrder.includes(tier)) {
      throw new PolicyError(
        `role "${role}" tier "${tier}" is not in tier_order (${tierOrder.join(', ')})`
      )
    }
    result[role] = {
      tier,
      source: fromProfile !== undefined ? 'rigor-profile' : 'role-baseline',
      families: roleTable.families,
      harnesses: roleTable.harnesses || []
    }
  }
  return result
}

// Present-but-wrong-type SHALL be rejected, never silently widened to the
// absent-key default — review round 3, confirmed: a malformed
// `[stage.implement].pool = "local"` (a string, not an array — a plausible
// typo for a single-entry allowlist) previously became `null` ("no
// restriction", i.e. every implementer-capable harness eligible), turning
// a mistaken narrow allowlist into the WIDEST possible one. Absent stays
// the documented default (`fallback`); present-and-wrong-type is a
// PolicyError.
function resolveStageArray(value, label, fallback) {
  if (value === undefined) return fallback
  if (!Array.isArray(value)) {
    throw new PolicyError(`${label} must be an array, got ${JSON.stringify(value)}`)
  }
  return value
}

function resolveStages(doc) {
  requireClosedTable(doc.stage, STAGES, [], '[stage]')
  const result = {}
  for (const stage of STAGES) {
    const table = doc.stage?.[stage]
    requireClosedTable(table, [], ['finders', 'finder_fallbacks', 'pool'], `[stage.${stage}]`)
    const finders = resolveStageArray(table?.finders, `[stage.${stage}].finders`, [])
    // Each entry in `finders` is its own all-of primary slot (dev-flow-exit.mjs
    // keys logical-round assembly by slot name) — a duplicate slug collapses
    // two nominally distinct slots onto the same map key. Shepherd-stage
    // cloud finding, confirmed: `finders = ["codex-cli", "codex-cli"]`
    // resolved cleanly, let ONE real pass silently satisfy BOTH nominal
    // slots, and breadth's worst-case calculation (finders.length * ...)
    // charged for two slots a single pass could actually fill.
    const dup = finders.find((f, i) => finders.indexOf(f) !== i)
    if (dup !== undefined) {
      throw new PolicyError(
        `[stage.${stage}].finders contains duplicate primary slot "${dup}" — each finder may fill at most one primary slot`
      )
    }
    const finderFallbacks = resolveStageArray(
      table?.finder_fallbacks,
      `[stage.${stage}].finder_fallbacks`,
      []
    )
    const duplicateFallback = finderFallbacks.find(
      (finder, index) => finderFallbacks.indexOf(finder) !== index
    )
    if (duplicateFallback !== undefined) {
      throw new PolicyError(
        `[stage.${stage}].finder_fallbacks contains duplicate finder "${duplicateFallback}"`
      )
    }
    // A single-primary stage's own primary finder listed in its OWN
    // finder_fallbacks is unconditionally dead configuration — post-merge
    // cloud review, confirmed: dev-flow-exit.mjs's assembleLogicalRounds
    // already refuses this at runtime (`finder !== slot`, a substitute
    // must differ from the slot it fills), so with exactly one primary
    // slot the finder can never validly serve as its own fallback,
    // advertising a recovery chain entry that will always be discarded and
    // a breadth budget that pays for an attempt that can only fail. Scoped
    // to the single-primary case specifically (matching the reproduction):
    // with multiple primaries, the same finder in finder_fallbacks is only
    // dead for ITS OWN slot, not necessarily for a different one, which
    // this finding neither reproduced nor asked to reject.
    if (finders.length === 1 && finderFallbacks.includes(finders[0])) {
      throw new PolicyError(
        `[stage.${stage}].finder_fallbacks includes "${finders[0]}", which is also this stage's only primary finder — a finder can never validly substitute for its own slot`
      )
    }
    result[stage] = {
      finders,
      finder_fallbacks: finderFallbacks,
      pool: resolveStageArray(table?.pool, `[stage.${stage}].pool`, null)
    }
  }
  return result
}

function resolveStrategy(doc, requestedStrategy) {
  // default_strategy is a REQUIRED top-level v2 field (specs/dev-flow-v2.md
  // "Top level: schema_version = 2, default_rigor, default_strategy, and..."
  // — the same requirement default_rigor has, validated unconditionally
  // above in resolveRigorLevel for the identical reason: `requestedStrategy
  // || doc.default_strategy` short-circuits on ANY override, so a policy
  // with a missing default_strategy resolved successfully whenever
  // --strategy was supplied. Shepherd-stage cloud finding, confirmed.
  if (!doc.default_strategy) throw new PolicyError('policy has no default_strategy')
  const strategies = doc.strategy
  if (!strategies || typeof strategies !== 'object' || Array.isArray(strategies)) {
    throw new PolicyError('policy has no [strategy.*] tables')
  }
  for (const [profileName, candidate] of Object.entries(strategies)) {
    const errorPath = `[strategy.${profileName}]`
    if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
      throw new PolicyError(`${errorPath} must be a table`)
    }
    const keys = Object.keys(candidate)
    const missing = [...STRATEGY_REQUIRED_KEYS].filter((key) => !Object.hasOwn(candidate, key))
    const extra = keys.filter(
      (key) => !STRATEGY_REQUIRED_KEYS.has(key) && !STRATEGY_OPTIONAL_KEYS.has(key)
    )
    if (missing.length > 0 || extra.length > 0) {
      throw new PolicyError(
        `${errorPath} has invalid keys` +
          `${missing.length > 0 ? `; missing: ${missing.join(', ')}` : ''}` +
          `${extra.length > 0 ? `; unsupported: ${extra.join(', ')}` : ''}`
      )
    }
    if (!STRATEGY_TOPOLOGIES.has(candidate.topology)) {
      throw new PolicyError(
        `${errorPath}.topology has unsupported value ${JSON.stringify(candidate.topology)}`
      )
    }
    if (!STRATEGY_PLANNING.has(candidate.planning)) {
      throw new PolicyError(
        `${errorPath}.planning has unsupported value ${JSON.stringify(candidate.planning)}`
      )
    }
    if (!STRATEGY_DELEGATION.has(candidate.delegation)) {
      throw new PolicyError(
        `${errorPath}.delegation has unsupported value ${JSON.stringify(candidate.delegation)}`
      )
    }
    const multiAgent =
      candidate.topology === 'lead-and-workers' || candidate.topology === 'independent-proposals'
    if (multiAgent && candidate.delegation !== 'required') {
      throw new PolicyError(
        `${errorPath}.topology ${JSON.stringify(candidate.topology)} requires delegation = "required"`
      )
    }
    if (candidate.topology === 'single-agent' && candidate.delegation === 'required') {
      throw new PolicyError(`${errorPath}.topology "single-agent" forbids delegation = "required"`)
    }
    if (
      candidate.delegation === 'none' &&
      candidate.topology !== 'single-agent' &&
      candidate.topology !== 'human-directed'
    ) {
      throw new PolicyError(
        `${errorPath}.delegation = "none" is valid only with topology = "single-agent" or "human-directed"`
      )
    }
    if (!Array.isArray(candidate.human_gates)) {
      throw new PolicyError(`${errorPath}.human_gates must be an array`)
    }
    const invalidGate = candidate.human_gates.find(
      (gate) => typeof gate !== 'string' || !STRATEGY_HUMAN_GATES.has(gate)
    )
    if (invalidGate !== undefined) {
      throw new PolicyError(
        `${errorPath}.human_gates contains unsupported or constitutional gate ${JSON.stringify(invalidGate)}`
      )
    }
    if (new Set(candidate.human_gates).size !== candidate.human_gates.length) {
      throw new PolicyError(`${errorPath}.human_gates must not contain duplicates`)
    }
    if (
      typeof candidate.description !== 'string' ||
      candidate.description.trim() === '' ||
      [...candidate.description].length > 100
    ) {
      throw new PolicyError(
        `${errorPath}.description must be a non-empty string of at most 100 characters`
      )
    }
    if (
      Object.hasOwn(candidate, 'coordination') &&
      candidate.coordination !== 'parallel-when-independent'
    ) {
      throw new PolicyError(`${errorPath}.coordination must be "parallel-when-independent"`)
    }
    if (Object.hasOwn(candidate, 'selection') && candidate.selection !== 'judge') {
      throw new PolicyError(`${errorPath}.selection must be "judge"`)
    }
    for (const booleanKey of ['synthesis', 'distinct_families']) {
      if (Object.hasOwn(candidate, booleanKey) && typeof candidate[booleanKey] !== 'boolean') {
        throw new PolicyError(`${errorPath}.${booleanKey} must be a boolean`)
      }
    }
    if (
      Object.hasOwn(candidate, 'min_agents') &&
      (!Number.isInteger(candidate.min_agents) || candidate.min_agents < 2)
    ) {
      throw new PolicyError(`${errorPath}.min_agents must be an integer >= 2`)
    }
    const topologyFields = {
      coordination: new Set(['lead-and-workers', 'independent-proposals']),
      selection: new Set(['independent-proposals']),
      synthesis: new Set(['independent-proposals']),
      min_agents: new Set(['lead-and-workers', 'independent-proposals']),
      distinct_families: new Set(['independent-proposals'])
    }
    for (const [key, topologies] of Object.entries(topologyFields)) {
      if (Object.hasOwn(candidate, key) && !topologies.has(candidate.topology)) {
        throw new PolicyError(
          `${errorPath}.${key} is not valid for topology ${JSON.stringify(candidate.topology)}`
        )
      }
    }
    const topologyRequired =
      candidate.topology === 'lead-and-workers'
        ? ['coordination', 'min_agents']
        : candidate.topology === 'independent-proposals'
          ? ['selection', 'synthesis', 'min_agents']
          : []
    const missingTopologyFields = topologyRequired.filter((key) => !Object.hasOwn(candidate, key))
    if (missingTopologyFields.length > 0) {
      throw new PolicyError(
        `${errorPath}.topology ${JSON.stringify(candidate.topology)} requires: ${missingTopologyFields.join(', ')}`
      )
    }
  }

  const name = requestedStrategy || doc.default_strategy
  if (!name) return null
  const table = strategies[name]
  if (!table) {
    throw new PolicyError(`strategy "${name}" has no [strategy.${name}] table`)
  }
  // `name` spread AFTER `table` (never before): the selected TOML section
  // key is the authoritative name. A `table` carrying its own `name` field
  // (e.g. `[strategy.council] name = "solo"`) must not be able to overwrite
  // it — spreading `table` first then `name` is what makes the outer
  // assignment win either way. Shepherd-stage cloud finding, confirmed: the
  // old `{ name, ...table }` let exactly that field silently relabel a
  // selected "council" as resolved.strategy.name === "solo", which made
  // crossValidate's council/orchestrate anchor-rule check skip entirely —
  // an incompatible council execution plan would then pass validation.
  return { ...table, name }
}

/**
 * Cross-file validation against the registry and the Taskfile's known
 * target names. `registryDoc` may be null (skip registry-dependent checks —
 * only legitimate when the caller has no registry to check against at all,
 * which is itself reported by the CLI as reduced-confidence, never silent).
 * `taskTargets` is a Set<string> of bare target names, or null.
 */
export function crossValidate(resolved, registryDoc, taskTargets) {
  const errors = []

  for (const key of GATE_KEYS) {
    const target = resolved.gates[key]
    if (taskTargets && !taskTargets.has(target)) {
      errors.push(`[gates].${key} = "${target}" is not an existing Taskfile target`)
    }
  }
  if (!taskTargets) {
    errors.push(
      'indeterminate: no Taskfile target list was supplied — gate slugs could not be checked'
    )
  }

  // Breadth-sufficiency and stage-has-no-finders use only the
  // already-resolved policy shape (rounds, breadth, stages) — no registry
  // needed — so they run UNCONDITIONALLY, independent of whether a
  // registry was supplied. Review round 1 (confirmed): nesting these under
  // `if (registryDoc)` meant a caller that never supplies a registry
  // (dev-flow-exit.mjs, invoked without ever running `devflow-policy.mjs
  // resolve` first) got no breadth validation at all, letting a policy
  // whose breadth cannot cover its own configured fallback chain — which
  // `devflow-policy.mjs resolve` itself would refuse — silently compute
  // exits anyway (exit-computation spec.md's "Scenario: Breadth cannot
  // cover a configured fallback chain" requires this rejected "before any
  // finder is dispatched", not only when a registry happens to be present).
  for (const stage of CONFIDENCE_STAGES) {
    const s = resolved.stages[stage]
    const cap = resolved.rounds[stage]
    if (cap > 0 && s.finders.length > 0) {
      // "for every finder slot" (exit-computation spec) is a per-slot
      // requirement, not an aggregate one: prove the ceiling covers EACH
      // slot independently attempting its own full primary+retry+fallback
      // chain, not just one slot's chain plus a fallback list shared
      // across every slot — the fallback list is preference-ordered per
      // slot, so the true worst case is every slot separately exhausting
      // it (finders.length primary+retry pairs, each also paying the
      // full fallback chain), never the fallback chain amortized once.
      const worstCase = s.finders.length * (2 + s.finder_fallbacks.length)
      if (resolved.breadth.max_agent_runs < worstCase) {
        errors.push(
          `[breadth.${resolved.breadth.policy}].max_agent_runs (${resolved.breadth.max_agent_runs}) cannot cover ` +
            `stage "${stage}"'s worst-case primary+retry+fallback chain (${worstCase} attempts across ${s.finders.length} finder slot(s), ` +
            `${s.finder_fallbacks.length} fallback(s) each)`
        )
      }
    }
    // A merge-base HISTORICAL DECODE (decodeHistoricalPolicy, the only
    // source that sets `decodedFrom`) always reports built-in-default empty
    // stage finders by construction — addendum 6 (registry-sourced finders/
    // roles/tiers for the decode path) is deliberately deferred, low
    // priority. That is a documented, deferred LIMITATION, not the kind of
    // genuine "[stage.*] misconfigured" mistake this check exists to catch
    // on the operating v2 path (or a v2-shaped merge-base, which resolves
    // its OWN real stages via resolveV2 and is not exempted here) — review
    // round 2, confirmed: without this exemption, the breadth/finders check
    // this same round's fix made unconditional (see the comment above) made
    // EVERY historical-decode resolution with a nonzero cap fail cross-
    // validation outright, a regression this fix introduced while closing
    // that gap.
    if (cap > 0 && s.finders.length === 0 && resolved.decodedFrom === undefined) {
      errors.push(
        `[stage.${stage}] has no finders configured but [rounds.${resolved.rounds.policy}].${stage} is ${cap} (> 0)`
      )
    }
  }

  // The same "no finders but nonzero cap" defect the loop above catches for
  // CONFIDENCE_STAGES, but integration is deliberately not one of those
  // (it is not a confidence stage — no challenge/review-style primary+
  // retry+fallback chain claim to breadth-check, so it stays out of the
  // loop above rather than widening CONFIDENCE_STAGES' own meaning).
  // Shepherd-stage cloud finding, confirmed: a positive
  // [rounds.*].integration with no configured [stage.integration] finders
  // exited 0 — the resolved integration stage then has no configured
  // source for checks, the Codex cycle, or thread evidence, so it could
  // never actually obtain the current-head result its own nonzero
  // allowance requires. Same historical-decode exemption as above, for the
  // same reason (addendum 6, deferred).
  const integrationCap = resolved.rounds.integration
  if (
    integrationCap > 0 &&
    resolved.stages.integration.finders.length === 0 &&
    resolved.decodedFrom === undefined
  ) {
    errors.push(
      `[stage.integration] has no finders configured but [rounds.${resolved.rounds.policy}].integration is ${integrationCap} (> 0)`
    )
  }

  // specs/dev-flow-v2.md § strategy (verbatim): "Orchestrate requires
  // max_agent_runs >= min_agents and, only under parallel coordination,
  // max_parallel_agents >= min_agents; sequential dispatch needs only the
  // run coverage... A council requiring N distinct families likewise
  // requires... max_agent_runs >= N, plus max_parallel_agents >= N only
  // under parallel coordination. A council with synthesis = true requires
  // max_agent_runs >= N + 1 for the fresh synthesis dispatch." Registry-
  // independent (only resolved.strategy/resolved.breadth), so — like the
  // checks above — this runs unconditionally. Shepherd-stage cloud finding
  // (round 2, about round 1's own anchor-rule check), confirmed: the
  // original formula — carrying a maintainer-relayed simplification, not
  // this spec's own precise text — required max_parallel_agents >=
  // min_agents and (for council) the +1 run UNCONDITIONALLY, rejecting a
  // valid sequential orchestrate or a non-synthesizing council that the
  // spec's own topology/synthesis-conditional rule permits. Other
  // strategies (solo, plan, plan-approved, human-led) declare no
  // min_agents and are unaffected.
  if (
    resolved.strategy &&
    (resolved.strategy.topology === 'lead-and-workers' ||
      resolved.strategy.topology === 'independent-proposals')
  ) {
    const { name, topology, min_agents: minAgents, synthesis, coordination } = resolved.strategy
    const isCouncil = topology === 'independent-proposals'
    // `coordination`/`synthesis` decide which anchor-rule constraints apply
    // — a malformed value must be REJECTED, never silently read as the
    // absent/default case. Shepherd-stage cloud finding (round 3),
    // confirmed: resolveStrategy spreads a [strategy.*] table with zero
    // validation, so a typo'd `coordination = "parallel-when-indpendent"`
    // or a string `synthesis = "true"` compared with strict `===` silently
    // fell through to "sequential"/"no extra run needed" — the SAFER-
    // LOOKING branch, not the one the author's malformed value actually
    // asked for — letting a required breadth check be bypassed by a typo.
    if (coordination !== undefined && coordination !== 'parallel-when-independent') {
      errors.push(
        `[strategy.${name}].coordination must be "parallel-when-independent" or absent, got ${JSON.stringify(coordination)}`
      )
    }
    if (isCouncil && synthesis !== undefined && typeof synthesis !== 'boolean') {
      errors.push(
        `[strategy.${name}].synthesis must be a boolean, got ${JSON.stringify(synthesis)}`
      )
    }
    if (!Number.isInteger(minAgents) || minAgents < 1) {
      errors.push(
        `[strategy.${name}].min_agents must be a positive integer, got ${JSON.stringify(minAgents)}`
      )
    } else {
      const isParallel = coordination === 'parallel-when-independent'
      const requiredRuns = isCouncil && synthesis === true ? minAgents + 1 : minAgents
      const {
        max_parallel_agents: maxParallel,
        max_agent_runs: maxRuns,
        policy: breadthPolicy
      } = resolved.breadth
      const unmet = []
      if (maxRuns < requiredRuns) unmet.push(`max_agent_runs >= ${requiredRuns}`)
      if (isParallel && maxParallel < minAgents) unmet.push(`max_parallel_agents >= ${minAgents}`)
      if (unmet.length > 0) {
        errors.push(
          `strategy "${name}" (min_agents=${minAgents}, coordination=${coordination ?? 'sequential'}` +
            `${isCouncil ? `, synthesis=${synthesis === true}` : ''}) is incompatible with ` +
            `[breadth.${breadthPolicy}] (max_parallel_agents=${maxParallel}, max_agent_runs=${maxRuns}): needs ${unmet.join(' and ')}`
        )
      }
    }
  }

  if (registryDoc) {
    const familySlugs = new Set((registryDoc.families || []).map((f) => f.slug))
    const familyBySlug = new Map((registryDoc.families || []).map((f) => [f.slug, f]))
    const harnessSlugs = new Set((registryDoc.harnesses || []).map((h) => h.slug))
    const harnessBySlug = new Map((registryDoc.harnesses || []).map((h) => [h.slug, h]))
    const finderBySlug = new Map((registryDoc.finders || []).map((f) => [f.slug, f]))

    for (const [role, r] of Object.entries(resolved.roles)) {
      // Same historical-decode exemption as the stage-finders check above,
      // for the same reason: builtinRolesDefault() always reports empty
      // families on that path by construction (addendum 6's registry-
      // sourced roles is deferred) — a documented, deferred limitation,
      // not a genuine [role.*] misconfiguration on the operating path.
      if (r.families.length === 0 && resolved.decodedFrom === undefined) {
        errors.push(`[role.${role}] has no resolvable family: "families" is empty`)
      }
      for (const fam of r.families) {
        if (!familySlugs.has(fam))
          errors.push(`[role.${role}].families references unknown family "${fam}"`)
      }
      // Family/harness/tier are checked jointly, not as independent slug
      // memberships — shepherd-stage cloud finding, confirmed: existence
      // checks alone let a role select a harness whose registry-declared
      // family_constraint excludes every family the role itself declared,
      // or a harness whose own `roles[]` list does not include this role
      // (e.g. an implementer-only harness assigned to `reviewer`), or a
      // tier no model in any of the role's families can ever provide —
      // every one of those resolves with no cross-validation error today.
      const knownHarnesses = []
      for (const h of r.harnesses) {
        const harness = harnessBySlug.get(h)
        if (!harness) {
          errors.push(`[role.${role}].harnesses references unknown harness "${h}"`)
          continue
        }
        knownHarnesses.push({ slug: h, harness })
        if (Array.isArray(harness.roles) && !harness.roles.includes(role)) {
          errors.push(
            `[role.${role}].harnesses includes "${h}", whose registry entry permits only role(s) ${harness.roles.join(', ')}`
          )
        }
      }
      // Family preference, harness compatibility, and model tier describe
      // ONE executable choice. Checking them as three independent existential
      // claims admits impossible combinations (for example, Gemini satisfies
      // an Antigravity harness while a different Claude family supplies the
      // requested apex model). Preserve ordered-preference semantics — an
      // incompatible early harness may be skipped — but require at least one
      // family/harness/model-tier tuple that can actually run the role.
      const knownFamilies = r.families
        .map((slug) => ({ slug, family: familyBySlug.get(slug) }))
        .filter(({ family }) => family)
      const tierAware = knownFamilies.some(({ family }) => Array.isArray(family.models))
      const tierEligibleFamilies = knownFamilies.filter(({ family }) => {
        if (r.tier === 'adaptive' || !tierAware) return true
        return Array.isArray(family.models) && family.models.some((model) => model.tier === r.tier)
      })
      if (r.tier !== 'adaptive' && knownFamilies.length > 0 && tierEligibleFamilies.length === 0) {
        errors.push(
          `[role.${role}] tier "${r.tier}" is not achievable by any model in its declared families (${r.families.join(', ')})`
        )
      }
      if (knownHarnesses.length > 0 && knownFamilies.length > 0) {
        const hasExecutableTuple = tierEligibleFamilies.some(({ slug: familySlug }) =>
          knownHarnesses.some(({ harness }) => {
            const roleAllowed = !Array.isArray(harness.roles) || harness.roles.includes(role)
            const familyAllowed =
              harness.family_constraint?.kind !== 'fixed' ||
              harness.family_constraint.family === familySlug
            return roleAllowed && familyAllowed
          })
        )
        if (!hasExecutableTuple) {
          errors.push(
            `[role.${role}] has no executable family/harness/tier tuple for tier "${r.tier}": ` +
              `families (${r.families.join(', ') || 'none'}), harnesses (${knownHarnesses.map(({ slug }) => slug).join(', ') || 'none'})`
          )
        }
      }
    }

    for (const [stage, s] of Object.entries(resolved.stages)) {
      const stageRole = {
        implement: 'implementer',
        challenge: 'challenger',
        review: 'reviewer',
        integration: 'integrator'
      }[stage]
      const allFinders = [...s.finders, ...s.finder_fallbacks]
      for (const slug of allFinders) {
        const finder = finderBySlug.get(slug)
        if (!finder) {
          errors.push(`[stage.${stage}] references unknown finder "${slug}"`)
          continue
        }
        if (PRE_PR_STAGES.has(stage) && finder.surface === 'pr-cloud') {
          errors.push(
            `[stage.${stage}] finders/finder_fallbacks includes "${slug}", whose surface is pr-cloud, on a pre-PR stage`
          )
        }
        // A finder's own registry entry may restrict which stages it may
        // serve (agent-registry.json #635/PR #713's finder.stages) — review
        // round 2, confirmed: existence and the pr-cloud check alone let a
        // finder configured for a DIFFERENT stage (e.g. challenge-only) be
        // dispatched here anyway. Absent (registries predating this field)
        // means unrestricted, matching every other additive field in this
        // family.
        if (Array.isArray(finder.stages) && !finder.stages.includes(stage)) {
          errors.push(
            `[stage.${stage}] finders/finder_fallbacks includes "${slug}", whose registry entry permits only stage(s) ${finder.stages.join(', ')}`
          )
        }
        if (finder.surface === 'local-cli') {
          const target = finder.invocation?.target
          if (finder.invocation?.type !== 'taskfile-target' || typeof target !== 'string') {
            errors.push(`[stage.${stage}] local finder "${slug}" has no taskfile-target invocation`)
          } else if (taskTargets && !taskTargets.has(target)) {
            errors.push(
              `[stage.${stage}] local finder "${slug}" invokes missing Taskfile target "${target}"`
            )
          }
        }
      }
      if (s.pool) {
        // Present-but-empty is not the documented "unrestricted" default
        // (that's absent/null) — it is a narrower-than-anything allowlist
        // admitting NO harness at all, so dispatch for this stage can never
        // succeed. Shepherd-stage cloud finding (round 3), confirmed: `[]`
        // is truthy in JS, so `if (s.pool)` already entered this branch,
        // but the loop below trivially passes over zero entries and raises
        // nothing — the stage's dispatch deadlock was never reported as a
        // policy validation error.
        if (s.pool.length === 0) {
          errors.push(
            `[stage.${stage}].pool is present but empty — no harness could ever implement this stage; omit it for "every eligible harness" or list at least one`
          )
        }
        for (const slug of s.pool) {
          const harness = harnessBySlug.get(slug)
          if (!harness) {
            errors.push(`[stage.${stage}].pool references unknown harness "${slug}"`)
          } else if (stageRole && !harness.roles?.includes(stageRole)) {
            errors.push(
              `[stage.${stage}].pool includes "${slug}", whose registry entry permits only role(s) ${harness.roles?.join(', ') || 'none'}; this stage requires role "${stageRole}"`
            )
          }
        }
        const roleConfig = resolved.roles[stageRole]
        const hasExecutablePoolTuple = s.pool.some((slug) => {
          const harness = harnessBySlug.get(slug)
          const preferredHarnesses = roleConfig?.harnesses ?? []
          if (
            !harness ||
            (preferredHarnesses.length > 0 && !preferredHarnesses.includes(slug))
          ) {
            return false
          }
          if (Array.isArray(harness.roles) && !harness.roles.includes(stageRole)) return false
          return roleConfig.families.some((familySlug) => {
            const family = familyBySlug.get(familySlug)
            if (!family) return false
            if (
              Array.isArray(family.models) &&
              !family.models.some((model) => model.tier === roleConfig.tier)
            ) {
              return false
            }
            return (
              harness.family_constraint?.kind !== 'fixed' ||
              harness.family_constraint.family === familySlug
            )
          })
        })
        if (!hasExecutablePoolTuple) {
          errors.push(
            `[stage.${stage}].pool has no executable intersection with [role.${stageRole}] ` +
              `for tier "${roleConfig?.tier}"`
          )
        }
      }
    }

    // specs/dev-flow-v2.md: "A council requiring N distinct families...
    // requires at least N eligible families in the implement-stage pool."
    // Shepherd-stage cloud finding (round 3), confirmed: the pool-harness
    // loop above only proves each slug EXISTS, never how many DISTINCT
    // families the eligible harnesses collectively span — a council
    // requiring 3 distinct families could resolve successfully against a
    // pool of harnesses all fixed to the SAME family, which can never
    // actually dispatch 3 distinct-family proposals. Eligibility also
    // intersects the implementer role's family preferences and resolved
    // tier: registry-wide implementer capability alone does not make a
    // family selectable for this run. Only "fixed" family_constraint
    // harnesses count toward the guaranteed-distinct set — a "broker"
    // harness's actual family is chosen at runtime and cannot be statically
    // proven distinct from another broker's choice.
    if (
      resolved.strategy?.topology === 'independent-proposals' &&
      resolved.strategy.distinct_families === true &&
      Number.isInteger(resolved.strategy.min_agents)
    ) {
      const requiredFamilies = resolved.strategy.min_agents
      const configuredPool = resolved.stages.implement.pool
      const eligibleSlugs = Array.isArray(configuredPool)
        ? configuredPool.filter((slug) => harnessSlugs.has(slug))
        : (registryDoc.harnesses || [])
            .filter((h) => Array.isArray(h.roles) && h.roles.includes('implementer'))
            .map((h) => h.slug)
      const eligibleFamilies = new Set()
      for (const slug of eligibleSlugs) {
        const harness = harnessBySlug.get(slug)
        if (!harness?.roles?.includes('implementer')) continue
        if (harness.family_constraint?.kind !== 'fixed') continue
        const familySlug = harness.family_constraint.family
        if (!resolved.roles.implementer.families.includes(familySlug)) continue
        const family = familyBySlug.get(familySlug)
        if (!family?.models?.some((model) => model.tier === resolved.roles.implementer.tier)) {
          continue
        }
        eligibleFamilies.add(familySlug)
      }
      if (eligibleFamilies.size < requiredFamilies) {
        errors.push(
          `[strategy.${resolved.strategy.name}].distinct_families requires ${requiredFamilies} distinct eligible families in the implement-stage pool, ` +
            `but only ${eligibleFamilies.size} (${[...eligibleFamilies].join(', ') || 'none'}) are available from fixed-family harnesses`
        )
      }
    }
  } else {
    errors.push(
      'indeterminate: no registry was supplied — finders/pools/families/harnesses could not be checked'
    )
  }

  return errors
}

/**
 * Resolve a v2-shaped, already-detected-as-v2 document into the full policy
 * shape. Throws PolicyError on any structural problem. Does not run
 * crossValidate — callers that have a registry/task-target list call that
 * separately and decide whether "indeterminate" blocks them.
 */
export function resolveV2(doc, { rigor: requestedRigor, strategy: requestedStrategy } = {}) {
  requireClosedTable(doc, TOP_LEVEL_REQUIRED_KEYS, TOP_LEVEL_OPTIONAL_KEYS, 'policy')
  if (doc.schema_version !== 2) {
    throw new PolicyError(
      `policy schema_version must be 2, got ${JSON.stringify(doc.schema_version)}`
    )
  }
  // A policy is one selectable catalog, not just today's default. Validate
  // every rounds/breadth/spend table before selecting a rigor so a dormant
  // malformed profile cannot become a delayed production failure when a
  // label selects it later.
  validatePolicyFamilies(doc)
  const { level, profile, order } = resolveRigorLevel(doc, requestedRigor)

  // Validate the whole closed rigor-profile family before selecting values.
  // Otherwise a misspelled control can silently become an absent/false one,
  // even when the malformed profile is not this invocation's default.
  const rigorKeys = new Set([
    'rounds',
    'breadth',
    'spend',
    'orchestrator_tier',
    'implementer_tier',
    'challenger_tier',
    'reviewer_tier',
    'integrator_tier',
    'tier_escalation',
    'description',
    'convergence'
  ])
  for (const [profileName, candidate] of Object.entries(doc.rigor || {})) {
    const errorPath = `[rigor.${profileName}]`
    if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
      throw new PolicyError(`${errorPath} must be a table`)
    }
    const missing = [...rigorKeys].filter(
      (key) => key !== 'convergence' && key !== 'spend' && !Object.hasOwn(candidate, key)
    )
    const extra = Object.keys(candidate).filter((key) => !rigorKeys.has(key))
    if (missing.length > 0 || extra.length > 0) {
      throw new PolicyError(
        `${errorPath} has invalid keys` +
          `${missing.length > 0 ? `; missing: ${missing.join(', ')}` : ''}` +
          `${extra.length > 0 ? `; unsupported: ${extra.join(', ')}` : ''}`
      )
    }
    if (typeof candidate.tier_escalation !== 'boolean') {
      throw new PolicyError(
        `${errorPath}.tier_escalation must be a boolean, got ${JSON.stringify(candidate.tier_escalation)}`
      )
    }
    if (
      typeof candidate.description !== 'string' ||
      candidate.description.trim() === '' ||
      [...candidate.description].length > 100
    ) {
      throw new PolicyError(
        `${errorPath}.description must be a non-empty string of at most 100 characters`
      )
    }
    for (const pointer of ['rounds', 'breadth']) {
      if (
        typeof candidate[pointer] !== 'string' ||
        candidate[pointer].length === 0 ||
        !doc[pointer]?.[candidate[pointer]] ||
        typeof doc[pointer][candidate[pointer]] !== 'object'
      ) {
        throw new PolicyError(
          `${errorPath}.${pointer} must name an existing [${pointer}.*] table, got ${JSON.stringify(candidate[pointer])}`
        )
      }
    }
    const profileTierKeys = [
      'orchestrator_tier',
      'implementer_tier',
      'challenger_tier',
      'reviewer_tier',
      'integrator_tier'
    ]
    for (const key of profileTierKeys) {
      if (!BUILTIN_TIER_ORDER.includes(candidate[key])) {
        throw new PolicyError(
          `${errorPath}.${key} must be a concrete tier in [${BUILTIN_TIER_ORDER.join(', ')}], got ${JSON.stringify(candidate[key])}`
        )
      }
    }
    const implementerIndex = BUILTIN_TIER_ORDER.indexOf(candidate.implementer_tier)
    for (const role of ['orchestrator', 'challenger', 'reviewer']) {
      const roleTier = candidate[`${role}_tier`]
      if (BUILTIN_TIER_ORDER.indexOf(roleTier) < implementerIndex) {
        throw new PolicyError(
          `${errorPath} violates the role-tier floor: ${role}_tier (${roleTier}) must be >= implementer_tier (${candidate.implementer_tier}) in tier_order`
        )
      }
    }
    // Validate profile-dependent constraints across the whole catalog too:
    // pointer reachability, forensic's stronger floor, and any convergence
    // override must not depend on which profile this invocation selected.
    resolveRounds(doc, candidate, profileName)
    resolveBreadth(doc, candidate, profileName)
    resolveSpend(doc, candidate)
    resolveConvergence(doc, profileName)
  }
  const rounds = resolveRounds(doc, profile, level)
  const breadth = resolveBreadth(doc, profile, level)
  const spend = resolveSpend(doc, profile)
  const gates = resolveGates(doc)
  const convergence = resolveConvergence(doc, level)
  const tierOrder = doc.tier_order
  if (!Array.isArray(tierOrder) || tierOrder.length === 0) {
    throw new PolicyError('policy has no tier_order ranking')
  }
  // tier_order is a spec-pinned constant (BUILTIN_TIER_ORDER's own comment:
  // "the ONLY definition of one-rung escalation"), not a per-repo choice —
  // exactly like rigor_order, it must equal the canonical ladder exactly,
  // not merely be nonempty. Shepherd-stage cloud finding, confirmed: a
  // reversed list, or one containing only `local`, resolved with no
  // cross-validation error, letting strongest-wins conflicts and one-rung
  // escalation silently select weaker tiers or lose required rungs.
  if (
    tierOrder.length !== BUILTIN_TIER_ORDER.length ||
    tierOrder.some((v, i) => v !== BUILTIN_TIER_ORDER[i])
  ) {
    throw new PolicyError(
      `policy's tier_order must be exactly [${BUILTIN_TIER_ORDER.join(', ')}] (weakest to strongest), got [${tierOrder.join(', ')}]`
    )
  }
  const roles = resolveRoles(doc, profile, level, tierOrder)
  const stages = resolveStages(doc)
  const strategy = resolveStrategy(doc, requestedStrategy)

  return {
    source: 'operating',
    rigor: { level, order, tier_escalation: profile.tier_escalation },
    rounds,
    breadth,
    spend,
    gates,
    convergence,
    tier_order: tierOrder,
    roles,
    stages,
    strategy
  }
}

// ---------------------------------------------------------------------------
// Historical merge-base decode (legacy/v1 → v2), reachable only from the
// merge-base path — see the "Merge-base rule" section of resolvePolicy()
// below. Never invoked for the operating policy.
// ---------------------------------------------------------------------------

function decodeLegacyRounds(doc, levelName) {
  const level = doc.rigor?.[levelName]
  if (!level || typeof level !== 'object') {
    throw new PolicyError(`merge-base legacy policy has no [rigor.${levelName}] table`)
  }
  for (const key of ['challenge', 'review', 'shepherd', 'min_rounds']) {
    if (typeof level[key] !== 'number') {
      throw new PolicyError(`merge-base legacy [rigor.${levelName}] is missing numeric "${key}"`)
    }
    requireNonNegativeInt(level[key], key, `merge-base legacy [rigor.${levelName}]`)
  }
  return {
    policy: `legacy:${levelName}`,
    challenge: level.challenge,
    review: level.review,
    integration: level.shepherd,
    remediation: BUILTIN_REMEDIATION_FALLBACK(level.shepherd),
    min_rounds: level.min_rounds,
    wall_clock_min: BUILTIN_WALL_CLOCK_MIN_FALLBACK,
    // Decoder-only marker (see decodeHistoricalPolicy's own comment): legacy
    // had ONE undifferentiated "shepherd" cap, never two independent ones,
    // so integration and remediation here are not separate budgets that
    // each independently allow N actions — together they must never permit
    // more than N total. The unit charged against that shared total is one
    // legacy ROUND: one fix push, or one no-change cycle where nothing
    // needed fixing (AGENTS.md's legacy shepherd definition, carried
    // forward unchanged by this decode). A Codex cycle that surfaces a
    // finding and the fix push that answers it are the SAME round, charged
    // once — never two separate charges for one cycle-then-fix sequence.
    shared_budget: true
  }
}

function decodeV1Rounds(doc, levelName) {
  const level = doc.rigor?.[levelName]
  if (!level || typeof level !== 'object' || typeof level.review !== 'string') {
    throw new PolicyError(`merge-base v1 policy has no [rigor.${levelName}].review pointer`)
  }
  const policyName = level.review
  const table = doc.review?.[policyName]
  if (!table || typeof table !== 'object') {
    throw new PolicyError(
      `merge-base v1 policy has no [review.${policyName}] (pointed to by [rigor.${levelName}].review)`
    )
  }
  for (const key of ['challenge', 'review', 'shepherd', 'min_rounds']) {
    if (typeof table[key] !== 'number') {
      throw new PolicyError(`merge-base v1 [review.${policyName}] is missing numeric "${key}"`)
    }
    requireNonNegativeInt(table[key], key, `merge-base v1 [review.${policyName}]`)
  }
  return {
    policy: `v1:${policyName}`,
    challenge: table.challenge,
    review: table.review,
    integration: table.shepherd,
    remediation: BUILTIN_REMEDIATION_FALLBACK(table.shepherd),
    min_rounds: table.min_rounds,
    wall_clock_min: BUILTIN_WALL_CLOCK_MIN_FALLBACK,
    // Decoder-only marker — see decodeLegacyRounds's comment; v1's
    // [review.<policy>] carried the identical single undifferentiated
    // "shepherd" cap legacy did.
    shared_budget: true
  }
}

function decodeHistoricalBudget(doc, levelName, { required = false } = {}) {
  const profile = doc.rigor?.[levelName]
  const policyName = profile?.budget
  if (typeof policyName !== 'string') {
    if (required) {
      throw new PolicyError(`merge-base v1 [rigor.${levelName}] has no "budget" pointer`)
    }
    return {
      breadth: { ...BUILTIN_BREADTH_DEFAULT },
      wallClockMin: BUILTIN_WALL_CLOCK_MIN_FALLBACK,
      tierEscalation: false,
      spend: { policy: null, max_tokens: null, max_usd: null, status: 'UNENFORCED' }
    }
  }
  const table = doc.budget?.[policyName]
  if (!table || typeof table !== 'object' || Array.isArray(table)) {
    throw new PolicyError(
      `merge-base v1 [budget.${policyName}] is missing (pointed to by [rigor.${levelName}])`
    )
  }

  const errorPath = `[budget.${policyName}]`
  requireClosedTable(
    table,
    ['max_agent_runs', 'max_parallel_agents', 'wall_clock_min', 'allow_tier_escalation'],
    ['max_tokens', 'max_usd'],
    errorPath
  )
  for (const key of ['max_agent_runs', 'max_parallel_agents', 'wall_clock_min']) {
    requirePositiveInt(table[key], key, errorPath)
  }
  if (typeof table.allow_tier_escalation !== 'boolean') {
    throw new PolicyError(
      `${errorPath}.allow_tier_escalation must be a boolean, got ${JSON.stringify(table.allow_tier_escalation)}`
    )
  }
  if (table.max_tokens !== undefined) requirePositiveInt(table.max_tokens, 'max_tokens', errorPath)
  if (
    table.max_usd !== undefined &&
    !(typeof table.max_usd === 'number' && Number.isFinite(table.max_usd) && table.max_usd > 0)
  ) {
    throw new PolicyError(
      `${errorPath}.max_usd must be a finite positive number, got ${JSON.stringify(table.max_usd)}`
    )
  }

  return {
    breadth: {
      policy: `v1:${policyName}`,
      max_agent_runs: table.max_agent_runs,
      max_parallel_agents: table.max_parallel_agents
    },
    wallClockMin: table.wall_clock_min,
    tierEscalation: table.allow_tier_escalation,
    spend: {
      policy: policyName,
      max_tokens: typeof table.max_tokens === 'number' ? table.max_tokens : null,
      max_usd: typeof table.max_usd === 'number' ? table.max_usd : null,
      status: 'UNENFORCED'
    }
  }
}

function decodeHistoricalTierOrder(doc) {
  const order = doc.tier && typeof doc.tier === 'object' ? Object.keys(doc.tier) : []
  if (order.length === 0) return [...BUILTIN_TIER_ORDER]
  if (
    order.length !== BUILTIN_TIER_ORDER.length ||
    order.some((value, index) => value !== BUILTIN_TIER_ORDER[index])
  ) {
    throw new PolicyError(
      `merge-base v1 [tier.*] tables must preserve [${BUILTIN_TIER_ORDER.join(', ')}], got [${order.join(', ')}]`
    )
  }
  return order
}

function decodeHistoricalRoles(doc, levelName, tierOrder, { required = false } = {}) {
  const profile = doc.rigor?.[levelName] ?? {}
  const result = builtinRolesDefault()
  const historicalKeys = {
    orchestrator: 'orchestrator_tier',
    implementer: 'implementer_tier',
    reviewer: 'reviewer_tier'
  }
  for (const [role, key] of Object.entries(historicalKeys)) {
    if (profile[key] === undefined) {
      if (required) {
        throw new PolicyError(`merge-base v1 [rigor.${levelName}] has no "${key}" value`)
      }
      continue
    }
    if (!tierOrder.includes(profile[key])) {
      throw new PolicyError(
        `merge-base v1 [rigor.${levelName}].${key} must be in [${tierOrder.join(', ')}], got ${JSON.stringify(profile[key])}`
      )
    }
    result[role] = { ...result[role], tier: profile[key], source: `merge-base-v1:${key}` }
  }
  if (profile.reviewer_tier !== undefined) {
    result.challenger = {
      ...result.challenger,
      tier: profile.reviewer_tier,
      source: 'merge-base-v1:reviewer_tier'
    }
  }
  return result
}

function decodeHistoricalStrategy(doc, requestedStrategy, { required = false } = {}) {
  if (doc.strategy && typeof doc.strategy === 'object') {
    return resolveStrategy(doc, requestedStrategy)
  }
  if (requestedStrategy) {
    throw new PolicyError(
      `strategy ${JSON.stringify(requestedStrategy)} was requested but the merge-base policy has no [strategy.*] catalog`
    )
  }
  if (required) throw new PolicyError('merge-base v1 policy has no [strategy.*] catalog')
  return { ...BUILTIN_STRATEGY_DEFAULT }
}

/**
 * Decode a merge-base `.devflow.toml` that is NOT v2 (legacy or v1) into a
 * COMPLETE v2-shaped resolution. Per the lane addenda, the decoder's scope
 * is an invariant, not a field list: every field is populated from either
 * the older shape's own compatible semantics (rounds, rigor, budget,
 * strategy, and the three roles it named) or a fixed built-in default for a
 * concept it genuinely lacked (convergence, stages, and new roles). This
 * function never falls back to the BRANCH copy. Only reachable via the
 * merge-base path in resolvePolicy(); never call this for an operating
 * policy (see requireOperatingV2 above).
 */
export function decodeHistoricalPolicy(
  doc,
  detection,
  { rigor: requestedRigor, strategy: requestedStrategy } = {}
) {
  if (detection.shape !== 'legacy' && detection.shape !== 'v1') {
    throw new PolicyError(
      `cannot decode a "${detection.shape}"-shaped merge-base policy (only legacy and v1 are decodable)`
    )
  }
  let level
  let order = null
  if (detection.shape === 'v1') {
    const historicalRigor = resolveRigorLevel(doc, requestedRigor)
    level = historicalRigor.level
    order = historicalRigor.order
  } else {
    level = requestedRigor || doc.default_rigor
    if (!level)
      throw new PolicyError('no rigor level given and merge-base policy has no default_rigor')
  }

  const rounds =
    detection.shape === 'legacy' ? decodeLegacyRounds(doc, level) : decodeV1Rounds(doc, level)
  const isV1 = detection.shape === 'v1'
  const budget = decodeHistoricalBudget(doc, level, { required: isV1 })
  rounds.wall_clock_min = budget.wallClockMin
  const gates = resolveGates(doc, { allowMissing: true, fallback: BUILTIN_GATE_DEFAULTS })
  const tierOrder = decodeHistoricalTierOrder(doc)

  return {
    source: `merge-base-historical-decode:${detection.shape}`,
    rigor: { level, order, tier_escalation: budget.tierEscalation },
    rounds,
    breadth: budget.breadth,
    spend: budget.spend,
    gates,
    convergence: {
      converged: { ...BUILTIN_CONVERGENCE_DEFAULT.converged },
      diverging: { ...BUILTIN_CONVERGENCE_DEFAULT.diverging },
      overridden: false
    },
    tier_order: tierOrder,
    roles: decodeHistoricalRoles(doc, level, tierOrder, { required: isV1 }),
    stages: builtinStagesDefault(),
    strategy: decodeHistoricalStrategy(doc, requestedStrategy, { required: isV1 }),
    decodedFrom: detection.shape
  }
}

// ---------------------------------------------------------------------------
// Top-level resolve(): operating-path shape gate + optional merge-base rule
// ---------------------------------------------------------------------------

/**
 * doc: the parsed operating (branch/working-tree) policy — MUST be v2.
 * opts:
 *   - rigor, strategy: requested overrides (else default_rigor/default_strategy)
 *   - mergeBaseDoc: parsed merge-base policy, when the diff under review
 *     touches .devflow.toml or agent-registry.json. When given, resolution
 *     uses ITS content instead of `doc`'s — v2-shaped merge-base content
 *     resolves normally; legacy/v1-shaped merge-base content is decoded
 *     via decodeHistoricalPolicy(). `doc` is still required to be v2 (the
 *     operating-path gate applies regardless of whether the merge-base
 *     rule also applies).
 */
export function resolvePolicy(doc, opts = {}) {
  if (doc === null || doc === undefined) {
    if (!opts.mergeBaseDoc) return resolveAbsentPolicy(opts)

    const mbDetection = detectShape(opts.mergeBaseDoc)
    if (mbDetection.shape === 'v2') {
      return { ...resolveV2(opts.mergeBaseDoc, opts), source: 'merge-base' }
    }
    if (mbDetection.shape === 'legacy' || mbDetection.shape === 'v1') {
      return decodeHistoricalPolicy(opts.mergeBaseDoc, mbDetection, opts)
    }
    throw new PolicyError(
      `merge-base .devflow.toml is ${shapeRefusalMessage(mbDetection, { forOperating: false })} and cannot be decoded`
    )
  }

  requireOperatingV2(doc)

  if (!opts.mergeBaseDoc) {
    return resolveV2(doc, opts)
  }

  // requireOperatingV2 above only checks doc's SHAPE MARKER, never that it
  // actually resolves — the merge-base rule protects which VALUES govern
  // review, not whether the branch's own v2 content is well-formed. A
  // branch doc carrying nothing but `schema_version = 2` would otherwise
  // resolve successfully here (borrowing the merge-base's real values) and
  // then fail every future resolution the moment this PR merges and there
  // is no more merge-base to fall back to. Resolve doc for its own sake —
  // the result is discarded, this call exists only to throw if doc itself
  // is not independently well-formed. Shepherd-stage cloud finding (round
  // 2, about round 1's own fix), confirmed: this validation must run for
  // EVERY merge-base branch, not only the v2 one — a legacy/v1 merge-base
  // (the more common migration shape, since that is what this whole
  // decoder exists for) skipped it entirely.
  // Requested selections govern the merge-base policy, not the branch
  // catalog. During a vocabulary migration an explicit/base-only selection
  // can be perfectly valid in the trusted policy while intentionally absent
  // from the candidate v2 catalog. Validate the branch's own defaults and
  // complete catalog independently; applying requestedRigor/requestedStrategy
  // here would let branch vocabulary reject a valid merge-base selection
  // before the trusted document is decoded.
  resolveV2(doc, {})

  const mbDetection = detectShape(opts.mergeBaseDoc)
  if (mbDetection.shape === 'v2') {
    return { ...resolveV2(opts.mergeBaseDoc, opts), source: 'merge-base' }
  }
  if (mbDetection.shape === 'legacy' || mbDetection.shape === 'v1') {
    return decodeHistoricalPolicy(opts.mergeBaseDoc, mbDetection, opts)
  }
  throw new PolicyError(
    `merge-base .devflow.toml is ${shapeRefusalMessage(mbDetection, { forOperating: false })} and cannot be decoded`
  )
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

// Deliberately never falls back to running `task --list --json` in the
// caller's own cwd: per the lane addenda, this reader must be runnable from
// a materialized merge-base tree and must not resolve anything relative to
// the worktree it happens to be invoked from. A caller either hands over a
// precomputed target list (--task-targets, e.g. from `task --list --json`
// run inside an extracted merge-base closure) or an explicit directory to
// run `task` against (--taskfile-dir, go-task's own `--dir`); with neither,
// gate-slug checking is indeterminate rather than silently cwd-scoped.
function readTaskTargets(explicitFile, taskfileDir) {
  if (explicitFile) {
    const parsed = JSON.parse(readFileSync(explicitFile, 'utf8'))
    const entries = Array.isArray(parsed) ? parsed : parsed?.tasks
    if (!Array.isArray(entries)) {
      throw new PolicyError(
        '--task-targets must contain either an array of target names or a task --list --json object with a tasks array'
      )
    }
    const names = entries.map((entry) => (typeof entry === 'string' ? entry : entry?.name))
    if (names.some((name) => typeof name !== 'string' || name.length === 0)) {
      throw new PolicyError('--task-targets contains an entry without a non-empty target name')
    }
    return new Set(names)
  }
  if (taskfileDir) {
    try {
      const out = execFileSync('task', ['--dir', taskfileDir, '--list', '--json'], {
        encoding: 'utf8'
      })
      const parsed = JSON.parse(out)
      return new Set((parsed.tasks || []).map((t) => t.name))
    } catch {
      return null
    }
  }
  return null
}

const DETECT_OPTIONS = new Set(['policy', 'json'])
const RESOLVE_OPTIONS = new Set([
  'policy',
  'merge-base-policy',
  'registry',
  'merge-base-registry',
  'task-targets',
  'taskfile-dir',
  'rigor',
  'strategy',
  'json'
])
const BOOLEAN_OPTIONS = new Set(['json'])

function parseArgs(argv, allowedOptions) {
  const args = { _: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      const raw = a.slice(2)
      const equalsAt = raw.indexOf('=')
      const key = equalsAt === -1 ? raw : raw.slice(0, equalsAt)
      const inlineValue = equalsAt === -1 ? undefined : raw.slice(equalsAt + 1)
      if (!key || !allowedOptions.has(key)) {
        throw new PolicyError(`unsupported option ${JSON.stringify(a)}`)
      }
      if (Object.hasOwn(args, key)) {
        throw new PolicyError(`option --${key} may be supplied only once`)
      }
      if (BOOLEAN_OPTIONS.has(key)) {
        if (inlineValue !== undefined) {
          throw new PolicyError(`boolean option --${key} does not take a value`)
        }
        args[key] = true
        continue
      }
      if (inlineValue !== undefined) {
        if (inlineValue === '') throw new PolicyError(`option --${key} requires a value`)
        args[key] = inlineValue
        continue
      }
      const next = argv[i + 1]
      if (next === undefined || next.startsWith('--')) {
        throw new PolicyError(`option --${key} requires a value`)
      }
      args[key] = next
      i++
    } else {
      args._.push(a)
    }
  }
  if (args._.length > 0) {
    throw new PolicyError(`unexpected positional argument ${JSON.stringify(args._[0])}`)
  }
  return args
}

function loadTomlFile(filePath) {
  const text = readFileSync(filePath, 'utf8')
  return parseToml(text)
}

function cliDetect(args) {
  // Shepherd-stage cloud finding, confirmed: a missing --policy, a missing
  // file, or malformed TOML previously threw UNCAUGHT — a raw Node stack
  // trace to stderr and exit 1, the SAME status this function's own normal
  // "successfully detected a non-v2 policy" path returns, so nothing could
  // distinguish the two from the exit code alone. --json produced no
  // structured result at all in that case either, unlike every other
  // failure path in this CLI (cliResolve's identical read/parse guard).
  if (!args.policy) {
    console.error('devflow-policy detect: --policy <file> is required')
    return 2
  }
  let doc
  try {
    doc = loadTomlFile(args.policy)
  } catch (err) {
    console.error(`devflow-policy: could not read/parse --policy: ${err.message}`)
    if (args.json) {
      console.log(
        JSON.stringify({
          shape: null,
          error: 'could not read/parse --policy',
          message: err.message
        })
      )
    }
    return 2
  }
  const detection = detectShape(doc)
  if (args.json) {
    console.log(JSON.stringify(detection))
  } else {
    console.log(`shape: ${detection.shape}`)
    console.log(`markers: ${detection.markers.join(', ') || 'none'}`)
  }
  return detection.shape === 'v2' ? 0 : 1
}

function cliResolve(args) {
  if (!args.policy) {
    console.error('devflow-policy resolve: --policy <file> is required')
    return 2
  }
  let doc
  try {
    doc = loadTomlFile(args.policy)
  } catch (err) {
    if (err?.code === 'ENOENT') {
      doc = null
    } else {
      console.error(`devflow-policy: could not read/parse --policy: ${err.message}`)
      return 2
    }
  }

  let mergeBaseDoc = null
  if (args['merge-base-policy']) {
    try {
      mergeBaseDoc = loadTomlFile(args['merge-base-policy'])
    } catch (err) {
      console.error(`devflow-policy: could not read/parse --merge-base-policy: ${err.message}`)
      return 2
    }
  }

  let resolved
  try {
    resolved = resolvePolicy(doc, { rigor: args.rigor, strategy: args.strategy, mergeBaseDoc })
  } catch (err) {
    if (err instanceof PolicyError || err instanceof TomlError) {
      console.error(`devflow-policy: ${err.message}`)
      return 1
    }
    throw err
  }

  // Runs even against a historical-decode result: its roles/stages are the
  // built-in defaults (empty families, empty finders), so cross-validation
  // honestly reports them as unresolvable rather than skipping the check.
  // When a merge-base policy is in play, ONLY --merge-base-registry may
  // supply the registry — never fall back to the branch's own --registry.
  // Shepherd-stage cloud finding (round 3), confirmed: silently validating
  // merge-base-resolved values against the BRANCH's registry mixes trust
  // revisions exactly the way the merge-base rule exists to prevent — a
  // branch could change a finder's registry entry (e.g. surface from
  // "pr-cloud" to "local") and have that change govern validation of the
  // merge-base policy's own finder references, even though the merge-base
  // rule's whole point is that branch-controlled data must never affect
  // what a self-modifying diff resolves to.
  const registryPath = mergeBaseDoc ? args['merge-base-registry'] : args.registry
  let registryDoc = null
  if (registryPath) {
    try {
      registryDoc = JSON.parse(readFileSync(registryPath, 'utf8'))
    } catch (err) {
      console.error(`devflow-policy: could not read/parse --registry: ${err.message}`)
      return 2
    }
  }
  const taskTargets = readTaskTargets(args['task-targets'], args['taskfile-dir'])
  const crossErrors = crossValidate(resolved, registryDoc, taskTargets)

  const indeterminate = crossErrors.filter((e) => e.startsWith('indeterminate:'))
  const hardErrors = crossErrors.filter((e) => !e.startsWith('indeterminate:'))

  // `resolved` above is always the MERGE-BASE's own resolution when one is
  // in play (resolvePolicy's own contract) — cross_validation therefore
  // only ever tells the caller whether the merge-base's values are sound.
  // The branch's own [stage.*] references are structurally validated
  // (resolvePolicy calls resolveV2(doc, opts) for its own sake) but never
  // CROSS-validated against any registry — shepherd-stage cloud finding,
  // confirmed: a branch stage referencing an unregistered finder exits 0
  // today, because the valid merge-base finder silently replaces it in the
  // output, and only fails once this PR merges and there is no more
  // merge-base fallback to borrow from. Reported here so the problem is at
  // least VISIBLE to a caller that reads it — deliberately advisory, never
  // folded into cross_validation/hardErrors or this command's own exit
  // code: this repo's own merge-base-mutation-invariant fixtures
  // deliberately poison the branch copy with values no registry could ever
  // satisfy specifically to prove poisoning it has NO EFFECT on what
  // actually governs the run, so gating THIS command's exit on the
  // branch's own validity would falsely fail exactly the scenario those
  // fixtures exist to prove safe. A caller that wants this to gate CI can
  // check branch_cross_validation.errors itself.
  let branchCrossValidation = null
  if (mergeBaseDoc && doc && args.registry) {
    let branchRegistryDoc
    try {
      branchRegistryDoc = JSON.parse(readFileSync(args.registry, 'utf8'))
    } catch (err) {
      console.error(`devflow-policy: could not read/parse --registry: ${err.message}`)
      return 2
    }
    const branchResolved = resolveV2(doc, {})
    const branchErrors = crossValidate(branchResolved, branchRegistryDoc, taskTargets)
    branchCrossValidation = {
      errors: branchErrors.filter((e) => !e.startsWith('indeterminate:')),
      indeterminate: branchErrors.filter((e) => e.startsWith('indeterminate:'))
    }
  }

  const output = {
    ...resolved,
    cross_validation: { errors: hardErrors, indeterminate },
    branch_cross_validation: branchCrossValidation
  }

  if (args.json) {
    console.log(JSON.stringify(output, null, 2))
  } else {
    console.log(`rigor: ${resolved.rigor.level} (source: ${resolved.source})`)
    console.log(
      `rounds[${resolved.rounds.policy}]: challenge<=${resolved.rounds.challenge} review<=${resolved.rounds.review} ` +
        `integration<=${resolved.rounds.integration} remediation<=${resolved.rounds.remediation} ` +
        `min_rounds=${resolved.rounds.min_rounds} wall_clock_min=${resolved.rounds.wall_clock_min}`
    )
    if (resolved.breadth) {
      console.log(
        `breadth[${resolved.breadth.policy}]: max_agent_runs=${resolved.breadth.max_agent_runs} max_parallel_agents=${resolved.breadth.max_parallel_agents}`
      )
    }
    console.log(
      `spend: ${resolved.spend.status}${resolved.spend.policy ? ` (${resolved.spend.policy})` : ''}`
    )
    console.log(
      `gates[${resolved.gates.source}]: round_code=${resolved.gates.round_code} round_docs=${resolved.gates.round_docs} secret_scan=${resolved.gates.secret_scan} pre_pr=${resolved.gates.pre_pr}`
    )
    if (hardErrors.length > 0) {
      console.log('cross-validation errors:')
      for (const e of hardErrors) console.log(`  - ${e}`)
    }
    if (indeterminate.length > 0) {
      console.log('cross-validation indeterminate:')
      for (const e of indeterminate) console.log(`  - ${e}`)
    }
    if (branchCrossValidation && branchCrossValidation.errors.length > 0) {
      console.log(
        'branch cross-validation errors (branch copy, not the merge-base values this run operates under):'
      )
      for (const e of branchCrossValidation.errors) console.log(`  - ${e}`)
    }
  }

  if (hardErrors.length > 0) return 1
  if (indeterminate.length > 0) return 3
  return 0
}

function main() {
  const argv = process.argv.slice(2)
  // Trust cannot be bootstrapped inside a branch-controlled module: Node
  // evaluates this file and its static imports before main() can inspect an
  // argument. A trusted broker/caller must materialize and invoke the
  // merge-base reader directly. Refuse the retired in-module spelling so a
  // stale caller cannot mistake an ignored/delegated flag for that boundary.
  if (argv.some((arg) => arg === '--closure' || arg.startsWith('--closure='))) {
    console.error(
      'devflow-policy: --closure cannot establish reader trust from inside branch-controlled code; invoke the materialized merge-base scripts/devflow-policy.mjs directly'
    )
    return 2
  }

  const cmd = argv[0]
  if (cmd !== 'detect' && cmd !== 'resolve') {
    console.error('usage: devflow-policy.mjs <detect|resolve> --policy <file> [options]')
    return 2
  }
  let args
  try {
    args = parseArgs(argv.slice(1), cmd === 'detect' ? DETECT_OPTIONS : RESOLVE_OPTIONS)
  } catch (err) {
    if (err instanceof PolicyError) {
      console.error(`devflow-policy: ${err.message}`)
      return 2
    }
    throw err
  }
  if (cmd === 'detect') return cliDetect(args)
  if (cmd === 'resolve') return cliResolve(args)
  console.error('usage: devflow-policy.mjs <detect|resolve> --policy <file> [options]')
  return 2
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]
if (isMain) {
  process.exitCode = main()
}
