#!/usr/bin/env python3
"""Behavioral checks for the advisory clone-pair report.

The report reads the scanner's deterministic stage files (per-file source
line classes, syntax observations, rule census) plus the existing raw
duplicate report, classifies every duplicate pair without touching the
detector itself, and publishes three machine-readable files: an index
summary plus full observation and clone streams. These tests pin that
behavior with small synthetic repositories and duplicate payloads shaped
like the real detector output; they fail while the report beside them is
absent.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPORT_PATH = Path(__file__).with_name("codehealth_signals_report.py")

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
ALL_RULE_IDS = tuple(rule for rule, _ in SOURCE_RULES) + (CLONE_RULE,)

CLASS_BY_REASON = {
    "aligned_behavior": "behavior_candidate",
    "both_literal_data": "pure_data",
    "data_behavior_mixture": "mixed",
    "no_proven_alignment": "unknown",
    "unequal_source_span": "unaligned",
}

DEFERRED_FAMILIES = (
    "table_key_redundancy",
    "magic_literals",
    "defensive_density",
    "bool_comparisons",
    "nil_false_fallback",
    "trivial_wrappers",
    "empty_branch",
)

SOURCE_URL_PREFIX = "https://github.com/portemon-nitro/portemon/blob/"
REPOSITORY_NAME = "portemon-nitro/portemon"
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def load_report_module():
    """Load the report beside this test file or fail with a clear reason."""
    if not REPORT_PATH.is_file():
        raise AssertionError(
            "the advisory clone-pair report must exist beside these "
            "behavioral checks before they can pass"
        )
    module_spec = importlib.util.spec_from_file_location(
        "codehealth_signals_report", REPORT_PATH
    )
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("the advisory clone-pair report cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _dump(value) -> str:
    return json.dumps(
        value, sort_keys=True, allow_nan=False, ensure_ascii=False,
        separators=(",", ":"),
    )


def _init_repository(files: dict[str, str]) -> Path:
    directory = Path(tempfile.mkdtemp())
    for relative, content in files.items():
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    subprocess.run(["git", "init", "--quiet"], cwd=directory, check=True)
    subprocess.run(
        ["git", "config", "user.email", "signals-test@example.com"],
        cwd=directory,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Signals Test"], cwd=directory, check=True
    )
    subprocess.run(["git", "add", "."], cwd=directory, check=True)
    subprocess.run(
        ["git", "commit", "--quiet", "-m", "test fixture"], cwd=directory, check=True
    )
    return directory


def _head_sha(repository: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _write_manifest(directory: Path, entries: list[str]) -> Path:
    manifest = Path(directory) / "manifest.txt"
    manifest.write_text(
        "".join(entry + "\n" for entry in sorted(entries)), encoding="utf-8"
    )
    return manifest


def _plain_source(total_lines: int) -> str:
    return "".join(f"local slot{n} = {n}\n" for n in range(1, total_lines + 1))


def _masks(
    total: int,
    *,
    mixed: tuple[int, ...] = (),
    pure: tuple[int, ...] = (),
    unknown: tuple[int, ...] = (),
) -> dict[str, list[int]]:
    claimed = list(mixed) + list(pure) + list(unknown)
    if len(set(claimed)) != len(claimed):
        raise AssertionError("fixture buckets must be disjoint")
    for number in claimed:
        if not 1 <= number <= total:
            raise AssertionError("fixture bucket line out of range")
    behavior = [n for n in range(1, total + 1) if n not in set(claimed)]
    return {
        "behavior": behavior,
        "mixed": sorted(mixed),
        "pureData": sorted(pure),
        "unknown": sorted(unknown),
    }


def _line_span(raw: bytes, line_number: int) -> tuple[int, int]:
    lines = raw.split(b"\n")
    start = sum(len(item) + 1 for item in lines[: line_number - 1])
    end = start + len(lines[line_number - 1])
    return start, end


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


def _make_finding(
    raw: bytes, path: str, commit: str, rule_id: str, line_number: int, details: dict,
) -> dict:
    start, end = _line_span(raw, line_number)
    lines = raw.decode("utf-8").splitlines()
    end_line = line_number
    group = SOURCE_GROUPS.get(rule_id, "typing")
    return {
        "id": _finding_id(rule_id, path, start, end, details),
        "ruleId": rule_id,
        "group": group,
        "path": path,
        "subsystem": _owner_for_path(path),
        "startByte": start,
        "endByte": end,
        "startLine": line_number,
        "endLine": end_line,
        "sourceUrl": f"{SOURCE_URL_PREFIX}{commit}/{path}#L{line_number}",
        "reviewState": "unreviewed",
        "scoreEligible": False,
        "details": details,
    }


def _owner_for_path(path: str) -> str:
    # Mirrors the grouping used by the existing quality report so per-file
    # rows stay comparable.
    parts = path.split("/")
    if parts[0] == "libs" and len(parts) > 1:
        return f"libs/{parts[1]}"
    if parts[0] == "game" and len(parts) > 1 and parts[1] == "hgss":
        return "game/hgss"
    return parts[0]


def _write_stage_files(
    source_dir: Path,
    manifest: Path,
    commit: str,
    files: list[dict],
) -> tuple[list[dict], list[dict]]:
    """Write scanner-shaped stage files for synthetic sources.

    Each entry in ``files`` carries ``path``, ``content``, ``masks`` and a
    list of ``(rule_id, line_number, details)`` observation triples.
    """
    source_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    findings: list[dict] = []
    for entry in files:
        raw = entry["content"].encode("utf-8")
        rows.append(
            {
                "path": entry["path"],
                "sourceSha256": hashlib.sha256(raw).hexdigest(),
                "sloc": entry["masks"],
            }
        )
        for rule_id, line_number, details in entry.get("observations", []):
            findings.append(
                _make_finding(raw, entry["path"], commit, rule_id, line_number, details)
            )
    rows.sort(key=lambda item: item["path"])
    findings.sort(
        key=lambda item: (
            item["path"],
            item["startByte"],
            item["endByte"],
            item["ruleId"],
            item["id"],
        )
    )
    counts = {rule_id: 0 for rule_id, _ in SOURCE_RULES}
    for finding in findings:
        # Unknown families pass through into the stream so the report
        # itself is the owner that rejects them.
        if finding["ruleId"] in counts:
            counts[finding["ruleId"]] += 1
    rules = {
        "schemaVersion": 1,
        "commit": commit,
        "manifestSha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "filesParsed": len(rows),
        "detectors": [
            {
                "id": rule_id,
                "group": group,
                "status": (
                    "executed_with_hits" if counts[rule_id] else "executed_no_match"
                ),
                "observations": counts[rule_id],
            }
            for rule_id, group in SOURCE_RULES
        ],
    }
    (source_dir / "source.jsonl").write_text(
        "".join(_dump(row) + "\n" for row in rows), encoding="utf-8"
    )
    (source_dir / "findings.jsonl").write_text(
        "".join(_dump(finding) + "\n" for finding in findings), encoding="utf-8"
    )
    (source_dir / "rules.json").write_text(_dump(rules), encoding="utf-8")
    return rows, findings


def _duplicate(
    first_path: str,
    first_start: int,
    first_end: int,
    second_path: str,
    second_start: int,
    second_end: int,
    tokens: int,
    lines: int | None = None,
) -> dict:
    def _endpoint(path: str, start: int, end: int) -> dict:
        return {
            "name": path,
            "start": start,
            "end": end,
            "startLoc": {"line": start, "column": 1, "position": 0},
            "endLoc": {"line": end, "column": 1, "position": 0},
        }

    return {
        "firstFile": _endpoint(first_path, first_start, first_end),
        "secondFile": _endpoint(second_path, second_start, second_end),
        "format": "lua",
        "lines": first_end - first_start + 1 if lines is None else lines,
        "tokens": tokens,
        "fragment": "local span = true\n",
    }


def _write_detector_json(
    path: Path,
    pairs: list[dict],
    *,
    clones: int | None = None,
    omit_duplicates: bool = False,
) -> dict:
    payload: dict = {
        "statistics": {
            "total": {
                "clones": len(pairs) if clones is None else clones,
                "sources": 2,
                "duplicatedLines": sum(
                    pair["firstFile"]["end"] - pair["firstFile"]["start"] + 1
                    for pair in pairs
                ),
                "percentage": 1.5,
                "tokens": 1000,
                "lines": 500,
            }
        }
    }
    if not omit_duplicates:
        payload["duplicates"] = pairs
    path.write_text(_dump(payload), encoding="utf-8")
    return payload


def _run_report(
    repository: Path,
    manifest: Path,
    source_dir: Path,
    detector_json: Path,
    output_dir: Path,
) -> subprocess.CompletedProcess[str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    return subprocess.run(
        [
            sys.executable,
            str(REPORT_PATH),
            "--repository-root",
            str(repository),
            "--manifest",
            str(manifest),
            "--source-dir",
            str(source_dir),
            "--jscpd-json",
            str(detector_json),
            "--output-dir",
            str(output_dir),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def _eligible_by_path(rows: list[dict]) -> dict[str, set[int]]:
    eligible: dict[str, set[int]] = {}
    for row in rows:
        eligible[row["path"]] = set(row["sloc"]["behavior"]) | set(
            row["sloc"]["mixed"]
        )
    return eligible


def _union_lines(
    pair_spans: list[tuple[str, int, int, str, int, int]],
    eligible: dict[str, set[int]],
) -> set[tuple[str, int]]:
    """Independent plain-set recomputation of distinct covered lines.

    Only equal-length spans contribute, and an offset counts only when the
    line on both sides is behavior-eligible.
    """
    covered: set[tuple[str, int]] = set()
    for first_path, first_start, first_end, second_path, second_start, second_end in (
        pair_spans
    ):
        if (first_end - first_start) != (second_end - second_start):
            continue
        for offset in range(first_end - first_start + 1):
            first_line = first_start + offset
            second_line = second_start + offset
            if (
                first_line in eligible.get(first_path, set())
                and second_line in eligible.get(second_path, set())
            ):
                covered.add((first_path, first_line))
                covered.add((second_path, second_line))
    return covered


def _clone_by_spans(
    clones: list[dict],
    first: tuple[str, int, int],
    second: tuple[str, int, int],
) -> dict:
    for record in clones:
        got_first = (
            record["first"]["path"],
            record["first"]["startLine"],
            record["first"]["endLine"],
        )
        got_second = (
            record["second"]["path"],
            record["second"]["startLine"],
            record["second"]["endLine"],
        )
        if (got_first, got_second) == (first, second) or (
            got_first,
            got_second,
        ) == (second, first):
            return record
    raise AssertionError(f"no published pair for {first} vs {second}")


class ReportModuleTest(unittest.TestCase):
    """The report exposes its documented private entry points."""

    def test_report_module_loads_beside_these_checks(self) -> None:
        module = load_report_module()
        for name in ("normalize_clones", "build_summary", "main"):
            self.assertTrue(
                callable(getattr(module, name, None)),
                f"report must expose callable {name}",
            )

    def test_tool_provenance_stays_honest_and_bounded(self) -> None:
        module = load_report_module()
        self.assertEqual(
            module._python_tool_version("no_such_module_zzz", "no-such-dist-zzz"),
            "unknown",
        )
        self.assertEqual(
            module._python_tool_version("hashlib", "no-such-dist-zzz"),
            "unknown",
        )
        versions = module._tool_versions()
        self.assertEqual(set(versions), {"treeSitter", "treeSitterLua", "jscpd"})
        for value in versions.values():
            self.assertIsInstance(value, str)
            self.assertLessEqual(len(value), 64)


class SameFileBothSidesTest(unittest.TestCase):
    """Both endpoints of a same-file pair count, with overlaps deduped."""

    FILE = "game/src/store.lua"
    TOTAL = 40
    PAIRS = (
        (10, 12, 30, 32, 60),
        (11, 13, 31, 33, 55),
        (10, 12, 12, 14, 50),
    )

    def _world(self, work: Path):
        content = _plain_source(self.TOTAL)
        repository = _init_repository({self.FILE: content})
        manifest = _write_manifest(work, [self.FILE])
        commit = _head_sha(repository)
        rows, _ = _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.FILE,
                    "content": content,
                    "masks": _masks(self.TOTAL),
                    "observations": [],
                }
            ],
        )
        pairs = [
            _duplicate(self.FILE, fs, fe, self.FILE, ss, se, tokens)
            for fs, fe, ss, se, tokens in self.PAIRS
        ]
        detector = work / "detector.json"
        _write_detector_json(detector, pairs)
        return repository, manifest, work / "stage", detector, rows

    def test_disjoint_pair_counts_both_sides_once_each(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            record = _clone_by_spans(
                clones, (self.FILE, 10, 12), (self.FILE, 30, 32)
            )
            self.assertEqual(record["first"]["eligibleAlignedLines"], [10, 11, 12])
            self.assertEqual(record["second"]["eligibleAlignedLines"], [30, 31, 32])
            self.assertTrue(record["sameFile"])
            self.assertFalse(record["overlap"])
            self.assertEqual(record["pairClass"], "behavior_candidate")
            self.assertEqual(record["reasonCode"], "aligned_behavior")
            self.assertEqual(record["alignment"], "equal")
            self.assertFalse(record["scoreEligible"])

    def test_overlapping_pairs_share_physical_lines_only_once(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, rows = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            summary = json.loads((work_path / "out" / "summary.json").read_text())
            spans = [
                (self.FILE, fs, fe, self.FILE, ss, se)
                for fs, fe, ss, se, _ in self.PAIRS
            ]
            expected = _union_lines(spans, _eligible_by_path(rows))
            # First disjoint pair: 6 distinct keys; the two further pairs add
            # only lines 13, 33 and 14, so the union holds 9 distinct lines.
            self.assertEqual(len(expected), 9)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], 9)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], len(expected))
            # The partly overlapping pair intersects itself and is flagged.
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            overlapping = _clone_by_spans(
                clones, (self.FILE, 10, 12), (self.FILE, 12, 14)
            )
            self.assertTrue(overlapping["sameFile"])
            self.assertTrue(overlapping["overlap"])
            self.assertEqual(overlapping["first"]["eligibleAlignedLines"], [10, 11, 12])
            self.assertEqual(overlapping["second"]["eligibleAlignedLines"], [12, 13, 14])

    def test_normalization_lists_each_side_separately(self) -> None:
        module = load_report_module()
        masks = {self.FILE: _masks(self.TOTAL)}
        payload = {
            "duplicates": [
                _duplicate(self.FILE, fs, fe, self.FILE, ss, se, tokens)
                for fs, fe, ss, se, tokens in self.PAIRS
            ],
            "statistics": {"total": {"clones": 3}},
        }
        clones = module.normalize_clones(payload, masks)
        self.assertEqual(len(clones), 3)
        record = _clone_by_spans(clones, (self.FILE, 10, 12), (self.FILE, 30, 32))
        self.assertEqual(record["first"]["eligibleAlignedLines"], [10, 11, 12])
        self.assertEqual(record["second"]["eligibleAlignedLines"], [30, 31, 32])

    def test_swapped_endpoints_publish_identical_rows(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            swapped = work_path / "swapped.json"
            _write_detector_json(
                swapped,
                [
                    _duplicate(self.FILE, ss, se, self.FILE, fs, fe, tokens)
                    for fs, fe, ss, se, tokens in self.PAIRS
                ],
            )
            first = _run_report(repository, manifest, stage, detector, work_path / "one")
            second = _run_report(repository, manifest, stage, swapped, work_path / "two")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(
                (work_path / "one" / "clones.jsonl").read_bytes(),
                (work_path / "two" / "clones.jsonl").read_bytes(),
            )

    def test_single_disjoint_pair_covers_twice_its_width(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            content = _plain_source(30)
            repository = _init_repository({self.FILE: content})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, [self.FILE])
            commit = _head_sha(repository)
            rows, _ = _write_stage_files(
                work_path / "stage",
                manifest,
                commit,
                [
                    {
                        "path": self.FILE,
                        "content": content,
                        "masks": _masks(30),
                        "observations": [],
                    }
                ],
            )
            detector = work_path / "detector.json"
            _write_detector_json(
                detector, [_duplicate(self.FILE, 5, 7, self.FILE, 20, 22, 40)]
            )
            result = _run_report(
                repository, manifest, work_path / "stage", detector, work_path / "out"
            )
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            summary = json.loads((work_path / "out" / "summary.json").read_text())
            expected = _union_lines(
                [(self.FILE, 5, 7, self.FILE, 20, 22)], _eligible_by_path(rows)
            )
            # One side spans 3 lines; both disjoint sides give 2 x 3 lines.
            self.assertEqual(len(expected), 6)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], 6)


class PairClassExclusionTest(unittest.TestCase):
    """Data-only, mixed, unknown and unequal spans never add candidate lines."""

    ALPHA = "game/src/alpha.lua"
    BETA = "game/src/beta.lua"

    def _world(self, work: Path):
        alpha = _plain_source(30)
        beta = _plain_source(20)
        repository = _init_repository({self.ALPHA: alpha, self.BETA: beta})
        manifest = _write_manifest(work, [self.ALPHA, self.BETA])
        commit = _head_sha(repository)
        rows, _ = _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.ALPHA,
                    "content": alpha,
                    "masks": _masks(30, pure=tuple(range(21, 31))),
                    "observations": [],
                },
                {
                    "path": self.BETA,
                    "content": beta,
                    "masks": _masks(20, unknown=tuple(range(11, 21))),
                    "observations": [],
                },
            ],
        )
        pairs = [
            # Two-sided behavior.
            _duplicate(self.ALPHA, 1, 3, self.BETA, 1, 3, 60),
            # Both whole spans are literal data.
            _duplicate(self.ALPHA, 21, 23, self.ALPHA, 24, 26, 55),
            # One side behavior, the other literal data.
            _duplicate(self.ALPHA, 4, 6, self.ALPHA, 21, 23, 50),
            # Both whole spans unclassified.
            _duplicate(self.BETA, 11, 13, self.BETA, 14, 16, 45),
            # Behavior on both sides but spans cannot be paired.
            _duplicate(self.ALPHA, 7, 9, self.BETA, 4, 7, 40),
        ]
        detector = work / "detector.json"
        _write_detector_json(detector, pairs)
        return repository, manifest, work / "stage", detector, rows

    def test_every_raw_pair_is_published_with_its_class(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            self.assertEqual(len(clones), 5)
            by_class = {
                "behavior_candidate": ((self.ALPHA, 1, 3), (self.BETA, 1, 3)),
                "pure_data": ((self.ALPHA, 21, 23), (self.ALPHA, 24, 26)),
                "mixed": ((self.ALPHA, 4, 6), (self.ALPHA, 21, 23)),
                "unknown": ((self.BETA, 11, 13), (self.BETA, 14, 16)),
                "unaligned": ((self.ALPHA, 7, 9), (self.BETA, 4, 7)),
            }
            seen: dict[str, int] = {}
            for record in clones:
                seen[record["pairClass"]] = seen.get(record["pairClass"], 0) + 1
                self.assertEqual(
                    CLASS_BY_REASON[record["reasonCode"]], record["pairClass"]
                )
                self.assertFalse(record["scoreEligible"])
            self.assertEqual(
                seen,
                {
                    "behavior_candidate": 1,
                    "pure_data": 1,
                    "mixed": 1,
                    "unknown": 1,
                    "unaligned": 1,
                },
            )
            for expected_class, (first, second) in by_class.items():
                record = _clone_by_spans(clones, first, second)
                self.assertEqual(record["pairClass"], expected_class)
            summary = json.loads((work_path / "out" / "summary.json").read_text())
            self.assertEqual(summary["clonePairs"]["rawPairs"], 5)
            self.assertEqual(
                summary["clonePairs"]["byClass"],
                {
                    "behavior_candidate": 1,
                    "pure_data": 1,
                    "mixed": 1,
                    "unknown": 1,
                    "unaligned": 1,
                },
            )

    def test_only_two_sided_behavior_enters_covered_lines(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, rows = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            summary = json.loads((work_path / "out" / "summary.json").read_text())
            spans = [
                (self.ALPHA, 1, 3, self.BETA, 1, 3),
                (self.ALPHA, 21, 23, self.ALPHA, 24, 26),
                (self.ALPHA, 4, 6, self.ALPHA, 21, 23),
                (self.BETA, 11, 13, self.BETA, 14, 16),
                (self.ALPHA, 7, 9, self.BETA, 4, 7),
            ]
            expected = _union_lines(spans, _eligible_by_path(rows))
            self.assertEqual(len(expected), 6)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], 6)
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            unaligned = _clone_by_spans(
                clones, (self.ALPHA, 7, 9), (self.BETA, 4, 7)
            )
            self.assertEqual(unaligned["alignment"], "unequal")
            self.assertEqual(unaligned["reasonCode"], "unequal_source_span")
            self.assertEqual(unaligned["first"]["eligibleAlignedLines"], [])
            self.assertEqual(unaligned["second"]["eligibleAlignedLines"], [])

    def test_data_only_pair_keeps_both_endpoints(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(result.returncode, 0, result.stderr)
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            record = _clone_by_spans(
                clones, (self.ALPHA, 21, 23), (self.ALPHA, 24, 26)
            )
            self.assertEqual(record["pairClass"], "pure_data")
            self.assertEqual(record["reasonCode"], "both_literal_data")
            self.assertTrue(record["sameFile"])
            self.assertFalse(record["overlap"])
            self.assertEqual(record["first"]["eligibleAlignedLines"], [])
            self.assertEqual(record["second"]["eligibleAlignedLines"], [])


class MachineIndexTest(unittest.TestCase):
    """The published index reconciles rules, files, owners and clones."""

    ALPHA = "game/src/alpha.lua"
    BETA = "libs/items/beta.lua"
    GAMMA = "app/src/caf\u00e9.lua"

    OBSERVATIONS = (
        ("pn-explicit-nil-init", 2, {"syntaxKind": "local_explicit_nil"}),
        (
            "lua-cast-directive",
            5,
            {"annotationKind": "cast_directive", "target": "value", "type": "Foo"},
        ),
        (
            "lua-unknown-valued-table",
            8,
            {
                "annotationKind": "field",
                "genericKeyType": "string",
                "genericValueType": "unknown",
                "declarationContext": "field",
                "visibility": "public_declared",
            },
        ),
        (
            "lua-inline-as-cast",
            2,
            {"annotationKind": "inline_as", "type": "Qux"},
        ),
        (
            "lua-unknown-keyed-table",
            4,
            {
                "annotationKind": "parameter",
                "genericKeyType": "unknown",
                "genericValueType": "number",
                "declarationContext": "parameter",
                "visibility": "public_declared",
            },
        ),
        (
            "lua-string-dispatch",
            7,
            {"variable": "kind", "comparisons": 4, "functionStartLine": 1},
        ),
    )

    def _world(self, work: Path):
        alpha = _plain_source(24)
        beta = _plain_source(12)
        gamma = _plain_source(4)
        repository = _init_repository(
            {self.ALPHA: alpha, self.BETA: beta, self.GAMMA: gamma}
        )
        manifest = _write_manifest(work, [self.ALPHA, self.BETA, self.GAMMA])
        commit = _head_sha(repository)
        rows, findings = _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.ALPHA,
                    "content": alpha,
                    "masks": _masks(
                        24, mixed=(17, 18), pure=(19, 20, 21, 22), unknown=(23, 24)
                    ),
                    "observations": [
                        (rule, line, details)
                        for rule, line, details in self.OBSERVATIONS[:3]
                    ],
                },
                {
                    "path": self.BETA,
                    "content": beta,
                    "masks": _masks(12),
                    "observations": [
                        (rule, line, details)
                        for rule, line, details in self.OBSERVATIONS[3:]
                    ],
                },
                {
                    "path": self.GAMMA,
                    "content": gamma,
                    "masks": _masks(4),
                    "observations": [],
                },
            ],
        )
        pairs = [
            _duplicate(self.ALPHA, 10, 12, self.BETA, 5, 7, 60),
            _duplicate(self.BETA, 1, 3, self.BETA, 9, 11, 50),
        ]
        detector = work / "detector.json"
        _write_detector_json(detector, pairs)
        return repository, manifest, work / "stage", detector, rows, findings, commit

    def test_three_artifacts_parse_and_reconcile(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, rows, findings, _ = self._world(
                work_path
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            out = work_path / "out"
            summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
            published_findings = _read_jsonl(out / "findings.jsonl")
            clones = _read_jsonl(out / "clones.jsonl")
            self.assertEqual(summary["schemaVersion"], 1)
            self.assertEqual(summary["methodVersion"], 2)
            self.assertEqual(summary["repository"], REPOSITORY_NAME)
            # Artifact digests and counts are recomputed from published bytes.
            for key, name in (("findings", "findings.jsonl"), ("clones", "clones.jsonl")):
                artifact = summary["artifacts"][key]
                self.assertEqual(artifact["path"], name)
                self.assertEqual(artifact["format"], "jsonl")
                blob = (out / name).read_bytes()
                self.assertEqual(artifact["records"], len(_read_jsonl(out / name)))
                self.assertEqual(artifact["sha256"], hashlib.sha256(blob).hexdigest())
            self.assertEqual(
                summary["artifacts"]["findings"]["records"], len(findings)
            )
            self.assertEqual(summary["artifacts"]["clones"]["records"], 2)
            # The observation stream is carried over byte for byte.
            self.assertEqual(
                (out / "findings.jsonl").read_bytes(),
                (stage / "findings.jsonl").read_bytes(),
            )
            self.assertEqual(len(published_findings), len(findings))
            # All seven families and all manifest files are represented.
            self.assertEqual(set(summary["rules"].keys()), set(ALL_RULE_IDS))
            self.assertEqual(
                [row["path"] for row in summary["files"]],
                sorted([self.ALPHA, self.BETA, self.GAMMA]),
            )
            for row in summary["files"]:
                self.assertEqual(set(row["byRule"].keys()), set(ALL_RULE_IDS))
            for owner in summary["subsystems"]:
                self.assertEqual(set(owner["byRule"].keys()), set(ALL_RULE_IDS))
            self.assertEqual(summary["clonePairs"]["rawPairs"], 2)
            self.assertEqual(sum(summary["clonePairs"]["byClass"].values()), 2)
            expected = _union_lines(
                [
                    (self.ALPHA, 10, 12, self.BETA, 5, 7),
                    (self.BETA, 1, 3, self.BETA, 9, 11),
                ],
                _eligible_by_path(rows),
            )
            self.assertEqual(len(expected), 12)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], 12)
            # Clone rows are sorted and carry stable identities.
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
            self.assertEqual(order, sorted(order))
            for record in clones:
                self.assertRegex(record["id"], r"^[0-9a-f]{64}$")
                self.assertEqual(record["schemaVersion"], 1)
                self.assertEqual(record["source"], "jscpd")
                self.assertIn(record["alignment"], ("equal", "unequal"))
            self.assertEqual(len({record["id"] for record in clones}), 2)

    def test_file_and_owner_rows_match_fresh_jsonl_iteration(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, rows, _, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(result.returncode, 0, result.stderr)
            out = work_path / "out"
            summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
            # Recompute every aggregate from the published bytes with
            # independent loops, never reusing the summary's own totals.
            source_rows = _read_jsonl(out / "findings.jsonl")
            clone_rows = _read_jsonl(out / "clones.jsonl")
            stage_rows = _read_jsonl(stage / "source.jsonl")
            masks = {row["path"]: row["sloc"] for row in stage_rows}
            finding_counts: dict[str, dict[str, int]] = {}
            for finding in source_rows:
                bucket = finding_counts.setdefault(finding["path"], {})
                bucket[finding["ruleId"]] = bucket.get(finding["ruleId"], 0) + 1
            touched: dict[str, int] = {}
            covered: dict[str, set[int]] = {}
            for record in clone_rows:
                if record["pairClass"] != "behavior_candidate":
                    continue
                for path in {record["first"]["path"], record["second"]["path"]}:
                    touched[path] = touched.get(path, 0) + 1
                for side in (record["first"], record["second"]):
                    for line in side["eligibleAlignedLines"]:
                        covered.setdefault(side["path"], set()).add(line)
            for row in summary["files"]:
                path = row["path"]
                sloc = masks[path]
                behavior = len(sloc["behavior"])
                mixed = len(sloc["mixed"])
                self.assertEqual(
                    row["sloc"],
                    {
                        "behavior": behavior,
                        "mixed": mixed,
                        "pureData": len(sloc["pureData"]),
                        "unknown": len(sloc["unknown"]),
                        "eligible": behavior + mixed,
                        "total": behavior + mixed + len(sloc["pureData"]) + len(
                            sloc["unknown"]
                        ),
                    },
                )
                for rule_id in ALL_RULE_IDS:
                    if rule_id == CLONE_RULE:
                        self.assertEqual(row["byRule"][rule_id], touched.get(path, 0))
                    else:
                        self.assertEqual(
                            row["byRule"][rule_id],
                            finding_counts.get(path, {}).get(rule_id, 0),
                        )
                self.assertEqual(
                    row["cloneCandidateCoveredLines"], len(covered.get(path, set()))
                )
            # One pair may increment two file rows while the global pair
            # count stays one.
            by_path = {row["path"]: row for row in summary["files"]}
            self.assertEqual(by_path[self.BETA]["byRule"][CLONE_RULE], 2)
            self.assertEqual(by_path[self.ALPHA]["byRule"][CLONE_RULE], 1)
            self.assertEqual(summary["rules"][CLONE_RULE]["observations"], 2)
            owners: dict[str, list[str]] = {}
            for row in summary["files"]:
                owners.setdefault(row["subsystem"], []).append(row["path"])
            self.assertEqual(
                {owner["name"] for owner in summary["subsystems"]}, set(owners)
            )
            for owner in summary["subsystems"]:
                members = owners[owner["name"]]
                self.assertEqual(owner["files"], len(members))
                for key in ("behavior", "mixed", "pureData", "unknown", "eligible", "total"):
                    self.assertEqual(
                        owner["sloc"][key],
                        sum(by_path[path]["sloc"][key] for path in members),
                    )
                for rule_id in ALL_RULE_IDS:
                    self.assertEqual(
                        owner["byRule"][rule_id],
                        sum(by_path[path]["byRule"][rule_id] for path in members),
                    )
                self.assertEqual(
                    owner["cloneCandidateCoveredLines"],
                    sum(
                        by_path[path]["cloneCandidateCoveredLines"] for path in members
                    ),
                )
            total_covered = _union_lines(
                [
                    (self.ALPHA, 10, 12, self.BETA, 5, 7),
                    (self.BETA, 1, 3, self.BETA, 9, 11),
                ],
                _eligible_by_path(rows),
            )
            self.assertEqual(
                summary["clonePairs"]["candidateCoveredLines"], len(total_covered)
            )

    def test_links_pin_commit_and_hide_local_paths(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _, _, commit = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(result.returncode, 0, result.stderr)
            out = work_path / "out"
            for finding in _read_jsonl(out / "findings.jsonl"):
                self.assertTrue(
                    finding["sourceUrl"].startswith(f"{SOURCE_URL_PREFIX}{commit}/"),
                    finding["sourceUrl"],
                )
            for record in _read_jsonl(out / "clones.jsonl"):
                for key in ("first", "second"):
                    self.assertTrue(
                        record["sourceUrls"][key].startswith(
                            f"{SOURCE_URL_PREFIX}{commit}/"
                        ),
                        record["sourceUrls"][key],
                    )
            blob = (
                (out / "summary.json").read_bytes()
                + (out / "findings.jsonl").read_bytes()
                + (out / "clones.jsonl").read_bytes()
            ).decode("utf-8")
            self.assertNotIn(str(work_path), blob)
            self.assertNotIn(str(repository), blob)

    def test_single_dot_slash_prefix_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            content = _plain_source(10)
            repository = _init_repository({self.ALPHA: content})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, [self.ALPHA])
            commit = _head_sha(repository)
            _write_stage_files(
                work_path / "stage",
                manifest,
                commit,
                [
                    {
                        "path": self.ALPHA,
                        "content": content,
                        "masks": _masks(10),
                        "observations": [],
                    }
                ],
            )
            detector = work_path / "detector.json"
            _write_detector_json(
                detector,
                [_duplicate(f"./{self.ALPHA}", 1, 3, self.ALPHA, 5, 7, 40)],
            )
            result = _run_report(
                repository, manifest, work_path / "stage", detector, work_path / "out"
            )
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            clones = _read_jsonl(work_path / "out" / "clones.jsonl")
            self.assertEqual(len(clones), 1)
            self.assertEqual(clones[0]["first"]["path"], self.ALPHA)
            self.assertEqual(clones[0]["second"]["path"], self.ALPHA)


class EmptyRunTest(unittest.TestCase):
    """A matchless run publishes valid empty streams with stable bytes."""

    FILE = "game/src/plain.lua"

    def _world(self, work: Path):
        content = _plain_source(3)
        repository = _init_repository({self.FILE: content})
        manifest = _write_manifest(work, [self.FILE])
        commit = _head_sha(repository)
        _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.FILE,
                    "content": content,
                    "masks": _masks(3),
                    "observations": [],
                }
            ],
        )
        detector = work / "detector.json"
        _write_detector_json(detector, [], clones=0, omit_duplicates=True)
        return repository, manifest, work / "stage", detector, commit

    def test_empty_streams_validate_with_zero_counts(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            out = work_path / "out"
            self.assertTrue((out / "findings.jsonl").is_file())
            self.assertTrue((out / "clones.jsonl").is_file())
            self.assertEqual((out / "findings.jsonl").read_text(encoding="utf-8"), "")
            self.assertEqual((out / "clones.jsonl").read_text(encoding="utf-8"), "")
            summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
            for rule_id in ALL_RULE_IDS:
                entry = summary["rules"][rule_id]
                self.assertEqual(entry["status"], "executed_no_match")
                self.assertEqual(entry["observations"], 0)
                self.assertEqual(entry["affectedFiles"], [])
            for key in ("findings", "clones"):
                self.assertEqual(summary["artifacts"][key]["records"], 0)
                self.assertEqual(summary["artifacts"][key]["sha256"], EMPTY_SHA256)
            self.assertEqual(
                set(summary["omittedFamilies"].keys()), set(DEFERRED_FAMILIES)
            )
            for family in DEFERRED_FAMILIES:
                entry = summary["omittedFamilies"][family]
                self.assertEqual(entry["status"], "not_executed")
                self.assertIsNone(entry["observations"])
                self.assertTrue(entry["reasonCode"])
            self.assertEqual(
                summary["scope"]["sloc"],
                {
                    "total": 3,
                    "behavior": 3,
                    "mixed": 0,
                    "pureData": 0,
                    "unknown": 0,
                    "eligible": 3,
                    "analyzedFiles": 1,
                },
            )
            self.assertEqual(summary["clonePairs"]["rawPairs"], 0)
            self.assertEqual(summary["clonePairs"]["candidateCoveredLines"], 0)

    def test_two_runs_agree_except_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            first = _run_report(repository, manifest, stage, detector, work_path / "one")
            second = _run_report(repository, manifest, stage, detector, work_path / "two")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            for name in ("findings.jsonl", "clones.jsonl"):
                self.assertEqual(
                    (work_path / "one" / name).read_bytes(),
                    (work_path / "two" / name).read_bytes(),
                    f"{name} must be byte-identical between runs",
                )
            one = json.loads((work_path / "one" / "summary.json").read_text())
            two = json.loads((work_path / "two" / "summary.json").read_text())
            self.assertRegex(one["generatedAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
            one.pop("generatedAt")
            two.pop("generatedAt")
            self.assertEqual(one, two)


class AdvisoryMetadataTest(unittest.TestCase):
    """Candidates stay unreviewed, unscored and advisory throughout."""

    FILE = "game/src/mixed.lua"

    def _world(self, work: Path):
        content = _plain_source(16)
        repository = _init_repository({self.FILE: content})
        manifest = _write_manifest(work, [self.FILE])
        commit = _head_sha(repository)
        observations = [
            ("pn-explicit-nil-init", 1, {"syntaxKind": "local_explicit_nil"}),
            (
                "lua-inline-as-cast",
                3,
                {"annotationKind": "inline_as", "type": "Qux"},
            ),
            (
                "lua-unknown-valued-table",
                5,
                {
                    "annotationKind": "field",
                    "genericKeyType": "string",
                    "genericValueType": "unknown",
                    "declarationContext": "field",
                    "visibility": "public_declared",
                },
            ),
            (
                "lua-string-dispatch",
                8,
                {"variable": "kind", "comparisons": 4, "functionStartLine": 1},
            ),
        ]
        _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.FILE,
                    "content": content,
                    "masks": _masks(16),
                    "observations": observations,
                }
            ],
        )
        detector = work / "detector.json"
        _write_detector_json(
            detector, [_duplicate(self.FILE, 10, 12, self.FILE, 13, 15, 60)]
        )
        return repository, manifest, work / "stage", detector

    def test_nothing_is_scored_or_marked_reviewed(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(
                result.returncode, 0, f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
            out = work_path / "out"
            for finding in _read_jsonl(out / "findings.jsonl"):
                self.assertEqual(finding["reviewState"], "unreviewed")
                self.assertFalse(finding["scoreEligible"])
            for record in _read_jsonl(out / "clones.jsonl"):
                self.assertFalse(record["scoreEligible"])
            summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
            self.assertIsNone(summary["aggregateVerbosityScore"])
            self.assertEqual(summary["enforcement"], "advisory")

    def test_deferred_families_stay_out_of_active_rules(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            result = _run_report(repository, manifest, stage, detector, work_path / "out")
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(
                (work_path / "out" / "summary.json").read_text(encoding="utf-8")
            )
            self.assertEqual(set(summary["rules"].keys()), set(ALL_RULE_IDS))
            self.assertEqual(
                set(summary["omittedFamilies"].keys()), set(DEFERRED_FAMILIES)
            )
            for family in DEFERRED_FAMILIES:
                self.assertEqual(summary["omittedFamilies"][family]["status"], "not_executed")
                self.assertIsNone(summary["omittedFamilies"][family]["observations"])


class InputRejectionTest(unittest.TestCase):
    """Malformed inputs abort without publishing a coherent index."""

    FILE = "game/src/alpha.lua"
    OTHER = "game/src/beta.lua"

    def _world(self, work: Path, *, pairs=None, observations=None):
        alpha = _plain_source(10)
        beta = _plain_source(10)
        repository = _init_repository({self.FILE: alpha, self.OTHER: beta})
        manifest = _write_manifest(work, [self.FILE, self.OTHER])
        commit = _head_sha(repository)
        _write_stage_files(
            work / "stage",
            manifest,
            commit,
            [
                {
                    "path": self.FILE,
                    "content": alpha,
                    "masks": _masks(10),
                    "observations": observations or [],
                },
                {
                    "path": self.OTHER,
                    "content": beta,
                    "masks": _masks(10),
                    "observations": [],
                },
            ],
        )
        detector = work / "detector.json"
        if pairs is None:
            pairs = [_duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)]
        _write_detector_json(detector, pairs)
        return repository, manifest, work / "stage", detector

    def _rejects(self, repository, manifest, stage, detector, work: Path) -> None:
        out = work / "out"
        result = _run_report(repository, manifest, stage, detector, out)
        self.assertNotEqual(result.returncode, 0, f"stderr={result.stderr!r}")
        self.assertFalse(
            (out / "summary.json").is_file(),
            "a failing run must not leave a coherent-looking index",
        )

    def test_rejects_duplicate_raw_pairs(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            pair = _duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)
            repository, manifest, stage, detector = self._world(
                work_path, pairs=[pair, dict(pair)]
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_detector_paths_outside_the_manifest(self) -> None:
        bad_names = [
            "../evil.lua",
            "/absolute/evil.lua",
            "C:/evil.lua",
            "game\\src\\evil.lua",
            "game/src/unlisted.lua",
        ]
        for bad in bad_names:
            with self.subTest(name=bad):
                with tempfile.TemporaryDirectory() as work:
                    work_path = Path(work)
                    repository, manifest, stage, detector = self._world(
                        work_path,
                        pairs=[_duplicate(bad, 1, 3, self.FILE, 1, 3, 40)],
                    )
                    self.addCleanup(
                        lambda: subprocess.run(
                            ["rm", "-rf", str(repository)], check=False
                        )
                    )
                    self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_impossible_ranges(self) -> None:
        cases = [
            ("zero start", _duplicate(self.FILE, 0, 3, self.OTHER, 1, 3, 40)),
            ("negative start", _duplicate(self.FILE, -2, 3, self.OTHER, 1, 3, 40)),
            ("end past file", _duplicate(self.FILE, 1, 400, self.OTHER, 1, 3, 40)),
            ("start past end", _duplicate(self.FILE, 5, 3, self.OTHER, 1, 3, 40)),
            (
                "negative tokens",
                _duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, -1),
            ),
        ]
        for label, pair in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as work:
                    work_path = Path(work)
                    repository, manifest, stage, detector = self._world(
                        work_path, pairs=[pair]
                    )
                    self.addCleanup(
                        lambda: subprocess.run(
                            ["rm", "-rf", str(repository)], check=False
                        )
                    )
                    self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_clone_count_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            # Empty list with a nonzero aggregate.
            empty = work_path / "empty.json"
            _write_detector_json(empty, [], clones=3)
            self._rejects(repository, manifest, stage, empty, work_path)
            # Missing member with a nonzero aggregate.
            missing = work_path / "missing.json"
            _write_detector_json(
                missing,
                [_duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)],
                clones=1,
                omit_duplicates=True,
            )
            self._rejects(repository, manifest, stage, missing, work_path)

    def test_rejects_stale_source_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            detector = work_path / "detector.json"
            _write_detector_json(
                detector, [_duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)]
            )
            # Tampered file digest.
            rows = _read_jsonl(stage / "source.jsonl")
            rows[0]["sourceSha256"] = "0" * 64
            (stage / "source.jsonl").write_text(
                "".join(_dump(row) + "\n" for row in rows), encoding="utf-8"
            )
            self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_source_changed_after_stage(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, _ = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            detector = work_path / "detector.json"
            _write_detector_json(
                detector, [_duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)]
            )
            target = repository / self.FILE
            with target.open("a", encoding="utf-8") as handle:
                handle.write("local late = 1\n")
            self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_manifest_digest_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            rules = json.loads((stage / "rules.json").read_text(encoding="utf-8"))
            rules["manifestSha256"] = "0" * 64
            (stage / "rules.json").write_text(_dump(rules), encoding="utf-8")
            self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_manifest_and_stage_coverage_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            content = _plain_source(10)
            repository = _init_repository(
                {self.FILE: content, self.OTHER: content, "game/src/extra.lua": content}
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, [self.FILE, self.OTHER])
            commit = _head_sha(repository)
            # Stage row missing for a manifest path.
            _write_stage_files(
                work_path / "stage",
                manifest,
                commit,
                [
                    {
                        "path": self.FILE,
                        "content": content,
                        "masks": _masks(10),
                        "observations": [],
                    },
                    {
                        "path": self.OTHER,
                        "content": content,
                        "masks": _masks(10),
                        "observations": [],
                    },
                ],
            )
            detector = work_path / "detector.json"
            _write_detector_json(
                detector, [_duplicate(self.FILE, 1, 3, self.OTHER, 1, 3, 40)]
            )
            narrow_manifest = _write_manifest(work_path, [self.FILE])
            self._rejects(
                repository, narrow_manifest, work_path / "stage", detector, work_path
            )

    def test_rejects_malformed_source_masks(self) -> None:
        cases = [
            (
                "line in two buckets",
                {"behavior": [1, 2, 3, 5, 6, 7, 8, 9, 10], "mixed": [4],
                 "pureData": [4], "unknown": []},
            ),
            ("line zero", {"behavior": [0, 1], "mixed": [], "pureData": [], "unknown": []}),
            (
                "line past end",
                {"behavior": list(range(1, 11)) + [11], "mixed": [],
                 "pureData": [], "unknown": []},
            ),
        ]
        for label, masks in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as work:
                    work_path = Path(work)
                    content = _plain_source(10)
                    repository = _init_repository({self.FILE: content})
                    self.addCleanup(
                        lambda: subprocess.run(
                            ["rm", "-rf", str(repository)], check=False
                        )
                    )
                    manifest = _write_manifest(work_path, [self.FILE])
                    commit = _head_sha(repository)
                    _write_stage_files(
                        work_path / "stage",
                        manifest,
                        commit,
                        [
                            {
                                "path": self.FILE,
                                "content": content,
                                "masks": masks,
                                "observations": [],
                            }
                        ],
                    )
                    detector = work_path / "detector.json"
                    _write_detector_json(
                        detector, [_duplicate(self.FILE, 1, 3, self.FILE, 4, 6, 40)]
                    )
                    self._rejects(
                        repository, manifest, work_path / "stage", detector, work_path
                    )

    def test_rejects_unknown_observation_family(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(
                work_path,
                observations=[
                    ("lua-not-a-family", 2, {"note": "stray"}),
                ],
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            self._rejects(repository, manifest, stage, detector, work_path)

    def test_rejects_bad_row_bytes_and_duplicate_ids(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(
                work_path,
                observations=[
                    ("pn-explicit-nil-init", 2, {"syntaxKind": "local_explicit_nil"}),
                ],
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            variants: list[str] = ["garbage findings", "garbage source", "duplicated finding"]
            for label in variants:
                with self.subTest(label=label):
                    if label == "garbage findings":
                        with (stage / "findings.jsonl").open("a", encoding="utf-8") as handle:
                            handle.write("not json\n")
                    elif label == "garbage source":
                        with (stage / "source.jsonl").open("a", encoding="utf-8") as handle:
                            handle.write("{oops\n")
                    else:
                        with (stage / "findings.jsonl").open("a", encoding="utf-8") as handle:
                            handle.write(
                                (stage / "findings.jsonl").read_text(encoding="utf-8")
                            )
                    self._rejects(repository, manifest, stage, detector, work_path)
                    # Restore valid bytes for the next variant.
                    repository_commit = _head_sha(repository)
                    alpha = (repository / self.FILE).read_text(encoding="utf-8")
                    beta = (repository / self.OTHER).read_text(encoding="utf-8")
                    _write_stage_files(
                        stage,
                        manifest,
                        repository_commit,
                        [
                            {
                                "path": self.FILE,
                                "content": alpha,
                                "masks": _masks(10),
                                "observations": [
                                    (
                                        "pn-explicit-nil-init",
                                        2,
                                        {"syntaxKind": "local_explicit_nil"},
                                    )
                                ],
                            },
                            {
                                "path": self.OTHER,
                                "content": beta,
                                "masks": _masks(10),
                                "observations": [],
                            },
                        ],
                    )

    def test_rejects_incomplete_command_line(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, stage, detector = self._world(work_path)
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            missing = subprocess.run(
                [
                    sys.executable,
                    str(REPORT_PATH),
                    "--repository-root",
                    str(repository),
                    "--output-dir",
                    str(work_path / "out"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing.returncode, 0)
            positional = subprocess.run(
                [
                    sys.executable,
                    str(REPORT_PATH),
                    "--repository-root",
                    str(repository),
                    "--manifest",
                    str(manifest),
                    "--source-dir",
                    str(stage),
                    "--jscpd-json",
                    str(detector),
                    "--output-dir",
                    str(work_path / "out"),
                    "extra",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(positional.returncode, 0)
            self.assertFalse((work_path / "out" / "summary.json").is_file())


if __name__ == "__main__":
    unittest.main()
