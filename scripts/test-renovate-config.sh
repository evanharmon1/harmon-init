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

# Render only the policy and its answers. Use the actual Copier questions on
# both sides so conditional defaults, unavailable answers and updates are
# exercised without a second full template render.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/harmon-init-renovate.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
source="$fixture/template-source"
mkdir -p "$source/template"
answers='template/[[ _copier_conf.answers_file ]].jinja'
# Main at the start of the pilot. This is the golden for the opt-out promise.
golden=3b6262b41e29f615acc7ed1e8b1c16fd1dc60a72
for file in copier.yml template/renovate.json.jinja "$answers"; do
    git show "$golden:$file" >"$source/$file"
done

fixture_git() {
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.org -c commit.gpgsign=false "${@:2}"
}
fixture_git "$source" init -q
fixture_git "$source" add -A
fixture_git "$source" commit -qm "golden Renovate policy"
fixture_git "$source" tag v0.0.1
for file in copier.yml template/renovate.json.jinja "$answers"; do
    cp "$file" "$source/$file"
done
fixture_git "$source" add -A
fixture_git "$source" commit -qm "candidate Renovate policy"
fixture_git "$source" tag v0.0.2

fixture_copy() {
    local version=$1 destination=$2
    shift 2
    copier copy "$source" "$destination" --vcs-ref="$version" --trust --defaults --skip-tasks \
        --data 'project_name=Renovate Pilot' "$@" >"$fixture/copier.log" 2>&1 ||
        {
            cat "$fixture/copier.log" >&2
            return 1
        }
}

case "$requested" in
all | update) policy_profiles=(minimal general web webapp iac docs full meta) ;;
minimal) policy_profiles=(minimal general docs) ;;
*) policy_profiles=("$requested") ;;
esac

for profile in "${policy_profiles[@]}"; do
    case "$profile" in
    minimal) opts=(--data project_type=general --data devcontainer=false --data use_skills_sync=false) ;;
    general | iac | docs) opts=(--data "project_type=$profile") ;;
    web) opts=(--data project_type=web-astro) ;;
    webapp) opts=(--data project_type=web-app) ;;
    full) opts=(--data project_type=web-astro --data include_ansible=true --data include_terraform=true) ;;
    meta) opts=(--data project_type=web-app --data devcontainer=false --data use_skills_sync=false) ;;
    esac

    old="$fixture/$profile-golden"
    inline="$fixture/$profile-inline"
    opted="$fixture/$profile-opted"
    fixture_copy v0.0.1 "$old" "${opts[@]}"
    fixture_copy v0.0.2 "$inline" "${opts[@]}"
    diff -u "$old/renovate.json" "$inline/renovate.json"
    fixture_copy v0.0.2 "$opted" "${opts[@]}" --data use_renovate_preset=true
    case "$profile" in
    web | webapp | full | meta) ;;
    *) diff -u "$old/renovate.json" "$opted/renovate.json" ;;
    esac

    if [ "$requested" = all ] || [ "$requested" = update ]; then
        fixture_git "$old" init -q
        fixture_git "$old" add -A
        fixture_git "$old" commit -qm "scaffold with pre-pilot answers"
        (cd "$old" && copier update --vcs-ref=v0.0.2 --trust --defaults --skip-tasks) >"$fixture/copier.log" 2>&1 ||
            {
                cat "$fixture/copier.log" >&2
                exit 1
            }
        diff -u "$inline/renovate.json" "$old/renovate.json"
        echo "Golden inline policy unchanged for $profile copy and update"
    else
        echo "Golden inline policy unchanged for $profile copy"
    fi
done

# Exercise each local manager as the sole member of the opted-in array. These
# fixtures compare current inline and opted-in policy without a golden update.
case "$requested" in
all | update | web)
    for single in skills-only devcontainer-only; do
        case "$single" in
        skills-only) opts=(--data use_skills_sync=true --data devcontainer=false) ;;
        devcontainer-only) opts=(--data use_skills_sync=false --data devcontainer=true) ;;
        esac
        fixture_copy v0.0.2 "$fixture/web-$single-inline" --data project_type=web-astro "${opts[@]}"
        fixture_copy v0.0.2 "$fixture/web-$single-opted" --data project_type=web-astro "${opts[@]}" \
            --data use_renovate_preset=true
    done
    ;;
esac

# The pilot uses this release's immutable blob. A local preset edit must not
# make the resolution test pass for bytes consumers cannot fetch.
preset_tag=v5.21.0
git show "refs/tags/$preset_tag:renovate/default.json" >"$fixture/tagged-preset.json"

# Validate the dogfood layer and published preset before rendering profiles.
# renovate: datasource=npm depName=renovate
RENOVATE_VALIDATOR_VERSION=44.252.8
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate-config-validator --strict renovate.json
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate-config-validator --strict --no-global renovate/default.json

# Exercise Renovate's own extraction and replacement, not a hand-written
# string substitution. Resolve imports from this same pinned npx package.
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    sh -c 'node --input-type=module - "$(command -v renovate)" "$@"' sh "$fixture" "$preset_tag" <<'JS'
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { isDeepStrictEqual } from 'node:util';
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
    const { massageConfig } = await load('config/massage.js');
    const { migrateConfig } = await load('config/migration.js');
    const { parsePreset } = await load('config/presets/parse.js');
    const { resolveConfigPresets } = await load('config/presets/index.js');
    const { validateConfig } = await load('config/validation.js');
    const { set } = await load('util/cache/memory/index.js');
    const { buildCacheKey } = await load('util/cache/package/key.js');
    const { applyPackageRules } = await load('util/package-rules/index.js');
    const { matchRegexOrGlobList } = await load('util/string-match.js');
    const { extractPackageFile: extractConfig } = await load('modules/manager/renovate-config/index.js');
    const require = createRequire(resolve(dist, 'renovate.js'));
    const YAML = require('yaml');
    const configs = ['renovate.json', 'renovate/default.json', 'template/renovate.json.jinja'];
    let checked = 0;
    for (const file of configs) {
        // All conditional managers enabled, as in the existing pin-policy tests.
        const source = readFileSync(file, 'utf8');
        const inline = file.endsWith('.jinja') ? source.split('\n[% else %]\n')[1] : source;
        const config = JSON.parse(inline.replace(/\[%[^%]*%\]/g, ''));
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

    const [fixture, tag] = process.argv.slice(3);
    const readConfig = (file) => JSON.parse(readFileSync(resolve(fixture, file), 'utf8'));
    const tagged = readConfig('tagged-preset.json');
    const repo = 'evanharmon1/harmon-init';
    const reference = `github>${repo}//renovate/default#${tag}`;
    assert.deepEqual(parsePreset(reference), {
        presetSource: 'github', presetPath: 'renovate', repo, presetName: 'default', tag,
        params: undefined, rawParams: undefined,
    });
    // Seed only the named preset fetch. Built-ins and every merge operation
    // still go through Renovate's normal resolver.
    set(buildCacheKey('preset', reference), tagged);
    const normalized = (config) => massageConfig(migrateConfig(config).migratedConfig);
    const resolved = async (config) => (await resolveConfigPresets(normalized(config))).config;
    const effectivePolicy = async (dep, packageRules) => {
        const { packageRules: _, description, ...effective } = await applyPackageRules({ ...dep, packageRules });
        return effective;
    };
    const existsIn = (object, list) => list.some((value) => isDeepStrictEqual(value, object));
    const policyFields = ({ description, ...fields }) => fields;
    const inherited = await resolved({ extends: [reference] });
    const pinPolicy = {
        matchManagers: ['renovate-config'], matchDatasources: ['github-tags'], matchPackageNames: [repo], enabled: false,
    };
    const lockfileManagers = ['npm', 'pep621', 'gomod', 'terraform'];
    const precedenceRules = tagged.packageRules.filter((rule) => rule.matchUpdateTypes &&
        rule.matchManagers?.every((manager) => lockfileManagers.includes(manager)) &&
        Object.hasOwn(rule, 'groupName'));
    const sharedFormatter = tagged.packageRules.find((rule) => rule.groupName === 'Formatters');
    assert.deepEqual(sharedFormatter.matchPackageNames, ['markdownlint-cli2']);

    // Cover shared/local interactions and nearby dependencies that must not
    // match, at both extraction time and after Renovate knows the update type.
    const dependencies = [
        ['github-actions', 'anthropics/claude-code-action', 'github-tags', '.github/workflows/review.yml'],
        ['github-actions', 'actions/checkout', 'github-tags', '.github/workflows/review.yml'],
        ['custom.regex', 'go-task/task', 'github-releases', '.github/workflows/build.yml'],
        ['custom.regex', 'koalaman/shellcheck', 'github-release-attachments', '.github/actions/setup/action.yml'],
        ['custom.regex', 'koalaman/shellcheck', 'github-releases', 'scripts/tool.sh'],
        ['dockerfile', 'ubuntu', 'docker', '.devcontainer/Dockerfile'],
        ['dockerfile', 'node', 'docker', 'Dockerfile'],
        ['custom.regex', 'node', 'node-version', '.devcontainer/Dockerfile'],
        ['github-actions', 'node', 'github-releases', '.github/workflows/build.yml', 'uses-with'],
        ['github-actions', 'node', 'docker', '.github/workflows/build.yml', 'container'],
        ['npm', 'node', 'node-version', 'package.json', 'engines'],
        ['npm', '@types/node', 'npm', 'package.json', 'devDependencies'],
        ['npm', 'typescript', 'npm', 'package.json', 'devDependencies'],
        ['custom.regex', 'typescript', 'npm', 'Taskfile.yml'],
        ['npm', 'pnpm', 'npm', 'package.json', 'packageManager'],
        ['npm', 'pnpm', 'npm', 'package.json', 'devDependencies'],
        ['npm', 'minimatch', 'npm', 'pnpm-workspace.yaml', 'pnpm-workspace.overrides'],
        ['npm', 'minimatch', 'npm', 'package.json', 'dependencies'],
        ['npm', 'prettier', 'npm', 'package.json', 'devDependencies'],
        ['npm', 'prettier-plugin-astro', 'npm', '.devcontainer/package.json', 'devDependencies'],
        ['npm', 'prettier-config-example', 'npm', 'package.json', 'devDependencies'],
        ['custom.regex', 'prettier-plugin-astro', 'npm', 'scripts/format.sh'],
        ['custom.regex', 'markdownlint-cli2', 'npm', 'scripts/markdownlint.sh'],
        ['custom.regex', 'markdownlint-cli2', 'npm', '.devcontainer/Dockerfile'],
        ['npm', 'markdownlint-cli2', 'npm', 'package.json', 'devDependencies'],
        ['pep621', 'black', 'pypi', 'pyproject.toml', 'dependency-groups'],
        ['pep621', 'blackened', 'pypi', 'pyproject.toml', 'dependency-groups'],
        ['custom.regex', 'black', 'pypi', 'scripts/format.sh'],
        ['gomod', 'example/module', 'go', '.devcontainer/go.mod', 'require'],
        ['terraform', 'hashicorp/aws', 'terraform-provider', 'terraform/main.tf', 'required_provider'],
        ['custom.regex', 'evanharmon1/harmon-devkit', 'github-tags', '.skills-sync.yaml'],
        ['renovate-config', 'example/another-preset', 'github-tags', 'renovate.json'],
        ['custom.regex', repo, 'github-tags', 'scripts/tool.sh'],
    ];
    const pin = (name, body, datasource = 'github-releases') =>
        `# renovate: datasource=${datasource} depName=${name}\n${body}\n`;
    const regexFiles = [
        ['.github/workflows/build.yml', pin('go-task/task', 'version: "3.44.1"')],
        ['.github/actions/setup/action.yml', pin('go-task/task', "version: '3.44.1'")],
        ['.github/workflows/check.yml', pin('go-task/task', 'TASK_VERSION=3.44.1')],
        ['.github/workflows/check.yml', `# renovate: datasource=github-release-attachments depName=mvdan/sh digestVersion=v3.12.0\nlinux_amd64_sha256=${'a'.repeat(64)}\n`],
        ['scripts/tool.sh', pin('go-task/task', 'TASK_VERSION=3.44.1')],
        ['scripts/tool.txt', pin('go-task/task', 'TASK_VERSION=3.44.1')],
        ['taskfiles/qa.yml', pin('go-task/task', 'TASK_VERSION: "3.44.1"')],
        ['Taskfile.yml', pin('go-task/task', 'TASK_VERSION: "3.44.1"')],
        ['.skills-sync.yaml', pin('evanharmon1/harmon-devkit', 'ref: v0.47.0', 'github-tags')],
        ['.devcontainer/Dockerfile', pin('node', 'ARG NODE_VERSION=24.0.0', 'node-version')],
        ['ansible/defaults/main.yml', pin('go-task/task', 'task_version: "3.44.1"')],
        ['ansible/defaults/main.yml.j2', pin('ubuntu', 'ubuntu_image: "ubuntu:24.04"', 'docker')],
    ];

    const singleManagerPaths = {
        'web-skills-only': '.skills-sync.yaml',
        'web-devcontainer-only': '.devcontainer/Dockerfile',
    };
    for (const profile of ['web', 'webapp', 'full', 'meta', ...Object.keys(singleManagerPaths)]) {
        const optedPath = `${profile}-opted/renovate.json`;
        if (!existsSync(resolve(fixture, optedPath))) continue;
        const inlineRaw = readConfig(`${profile}-inline/renovate.json`);
        const optedRaw = readConfig(optedPath);
        assert.deepEqual(optedRaw.extends, [reference], profile);
        assert.equal(migrateConfig(optedRaw).isMigrated, false, `${profile}: opt-in requires a config migration`);
        assert.deepEqual(await validateConfig('repo', normalized(optedRaw)), { errors: [], warnings: [] }, profile);

        const { packageRules: inlineRules, customManagers: inlineManagers, ...inlineCommon } = await resolved(inlineRaw);
        const { packageRules: optedRules, customManagers: optedManagers, ...optedCommon } = await resolved(optedRaw);
        assert.deepEqual(optedCommon, inlineCommon, `${profile}: common policy`);
        const localManagers = inlineRaw.customManagers.filter((manager) => !existsIn(manager, tagged.customManagers));
        assert.deepEqual(optedRaw.customManagers, localManagers, `${profile}: local manager order`);
        if (singleManagerPaths[profile]) {
            assert.equal(optedRaw.customManagers.length, 1, `${profile}: expected one local manager`);
            assert.ok(matchRegexOrGlobList(singleManagerPaths[profile], optedRaw.customManagers[0].managerFilePatterns),
                `${profile}: expected local manager owns the fixture path`);
        }
        assert.deepEqual(optedManagers, [...inherited.customManagers, ...normalized({ customManagers: localManagers }).customManagers],
            `${profile}: inherited manager order`);
        assert.equal(optedManagers.length, inlineManagers.length, `${profile}: manager count`);
        for (const manager of inlineManagers) {
            assert.equal(optedManagers.filter((value) => isDeepStrictEqual(value, manager)).length, 1,
                `${profile}: absent or duplicated manager ${manager.description}`);
        }

        const formatter = inlineRaw.packageRules.find((rule) => rule.groupName === 'Formatters');
        assert.deepEqual(sharedFormatter.prBodyNotes, formatter.prBodyNotes, `${profile}: shared formatter notes`);
        for (const rule of tagged.packageRules.filter((rule) => rule !== sharedFormatter)) {
            assert.equal(inlineRaw.packageRules.filter((value) => isDeepStrictEqual(value, rule)).length, 1,
                `${profile}: shared rule differs from inline: ${rule.description}`);
        }
        const localRules = inlineRaw.packageRules.filter((rule) =>
            rule !== formatter && !existsIn(rule, tagged.packageRules));
        const [pinRule, ...exceptions] = optedRaw.packageRules;
        const [markdownlint, otherFormatters, ...replayed] = exceptions.slice(localRules.length);
        assert.deepEqual(policyFields(pinRule), pinPolicy, `${profile}: reviewed pin updates`);
        assert.deepEqual(exceptions.slice(0, localRules.length), localRules, `${profile}: local rule order`);
        assert.deepEqual(policyFields(markdownlint), {
            matchPackageNames: sharedFormatter.matchPackageNames, groupName: formatter.groupName,
        }, `${profile}: local markdownlint precedence`);
        assert.deepEqual(policyFields(otherFormatters), {
            ...policyFields(formatter),
            matchPackageNames: formatter.matchPackageNames.filter((name) => name !== 'markdownlint-cli2'),
        }, `${profile}: local formatter names and notes`);
        assert.deepEqual(replayed, precedenceRules, `${profile}: lockfile precedence`);
        assert.deepEqual(optedRules.slice(0, inherited.packageRules.length), inherited.packageRules,
            `${profile}: inherited package rule order`);
        assert.deepEqual(optedRules.slice(inherited.packageRules.length), normalized(optedRaw).packageRules,
            `${profile}: resolved local package rule order`);

        for (const [manager, name, datasource, packageFile, depType] of dependencies) {
            for (const updateType of [undefined, 'major', 'minor', 'patch', 'pin', 'digest', 'lockFileMaintenance']) {
                const dep = { manager, depName: name, packageName: name, datasource, packageFile, depType, updateType };
                const [before, after] = await Promise.all([inlineRules, optedRules].map((rules) => effectivePolicy(dep, rules)));
                assert.deepEqual(after, before, `${profile}: ${manager} ${name} in ${packageFile} (${updateType})`);
            }
        }
        for (const [file, contents] of regexFiles) {
            const extract = (managers) => managers
                .filter((manager) => manager.customType === 'regex' && matchRegexOrGlobList(file, manager.managerFilePatterns))
                .flatMap((manager) => extractPackageFile(contents, file, manager)?.deps ?? []);
            assert.deepEqual(extract(optedManagers), extract(inlineManagers), `${profile}: extraction from ${file}`);
        }
        const { deps } = extractConfig(JSON.stringify(optedRaw), 'renovate.json');
        assert.deepEqual(deps, [{ depName: repo, datasource: 'github-tags', currentValue: tag }]);
        const ownPin = { ...deps[0], packageName: deps[0].depName, manager: 'renovate-config' };
        const githubPin = await effectivePolicy(ownPin, optedRules);
        assert.equal(githubPin.enabled, false, `${profile}: automatic GitHub preset bumps must stay disabled`);
        const gitlabPin = { ...ownPin, datasource: 'gitlab-tags' };
        assert.deepEqual(
            await effectivePolicy(gitlabPin, optedRules),
            await effectivePolicy(gitlabPin, inlineRules),
            `${profile}: the same repository path on GitLab must retain its inline policy`,
        );
        console.log(`Pinned Renovate: resolved policy and extraction match for ${profile}`);
    }
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
