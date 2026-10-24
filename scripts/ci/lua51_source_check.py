#!/usr/bin/env python3
"""Reject Lua 5.2-only source features not guaranteed by LuaJIT's 5.1 API.

StyLua's pinned Lua51 syntax parser catches general grammar differences. This
small lexer adds deterministic, line-addressed policy errors while avoiding
false positives in comments and data strings (including HGSS script opcodes).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LONG_OPEN = re.compile(r"\[(=*)\[")
NATIVE_GOTO = re.compile(r"\bgoto\s+[A-Za-z_][A-Za-z_0-9]*\b")
NATIVE_LABEL = re.compile(r"::[A-Za-z_][A-Za-z_0-9]*::")
NEWER_CALL = re.compile(
    r"\b(?:table\s*\.\s*(?:unpack|pack|move)|"
    r"string\s*\.\s*(?:pack|unpack|packsize)|"
    r"math\s*\.\s*(?:type|tointeger)|"
    r"package\s*\.\s*searchpath)\s*\("
)
HEX_ESCAPE = re.compile(r"[a-fA-F0-9]{2}")


def scan(source: str) -> list[tuple[int, str]]:
    """Return (1-based line, violation) without examining strings/comments."""
    code = list(source)
    issues: list[tuple[int, str]] = []
    n = len(source)

    def blank(begin: int, end: int) -> None:
        for pos in range(begin, end):
            if code[pos] != "\n":
                code[pos] = " "

    def line(at: int) -> int:
        return source.count("\n", 0, at) + 1

    def long_end(begin: int) -> int | None:
        opener = LONG_OPEN.match(source, begin)
        if opener is None:
            return None
        closer = "]" + opener.group(1) + "]"
        end = source.find(closer, opener.end())
        return n if end == -1 else end + len(closer)

    pos = 0
    while pos < n:
        if source.startswith("--", pos):
            until = long_end(pos + 2)
            if until is None:
                newline = source.find("\n", pos)
                until = n if newline == -1 else newline
            blank(pos, until)
            pos = until
            continue
        if source[pos] == "[":
            until = long_end(pos)
            if until is not None:
                blank(pos, until)
                pos = until
                continue
        if source[pos] in ('"', "'"):
            begin = pos
            quote = source[pos]
            pos += 1
            while pos < n:
                if source[pos] == "\\" and pos + 1 < n:
                    escape = source[pos + 1]
                    if escape == "x" and HEX_ESCAPE.match(source, pos + 2):
                        issues.append((line(pos), "Lua 5.1 has no hexadecimal escape (use \\ddd)"))
                    elif escape == "z":
                        issues.append((line(pos), "Lua 5.1 has no \\z whitespace escape"))
                    pos += 2
                elif source[pos] == quote:
                    pos += 1
                    break
                else:
                    pos += 1
            blank(begin, pos)
            continue
        pos += 1

    clean = "".join(code)
    for match in NATIVE_GOTO.finditer(clean):
        issues.append((line(match.start()), "native goto is not supported by Lua 5.1"))
    for match in NATIVE_LABEL.finditer(clean):
        issues.append((line(match.start()), "native ::label:: is not supported by Lua 5.1"))
    for match in NEWER_CALL.finditer(clean):
        issues.append((line(match.start()), "newer Lua standard-library call: " + re.sub(r"\s+", "", match.group()).rstrip("(")))
    return sorted(issues)


def main(paths: list[str]) -> int:
    violations = 0
    for path in paths:
        try:
            source = Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"invariants: {path}: {exc}", file=sys.stderr)
            violations += 1
            continue
        for line, message in scan(source):
            print(f"invariants: {path}:{line}: {message}", file=sys.stderr)
            violations += 1
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
