#!/usr/bin/env bash
# test-renovate-config.sh — strictly validate rendered Renovate configuration
# for one template profile or the complete profile matrix.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

requested="${1:-all}"
case "$requested" in
all)
    profiles=(minimal web webapp iac full meta update)
    ;;
minimal | web | webapp | iac | full | meta | update)
    profiles=("$requested")
    ;;
*)
    echo "Unknown profile: ${requested}" >&2
    exit 2
    ;;
esac

if ! command -v npx >/dev/null 2>&1; then
    echo "FAIL: required tool 'npx' is not installed for strict Renovate configuration validation" >&2
    exit 1
fi

# Validate the dogfood layer and published preset before rendering profiles.
# renovate: datasource=npm depName=renovate
RENOVATE_VALIDATOR_VERSION=44.216.5
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate-config-validator --strict renovate.json
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate-config-validator --strict --no-global renovate/default.json

# Exercise Renovate's own extraction and replacement, not a hand-written
# string substitution. Resolve imports from this same pinned npx package.
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    sh -c 'node --input-type=module - "$(command -v renovate)"' <<'JS'
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const dist = dirname(realpathSync(process.argv[2]));
const load = (path) => import(pathToFileURL(resolve(dist, path)).href);
const { init } = await load('logger/index.js');
await init();
const { GlobalConfig } = await load('config/global.js');
const localDir = mkdtempSync(resolve(tmpdir(), 'renovate-version-quotes-'));
GlobalConfig.set({ localDir });
try {
    const { extractPackageFile } = await load('modules/manager/custom/regex/index.js');
    const { doAutoReplace } = await load('workers/repository/update/branch/auto-replace.js');
    const { api: semver } = await load('modules/versioning/semver/index.js');
    const require = createRequire(resolve(dist, 'renovate.js'));
    const YAML = require('yaml');
    const configs = ['renovate.json', 'renovate/default.json', 'template/renovate.json.jinja'];
    let checked = 0;
    for (const file of configs) {
        // All conditional managers enabled, as in the existing pin-policy tests.
        const config = JSON.parse(readFileSync(file, 'utf8').replace(/\[%[^%]*%\]/g, ''));
        for (const packageFile of ['.github/workflows/fixture.yml', '.github/actions/fixture/action.yml']) {
            const managers = config.customManagers.filter((m) =>
                m.managerFilePatterns.some((p) => new RegExp(p.slice(1, -1)).test(packageFile)) &&
                m.matchStrings.some((p) => p.includes('version:\\s*')));
            assert.equal(managers.length, 1, `${file}: ${packageFile}`);
            const manager = managers[0];
            for (const quote of ['', "'", '"']) {
                // Include a numeric-looking version to catch accidental YAML numbers.
                for (const [currentValue, newValue] of [['3.44.1', '3.45.0'], ['3.0', '3.1']]) {
                    for (const extractVersion of [undefined, '^v(?<version>.+)$']) {
                        const annotation = '# renovate: datasource=github-releases depName=go-task/task' +
                            (extractVersion ? ` extractVersion=${extractVersion}` : '');
                        const content = `${annotation}\nversion: ${quote}${currentValue}${quote}\n`;
                        const extracted = extractPackageFile(content, packageFile, manager);
                        assert.equal(extracted?.deps.length, 1);
                        const dep = extracted.deps[0];
                        assert.equal(dep.currentValue, currentValue);
                        assert.equal(dep.depName, 'go-task/task');
                        assert.equal(dep.datasource, 'github-releases');
                        assert.equal(dep.extractVersion, extractVersion);
                        if (currentValue === '3.44.1') assert.ok(semver.isValid(dep.currentValue));
                        const updated = await doAutoReplace({
                            ...manager, ...dep, manager: 'regex', packageFile,
                            depIndex: 0, newValue, autoReplaceGlobalMatch: true,
                        }, content, false);
                        assert.equal(updated, `${annotation}\nversion: ${quote}${newValue}${quote}\n`);
                        const parsed = YAML.parse(updated).version;
                        assert.equal(parsed, quote || newValue === '3.45.0' ? newValue : Number(newValue));
                        if (quote) assert.equal(typeof parsed, 'string');
                        checked++;
                    }
                }
            }
        }
    }
    console.log(`Pinned Renovate: ${checked} bare-version extraction/replacement cases passed`);
} finally {
    rmSync(localDir, { recursive: true, force: true });
}
JS

# The dogfood .coderabbit.yaml against CodeRabbit's published schema. Each
# profile's render is validated the same way inside test-template.sh (#1908).
if ! command -v uvx >/dev/null 2>&1; then
    echo "FAIL: required tool 'uvx' is not installed for CodeRabbit schema validation" >&2
    exit 1
fi
# renovate: datasource=pypi depName=check-jsonschema
CHECK_JSONSCHEMA_VERSION=0.39.0
uvx --from "check-jsonschema==${CHECK_JSONSCHEMA_VERSION}" check-jsonschema \
    --schemafile https://coderabbit.ai/integrations/schema.v2.json .coderabbit.yaml

for profile in "${profiles[@]}"; do
    if [ "$profile" = "update" ]; then
        ./scripts/test-template-update.sh renovate-config
    else
        ./scripts/test-template.sh "$profile" renovate-config
    fi
done
