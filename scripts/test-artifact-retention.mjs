import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'

const [root, work] = process.argv.slice(2)
function yaml(file) {
  const result = spawnSync('yq', ['-o=json', '.', file], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  return JSON.parse(result.stdout)
}
const upload = step => step.uses?.startsWith('actions/upload-artifact@')
const lighthouse = step => step.uses?.startsWith('treosh/lighthouse-ci-action@')
function inventory(dir) {
  return fs.readdirSync(dir).filter(f => /\.ya?ml$/.test(f)).map(file => ({
    file, workflow: yaml(path.join(dir, file)),
  }))
}
function validateInventory(entries) {
  for (const { file, workflow } of entries) {
    for (const job of Object.values(workflow.jobs)) {
      for (const step of job.steps || []) {
        if (upload(step)) {
          const days = step.with?.['retention-days']
          assert.ok(Number.isInteger(days) && days > 0, `${file}: explicit positive retention required`)
          const name = step.with.name
          if (name === 'lighthouse-results' || name === 'playwright-report') {
            assert.ok(days >= 7 && days <= 14, `${file}: ordinary report retention must be 7–14 days`)
          } else if (file === 'security-audit-fix.yml') {
            assert.equal(days, 3, 'preserve the audit handoff lifetime')
          } else if (file === 'publish-harmon-devcontainer.yml') {
            assert.equal(days, 1, 'preserve the candidate handoff lifetime')
          } else {
            assert.ok(days <= 14, `${file}: document and classify new artifact producers`)
          }
        }
        if (lighthouse(step)) {
          assert.equal(step.with?.uploadArtifacts, false, 'Lighthouse internal upload has no retention input')
          assert.equal(step.with?.['retention-days'], undefined, 'do not supply unsupported action inputs')
        }
      }
    }
  }
}
function reportContract(job, name, expectedPath, condition) {
  const reports = job.steps.filter(upload)
  assert.equal(reports.length, 1, `${name}: one controlled uploader`)
  const report = reports[0]
  assert.equal(report.with.name, name)
  assert.equal(report.with.path, expectedPath)
  assert.equal(report.if, condition)
  assert.ok(!report['continue-on-error'], 'upload failure must stay visible')
  assert.ok(!job['continue-on-error'], 'job failure must remain gating')
  return report
}
const conditions = {
  lighthouse: "${{ !cancelled() && hashFiles('.lighthouseci/**') != '' }}",
  e2e: "${{ !cancelled() && steps.pw.outputs.present == 'true' && hashFiles('playwright-report/**') != '' }}",
}
function webContract(workflow, astro) {
  const e2e = workflow.jobs.e2e
  const report = reportContract(e2e, 'playwright-report', 'playwright-report/', conditions.e2e)
  const test = e2e.steps.find(s => s.name === 'End-to-end tests')
  assert.equal(test.run, 'task test:e2e')
  assert.ok(!test['continue-on-error'])
  assert.ok(e2e.steps.indexOf(report) > e2e.steps.indexOf(test))
  assert.ok(workflow.jobs.verify.needs.includes('e2e'))
  if (astro) {
    const job = workflow.jobs.lighthouse
    const action = job.steps.find(lighthouse)
    // This immutable action runs assertions and sets failure annotations. Keep
    // that contract instead of replacing audits with a non-gating collect step.
    assert.equal(action.uses, 'treosh/lighthouse-ci-action@3e7e23fb74242897f95c0ba9cabad3d0227b9b18')
    assert.equal(action.id, 'lighthouse')
    assert.equal(action.with.configPath, './lighthouserc.json')
    assert.equal(action.with.temporaryPublicStorage, true)
    assert.equal(action.with.uploadArtifacts, false)
    assert.ok(!action['continue-on-error'])
    const lhReport = reportContract(job, 'lighthouse-results', '.lighthouseci/', conditions.lighthouse)
    assert.equal(lhReport.with['include-hidden-files'], true, 'include the hidden LHCI directory')
    assert.ok(job.steps.indexOf(lhReport) > job.steps.indexOf(action))
    const comment = job.steps.find(s => s.name === 'Comment Lighthouse results on PR')
    assert.equal(comment.env.LHCI_RESULTS_PATH, '${{ steps.lighthouse.outputs.resultspath }}')
    assert.equal(comment.env.LHCI_LINKS, '${{ steps.lighthouse.outputs.links }}')
    assert.ok(workflow.jobs.verify.needs.includes('lighthouse'))
  } else {
    assert.equal(workflow.jobs.lighthouse, undefined)
  }
}
function rejectsMutation(original, mutate, validate) {
  const copy = structuredClone(original)
  mutate(copy)
  assert.throws(() => validate(copy))
}
const rootInventory = inventory(path.join(root, '.github/workflows'))
validateInventory(rootInventory)
const rendered = {}
for (const profile of ['web-astro', 'web-app', 'general']) {
  const entries = inventory(path.join(work, profile, '.github/workflows'))
  validateInventory(entries)
  const build = entries.find(e => e.file === 'build.yml').workflow
  rendered[profile] = build
  if (profile === 'general') {
    assert.equal(build.jobs.e2e, undefined)
    assert.equal(build.jobs.lighthouse, undefined)
  } else {
    webContract(build, profile === 'web-astro')
  }
  console.log(`PASS: ${profile} artifact inventory and report contract`)
}
for (const days of [undefined, 0, -1, 30, '${{ github.retention_days }}']) {
  rejectsMutation([{ file: 'build.yml', workflow: rendered['web-astro'] }], entries => {
    entries[0].workflow.jobs.e2e.steps.find(upload).with['retention-days'] = days
  }, validateInventory)
}
rejectsMutation([{ file: 'build.yml', workflow: rendered['web-astro'] }], entries => {
  entries[0].workflow.jobs.lighthouse.steps.find(lighthouse).with.uploadArtifacts = true
}, validateInventory)
for (const mutate of [
  w => { w.jobs.lighthouse.steps.find(upload).with['include-hidden-files'] = false },
  w => { w.jobs.lighthouse.steps.find(upload).if = '${{ success() }}' },
  w => { w.jobs.e2e.steps.find(s => s.name === 'End-to-end tests')['continue-on-error'] = true },
  w => { w.jobs.verify.needs = w.jobs.verify.needs.filter(n => n !== 'lighthouse') },
]) rejectsMutation(rendered['web-astro'], mutate, w => webContract(w, true))
console.log('PASS: negative controls reject uncontrolled retention and lost failure diagnostics/verdicts')

// Evaluate the actual rendered expressions against controlled runner functions.
// Exact expression checks above bound this to the two supported report guards.
function shouldUpload(expression, { cancelled, present, files }) {
  const code = expression.slice(3, -2)
  return Function('cancelled', 'hashFiles', 'steps', `return (${code})`)(
    () => cancelled, () => files ? 'fixture-digest' : '', { pw: { outputs: { present: String(present) } } })
}
const build = rendered['web-astro']
const aggregate = build.jobs.verify.steps.find(s => s.name === 'Verify required jobs succeeded')
assert.ok(aggregate.run.includes('./scripts/verify-ci-results.sh'))
for (const jobName of ['e2e', 'lighthouse']) {
  const report = build.jobs[jobName].steps.find(upload)
  for (const cancelled of [false, true]) {
    for (const files of [false, true]) {
      for (const present of [false, true]) {
        assert.equal(shouldUpload(report.if, { cancelled, files, present }),
          !cancelled && files && (jobName !== 'e2e' || present))
      }
    }
  }
  // A failed test/assertion still schedules available reports. Upload success
  // or failure cannot erase the earlier failed step's job result.
  for (const diagnosticUploadResult of ['success', 'failure']) {
    assert.ok(shouldUpload(report.if, { cancelled: false, files: true, present: true }))
    const env = { ...process.env, CI_EVENT_NAME: 'pull_request', CHANGES_RESULT: 'success',
      CHECK_RESULT: 'success', REPO_GUARDS_RESULT: 'success', DEVCONTAINER_PERMISSIONS_RESULT: 'success',
      SECURITY_RESULT: 'success', BUILD_TEST_RESULT: 'success', E2E_RESULT: 'success',
      LIGHTHOUSE_RESULT: 'success', RENDER_PARITY_RESULT: 'success', DOCS_ONLY: 'false',
      EXPECTED_RESULT: 'success', DOCS_ONLY_JOBS: aggregate.env.DOCS_ONLY_JOBS,
      [jobName === 'e2e' ? 'E2E_RESULT' : 'LIGHTHOUSE_RESULT']: 'failure' }
    const result = spawnSync('bash', ['-c', aggregate.run], { cwd: root, env, encoding: 'utf8' })
    assert.notEqual(result.status, 0, `${jobName}: failed verdict lost after ${diagnosticUploadResult} report upload`)
    assert.ok(result.stderr.includes(`Job ${jobName} result: failure`))
  }
}
console.log('PASS: failed tests/audits retain eligible diagnostics and fail the real rendered aggregate')
