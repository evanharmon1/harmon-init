#!/usr/bin/env python3
"""devflow-resolve.py — minimal reference resolver for .devflow.toml.

Resolves a rigor + strategy execution policy the way AGENTS.md's Dev Loop
describes and ADR 0007 (docs/decisions/0007-rigor-and-strategy-axes.md)
records: explicit operator instruction > rigor:*/strategy:* labels >
default_rigor/default_strategy > the built-in fallback. The built-in
fallback is a FLOOR, not a bypass: even when .devflow.toml is entirely
absent, every input below is still parsed and applied over it — an
--override or --trusted-label naming a rigor/strategy the built-in cannot
honor (there are no [rigor.*]/[strategy.*] tables to resolve anything else
against) is a deterministic error, never silently discarded.

Trust is a CONSUMER input, not something this resolver infers: --label is
UNVERIFIED by default, and --trusted-label marks the subset whose provenance
the caller has already verified against its own trusted-actor configuration
(ADR 0006 D6). Unattended automation may act only on trusted labels (D6.1) —
every other --label is ignored, with a warning naming it, and falls back to
the default. An interactive session may still act on any --label (advisory,
as before trust existed as a concept here), but an off-default result driven
by an untrusted one sets requires_confirmation, so the operator is asked
before it is used rather than applied silently (D6.2). An --override is
always trusted by definition — it is the explicit, attributable instruction
channel ADR 0006 D5 describes, never repository content.

Only labels in the rigor:/strategy:/tier: namespaces are this resolver's
business — anything else (including retired `method:*`, a plain `bug`, or an
`area:ci`) is filtered out
before either the trust filter or the label parser ever see it, silently:
it was never a devflow input, so it produces no warning of any kind.

Malformed input never produces a raw traceback. A config file that EXISTS but
cannot be read, decoded as UTF-8, or parsed as TOML at all reports
invalid_config, the same as one that parses fine but whose cross-references
dangle (an unknown default_rigor, a rigor level naming a missing
review/budget, a rigor_order entry with no matching table, rigor_order itself
missing an entry or holding a duplicate, and so on) — validated BEFORE
anything is dereferenced. The same net catches a value TOML can represent but
JSON cannot serialize CLEANLY: a bare date/datetime/time literal
(`human_gates = 2026-08-25` parses as a real datetime.date, not a string)
anywhere inside a [review.*], [budget.*], or [strategy.*] table is
invalid_config too, checked before that table can ever reach json.dumps()
and raise — and so is a non-finite float (`max_usd = nan` or `= inf`),
which json.dumps() does NOT raise on (Python emits the bareword tokens
NaN/Infinity by default) but which is not valid JSON per RFC 8259 either;
math.isfinite() catches what a raw isinstance(x, float) check would miss.
An existing --config/--merge-base-config path that is not a regular file
(a directory, a socket) is invalid_input rather than either of those —
distinct again from genuine absence, since it is almost certainly a
caller/path mistake, not a signal that no config exists. This is a
crash-safety net, not a restatement of scripts/test-devflow-config.sh's
exhaustive static validation (enums, cross-registry checks, description
equality) — that script is the authority on whether a config is
well-formed; this resolver only needs enough checking to fail cleanly on
one that isn't (or on an invocation that doesn't even resolve to one, per
argparse's own overridden error() below).

Reading the branch's own --config copy is NEVER a silent default: exactly
one of three config-basis flags is required on every invocation, because a
branch that edits .devflow.toml could otherwise have its own PR read its own
(possibly weakened) copy instead of the merge-base's, simply because a
caller forgot a flag. --merge-base-config PATH says the branch edits the
file and here is the merge-base's extracted copy to read instead — the path
MUST exist; naming one that does not is a hard invalid_input error (far more
likely a caller/extraction bug — a failed `git show <sha>:.devflow.toml`, a
wrong path — than genuine absence). --merge-base-absent says the branch
edits the file but the merge-base commit genuinely predates it (this PR
might be the one introducing .devflow.toml) — resolves from the built-in
fallback, with every --label/--override/--trusted-label still applied over
it exactly as an absent --config would be. --config-unchanged says the
branch does NOT touch .devflow.toml at all, so the merge-base rule does not
apply and reading --config directly is correct. Zero or more than one of
these three is an invalid_input error.

`adaptive` is a VALID provisioned tier value in exactly one shape: the
UNQUALIFIED `tier:adaptive` LABEL (which, like any unqualified tier label,
targets the implementer role). label-registry.json's `tier` family provisions
`adaptive` as one of its 6 values; its separate `tier-role` family provisions
only the 15 CONCRETE role-scoped combinations (3 roles x 5 ladder tiers) and
was never seeded with a role-scoped adaptive variant — a role can't be pinned
to "let a preflight classifier decide". So `tier:<role>:adaptive` is not a
provisioned label shape at all: treated as unknown (ignored with a warning),
exactly like any other value that names no concrete ladder tier. `--override
tier=adaptive` and `--override tier.<role>=adaptive` are rejected outright
(invalid_input) for a different reason — an override is the explicit,
attributable instruction channel (ADR 0006 D5), and "defer this to a
preflight classifier" is not a concrete instruction, so an operator wanting
that must use the `tier:adaptive` LABEL rather than an override.

For the one reachable shape (an unqualified `tier:adaptive` label targeting
implementer): --adaptive-result <ladder tier> represents the caller's own
preflight classifier having already decided a concrete answer; when given, it
wins outright for the role that resolved to `adaptive`. Absent it, an
adaptive-resolved role reports preflight_required=true (also aggregated at
the top level) and provisionally uses the rigor profile's own tier for that
role — never a claim that preflight has already run. A concrete tier label on
the same role still beats `adaptive` (ADR 0006 D5) before any of this
applies, exactly as a stronger concrete label beats a weaker one.
requires_confirmation stays honest throughout: it is computed from what was
actually requested (`adaptive`) for trust purposes, not from whatever
--adaptive-result later resolved it to, so an untrusted label asking for
adaptive is exactly as confirmation-worthy as one asking for any other
off-profile tier once it resolves to something concrete.

This is a ROOT-ONLY reference implementation, not the versioned,
cross-consumer conformance contract — that is harmon-init#1048
(schema_version, language-neutral fixtures, a fixture corpus). It exists so
scripts/test-devflow-config.sh has something executable to run the
resolution-order case table against, and so an agent or Foreman has a
starting point rather than re-deriving the algorithm from prose each time.

Usage:
    devflow-resolve.py --config .devflow.toml \\
        (--merge-base-config PATH | --merge-base-absent | --config-unchanged) \\
        [--label rigor:deep] [--label strategy:council] \\
        [--label tier:economy] [--label tier:implementer:economy] \\
        [--label tier:adaptive] [--adaptive-result economy] \\
        [--trusted-label rigor:deep] \\
        [--override rigor=deep] [--override tier.implementer=economy] \\
        [--unattended]

Prints one normalized JSON object to stdout and exits 0 if resolution
completed with no errors (warnings are fine), 1 otherwise. Errors and
warnings are always both present in the output (possibly empty lists) so a
caller never needs to guess whether the key exists.

Inputs, precisely:
  --config PATH             the branch's copy of .devflow.toml. Always
                             required and always recorded, but only actually
                             READ when --config-unchanged selects it as the
                             basis (see the three flags below).
  EXACTLY ONE of the following three is required — see the module docstring
  above for why there is no silent default:
  --merge-base-config PATH  the branch edits .devflow.toml; THIS is the
                             merge-base's extracted copy to read instead —
                             the merge-base rule (AGENTS.md, "When the
                             change under review edits .devflow.toml...").
                             The path MUST exist — naming one that does not
                             is an invalid_input error, not a fallback to
                             the built-in.
  --merge-base-absent        the branch edits .devflow.toml, but the
                             merge-base commit genuinely has no such file
                             (this PR may be the one introducing it) —
                             resolves from the built-in fallback, exactly
                             like an absent --config would.
  --config-unchanged         the branch does NOT modify .devflow.toml —
                             the merge-base rule does not apply, so --config
                             itself is read directly.
  --label FAMILY:VALUE      a rigor:*/strategy:*/tier:* label present on the
                             issue or PR, repeatable — UNVERIFIED provenance.
                             Anything outside those three namespaces is
                             silently irrelevant, not a warning — it is
                             filtered out before trust or parsing ever runs.
                             tier:<value> is unqualified (implementer only);
                             tier:<role>:<value> is scoped (role one of
                             orchestrator/implementer/reviewer). Multiple
                             tier labels that land on the same role — any mix
                             of the unqualified and scoped forms — resolve
                             strongest-wins by ladder rank, regardless of
                             input order: a conflict can only ever raise the
                             tier, mirroring how a rigor conflict can only
                             ever buy more depth (ADR 0006 D5). `adaptive` is
                             only reachable via the unqualified tier:adaptive
                             form — tier:<role>:adaptive is not a provisioned
                             label shape and is treated as unknown (see the
                             module docstring above).
  --trusted-label F:V       the subset of labels (same FAMILY:VALUE forms as
                             --label, same namespace filter) whose provenance
                             the CALLER has already verified against its own
                             trusted-actor configuration (ADR 0006 D6) —
                             repeatable, and need not literally duplicate a
                             --label entry. Under --unattended, ONLY trusted
                             labels participate in resolution. In interactive
                             mode every --label still applies; --trusted-label
                             instead controls whether an off-default result
                             sets requires_confirmation. When the config is
                             absent, a trusted rigor:/strategy: label naming
                             anything the built-in fallback does not define
                             is a deterministic error, exactly like an
                             --override would be.
  --override KEY=VALUE      an explicit, attributable operator instruction,
                             repeatable — always trusted by definition
                             (ADR 0006 D5: an explicit instruction arrives on
                             the operator's attributable channel and is never
                             repository content). KEY is one of: rigor,
                             strategy, tier (unqualified, implementer only),
                             tier.orchestrator, tier.implementer,
                             tier.reviewer. A tier VALUE of `adaptive` is
                             rejected (invalid_input) for every one of these
                             keys — see the module docstring above.
  --adaptive-result TIER    the caller's own preflight classifier's already-
                             decided concrete answer (one of the ladder
                             tiers, never `adaptive` itself) — applies to
                             EVERY role that resolved to `adaptive`, not a
                             single role. Absent, an adaptive-resolved role
                             reports preflight_required instead of guessing.
  --unattended               two effects, both from ADR 0006 D6.1: an
                             ambiguous strategy conflict falls back to
                             default_strategy with a warning instead of
                             erroring, AND only --trusted-label values are
                             applied at all — every plain --label is ignored
                             (with a warning naming it) and falls back to the
                             default instead.
"""
import argparse
import hashlib
import json
import math
import os
import sys
import tomllib
from pathlib import Path

LADDER = ("local", "economy", "standard", "frontier", "apex")
LADDER_RANK = {tier: i for i, tier in enumerate(LADDER)}
SUPPORTED_SCHEMA_VERSION = 1
TOP_LEVEL_KEYS = {
    "schema_version", "default_rigor", "default_strategy", "rigor_order",
    "rigor", "review", "budget", "strategy", "tier",
}

_JSON_SAFE_SCALARS = (str, int, float, bool, type(None))


def _schema_type_matches(value, expected):
    """Implement the small, portable JSON Schema subset used by v1."""
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return True


def _schema_violations(value, schema, root, path="$"):
    """Return structural v1-schema violations as stable path/message pairs.

    v1 uses only the keywords implemented here. Reject an unsupported schema
    reference rather than silently validating less than the contract says.
    """
    if "$ref" in schema:
        ref = schema["$ref"]
        prefix = "#/$defs/"
        if not isinstance(ref, str) or not ref.startswith(prefix):
            return [(path, f"unsupported schema reference {ref!r}")]
        target = root.get("$defs", {}).get(ref[len(prefix):])
        if not isinstance(target, dict):
            return [(path, f"unresolved schema reference {ref!r}")]
        return _schema_violations(value, target, root, path)

    violations = []
    expected_type = schema.get("type")
    if isinstance(expected_type, str) and not _schema_type_matches(value, expected_type):
        return [(path, f"must be a {expected_type}")]
    if "const" in schema and value != schema["const"]:
        violations.append((path, f"must equal {schema['const']!r}"))
    if "enum" in schema and value not in schema["enum"]:
        violations.append((path, f"must be one of {schema['enum']!r}"))

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                violations.append((path, f"is missing required property {key!r}"))
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            item_schema = properties.get(key)
            if item_schema is None:
                if additional is False:
                    violations.append((f"{path}.{key}", "is not allowed"))
                elif isinstance(additional, dict):
                    violations.extend(_schema_violations(item, additional, root, f"{path}.{key}"))
            elif isinstance(item_schema, dict):
                violations.extend(_schema_violations(item, item_schema, root, f"{path}.{key}"))
    elif isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for index, item in enumerate(value):
                violations.extend(_schema_violations(item, items, root, f"{path}[{index}]"))
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in value]
            if len(encoded) != len(set(encoded)):
                violations.append((path, "must have unique items"))

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            violations.append((path, f"must have length >= {schema['minLength']}"))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            violations.append((path, f"must have length <= {schema['maxLength']}"))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            violations.append((path, f"must be >= {schema['minimum']}"))
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            violations.append((path, f"must be > {schema['exclusiveMinimum']}"))
    return violations


def validate_schema_v1_shape(cfg, errors, *, allow_legacy_merge_base=False):
    """Validate a present config against the checked-in v1 schema.

    The unversioned merge-base compatibility basis still has to satisfy every
    v1 requirement except its absent schema_version.
    """
    schema_path = Path(__file__).resolve().parents[1] / ".devflow.schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append({
            "code": "invalid_config",
            "detail": f"cannot load v1 structural schema {schema_path}: {exc}",
        })
        return False
    violations = _schema_violations(cfg, schema, schema)
    if allow_legacy_merge_base:
        violations = [
            violation for violation in violations
            if violation != ("$", "is missing required property 'schema_version'")
        ]
    for path, detail in violations:
        errors.append({"code": "invalid_config", "detail": f"schema v1 {path} {detail}"})
    return not violations


def json_safe(value):
    """True if `value` will serialize cleanly with json.dumps() to output
    that is actually valid JSON. TOML has native date/datetime/time
    literals with no JSON equivalent (tomllib parses `2026-08-25` as a real
    datetime.date, not a string) — those make json.dumps() raise outright.
    TOML also has nan/inf/-inf float literals; json.dumps() does NOT raise
    on those (Python's own extension emits the bareword tokens NaN/
    Infinity/-Infinity by default), but that output is not valid JSON per
    RFC 8259 — a strict downstream parser would reject it, so this counts
    them as unsafe too, checked with math.isfinite() rather than a raw
    isinstance. Checked structurally, recursively through any list/dict,
    since this is a crash/malformed-output safety net for WHATEVER shape a
    table takes, not a restatement of scripts/test-devflow-config.sh's
    exhaustive per-field validation."""
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, _JSON_SAFE_SCALARS):
        return True
    if isinstance(value, list):
        return all(json_safe(v) for v in value)
    if isinstance(value, dict):
        return all(isinstance(k, str) and json_safe(v) for k, v in value.items())
    return False
ROLES = ("orchestrator", "implementer", "reviewer")
DEVFLOW_LABEL_PREFIXES = ("rigor:", "strategy:", "tier:")

# Used only when .devflow.toml is entirely absent (AGENTS.md's built-in
# fallback sentence, kept in lockstep with it and with [review.standard] by
# scripts/test-devflow-config.sh — this script does not re-derive it from a
# config that, by definition, is not there to read).
BUILTIN_RIGOR = "standard"
BUILTIN_STRATEGY = "plan"
BUILTIN_REVIEW = {"challenge": 3, "review": 3, "shepherd": 4, "min_rounds": 1}
# min_rounds is a floor on ROUNDS THE AGENT ITSELF RUNS before the
# early-clean-round exit is available — it is scoped to challenge and
# review only. shepherd is externally driven (CI results, human review,
# Codex) and cannot manufacture a round on its own, so it is never part of
# what min_rounds bounds; scripts/test-devflow-config.sh's validator enforces
# `0 <= min_rounds <= min(challenge, review)` accordingly. Included in every
# `review` output object below so a caller does not have to already know
# this to interpret min_rounds correctly.
MIN_ROUNDS_SCOPE = ["challenge", "review"]
# A minimal synthetic config, structurally just real enough that
# resolve_rigor()/resolve_strategy() need no absent-config special case of
# their own: membership in `rigor`/`strategy` here IS the built-in's
# vocabulary (exactly BUILTIN_RIGOR/BUILTIN_STRATEGY, nothing else), so an
# --override or label naming anything else is rejected by the SAME
# "not in levels"/"not in strategies" checks that already guard a real
# config, for free. The inner tables are intentionally empty: no [tier.*]
# ladder, no [budget.*], no [review.*] beyond BUILTIN_REVIEW — "tiers inert"
# means there is nothing for a role tier to refine, so those are never
# dereferenced against this dict (main() branches on config_absent instead).
BUILTIN_CFG = {
    "default_rigor": BUILTIN_RIGOR,
    "default_strategy": BUILTIN_STRATEGY,
    "rigor_order": [BUILTIN_RIGOR],
    "rigor": {BUILTIN_RIGOR: {}},
    "strategy": {BUILTIN_STRATEGY: {}},
}


class ConfigReadError(Exception):
    """Raised by load_config() when the path EXISTS but cannot be read,
    decoded as UTF-8, or parsed as TOML. Kept distinct from the (None, None)
    "genuinely absent" return so a caller can tell "there is no file" apart
    from "there is a file and it is broken" — the latter is never silently
    treated as the built-in fallback."""


def load_config(path):
    """Returns (cfg, sha256_hex) or (None, None) if path does not exist.
    Raises ConfigReadError — never lets OSError/UnicodeDecodeError/
    tomllib.TOMLDecodeError escape as a raw traceback — if the path exists
    but cannot be read, decoded, or parsed."""
    if not os.path.isfile(path):
        return None, None
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        cfg = tomllib.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise ConfigReadError(f"{path}: {exc}") from exc
    return cfg, hashlib.sha256(raw).hexdigest()


def validate_config_references(cfg, errors, *, allow_legacy_merge_base=False):
    """Defensive validation this resolver needs to avoid a raw traceback on
    a malformed-but-syntactically-valid TOML config — see the module
    docstring on how this differs from scripts/test-devflow-config.sh.
    Every reference checked here is one this resolver is about to
    dereference somewhere below; catching a dangling one here turns a
    KeyError/TypeError into one clean invalid_config error instead. Returns
    True if every reference this resolver depends on actually resolves.
    """
    ok = True

    def fail(detail):
        nonlocal ok
        errors.append({"code": "invalid_config", "detail": detail})
        ok = False

    levels = cfg.get("rigor")
    if not isinstance(levels, dict) or not levels:
        fail("[rigor.*] must be a non-empty table of tables")
        return False  # nothing below is safe to inspect without at least this

    reviews = cfg.get("review")
    reviews = reviews if isinstance(reviews, dict) else {}
    budgets = cfg.get("budget")
    budgets = budgets if isinstance(budgets, dict) else {}
    strategies = cfg.get("strategy")
    strategies = strategies if isinstance(strategies, dict) else {}

    unknown = sorted(set(cfg) - TOP_LEVEL_KEYS)
    if unknown:
        fail(f"unknown top-level key(s): {', '.join(unknown)}")

    schema_version = cfg.get("schema_version")
    if schema_version is None and allow_legacy_merge_base:
        pass
    elif not isinstance(schema_version, int) or isinstance(schema_version, bool):
        fail(f"schema_version must be an integer (got {schema_version!r})")
    elif schema_version != SUPPORTED_SCHEMA_VERSION:
        fail(
            f"schema_version={schema_version!r} is unsupported — this resolver supports "
            f"schema version {SUPPORTED_SCHEMA_VERSION}; upgrade the consumer or use a compatible config"
        )

    # Every reference below is type-checked as a scalar string BEFORE any
    # dictionary-membership test (`x not in some_dict`) — dict membership
    # requires its LHS to be hashable, and TOML happily parses
    # `default_rigor = ["standard"]` as a perfectly valid (if wrong) list
    # value. An unhashable value there would otherwise raise a raw
    # TypeError instead of the invalid_config this function exists to
    # produce. `x not in LADDER` (a tuple) needs no such guard — tuple
    # membership never raises regardless of x's type — but is still
    # type-checked here for a clearer message and for consistency across
    # every reference this function validates.
    default_rigor = cfg.get("default_rigor")
    if not isinstance(default_rigor, str):
        fail(f"default_rigor must be a string (got {default_rigor!r})")
    elif default_rigor not in levels:
        fail(f"default_rigor={default_rigor!r} names no [rigor.*] level")

    default_strategy = cfg.get("default_strategy")
    if not isinstance(default_strategy, str):
        fail(f"default_strategy must be a string (got {default_strategy!r})")
    elif default_strategy not in strategies:
        fail(f"default_strategy={default_strategy!r} names no [strategy.*] value")

    # rigor_order must be a duplicate-free EXACT permutation of [rigor.*],
    # not merely a list of valid entries — resolve_rigor builds
    # {name: i for i, name in enumerate(rigor_order)} and falls back to -1
    # for anything missing, so a level left OUT of rigor_order would
    # silently rank as weakest-possible instead of failing loudly, and a
    # duplicate would make that level's own rank ambiguous. Checked here,
    # before rank-building ever runs, so either case is invalid_config
    # instead of a silent wrong-conflict-winner.
    rigor_order = cfg.get("rigor_order")
    if not isinstance(rigor_order, list) or not all(isinstance(e, str) for e in rigor_order):
        fail("rigor_order must be a list of strings")
    elif len(rigor_order) != len(set(rigor_order)):
        dupes = sorted({e for e in rigor_order if rigor_order.count(e) > 1})
        fail(f"rigor_order has duplicate entries: {dupes}")
    elif set(rigor_order) != set(levels):
        missing = sorted(set(levels) - set(rigor_order))
        extra = sorted(set(rigor_order) - set(levels))
        detail = []
        if missing:
            detail.append(f"missing {missing}")
        if extra:
            detail.append(f"names unknown level(s) {extra}")
        fail(f"rigor_order is not a permutation of [rigor.*] — {'; '.join(detail)}")

    for name, tbl in levels.items():
        if not isinstance(tbl, dict):
            fail(f"[rigor.{name}] is not a table")
            continue
        for field in ("review", "orchestrator_tier", "implementer_tier", "reviewer_tier", "budget"):
            if field not in tbl:
                fail(f"[rigor.{name}] is missing {field!r}")
        review_ref = tbl.get("review")
        if "review" in tbl:
            if not isinstance(review_ref, str):
                fail(f"[rigor.{name}].review must be a string (got {review_ref!r})")
            elif review_ref not in reviews:
                fail(f"[rigor.{name}].review={review_ref!r} names no [review.*] policy")
        budget_ref = tbl.get("budget")
        if "budget" in tbl:
            if not isinstance(budget_ref, str):
                fail(f"[rigor.{name}].budget must be a string (got {budget_ref!r})")
            elif budget_ref not in budgets:
                fail(f"[rigor.{name}].budget={budget_ref!r} names no [budget.*] profile")
        for field in ("orchestrator_tier", "implementer_tier", "reviewer_tier"):
            if field not in tbl:
                continue
            if not isinstance(tbl[field], str):
                fail(f"[rigor.{name}].{field} must be a string (got {tbl[field]!r})")
            elif tbl[field] not in LADDER:
                fail(f"[rigor.{name}].{field}={tbl[field]!r} is not a concrete ladder tier")

    # review/budget/strategy tables are spread wholesale into the output
    # below (main()'s "review": {**review_tbl, ...} and friends) — every
    # value inside ANY of them, not just the fields this function otherwise
    # inspects, must be JSON-safe before that spread can ever run, or
    # json.dumps() raises a raw TypeError on a TOML date/time value instead
    # of this function's clean invalid_config. Checked for every table
    # regardless of which rigor/strategy ends up selected, exactly like
    # every other check in this function.
    for name, tbl in reviews.items():
        if not isinstance(tbl, dict):
            fail(f"[review.{name}] is not a table")
        elif not json_safe(tbl):
            fail(f"[review.{name}] contains a value with no JSON equivalent (a TOML date/time, or a non-finite float?)")

    for name, tbl in budgets.items():
        if not isinstance(tbl, dict):
            fail(f"[budget.{name}] is not a table")
            continue
        if not json_safe(tbl):
            fail(f"[budget.{name}] contains a value with no JSON equivalent (a TOML date/time, or a non-finite float?)")
        for field in ("max_agent_runs", "max_parallel_agents"):
            if field not in tbl or not isinstance(tbl[field], int) or isinstance(tbl[field], bool):
                fail(f"[budget.{name}].{field} must be an integer")

    for name, tbl in strategies.items():
        if not isinstance(tbl, dict):
            fail(f"[strategy.{name}] is not a table")
        elif not json_safe(tbl):
            fail(f"[strategy.{name}] contains a value with no JSON equivalent (a TOML date/time, or a non-finite float?)")

    return ok


def filter_to_devflow_namespace(raw_labels):
    """Anything outside rigor:/strategy:/tier: is not this resolver's
    business at all — dropped here, before the trust filter or the label
    parser, so a plain `bug` or `area:ci` produces no warning of any kind
    (neither an untrusted_label_ignored under --unattended nor an
    unknown_label from the parser). Everything that DOES match one of the
    three namespaces still goes through full validation below — this is a
    namespace pre-filter, not a shape check."""
    return [raw for raw in raw_labels if raw.startswith(DEVFLOW_LABEL_PREFIXES)]


def filter_labels_by_trust(raw_labels, trusted_labels, *, unattended, warnings):
    """Returns the effective raw label list resolution should actually use.
    Callers pass namespace-filtered lists in (filter_to_devflow_namespace) —
    this function only implements the trust policy, not the namespace one.

    Interactive: every --label still applies (trust only affects
    requires_confirmation later) — --trusted-label entries are unioned in so
    a caller may assert trust for a label it did not separately re-pass via
    --label. Unattended (ADR 0006 D6.1): ONLY trusted labels apply; every
    other --label is dropped with a warning naming it, and --trusted-label
    entries are still unioned in for the same reason as above.
    """
    trusted_set = set(trusted_labels)
    if unattended:
        effective = [raw for raw in raw_labels if raw in trusted_set]
        for raw in raw_labels:
            if raw not in trusted_set:
                warnings.append({
                    "code": "untrusted_label_ignored",
                    "detail": f"{raw!r} ignored under --unattended (no matching --trusted-label) "
                              "— falls back to the default",
                })
    else:
        effective = list(raw_labels)
    for raw in trusted_labels:
        if raw not in effective:
            effective.append(raw)
    return effective


def validate_trusted_labels_against_builtin(trusted_labels, errors):
    """Only called when the config is absent. The built-in fallback honors
    exactly rigor=standard and strategy=plan (BUILTIN_CFG) — there are no
    tables to resolve anything else against. A --trusted-label is a
    verified, attributable instruction like an --override; naming something
    the built-in cannot honor is a deterministic error here too, not the
    warn-and-fall-through treatment a merely UNVERIFIED label's mismatch
    already gets (that path still applies via resolve_rigor/resolve_strategy
    for any trusted label that TOLERATES the mismatch, i.e. every non-rigor/
    non-strategy label, and for plain unverified labels)."""
    for raw in trusted_labels:
        parts = raw.split(":")
        if parts[0] == "rigor" and len(parts) == 2 and parts[1] != BUILTIN_RIGOR:
            errors.append({
                "code": "invalid_override",
                "detail": f"--trusted-label {raw!r} cannot be honored — .devflow.toml is absent, "
                          f"so only rigor:{BUILTIN_RIGOR} (the built-in fallback) resolves",
            })
        elif parts[0] == "strategy" and len(parts) == 2 and parts[1] != BUILTIN_STRATEGY:
            errors.append({
                "code": "invalid_override",
                "detail": f"--trusted-label {raw!r} cannot be honored — .devflow.toml is absent, "
                          f"so only strategy:{BUILTIN_STRATEGY} (the built-in fallback) resolves",
            })


def _add_tier_candidate(tier_candidates, role, value, raw, warnings, *, allow_adaptive):
    # `adaptive` is a valid provisioned tier value ONLY via the unqualified
    # tier:<value> label shape (allow_adaptive=True, role forced to
    # "implementer" by the caller) — label-registry.json's tier-role family
    # was never seeded with a role-scoped adaptive variant, so
    # tier:<role>:adaptive is not a provisioned label shape at all and is
    # "unknown" like any other unrecognized value, not a valid candidate
    # (see the module docstring).
    if value in LADDER or (allow_adaptive and value == "adaptive"):
        tier_candidates[role].append(value)
    else:
        allowed = f"({', '.join(LADDER)}{', adaptive' if allow_adaptive else ''})"
        suffix = " or `adaptive`" if allow_adaptive else ""
        warnings.append({
            "code": "unknown_label",
            "detail": f"{raw!r} is not a concrete ladder tier{suffix} {allowed}, ignored",
        })


def parse_labels(raw_labels, warnings):
    """Returns (rigor_labels, strategy_labels, tier_candidates). Callers
    pass namespace-filtered, trust-filtered labels in — every raw label here
    is assumed to already be this resolver's business.

    tier_candidates is {role: [valid ladder values, plus `adaptive` for
    "implementer" only]} — an unqualified tier:<value> label folds into
    "implementer" and may name `adaptive`; a scoped tier:<role>:<value> label
    folds into its named role but may NOT name `adaptive` (not a provisioned
    label shape — see the module docstring). A label naming something that
    is not accepted for its shape is dropped with a warning HERE, before the
    strongest-wins reduction, so an invalid candidate can never "win" by
    being the only one left.
    """
    rigor_labels = []
    strategy_labels = []
    tier_candidates = {role: [] for role in ROLES}
    for raw in raw_labels:
        parts = raw.split(":")
        if parts[0] == "rigor" and len(parts) == 2:
            rigor_labels.append(parts[1])
        elif parts[0] == "strategy" and len(parts) == 2:
            strategy_labels.append(parts[1])
        elif parts[0] == "tier" and len(parts) == 2:
            _add_tier_candidate(tier_candidates, "implementer", parts[1], raw, warnings, allow_adaptive=True)
        elif parts[0] == "tier" and len(parts) == 3 and parts[1] in ROLES:
            _add_tier_candidate(tier_candidates, parts[1], parts[2], raw, warnings, allow_adaptive=False)
        else:
            # Reachable only for a malformed shape WITHIN the devflow
            # namespace (e.g. "tier:bogus:role:extra", "rigor:x:y") — a
            # label outside rigor:/strategy:/tier: never reaches here at
            # all (filter_to_devflow_namespace runs first).
            warnings.append({
                "code": "unknown_label",
                "detail": f"{raw!r} is not a recognized rigor:/strategy:/tier: label shape, ignored",
            })
    return rigor_labels, strategy_labels, tier_candidates


def strongest_tier_per_role(tier_candidates):
    """Labels are an unordered set — GitHub attaches no meaning to which was
    applied first — so multiple tier labels landing on one role must resolve
    identically regardless of input order. Strongest-by-ladder-rank is the
    same conflict rule rigor itself uses (ADR 0006 D5: "a label only ever
    buys more capability or oversight"): a conflict can only ever raise the
    tier, never silently weaken it by depending on which label happened to
    be seen, or applied, last.

    A CONCRETE tier always beats `adaptive` for the same role (ADR 0006 D5)
    — `adaptive` is not on the ladder, so it never wins a rank comparison
    against something that is. A role whose candidates are ALL `adaptive`
    resolves to `adaptive` itself, for resolve_tiers to handle (preflight
    result, or preflight_required)."""
    result = {}
    for role, values in tier_candidates.items():
        if not values:
            continue
        concrete = [v for v in values if v != "adaptive"]
        result[role] = max(concrete, key=lambda v: LADDER_RANK[v]) if concrete else "adaptive"
    return result


def parse_overrides(raw_overrides, errors):
    explicit_rigor = None
    explicit_strategy = None
    tier_unqualified = None
    tier_scoped = {}
    for raw in raw_overrides:
        if "=" not in raw:
            errors.append({"code": "invalid_override", "detail": f"{raw!r} is not key=value"})
            continue
        key, value = raw.split("=", 1)
        if key == "rigor":
            explicit_rigor = value
        elif key == "strategy":
            explicit_strategy = value
        elif key == "tier":
            tier_unqualified = value
        elif key in ("tier.orchestrator", "tier.implementer", "tier.reviewer"):
            tier_scoped[key.split(".", 1)[1]] = value
        else:
            errors.append({"code": "invalid_override", "detail": f"unknown override key {key!r}"})
    return explicit_rigor, explicit_strategy, tier_unqualified, tier_scoped


def validate_override_tier_values(unqualified, scoped, errors):
    """Overrides are explicit and attributable, so an invalid tier value here
    is a hard error (never a silently-dropped candidate the way a bad label
    is). `adaptive` is REJECTED here specifically — an override is the
    explicit, attributable instruction channel (ADR 0006 D5), and "defer
    this to a preflight classifier" is not a concrete instruction the way
    naming a ladder tier is; an operator wanting preflight classification
    must use the tier:adaptive LABEL instead (unqualified only — see the
    module docstring). Coded invalid_input, distinct from invalid_override's
    "this names no recognized tier value at all" below — adaptive IS a
    recognized value, just not a legal one for this channel."""
    if unqualified == "adaptive":
        errors.append({
            "code": "invalid_input",
            "detail": "--override tier=adaptive is rejected — an explicit instruction names a "
                      "concrete tier; use a tier:adaptive LABEL instead if preflight "
                      "classification is what's actually wanted",
        })
        unqualified = None
    elif unqualified is not None and unqualified not in LADDER:
        errors.append({
            "code": "invalid_override",
            "detail": f"tier={unqualified!r} is not a concrete ladder tier ({', '.join(LADDER)})",
        })
        unqualified = None
    for role in list(scoped):
        if scoped[role] == "adaptive":
            errors.append({
                "code": "invalid_input",
                "detail": f"--override tier.{role}=adaptive is rejected — an explicit instruction "
                          "names a concrete tier; tier:<role>:adaptive is not even a provisioned "
                          "label shape, so preflight classification is only reachable via the "
                          "unqualified tier:adaptive LABEL, which targets implementer",
            })
            del scoped[role]
        elif scoped[role] not in LADDER:
            errors.append({
                "code": "invalid_override",
                "detail": f"tier.{role}={scoped[role]!r} is not a concrete ladder tier "
                          f"({', '.join(LADDER)})",
            })
            del scoped[role]
    return unqualified, scoped


def merge_tier_overrides(unqualified, scoped):
    """Unqualified targets the implementer; a scoped override for the same
    role is more specific and wins. Overrides are a single attributable
    operator's own instructions (not competing votes the way labels are), so
    this stays most-specific-wins rather than strongest-wins-by-rank — this
    ordering is this resolver's own documented choice, not independently
    specified."""
    merged = {}
    if unqualified is not None:
        merged["implementer"] = unqualified
    merged.update(scoped)
    return merged


def resolve_rigor(cfg, rigor_labels, explicit_rigor, warnings, errors):
    levels = cfg["rigor"]
    order = cfg["rigor_order"]
    rank = {name: i for i, name in enumerate(order)}
    if explicit_rigor is not None:
        if explicit_rigor not in levels:
            errors.append({
                "code": "invalid_override",
                "detail": f"rigor={explicit_rigor!r} names no [rigor.*] level",
            })
            return None, None
        return explicit_rigor, "explicit"
    known = [v for v in rigor_labels if v in levels]
    for v in rigor_labels:
        if v not in levels:
            warnings.append({"code": "unknown_label", "detail": f"rigor:{v} names no [rigor.*] level, ignored"})
    if known:
        return max(known, key=lambda v: rank.get(v, -1)), "label"
    return cfg.get("default_rigor"), "default"


def resolve_strategy(cfg, strategy_labels, explicit_strategy, unattended, warnings, errors):
    strategies = cfg["strategy"]
    if explicit_strategy is not None:
        if explicit_strategy not in strategies:
            errors.append({
                "code": "invalid_override",
                "detail": f"strategy={explicit_strategy!r} names no [strategy.*] value",
            })
            return None, None
        return explicit_strategy, "explicit"
    known = sorted({v for v in strategy_labels if v in strategies})
    for v in strategy_labels:
        if v not in strategies:
            warnings.append({"code": "unknown_label", "detail": f"strategy:{v} names no [strategy.*] value, ignored"})
    if len(known) > 1:
        if unattended:
            warnings.append({
                "code": "ambiguous_strategy",
                "detail": f"labels {known} are ambiguous (no rank) — defaulted to default_strategy",
            })
            return cfg.get("default_strategy"), "default"
        errors.append({
            "code": "ambiguous_strategy",
            "detail": f"labels {known} are ambiguous — strategies are not ranked; "
                      "an attributable operator instruction must pick one",
        })
        return None, None
    if len(known) == 1:
        return known[0], "label"
    return cfg.get("default_strategy"), "default"


def resolve_tiers(rigor_tbl, overrides_label, overrides_explicit, adaptive_result):
    """`requested` is what was actually asked for (may be `"adaptive"`);
    `value` is what the role resolves TO. When requested is `adaptive`:
      - adaptive_result given (--adaptive-result, the caller's preflight
        classification): value = adaptive_result, resolved exactly like an
        explicitly-requested concrete tier would be.
      - adaptive_result absent: preflight_required = True and value falls
        back to the rigor profile's OWN tier for that role — a provisional
        placeholder, not a claim that this is the final answer. off_profile
        is computed off the RESOLVED value, so a role sitting on its own
        provisional fallback is never flagged off-profile just for being
        unresolved; a role adaptive-resolved to something concrete IS
        checked against the profile like any other value.
    `requested` (not `value`) is what trust-checking must reconstruct the
    original raw label/override from — see tier_drove_untrusted_off_profile.
    """
    tiers = {}
    for role in ROLES:
        profile_value = rigor_tbl[f"{role}_tier"]
        requested, source = profile_value, "profile"
        if role in overrides_label:
            requested, source = overrides_label[role], "label"
        if role in overrides_explicit:
            requested, source = overrides_explicit[role], "explicit"

        preflight_required = False
        if requested == "adaptive":
            if adaptive_result is not None:
                value = adaptive_result
            else:
                preflight_required = True
                value = profile_value
        else:
            value = requested

        tiers[role] = {
            "value": value,
            "requested": requested,
            "source": source,
            "off_profile": value != profile_value,
            "preflight_required": preflight_required,
        }
    return tiers


def required_agent_runs_and_parallel(topology, min_agents):
    """min_agents means something different per topology (docs/guides/
    devflow.md, "Strategy: how the work is organized"), so the budget it
    needs does too — but ONLY council's counting convention changes the
    compatibility ARITHMETIC; every topology is checked against BOTH
    ceilings directly, with no subtraction:
      independent-proposals (council): min_agents counts PROPOSERS only —
        the coordinator that judges them afterward is one MORE run, but
        does not need a concurrent slot of its own (it runs once the
        proposers have finished). Needs max_agent_runs >= min_agents + 1
        and max_parallel_agents >= min_agents.
      lead-and-workers (orchestrate): min_agents counts the lead PLUS its
        workers (ADR 0007 D2's "a lead plus at least one worker") — the
        WHOLE minimum roster, lead included. Needs max_agent_runs >=
        min_agents and max_parallel_agents >= min_agents, exactly like the
        generic fallback below — there is no "the lead doesn't count"
        subtraction on either ceiling; specs/issue-strategy.md states the
        plain "min_agents exceeds max_agent_runs or max_parallel_agents"
        rule with no per-topology discount, and orchestrate does not
        special-case away from that the way council's different counting
        convention does.
      anything else: no topology-specific formula is defined, so fall back
        to the conservative same-value check.
    """
    if topology == "independent-proposals":
        return min_agents + 1, min_agents
    if topology == "lead-and-workers":
        return min_agents, min_agents
    return min_agents, min_agents


def check_incompatible(cfg, rigor_name, strategy_name, errors):
    if rigor_name is None or strategy_name is None:
        return
    strategy_tbl = cfg["strategy"][strategy_name]
    min_agents = strategy_tbl.get("min_agents")
    if not isinstance(min_agents, int) or isinstance(min_agents, bool):
        return
    topology = strategy_tbl.get("topology")
    required_runs, required_parallel = required_agent_runs_and_parallel(topology, min_agents)
    budget_name = cfg["rigor"][rigor_name]["budget"]
    budget = cfg["budget"][budget_name]
    if required_runs > budget["max_agent_runs"] or required_parallel > budget["max_parallel_agents"]:
        errors.append({
            "code": "incompatible_strategy",
            "detail": (
                f"strategy {strategy_name!r} ({topology!r}, min_agents={min_agents}) needs "
                f"max_agent_runs>={required_runs} and max_parallel_agents>={required_parallel}, "
                f"but rigor {rigor_name!r}'s budget {budget_name!r} allows "
                f"max_agent_runs={budget['max_agent_runs']}, "
                f"max_parallel_agents={budget['max_parallel_agents']}"
            ),
        })


def label_drove_untrusted_off_default(rigor_name, rigor_source, cfg, trusted_set):
    return (
        rigor_source == "label"
        and rigor_name != cfg.get("default_rigor")
        and f"rigor:{rigor_name}" not in trusted_set
    )


def strategy_drove_untrusted_off_default(strategy_name, strategy_source, cfg, trusted_set):
    return (
        strategy_source == "label"
        and strategy_name is not None
        and strategy_name != cfg.get("default_strategy")
        and f"strategy:{strategy_name}" not in trusted_set
    )


def tier_drove_untrusted_off_profile(role, tier, trusted_set):
    if tier["source"] != "label" or not tier["off_profile"]:
        return False
    # Reconstructed from `requested`, NOT `value`: when the label was the
    # unqualified `tier:adaptive` and --adaptive-result resolved it to a
    # concrete tier, `value` is that concrete tier but the label that was
    # actually APPLIED — and whose trust this checks — still reads
    # "adaptive". Checking trust against the resolved value would look for a
    # label that was never there. raw_scoped covers a concrete scoped label
    # (tier:<role>:economy); it can never match on requested=="adaptive"
    # since tier:<role>:adaptive is not a provisioned label shape at all
    # (see the module docstring) — requested=="adaptive" is only reachable
    # for role=="implementer", where raw_unqualified is the one that matters.
    raw_scoped = f"tier:{role}:{tier['requested']}"
    raw_unqualified = f"tier:{tier['requested']}" if role == "implementer" else None
    trusted = raw_scoped in trusted_set or (raw_unqualified is not None and raw_unqualified in trusted_set)
    return not trusted


def emit(output, errors):
    # The resolver's output itself is a versioned interoperability surface.
    # Keep this separate from config_schema_version: a resolver can report a
    # malformed or unsupported config without pretending it successfully
    # resolved that config's contract.
    output.setdefault("result_schema_version", SUPPORTED_SCHEMA_VERSION)
    # Diagnostic prose is deliberately actionable but not a compatibility
    # surface. Every v1 diagnostic carries a stable code and broad subject so
    # consumers can branch without parsing English text.
    subject_by_code = {
        "invalid_config": "config",
        "invalid_input": "input",
        "invalid_override": "override",
        "unknown_label": "label",
        "untrusted_label_ignored": "label",
        "ambiguous_strategy": "strategy",
        "incompatible_strategy": "strategy",
        "config_absent": "config",
        "legacy_merge_base_config": "config",
    }
    for collection in (output.get("warnings", []), output.get("errors", [])):
        for diagnostic in collection:
            diagnostic.setdefault("subject", subject_by_code.get(diagnostic.get("code"), "resolution"))
    print(json.dumps(output, indent=2, sort_keys=True))
    sys.exit(1 if errors else 0)


class DevflowArgumentParser(argparse.ArgumentParser):
    """argparse's default .error() prints a usage message to STDERR and
    exits 2 — bypassing this script's entire contract that every invocation
    emits one normalized JSON object to stdout and exits 0 or 1 (see the
    module docstring). A missing --config, an unknown flag, or an option
    missing its value would otherwise look like a crash — empty stdout, an
    exit code the documented contract never mentions — to a caller that
    only reads stdout and checks for 0/1. Overridden so those failures are
    reported exactly like any other invalid_input."""

    def error(self, message):
        errors = [{"code": "invalid_input", "detail": message}]
        emit({
            "config_path": None, "config_source": None, "config_sha256": None,
            "requires_confirmation": False, "preflight_required": False,
            "warnings": [], "errors": errors,
        }, errors)


def main():
    ap = DevflowArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--merge-base-config")
    ap.add_argument("--merge-base-absent", action="store_true")
    ap.add_argument("--config-unchanged", action="store_true")
    ap.add_argument("--label", action="append", default=[], dest="labels")
    ap.add_argument("--trusted-label", action="append", default=[], dest="trusted_labels")
    ap.add_argument("--override", action="append", default=[], dest="overrides")
    ap.add_argument("--adaptive-result")
    ap.add_argument("--unattended", action="store_true")
    args = ap.parse_args()

    warnings = []
    errors = []

    if args.adaptive_result is not None and args.adaptive_result not in LADDER:
        errors.append({
            "code": "invalid_input",
            "detail": f"--adaptive-result {args.adaptive_result!r} is not a concrete ladder tier "
                      f"({', '.join(LADDER)}) — it names what the caller's preflight classifier "
                      "already decided, so it can never itself be `adaptive`",
        })
        emit({"config_path": None, "config_source": None, "config_sha256": None,
              "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    # Exactly one config-basis flag is required — reading --config is NEVER
    # a silent default (see the module docstring). argparse's own
    # mutually-exclusive-group is deliberately not used here: its error
    # handling bypasses this script's "always emit clean JSON" contract.
    basis_given = [
        name for name, present in (
            ("--merge-base-config", bool(args.merge_base_config)),
            ("--merge-base-absent", args.merge_base_absent),
            ("--config-unchanged", args.config_unchanged),
        )
        if present
    ]
    if len(basis_given) != 1:
        errors.append({
            "code": "invalid_input",
            "detail": (
                "exactly one of --merge-base-config PATH, --merge-base-absent, or "
                f"--config-unchanged is required — got {len(basis_given)} "
                f"({', '.join(basis_given) if basis_given else 'none'}). Reading the branch "
                "config must never be a silent default: a branch that edits .devflow.toml could "
                "otherwise read its own (possibly weakened) copy instead of the merge-base's."
            ),
        })
        emit({"config_path": None, "config_source": None, "config_sha256": None,
              "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    if args.merge_base_absent:
        # The caller has explicitly CONFIRMED the merge-base commit has no
        # .devflow.toml — a real, valid state (e.g. this PR is the one
        # introducing the file). Distinct from merge_base_config naming a
        # path that just doesn't exist on disk, handled below: that is far
        # more likely a caller/extraction bug (git show <sha>:path failed,
        # wrong path, ...) than genuine absence, so it errors instead of
        # being silently treated the same as this confirmed case.
        read_path = None
        config_source = "absent"
    elif args.merge_base_config:
        read_path = args.merge_base_config
        config_source = "merge-base"
        if not os.path.exists(read_path):
            errors.append({
                "code": "invalid_input",
                "detail": (
                    f"--merge-base-config {read_path!r} does not exist — this looks like a "
                    "caller/extraction error (e.g. `git show <merge-base>:.devflow.toml` failed "
                    "or wrote nowhere), not a signal that the merge-base has no .devflow.toml; "
                    "pass --merge-base-absent instead if it genuinely does not"
                ),
            })
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": None,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)
    else:
        # The only remaining possibility, given basis_given has exactly one
        # member: --config-unchanged. The branch does not touch
        # .devflow.toml, so the merge-base rule does not apply and --config
        # is the right thing to read directly.
        read_path = args.config
        config_source = "branch"

    # A path that EXISTS but is not a regular file (a directory, a socket, a
    # FIFO, ...) is a caller/path mistake, not genuine absence — checked
    # here, uniformly, for whichever branch above produced read_path.
    # load_config()'s own os.path.isfile() check would otherwise treat it
    # exactly like a missing path and silently fall back to the built-in,
    # which is wrong for --config-unchanged (a typo'd directory path is not
    # "this repo has no .devflow.toml") and would be a misleading message
    # for --merge-base-config (already caught above as "does not exist",
    # which is inaccurate for something that does exist, just not as a
    # file). Only a path absent from the filesystem entirely may resolve as
    # absent.
    if read_path is not None and os.path.exists(read_path) and not os.path.isfile(read_path):
        errors.append({
            "code": "invalid_input",
            "detail": f"{read_path} exists but is not a regular file (a directory? a socket?) — "
                      "this looks like a caller/path mistake, not genuine absence; only a path "
                      "that does not exist at all may resolve as absent",
        })
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": None,
              "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    if read_path is None:
        cfg, digest = None, None
    else:
        try:
            cfg, digest = load_config(read_path)
        except ConfigReadError as exc:
            errors.append({"code": "invalid_config", "detail": str(exc)})
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": None,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    config_absent = cfg is None
    if config_absent:
        # Set once, here, rather than special-cased per emit() call below:
        # every exit path from this point on — success or error — reports
        # the config as absent and carries the same notice, not just the
        # final happy-path output. read_path is None specifically for the
        # --merge-base-absent case (an explicit confirmation, not a path
        # that failed to resolve) — worded differently since "None does not
        # exist" would be a confusing thing to print.
        config_source = "absent"
        if read_path is None:
            detail = (
                "merge-base .devflow.toml confirmed absent via --merge-base-absent "
                "— resolved from the built-in fallback"
            )
        else:
            detail = f"{read_path} does not exist — resolved from the built-in fallback"
        warnings.append({"code": "config_absent", "detail": detail})

    legacy_merge_base = (
        not config_absent and config_source == "merge-base" and "schema_version" not in cfg
    )
    if legacy_merge_base:
        warnings.append({
            "code": "legacy_merge_base_config",
            "detail": (
                "merge-base .devflow.toml predates schema v1; using the legacy compatibility "
                "basis only for this self-edit transition"
            ),
        })

    if not config_absent:
        required_tables = ("rigor", "strategy", "review", "budget", "tier")
        missing = [t for t in required_tables if t not in cfg]
        if missing or "default_rigor" not in cfg or "default_strategy" not in cfg:
            detail_bits = missing + (["default_rigor"] if "default_rigor" not in cfg else []) + (
                ["default_strategy"] if "default_strategy" not in cfg else [])
            errors.append({
                "code": "invalid_config",
                "detail": f"{read_path}: missing required key(s)/table(s): {', '.join(detail_bits)}",
            })
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)
        if not validate_config_references(cfg, errors, allow_legacy_merge_base=legacy_merge_base):
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)
        if not validate_schema_v1_shape(cfg, errors, allow_legacy_merge_base=legacy_merge_base):
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    resolution_cfg = BUILTIN_CFG if config_absent else cfg
    trusted_labels = filter_to_devflow_namespace(args.trusted_labels)
    trusted_set = set(trusted_labels)

    if config_absent:
        validate_trusted_labels_against_builtin(trusted_labels, errors)
        if errors:
            emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
                  "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    devflow_labels = filter_to_devflow_namespace(args.labels)
    effective_labels = filter_labels_by_trust(
        devflow_labels, trusted_labels, unattended=args.unattended, warnings=warnings)
    rigor_labels, strategy_labels, tier_candidates = parse_labels(effective_labels, warnings)
    explicit_rigor, explicit_strategy, tier_override_unqualified, tier_override_scoped = parse_overrides(
        args.overrides, errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    tier_override_unqualified, tier_override_scoped = validate_override_tier_values(
        tier_override_unqualified, tier_override_scoped, errors)
    if errors:
        emit({"config_path": read_path, "config_source": config_source, "config_sha256": digest,
              "requires_confirmation": False, "preflight_required": False,
              "warnings": warnings, "errors": errors}, errors)

    rigor_name, rigor_source = resolve_rigor(resolution_cfg, rigor_labels, explicit_rigor, warnings, errors)
    if config_absent and rigor_source == "default":
        rigor_source = "builtin"
    if rigor_name is None:
        emit({
            "config_path": read_path, "config_source": config_source, "config_sha256": digest,
            "selections": {"rigor": {"value": None, "source": rigor_source}},
            "requires_confirmation": False, "preflight_required": False,
            "warnings": warnings, "errors": errors,
        }, errors)

    strategy_name, strategy_source = resolve_strategy(
        resolution_cfg, strategy_labels, explicit_strategy, args.unattended, warnings, errors)
    if config_absent and strategy_source == "default":
        strategy_source = "builtin"

    if config_absent:
        review_policy_name = BUILTIN_RIGOR
        review_tbl = BUILTIN_REVIEW
        budget_name = None
        budget_tbl = None
        strategy_tbl = None
        tiers = {
            role: {"value": None, "requested": None, "source": "builtin",
                   "off_profile": False, "preflight_required": False}
            for role in ROLES
        }
    else:
        check_incompatible(cfg, rigor_name, strategy_name, errors)
        rigor_tbl = cfg["rigor"][rigor_name]
        review_policy_name = rigor_tbl["review"]
        review_tbl = cfg["review"][review_policy_name]
        budget_name = rigor_tbl["budget"]
        budget_tbl = cfg["budget"][budget_name]
        strategy_tbl = cfg["strategy"][strategy_name] if strategy_name is not None else None
        overrides_label = strongest_tier_per_role(tier_candidates)
        overrides_explicit = merge_tier_overrides(tier_override_unqualified, tier_override_scoped)
        tiers = resolve_tiers(rigor_tbl, overrides_label, overrides_explicit, args.adaptive_result)

    off_default = rigor_name != resolution_cfg.get("default_rigor") or (
        strategy_name is not None and strategy_name != resolution_cfg.get("default_strategy"))
    off_profile = any(t["off_profile"] for t in tiers.values())
    preflight_required = any(t["preflight_required"] for t in tiers.values())

    # Interactive-only (ADR 0006 D6.2): an off-default/off-profile result is
    # fine when it came from an explicit override or a TRUSTED label — both
    # are attributable to an authorized actor. It requires operator
    # confirmation when the label that produced it is not in --trusted-label.
    # Unattended automation never sets this: it already only acted on
    # trusted labels in the first place (D6.1), so there is nothing left
    # here for a human to confirm synchronously. Never true when the config
    # is absent, either — the only value achievable is the built-in's own,
    # which is by definition never off its own default.
    requires_confirmation = False
    if not args.unattended and not config_absent:
        if label_drove_untrusted_off_default(rigor_name, rigor_source, resolution_cfg, trusted_set):
            requires_confirmation = True
        if strategy_drove_untrusted_off_default(strategy_name, strategy_source, resolution_cfg, trusted_set):
            requires_confirmation = True
        if any(tier_drove_untrusted_off_profile(role, t, trusted_set) for role, t in tiers.items()):
            requires_confirmation = True

    emit({
        "config_path": read_path,
        "config_source": config_source,
        "config_sha256": digest,
        "config_schema_version": None if config_absent else cfg.get("schema_version", 0),
        "selections": {
            "rigor": {"value": rigor_name, "source": rigor_source},
            "strategy": {"value": strategy_name, "source": strategy_source},
        },
        "review": {
            **review_tbl, "policy": review_policy_name,
            "source": "builtin" if config_absent else "profile",
            "min_rounds_scope": MIN_ROUNDS_SCOPE,
        },
        "tiers": tiers,
        "budget": None if budget_tbl is None else {**budget_tbl, "name": budget_name, "source": "profile"},
        "strategy_fields": strategy_tbl,
        "disclosure": {
            "off_default": off_default,
            "off_profile": off_profile,
            # Full reviewer-harness family selection depends on which
            # harnesses are actually configured/authenticated in the
            # consuming environment, which this reference resolver has no
            # way to know — that is consumer-specific (docs/guides/devflow.md
            # covers the tier-floor/harness/family-diversity split) and out
            # of scope for a config-only resolver. `null` means genuinely
            # UNKNOWN here, not "no" — a caller must not treat a missing
            # same-family disclosure as "different family confirmed" just
            # because this resolver said false. A fuller resolver (#1048)
            # that is handed actual configured families could compute this
            # for real.
            "same_family_reviewer": None,
        },
        "requires_confirmation": requires_confirmation,
        "preflight_required": preflight_required,
        "warnings": warnings,
        "errors": errors,
    }, errors)


if __name__ == "__main__":
    main()
