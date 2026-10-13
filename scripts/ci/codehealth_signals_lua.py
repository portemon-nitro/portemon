#!/usr/bin/env python3
"""Advisory Lua signal scan over the structural code-health manifest.

Reads the Lizard-backed structural manifest, parses each listed Lua source
with Tree-sitter, classifies every executable source line into exactly one
of four exclusive buckets (behavior, mixed, pure data, unknown), and records
narrow syntax observations -- explicit nil initializers, cast annotations,
unknown-shaped table generics, and string-dispatch concentrations -- as
deterministic machine-readable stage files for a separate report consumer.

The scan is read-only with respect to the inspected repository and fails
closed: any unsafe path, missing source, undecodable text, syntax error, or
contract mismatch aborts without publishing a success claim. Every emitted
observation is unreviewed and scores nothing; candidacy here never means a
verified defect or a safe removal.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import codehealth_scope


try:
    import tree_sitter
    import tree_sitter_lua
except ImportError as error:  # failed dependency aborts every entry point
    raise SystemExit(f"lua signals: missing parser dependency: {error}")


REPOSITORY_URL_PREFIX = "https://github.com/portemon-nitro/portemon/blob/"

RULES: tuple[tuple[str, str], ...] = (
    ("lua-cast-directive", "typing"),
    ("lua-inline-as-cast", "typing"),
    ("lua-string-dispatch", "verbosity_candidate"),
    ("lua-unknown-keyed-table", "typing"),
    ("lua-unknown-valued-table", "typing"),
    ("pn-explicit-nil-init", "verbosity_candidate"),
)
RULE_GROUPS = dict(RULES)

NIL_INIT = "pn-explicit-nil-init"
CAST_DIRECTIVE = "lua-cast-directive"
INLINE_CAST = "lua-inline-as-cast"
UNKNOWN_VALUED = "lua-unknown-valued-table"
UNKNOWN_KEYED = "lua-unknown-keyed-table"
STRING_DISPATCH = "lua-string-dispatch"

_DIRECTIVE_NAMES = (
    "param",
    "return",
    "type",
    "field",
    "alias",
    "vararg",
    "cast",
)

_CAST_RE = re.compile(r"^-\s*@\s*cast\s+(\S+)\s+(.+?)\s*$")
_DIRECTIVE_RE = re.compile(r"^-\s*@\s*([A-Za-z_]\w*)(.*)$", re.DOTALL)
_NAME_SKIP_RES = {
    "field": re.compile(
        r"^\s*(?:(public|private|protected)\s+)?"
        r"(\.\.\.|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*|\[[^\]]*\])\??\s+",
        re.DOTALL,
    ),
    "param": re.compile(r"^\s*(\.\.\.|[A-Za-z_]\w*)\??\s+", re.DOTALL),
    "alias": re.compile(r"^\s*(\S+)\s+", re.DOTALL),
    "cast": re.compile(r"^\s*(\S+)\s+", re.DOTALL),
}
_VISIBILITY_BY_MARKER = {
    "public": "public_declared",
    "private": "private_declared",
}
_CONTEXT_BY_DIRECTIVE = {
    "field": "field",
    "param": "parameter",
    "return": "return",
    "alias": "alias",
    "type": "local",
    "vararg": "other",
    "cast": "other",
    "as": "inline",
    "continuation": "other",
}
_KIND_BY_DIRECTIVE = {
    "field": "field",
    "param": "parameter",
    "return": "return",
    "alias": "alias",
    "type": "type",
    "vararg": "vararg",
    "cast": "cast_directive",
    "as": "inline_as",
    "continuation": "continuation",
}

_SCAFFOLD_LEAF_TYPES = frozenset({"local", "identifier", "=", ",", ";", ".", ":"})

_FUNCTION_NODE_TYPES = frozenset({"function_declaration", "function_definition"})
_DYNAMIC_NODE_TYPES = frozenset({"function_call", "binary_expression"})

_TABLE_WORD_RE = re.compile(r"(?<![A-Za-z0-9_])table\s*<")


class ScanError(ValueError):
    """A fail-closed scan failure: publish nothing on success claims."""


def _language():
    return tree_sitter.Language(tree_sitter_lua.language())


def _iter_nodes(root):
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(node.children))


def _is_static_table(node) -> bool:
    """A table holds static data only when every field is a literal, a
    nested static table, or a signed numeric literal. Any call, computed
    identifier read, function value, or other evaluated expression --
    including a dotted name read -- disqualifies the whole table."""
    if node.type != "table_constructor":
        return False
    state = {"ok": True}

    def _value(item) -> None:
        if not state["ok"]:
            return
        kind = item.type
        if kind in ("number", "string", "true", "false", "nil"):
            return
        if kind == "table_constructor":
            for child in item.children:
                _value(child)
            return
        if kind == "field":
            kids = [c for c in item.children if not c.is_extra]
            if len(kids) == 3 and kids[1].type == "=" and kids[0].type != "[":
                # A bare-name key is syntax, not a read; the value decides.
                _value(kids[2])
                return
            if kids and kids[0].type == "[":
                # A bracketed key is evaluated, so key and value must both
                # be plain literals.
                named = [c for c in kids if c.is_named and not c.is_extra]
                if len(named) == 2 and named[0].type in (
                    "number",
                    "string",
                    "true",
                    "false",
                ):
                    _value(named[1])
                    return
                state["ok"] = False
                return
            for child in kids:
                _value(child)
            return
        if kind == "unary_expression":
            kids = [c for c in item.children if not c.is_extra]
            if len(kids) == 2 and kids[0].type == "-" and kids[1].type == "number":
                return
            state["ok"] = False
            return
        if item.is_named:
            # Identifier reads, calls, functions, dotted reads, varargs,
            # and parenthesized or computed expressions are evaluated.
            state["ok"] = False
            return

    for child in node.children:
        _value(child)
    return state["ok"]


def _comment_ranges(nodes):
    return [
        (node.start_byte, node.end_byte) for node in nodes if node.type == "comment"
    ]


def _annotation_comments(nodes):
    """Comments eligible for annotation reading: real comments only, never
    bracket text lexed inside a string literal."""
    found = []
    for node in nodes:
        if node.type != "comment":
            continue
        ancestor = node.parent
        inside_string = False
        while ancestor is not None:
            if ancestor.type == "string":
                inside_string = True
                break
            ancestor = ancestor.parent
        if not inside_string:
            found.append(node)
    return found


def _function_nodes(nodes):
    return [n for n in nodes if n.type in _FUNCTION_NODE_TYPES]


def _named(node):
    return [c for c in node.children if c.is_named and not c.is_extra]


def _code_children(node):
    return [c for c in node.children if not c.is_extra]


def _span_cover(spans):
    """A containment probe over byte spans: sorted starts plus a running
    maximum end, so one binary search answers whether a byte sits inside
    any span even when spans nest."""
    ordered = sorted(spans)
    starts = [start for start, _ in ordered]
    running_end = []
    peak = -1
    for _, end in ordered:
        peak = max(peak, end)
        running_end.append(peak)
    return starts, running_end


def _covered(probe, byte: int) -> bool:
    starts, running_end = probe
    index = bisect.bisect_right(starts, byte) - 1
    return index >= 0 and running_end[index] > byte


def _classify_source_lines(nodes, raw: bytes):
    """Bucket every executable line into exactly one exclusive class.

    Lines touching a static literal table span are data; lines touching a
    function body, call, or computed comparison are behavior; lines with
    both are mixed; lines with neither -- bare name traffic, unattributable
    string payload -- stay unknown rather than invented behavior.
    """
    static_spans = []
    for node in nodes:
        if node.type != "table_constructor":
            continue
        if any(s <= node.start_byte < e for s, e in static_spans):
            continue  # nested statics are covered by the outer span
        if _is_static_table(node):
            static_spans.append((node.start_byte, node.end_byte))
    behavior_spans = [
        (node.start_byte, node.end_byte)
        for node in nodes
        if node.type in _FUNCTION_NODE_TYPES or node.type in _DYNAMIC_NODE_TYPES
    ]

    comments = _comment_ranges(nodes)
    static_cover = _span_cover(static_spans)
    behavior_cover = _span_cover(behavior_spans)
    comment_cover = _span_cover(comments)

    line_leaves: dict[int, list] = {}
    for node in nodes:
        if node.child_count != 0 or node.is_extra:
            continue
        if _covered(comment_cover, node.start_byte):
            continue
        for number in range(node.start_point.row + 1, node.end_point.row + 2):
            line_leaves.setdefault(number, []).append(node)

    buckets: dict[str, list[int]] = {
        "behavior": [],
        "mixed": [],
        "pureData": [],
        "unknown": [],
    }
    # A line counts only when noncomment bytes remain: blank the exact
    # parser-identified comment spans while keeping every line break, so
    # comment-only lines vanish but code beside comments and `--` text
    # inside long strings survive with positions intact.
    uncommented = bytearray(raw)
    for start_byte, end_byte in comments:
        uncommented[start_byte:end_byte] = re.sub(
            rb"[^\r\n]", b" ", raw[start_byte:end_byte]
        )
    text = bytes(uncommented).decode("utf-8")
    for number, content in enumerate(text.split("\n"), start=1):
        if not content.strip():
            continue
        leaves = line_leaves.get(number, [])
        static_hit = any(_covered(static_cover, leaf.start_byte) for leaf in leaves)
        behavior_hit = any(
            not _covered(static_cover, leaf.start_byte)
            and _covered(behavior_cover, leaf.start_byte)
            for leaf in leaves
        )
        if static_hit and behavior_hit:
            buckets["mixed"].append(number)
        elif behavior_hit:
            buckets["behavior"].append(number)
        elif static_hit:
            rest = [
                leaf
                for leaf in leaves
                if not _covered(static_cover, leaf.start_byte)
            ]
            if all(leaf.type in _SCAFFOLD_LEAF_TYPES for leaf in rest):
                buckets["pureData"].append(number)
            else:
                buckets["mixed"].append(number)
        else:
            buckets["unknown"].append(number)
    return buckets


def _finding_id(rule_id: str, path: str, start: int, end: int, details: dict) -> str:
    canonical_details = json.dumps(
        details,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
        ensure_ascii=False,
    )
    payload = "\x00".join((rule_id, path, str(start), str(end), canonical_details))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _subsystem_for_path(path: str) -> str:
    # Mirrors the grouping used by the existing quality report so per-file
    # rows stay comparable without importing the report builder here.
    parts = path.split("/")
    if parts[0] == "libs" and len(parts) > 1:
        return f"libs/{parts[1]}"
    if parts[0] == "game" and len(parts) > 1 and parts[1] == "hgss":
        return "game/hgss"
    return parts[0]


def _line_of(raw: bytes, byte: int) -> int:
    return raw.count(b"\n", 0, byte) + 1


def _end_line_of(raw: bytes, start: int, end: int) -> int:
    return raw.count(b"\n", 0, max(start, end - 1)) + 1


def _finish_finding(
    rule_id: str,
    path: str,
    raw: bytes,
    start: int,
    end: int,
    details: dict,
) -> dict:
    if not (0 <= start < end <= len(raw)):
        raise ScanError(f"finding span out of range for {path}")
    try:
        raw[start:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ScanError(f"finding span splits text in {path}: {error}") from error
    # Round-trip through canonical JSON so only finite primitives survive.
    details = json.loads(
        json.dumps(details, sort_keys=True, allow_nan=False, ensure_ascii=False)
    )
    return {
        "id": _finding_id(rule_id, path, start, end, details),
        "ruleId": rule_id,
        "group": RULE_GROUPS[rule_id],
        "path": path,
        "subsystem": _subsystem_for_path(path),
        "startByte": start,
        "endByte": end,
        "startLine": _line_of(raw, start),
        "endLine": _end_line_of(raw, start, end),
        "sourceUrl": "",
        "reviewState": "unreviewed",
        "scoreEligible": False,
        "details": details,
    }


def _nil_findings(nodes, path: str, raw: bytes) -> list[dict]:
    """A single `local name = nil` statement only: exactly one declared
    name with exactly one initializer that is the literal nil. Anything
    wider -- multiple names, call results, plain assignment, returns --
    is a different shape and stays silent."""
    findings = []
    for node in nodes:
        if node.type != "variable_declaration":
            continue
        kids = _code_children(node)
        if not any(child.type == "local" for child in kids):
            continue
        statements = [child for child in kids if child.type == "assignment_statement"]
        if len(statements) != 1:
            continue
        skids = _code_children(statements[0])
        varlists = [child for child in skids if child.type == "variable_list"]
        exprlists = [child for child in skids if child.type == "expression_list"]
        if len(varlists) != 1 or len(exprlists) != 1:
            continue
        names = _named(varlists[0])
        values = _named(exprlists[0])
        if len(names) != 1 or names[0].type != "identifier":
            continue
        if len(values) != 1 or values[0].type != "nil":
            continue
        findings.append(
            _finish_finding(
                NIL_INIT,
                path,
                raw,
                node.start_byte,
                node.end_byte,
                {"syntaxKind": "local_explicit_nil"},
            )
        )
    return findings


def _iter_table_generics(text: str):
    """Yield (key, value, start, end) for each balanced `table<K, V>`
    occurrence, including nested ones. String-aware so quoted commas and
    brackets never split or close a generic early."""
    out: list[tuple[str, str, int, int]] = []

    def _scan_angles(body: str, pos: int) -> int:
        depth = 1
        quote: str | None = None
        i = pos
        while i < len(body):
            c = body[i]
            if quote is not None:
                if c == quote:
                    quote = None
                i += 1
                continue
            if c in "\"'":
                quote = c
                i += 1
                continue
            if body[i : i + 2] == "->":
                i += 2
                continue
            if c == "<":
                depth += 1
            elif c == ">":
                depth -= 1
                if depth == 0:
                    return i
            i += 1
        return -1

    def _split_top_level(inner: str) -> list[str]:
        parts: list[str] = []
        depths = [0, 0, 0, 0]
        quote: str | None = None
        current: list[str] = []
        i = 0
        while i < len(inner):
            c = inner[i]
            if quote is not None:
                current.append(c)
                if c == quote:
                    quote = None
                i += 1
                continue
            if c in "\"'":
                quote = c
                current.append(c)
                i += 1
                continue
            if inner[i : i + 2] == "->":
                current.append("->")
                i += 2
                continue
            if c == "<":
                depths[0] += 1
            elif c == ">":
                depths[0] = max(0, depths[0] - 1)
            elif c == "(":
                depths[1] += 1
            elif c == ")":
                depths[1] = max(0, depths[1] - 1)
            elif c == "{":
                depths[2] += 1
            elif c == "}":
                depths[2] = max(0, depths[2] - 1)
            elif c == "[":
                depths[3] += 1
            elif c == "]":
                depths[3] = max(0, depths[3] - 1)
            if c == "," and all(depth == 0 for depth in depths):
                parts.append("".join(current).strip())
                current = []
                i += 1
                continue
            current.append(c)
            i += 1
        parts.append("".join(current).strip())
        return parts

    def _recurse(body: str, base: int) -> None:
        i = 0
        while i < len(body):
            match = _TABLE_WORD_RE.search(body, i)
            if match is None:
                break
            angle = match.group(0).rfind("<")
            inner_start = match.start() + angle + 1
            close = _scan_angles(body, inner_start)
            if close < 0:
                i = match.end()
                continue
            inner = body[inner_start:close]
            parts = _split_top_level(inner)
            key = parts[0] if parts else ""
            value = parts[1] if len(parts) > 1 else ""
            table_at = body.rfind("table", match.start(), inner_start)
            start = base + (table_at if table_at >= 0 else match.start())
            out.append((key, value, start, base + close + 1))
            _recurse(inner, base + inner_start)
            i = close + 1

    _recurse(text, 0)
    return out


def _is_unknown_type(text: str) -> bool:
    return text.strip().rstrip("?").strip() == "unknown"


def _type_region_end(text: str, start: int) -> int:
    """End of one type expression: spaces are allowed inside brackets and
    around union bars, but a bare word after a top-level space starts
    trailing prose and ends the type. A top-level `|` opens another
    operand, so spaces after it are consumed until that operand starts."""
    angle = paren = brace = bracket = 0
    quote: str | None = None
    need_operand = False
    i = start
    while i < len(text):
        c = text[i]
        if quote is not None:
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            need_operand = False
            i += 1
            continue
        if text[i : i + 2] == "->":
            need_operand = False
            i += 2
            continue
        if c in "<([{":
            angle += c == "<"
            paren += c == "("
            brace += c == "{"
            bracket += c == "["
            need_operand = False
            i += 1
            continue
        if c in ">)}]":
            angle = max(0, angle - (c == ">"))
            paren = max(0, paren - (c == ")"))
            brace = max(0, brace - (c == "}"))
            bracket = max(0, bracket - (c == "]"))
            need_operand = False
            i += 1
            continue
        if c == "|" and not (angle or paren or brace or bracket):
            need_operand = True
            i += 1
            continue
        if c in " \t":
            if angle or paren or brace or bracket:
                i += 1
                continue
            if need_operand:
                i += 1
                continue
            ahead = i
            while ahead < len(text) and text[ahead] in " \t":
                ahead += 1
            if text[ahead : ahead + 1] in ("|", "?", "[", ",", ".", ":"):
                i = ahead
                continue
            return i
        need_operand = False
        i += 1
    return i


def _utf8_len(prefix: str) -> int:
    return len(prefix.encode("utf-8"))


def _unknown_findings_for_type(
    type_text: str,
    type_start_in_comment: int,
    comment_text: str,
    comment_start_byte: int,
    path: str,
    raw: bytes,
    annotation_kind: str,
    declaration_context: str,
    visibility: str,
) -> list[dict]:
    findings = []
    region = type_text[: _type_region_end(type_text, 0)]
    for key, value, start, end in _iter_table_generics(region):
        generic_start = comment_start_byte + _utf8_len(
            comment_text[: type_start_in_comment + start]
        )
        generic_end = comment_start_byte + _utf8_len(
            comment_text[: type_start_in_comment + end]
        )
        base_details = {
            "genericKeyType": key.strip(),
            "genericValueType": value.strip(),
            "annotationKind": annotation_kind,
            "declarationContext": declaration_context,
            "visibility": visibility,
        }
        if _is_unknown_type(value):
            findings.append(
                _finish_finding(
                    UNKNOWN_VALUED,
                    path,
                    raw,
                    generic_start,
                    generic_end,
                    dict(base_details),
                )
            )
        if _is_unknown_type(key):
            findings.append(
                _finish_finding(
                    UNKNOWN_KEYED,
                    path,
                    raw,
                    generic_start,
                    generic_end,
                    dict(base_details),
                )
            )
    return findings


def _inline_as_findings(comment_text: str, start: int, path: str, raw: bytes):
    """An inline `@as` cast opens a long bracket comment; anything else in
    that shape -- including an `@as` buried in prose -- stays silent."""
    opener = 2
    while opener < len(comment_text) and comment_text[opener] in "[=":
        opener += 1
    closer = len(comment_text)
    while closer > opener and comment_text[closer - 1] in "]=":
        closer -= 1
    inner = comment_text[opener:closer]
    leading = len(inner) - len(inner.lstrip())
    if not inner[leading:].startswith("@as"):
        return []
    as_at = leading
    tail = inner[as_at + len("@as") :]
    type_text = tail.lstrip()
    if not type_text:
        return []
    type_start = opener + as_at + len("@as") + (len(tail) - len(type_text))
    region_end = _type_region_end(type_text, 0)
    cast_type = type_text[:region_end].strip()
    if not cast_type:
        return []
    findings = [
        _finish_finding(
            INLINE_CAST,
            path,
            raw,
            start,
            start + _utf8_len(comment_text),
            {"type": cast_type, "annotationKind": "inline_as"},
        )
    ]
    findings.extend(
        _unknown_findings_for_type(
            type_text,
            type_start,
            comment_text,
            start,
            path,
            raw,
            "inline_as",
            "inline",
            "unknown_visibility",
        )
    )
    return findings


def _is_whole_line_comment(raw: bytes, start: int) -> bool:
    """Whether only horizontal whitespace precedes a comment on its line."""
    line_start = raw.rfind(b"\n", 0, start) + 1
    return not raw[line_start:start].strip()


def _annotation_findings(comments, path: str, raw: bytes) -> list[dict]:
    """Cast and unknown-table observations from real annotation comments
    only: directive comments, valid alias/parameter continuation chains,
    and inline `@as` forms. Ordinary prose, strings, orphan continuations,
    and the words after a complete type never produce observations."""
    findings: list[dict] = []
    anchor_context: str | None = None
    anchor_row: int | None = None
    ordered = sorted(comments, key=lambda node: (node.start_byte, node.end_byte))
    for comment in ordered:
        start = comment.start_byte
        text = raw[start : comment.end_byte].decode("utf-8")
        if text.startswith("--["):
            findings.extend(_inline_as_findings(text, start, path, raw))
            anchor_context = None
            anchor_row = None
            continue
        content = text[2:]
        content_start = start + 2
        directive = _DIRECTIVE_RE.match(content)
        if directive is not None:
            word, remainder = directive.group(1), directive.group(2)
            if word not in _DIRECTIVE_NAMES:
                anchor_context = None
                anchor_row = None
                continue
            if word == "cast":
                anchor_context = None
                anchor_row = None
                cast = _CAST_RE.match(content)
                if cast is None:
                    continue
                target, cast_type = cast.group(1), cast.group(2).strip()
                if not target or not cast_type:
                    continue
                findings.append(
                    _finish_finding(
                        CAST_DIRECTIVE,
                        path,
                        raw,
                        start,
                        start + _utf8_len(text),
                        {
                            "target": target,
                            "type": cast_type,
                            "annotationKind": "cast_directive",
                        },
                    )
                )
                skip = _NAME_SKIP_RES["cast"].match(remainder)
                offset = len(content) - len(remainder) + (skip.end() if skip else 0)
                findings.extend(
                    _unknown_findings_for_type(
                        content[offset:],
                        offset,
                        content,
                        content_start,
                        path,
                        raw,
                        "cast_directive",
                        "other",
                        "unknown_visibility",
                    )
                )
                continue
            skip = None
            if word in _NAME_SKIP_RES:
                skip = _NAME_SKIP_RES[word].match(remainder)
            if skip is not None:
                marker = skip.group(1) if word == "field" else None
                visibility = _VISIBILITY_BY_MARKER.get(marker, "unknown_visibility")
                offset = len(content) - len(remainder) + skip.end()
            else:
                visibility = "unknown_visibility"
                offset = len(content) - len(remainder)
                while offset < len(content) and content[offset] in " \t":
                    offset += 1
            findings.extend(
                _unknown_findings_for_type(
                    content[offset:],
                    offset,
                    content,
                    content_start,
                    path,
                    raw,
                    _KIND_BY_DIRECTIVE[word],
                    _CONTEXT_BY_DIRECTIVE[word],
                    visibility,
                )
            )
            if (
                word in ("alias", "param")
                and remainder.strip() != ""
                and _is_whole_line_comment(raw, start)
            ):
                # A named whole-line alias/parameter directive opens a
                # continuation chain for the immediately following line.
                anchor_context = _CONTEXT_BY_DIRECTIVE[word]
                anchor_row = comment.end_point.row
            else:
                anchor_context = None
                anchor_row = None
            continue
        if content.startswith("-|"):
            # A `---|` continuation belongs to a neighboring alias or
            # parameter anchor only: same chain, adjacent physical line,
            # whole-line comment. Anything else is prose, not a type.
            if (
                anchor_context is not None
                and anchor_row is not None
                and comment.start_point.row == anchor_row + 1
                and _is_whole_line_comment(raw, start)
            ):
                offset = 2
                while offset < len(content) and content[offset] in " \t":
                    offset += 1
                findings.extend(
                    _unknown_findings_for_type(
                        content[offset:],
                        offset,
                        content,
                        content_start,
                        path,
                        raw,
                        "continuation",
                        anchor_context,
                        "unknown_visibility",
                    )
                )
                anchor_row = comment.end_point.row
            else:
                anchor_context = None
                anchor_row = None
            continue
        anchor_context = None
        anchor_row = None
    return findings


def _identifier_label(raw: bytes, node) -> str:
    return raw[node.start_byte : node.end_byte].decode("utf-8")


def _dispatch_findings(nodes, path: str, raw: bytes) -> list[dict]:
    """One observation per function and discriminant name with at least
    four string-literal equality comparisons against the same binding.
    Comparisons hidden in nested functions, comments, or string text do
    not count toward the enclosing function."""
    findings: list[dict] = []
    for function in _function_nodes(nodes):
        env: dict[str, tuple[str, int | None]] = {}
        for child in function.children:
            if child.type == "parameters":
                for name in _named(child):
                    if name.type == "identifier":
                        label = _identifier_label(raw, name)
                        env[label] = (label, name.start_byte)
        hits: dict[tuple[str, int | None], list] = {}

        def _walk(node, scope: dict) -> None:
            if node.type in _FUNCTION_NODE_TYPES and node is not function:
                return
            if node.type == "variable_declaration":
                for statement in _code_children(node):
                    if statement.type != "assignment_statement":
                        continue
                    skids = _code_children(statement)
                    for child in skids:
                        if child.type == "expression_list":
                            for item in _code_children(child):
                                _walk(item, scope)
                    for child in skids:
                        if child.type == "variable_list":
                            for name in _named(child):
                                if name.type == "identifier":
                                    label = _identifier_label(raw, name)
                                    scope[label] = (label, name.start_byte)
                return
            if node.type == "for_statement":
                body_scope = dict(scope)
                for child in _code_children(node):
                    if child.type == "for_numeric_clause":
                        for item in _code_children(child):
                            if item.type == "identifier":
                                label = _identifier_label(raw, item)
                                body_scope[label] = (label, item.start_byte)
                            elif item.type not in ("=", ","):
                                _walk(item, scope)
                    elif child.type == "for_generic_clause":
                        for item in _code_children(child):
                            if item.type == "variable_list":
                                for name in _named(item):
                                    if name.type == "identifier":
                                        label = _identifier_label(raw, name)
                                        body_scope[label] = (label, name.start_byte)
                            elif item.type == "expression_list":
                                for sub in _code_children(item):
                                    _walk(sub, scope)
                            elif item.type not in ("in", ","):
                                _walk(item, scope)
                    elif child.type == "block":
                        _walk(child, body_scope)
                    elif child.type not in ("for", "do", "end"):
                        _walk(child, scope)
                return
            if node.type == "block":
                inner = dict(scope)
                for child in _code_children(node):
                    _walk(child, inner)
                return
            if node.type == "binary_expression":
                kids = _code_children(node)
                operands = _named(node)
                if (
                    any(child.type == "==" for child in kids)
                    and len(operands) == 2
                ):
                    left, right = operands
                    identifier = None
                    if left.type == "identifier" and right.type == "string":
                        identifier = left
                    elif right.type == "identifier" and left.type == "string":
                        identifier = right
                    if identifier is not None:
                        label = _identifier_label(raw, identifier)
                        hits.setdefault(scope.get(label, (label, None)), []).append(
                            node
                        )
                        return
            for child in _code_children(node):
                _walk(child, scope)

        _walk(function, dict(env))
        for (label, _binding), nodes in sorted(
            hits.items(), key=lambda item: (item[0][0], item[0][1] or 0)
        ):
            if len(nodes) < 4:
                continue
            ordered = sorted(nodes, key=lambda n: (n.start_byte, n.end_byte))
            findings.append(
                _finish_finding(
                    STRING_DISPATCH,
                    path,
                    raw,
                    ordered[0].start_byte,
                    ordered[-1].end_byte,
                    {
                        "variable": label,
                        "comparisons": len(ordered),
                        "functionStartLine": function.start_point.row + 1,
                    },
                )
            )
    findings.sort(key=lambda item: (item["startByte"], item["endByte"], item["ruleId"]))
    return findings


def scan_file(path: str, source: bytes, lang) -> tuple[dict, list[dict]]:
    """Classify one source buffer and collect its six syntax observations.

    Pure across repositories: no filesystem or process state is touched.
    Raises ScanError on undecodable text or any syntax error.
    """
    try:
        source.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ScanError(f"invalid text in {path}: {error}") from error
    parser = tree_sitter.Parser(lang)
    tree = parser.parse(source)
    root = tree.root_node
    nodes = list(_iter_nodes(root))
    for node in nodes:
        if node.is_error or node.is_missing:
            raise ScanError(f"unparsable source in {path}")
    buckets = _classify_source_lines(nodes, source)
    seen: dict[int, str] = {}
    for bucket, numbers in buckets.items():
        for number in numbers:
            if number in seen:
                raise ScanError(f"line {number} classified twice in {path}")
            seen[number] = bucket
    comments = _annotation_comments(nodes)
    findings = (
        _nil_findings(nodes, path, source)
        + _annotation_findings(comments, path, source)
        + _dispatch_findings(nodes, path, source)
    )
    row = {
        "path": path,
        "sourceSha256": hashlib.sha256(source).hexdigest(),
        "sloc": buckets,
    }
    return row, findings


def scan_sources(
    repository_root: Path | str, manifest_paths: list[str]
) -> tuple[list[dict], list[dict], str]:
    """Scan every manifest path against its on-disk source root.

    Returns (source rows, findings, full HEAD commit). Raises ScanError or
    ValueError without side effects on any invalid input.
    """
    root = codehealth_scope._resolve_repository_root(Path(repository_root))
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ScanError(f"cannot resolve source commit: {error}") from error
    commit = completed.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ScanError(f"invalid source commit {commit!r}")
    if manifest_paths:
        # Reject staged edits to exactly the manifest paths before any
        # source URL is built; unrelated working-tree or index changes
        # outside the manifest never block the scan.
        def _staged_difference(relative: str) -> bool:
            try:
                probe = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(root),
                        "diff",
                        "--cached",
                        "--quiet",
                        commit,
                        "--",
                        f":(literal){relative}",
                    ],
                    check=False,
                    capture_output=True,
                )
            except OSError as error:
                raise ScanError(
                    f"cannot check staged sources: {error}"
                ) from error
            if probe.returncode == 1:
                return True
            if probe.returncode != 0:
                raise ScanError(
                    f"cannot check staged sources: {probe.stderr.decode('utf-8', 'replace').strip()}"
                )
            return False

        try:
            staged = subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "diff",
                    "--cached",
                    "--quiet",
                    commit,
                    "--",
                    *(f":(literal){relative}" for relative in manifest_paths),
                ],
                check=False,
                capture_output=True,
            )
        except OSError as error:
            raise ScanError(f"cannot check staged sources: {error}") from error
        if staged.returncode == 1:
            # Name the offending manifest source for the diagnosis.
            culprit = next(
                (relative for relative in manifest_paths if _staged_difference(relative)),
                manifest_paths[0],
            )
            raise ScanError(f"staged changes to scanned source: {culprit!r}")
        if staged.returncode != 0:
            raise ScanError(
                f"cannot check staged sources: {staged.stderr.decode('utf-8', 'replace').strip()}"
            )
    lang = _language()
    rows: list[dict] = []
    findings: list[dict] = []
    for relative in manifest_paths:
        target = root / relative
        if target.is_symlink():
            raise ScanError(f"refusing symlinked source {relative!r}")
        resolved = target.resolve()
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ScanError(
                f"source escapes repository root: {relative!r}"
            ) from error
        try:
            data = resolved.read_bytes()
        except OSError as error:
            raise ScanError(f"cannot read source {relative!r}: {error}") from error
        if not resolved.is_file():
            raise ScanError(f"source is not a file: {relative!r}")
        # The emitted commit-pinned URL is only honest when these exact
        # bytes equal the committed blob; compare the same buffer that is
        # scanned so a concurrent edit cannot swap it underneath us.
        try:
            shown = subprocess.run(
                ["git", "-C", str(root), "show", f"{commit}:{relative}"],
                check=False,
                capture_output=True,
            )
        except OSError as error:
            raise ScanError(
                f"cannot read HEAD source {relative!r}: {error}"
            ) from error
        if shown.returncode != 0 or shown.stdout != data:
            raise ScanError(f"source does not match HEAD: {relative}")
        row, file_findings = scan_file(relative, data, lang)
        prefix = f"{REPOSITORY_URL_PREFIX}{commit}/{relative}#L"
        for finding in file_findings:
            if finding["startLine"] == finding["endLine"]:
                finding["sourceUrl"] = f"{prefix}{finding['startLine']}"
            else:
                finding["sourceUrl"] = (
                    f"{prefix}{finding['startLine']}-L{finding['endLine']}"
                )
        rows.append(row)
        findings.extend(file_findings)
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
    identifiers = [finding["id"] for finding in findings]
    if len(set(identifiers)) != len(identifiers):
        raise ScanError("duplicate observation identities")
    return rows, findings, commit


def _write_stage_files(
    output_dir: Path,
    rows: list[dict],
    findings: list[dict],
    commit: str,
    manifest_sha: str,
) -> None:
    counts = {rule_id: 0 for rule_id, _ in RULES}
    for finding in findings:
        if finding["ruleId"] not in counts:
            raise ScanError(f"unknown observation family {finding['ruleId']!r}")
        counts[finding["ruleId"]] += 1
    rules = {
        "schemaVersion": 1,
        "commit": commit,
        "manifestSha256": manifest_sha,
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
            for rule_id, group in RULES
        ],
    }

    def _dump(value) -> str:
        return json.dumps(value, sort_keys=True, allow_nan=False, ensure_ascii=False)

    output_dir.mkdir(parents=True, exist_ok=True)
    # Stage beside the final files so the publish renames never cross
    # filesystems.
    with tempfile.TemporaryDirectory(dir=output_dir) as staging:
        stage = Path(staging)
        with (stage / "source.jsonl").open("w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(_dump(row) + "\n")
        with (stage / "findings.jsonl").open("w", encoding="utf-8") as handle:
            for finding in findings:
                handle.write(_dump(finding) + "\n")
        with (stage / "rules.json").open("w", encoding="utf-8") as handle:
            handle.write(_dump(rules) + "\n")
        # Independent reload: the staged bytes must already satisfy the
        # consumer contract before anything is published.
        for name in ("source.jsonl", "findings.jsonl", "rules.json"):
            (stage / name).read_bytes()
        reloaded = json.loads((stage / "rules.json").read_text(encoding="utf-8"))
        if reloaded != rules:
            raise ScanError("staged summary failed to round-trip")
        for name in ("source.jsonl", "findings.jsonl", "rules.json"):
            os.replace(stage / name, output_dir / name)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Scan structural Lua sources for advisory syntax signals."
    )
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        try:
            manifest_bytes = Path(args.manifest).read_bytes()
        except OSError as error:
            raise ScanError(
                f"cannot read structural manifest {args.manifest}: {error}"
            ) from error
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        try:
            manifest_paths = codehealth_scope._read_manifest_file(Path(args.manifest))
        except ValueError as error:
            raise ScanError(str(error)) from error
        rows, findings, commit = scan_sources(args.repository_root, manifest_paths)
        _write_stage_files(Path(args.output_dir), rows, findings, commit, manifest_sha)
    except (ScanError, ValueError) as error:
        print(f"lua signals: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
