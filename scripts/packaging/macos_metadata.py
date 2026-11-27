#!/usr/bin/env python3
"""Set and verify the fixed macOS bundle metadata used by the release builder."""

from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import sys


APPLICATION_ID = "io.github.portemonnitro.portemon"
PRODUCT_NAME = "Portémon Nitro"


def expected_metadata(version: str) -> dict[str, str]:
    return {
        "CFBundleIdentifier": APPLICATION_ID,
        "CFBundleName": PRODUCT_NAME,
        "CFBundleDisplayName": PRODUCT_NAME,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleExecutable": "portemon",
        "CFBundleIconFile": "portemon",
    }


def write_metadata(path: Path, version: str) -> None:
    info = plistlib.loads(path.read_bytes())
    if not isinstance(info, dict):
        raise ValueError("Info.plist root must be a dictionary")
    info.update(expected_metadata(version))
    info["UTExportedTypeDeclarations"] = [{
        "UTTypeIdentifier": "io.github.portemonnitro.nds-rom",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": {"public.filename-extension": ["nds"]},
    }]
    path.write_bytes(plistlib.dumps(info, sort_keys=False))


def verify_metadata(path: Path, version: str) -> None:
    info = plistlib.loads(path.read_bytes())
    if not isinstance(info, dict):
        raise ValueError("Info.plist root must be a dictionary")
    for key, wanted in expected_metadata(version).items():
        if info.get(key) != wanted:
            raise ValueError(f"invalid {key}")
    declarations = info.get("UTExportedTypeDeclarations")
    if not isinstance(declarations, list) or len(declarations) != 1:
        raise ValueError("invalid UTExportedTypeDeclarations")
    declaration = declarations[0]
    if (
        not isinstance(declaration, dict)
        or declaration.get("UTTypeIdentifier") != "io.github.portemonnitro.nds-rom"
        or declaration.get("UTTypeConformsTo") != ["public.data"]
        or declaration.get("UTTypeTagSpecification") != {"public.filename-extension": ["nds"]}
    ):
        raise ValueError("invalid exported NDS UTI")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.verify:
            verify_metadata(args.plist, args.version)
        else:
            write_metadata(args.plist, args.version)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"macos_metadata: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
