#!/usr/bin/env python3
"""Build one deterministic, ROM-independent LÖVE source payload."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile


SOURCE_TREES = (
    "app/src",
    "game/src",
    "game/hgss/src",
    "romdump/src",
    "data/manifests",
    "data/scripts/manifests",
    "data/scripts/overrides",
)
FONT_FILES = (
    "assets/fonts/galmuri/Galmuri11.ttf",
    "assets/fonts/galmuri/Galmuri11-Bold.ttf",
    "assets/fonts/galmuri/LICENSE.txt",
    "assets/fonts/mplus1p/MPLUS1p-Regular.ttf",
    "assets/fonts/mplus1p/OFL.txt",
)
ICON_FILES = tuple(
    f"assets/ui/launcher/icons/{name}.png"
    for name in ("add-game", "back", "check", "close", "play", "warning")
) + ("assets/ui/launcher/LICENSE.txt",)
BRANDING_FILES = (
    "assets/branding/portemon-nitro.png",
    "assets/branding/portemon-nitro.ico",
    "assets/branding/portemon-nitro.icns",
)
AUDIO_FILES = tuple(
    f"assets/audio/launcher/{name}.ogg" for name in ("boot", "focus", "confirm", "back", "error")
) + ("assets/audio/launcher/README.md",)
REQUIRED_FILES = (
    "app/main.lua",
    "app/conf.lua",
    "LICENSE",
    "app/src/BuildInfo.lua",
    "gen4/script.lua",
    "gen4/battle.lua",
    *FONT_FILES,
    *ICON_FILES,
    *BRANDING_FILES,
    *AUDIO_FILES,
)
SEMVER_IDENTIFIER = r"[0-9A-Za-z-]+"
SEMVER_NUMBER = r"(?:0|[1-9][0-9]*)"
SEMVER_PRERELEASE = rf"(?:{SEMVER_NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = re.compile(
    rf"{SEMVER_NUMBER}\.{SEMVER_NUMBER}\.{SEMVER_NUMBER}"
    rf"(?:-{SEMVER_PRERELEASE}(?:\.{SEMVER_PRERELEASE})*)?"
    rf"(?:\+{SEMVER_IDENTIFIER}(?:\.{SEMVER_IDENTIFIER})*)?"
)
COMMIT = re.compile(r"[0-9a-f]{40}")
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def source_files(root: Path) -> list[str]:
    names = {"main.lua", "conf.lua"}
    for tree in SOURCE_TREES:
        base = root / tree
        if not base.is_dir():
            raise ValueError(f"required runtime source tree is missing: {tree}")
        for path in base.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"runtime source must be a regular file: {path.relative_to(root).as_posix()}")
            if path.is_file():
                names.add(path.relative_to(root).as_posix())
    libraries = root / "libs"
    if not libraries.is_dir():
        raise ValueError("required runtime library tree is missing: libs")
    for library in sorted(libraries.glob("*/src")):
        if not library.is_dir():
            continue
        for path in library.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"runtime source must be a regular file: {path.relative_to(root).as_posix()}")
            if path.is_file():
                names.add(path.relative_to(root).as_posix())
    names.update(REQUIRED_FILES[2:])
    names.difference_update(("app/main.lua", "app/conf.lua"))
    branding = root / "assets" / "branding"
    if branding.is_dir():
        for path in branding.rglob("*"):
            if path.is_file() and not path.is_symlink() and path.suffix.lower() in (".png", ".ico", ".icns"):
                names.add(path.relative_to(root).as_posix())
    return sorted(names)


def validate_identity(version: str, commit: str) -> None:
    if version != "dev" and VERSION.fullmatch(version) is None:
        raise ValueError("version must be dev or a complete semantic version")
    if COMMIT.fullmatch(commit) is None:
        raise ValueError("commit must be a full 40-character lowercase source SHA")


def build_identity(version: str, commit: str) -> bytes:
    return f'-- Immutable installed source identity; release packaging stamps a staging copy.\n\nreturn {{ version = "{version}", commit = "{commit}" }}\n'.encode()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def build(root: Path, output: Path, listing: Path | None, version: str, commit: str) -> None:
    validate_identity(version, commit)
    if listing is not None and listing.resolve() == output.resolve():
        raise ValueError("payload output and listing must be different files")
    names = source_files(root)
    for relative in REQUIRED_FILES:
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"required runtime source is missing: {relative}")

    def member_bytes(relative: str) -> bytes:
        if relative == "app/src/BuildInfo.lua":
            return build_identity(version, commit)
        source = "app/" + relative if relative in ("main.lua", "conf.lua") else relative
        return (root / source).read_bytes()

    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for relative in names:
                data = member_bytes(relative)
                info = zipfile.ZipInfo(relative, FIXED_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        with zipfile.ZipFile(temporary) as archive:
            if archive.namelist() != names or archive.testzip() is not None:
                raise ValueError("payload verification failed")
            for relative in ("main.lua", "conf.lua", *REQUIRED_FILES[2:]):
                if relative not in archive.namelist():
                    raise ValueError(f"payload verification omitted {relative}")
            identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
            if f'version = "{version}"' not in identity or f'commit = "{commit}"' not in identity:
                raise ValueError("payload identity verification failed")
        os.replace(temporary, output)
        if listing is not None:
            listing.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(listing, ("\n".join(names) + "\n").encode("utf-8"))
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--listing", type=Path)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        build(root, args.output.resolve(), args.listing.resolve() if args.listing else None, args.version, args.commit)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"pack_love: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
