#!/usr/bin/env python3
"""Execute the portable .devflow.toml conformance corpus.

The JSON corpus intentionally contains only data: basis selection, labels,
operator overrides, and partial normalized-result expectations. Consumers in
other languages can run the same vectors without importing this Python
reference resolver. This harness proves the shipped resolver honors them.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


SUPPORTED_SCHEMA_VERSION = 1
CASE_KEYS = {
    "adaptive_result",
    "basis",
    "config_replacements",
    "expect",
    "labels",
    "merge_base_replacements",
    "name",
    "overrides",
    "trusted_labels",
    "unattended",
}
EXPECT_KEYS = {"error_diagnostics", "exit", "result", "warning_diagnostics"}
V2_CASE_KEYS = {
    "basis",
    "config_replacements",
    "expect",
    "merge_base_replacements",
    "name",
    "overrides",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)


def matches(actual, expected, path="result") -> list[str]:
    """Partial, recursive match: fixtures specify contract-relevant fields.

    A partial expected result lets v1 reserve room for additive diagnostics
    while still pinning every semantic value consumers must agree on.
    """
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {actual!r}"]
        failures = []
        for key, value in expected.items():
            if key not in actual:
                failures.append(f"{path}.{key}: missing")
            else:
                failures.extend(matches(actual[key], value, f"{path}.{key}"))
        return failures
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [f"{path}: expected array, got {actual!r}"]
        if len(actual) != len(expected):
            return [f"{path}: expected {len(expected)} item(s), got {len(actual)}"]
        return [
            failure
            for index, value in enumerate(expected)
            for failure in matches(actual[index], value, f"{path}[{index}]")
        ]
    if type(actual) is not type(expected) or actual != expected:
        return [f"{path}: expected {expected!r}, got {actual!r}"]
    return []


def replace(text: str, replacements, case: str, label: str) -> str:
    for pair in replacements:
        if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(v, str) for v in pair):
            raise ValueError(f"{case}: {label} must contain [old, new] string pairs")
        old, new = pair
        if old not in text:
            raise ValueError(f"{case}: {label} anchor {old!r} was not found")
        text = text.replace(old, new, 1)
    return text


def diagnostics_match(actual, expected, case: str, kind: str) -> list[str]:
    """Require stable diagnostic code/subject pairs without pinning prose."""
    if not isinstance(expected, list):
        return [f"{case}: {kind}_diagnostics must be an array"]
    failures = []
    if not isinstance(actual, list):
        return [f"{case}: output {kind}s must be an array"]
    actual_pairs = set()
    for item in actual:
        if not isinstance(item, dict) or not all(isinstance(item.get(key), str) for key in ("code", "subject")):
            failures.append(f"{case}: output {kind} must contain string code/subject fields")
        else:
            actual_pairs.add((item["code"], item["subject"]))
    expected_pairs = set()
    for item in expected:
        if not isinstance(item, dict) or set(item) != {"code", "subject"} or not all(
            isinstance(item.get(key), str) for key in ("code", "subject")
        ):
            failures.append(f"{case}: every {kind}_diagnostics item must be a code/subject object")
        else:
            expected_pairs.add((item["code"], item["subject"]))
    if actual_pairs != expected_pairs:
        missing = sorted(expected_pairs - actual_pairs)
        unexpected = sorted(actual_pairs - expected_pairs)
        if missing:
            failures.append(f"{case}: missing {kind} diagnostic pairs {missing!r}")
        if unexpected:
            failures.append(f"{case}: unexpected {kind} diagnostic pairs {unexpected!r}")
    return failures


def run_v2(repo: Path, fixture: dict, config: Path) -> int:
    """Run the v2 corpus against the shared JavaScript policy reader."""
    source = config.read_text()
    failures: list[str] = []
    for case in fixture.get("cases", []):
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            failures.append("every fixture case needs a non-empty name")
            continue
        unsupported = sorted(set(case) - V2_CASE_KEYS)
        if unsupported:
            failures.append(
                f"{name}: v2 reader does not support case input(s): {', '.join(unsupported)}"
            )
            continue
        basis = case.get("basis")
        if basis not in {"absent", "branch", "merge-base"}:
            failures.append(f"{name}: basis must be absent, branch, or merge-base")
            continue
        overrides = case.get("overrides", [])
        if not isinstance(overrides, list) or not all(isinstance(value, str) for value in overrides):
            failures.append(f"{name}: overrides must be an array of strings")
            continue
        selections: dict[str, str] = {}
        try:
            for override in overrides:
                axis, value = override.split("=", 1)
                if axis not in {"rigor", "strategy"} or not value:
                    raise ValueError(
                        f"{name}: v2 overrides support only non-empty rigor=<value> or strategy=<value>"
                    )
                if axis in selections:
                    raise ValueError(f"{name}: duplicate {axis} override")
                selections[axis] = value
        except ValueError as exc:
            failures.append(str(exc))
            continue
        expected = case.get("expect")
        if not isinstance(expected, dict):
            failures.append(f"{name}: expect must be an object")
            continue
        unknown_expect_keys = sorted(set(expected) - EXPECT_KEYS)
        if unknown_expect_keys:
            failures.append(f"{name}: unknown expect key(s): {', '.join(unknown_expect_keys)}")
            continue
        expected_exit = expected.get("exit")
        if (
            not isinstance(expected_exit, int)
            or isinstance(expected_exit, bool)
            or expected_exit not in (0, 1)
        ):
            failures.append(f"{name}: expect.exit must be the integer 0 or 1")
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                policy = tmp_path / "policy.toml"
                branch_text = (
                    replace(source, case.get("config_replacements", []), name, "config_replacements")
                )
                if basis != "absent":
                    policy.write_text(branch_text)
                command = [
                    "node",
                    str(repo / "scripts" / "devflow-policy.mjs"),
                    "resolve",
                    "--policy",
                    str(policy),
                    "--registry",
                    str(repo / "agent-registry.json"),
                    "--taskfile-dir",
                    str(repo),
                    "--json",
                ]
                if basis == "merge-base":
                    merge_base = tmp_path / "merge-base.toml"
                    merge_base.write_text(
                        replace(
                            source,
                            case.get("merge_base_replacements", []),
                            name,
                            "merge_base_replacements",
                        )
                    )
                    command.extend(
                        [
                            "--merge-base-policy",
                            str(merge_base),
                            "--merge-base-registry",
                            str(repo / "agent-registry.json"),
                        ]
                    )
                for axis, value in selections.items():
                    command.extend([f"--{axis}", value])
                result = subprocess.run(command, capture_output=True, text=True)
        except (OSError, ValueError) as exc:
            failures.append(f"{name}: harness failure: {exc}")
            continue

        errors: list[dict[str, str]] = []
        normalized: dict = {"config_schema_version": 2}
        if result.returncode == 0:
            try:
                resolved = json.loads(result.stdout)
            except json.JSONDecodeError as exc:
                failures.append(f"{name}: invalid reader JSON: {exc}")
                continue
            normalized["config_source"] = resolved["source"]
            normalized["selections"] = {
                "rigor": {
                    "value": resolved["rigor"]["level"],
                    "source": "explicit" if "rigor" in selections else (
                        "builtin" if basis == "absent" else "default"
                    ),
                },
                "strategy": {
                    "value": resolved["strategy"]["name"],
                    "source": "explicit" if "strategy" in selections else (
                        "builtin" if basis == "absent" else "default"
                    ),
                },
            }
        elif "schema_version" in result.stderr and (
            "legacy" in result.stderr
            or "v1" in result.stderr
            or "migrate to schema_version" in result.stderr
        ):
            errors.append({"code": "migration_required", "subject": "schema_version"})
        else:
            failures.append(f"{name}: unclassified reader failure: {result.stderr.strip()}")

        if result.returncode != expected.get("exit"):
            failures.append(f"{name}: expected exit {expected.get('exit')!r}, got {result.returncode}")
        failures.extend(f"{name}: {item}" for item in matches(normalized, expected.get("result", {})))
        failures.extend(
            diagnostics_match(errors, expected.get("error_diagnostics", []), name, "error")
        )

    if failures:
        for item in failures:
            fail(item)
        return 1
    print(f"devflow conformance v2 OK: {len(fixture['cases'])} cases")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    fixture_path = args.fixture or repo / ".devflow-conformance-v2.json"
    resolver = repo / "scripts" / "devflow-resolve.py"
    config = args.config or repo / ".devflow.toml"
    if not config.is_absolute():
        config = repo / config

    try:
        fixture = json.loads(fixture_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read fixture {fixture_path}: {exc}")
        return 1
    if not isinstance(fixture, dict):
        fail("fixture root must be an object")
        return 1
    if fixture.get("kind") != "harmon-init.devflow.conformance":
        fail("fixture kind must be 'harmon-init.devflow.conformance'")
        return 1
    schema_version = fixture.get("schema_version")
    if schema_version == 2:
        if fixture.get("result_schema_version") != 2:
            fail("fixture result_schema_version must be 2")
            return 1
        if not isinstance(fixture.get("cases"), list) or not fixture["cases"]:
            fail("fixture cases must be a non-empty array")
            return 1
        return run_v2(repo, fixture, config)
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != SUPPORTED_SCHEMA_VERSION
    ):
        fail(f"fixture schema_version must be {SUPPORTED_SCHEMA_VERSION}")
        return 1
    result_schema_version = fixture.get("result_schema_version")
    if (
        not isinstance(result_schema_version, int)
        or isinstance(result_schema_version, bool)
        or result_schema_version != SUPPORTED_SCHEMA_VERSION
    ):
        fail(f"fixture result_schema_version must be {SUPPORTED_SCHEMA_VERSION}")
        return 1
    if not isinstance(fixture.get("cases"), list) or not fixture["cases"]:
        fail("fixture cases must be a non-empty array")
        return 1

    names = []
    for case in fixture["cases"]:
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            fail("every fixture case needs a non-empty name")
            return 1
        names.append(name)
        unknown_case_keys = sorted(set(case) - CASE_KEYS)
        if unknown_case_keys:
            fail(f"{name}: unknown case key(s): {', '.join(unknown_case_keys)}")
            return 1
        if not isinstance(case.get("expect"), dict):
            fail(f"{name}: expect must be an object")
            return 1
        unknown_expect_keys = sorted(set(case["expect"]) - EXPECT_KEYS)
        if unknown_expect_keys:
            fail(f"{name}: unknown expect key(s): {', '.join(unknown_expect_keys)}")
            return 1
        expected_exit = case["expect"].get("exit")
        if not isinstance(expected_exit, int) or isinstance(expected_exit, bool) or expected_exit not in (0, 1):
            fail(f"{name}: expect.exit must be the integer 0 or 1")
            return 1
        for field in ("labels", "trusted_labels", "overrides"):
            values = case.get(field, [])
            if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                fail(f"{name}: {field} must be an array of strings")
                return 1
        if "unattended" in case and not isinstance(case["unattended"], bool):
            fail(f"{name}: unattended must be a boolean")
            return 1
    if len(names) != len(set(names)):
        fail("fixture case names must be unique")
        return 1

    source = config.read_text()
    failures = []
    for case in fixture["cases"]:
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            failures.append("every fixture case needs a non-empty name")
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                branch_text = replace(source, case.get("config_replacements", []), name, "config_replacements")
                branch_config = tmp_path / "branch.toml"
                branch_config.write_text(branch_text)
                command = [sys.executable, str(resolver), "--config", str(branch_config)]
                basis = case.get("basis")
                if basis == "branch":
                    command.append("--config-unchanged")
                elif basis == "absent":
                    command.extend(["--config", str(tmp_path / "absent.toml"), "--config-unchanged"])
                elif basis == "merge-base":
                    merge_base_text = replace(source, case.get("merge_base_replacements", []), name,
                                              "merge_base_replacements")
                    merge_base_config = tmp_path / "merge-base.toml"
                    merge_base_config.write_text(merge_base_text)
                    command.extend(["--merge-base-config", str(merge_base_config)])
                else:
                    raise ValueError(f"{name}: basis must be branch, absent, or merge-base")
                for label in case.get("labels", []):
                    command.extend(["--label", label])
                for label in case.get("trusted_labels", []):
                    command.extend(["--trusted-label", label])
                for override in case.get("overrides", []):
                    command.extend(["--override", override])
                if case.get("unattended") is True:
                    command.append("--unattended")
                if "adaptive_result" in case:
                    adaptive_result = case["adaptive_result"]
                    if not isinstance(adaptive_result, str):
                        raise ValueError(f"{name}: adaptive_result must be a string")
                    command.extend(["--adaptive-result", adaptive_result])
                result = subprocess.run(command, capture_output=True, text=True)
                output = json.loads(result.stdout)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures.append(f"{name}: harness failure: {exc}")
            continue

        expected = case.get("expect")
        if not isinstance(expected, dict):
            failures.append(f"{name}: expect must be an object")
            continue
        if result.returncode != expected.get("exit"):
            failures.append(f"{name}: expected exit {expected.get('exit')!r}, got {result.returncode}")
        failures.extend(f"{name}: {item}" for item in matches(output, expected.get("result", {})))
        failures.extend(
            diagnostics_match(output.get("warnings", []), expected.get("warning_diagnostics", []), name, "warning")
        )
        failures.extend(
            diagnostics_match(output.get("errors", []), expected.get("error_diagnostics", []), name, "error")
        )
        if output.get("result_schema_version") != SUPPORTED_SCHEMA_VERSION:
            failures.append(f"{name}: output missing result_schema_version {SUPPORTED_SCHEMA_VERSION}")

    if failures:
        for item in failures:
            fail(item)
        return 1
    print(f"devflow conformance v{SUPPORTED_SCHEMA_VERSION} OK: {len(fixture['cases'])} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
