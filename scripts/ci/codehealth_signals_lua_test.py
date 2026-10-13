#!/usr/bin/env python3
"""Behavioral checks for the advisory Lua signal scanner.

The scanner reads the structural Lua manifest, classifies each executable
source line, and records narrow syntax observations (explicit nil
initializers, cast annotations, unknown-shaped table generics, and
string-dispatch concentrations) as deterministic machine-readable output
files. These tests pin that behavior with inline fixtures and temporary
repositories; they fail while the scanner beside them is absent.
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


import tree_sitter
import tree_sitter_lua


SCANNER_PATH = Path(__file__).with_name("codehealth_signals_lua.py")

NIL_INIT = "pn-explicit-nil-init"
CAST_DIRECTIVE = "lua-cast-directive"
INLINE_CAST = "lua-inline-as-cast"
UNKNOWN_VALUED = "lua-unknown-valued-table"
UNKNOWN_KEYED = "lua-unknown-keyed-table"
STRING_DISPATCH = "lua-string-dispatch"

EXPECTED_RULE_IDS = (
    NIL_INIT,
    CAST_DIRECTIVE,
    INLINE_CAST,
    UNKNOWN_VALUED,
    UNKNOWN_KEYED,
    STRING_DISPATCH,
)

EXPECTED_FINDING_KEYS = frozenset(
    {
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
    }
)

SOURCE_URL_PREFIX = "https://github.com/portemon-nitro/portemon/blob/"


def load_scanner_module():
    """Load the scanner beside this test file or fail with a clear reason."""
    if not SCANNER_PATH.is_file():
        raise AssertionError(
            "the advisory Lua signal scanner must exist beside these "
            "behavioral checks before they can pass"
        )
    module_spec = importlib.util.spec_from_file_location(
        "codehealth_signals_lua", SCANNER_PATH
    )
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("the advisory Lua signal scanner cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _language():
    return tree_sitter.Language(tree_sitter_lua.language())


def _scan_source(module, source: str, path: str = "game/src/fixture.lua"):
    """Run the pure per-file scan and return its source row and findings."""
    raw = source.encode("utf-8")
    row, findings = module.scan_file(path, raw, _language())
    return row, findings


def _findings_for(findings, rule_id: str) -> list[dict]:
    return [item for item in findings if item["ruleId"] == rule_id]


def _init_repository(files: dict[str, str]) -> Path:
    directory = Path(tempfile.mkdtemp())
    for relative, content in files.items():
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, str):
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


def _run_scanner(
    repository: Path, manifest: Path, output_dir: Path
) -> subprocess.CompletedProcess[str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    return subprocess.run(
        [
            sys.executable,
            str(SCANNER_PATH),
            "--repository-root",
            str(repository),
            "--manifest",
            str(manifest),
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


def _sloc_buckets(row: dict) -> dict[str, list[int]]:
    return row["sloc"]


def _assert_exclusive_partition(
    case: unittest.TestCase, row: dict, raw: bytes, path: str
) -> None:
    buckets = _sloc_buckets(row)
    case.assertEqual(
        set(buckets.keys()), {"behavior", "mixed", "pureData", "unknown"}
    )
    seen: dict[int, str] = {}
    for bucket, lines in buckets.items():
        case.assertEqual(lines, sorted(lines), f"{bucket} lines must be sorted")
        for line_number in lines:
            case.assertNotIn(
                line_number, seen, f"line {line_number} classified twice"
            )
            seen[line_number] = bucket
    expected: set[int] = set()
    for number, text in enumerate(raw.decode("utf-8").splitlines(), start=1):
        stripped = text.strip()
        if not stripped or stripped.startswith("--"):
            continue
        expected.add(number)
    case.assertEqual(set(seen.keys()), expected)


class SourceLineTaxonomyTest(unittest.TestCase):
    """Executable lines carry exactly one of four exclusive classes."""

    FIXTURE = (
        "local Data = {}\n"
        "Data.WORDS = {\n"
        "  10,\n"
        "  20,\n"
        "  30,\n"
        "}\n"
        "local function total(list)\n"
        "  local sum = 0\n"
        "  for _, value in ipairs(list) do\n"
        "    sum = sum + value\n"
        "  end\n"
        "  return sum\n"
        "end\n"
        "local combined = { 1, 2, total({ 3 }) }\n"
        "-- closing note\n"
        "local prose = [[\n"
        "just words here\n"
        "]]\n"
        "return Data\n"
    )

    def test_static_table_function_and_mixed_lines_are_partitioned(self) -> None:
        module = load_scanner_module()
        row, _ = _scan_source(module, self.FIXTURE)
        buckets = _sloc_buckets(row)
        for line_number in (3, 4, 5):
            self.assertIn(line_number, buckets["pureData"])
        for line_number in (7, 8, 9, 10, 11, 12, 13):
            self.assertIn(line_number, buckets["behavior"])
        self.assertIn(14, buckets["mixed"])
        self.assertIn(19, buckets["unknown"])
        _assert_exclusive_partition(
            self, row, self.FIXTURE.encode("utf-8"), "game/src/fixture.lua"
        )

    def test_comment_lines_are_not_source_lines(self) -> None:
        module = load_scanner_module()
        row, _ = _scan_source(module, self.FIXTURE)
        buckets = _sloc_buckets(row)
        for lines in buckets.values():
            self.assertNotIn(15, lines)

    def test_cli_reports_same_partition_and_leaves_sources_untouched(self) -> None:
        module = load_scanner_module()
        del module
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/mixed.lua": self.FIXTURE})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/mixed.lua"])
            target = repository / "game/src/mixed.lua"
            before = hashlib.sha256(target.read_bytes()).hexdigest()
            output_dir = work_path / "out"
            result = _run_scanner(repository, manifest, output_dir)
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), before)
            rows = _read_jsonl(output_dir / "source.jsonl")
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["path"], "game/src/mixed.lua")
            self.assertEqual(
                rows[0]["sourceSha256"],
                hashlib.sha256(self.FIXTURE.encode("utf-8")).hexdigest(),
            )
            buckets = _sloc_buckets(rows[0])
            for line_number in (3, 4, 5):
                self.assertIn(line_number, buckets["pureData"])
            for line_number in (7, 8, 9, 10, 11, 12, 13):
                self.assertIn(line_number, buckets["behavior"])
            self.assertIn(14, buckets["mixed"])
            self.assertIn(19, buckets["unknown"])
            _assert_exclusive_partition(
                self, rows[0], self.FIXTURE.encode("utf-8"), "game/src/mixed.lua"
            )


class ManifestScopeTest(unittest.TestCase):
    """Only manifest sources are scanned, with provenance pinned to HEAD."""

    KEPT = "local n = nil\nreturn n\n"
    SKIPPED = "local skipped = nil\nreturn skipped\n"

    def test_only_manifest_sources_appear_with_byte_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository(
                {
                    "game/src/kept.lua": self.KEPT,
                    "game/src/skipped.lua": self.SKIPPED,
                }
            )
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/kept.lua"])
            output_dir = work_path / "out"
            result = _run_scanner(repository, manifest, output_dir)
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            head = _head_sha(repository)
            self.assertRegex(head, r"^[0-9a-f]{40}$")
            rows = _read_jsonl(output_dir / "source.jsonl")
            self.assertEqual([row["path"] for row in rows], ["game/src/kept.lua"])
            self.assertEqual(
                rows[0]["sourceSha256"],
                hashlib.sha256(self.KEPT.encode("utf-8")).hexdigest(),
            )
            rules = json.loads((output_dir / "rules.json").read_text(encoding="utf-8"))
            self.assertEqual(rules["commit"], head)
            findings = _read_jsonl(output_dir / "findings.jsonl")
            self.assertTrue(findings, "kept fixture must yield at least one finding")
            for finding in findings:
                self.assertTrue(
                    finding["sourceUrl"].startswith(
                        f"{SOURCE_URL_PREFIX}{head}/game/src/kept.lua#L"
                    ),
                    f"source URL must pin HEAD: {finding['sourceUrl']!r}",
                )

    def test_parent_traversal_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/kept.lua": self.KEPT})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = work_path / "manifest.txt"
            manifest.write_text("../outside.lua\n", encoding="utf-8")
            result = _run_scanner(repository, manifest, work_path / "out")
            self.assertNotEqual(result.returncode, 0)

    def test_symlink_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            outside = work_path / "outside.lua"
            outside.write_text("local n = nil\nreturn n\n", encoding="utf-8")
            repository = _init_repository({"game/src/kept.lua": self.KEPT})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            link = repository / "game/src/link.lua"
            link.symlink_to(outside)
            manifest = _write_manifest(work_path, ["game/src/link.lua"])
            result = _run_scanner(repository, manifest, work_path / "out")
            self.assertNotEqual(result.returncode, 0)

    def test_missing_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/kept.lua": self.KEPT})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/gone.lua"])
            result = _run_scanner(repository, manifest, work_path / "out")
            self.assertNotEqual(result.returncode, 0)

    def test_missing_flags_and_positional_input_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/kept.lua": self.KEPT})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/kept.lua"])
            missing = subprocess.run(
                [
                    sys.executable,
                    str(SCANNER_PATH),
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
                    str(SCANNER_PATH),
                    "--repository-root",
                    str(repository),
                    "--manifest",
                    str(manifest),
                    "--output-dir",
                    str(work_path / "out"),
                    "extra",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(positional.returncode, 0)


class NilInitializerTest(unittest.TestCase):
    """Only the single-local single-nil form is a nil-init candidate."""

    FIXTURE = (
        "local x = nil\n"
        "local a, b = nil, nil\n"
        "local y = make(), nil\n"
        "x = nil\n"
        "local z = false\n"
        "local function f()\n"
        "  return nil\n"
        "end\n"
        "return { x = x, a = a, b = b, y = y, z = z, f = f }\n"
    )

    def test_single_local_nil_matches_nothing_else_does(self) -> None:
        module = load_scanner_module()
        _, findings = _scan_source(module, self.FIXTURE)
        matches = _findings_for(findings, NIL_INIT)
        self.assertEqual(len(matches), 1)
        match = matches[0]
        self.assertEqual(match["startLine"], 1)
        self.assertEqual(match["endLine"], 1)
        self.assertEqual(match["details"]["syntaxKind"], "local_explicit_nil")
        self.assertEqual(match["reviewState"], "unreviewed")
        self.assertFalse(match["scoreEligible"])


class StringDispatchTest(unittest.TestCase):
    """Four same-binding string comparisons in one function are a candidate."""

    FIXTURE = (
        "local function describe(kind)\n"
        '  if kind == "fire" then\n'
        "    return 1\n"
        '  elseif kind == "water" then\n'
        "    return 2\n"
        '  elseif kind == "grass" then\n'
        "    return 3\n"
        '  elseif kind == "electric" then\n'
        "    return 4\n"
        "  end\n"
        "  return 0\n"
        "end\n"
        "local function small(kind)\n"
        '  -- if kind == "extra" then return 9 end\n'
        '  if kind == "a" then\n'
        "    return 1\n"
        '  elseif kind == "b" then\n'
        "    return 2\n"
        '  elseif kind == "c" then\n'
        "    return 3\n"
        "  end\n"
        "  return 0\n"
        "end\n"
        "local function outer(mode)\n"
        "  local function inner(mode)\n"
        '    if mode == "p" then\n'
        "      return 1\n"
        '    elseif mode == "q" then\n'
        "      return 2\n"
        '    elseif mode == "r" then\n'
        "      return 3\n"
        "    end\n"
        "    return 0\n"
        "  end\n"
        '  if mode == "a" then\n'
        "    return inner(mode)\n"
        '  elseif mode == "b" then\n'
        "    return 2\n"
        "  end\n"
        "  return 0\n"
        "end\n"
        'local text = "kind == fire"\n'
        "return { describe = describe, small = small, outer = outer, text = text }\n"
    )

    def test_four_comparison_binding_matches_once(self) -> None:
        module = load_scanner_module()
        _, findings = _scan_source(module, self.FIXTURE)
        matches = _findings_for(findings, STRING_DISPATCH)
        self.assertEqual(len(matches), 1)
        match = matches[0]
        self.assertEqual(match["details"]["variable"], "kind")
        self.assertEqual(match["details"]["comparisons"], 4)
        self.assertEqual(match["details"]["functionStartLine"], 1)
        self.assertEqual(match["reviewState"], "unreviewed")
        self.assertFalse(match["scoreEligible"])


class CastAnnotationTest(unittest.TestCase):
    """Only real annotation cast forms match, with exact byte positions."""

    FIXTURE = (
        'local label = "caf\u00e9"\n'
        "---@cast value Foo\n"
        "local value = get()\n"
        'local text = "--[[@as Bar]]"\n'
        "---@type Foo\n"
        "local typed = get()\n"
        "-- note about casts for readers\n"
        "local inline = compute() --[[@as Qux]]\n"
        "return { label = label, value = value, text = text, typed = typed, inline = inline }\n"
    )

    def test_directive_and_inline_casts_match_without_false_positives(self) -> None:
        module = load_scanner_module()
        raw = self.FIXTURE.encode("utf-8")
        _, findings = _scan_source(module, self.FIXTURE)
        directives = _findings_for(findings, CAST_DIRECTIVE)
        inlines = _findings_for(findings, INLINE_CAST)
        self.assertEqual(len(directives), 1)
        self.assertEqual(len(inlines), 1)
        directive = directives[0]
        self.assertEqual(directive["details"]["target"], "value")
        self.assertIn("Foo", directive["details"]["type"])
        self.assertIn("annotationKind", directive["details"])
        inline = inlines[0]
        self.assertIn("Qux", inline["details"]["type"])
        self.assertIn("annotationKind", inline["details"])
        self.assertEqual(
            {directive["startLine"], inline["startLine"]},
            {2, 8},
            "type declarations, strings, and prose must not match as casts",
        )

    def test_multibyte_prefix_keeps_byte_offsets_exact(self) -> None:
        module = load_scanner_module()
        raw = self.FIXTURE.encode("utf-8")
        _, findings = _scan_source(module, self.FIXTURE)
        directives = _findings_for(findings, CAST_DIRECTIVE)
        self.assertEqual(len(directives), 1)
        directive = directives[0]
        self.assertEqual(directive["startByte"], raw.index(b"---@cast"))
        span = raw[directive["startByte"] : directive["endByte"]]
        self.assertIn(b"@cast", span)
        self.assertEqual(raw.count(b"\n", 0, directive["startByte"]) + 1, 2)
        self.assertEqual(directive["startLine"], 2)


class UnknownTableTest(unittest.TestCase):
    """Unknown key/value generics match per generic with declaration context."""

    FIXTURE = (
        "---@field public x table<string, unknown>?\n"
        "---@param map table<unknown, unknown> lookup entries follow\n"
        "local function f(map)\n"
        "  return map\n"
        "end\n"
        'local label = "table<string, unknown>"\n'
        "-- table<key, unknownThing> is not a real annotation\n"
        "---@field private y table<string, table<unknown, number>>\n"
        "local mod = { f = f, label = label }\n"
        "return mod\n"
    )

    def test_keyed_and_valued_unknowns_are_distinct_findings(self) -> None:
        module = load_scanner_module()
        _, findings = _scan_source(module, self.FIXTURE)
        valued = _findings_for(findings, UNKNOWN_VALUED)
        keyed = _findings_for(findings, UNKNOWN_KEYED)
        self.assertEqual(
            sorted(match["startLine"] for match in valued),
            [1, 2],
            "optional markers and trailing prose must not defeat parsing",
        )
        self.assertEqual(
            sorted(match["startLine"] for match in keyed),
            [2, 8],
            "nested generics match per inner generic, strings and prose never match",
        )
        by_line = {(match["ruleId"], match["startLine"]): match for match in valued}
        first = by_line[(UNKNOWN_VALUED, 1)]
        self.assertEqual(first["details"]["genericKeyType"], "string")
        self.assertEqual(first["details"]["genericValueType"], "unknown")
        self.assertEqual(first["details"]["declarationContext"], "field")
        self.assertEqual(first["details"]["visibility"], "public_declared")
        second = by_line[(UNKNOWN_VALUED, 2)]
        self.assertEqual(second["details"]["genericKeyType"], "unknown")
        self.assertEqual(second["details"]["genericValueType"], "unknown")
        self.assertEqual(second["details"]["declarationContext"], "parameter")
        inner = [match for match in keyed if match["startLine"] == 8][0]
        self.assertEqual(inner["details"]["genericKeyType"], "unknown")
        self.assertEqual(inner["details"]["genericValueType"], "number")
        self.assertEqual(inner["details"]["visibility"], "private_declared")
        for match in valued + keyed:
            for key in (
                "annotationKind",
                "genericKeyType",
                "genericValueType",
                "declarationContext",
                "visibility",
            ):
                self.assertIn(key, match["details"])
            self.assertEqual(match["reviewState"], "unreviewed")
            self.assertFalse(match["scoreEligible"])

    def test_single_annotation_generics_have_noncolliding_ids(self) -> None:
        module = load_scanner_module()
        _, findings = _scan_source(module, self.FIXTURE)
        matches = _findings_for(findings, UNKNOWN_VALUED) + _findings_for(
            findings, UNKNOWN_KEYED
        )
        identifiers = [match["id"] for match in matches if "id" in match]
        if identifiers:
            self.assertEqual(len(identifiers), len(set(identifiers)))


class OutputHandoffTest(unittest.TestCase):
    """Repeated runs publish byte-identical, fully reconciled output files."""

    FIXTURE = (
        "---@cast target Config\n"
        "local n = nil\n"
        "local function f(mode)\n"
        '  if mode == "a" then\n'
        "    return 1\n"
        '  elseif mode == "b" then\n'
        "    return 2\n"
        '  elseif mode == "c" then\n'
        "    return 3\n"
        '  elseif mode == "d" then\n'
        "    return 4\n"
        "  end\n"
        "  return 0\n"
        "end\n"
        "return { n = n, f = f }\n"
    )
    EMPTY = "local n = 42\nlocal m = n + 1\nreturn m\n"

    def _scan_fixture(self, work: Path, filename: str, content: str):
        repository = _init_repository({f"game/src/{filename}": content})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        manifest = _write_manifest(work, [f"game/src/{filename}"])
        first = work / "first"
        second = work / "second"
        for output_dir in (first, second):
            result = _run_scanner(repository, manifest, output_dir)
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
        return repository, manifest, first, second

    def test_repeated_runs_are_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            _, _, first, second = self._scan_fixture(
                work_path, "signals.lua", self.FIXTURE
            )
            for name in ("source.jsonl", "findings.jsonl", "rules.json"):
                first_digest = hashlib.sha256(
                    (first / name).read_bytes()
                ).hexdigest()
                second_digest = hashlib.sha256(
                    (second / name).read_bytes()
                ).hexdigest()
                self.assertEqual(
                    first_digest, second_digest, f"{name} must be reproducible"
                )

    def test_output_files_are_sorted_and_reconciled(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository, manifest, first, _ = self._scan_fixture(
                work_path, "signals.lua", self.FIXTURE
            )
            head = _head_sha(repository)
            raw = self.FIXTURE.encode("utf-8")
            source_rows = _read_jsonl(first / "source.jsonl")
            self.assertEqual(len(source_rows), 1)
            self.assertEqual(source_rows[0]["path"], "game/src/signals.lua")
            _assert_exclusive_partition(
                self, source_rows[0], raw, "game/src/signals.lua"
            )
            findings = _read_jsonl(first / "findings.jsonl")
            self.assertTrue(findings)
            keys = [
                (
                    finding["path"],
                    finding["startByte"],
                    finding["endByte"],
                    finding["ruleId"],
                    finding["id"],
                )
                for finding in findings
            ]
            self.assertEqual(keys, sorted(keys), "findings must be sorted")
            identifiers = [finding["id"] for finding in findings]
            for identifier in identifiers:
                self.assertRegex(identifier, r"^[0-9a-f]{64}$")
            self.assertEqual(len(identifiers), len(set(identifiers)))
            for finding in findings:
                self.assertEqual(set(finding.keys()), EXPECTED_FINDING_KEYS)
                self.assertEqual(finding["reviewState"], "unreviewed")
                self.assertFalse(finding["scoreEligible"])
                self.assertLess(finding["startByte"], finding["endByte"])
                self.assertLessEqual(finding["startLine"], finding["endLine"])
                span = raw[finding["startByte"] : finding["endByte"]]
                self.assertTrue(span, "byte span must be nonempty")
                span.decode("utf-8")
                self.assertEqual(
                    raw.count(b"\n", 0, finding["startByte"]) + 1,
                    finding["startLine"],
                )
                json.dumps(finding["details"])
            rules = json.loads((first / "rules.json").read_text(encoding="utf-8"))
            self.assertEqual(rules["schemaVersion"], 1)
            self.assertEqual(rules["commit"], head)
            self.assertEqual(
                rules["manifestSha256"],
                hashlib.sha256(manifest.read_bytes()).hexdigest(),
            )
            self.assertEqual(rules["filesParsed"], 1)
            detectors = rules["detectors"]
            self.assertEqual(
                sorted(detector["id"] for detector in detectors),
                sorted(EXPECTED_RULE_IDS),
            )
            for detector in detectors:
                count = len(_findings_for(findings, detector["id"]))
                self.assertEqual(detector["observations"], count)
                if count:
                    self.assertEqual(detector["status"], "executed_with_hits")
                else:
                    self.assertEqual(detector["status"], "executed_no_match")

    def test_matchless_source_writes_a_genuinely_empty_findings_stream(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/plain.lua": self.EMPTY})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/plain.lua"])
            output_dir = work_path / "out"
            result = _run_scanner(repository, manifest, output_dir)
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            findings_path = output_dir / "findings.jsonl"
            self.assertTrue(findings_path.is_file())
            self.assertEqual(findings_path.read_text(encoding="utf-8"), "")
            rules = json.loads(
                (output_dir / "rules.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                sorted(detector["id"] for detector in rules["detectors"]),
                sorted(EXPECTED_RULE_IDS),
            )
            for detector in rules["detectors"]:
                self.assertEqual(detector["status"], "executed_no_match")
                self.assertEqual(detector["observations"], 0)

    def test_unparsable_source_aborts_without_a_success_claim(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            work_path = Path(work)
            repository = _init_repository({"game/src/broken.lua": "local x = =\n"})
            self.addCleanup(
                lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
            )
            manifest = _write_manifest(work_path, ["game/src/broken.lua"])
            output_dir = work_path / "out"
            result = _run_scanner(repository, manifest, output_dir)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((output_dir / "rules.json").is_file())


if __name__ == "__main__":
    unittest.main()
