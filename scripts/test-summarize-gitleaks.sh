#!/usr/bin/env bash
set -euo pipefail

script="./scripts/summarize-gitleaks.mjs"
if [ ! -f "$script" ]; then
  echo "TEST FAIL: could not find $script"
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "TEST FAIL: $*" >&2
  exit 1
}

# --- Empty args ---
echo "==> empty args"
set +e
out="$("$script" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "expected exit code 2 for missing args, got $rc"
fi
if ! echo "$out" | grep -q 'usage: summarize-gitleaks.mjs'; then
  fail "expected usage message, got $out"
fi

# --- Missing JSON report ---
echo "==> missing JSON report"
out="$("$script" "$tmpdir/missing.json")"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "expected exit code 0 for missing report, got $rc"
fi
if ! echo "$out" | grep -q 'Secrets: PASS — 0 finding(s)'; then
  fail "expected PASS output, got $out"
fi

# --- Empty JSON report ---
echo "==> empty JSON report"
echo "[]" > "$tmpdir/empty.json"
out="$("$script" "$tmpdir/empty.json")"
if ! echo "$out" | grep -q 'Secrets: PASS — 0 finding(s)'; then
  fail "expected PASS output, got $out"
fi

# --- Invalid JSON report ---
echo "==> invalid JSON report"
echo "{" > "$tmpdir/invalid.json"
out="$("$script" "$tmpdir/invalid.json" 2>&1)"
if ! echo "$out" | grep -q 'failed to parse'; then
  fail "expected parse error message, got $out"
fi

# --- Valid JSON array with findings ---
echo "==> valid JSON array with findings"
cat <<'JSON' > "$tmpdir/findings.json"
[
  {
    "RuleID": "test-rule",
    "File": "test-file.txt",
    "StartLine": 42,
    "Commit": "a1b2c3d4e5"
  }
]
JSON
out="$("$script" "$tmpdir/findings.json")"
if ! echo "$out" | grep -q 'Secrets: FAIL — 1 finding(s)'; then
  fail "expected FAIL output, got $out"
fi

# --- Markdown summary ---
echo "==> markdown summary generation"
summary_file="$tmpdir/summary.md"
export GITHUB_STEP_SUMMARY="$summary_file"
"$script" "$tmpdir/findings.json" > /dev/null
if [ ! -f "$summary_file" ]; then
  fail "summary file was not created"
fi
summary_out="$(cat "$summary_file")"
if ! echo "$summary_out" | grep -q '### Secrets Scan (gitleaks)'; then
  fail "expected header in summary, got $summary_out"
fi
if ! echo "$summary_out" | grep -q '\*\*FAIL\*\* — 1 finding(s)'; then
  fail "expected FAIL result in summary, got $summary_out"
fi
if ! echo "$summary_out" | grep -Fq "\`test-rule\` | \`test-file.txt\` | 42 | \`a1b2c3d\`"; then
  fail "expected finding details in summary, got $summary_out"
fi

# --- Markdown summary with > 20 findings ---
echo "==> markdown summary truncation"
summary_file2="$tmpdir/summary2.md"
export GITHUB_STEP_SUMMARY="$summary_file2"
# Generate 25 findings
node -e "const fs = require('fs'); const findings = Array.from({length: 25}).map((_, i) => ({RuleID: 'rule'+i, File: 'file'+i, StartLine: i, Commit: 'c'+i})); fs.writeFileSync('$tmpdir/many.json', JSON.stringify(findings));"
"$script" "$tmpdir/many.json" > /dev/null
summary2_out="$(cat "$summary_file2")"
if ! echo "$summary2_out" | grep -q '_(showing first 20 of 25)_'; then
  fail "expected truncation message, got $summary2_out"
fi

echo "test-summarize-gitleaks: all cases passed"
