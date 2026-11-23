#!/usr/bin/env bash
# validate-toolchain-floors.sh — keep the template's own toolchain pins at or
# above the floors toolchain-floors.json declares (task validate:toolchain-floors).
#
# For every floor it validates the declaration against toolchain-floors.schema.json,
# checks every locator match against the floor, and fails when a match is below
# it or the pin has no match. Step pins check rendered YAML using Copier and yq.
# Each covered action step must have exactly one recognized input.
# A pin with a null `template_path` is repository-owned (package.json `packageManager`): the
# template never writes it, so it is reported as consumer-checked and skipped.
# A `copier` floor is held to `_min_copier_version` in copier.yml, and `when`
# must name a boolean answer in copier.yml.
#
# `ancestor` floors ask local git only (`git merge-base --is-ancestor`), never
# the network. A commit absent from the local history is "unknown" and fails
# closed — fetch full history, do not weaken the check.
#
# Usage: validate-toolchain-floors.sh [--root DIR] [--floors FILE] [--schema FILE]
#                                    [--rendered DIR] [--inventory] [--with-template-tests]
#   --root    repository to check (default: this repository); every relative
#             path and the git history resolve against it
#   --floors  declaration (default: ROOT/toolchain-floors.json)
#   --schema  schema      (default: ROOT/toolchain-floors.schema.json)
#   --rendered  one pre-rendered tree (for offline fixtures)
#   --inventory  also inventory workflows in a pre-rendered tree
#   --with-template-tests  check the six outputs of task test:template
# Exit: 0 all floors hold; 1 a floor is violated or unverifiable; 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLOORS=""
SCHEMA=""
RENDERED=""
INVENTORY=0
WITH_TEMPLATE_TESTS=0

while [ "$#" -gt 0 ]; do
    case "$1" in
    --root)
        [ "$#" -ge 2 ] || {
            echo "validate-toolchain-floors: --root needs a directory" >&2
            exit 2
        }
        ROOT="$(cd "$2" && pwd)"
        shift 2
        ;;
    --floors)
        [ "$#" -ge 2 ] || {
            echo "validate-toolchain-floors: --floors needs a file" >&2
            exit 2
        }
        FLOORS="$2"
        shift 2
        ;;
    --schema)
        [ "$#" -ge 2 ] || {
            echo "validate-toolchain-floors: --schema needs a file" >&2
            exit 2
        }
        SCHEMA="$2"
        shift 2
        ;;
    --rendered)
        [ "$#" -ge 2 ] && [ -d "$2" ] || {
            echo "validate-toolchain-floors: --rendered needs a directory" >&2
            exit 2
        }
        RENDERED="$(cd "$2" && pwd)"
        shift 2
        ;;
    --inventory)
        INVENTORY=1
        shift
        ;;
    --with-template-tests)
        WITH_TEMPLATE_TESTS=1
        shift
        ;;
    -h | --help)
        sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "validate-toolchain-floors: unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

# A relative --floors/--schema resolves against ROOT, as the usage says.
: "${FLOORS:=toolchain-floors.json}"
: "${SCHEMA:=toolchain-floors.schema.json}"
case "$FLOORS" in /*) ;; *) FLOORS="${ROOT}/${FLOORS}" ;; esac
case "$SCHEMA" in /*) ;; *) SCHEMA="${ROOT}/${SCHEMA}" ;; esac
command -v node >/dev/null 2>&1 || {
    echo "validate-toolchain-floors: node is required" >&2
    exit 1
}

[ -z "$RENDERED" ] || [ "$WITH_TEMPLATE_TESTS" = 0 ] || {
    echo "validate-toolchain-floors: --rendered and --with-template-tests are mutually exclusive" >&2
    exit 2
}

exec node --input-type=module - "$ROOT" "$FLOORS" "$SCHEMA" "$SCRIPT_DIR" "$RENDERED" "$INVENTORY" "$WITH_TEMPLATE_TESTS" <<'NODE'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [root, floorsPath, schemaPath, scripts, rendered, inventory, withTemplateTests] = process.argv.slice(2)
const { createSchemaValidator } = await import(pathToFileURL(path.join(scripts, 'lib/json-schema-subset.mjs')).href)

const errors = []
const fail = (message) => errors.push(message)
const say = (message) => console.log(message)

function loadJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    console.error(`toolchain-floors: cannot read valid JSON for ${label} from ${file}: ${error.message}`)
    process.exit(1)
  }
}

const declaration = loadJson(floorsPath, 'the floors file')
const schema = loadJson(schemaPath, 'the schema')
const engine = createSchemaValidator(schema)
try {
  engine.assertSupportedSchema(schema)
} catch (error) {
  console.error(`toolchain-floors: invalid or unsupported schema: ${error.message}`)
  process.exit(1)
}
const schemaErrors = engine.validate(declaration, schema, '$floors')
if (schemaErrors.length > 0) {
  for (const message of schemaErrors) console.error(`toolchain-floors: ${message}`)
  console.error('toolchain-floors: FAIL — the declaration does not match its schema')
  process.exit(1)
}
if (declaration?.schema_version !== 2) {
  console.error('toolchain-floors: unsupported schema_version; expected 2')
  process.exit(1)
}

// Dotted numeric versions: compare component-wise, missing components are 0.
function compareVersions(left, right) {
  const a = left.split('.').map(Number)
  const b = right.split('.').map(Number)
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0)
    if (diff !== 0) return diff < 0 ? -1 : 1
  }
  return 0
}

// A path from the declaration must stay inside the checked repository.
function insideRoot(relative) {
  const resolved = path.resolve(root, relative)
  return !path.isAbsolute(relative) && (resolved === root || resolved.startsWith(root + path.sep))
    ? resolved
    : null
}

// Git runs against ROOT alone: a hook-exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE
// must not retarget it.
const gitEnv = Object.fromEntries(
  Object.entries(process.env).filter(
    ([name]) =>
      !/^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|PREFIX|NAMESPACE|CEILING_DIRECTORIES)$/.test(name)
  )
)

function git(args) {
  return spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', env: gitEnv })
}

// The unpeeled object type: an annotated tag's id is not the commit it points at.
function objectType(sha) {
  const result = git(['cat-file', '-t', sha])
  return result.status === 0 ? result.stdout.trim() : null
}

function checkAncestor(label, minimum, pinned) {
  const notCommits = [minimum, pinned].filter((sha) => ![null, 'commit'].includes(objectType(sha)))
  if (notCommits.length > 0) {
    for (const sha of notCommits) fail(`${label}: ${sha} is a ${objectType(sha)} object, not a commit`)
    return false
  }
  const missing = [minimum, pinned].filter((sha) => objectType(sha) === null)
  if (missing.length > 0) {
    fail(
      `${label}: unknown — commit ${missing.join(', ')} is not in the local git history ` +
        '(fetch full history; the check never asks the network and fails closed)'
    )
    return false
  }
  const result = git(['merge-base', '--is-ancestor', minimum, pinned])
  if (result.status === 0) return true
  if (result.status === 1) {
    if (git(['rev-parse', '--is-shallow-repository']).stdout.trim() === 'true') {
      fail(
        `${label}: unknown — this clone is shallow, so no path from ${minimum} to ${pinned} is unproven, not disproven ` +
          '(fetch full history; the check never asks the network and fails closed)'
      )
    } else {
      fail(`${label}: pinned commit ${pinned} does not descend from the floor commit ${minimum}`)
    }
  } else {
    fail(`${label}: unknown — git merge-base --is-ancestor exited ${result.status}: ${result.stderr.trim()}`)
  }
  return false
}

// copier.yml: the declared minimum copier and the boolean answers `when` may name.
let copierYml = null
const copierYmlPath = path.join(root, 'copier.yml')
if (fs.existsSync(copierYmlPath)) copierYml = fs.readFileSync(copierYmlPath, 'utf8')

function booleanAnswer(name) {
  if (copierYml === null) return null
  const lines = copierYml.split('\n')
  const start = lines.findIndex((line) => new RegExp(`^${name}:\\s*(?:#.*)?$`).test(line))
  if (start === -1) return false
  // Only the question's own `type:` (two-space indent) counts; deeper lines are
  // block-scalar text such as `help:`.
  for (let i = start + 1; i < lines.length && /^(\s|$)/.test(lines[i]); i += 1) {
    if (/^ {2}type:\s*(?:bool|'bool'|"bool")(?:\s+#.*)?\s*$/.test(lines[i])) return true
  }
  return false
}

function readSteps(label, source) {
  const result = spawnSync('yq', ['-o=json', '-I=0', `
    [(.runs.steps, .jobs[].steps) | explode(.) | select(tag == "!!seq") | .[]
      | select(tag == "!!map")
      | {"uses": .uses, "line": line, "style": style,
         "inputStyle": (.with | style),
         "inputs": [(.with | select(tag == "!!map") | to_entries | .[]
           | {"name": .key, "line": (.value | line), "column": (.value | column),
              "value": (.value | to_string)})]}]
  `, '-'], { input: source, encoding: 'utf8' })
  if (result.status !== 0) {
    fail(`${label}: cannot enumerate steps with Mike Farah yq: ${result.error?.message ?? result.stderr.trim()}`)
    return []
  }

  try {
    return JSON.parse(result.stdout).map((step) => ({
      ...step,
      action: typeof step.uses === 'string' ? step.uses.toLowerCase().split('@')[0].replace(/\/\.$/, '') : ''
    }))
  } catch (error) {
    fail(`${label}: cannot read steps from yq: ${error.message}`)
    return []
  }
}

function versionsIn(source, regex) {
  return [...source.matchAll(regex)].map((match) => ({
    pinned: match[1], capture: match.indices?.[1]?.[0], locations: []
  }))
}

function associateStepPins(label, source, steps, { action, input, pattern_scope: scope }, versions, regex, compare) {
  const covered = steps.filter((step) => step.action === action)
  if (covered.length === 0) fail(`${label}: no ${action} steps found`)

  const lines = source.split('\n')
  const starts = [0]
  for (const line of lines) starts.push(starts[starts.length - 1] + line.length + 1)

  for (const step of covered) {
    const here = `${label}:${step.line}`
    if (step.style === 'flow' || step.inputStyle === 'flow') {
      fail(`${here}: ${action} step uses an unsupported flow-style mapping`)
      continue
    }
    const inputs = step.inputs.filter(({ name }) => name === input)
    if (inputs.length !== 1) {
      fail(`${here}: ${action} step needs exactly one ${input} input (found ${inputs.length})`)
      continue
    }

    const [{ line, column, value }] = inputs
    const location = `${label}:${line}:${column}`
    let captures
    if (scope === 'value') {
      captures = versionsIn(value, regex)
      for (const capture of captures) capture.locations.push(location)
      versions.push(...captures)
    } else {
      // yq columns count characters; RegExp indices count UTF-16 code units.
      const text = lines[line - 1] ?? ''
      const prefix = Array.from(text).slice(0, column - 1).join('')
      const start = starts[line - 1] + prefix.length
      const valueStart = /^["']/.test(source[start]) ? start + 1 : start
      captures = versions.filter(({ capture }) => capture === valueStart)
    }
    const pinned = captures[0]?.pinned
    const matchesValue = pinned === value ||
      (compare === 'major' && pinned !== undefined && value.startsWith(pinned) &&
        /^(?:\.[0-9]+)+$/.test(value.slice(pinned.length)))
    if (captures.length !== 1 || !matchesValue) {
      fail(`${location}: ${action} step needs exactly one recognized ${input} version`)
      continue
    }
    if (scope !== 'value') captures[0].locations.push(location)
  }
}

function isFile(file) {
  return fs.statSync(file, { throwIfNoEntry: false })?.isFile() === true
}

function floorRenders() {
  if (rendered) return [{ dir: rendered, name: 'rendered' }]
  for (const [command, name] of [['copier', 'Copier'], ['yq', 'Mike Farah yq']]) {
    const result = spawnSync(command, ['--version'], { encoding: 'utf8' })
    if (result.status !== 0 || (command === 'yq' && !result.stdout.includes('mikefarah/yq'))) {
      fail(`${name} is required to check rendered YAML — run 'task install'`)
    }
  }
  if (errors.length > 0) return []

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'toolchain-floors-'))
  process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }))
  const profiles = ['full', 'minimal', 'web', 'webapp', 'iac', 'meta']
    .map((name) => ({ dir: path.join(scratch, name), name }))
  if (withTemplateTests === '1') {
    const result = spawnSync('task', ['test:template'], {
      cwd: root, stdio: 'inherit', env: { ...gitEnv, TOOLCHAIN_FLOORS_SMOKE_OUTPUT: scratch }
    })
    if (result.status !== 0) {
      fail(`template smoke tests failed: ${result.error?.message ?? result.signal ?? result.status}`)
      return []
    }
    for (const { dir, name } of profiles) {
      if (!fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory()) {
        fail(`${name}: template smoke test did not provide its render`)
        return []
      }
    }
    return profiles
  }
  for (const { dir, name } of profiles) {
    const result = spawnSync(path.join(scripts, 'test-template.sh'), [name, 'render-only', dir, root], {
      encoding: 'utf8', env: gitEnv
    })
    if (result.status !== 0) {
      fail(`${name}: Copier render failed: ${result.error?.message ?? result.stderr.trim()}`)
      return []
    }
  }
  return profiles
}

const knownSteps = new Map([
  ['actions/setup-node', { tool: 'node', input: 'node-version' }],
  ['arduino/setup-task', { tool: 'task', input: 'version' }]
])

function checkInventory(dir, profile, getSteps) {
  const workflows = '.github/workflows'
  const workflowDir = path.join(dir, workflows)
  const files = fs.existsSync(workflowDir)
    ? fs.readdirSync(workflowDir).filter((name) => /\.ya?ml$/.test(name)).map((name) => path.join(workflows, name))
    : []
  files.push('.github/actions/setup/action.yml')
  for (const file of files) {
    if (!isFile(path.join(dir, file))) continue
    for (const { action, line } of getSteps(file)) {
      const known = knownSteps.get(action)
      if (!known) continue
      const floor = declaration.floors.find(({ tool }) => tool === known.tool)
      if (!floor?.pins.some((pin) => pin.path === file && pin.step?.action === action && pin.step.input === known.input)) {
        fail(`${file} [${profile}]:${line}: undeclared ${action} step with input ${known.input} in the ${known.tool} floor`)
      }
    }
  }
}

function renderPath(templatePath) {
  return templatePath.replace(/^template\//, '').replace(/\[%[^%]*%\]/g, '').replace(/\.jinja$/, '')
}

const renders = floorRenders().map(({ dir, name }) => {
  const cache = new Map()
  function getSteps(file) {
    if (!cache.has(file)) cache.set(file, readSteps(`${name} ${file}`, fs.readFileSync(path.join(dir, file), 'utf8')))
    return cache.get(file)
  }
  if (!rendered || inventory === '1') checkInventory(dir, name, getSteps)
  return { dir, name, getSteps }
})

const seenTools = new Set()
for (const floor of declaration.floors) {
  const { tool, minimum, compare, pins } = floor
  const gate = floor.when ? `, when ${floor.when}` : ''
  say(`toolchain-floors: ${tool} (${compare} >= ${minimum}${gate})`)
  if (seenTools.has(tool)) fail(`${tool}: declared more than once`)
  seenTools.add(tool)

  if (floor.when !== undefined) {
    const answer = booleanAnswer(floor.when)
    if (answer === null) fail(`${tool}: cannot check when "${floor.when}" — no copier.yml in ${root}`)
    else if (!answer) fail(`${tool}: when "${floor.when}" is not a boolean answer in copier.yml`)
  }

  if (tool === 'copier') {
    if (compare !== 'version') fail('copier: must compare by version')
    const declared = copierYml === null ? null : /^_min_copier_version:\s*["']?([0-9][0-9.]*)["']?\s*(?:#.*)?$/m.exec(copierYml)
    if (declared === null) {
      fail('copier: copier.yml declares no _min_copier_version to hold the floor against')
    } else if (!/^[0-9]+(\.[0-9]+)*$/.test(declared[1])) {
      fail(`copier: _min_copier_version "${declared[1]}" is not a dotted numeric version, so the floor cannot be verified`)
    } else if (compare === 'version' && compareVersions(minimum, declared[1]) > 0) {
      fail(`copier: floor ${minimum} exceeds _min_copier_version ${declared[1]} in copier.yml`)
    } else {
      say(`  ok   copier.yml _min_copier_version ${declared[1]} >= floor ${minimum}`)
    }
  }

  if (pins.length === 0 && tool !== 'copier') {
    fail(`${tool}: declares no pins, so nothing enforces its floor (only copier is checked against copier.yml)`)
  }

  for (const pin of pins) {
    const label = `${tool} ${pin.path}`
    // 9: a pattern is a published contract whoever owns the pin, so compile it first.
    let regex
    try {
      regex = new RegExp(pin.pattern, pin.step === undefined ? 'gm' : 'gmd')
    } catch (error) {
      fail(`${label}: pattern does not compile: ${error.message}`)
      continue
    }
    if (new RegExp(`${pin.pattern}|`, 'm').exec('').length < 2) {
      fail(`${label}: pattern has no capture group 1`)
      continue
    }
    if (pin.template_path === null) {
      say(`  consumer-checked  ${pin.path}${pin.json_pointer ? ` (${pin.json_pointer})` : ''} — repository-owned, not in the template`)
      continue
    }
    // The consumer path is what template_path renders to: drop the template/ root,
    // each [% … %] tag, and the .jinja suffix.
    const target = renderPath(pin.template_path)
    if (target !== pin.path) {
      fail(`${label}: path is not what ${pin.template_path} renders to (${target})`)
      continue
    }
    if (pin.json_pointer !== undefined) {
      fail(`${label}: json_pointer needs a consumer file; a template_path pin is matched as raw text`)
      continue
    }
    const file = insideRoot(pin.template_path)
    if (file === null) {
      fail(`${label}: template_path ${pin.template_path} leaves the repository`)
      continue
    }
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      fail(`${label}: template_path ${pin.template_path} does not exist`)
      continue
    }
    const fileLabel = `${label} (${pin.template_path})`
    const versions = []
    if (pin.step === undefined) {
      versions.push(...versionsIn(fs.readFileSync(file, 'utf8'), regex))
      if (versions.length === 0) fail(`${label}: pattern matches nothing in ${pin.template_path}`)
    } else {
      let found = false
      for (const { dir, name, getSteps } of renders) {
        const output = path.join(dir, pin.path)
        if (!isFile(output)) continue
        found = true
        const source = fs.readFileSync(output, 'utf8')
        const matches = pin.step.pattern_scope === 'value' ? [] : versionsIn(source, regex)
        associateStepPins(`${fileLabel} [${name}]`, source, getSteps(pin.path), pin.step, matches, regex, compare)
        for (const match of matches) {
          if (match.locations.length === 0) match.locations.push(`${fileLabel} [${name}]`)
          versions.push(match)
        }
      }
      if (!found) fail(`${label}: ${pin.template_path} is absent from every checked render`)
    }
    // Check each locator match once, including matches outside covered steps.
    for (const { pinned, locations } of versions) {
      const here = locations[0] ?? fileLabel
      let success
      if (pinned === undefined) {
        fail(`${here}: pattern has no capture group 1`)
      } else if (compare === 'ancestor') {
        if (!/^[0-9a-f]{40}$/.test(pinned)) fail(`${here}: "${pinned}" is not a 40-character commit`)
        else if (checkAncestor(here, minimum, pinned)) success = `${pinned} descends from ${minimum}`
      } else if (!/^[0-9]+(\.[0-9]+)*$/.test(pinned) || (compare === 'major' && !/^[0-9]+$/.test(pinned))) {
        fail(`${here}: "${pinned}" is not a ${compare === 'major' ? 'major version' : 'dotted numeric version'}`)
      } else if (compare === 'major' ? Number(pinned) < Number(minimum) : compareVersions(pinned, minimum) < 0) {
        fail(`${here}: pinned ${pinned} is below the floor ${minimum}`)
      } else {
        success = `${pinned} >= ${minimum}`
      }
      if (success !== undefined) {
        for (const location of locations.length === 0 ? [fileLabel] : locations) {
          say(`  ok   ${location}: ${success}`)
        }
      }
    }
  }
}

if (errors.length > 0) {
  for (const message of errors) console.error(`toolchain-floors: ${message}`)
  console.error(`toolchain-floors: FAIL — ${errors.length} problem(s)`)
  process.exit(1)
}
say('toolchain-floors: ok')
NODE
