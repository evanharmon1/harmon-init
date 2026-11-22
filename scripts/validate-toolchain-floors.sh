#!/usr/bin/env bash
# validate-toolchain-floors.sh — keep the template's own toolchain pins at or
# above the floors toolchain-floors.json declares (task validate:toolchain-floors).
#
# For every floor it validates the declaration against toolchain-floors.schema.json,
# then for every pin with a non-null `template_path` reads that file's raw text
# (Jinja and all), checks every `pattern` match against the floor, and fails
# when a match is below it or when the file has no match at all. A `step` pin
# uses yq to find the action's steps and requires a recognized input in each.
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
#   --root    repository to check (default: this repository); every relative
#             path and the git history resolve against it
#   --floors  declaration (default: ROOT/toolchain-floors.json)
#   --schema  schema      (default: ROOT/toolchain-floors.schema.json)
# Exit: 0 all floors hold; 1 a floor is violated or unverifiable; 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLOORS=""
SCHEMA=""

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

exec node --input-type=module - "$ROOT" "$FLOORS" "$SCHEMA" "${SCRIPT_DIR}/lib/json-schema-subset.mjs" <<'NODE'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [root, floorsPath, schemaPath, enginePath] = process.argv.slice(2)
const { createSchemaValidator } = await import(pathToFileURL(enginePath).href)

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

function stepPins(label, source, { action, input }, regex) {
  // Blank Jinja control lines and mask substitutions for structural parsing.
  // Preserve source line numbers and apply the pattern to the original text.
  const lines = source.split(/\r?\n/)
  const jinjaControl = /^ *\[%.*%\] *$/
  const yaml = lines.map((line) => jinjaControl.test(line) ? '' : line.replace(/\[\[.*?\]\]/g, 'JINJA')).join('\n')
  const result = spawnSync('yq', ['-o=json', '-I=0', `
    [(.runs.steps[]?, .jobs[].steps[]?)
      | explode(.)
      | select(tag == "!!map")
      | select((.uses | downcase | split("@") | .[0]) == strenv(FLOOR_STEP_ACTION))]
    | map({"line": line, "usesLine": (.uses | line), "style": style, "inputStyle": (.with | style),
         "inputs": [(.with | select(tag == "!!map") | to_entries | .[]
           | select(.key == strenv(FLOOR_STEP_INPUT))
           | {"line": (.key | line), "value": (.value | to_string)})]})
  `, '-'], {
    input: yaml,
    encoding: 'utf8',
    env: { ...process.env, FLOOR_STEP_ACTION: action, FLOOR_STEP_INPUT: input }
  })
  if (result.status !== 0) {
    fail(`${label}: cannot enumerate ${action} steps with Mike Farah yq: ${result.error?.message ?? result.stderr.trim()}`)
    return []
  }

  let steps
  try {
    steps = JSON.parse(result.stdout)
    if (!Array.isArray(steps)) throw new Error('expected a YAML step list')
  } catch (error) {
    fail(`${label}: cannot read ${action} steps from yq: ${error.message}`)
    return []
  }
  if (steps.length === 0) fail(`${label}: no ${action} steps found`)

  // Evaluate the locator against the untouched file, including context outside
  // the step. Use capture group 1's position, since the match can span lines.
  const capturesByLine = new Map()
  for (const match of source.matchAll(new RegExp(regex, regex.flags + 'd'))) {
    const capture = match.indices[1]
    if (capture === undefined) continue
    const [start, end] = capture
    if (source.slice(start, end).includes('\n')) continue
    const line = source.slice(0, start).split('\n').length
    const captures = capturesByLine.get(line) ?? []
    captures.push(match[1])
    capturesByLine.set(line, captures)
  }

  const pins = []
  for (const step of steps) {
    const here = `${label}:${step.line}`
    if (step.style === 'flow' || step.inputStyle === 'flow') {
      fail(`${here}: ${action} step uses an unsupported flow-style mapping`)
      continue
    }
    if (step.inputs.length !== 1) {
      fail(`${here}: ${action} step needs exactly one ${input} input (found ${step.inputs.length})`)
      continue
    }
    const [version] = step.inputs
    let first = Math.min(step.line, step.usesLine, version.line) - 1
    const last = Math.max(step.usesLine, version.line) - 1
    // yq reports the first key for a mapping whose list dash is on its own
    // line. Include any directives between that dash and the first key.
    let previous = first - 1
    while (previous >= 0 && (/^\s*(?:#.*)?$/.test(lines[previous]) || jinjaControl.test(lines[previous]))) previous -= 1
    if (previous >= 0 && /^ *- *(?:#.*)?$/.test(lines[previous])) first = previous
    // Ignore whole-step guards outside this range and controls after both
    // fields, such as the shared setup action's conditional cache input.
    if (lines.slice(first, last + 1).some((line) => jinjaControl.test(line))) {
      fail(`${here}: Jinja control prevents verifying the ${action} step's uses and ${input} input together`)
      continue
    }
    const captures = capturesByLine.get(version.line) ?? []
    if (captures.length !== 1 || captures[0] !== version.value) {
      fail(`${here}: ${action} step needs exactly one recognized ${input} version`)
      continue
    }
    pins.push({ pinned: captures[0], here })
  }
  return pins
}

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
      regex = new RegExp(pin.pattern, 'gm')
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
    const rendered = pin.template_path.replace(/^template\//, '').replace(/\[%[^%]*%\]/g, '').replace(/\.jinja$/, '')
    if (rendered !== pin.path) {
      fail(`${label}: path is not what ${pin.template_path} renders to (${rendered})`)
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
    const source = fs.readFileSync(file, 'utf8')
    const here = `${label} (${pin.template_path})`
    const versions = pin.step === undefined
      ? [...source.matchAll(regex)].map((match) => ({ pinned: match[1], here }))
      : stepPins(here, source, pin.step, regex)
    if (pin.step === undefined && versions.length === 0) {
      fail(`${label}: pattern matches nothing in ${pin.template_path}`)
    }
    for (const { pinned, here } of versions) {
      if (pinned === undefined) {
        fail(`${here}: pattern has no capture group 1`)
      } else if (compare === 'ancestor') {
        if (!/^[0-9a-f]{40}$/.test(pinned)) fail(`${here}: "${pinned}" is not a 40-character commit`)
        else if (checkAncestor(here, minimum, pinned)) say(`  ok   ${here}: ${pinned} descends from ${minimum}`)
      } else if (!/^[0-9]+(\.[0-9]+)*$/.test(pinned) || (compare === 'major' && !/^[0-9]+$/.test(pinned))) {
        fail(`${here}: "${pinned}" is not a ${compare === 'major' ? 'major version' : 'dotted numeric version'}`)
      } else if (compare === 'major' ? Number(pinned) < Number(minimum) : compareVersions(pinned, minimum) < 0) {
        fail(`${here}: pinned ${pinned} is below the floor ${minimum}`)
      } else {
        say(`  ok   ${here}: ${pinned} >= ${minimum}`)
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
