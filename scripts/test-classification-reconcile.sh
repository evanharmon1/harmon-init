#!/usr/bin/env bash
# test-classification-reconcile.sh — hermetic test of the classification
# reconciler (scripts/classification-reconcile.mjs) and of the event
# workflow's job-level filter. No network, no gh. Run via
# `task test:classification-reconcile`.
#
# What it holds:
#   - decide(): pinned, ambiguous pin, missing inputs, drift, no-op, invalid
#     input, both input shapes (organization field and personal-account label),
#     needs-triage on a pinned issue, and the writer allowlist.
#   - The pin race (#1450 C1-F3): a human pins with two UI edits, in either
#     order, and no event of either sequence starts a job.
#   - loadDerivation(): a missing reader, a reader without deriveTier, and a
#     reader that throws while resolving the policy all leave the Tier
#     underivable and never throw; this repository's own reader, when it has
#     deriveTier, derives through it.
#   - The event workflow's `if`, evaluated as GitHub would against fixture
#     events — including CLASSIFICATION_AGENT_LOGINS unset (an unset vars.*
#     reads as the empty string) — and its input lists held equal to the
#     script's and to label-registry.json's.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node --input-type=module - "$PWD" "$tmp" <<'EOF'
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const [root, tmp] = process.argv.slice(2)
const m = await import(pathToFileURL(join(root, 'scripts/classification-reconcile.mjs')).href)
const registry = JSON.parse(readFileSync(join(root, 'label-registry.json'), 'utf8'))
const vocabulary = m.activeVocabulary(registry)
const workTypes = vocabulary.workTypes

let passed = 0
function check(name, fn) {
  try {
    fn()
    passed += 1
  } catch (err) {
    console.error(`TEST FAIL: ${name}\n${err.stack}`)
    process.exitCode = 1
  }
}

// A stand-in for the reader's deriveTier: the tests below are about the
// reconciler's decisions, not the matrix cells (the reader owns those).
const derive = (risk, complexity) => {
  if (risk === 'bogus') throw new Error('risk must be one of [...], got "bogus"')
  return `${risk}-${complexity}` === 'high-m' ? 'frontier' : 'standard'
}
const ctx = { vocabulary, derive, underivable: null }
const triaged = ['feature', 'area:ci', 'layer:none', 'domain:none', 'impact:low']
const issue = (labels, extra = {}) => ({ labels, issueType: null, fields: {}, ...extra })

// --- decide() ---------------------------------------------------------------

check('drift: a stale Tier is replaced, exclusively', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:standard', 'needs-triage']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.deepEqual(d.remove.sort(), ['needs-triage', 'tier:standard'])
})
check('drift: an absent Tier is written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.deepEqual(d.remove, [])
})
check('no-op: labels already match, nothing written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier']), ctx)
  assert.deepEqual([d.add, d.remove, d.reports], [[], [], []])
})
check('pinned: no Tier write, needs-triage still maintained', () => {
  const d = m.decide(issue(['risk:high', 'complexity:m', 'tier:local', 'tier:pinned']), ctx)
  assert.deepEqual(d.add, ['needs-triage'])
  assert.deepEqual(d.remove, [])
  const t = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'tier:pinned', 'needs-triage']), ctx)
  assert.deepEqual([t.add, t.remove], [[], ['needs-triage']])
})
check('ambiguous pin: reported, both tier labels left', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'tier:apex', 'tier:pinned']), ctx)
  assert.deepEqual([d.add, d.remove], [[], []])
  assert.equal(d.reports[0].code, 'ambiguous-pin')
})
check('missing inputs: no Tier write; a stale unpinned Tier is left and reported', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'tier:apex']), ctx)
  assert.deepEqual(d.add, ['needs-triage'])
  assert.deepEqual(d.remove, [])
  assert.equal(d.reports[0].code, 'cache-unverifiable')
})
check('missing inputs without a Tier: only needs-triage', () => {
  const d = m.decide(issue(['bug']), ctx)
  assert.deepEqual([d.add, d.remove, d.reports], [['needs-triage'], [], []])
})
check('an off-scale input is reported, not guessed', () => {
  const d = m.decide(issue([...triaged, 'risk:bogus', 'complexity:m', 'tier:apex']), ctx)
  assert.deepEqual(d.remove, [])
  assert.deepEqual(d.reports.map((r) => r.code), ['unrecognized-value', 'invalid-input'])
})
check('a conflicted axis: no value read, not triaged, needs-triage kept (C1-F3)', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'risk:low', 'complexity:m', 'needs-triage']), ctx)
  assert.deepEqual([d.add, d.remove, d.triaged], [[], [], false])
  assert.equal(d.reports[0].code, 'conflicted-axis')
})
check('an unknown value does not classify its axis (C1-F3)', () => {
  const d = m.decide(issue(['feature', 'area:ci', 'layer:none', 'domain:none', 'impact:bogus', 'risk:high', 'complexity:m', 'needs-triage']), ctx)
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
  assert.equal(d.reports[0].code, 'unrecognized-value')
})
check('a retired value does not classify its axis (C1-F3)', () => {
  const synthetic = structuredClone(registry)
  synthetic.families.find((f) => f.family === 'area').values.push({ value: 'old-area', retired: true })
  const v = m.activeVocabulary(synthetic)
  assert.ok(!v.recognized.area.includes('old-area'))
  const d = m.decide(issue(['feature', 'area:old-area', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']), { ...ctx, vocabulary: v })
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
  assert.match(d.reports[0].message, /retired or unknown/)
})
check('an absent registry: every axis unverifiable, needs-triage left as it is (C1-F3)', () => {
  const noReg = { ...ctx, vocabulary: null }
  const a = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'needs-triage']), noReg)
  assert.deepEqual([a.add.includes('needs-triage'), a.remove.includes('needs-triage'), a.triaged], [false, false, null])
  const b = m.decide(issue(['bug']), noReg)
  assert.deepEqual([b.add, b.remove], [[], []])
})
check('exactly one work-type label types an issue; two are a conflicted axis', () => {
  const rest = ['area:ci', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']
  assert.equal(m.decide(issue(['feature', ...rest]), ctx).triaged, true)
  const two = m.decide(issue(['feature', 'bug', ...rest]), ctx)
  assert.equal(two.triaged, false)
  assert.ok(!two.remove.includes('needs-triage'))
  assert.ok(two.reports.some((r) => r.code === 'conflicted-axis' && /work-type/.test(r.message)))
  // A native Issue Type types the issue whatever its labels say.
  assert.equal(m.decide(issue(['feature', 'bug', ...rest], { issueType: 'Task' }), ctx).triaged, true)
})
check('a retired work type does not type an issue (C1-F4)', () => {
  assert.ok(!workTypes.includes('enhancement'), 'enhancement is retired in label-registry.json')
  const d = m.decide(issue(['enhancement', 'area:ci', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']), ctx)
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
})
check('a truncated read is skipped and reported (C1-F6)', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local'], { truncated: 'labels' }), ctx)
  assert.deepEqual([d.add, d.remove, d.reports[0].code], [[], [], 'truncated'])
})
check('organization shape: fields and the native Type count; a field wins over a label', () => {
  const org = issue(['area:ci', 'layer:none', 'domain:none', 'risk:low'], {
    issueType: 'Task',
    fields: { Impact: 'low', Risk: 'high', Complexity: 'm' }
  })
  const d = m.decide(org, ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.equal(d.triaged, true)
  assert.equal(d.reports[0].code, 'field-label-conflict')
})
check('a family `none` value satisfies triage; a missing family does not', () => {
  assert.equal(m.decide(issue([...triaged, 'risk:high', 'complexity:m']), ctx).triaged, true)
  assert.equal(m.decide(issue(['feature', 'area:ci', 'layer:none', 'impact:low', 'risk:high', 'complexity:m']), ctx).triaged, false)
})
check('underivable: needs-triage maintained, no Tier write, reason reported', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'needs-triage']), {
    ...ctx,
    derive: null,
    underivable: 'the reader has no deriveTier'
  })
  assert.deepEqual([d.add, d.remove], [[], ['needs-triage']])
  assert.match(d.reports[0].message, /tier not derivable: the reader has no deriveTier/)
})
check('tier:adaptive is reported and never written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:adaptive']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.ok(!d.remove.includes('tier:adaptive'))
  assert.equal(d.reports[0].code, 'tier-retired')
})
check('writer allowlist: only tier:<value> and needs-triage', () => {
  for (const ok of ['needs-triage', 'tier:local', 'tier:apex']) assert.equal(m.assertWritable(ok), ok)
  for (const bad of ['tier:pinned', 'tier:adaptive', 'priority:high', 'priority-ai:p1', 'rigor:deep', 'strategy:plan', 'claim:claude', 'tier:implementer:apex', 'risk:high']) {
    assert.throws(() => m.assertWritable(bad), /refusing to write/)
  }
})
check('parseRepositories: list, fallback, and refusal', () => {
  assert.deepEqual(m.parseRepositories('a/b, c/d\ne/f', 'x/y'), ['a/b', 'c/d', 'e/f'])
  assert.deepEqual(m.parseRepositories('', 'x/y'), ['x/y'])
  assert.throws(() => m.parseRepositories('a/b/c', null), /not an owner\/name/)
})

// --- The event workflow's job-level `if` -------------------------------------

// A small evaluator for the subset of GitHub expressions the filter uses:
// && || ! == != ( ) , string literals, context paths, and contains /
// startsWith / fromJSON. Semantics as GitHub documents them: && and || return
// an operand; null, false, 0 and '' are falsy; string comparison ignores case;
// a missing property is null; null coerces to '' in string functions.
function evaluate(expr, context) {
  return evaluateRaw(expr, context, true)
}
function evaluateValue(expr, context) {
  return evaluateRaw(expr, context, false)
}
function evaluateRaw(expr, context, asBool) {
  const tokens = expr.match(/'(?:[^']|'')*'|&&|\|\||==|!=|[!(),]|[A-Za-z_][\w.-]*/g)
  let i = 0
  const peek = () => tokens[i]
  const take = (t) => {
    if (t !== undefined && tokens[i] !== t) throw new Error(`expected ${t} at token ${i}, got ${tokens[i]}`)
    return tokens[i++]
  }
  const truthy = (v) => !(v === null || v === undefined || v === false || v === 0 || v === '')
  const str = (v) => (v === null || v === undefined ? '' : String(v)).toLowerCase()
  const fns = {
    contains: (hay, needle) =>
      Array.isArray(hay) ? hay.some((h) => str(h) === str(needle)) : str(hay).includes(str(needle)),
    startsWith: (s, p) => str(s).startsWith(str(p)),
    fromJSON: (s) => JSON.parse(s)
  }
  function primary() {
    const t = take()
    if (t === '(') {
      const v = or()
      take(')')
      return v
    }
    if (t === '!') return !truthy(primary())
    if (t.startsWith("'")) return t.slice(1, -1).replaceAll("''", "'")
    if (t === 'true' || t === 'false') return t === 'true'
    if (t === 'null') return null
    if (peek() === '(') {
      take('(')
      const args = [or()]
      while (peek() === ',') {
        take(',')
        args.push(or())
      }
      take(')')
      if (!fns[t]) throw new Error(`unsupported function ${t}`)
      return fns[t](...args)
    }
    return t.split('.').reduce((o, k) => (o === null || o === undefined ? null : (o[k] ?? null)), context)
  }
  function cmp() {
    let v = primary()
    while (peek() === '==' || peek() === '!=') {
      const op = take()
      const r = primary()
      const eq = typeof v === 'string' && typeof r === 'string' ? str(v) === str(r) : v === r
      v = op === '==' ? eq : !eq
    }
    return v
  }
  function and() {
    let v = cmp()
    while (peek() === '&&') {
      take('&&')
      const r = cmp()
      v = truthy(v) ? r : v
    }
    return v
  }
  function or() {
    let v = and()
    while (peek() === '||') {
      take('||')
      const r = and()
      v = truthy(v) ? v : r
    }
    return v
  }
  const v = or()
  if (i !== tokens.length) throw new Error(`trailing tokens from ${tokens[i]}`)
  return asBool ? truthy(v) : v
}

const wf = readFileSync(join(root, '.github/workflows/classification-event.yml'), 'utf8')
const ifMatch = wf.match(/^ {4}if: >-\n((?: {6}.*\n)+)/m)
assert.ok(ifMatch, 'classification-event.yml: no folded job-level `if: >-` block')
const gate = ifMatch[1].replace(/\s+/g, ' ').trim()
const runs = (event, vars = {}) => evaluate(gate, { github: { event }, vars })
const human = { type: 'User', login: 'a-human' }
const labelEvent = (action, name, sender = human) => ({ action, label: { name }, sender })

check('the filter: inputs start a job for a human', () => {
  for (const name of ['risk:high', 'complexity:m', 'impact:low', 'area:ci', 'layer:ui', 'domain:none', ...workTypes]) {
    assert.ok(runs(labelEvent('labeled', name)), `labeled ${name}`)
    assert.ok(runs(labelEvent('unlabeled', name)), `unlabeled ${name}`)
  }
  for (const action of ['opened', 'typed', 'untyped']) assert.ok(runs({ action, sender: human }), action)
})
check('the filter: tier:*, needs-triage and other labels never start a job', () => {
  for (const name of ['tier:standard', 'tier:pinned', 'tier:adaptive', 'tier:implementer:apex', 'needs-triage', 'priority:high', 'priority-ai:p1', 'claim:claude', 'rigor:deep', 'blocked']) {
    assert.ok(!runs(labelEvent('labeled', name)), `labeled ${name}`)
    assert.ok(!runs(labelEvent('unlabeled', name)), `unlabeled ${name}`)
  }
})
check('the filter: bots never start a job', () => {
  assert.ok(!runs(labelEvent('labeled', 'risk:high', { type: 'Bot', login: 'my-ci-app[bot]' })))
  assert.ok(!runs({ action: 'opened', sender: { type: 'Bot', login: 'claude[bot]' } }))
})
check('the filter: CLASSIFICATION_AGENT_LOGINS unset reads as an empty allowlist', () => {
  assert.ok(runs(labelEvent('labeled', 'risk:high'), {}))
  assert.ok(runs(labelEvent('labeled', 'risk:high'), { CLASSIFICATION_AGENT_LOGINS: '' }))
})
check('the filter: an allowlisted agent login never starts a job', () => {
  const vars = { CLASSIFICATION_AGENT_LOGINS: '["an-agent","another"]' }
  assert.ok(!runs(labelEvent('labeled', 'risk:high', { type: 'User', login: 'an-agent' }), vars))
  assert.ok(!runs({ action: 'opened', sender: { type: 'User', login: 'Another' } }, vars))
  assert.ok(runs(labelEvent('labeled', 'risk:high'), vars))
})
check('pin race, Tier first: set the Tier, then add tier:pinned — no job starts', () => {
  const seq = [labelEvent('unlabeled', 'tier:standard'), labelEvent('labeled', 'tier:frontier'), labelEvent('labeled', 'tier:pinned')]
  assert.deepEqual(seq.map((e) => runs(e)), [false, false, false])
  const final = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:pinned']), ctx)
  assert.deepEqual([final.add, final.remove], [[], []])
})
check('pin race, pin first: add tier:pinned, then swap the Tier — no job starts', () => {
  const seq = [labelEvent('labeled', 'tier:pinned'), labelEvent('labeled', 'tier:apex'), labelEvent('unlabeled', 'tier:frontier')]
  assert.deepEqual(seq.map((e) => runs(e)), [false, false, false])
  // The gap holds two tier values beside the pin: a run there (the schedule)
  // reports it and leaves both, never picking one.
  const gap = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:apex', 'tier:pinned']), ctx)
  assert.deepEqual([gap.add, gap.remove, gap.reports[0].code], [[], [], 'ambiguous-pin'])
})
check('the filter and the script name the same inputs and event types', () => {
  const prefixes = [...gate.matchAll(/startsWith\(github\.event\.label\.name, '([^']+)'\)/g)].map((x) => x[1])
  assert.deepEqual(prefixes.sort(), [...m.INPUT_LABEL_PREFIXES].sort())
  const lists = [...gate.matchAll(/fromJSON\('(\[[^']*\])'\), github\.event\.label\.name\)/g)].map((x) => JSON.parse(x[1]))
  assert.equal(lists.length, 1, 'one work-type list')
  assert.deepEqual(lists[0].sort(), [...workTypes].sort(), 'the work-type list matches label-registry.json')
  const types = wf.match(/^ {4}types: \[([^\]]*)\]/m)[1].split(',').map((s) => s.trim())
  assert.deepEqual(types, [...m.EVENT_TYPES])
  for (const absent of ['edited', 'field_added', 'field_removed']) assert.ok(!types.includes(absent), absent)
})

// --- applyPlan(): every Tier write is guarded by a pin-free read (C1-F5, C2-F1),
// and the result is verified and repaired once (C1-F7, C3-F1) --------------------

// A stateful fake issue: writes really change its labels. `onRead[n]` edits
// the labels just before the n-th read (a human pinning, a concurrent run
// writing); `failWrites` lists `METHOD label` writes that error once each.
const TRUNCATED = Symbol('truncated')
function fakeClient(initial, { onRead = {}, failWrites = [] } = {}) {
  let labels = [...initial]
  let reads = 0
  const fails = [...failWrites]
  const calls = []
  const node = () => ({
    state: 'OPEN',
    number: 7,
    url: 'u',
    issueType: null,
    labels: {
      pageInfo: { hasNextPage: labels.at(-1) === TRUNCATED },
      nodes: labels.filter((l) => l !== TRUNCATED).map((name) => ({ name }))
    },
    issueFieldValues: { pageInfo: { hasNextPage: false }, nodes: [] }
  })
  return {
    calls,
    reads: () => reads,
    labels: () => labels.filter((l) => l !== TRUNCATED),
    async graphql() {
      reads += 1
      if (onRead[reads]) labels = onRead[reads](labels)
      return { repository: { issue: node() } }
    },
    async rest(method, path, payload) {
      const label = method === 'POST' ? payload.labels[0] : decodeURIComponent(path.split('/').at(-1))
      calls.push([method, label])
      const i = fails.indexOf(`${method} ${label}`)
      if (i >= 0) {
        fails.splice(i, 1)
        throw new Error(`${method} ${path}: 502 bad gateway`)
      }
      if (method === 'POST' && !labels.includes(label)) labels = [...labels, label]
      if (method === 'DELETE') labels = labels.filter((l) => l !== label)
      return null
    }
  }
}
const tiers = (c) => c.labels().filter((l) => /^tier:/.test(l)).sort()
const codes = (plan) => plan.reports.map((r) => r.code)
const stale = [...triaged, 'risk:high', 'complexity:m', 'tier:standard']
const addPin = (labels) => [...labels, 'tier:pinned']
{
  const client = fakeClient(stale)
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: an unpinned drift adds the derived Tier, deletes the stale one, and verifies', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), [])
  })
}
{
  const client = fakeClient(stale, { onRead: { 2: addPin } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin landing after the add stops the stale-Tier delete', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], []])
    assert.deepEqual(codes(plan), ['pin-appeared'])
    assert.ok(!plan.unrepaired, 'a pin stop is not a failure')
  })
}
{
  // The pin is already on the decision read: no Tier write at all, and
  // needs-triage is still maintained (it is never guarded).
  const client = fakeClient(['risk:high', 'complexity:m', 'tier:standard', 'tier:pinned'])
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin before the add means no Tier write; needs-triage still written', () => {
    assert.deepEqual(client.calls, [['POST', 'needs-triage']])
    assert.deepEqual([plan.add, plan.remove], [['needs-triage'], []])
  })
}
{
  // A delete-only plan (two stale tiers beside the derived one): the second
  // delete re-reads and sees the pin.
  const twoStale = [...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:standard', 'tier:local']
  const client = fakeClient(twoStale, {
    onRead: { 2: (l) => addPin(l.filter((x) => x !== 'tier:standard')) }
  })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a delete-only plan stops at the first read that shows a pin', () => {
    assert.deepEqual(client.calls, [['DELETE', 'tier:standard']])
    assert.deepEqual([plan.add, plan.remove], [[], ['tier:standard']])
    assert.match(plan.reports.at(-1).message, /remove tier:local not applied/)
  })
}
{
  // A guard re-read that spans more than one page cannot prove "unpinned".
  const client = fakeClient(stale, { onRead: { 2: (l) => [...l, TRUNCATED] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a truncated guard read stops the remaining Tier writes (C3-F2)', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], []])
    assert.deepEqual(codes(plan), ['pin-guard-indeterminate'])
  })
}
{
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard'] })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a failed delete is healed by the one repair pass (C1-F7)', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard'], ['DELETE', 'tier:standard']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), ['write-failed'])
  })
}
{
  // Reads: 1 decision, 2 guard before the delete, 3 verify — a concurrent run
  // has added another rung by then.
  const client = fakeClient(stale, { onRead: { 3: (l) => [...l, 'tier:apex'] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check("applyPlan: a concurrent run's extra rung is healed by the repair pass (C3-F1)", () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard'], ['DELETE', 'tier:apex']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), [])
  })
}
{
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard', 'DELETE tier:standard'] })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a repair that also fails is reported as tier-not-exclusive, with no further pass', () => {
    assert.deepEqual(client.calls.filter(([meth]) => meth === 'DELETE').length, 2)
    assert.deepEqual(tiers(client), ['tier:frontier', 'tier:standard'])
    assert.deepEqual(codes(plan), ['write-failed', 'write-failed', 'tier-not-exclusive'])
    assert.equal(plan.unrepaired, true)
  })
}
{
  // Impact is missing on the decision read, so needs-triage would be added;
  // a human completes the classification before the verify read (read 3).
  // needs-triage is decided from that latest read, so it is not added.
  const partial = ['feature', 'area:ci', 'layer:none', 'domain:none', 'risk:high', 'complexity:m', 'tier:standard']
  const client = fakeClient(partial, { onRead: { 3: (l) => [...l, 'impact:low'] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: needs-triage is decided from the latest read, not the first', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], ['tier:standard']])
    assert.equal(client.reads(), 3)
  })
}
{
  const client = fakeClient(['bug'])
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: with no Tier write, needs-triage uses the decision read (no extra read)', () => {
    assert.deepEqual(client.calls, [['POST', 'needs-triage']])
    assert.equal(client.reads(), 1)
    assert.deepEqual(plan.add, ['needs-triage'])
  })
}
{
  // The delete fails; by the verify read (read 3) a human has pinned.
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard'], onRead: { 3: addPin } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin seen on the verify read stops the repair', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual(codes(plan), ['write-failed'])
  })
}

// --- run(): the driver, against a stubbed fetch (R1-F1; integration 1–2) -------

// A stateful fake GitHub. Each repository holds issues (labels really change
// on POST/DELETE), the files its contents API serves (`null` → 404), an
// optional `down` (every call 502s), `failPaths` (REST paths that always 502)
// and `afterWrite(issue, method, label)` (a human or another run acting
// between our calls).
function fakeGitHub(repos) {
  const rest = []
  const json = (body, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  const node = (number, issue) => ({
    state: 'OPEN',
    number,
    url: `https://github.test/issues/${number}`,
    issueType: issue.issueType ? { name: issue.issueType } : null,
    labels: { pageInfo: { hasNextPage: false }, nodes: issue.labels.map((name) => ({ name })) },
    issueFieldValues: {
      pageInfo: { hasNextPage: false },
      nodes: [
        ...Object.entries(issue.fields ?? {}).map(([field, value]) => ({ name: value, field: { name: field } })),
        { name: 'p1', field: { name: 'Priority (AI)' } },
        {}
      ]
    }
  })
  async function fetch(url, init = {}) {
    const { pathname } = new URL(url)
    if (pathname === '/graphql') {
      const { query, variables } = JSON.parse(init.body)
      const repo = repos[`${variables.owner}/${variables.name}`]
      if (!repo || repo.down) return json({ message: 'bad gateway' }, 502)
      if (query.includes('issue(number:')) {
        const issue = repo.issues[variables.number]
        return json({ data: { repository: { issue: issue ? node(variables.number, issue) : null } } })
      }
      // One issue per page, so pagination is always exercised.
      const numbers = Object.keys(repo.issues).map(Number)
      const at = variables.after ? Number(variables.after) : 0
      return json({
        data: {
          repository: {
            issues: {
              pageInfo: { hasNextPage: at + 1 < numbers.length, endCursor: String(at + 1) },
              nodes: [node(numbers[at], repo.issues[numbers[at]])]
            }
          }
        }
      })
    }
    const [, , owner, name, kind, ...rest_] = pathname.split('/')
    const repo = repos[`${owner}/${name}`]
    if (!repo || repo.down) return json({ message: 'bad gateway' }, 502)
    if (kind === 'contents') {
      const text = repo.files?.[rest_.join('/')] ?? null
      return text === null ? json({ message: 'Not Found' }, 404) : new Response(text, { status: 200 })
    }
    rest.push([init.method, pathname, init.body ? JSON.parse(init.body) : null])
    if ((repo.failPaths ?? []).includes(pathname)) return json({ message: 'bad gateway' }, 502)
    const issue = repo.issues[Number(rest_[0])]
    const label = init.method === 'POST' ? JSON.parse(init.body).labels[0] : decodeURIComponent(rest_.at(-1))
    if (init.method === 'POST' && !issue.labels.includes(label)) issue.labels.push(label)
    if (init.method === 'DELETE') issue.labels = issue.labels.filter((l) => l !== label)
    repo.afterWrite?.(issue, init.method, label)
    return init.method === 'DELETE' ? new Response(null, { status: 204 }) : json([])
  }
  return { fetch, rest }
}
const ownText = (file) => readFileSync(join(root, file), 'utf8')
const canDerive = (await m.loadDerivation(root)).derive !== null
const classified = () => ({
  issueType: 'Task',
  labels: ['area:ci', 'layer:none', 'domain:none', 'needs-triage'],
  fields: { Impact: 'low', Risk: 'high', Complexity: 'm' }
})
async function runWith(repos, env) {
  const gh = fakeGitHub(repos)
  const summaryFile = join(tmp, `summary-${Object.keys(repos).join('-').replaceAll('/', '_')}-${Math.random()}.md`)
  const printed = []
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', GITHUB_STEP_SUMMARY: summaryFile, ...env },
    { fetch: gh.fetch, root, print: (l) => printed.push(l) }
  )
  return { code, gh, printed, summary: readFileSync(summaryFile, 'utf8') }
}
const writes = (gh, prefix) => gh.rest.filter(([, path]) => path.startsWith(prefix)).map(([meth, path, body]) => `${meth} ${body?.labels?.[0] ?? decodeURIComponent(path.split('/').at(-1))}`)
{
  const r = await runWith(
    { 'a/one': { down: true, issues: {} }, 'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() } } },
    { RECONCILE_REPOSITORIES: 'a/one a/two' }
  )
  check('run(): a failing repository does not stop the next one; the run exits 1', () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /^Failed: a\/one\.$/m)
    assert.match(r.summary, /\*\*a\/one failed:\*\* /)
    assert.ok(r.printed.some((l) => l.startsWith('::error title=classification reconcile a/one::')))
    assert.deepEqual(writes(r.gh, '/repos/a/one/'), [])
  })
  check('run(): the issues connection is paginated and both pages are decided', () => {
    assert.match(r.summary, /of 2 open issue\(s\) in a\/one, a\/two\.$/m)
  })
  check('run(): issue-field values are normalized (Impact/Risk/Complexity read, others ignored)', () => {
    assert.ok(writes(r.gh, '/repos/a/two/issues/1/').includes('POST needs-triage'))
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('DELETE needs-triage'))
  })
}
{
  const r = await runWith({ 'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() } } }, { RECONCILE_DRY_RUN: 'true' })
  check('run(): a dry run makes no REST call and reports what it would change', () => {
    assert.equal(r.code, 0)
    assert.deepEqual(r.gh.rest, [])
    assert.match(r.summary, /^Dry run: would change 2 of 2 open issue\(s\) in a\/two\.$/m)
  })
}
{
  const r = await runWith({
    'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() }, failPaths: ['/repos/a/two/issues/1/labels'] }
  })
  check("run(): one issue's failure does not stop the next issue; the run exits 1", () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /\*\*a\/two#1 failed:\*\* POST \/repos\/a\/two\/issues\/1\/labels: 502/)
    assert.match(r.summary, /^Failed: a\/two\.$/m)
    assert.ok(r.printed.some((l) => l.startsWith('::error title=classification reconcile a/two#1::')))
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('DELETE needs-triage'))
  })
}
if (canDerive) {
  const stuck = { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'tier:standard'] }
  const r = await runWith({
    'a/two': {
      issues: { 1: stuck, 2: { labels: ['bug'] } },
      failPaths: ['/repos/a/two/issues/1/labels/tier%3Astandard']
    }
  })
  check('run(): a Tier still not exclusive after the repair fails the run, and the walk completes', () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /tier-not-exclusive/)
    assert.match(r.summary, /^Failed: a\/two\.$/m)
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('POST needs-triage'))
  })
  const pinned = { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'tier:standard'] }
  const p = await runWith({
    'a/two': {
      issues: { 1: pinned },
      // A human pins right after our add, before the stale-Tier delete.
      afterWrite: (issue, meth, label) => meth === 'POST' && label.startsWith('tier:') && issue.labels.push('tier:pinned')
    }
  })
  check('run(): a pin that stops the Tier writes is reported, not a failure', () => {
    assert.equal(p.code, 0)
    assert.match(p.summary, /pin-appeared/)
    assert.doesNotMatch(p.summary, /^Failed:/m)
  })
}
{
  // b/three's own registry knows area:zzz and its own matrix maps m × high to
  // apex; the caller (a/two) knows neither. c/four has no registry; d/five
  // has no policy.
  const foreignRegistry = structuredClone(registry)
  foreignRegistry.families.find((f) => f.family === 'area').values = [{ value: 'zzz' }]
  const ownPolicy = ownText('.devflow.toml')
  const foreignPolicy = ownPolicy.replace(/^(m\s*=\s*\{.*high = )"[a-z]+"/m, '$1"apex"')
  assert.notEqual(foreignPolicy, ownPolicy, 'the foreign matrix differs')
  const zzz = () => ({ labels: ['feature', 'area:zzz', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage'] })
  const r = await runWith(
    {
      'a/two': { issues: { 1: zzz() } },
      'b/three': { issues: { 1: zzz() }, files: { 'label-registry.json': JSON.stringify(foreignRegistry), '.devflow.toml': foreignPolicy } },
      'c/four': { issues: { 1: { labels: ['bug'] } }, files: { 'label-registry.json': null, '.devflow.toml': ownPolicy } },
      'd/five': {
        issues: { 1: { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'needs-triage', 'tier:local'] } },
        files: { 'label-registry.json': JSON.stringify(registry), '.devflow.toml': null }
      }
    },
    { RECONCILE_REPOSITORIES: 'a/two b/three c/four d/five' }
  )
  check("run(): another repository is judged by its own registry and its own matrix", () => {
    assert.equal(r.code, 0)
    assert.ok(!writes(r.gh, '/repos/a/two/').includes('DELETE needs-triage'), 'area:zzz is unknown to the caller')
    assert.ok(writes(r.gh, '/repos/b/three/').includes('DELETE needs-triage'), 'area:zzz is known to b/three')
    if (canDerive) {
      assert.ok(writes(r.gh, '/repos/a/two/').includes('POST tier:frontier'))
      assert.ok(writes(r.gh, '/repos/b/three/').includes('POST tier:apex'))
    }
  })
  check('run(): a repository without a registry gets no needs-triage write, reported once', () => {
    assert.deepEqual(writes(r.gh, '/repos/c/four/').filter((w) => w.endsWith('needs-triage')), [])
    assert.equal(r.summary.match(/c\/four:\*\* label-registry\.json is unreadable/g)?.length, 1)
  })
  check('run(): a repository without a policy gets no Tier write, reported once', () => {
    assert.deepEqual(writes(r.gh, '/repos/d/five/').filter((w) => /tier:/.test(w)), [])
    // Without a deriving reader (a generated repo before harmon-devkit#1248),
    // the reader is the reason reported; with one, the missing policy is.
    const reason = canDerive ? 'no \\.devflow\\.toml' : '(no policy reader found|has no deriveTier)'
    assert.equal(r.summary.match(new RegExp(`d/five:\\*\\* tier not derivable: ${reason}`, 'g'))?.length, 1)
    assert.ok(writes(r.gh, '/repos/d/five/').includes('DELETE needs-triage'))
  })
}

// --- The reconcile workflow's token expression (C1-F1) ----------------------

const rwf = readFileSync(join(root, '.github/workflows/classification-reconcile.yml'), 'utf8')
check('the token: CLASSIFICATION_TOKEN only when a workflow_call caller sets use-token', () => {
  const tokenExpr = rwf.match(/^ {10}GH_TOKEN: \$\{\{ (.*) \}\}$/m)?.[1]
  assert.equal(tokenExpr, 'inputs.use-token && secrets.CLASSIFICATION_TOKEN || github.token')
  const tok = (inputs, secrets) => evaluateValue(tokenExpr, { inputs, secrets, github: { token: 'GITHUB_TOKEN' } })
  // schedule / workflow_dispatch: no use-token input, whatever secrets exist.
  assert.equal(tok({}, { CLASSIFICATION_TOKEN: 'stored' }), 'GITHUB_TOKEN')
  assert.equal(tok({ 'use-token': false }, { CLASSIFICATION_TOKEN: 'app' }), 'GITHUB_TOKEN')
  assert.equal(tok({ 'use-token': true }, { CLASSIFICATION_TOKEN: 'app' }), 'app')
  assert.equal(tok({ 'use-token': true }, {}), 'GITHUB_TOKEN')
  const dispatch = rwf.slice(rwf.indexOf('  workflow_dispatch:'), rwf.indexOf('  workflow_call:'))
  const call = rwf.slice(rwf.indexOf('  workflow_call:'), rwf.indexOf('\npermissions:'))
  assert.ok(!dispatch.includes('use-token'), 'use-token is never a workflow_dispatch input')
  assert.match(call, /^ {6}use-token:\n {8}description: .*\n {8}type: boolean\n {8}required: false\n {8}default: false$/m)
})

// --- loadDerivation() --------------------------------------------------------

function fakeRepo(name, readerSource, { policy = true } = {}) {
  const dir = join(tmp, name)
  mkdirSync(join(dir, 'scripts/lib'), { recursive: true })
  if (readerSource !== null) writeFileSync(join(dir, 'scripts/devflow-policy.mjs'), readerSource)
  writeFileSync(join(dir, 'scripts/lib/toml-lite.mjs'), 'export function parseToml() { return { tier: {} } }\n')
  if (policy) writeFileSync(join(dir, '.devflow.toml'), '[tier.matrix]\n')
  return dir
}
const cases = [
  ['no reader', fakeRepo('none', null), /no policy reader found/],
  [
    'no policy file',
    fakeRepo('nopolicy', 'export function deriveTier() {}\nexport function resolvePolicy() { return {} }\n', { policy: false }),
    /no \.devflow\.toml/
  ],
  ['a reader without deriveTier', fakeRepo('old', 'export function resolvePolicy() { return {} }\n'), /has no deriveTier/],
  [
    'a reader that throws on the policy',
    fakeRepo('throws', 'export function deriveTier() {}\nexport function resolvePolicy() { throw new Error("[tier] is not a known table") }\n'),
    /could not resolve the policy: \[tier\] is not a known table/
  ],
  ['a reader whose policy has no matrix', fakeRepo('nomatrix', 'export function deriveTier() {}\nexport function resolvePolicy() { return {} }\n'), /no \[tier\.matrix\]/]
]
for (const [name, dir, reason] of cases) {
  const d = await m.loadDerivation(dir)
  check(`loadDerivation: ${name} leaves the Tier underivable`, () => {
    assert.equal(d.derive, null)
    assert.match(d.underivable, reason)
  })
}
const own = await m.loadDerivation(root)
const reader = own.reader ? await import(pathToFileURL(own.reader).href) : {}
if (typeof reader.deriveTier === 'function') {
  check("loadDerivation: this repository's reader derives through deriveTier", () => {
    assert.equal(own.underivable, null)
    assert.ok(m.TIER_VALUES.includes(own.derive('high', 'm')))
    assert.throws(() => own.derive('bogus', 'm'))
  })
} else {
  check('loadDerivation: a reader without deriveTier is reported, not fatal', () => {
    assert.equal(own.derive, null)
    assert.ok(own.underivable)
  })
}

if (process.exitCode) process.exit(process.exitCode)
console.log(`classification-reconcile tests OK: ${passed} checks`)
EOF
