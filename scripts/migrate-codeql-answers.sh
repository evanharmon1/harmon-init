#!/usr/bin/env bash
# Seed explicit CodeQL Copier answers from a legacy repository's actual
# workflow before an update. Copier reloads the answers file after this
# before-stage migration and then renders with these preserved choices.
set -euo pipefail

answers_file="${1:-.copier-answers.yml}"
if [ ! -f "$answers_file" ]; then
    echo "CodeQL answers migration: ${answers_file} is missing" >&2
    exit 1
fi

has_use_codeql=false
has_languages=false
grep -q '^use_codeql:' "$answers_file" && has_use_codeql=true
grep -q '^codeql_languages:' "$answers_file" && has_languages=true
if [ "$has_use_codeql" = true ] && [ "$has_languages" = true ]; then
    exit 0
fi

codeql_workflow=""
for candidate in .github/workflows/codeql.yml .github/workflows/codeql.yaml; do
    if [ -f "$candidate" ]; then
        codeql_workflow="$candidate"
        break
    fi
done

use_codeql=false
javascript=false
python=false
if [ -n "$codeql_workflow" ]; then
    use_codeql=true
    grep -qF 'javascript-typescript' "$codeql_workflow" && javascript=true
    grep -Eq '(^|[^[:alnum:]_-])python([^[:alnum:]_-]|$)' "$codeql_workflow" && python=true
fi

# A custom/dynamic legacy matrix may not contain literal language names. Fall
# back to the old profile-derived matrix so enabling CodeQL never records an
# empty selection that the new validator would reject.
if [ "$use_codeql" = true ] && [ "$javascript" = false ] && [ "$python" = false ]; then
    project_type="$(sed -n -E 's/^project_type:[[:space:]]*(.*)$/\1/p' "$answers_file" | tail -n 1 | tr -d "\"'")"
    include_ansible="$(sed -n -E 's/^include_ansible:[[:space:]]*(.*)$/\1/p' "$answers_file" | tail -n 1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]')"
    case "$project_type" in
    web-astro | web-app) javascript=true ;;
    esac
    if [ "$project_type" = iac ] || [ "$include_ansible" = true ] || [ "$include_ansible" = yes ]; then
        python=true
    fi
fi

if [ "$has_use_codeql" = false ]; then
    printf '\nuse_codeql: %s\n' "$use_codeql" >>"$answers_file"
fi
if [ "$has_languages" = false ]; then
    if [ "$javascript" = false ] && [ "$python" = false ]; then
        printf 'codeql_languages: []\n' >>"$answers_file"
    else
        printf 'codeql_languages:\n' >>"$answers_file"
        [ "$javascript" = true ] && printf '%s\n' '- javascript-typescript' >>"$answers_file"
        [ "$python" = true ] && printf '%s\n' '- python' >>"$answers_file"
    fi
fi

echo "CodeQL answers migration: use_codeql=${use_codeql}, javascript-typescript=${javascript}, python=${python}"
