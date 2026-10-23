#!/usr/bin/env bash
# Exercise the actual github-script bodies from one working-tree render.
# Node and mikefarah/yq are installed by Build's repo-guards setup action.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for tool in copier node yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FAIL: required tool '$tool' is not installed" >&2
        exit 1
    }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/harmon-comment-annotators.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Isolate Copier's own temporary clones from concurrent renders.
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"

dest="$work/render"
if ! copier copy --vcs-ref=HEAD --trust --defaults --skip-tasks \
    --data project_name="Comment Annotator Test" \
    --data project_type=web-astro \
    --data deploy_cloudflare_workers=true \
    --data github_remote_create=false \
    --data github_release_init=false \
    --data run_task_install=false \
    --data bunch_add=false \
    --data obsidian_project_add=false \
    "$repo_root" "$dest" >"$work/render.log" 2>&1; then
    cat "$work/render.log" >&2
    exit 1
fi
echo "PASS: render web-astro with deploy_cloudflare_workers=true"

yq -o=json '.' "$dest/.github/workflows/build.yml" >"$work/lighthouse.json"
yq -o=json '.' "$dest/.github/workflows/deploy-preview.yml" >"$work/preview.json"

node - "$work" <<'JS'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const work = process.argv[2]
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const head = 'a'.repeat(40)
const merge = 'b'.repeat(40)
const olderHead = 'c'.repeat(40)
const docsHead = 'd'.repeat(40)
const noteMarker = '<!-- docs-only-status -->'
const context = {
  repo: { owner: 'owner', repo: 'repo' }, issue: { number: 123 },
  serverUrl: 'https://github.com', runId: 456,
}
const specs = [
  { file: 'lighthouse.json', job: 'lighthouse', annotator: 'lighthouse-stale-comment',
    step: 'Comment Lighthouse results on PR', heading: '## Lighthouse CI Results',
    marker: 'Measured', verb: 're-measured', result: 'measurement', shaEnv: 'MEASURED_SHA' },
  { file: 'preview.json', job: 'deploy', annotator: 'preview-stale-comment',
    step: 'Comment preview URLs on PR', heading: '## Cloudflare Workers Preview',
    marker: 'Deployed', verb: 're-deployed', result: 'deployment', shaEnv: 'DEPLOYED_SHA' },
]
fs.writeFileSync(path.join(work, 'manifest.json'), JSON.stringify([
  { isRepresentativeRun: true, url: 'http://localhost/',
    summary: { performance: 0.97, accessibility: 1, 'best-practices': 1, seo: 0.99 } },
]))

function scriptStep(workflow, job, name) {
  const steps = workflow.jobs[job].steps.filter(s =>
    s.uses?.startsWith('actions/github-script@') && (!name || s.name === name))
  assert.equal(steps.length, 1, `expected one github-script in ${job}`)
  assert.equal(typeof steps[0].with.script, 'string')
  return steps[0]
}

// listComments returns only ONE page. paginate must call it until exhausted;
// returning the whole fixture for every API call would conceal the original bug.
async function execute(script, comments, { currentHead = head, eventHead = head } = {}) {
  const updates = [], creates = [], pages = []
  const github = { rest: {
    pulls: { get: async args => {
      assert.deepEqual(args, { ...context.repo, pull_number: context.issue.number })
      return { data: { head: { sha: currentHead } } }
    } },
    issues: {
      listComments: async args => {
        assert.equal(args.owner, context.repo.owner)
        assert.equal(args.repo, context.repo.repo)
        assert.equal(args.issue_number, context.issue.number)
        const page = args.page || 1, size = args.per_page || 30
        pages.push(page)
        return { data: comments.slice((page - 1) * size, page * size) }
      },
      updateComment: async args => { updates.push(args) },
      createComment: async args => { creates.push(args) },
    },
  } }
  github.paginate = async (method, args) => {
    assert.equal(method, github.rest.issues.listComments)
    assert.equal(args.per_page, 100)
    const all = []
    for (let page = 1; ; page++) {
      const { data } = await method({ ...args, page })
      all.push(...data)
      if (data.length < args.per_page) return all
    }
  }
  const env = {
    HEAD_SHA: eventHead, MEASURED_SHA: merge, DEPLOYED_SHA: merge,
    LHCI_LINKS: JSON.stringify({ 'http://localhost/': 'https://reports.example/test' }),
    LHCI_RESULTS_PATH: work, DEPLOY_URL: 'https://version.example.workers.dev',
    PREVIEW_ALIAS: 'test', COMMAND_OUTPUT: 'https://test-app.example.workers.dev',
  }
  await new AsyncFunction('github', 'context', 'process', 'require', script)(
    github, context, { env }, require)
  for (const args of [...updates, ...creates]) {
    assert.equal(args.owner, context.repo.owner)
    assert.equal(args.repo, context.repo.repo)
  }
  return { updates, creates, pages }
}

function onlyUpdate(result, id) {
  assert.equal(result.creates.length, 0, 'must not create a duplicate')
  assert.equal(result.updates.length, 1, 'must update exactly one comment')
  assert.equal(result.updates[0].comment_id, id, 'must select newest matching bot comment')
  return result.updates[0].body
}

async function run(spec) {
  const workflow = JSON.parse(fs.readFileSync(path.join(work, spec.file), 'utf8'))
  const publisherStep = scriptStep(workflow, spec.job, spec.step)
  const annotatorStep = scriptStep(workflow, spec.annotator)
  const publisher = publisherStep.with.script, annotator = annotatorStep.with.script
  assert.equal(publisherStep.env[spec.shaEnv], '${{ github.sha }}')
  assert.equal(publisherStep.env.HEAD_SHA, '${{ github.event.pull_request.head.sha }}')
  assert.equal(annotatorStep.env.HEAD_SHA, '${{ github.event.pull_request.head.sha }}')
  const checkout = workflow.jobs[spec.job].steps.find(s => s.uses?.startsWith('actions/checkout@'))
  assert.ok(checkout, `${spec.job} must check out code`)
  assert.equal(checkout.with?.ref, undefined, 'keep default merge-ref checkout')
  console.log(`PASS: ${spec.job}: default merge-ref checkout`)
  const label = `${merge} (merge of head ${olderHead})`
  const original = marker => `${spec.heading}\n\n${marker ? `_${spec.marker} commit: ${marker}_\n\n` : ''}` +
    '| preserved | https://results.example/original |\n| score | 97 |'
  const comment = (id, marker = label) => ({ id, user: { type: 'Bot' }, body: original(marker) })
  const noise = id => ({ id, user: { type: 'User' }, body: spec.heading })
  const passed = name => console.log(`PASS: ${spec.job}: ${name}`)
  const expectedNote = (sha, marker) => `Head ${sha} was not ${spec.verb} (docs-only change). ` +
    (marker ? `This comment still reflects commit ${marker}.` :
      `This comment reflects an earlier ${spec.result} whose commit was not recorded.`)

  const duplicates = [comment(1), noise(2), comment(3), noise(4)]
  onlyUpdate(await execute(annotator, duplicates), 3)
  onlyUpdate(await execute(publisher, duplicates), 3)
  passed('newest-of-duplicates (ignores later human heading)')

  for (const [name, marker] of [['legacy without marker', null], ['legacy bare-SHA marker', merge],
    ['labelled merge marker', label]]) {
    const body = onlyUpdate(await execute(annotator, [comment(5, marker)]), 5)
    assert.equal(body, `${original(marker)}\n\n${noteMarker}\n${expectedNote(head, marker)}`)
    passed(name)
  }

  const moved = await execute(annotator, [comment(5)], { currentHead: docsHead })
  assert.deepEqual(moved.updates, [])
  assert.deepEqual(moved.creates, [])
  passed('head moved before write (no update)')

  const annotated = onlyUpdate(await execute(annotator, [comment(5)]), 5)
  const again = onlyUpdate(await execute(annotator, [{ ...comment(5), body: annotated }],
    { currentHead: docsHead, eventHead: docsHead }), 5)
  assert.equal(again, `${original(label)}\n\n${noteMarker}\n${expectedNote(docsHead, label)}`)
  assert.equal(again.split(noteMarker).length - 1, 1)
  passed('re-annotation replaces the old note and preserves results')

  const missing = [noise(1), { ...comment(2), body: '## Different bot comment' }]
  const noMatch = await execute(annotator, missing)
  assert.deepEqual(noMatch.updates, [])
  assert.deepEqual(noMatch.creates, [])
  passed('no matching comment (annotator no-op)')

  const created = await execute(publisher, missing)
  assert.equal(created.updates.length, 0)
  assert.equal(created.creates.length, 1)
  assert.equal(created.creates[0].issue_number, context.issue.number)
  const marker = `_${spec.marker} commit: ${merge} (merge of head ${head})_`
  assert.ok(created.creates[0].body.includes(marker), 'publisher must label actual merge and head')
  passed('publisher creates and labels actual merge when no comment exists')

  const longThread = Array.from({ length: 105 }, (_, i) => noise(i + 10))
  longThread.push(comment(200))
  const beyond = await execute(publisher, longThread)
  onlyUpdate(beyond, 200)
  assert.deepEqual(beyond.pages, [1, 2])
  passed('publisher finds comment beyond page 1 without creating duplicate')

  longThread[0] = comment(9)
  const published = await execute(publisher, longThread)
  const publishedBody = onlyUpdate(published, 200)
  const afterPublish = longThread.map(c => c.id === 200 ? { ...c, body: publishedBody } : c)
  const marked = await execute(annotator, afterPublish)
  const markedBody = onlyUpdate(marked, 200)
  assert.deepEqual(published.pages, [1, 2])
  assert.deepEqual(marked.pages, [1, 2])
  assert.equal(markedBody, `${publishedBody}\n\n${noteMarker}\n${expectedNote(head, `${merge} (merge of head ${head})`)}`)
  passed('publisher and annotator select SAME newest comment across pages')
}

(async () => {
  for (const spec of specs) await run(spec)
  console.log('PASS: all rendered comment publisher/annotator cases')
})().catch(error => { console.error(error); process.exitCode = 1 })
JS
