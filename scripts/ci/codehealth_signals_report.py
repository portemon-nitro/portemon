#!/usr/bin/env python3
"""Advisory clone-pair report from scan stage files and a raw duplicate report.

Reads the deterministic per-file line-class evidence, syntax observations,
and rule census written by the Lua signal scan beside this file, plus the
existing duplicate report produced by the repository's jscpd invocation.
Every raw duplicate pair is preserved with both endpoints, classified by
positional line alignment against the line-class evidence, and published
together with the unchanged observations as three machine-readable files:
an index summary plus full observation and clone streams.

The inspected repository is only read, never modified. Any unreadable,
contradictory, or out-of-manifest input aborts without publishing a
report; an empty duplicate set is valid only when the detector aggregate
agrees it is empty. Every published observation stays unreviewed and
carries no verdict.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import codehealth_scope


REPOSITORY = "portemon-nitro/portemon"
SOURCE_URL_PREFIX = "https://github.com/portemon-nitro/portemon/blob/"
SCHEMA_VERSION = 1
METHOD_VERSION = 1
SCOPE_NAME = "codehealth-structural"

SOURCE_RULES = (
    ("lua-cast-directive", "typing"),
    ("lua-inline-as-cast", "typing"),
    ("lua-string-dispatch", "verbosity_candidate"),
    ("lua-unknown-keyed-table", "typing"),
    ("lua-unknown-valued-table", "typing"),
    ("pn-explicit-nil-init", "verbosity_candidate"),
)
SOURCE_GROUPS = dict(SOURCE_RULES)
CLONE_RULE = "lua-behavioral-clone-pair"
CLONE_GROUP = "duplication_candidate"
ALL_RULE_IDS = tuple(rule for rule, _ in SOURCE_RULES) + (CLONE_RULE,)

CLASS_NAMES = (
    "behavior_candidate",
    "pure_data",
    "mixed",
    "unknown",
    "unaligned",
)
REASON_FOR_CLASS = {
    "behavior_candidate": "aligned_behavior",
    "pure_data": "both_literal_data",
    "mixed": "data_behavior_mixture",
    "unknown": "no_proven_alignment",
    "unaligned": "unequal_source_span",
}
CLASS_FOR_REASON = {reason: name for name, reason in REASON_FOR_CLASS.items()}

OMITTED_FAMILIES = (
    ("table_key_redundancy", "unproven_provenance"),
    ("magic_literals", "low_precision"),
    ("defensive_density", "semantic_proof_required"),
    ("bool_comparisons", "semantic_proof_required"),
    ("nil_false_fallback", "nil_false_semantics"),
    ("trivial_wrappers", "legitimate_interfaces"),
    ("empty_branch", "no_calibration_hits"),
)

FINDING_FIELDS = (
    "id",
    "ruleId",
    "group",
    "path",
    "subsystem",
    "startByte",
    "endByte",
    "startLine",
    "endLine",
    "sourceUrl",
    "reviewState",
    "scoreEligible",
    "details",
)
MASK_BUCKETS = ("behavior", "mixed", "pureData", "unknown")


class ReportError(ValueError):
    """A fail-closed report failure: nothing is published on this run."""


def _dump(value) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
        ensure_ascii=False,
    )


def _encode_jsonl(records) -> str:
    return "".join(_dump(record) + "\n" for record in records)


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _subsystem_for_path(path: str) -> str:
    # Same grouping as the existing quality report so per-file rows stay
    # comparable. Kept as a small local copy because importing the report
    # builder would run its history/scope loaders at module top level,
    # and the Lua scan beside this file mirrors it for the same reason.
    parts = path.split("/")
    if parts[0] == "libs" and len(parts) > 1:
        return f"libs/{parts[1]}"
    if parts[0] == "game" and len(parts) > 1 and parts[1] == "hgss":
        return "game/hgss"
    return parts[0]


def _parse_jsonl(blob: bytes, label: str) -> list[dict]:
    try:
        text = blob.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReportError(f"invalid text in {label}: {error}") from error
    rows: list[dict] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ReportError(f"invalid row in {label}: {error}") from error
        if not isinstance(row, dict):
            raise ReportError(f"invalid row in {label}: not an object")
        rows.append(row)
    return rows


def _head_commit(root: Path) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReportError(f"cannot resolve source commit: {error}") from error
    commit = completed.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ReportError(f"invalid source commit {commit!r}")
    return commit


def _finding_id(rule_id: str, path: str, start: int, end: int, details: dict) -> str:
    canonical = json.dumps(
        details,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
        ensure_ascii=False,
    )
    payload = "\x00".join((rule_id, path, str(start), str(end), canonical))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _read_original_source(root: Path, relative: str) -> bytes:
    target = root / relative
    if target.is_symlink():
        raise ReportError(f"refusing symlinked source {relative!r}")
    resolved = target.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise ReportError(
            f"source escapes repository root: {relative!r}"
        ) from error
    try:
        data = resolved.read_bytes()
    except OSError as error:
        raise ReportError(f"cannot read source {relative!r}: {error}") from error
    if not resolved.is_file():
        raise ReportError(f"source is not a file: {relative!r}")
    return data


def _load_source_evidence(repository_root, manifest_path, stage_dir) -> dict:
    """Validate the scan stage files against the manifest and live sources."""
    root = codehealth_scope._resolve_repository_root(Path(repository_root))
    try:
        manifest_bytes = Path(manifest_path).read_bytes()
    except OSError as error:
        raise ReportError(
            f"cannot read structural manifest {manifest_path}: {error}"
        ) from error
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_paths = codehealth_scope._read_manifest_file(Path(manifest_path))
    manifest_set = set(manifest_paths)
    commit = _head_commit(root)

    stage = Path(stage_dir)
    try:
        rules_blob = (stage / "rules.json").read_bytes()
        findings_blob = (stage / "findings.jsonl").read_bytes()
        source_blob = (stage / "source.jsonl").read_bytes()
    except OSError as error:
        raise ReportError(f"cannot read scan stage files: {error}") from error
    try:
        rules = json.loads(rules_blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReportError(f"invalid rules.json: {error}") from error
    if not isinstance(rules, dict):
        raise ReportError("invalid rules.json: not an object")
    if rules.get("schemaVersion") != 1:
        raise ReportError("invalid rules.json: unsupported schemaVersion")
    if rules.get("commit") != commit:
        raise ReportError("scan stage commit does not match repository HEAD")
    if rules.get("manifestSha256") != manifest_sha:
        raise ReportError("scan stage manifest digest does not match manifest")
    if rules.get("filesParsed") != len(manifest_paths):
        raise ReportError("scan stage file count does not match manifest")
    detectors = rules.get("detectors")
    if not isinstance(detectors, list) or len(detectors) != len(SOURCE_RULES):
        raise ReportError("invalid rules.json: detector census must list six rules")
    expected_counts: dict[str, int] = {}
    for entry in detectors:
        if not isinstance(entry, dict):
            raise ReportError("invalid rules.json: detector entry must be an object")
        rule_id = entry.get("id")
        if rule_id not in SOURCE_GROUPS:
            raise ReportError(f"invalid rules.json: unknown rule {rule_id!r}")
        if rule_id in expected_counts:
            raise ReportError(f"invalid rules.json: duplicate rule {rule_id!r}")
        if entry.get("group") != SOURCE_GROUPS[rule_id]:
            raise ReportError(f"invalid rules.json: wrong group for {rule_id!r}")
        status = entry.get("status")
        observations = entry.get("observations")
        if status not in ("executed_with_hits", "executed_no_match"):
            raise ReportError(f"invalid rules.json: bad status for {rule_id!r}")
        if not _is_int(observations) or observations < 0:
            raise ReportError(
                f"invalid rules.json: bad observation count for {rule_id!r}"
            )
        if (status == "executed_with_hits") != (observations > 0):
            raise ReportError(
                f"invalid rules.json: status disagrees with count for {rule_id!r}"
            )
        expected_counts[rule_id] = observations

    source_rows = _parse_jsonl(source_blob, "source.jsonl")
    rows_by_path: dict[str, dict] = {}
    masks: dict[str, dict] = {}
    raw_by_path: dict[str, bytes] = {}
    for row in source_rows:
        path = row.get("path")
        if path not in manifest_set:
            raise ReportError(f"source row for unknown path {path!r}")
        if path in rows_by_path:
            raise ReportError(f"duplicate source row for {path!r}")
        digest = row.get("sourceSha256")
        buckets = row.get("sloc")
        if not isinstance(digest, str) or not isinstance(buckets, dict):
            raise ReportError(f"invalid source row for {path!r}")
        if set(buckets) != set(MASK_BUCKETS):
            raise ReportError(f"invalid line masks for {path!r}")
        data = _read_original_source(root, path)
        if digest != hashlib.sha256(data).hexdigest():
            raise ReportError(f"source hash mismatch for {path!r}")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ReportError(f"invalid text in {path!r}: {error}") from error
        line_count = len(text.splitlines())
        seen_lines: set[int] = set()
        for bucket in MASK_BUCKETS:
            numbers = buckets[bucket]
            if not isinstance(numbers, list):
                raise ReportError(f"invalid line masks for {path!r}")
            if numbers != sorted(numbers):
                raise ReportError(f"line masks for {path!r} are not sorted")
            for number in numbers:
                if not _is_int(number):
                    raise ReportError(f"invalid masked line in {path!r}")
                if not 1 <= number <= line_count:
                    raise ReportError(f"masked line out of range in {path!r}")
                if number in seen_lines:
                    raise ReportError(f"masked line listed twice in {path!r}")
                seen_lines.add(number)
        rows_by_path[path] = row
        masks[path] = {bucket: list(buckets[bucket]) for bucket in MASK_BUCKETS}
        raw_by_path[path] = data
    if set(rows_by_path) != manifest_set:
        raise ReportError("scan stage rows do not cover the manifest exactly once")

    findings = _parse_jsonl(findings_blob, "findings.jsonl")
    seen_ids: set[str] = set()
    actual_counts = {rule_id: 0 for rule_id, _ in SOURCE_RULES}
    for finding in findings:
        for field in FINDING_FIELDS:
            if field not in finding:
                raise ReportError(f"observation is missing {field!r}")
        rule_id = finding["ruleId"]
        if rule_id not in SOURCE_GROUPS:
            raise ReportError(f"unknown observation family {rule_id!r}")
        if finding["group"] != SOURCE_GROUPS[rule_id]:
            raise ReportError(f"observation has wrong group for {rule_id!r}")
        path = finding["path"]
        if path not in manifest_set:
            raise ReportError(f"observation for unknown path {path!r}")
        if finding["subsystem"] != _subsystem_for_path(path):
            raise ReportError(f"observation has wrong owner for {path!r}")
        data = raw_by_path[path]
        start = finding["startByte"]
        end = finding["endByte"]
        start_line = finding["startLine"]
        end_line = finding["endLine"]
        if not _is_int(start) or not _is_int(end):
            raise ReportError(f"observation has invalid span in {path!r}")
        if not 0 <= start < end <= len(data):
            raise ReportError(f"observation span out of range in {path!r}")
        try:
            data[start:end].decode("utf-8")
        except UnicodeDecodeError as error:
            raise ReportError(
                f"observation span splits text in {path!r}: {error}"
            ) from error
        if start_line != data.count(b"\n", 0, start) + 1:
            raise ReportError(f"observation has wrong start line in {path!r}")
        if end_line != data.count(b"\n", 0, max(start, end - 1)) + 1:
            raise ReportError(f"observation has wrong end line in {path!r}")
        if finding["reviewState"] != "unreviewed":
            raise ReportError(f"observation carries a verdict in {path!r}")
        if finding["scoreEligible"] is not False:
            raise ReportError(f"observation is marked eligible in {path!r}")
        details = finding["details"]
        if not isinstance(details, dict):
            raise ReportError(f"observation has invalid details in {path!r}")
        if finding["id"] != _finding_id(rule_id, path, start, end, details):
            raise ReportError(f"observation identity mismatch in {path!r}")
        if finding["id"] in seen_ids:
            raise ReportError(f"duplicate observation identity in {path!r}")
        seen_ids.add(finding["id"])
        actual_counts[rule_id] += 1
    if actual_counts != expected_counts:
        raise ReportError("observation counts disagree with the rule census")

    return {
        "root": root,
        "commit": commit,
        "manifest_sha": manifest_sha,
        "manifest": manifest_paths,
        "rows": rows_by_path,
        "masks": masks,
        "raw": raw_by_path,
        "rules": rules,
        "findings": findings,
        "findings_bytes": findings_blob,
    }


def _normalize_jscpd_endpoint(endpoint, manifest_set, ceilings) -> tuple[str, int, int]:
    """Check one duplicate endpoint against manifest paths and line bounds."""
    if not isinstance(endpoint, dict):
        raise ReportError("duplicate endpoint must be an object")
    try:
        name = endpoint["name"]
        start = endpoint["start"]
        end = endpoint["end"]
    except KeyError as error:
        raise ReportError(f"duplicate endpoint is missing {error}") from error
    if not isinstance(name, str) or not name:
        raise ReportError(f"duplicate endpoint has an invalid path {name!r}")
    if name.startswith("./"):
        name = name[2:]
    parts = name.split("/")
    if (
        "\\" in name
        or name.startswith("/")
        or (len(name) >= 2 and name[1] == ":")
        or ".." in parts
        or "" in parts
    ):
        raise ReportError(f"duplicate endpoint has an unsafe path {name!r}")
    if name not in manifest_set:
        raise ReportError(f"duplicate endpoint is outside the manifest: {name!r}")
    if not _is_int(start) or not _is_int(end):
        raise ReportError(f"duplicate endpoint has an invalid range in {name!r}")
    if not 1 <= start <= end:
        raise ReportError(f"duplicate endpoint has an impossible range in {name!r}")
    if end > ceilings.get(name, 0):
        raise ReportError(f"duplicate endpoint is out of file in {name!r}")
    return name, start, end


def normalize_clones(duplicates_report, source_masks) -> list[dict]:
    """Classify every raw duplicate pair with positional line alignment."""
    if not isinstance(duplicates_report, dict):
        raise ReportError("duplicate report must be an object")
    statistics = duplicates_report.get("statistics")
    total = statistics.get("total") if isinstance(statistics, dict) else None
    raw_total = total.get("clones") if isinstance(total, dict) else None
    if not _is_int(raw_total) or raw_total < 0:
        raise ReportError("duplicate report has an invalid clone total")
    if "duplicates" not in duplicates_report:
        if raw_total != 0:
            raise ReportError("duplicate report omits pairs for a nonzero total")
        pairs: list = []
    else:
        pairs = duplicates_report["duplicates"]
        if not isinstance(pairs, list):
            raise ReportError("duplicate report pairs must be an array")
        if len(pairs) != raw_total:
            raise ReportError("duplicate pair count disagrees with the total")
    if not isinstance(source_masks, dict):
        raise ReportError("line masks must be an object")
    eligible: dict[str, set[int]] = {}
    line_class: dict[str, dict[int, str]] = {}
    ceilings: dict[str, int] = {}
    for path, buckets in source_masks.items():
        if not isinstance(buckets, dict) or set(buckets) != set(MASK_BUCKETS):
            raise ReportError(f"invalid line masks for {path!r}")
        for bucket in MASK_BUCKETS:
            if not isinstance(buckets[bucket], list) or any(
                not _is_int(number) for number in buckets[bucket]
            ):
                raise ReportError(f"invalid line masks for {path!r}")
        eligible[path] = set(buckets["behavior"]) | set(buckets["mixed"])
        table: dict[int, str] = {}
        for bucket in MASK_BUCKETS:
            for number in buckets[bucket]:
                table[number] = bucket
        line_class[path] = table
        flat = [n for bucket in MASK_BUCKETS for n in buckets[bucket]]
        ceilings[path] = max(flat) if flat else 0
    manifest_set = set(source_masks)

    records: list[dict] = []
    seen_keys: set[tuple] = set()
    for pair in pairs:
        if not isinstance(pair, dict):
            raise ReportError("duplicate pair must be an object")
        try:
            first_raw = pair["firstFile"]
            second_raw = pair["secondFile"]
        except KeyError as error:
            raise ReportError(f"duplicate pair is missing {error}") from error
        tokens = pair.get("tokens")
        lines = pair.get("lines")
        if not _is_int(tokens) or tokens < 0:
            raise ReportError("duplicate pair has invalid tokens")
        first_path, first_start, first_end = _normalize_jscpd_endpoint(
            first_raw, manifest_set, ceilings
        )
        second_path, second_start, second_end = _normalize_jscpd_endpoint(
            second_raw, manifest_set, ceilings
        )
        if (
            not _is_int(lines)
            or lines <= 0
            or lines != first_end - first_start + 1
        ):
            raise ReportError("duplicate pair has inconsistent lines")
        first_key = (first_path, first_start, first_end)
        second_key = (second_path, second_start, second_end)
        if second_key < first_key:
            first_key, second_key = second_key, first_key
        key = first_key + second_key + (tokens,)
        if key in seen_keys:
            raise ReportError("duplicate report repeats a pair")
        seen_keys.add(key)
        first_path, first_start, first_end = first_key
        second_path, second_start, second_end = second_key
        pair_id = hashlib.sha256(
            "\x00".join(
                (
                    first_path,
                    str(first_start),
                    str(first_end),
                    second_path,
                    str(second_start),
                    str(second_end),
                    str(tokens),
                )
            ).encode("utf-8")
        ).hexdigest()
        same_file = first_path == second_path
        overlap = same_file and first_start <= second_end and second_start <= first_end
        if (first_end - first_start) != (second_end - second_start):
            alignment = "unequal"
            pair_class = "unaligned"
            reason = REASON_FOR_CLASS["unaligned"]
            first_lines: list[int] = []
            second_lines: list[int] = []
        else:
            alignment = "equal"
            first_lines = []
            second_lines = []
            for offset in range(first_end - first_start + 1):
                first_line = first_start + offset
                second_line = second_start + offset
                if (
                    first_line in eligible[first_path]
                    and second_line in eligible[second_path]
                ):
                    first_lines.append(first_line)
                    second_lines.append(second_line)
            first_span = [
                line_class[first_path].get(number, "unknown")
                for number in range(first_start, first_end + 1)
            ]
            second_span = [
                line_class[second_path].get(number, "unknown")
                for number in range(second_start, second_end + 1)
            ]
            if first_lines:
                pair_class = "behavior_candidate"
            elif all(name == "pureData" for name in first_span) and all(
                name == "pureData" for name in second_span
            ):
                pair_class = "pure_data"
            elif any(
                name in ("pureData", "mixed") for name in first_span + second_span
            ):
                pair_class = "mixed"
            else:
                pair_class = "unknown"
            reason = REASON_FOR_CLASS[pair_class]
        records.append(
            {
                "schemaVersion": SCHEMA_VERSION,
                "id": pair_id,
                "source": "jscpd",
                "first": {
                    "path": first_path,
                    "startLine": first_start,
                    "endLine": first_end,
                    "eligibleAlignedLines": first_lines,
                },
                "second": {
                    "path": second_path,
                    "startLine": second_start,
                    "endLine": second_end,
                    "eligibleAlignedLines": second_lines,
                },
                "sameFile": same_file,
                "overlap": overlap,
                "tokens": tokens,
                "pairClass": pair_class,
                "alignment": alignment,
                "reasonCode": reason,
                "scoreEligible": False,
            }
        )
    records.sort(
        key=lambda record: (
            record["first"]["path"],
            record["first"]["startLine"],
            record["second"]["path"],
            record["second"]["startLine"],
            record["id"],
        )
    )
    return records


def _record_aggregates(findings, clones) -> dict:
    """Count observations, pair classes, touched files, and covered lines."""
    source_counts: dict[str, dict[str, int]] = {}
    source_files: dict[str, set[str]] = {}
    for finding in findings:
        bucket = source_counts.setdefault(finding["path"], {})
        bucket[finding["ruleId"]] = bucket.get(finding["ruleId"], 0) + 1
        source_files.setdefault(finding["ruleId"], set()).add(finding["path"])
    class_counts = {name: 0 for name in CLASS_NAMES}
    for record in clones:
        pair_class = record.get("pairClass")
        if pair_class not in class_counts:
            raise ReportError(f"unknown pair class {pair_class!r}")
        class_counts[pair_class] += 1
    candidates = [
        record for record in clones if record["pairClass"] == "behavior_candidate"
    ]
    pair_touch: dict[str, int] = {}
    covered: set[tuple[str, int]] = set()
    for record in candidates:
        for touched in {record["first"]["path"], record["second"]["path"]}:
            pair_touch[touched] = pair_touch.get(touched, 0) + 1
        for side in (record["first"], record["second"]):
            for line in side["eligibleAlignedLines"]:
                covered.add((side["path"], line))
    covered_by_file: dict[str, set[int]] = {}
    for path, line in covered:
        covered_by_file.setdefault(path, set()).add(line)
    return {
        "source_counts": source_counts,
        "source_files": source_files,
        "class_counts": class_counts,
        "candidates": len(candidates),
        "pair_touch": pair_touch,
        "covered": covered,
        "covered_by_file": covered_by_file,
    }


def _file_rows(evidence, aggregates) -> list[dict]:
    rows: list[dict] = []
    for path in evidence["manifest"]:
        buckets = evidence["masks"][path]
        behavior = len(buckets["behavior"])
        mixed = len(buckets["mixed"])
        pure = len(buckets["pureData"])
        unknown = len(buckets["unknown"])
        counts = aggregates["source_counts"].get(path, {})
        by_rule = {
            rule_id: (
                aggregates["pair_touch"].get(path, 0)
                if rule_id == CLONE_RULE
                else counts.get(rule_id, 0)
            )
            for rule_id in ALL_RULE_IDS
        }
        rows.append(
            {
                "path": path,
                "subsystem": _subsystem_for_path(path),
                "sourceSha256": evidence["rows"][path]["sourceSha256"],
                "sloc": {
                    "behavior": behavior,
                    "mixed": mixed,
                    "pureData": pure,
                    "unknown": unknown,
                    "eligible": behavior + mixed,
                    "total": behavior + mixed + pure + unknown,
                },
                "byRule": by_rule,
                "cloneCandidateCoveredLines": len(
                    aggregates["covered_by_file"].get(path, set())
                ),
            }
        )
    return rows


def _subsystem_rows(file_rows) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    for row in file_rows:
        grouped.setdefault(row["subsystem"], []).append(row)
    owners: list[dict] = []
    for name in sorted(grouped):
        members = grouped[name]
        sloc = {
            key: sum(member["sloc"][key] for member in members)
            for key in ("behavior", "mixed", "pureData", "unknown", "eligible", "total")
        }
        owners.append(
            {
                "name": name,
                "files": len(members),
                "sloc": sloc,
                "byRule": {
                    rule_id: sum(member["byRule"][rule_id] for member in members)
                    for rule_id in ALL_RULE_IDS
                },
                "cloneCandidateCoveredLines": sum(
                    member["cloneCandidateCoveredLines"] for member in members
                ),
            }
        )
    return owners


def _rules_index(evidence, aggregates) -> dict:
    index: dict[str, dict] = {}
    for rule_id, group in SOURCE_RULES:
        touched = sorted(aggregates["source_files"].get(rule_id, set()))
        observations = sum(
            counts.get(rule_id, 0)
            for counts in aggregates["source_counts"].values()
        )
        index[rule_id] = {
            "group": group,
            "status": (
                "executed_with_hits" if observations else "executed_no_match"
            ),
            "observations": observations,
            "affectedFiles": touched,
        }
    touched = sorted(
        path for path, count in aggregates["pair_touch"].items() if count > 0
    )
    index[CLONE_RULE] = {
        "group": CLONE_GROUP,
        "status": "executed_with_hits" if aggregates["candidates"] else "executed_no_match",
        "observations": aggregates["candidates"],
        "affectedFiles": touched,
    }
    return index


def _python_tool_version(module_name: str, distribution: str) -> str:
    """Best-effort installed-version provenance for a Python tool.

    A module `__version__` marker wins when present; otherwise the
    installed distribution metadata answers. Anything undiscoverable
    stays the honest string "unknown" rather than aborting the build."""
    try:
        module = importlib.import_module(module_name)
    except ImportError:
        module = None
    if module is not None:
        marker = getattr(module, "__version__", None)
        if marker is not None:
            return str(marker)[:64]
    try:
        from importlib.metadata import version as _distribution_version

        return str(_distribution_version(distribution))[:64]
    except Exception:
        return "unknown"


def _tool_versions() -> dict:
    tree_version = _python_tool_version("tree_sitter", "tree-sitter")
    lua_version = _python_tool_version("tree_sitter_lua", "tree-sitter-lua")
    detector_version = "unknown"
    try:
        completed = subprocess.run(
            ["jscpd", "--version"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        tokens = ((completed.stdout or "") + " " + (completed.stderr or "")).split()
        if completed.returncode == 0 and tokens:
            detector_version = tokens[0][:64]
    except (OSError, subprocess.SubprocessError):
        detector_version = "unknown"
    return {
        "treeSitter": tree_version,
        "treeSitterLua": lua_version,
        "jscpd": detector_version,
    }


def build_summary(validated_sources, validated_findings, clones, commit) -> dict:
    """Combine validated scan evidence and classified pairs into the index."""
    evidence = validated_sources
    if commit != evidence["commit"]:
        raise ReportError("summary commit does not match validated evidence")
    prefix = f"{SOURCE_URL_PREFIX}{commit}/"

    def _url(path: str, start: int, end: int) -> str:
        if start == end:
            return f"{prefix}{path}#L{start}"
        return f"{prefix}{path}#L{start}-L{end}"

    stamped: list[dict] = []
    for record in clones:
        first = record["first"]
        second = record["second"]
        copy = dict(record)
        copy["first"] = dict(first)
        copy["second"] = dict(second)
        copy["sourceUrls"] = {
            "first": _url(first["path"], first["startLine"], first["endLine"]),
            "second": _url(second["path"], second["startLine"], second["endLine"]),
        }
        stamped.append(copy)
    clones[:] = stamped

    aggregates = _record_aggregates(validated_findings, stamped)
    files = _file_rows(evidence, aggregates)
    owners = _subsystem_rows(files)
    rules = _rules_index(evidence, aggregates)
    behavior = sum(row["sloc"]["behavior"] for row in files)
    mixed = sum(row["sloc"]["mixed"] for row in files)
    pure = sum(row["sloc"]["pureData"] for row in files)
    unknown = sum(row["sloc"]["unknown"] for row in files)
    findings_blob = evidence["findings_bytes"]
    clones_text = _encode_jsonl(stamped)
    clones_blob = clones_text.encode("utf-8")
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "methodVersion": METHOD_VERSION,
        "commit": commit,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repository": REPOSITORY,
        "enforcement": "advisory",
        "aggregateVerbosityScore": None,
        "scope": {
            "name": SCOPE_NAME,
            "manifestSha256": evidence["manifest_sha"],
            "files": len(evidence["manifest"]),
            "sloc": {
                "total": behavior + mixed + pure + unknown,
                "behavior": behavior,
                "mixed": mixed,
                "pureData": pure,
                "unknown": unknown,
                "eligible": behavior + mixed,
                "analyzedFiles": len(evidence["manifest"]),
            },
        },
        "rules": rules,
        "clonePairs": {
            "rawPairs": len(stamped),
            "byClass": dict(aggregates["class_counts"]),
            "candidateCoveredLines": len(aggregates["covered"]),
        },
        "files": files,
        "subsystems": owners,
        "omittedFamilies": {
            family: {
                "status": "not_executed",
                "reasonCode": reason,
                "observations": None,
            }
            for family, reason in OMITTED_FAMILIES
        },
        "artifacts": {
            "findings": {
                "path": "findings.jsonl",
                "format": "jsonl",
                "records": len(validated_findings),
                "sha256": hashlib.sha256(findings_blob).hexdigest(),
            },
            "clones": {
                "path": "clones.jsonl",
                "format": "jsonl",
                "records": len(stamped),
                "sha256": hashlib.sha256(clones_blob).hexdigest(),
            },
        },
        "tools": _tool_versions(),
    }
    return summary


def _validate_published(directory, evidence) -> dict:
    """Recompute every aggregate from staged bytes and compare to the index."""
    directory = Path(directory)
    try:
        summary_blob = (directory / "summary.json").read_bytes()
        findings_blob = (directory / "findings.jsonl").read_bytes()
        clones_blob = (directory / "clones.jsonl").read_bytes()
    except OSError as error:
        raise ReportError(f"published files are incomplete: {error}") from error
    try:
        summary = json.loads(summary_blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReportError(f"published index is invalid: {error}") from error
    if not isinstance(summary, dict):
        raise ReportError("published index must be an object")
    if summary.get("schemaVersion") != SCHEMA_VERSION:
        raise ReportError("published index has the wrong schemaVersion")
    if summary.get("methodVersion") != METHOD_VERSION:
        raise ReportError("published index has the wrong methodVersion")
    if summary.get("commit") != evidence["commit"]:
        raise ReportError("published index pins the wrong commit")
    if summary.get("repository") != REPOSITORY:
        raise ReportError("published index names the wrong repository")
    if summary.get("scope", {}).get("manifestSha256") != evidence["manifest_sha"]:
        raise ReportError("published index pins the wrong manifest")
    findings = _parse_jsonl(findings_blob, "findings.jsonl")
    clones = _parse_jsonl(clones_blob, "clones.jsonl")
    artifacts = summary.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ReportError("published index has invalid artifacts")
    for key, blob, parsed in (
        ("findings", findings_blob, findings),
        ("clones", clones_blob, clones),
    ):
        entry = artifacts.get(key)
        if not isinstance(entry, dict):
            raise ReportError(f"published index has an invalid {key} artifact")
        if entry.get("path") != f"{key}.jsonl" or entry.get("format") != "jsonl":
            raise ReportError(f"published index mislabels the {key} artifact")
        if entry.get("records") != len(parsed):
            raise ReportError(f"published {key} record count disagrees")
        if entry.get("sha256") != hashlib.sha256(blob).hexdigest():
            raise ReportError(f"published {key} digest disagrees")
    seen_ids: set[str] = set()
    for record in clones:
        record_id = record.get("id")
        if (
            not isinstance(record_id, str)
            or not re.fullmatch(r"[0-9a-f]{64}", record_id)
            or record_id in seen_ids
        ):
            raise ReportError("published clone rows have invalid identities")
        seen_ids.add(record_id)
        pair_class = record.get("pairClass")
        reason = record.get("reasonCode")
        if CLASS_FOR_REASON.get(reason) != pair_class:
            raise ReportError("published clone row mixes class and reason")
        if record.get("alignment") not in ("equal", "unequal"):
            raise ReportError("published clone row has invalid alignment")
        for side in (record.get("first"), record.get("second")):
            if not isinstance(side, dict):
                raise ReportError("published clone row has an invalid endpoint")
            lines = side.get("eligibleAlignedLines")
            if (
                not isinstance(lines, list)
                or any(not _is_int(number) for number in lines)
                or lines != sorted(lines)
            ):
                raise ReportError("published clone row has invalid aligned lines")
    order = [
        (
            record["first"]["path"],
            record["first"]["startLine"],
            record["second"]["path"],
            record["second"]["startLine"],
            record["id"],
        )
        for record in clones
    ]
    if order != sorted(order):
        raise ReportError("published clone rows are not sorted")
    aggregates = _record_aggregates(findings, clones)
    if _rules_index(evidence, aggregates) != summary.get("rules"):
        raise ReportError("published rule index disagrees with row bytes")
    expected_files = _file_rows(evidence, aggregates)
    if expected_files != summary.get("files"):
        raise ReportError("published file rows disagree with row bytes")
    if _subsystem_rows(expected_files) != summary.get("subsystems"):
        raise ReportError("published owner rows disagree with row bytes")
    clone_pairs = summary.get("clonePairs")
    if (
        not isinstance(clone_pairs, dict)
        or clone_pairs.get("rawPairs") != len(clones)
        or clone_pairs.get("byClass") != aggregates["class_counts"]
        or clone_pairs.get("candidateCoveredLines") != len(aggregates["covered"])
    ):
        raise ReportError("published pair totals disagree with row bytes")
    scope = summary.get("scope")
    behavior = sum(row["sloc"]["behavior"] for row in expected_files)
    mixed = sum(row["sloc"]["mixed"] for row in expected_files)
    pure = sum(row["sloc"]["pureData"] for row in expected_files)
    unknown = sum(row["sloc"]["unknown"] for row in expected_files)
    if (
        not isinstance(scope, dict)
        or scope.get("files") != len(evidence["manifest"])
        or scope.get("sloc")
        != {
            "total": behavior + mixed + pure + unknown,
            "behavior": behavior,
            "mixed": mixed,
            "pureData": pure,
            "unknown": unknown,
            "eligible": behavior + mixed,
            "analyzedFiles": len(evidence["manifest"]),
        }
    ):
        raise ReportError("published scope totals disagree with row bytes")
    return summary


def main(argv=None) -> int:
    """Run the report: validate inputs, classify pairs, publish three files."""
    parser = argparse.ArgumentParser(
        description="Publish advisory clone-pair and observation reports."
    )
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--jscpd-json", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        evidence = _load_source_evidence(
            args.repository_root, args.manifest, args.source_dir
        )
        try:
            detector_blob = Path(args.jscpd_json).read_bytes()
        except OSError as error:
            raise ReportError(
                f"cannot read duplicate report {args.jscpd_json}: {error}"
            ) from error
        try:
            detector = json.loads(detector_blob.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ReportError(f"invalid duplicate report: {error}") from error
        clones = normalize_clones(detector, evidence["masks"])
        summary = build_summary(
            evidence, evidence["findings"], clones, evidence["commit"]
        )
        output = Path(args.output_dir)
        output.mkdir(parents=True, exist_ok=True)
        summary_blob = (_dump(summary) + "\n").encode("utf-8")
        clones_blob = _encode_jsonl(clones).encode("utf-8")
        findings_blob = evidence["findings_bytes"]
        with tempfile.TemporaryDirectory(dir=output) as staging:
            stage = Path(staging)
            (stage / "summary.json").write_bytes(summary_blob)
            (stage / "findings.jsonl").write_bytes(findings_blob)
            (stage / "clones.jsonl").write_bytes(clones_blob)
            _validate_published(stage, evidence)
            os.replace(stage / "summary.json", output / "summary.json")
            os.replace(stage / "findings.jsonl", output / "findings.jsonl")
            os.replace(stage / "clones.jsonl", output / "clones.jsonl")
    except (ReportError, ValueError) as error:
        print(f"clone-pair report: {error}", file=sys.stderr)
        return 1
    print(
        "clone-pair report: wrote "
        f"{output / 'summary.json'}, {output / 'findings.jsonl'}, "
        f"{output / 'clones.jsonl'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
