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
const workTypes = m.workTypeLabels(registry)

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
const ctx = { workTypes, derive, underivable: null }
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
  assert.equal(d.reports[0].code, 'invalid-input')
})
check('two exclusive input labels: no value read, reported', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'risk:low', 'complexity:m']), ctx)
  assert.deepEqual(d.add, [])
  assert.equal(d.reports[0].code, 'ambiguous-input')
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
  return truthy(v)
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
  ['no policy file', fakeRepo('nopolicy', 'export const x = 1\n', { policy: false }), /no \.devflow\.toml/],
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
