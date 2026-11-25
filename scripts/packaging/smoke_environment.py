#!/usr/bin/env python3
"""Define owned user-data roots for packaged desktop smoke processes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def environment(platform: str, root: Path) -> dict[str, str]:
    if platform not in {"linux", "macos", "windows"}:
        raise ValueError("platform must be linux, macos, or windows")
    root = root.resolve()
    data = str(root / "data")
    if platform == "linux":
        return {
            "HOME": str(root / "home"),
            "XDG_DATA_HOME": data,
            "XDG_CACHE_HOME": str(root / "cache"),
            "PORTEMON_SAVE_DIR": data,
        }
    if platform == "macos":
        return {"HOME": str(root / "home"), "PORTEMON_SAVE_DIR": data}
    return {
        "APPDATA": str(root / "roaming"),
        "LOCALAPPDATA": str(root / "local"),
        "USERPROFILE": str(root / "home"),
        "PORTEMON_SAVE_DIR": data,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("linux", "macos", "windows"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--format", choices=("env", "json"), default="json")
    args = parser.parse_args(argv)
    values = environment(args.platform, args.root)
    if args.format == "json":
        print(json.dumps(values, sort_keys=True))
    else:
        for name, value in values.items():
            print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
