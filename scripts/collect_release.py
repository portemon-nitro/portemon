#!/usr/bin/env python3
"""Validate and collect the finite, versioned desktop and Android release set."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

from pack_love import validate_identity
from packaging.macos_metadata import expected_metadata


APPLICATION_ID = "io.github.portemonnitro.portemon"
FORBIDDEN_PARTS = {"roms", "saves", "cache", "references", "tests", ".agents", ".git", "icons-src", "imports", "import-output"}
FORBIDDEN_SUFFIXES = {".nds", ".sav", ".zip", ".keystore", ".jks", ".p12", ".pfx", ".pem", ".key"}
ANDROID_ABIS = {"arm64-v8a", "armeabi-v7a"}


def artifact_names(version: str) -> tuple[str, ...]:
    return (
        f"portemon-nitro-{version}.love",
        f"portemon-nitro-{version}-windows-x86_64.zip",
        f"portemon-nitro-{version}-macos-universal.zip",
        f"portemon-nitro-{version}-linux-x86_64.AppImage",
        f"portemon-nitro-{version}-android.apk",
    )


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and "\\" not in name
        and not FORBIDDEN_PARTS.intersection(path.parts)
        and path.suffix.lower() not in FORBIDDEN_SUFFIXES
    )


def inspect_payload(path: Path, version: str, commit: str) -> str:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError(f"invalid payload archive: {path.name}")
        forbidden = [name for name in names if not safe_member(name)]
        if forbidden:
            raise ValueError(f"payload contains forbidden file: {forbidden[0]}")
        identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
        found_version = re.search(r'version\s*=\s*"([^"]+)"', identity)
        found_commit = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
        if found_version is None or found_commit is None:
            raise ValueError(f"payload has no valid BuildInfo: {path.name}")
        validate_identity(found_version.group(1), found_commit.group(1))
        if (found_version.group(1), found_commit.group(1)) != (version, commit):
            raise ValueError(f"payload identity does not match release: {path.name}")
        if not {"main.lua", "conf.lua", "LICENSE"}.issubset(names):
            raise ValueError(f"payload is incomplete: {path.name}")
    return digest(path)


def zip_members(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError(f"invalid ZIP archive: {path.name}")
        forbidden = [name for name in names if not safe_member(name)]
        if forbidden:
            raise ValueError(f"{path.name} contains forbidden file: {forbidden[0]}")
        return {name: archive.read(name) for name in names}


def inspect_windows(path: Path, payload: Path) -> None:
    members = zip_members(path)
    roots = {PurePosixPath(name).parts[0] for name in members}
    if roots != {"Portemon Nitro"}:
        raise ValueError(f"{path.name} must contain one Portemon Nitro folder")
    prefix = "Portemon Nitro/"
    executables = [name for name in members if name.endswith(".exe")]
    if len(executables) != 1 or executables[0] != prefix + "Portemon Nitro.exe":
        raise ValueError(f"{path.name} must contain only the fused product executable")
    if any(name in (prefix + "love.exe", prefix + "lovec.exe") for name in members):
        raise ValueError(f"{path.name} contains an unbranded LÖVE executable")
    required = {
        prefix + "app/native/windows/x64/nfd.dll",
        prefix + "portemon-nitro.ico",
        prefix + "LICENSE",
    }
    missing = sorted(required.difference(members))
    if missing:
        raise ValueError(f"{path.name} is missing {missing[0]}")
    executable = members[executables[0]]
    wanted = payload.read_bytes()
    if len(executable) < len(wanted) or executable[-len(wanted):] != wanted:
        raise ValueError(f"{path.name} embedded payload differs from shared payload")
    if hashlib.sha256(executable[-len(wanted):]).hexdigest() != hashlib.sha256(wanted).hexdigest():
        raise ValueError(f"{path.name} embedded payload digest differs from shared payload")


def inspect_macos(path: Path, payload_hash: str, version: str) -> None:
    members = zip_members(path)
    bundle = "Portemon Nitro.app"
    resources = bundle + "/Contents/Resources/"
    required = {
        bundle + "/Contents/Info.plist",
        bundle + "/Contents/MacOS/portemon",
        resources + "game.love",
        resources + "portemon.icns",
        resources + "app/native/macos/x64/libnfd.dylib",
        resources + "app/native/macos/arm64/libnfd.dylib",
        resources + "LICENSE",
    }
    missing = sorted(required.difference(members))
    if missing:
        raise ValueError(f"{path.name} is missing {missing[0]}")
    payloads = [name for name in members if name.endswith(".love")]
    if payloads != [resources + "game.love"]:
        raise ValueError(f"{path.name} must contain exactly one product payload")
    if hashlib.sha256(members[resources + "game.love"]).hexdigest() != payload_hash:
        raise ValueError(f"{path.name} embedded payload differs from shared payload")
    info = plistlib.loads(members[bundle + "/Contents/Info.plist"])
    core = version.split("-", 1)[0].split("+", 1)[0]
    expected = expected_metadata(core)
    for key, wanted in expected.items():
        if info.get(key) != wanted:
            raise ValueError(f"{path.name} has invalid {key}")
    icons = [name for name in members if name.startswith(resources) and name.endswith(".icns")]
    if icons != [resources + "portemon.icns"]:
        raise ValueError(f"{path.name} must contain only the product icon")


def elf_squashfs_offset(data: bytes) -> int | None:
    if not data.startswith(b"\x7fELF"):
        return None
    byte_order = "<" if data[5] == 1 else ">" if data[5] == 2 else None
    if byte_order is None or data[4] != 2:
        return None
    header = struct.unpack_from(byte_order + "HHIQQQIHHHHHH", data, 16)
    section_offset, entry_size, section_count, section_names = header[5], header[10], header[11], header[12]
    if not section_offset or not section_count or entry_size < 64:
        return None
    if section_offset + entry_size * section_count > len(data):
        raise ValueError("truncated AppImage ELF section table")
    sections = [struct.unpack_from(byte_order + "IIQQQQIIQQ", data, section_offset + index * entry_size)
                for index in range(section_count)]
    if section_names >= len(sections):
        raise ValueError("invalid AppImage ELF section-name index")
    names = sections[section_names]
    table = data[names[4]:names[4] + names[5]]
    runtime_end = section_offset + entry_size * section_count
    for section in sections:
        start = section[0]
        end = table.find(b"\0", start)
        if end >= 0 and table[start:end] == b".sqfs":
            return section[4]
        if section[1] != 8:  # SHT_NOBITS occupies no file bytes.
            runtime_end = max(runtime_end, section[4] + section[5])
    # Type-2 AppImage runtimes place SquashFS immediately after the ELF
    # image, including signature and section-table metadata.
    if data[runtime_end:runtime_end + 4] == b"hsqs":
        return runtime_end
    raise ValueError("AppImage ELF runtime has no verifiable SquashFS boundary")


def squashfs_offset(path: Path) -> int:
    with path.open("rb") as handle:
        prefix = handle.read(1024 * 1024)
    if prefix.startswith(b"\x7fELF"):
        offset = elf_squashfs_offset(prefix)
        if offset is None:
            raise ValueError(f"{path.name} has no ELF runtime")
        return offset
    # Structural fixtures need not carry an executable ELF runtime. Accept a
    # candidate only when SquashFS itself validates the complete superblock.
    start = 0
    while True:
        start = prefix.find(b"hsqs", start)
        if start < 0:
            break
        result = subprocess.run(
            ["unsquashfs", "-o", str(start), "-s", str(path)],
            check=False, capture_output=True, text=True,
        )
        if result.returncode == 0:
            return start
        start += 4
    raise ValueError(f"{path.name} has no verifiable SquashFS filesystem")


def inspect_linux(path: Path, payload_hash: str) -> None:
    unsquashfs = shutil.which("unsquashfs")
    if unsquashfs is None:
        raise ValueError("unsquashfs is required to inspect the Linux AppImage")
    offset = squashfs_offset(path)
    with tempfile.TemporaryDirectory(prefix="portemon-release-appimage-") as directory:
        result = subprocess.run(
            [unsquashfs, "-no-xattrs", "-o", str(offset), "-d", directory, str(path)],
            check=False, capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise ValueError(f"cannot extract {path.name}: {result.stderr.strip()}")
        root = Path(directory)
        for relative in (
            "game.love", "app/native/linux/x64/libnfd.so", "AppRun", "portemon.desktop", "portemon.png",
            "share/pixmaps/portemon.png", ".DirIcon", "LICENSE",
        ):
            if not (root / relative).is_file():
                raise ValueError(f"{path.name} is missing {relative}")
        if (root / "portemon.png").read_bytes() != (root / ".DirIcon").read_bytes():
            raise ValueError(f"{path.name} AppDir icon differs from the product icon")
        desktop = {}
        for line in (root / "portemon.desktop").read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                desktop[key] = value
        if desktop.get("Icon") != "portemon":
            raise ValueError(f"{path.name} must set Icon=portemon in its desktop entry")
        if any((root / name).exists() for name in ("love.desktop", "love.svg", "share/pixmaps/love.svg")):
            raise ValueError(f"{path.name} contains upstream LÖVE desktop branding")
        for member in root.rglob("*"):
            relative = member.relative_to(root).as_posix()
            if not safe_member(relative):
                raise ValueError(f"{path.name} contains forbidden file: {relative}")
            if member.is_symlink():
                target = os.readlink(member)
                resolved = (member.parent / target).resolve()
                if Path(target).is_absolute() or root.resolve() not in resolved.resolve().parents or not safe_member(resolved.relative_to(root.resolve()).as_posix()):
                    raise ValueError(f"{path.name} contains an unsafe symlink: {relative}")
        if hashlib.sha256((root / "game.love").read_bytes()).hexdigest() != payload_hash:
            raise ValueError(f"{path.name} embedded payload differs from shared payload")
        apprun = (root / "AppRun").read_text()
        active = "\n".join(line for line in apprun.splitlines() if not line.lstrip().startswith("#"))
        selects_payload = (
            'FUSE_PATH="$APPDIR/game.love"' in active
            or re.search(r'["\']\$APPDIR/game\.love["\']|"\$\(dirname "\$0"\)/game\.love"', active) is not None
        )
        if not selects_payload:
            raise ValueError(f"{path.name} does not select the product payload")


def android_badging(path: Path) -> str:
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not sdk:
        raise ValueError("ANDROID_SDK_ROOT is required to verify a release APK")
    aapt2 = Path(sdk) / "build-tools" / "36.0.0" / "aapt2"
    if not aapt2.is_file():
        raise ValueError("locked Android Build Tools are required to verify a release APK")
    result = subprocess.run([str(aapt2), "dump", "badging", str(path)], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError(f"{path.name} package metadata verification failed")
    return result.stdout


def inspect_android(path: Path, payload_hash: str, version: str) -> None:
    members = zip_members(path)
    required = {"assets/game.love", "META-INF/MANIFEST.MF"}
    for abi in sorted(ANDROID_ABIS):
        required.add(f"lib/{abi}/liblove.so")
    missing = sorted(required.difference(members))
    if missing:
        raise ValueError(f"{path.name} is missing {missing[0]}")
    abis = {PurePosixPath(name).parts[1] for name in members if name.startswith("lib/") and name.endswith(".so")}
    if abis != ANDROID_ABIS:
        raise ValueError(f"{path.name} has an unexpected Android ABI set")
    if hashlib.sha256(members["assets/game.love"]).hexdigest() != payload_hash:
        raise ValueError(f"{path.name} embedded payload differs from shared payload")
    # Real release APKs always carry the binary manifest and are additionally
    # verified by platform tools. Structural fixtures use executable fake tools
    # in scripts/test_packaging.py rather than weakening this production gate.
    if "AndroidManifest.xml" not in members:
        raise ValueError(f"{path.name} is missing AndroidManifest.xml")
    badging = android_badging(path)
    if f"package: name='{APPLICATION_ID}'" not in badging:
        raise ValueError(f"{path.name} has the wrong release application ID")
    version_name = re.search(r"versionName='([^']+)'", badging)
    version_code = re.search(r"versionCode='([0-9]+)'", badging)
    if version_name is None or version_name.group(1) != version:
        raise ValueError(f"{path.name} has the wrong release version")
    if version_code is None or int(version_code.group(1)) <= 0:
        raise ValueError(f"{path.name} has an invalid versionCode")
    sdk = Path(os.environ["ANDROID_SDK_ROOT"])
    apksigner = sdk / "build-tools" / "36.0.0" / "apksigner"
    if not apksigner.is_file():
        raise ValueError("apksigner is required to verify a release APK")
    verified = subprocess.run(
        [str(apksigner), "verify", "--verbose", "--print-certs", str(path)],
        check=False, capture_output=True, text=True,
    )
    if verified.returncode != 0 or "certificate SHA-256 digest:" not in verified.stdout:
        raise ValueError(f"{path.name} release signature verification failed")
    certificate = re.search(r"certificate SHA-256 digest: ([0-9a-fA-F]+)", verified.stdout)
    if certificate is None:
        raise ValueError(f"{path.name} did not report a signing certificate")
    print(f"collect_release: android versionCode={version_code.group(1)} certificate={certificate.group(1).lower()}")


def collect(inputs: Path, output: Path, version: str, commit: str) -> None:
    validate_identity(version, commit)
    if version == "dev":
        raise ValueError("release version must be a complete semantic version")
    expected = artifact_names(version)
    if not inputs.is_dir():
        raise ValueError(f"input directory does not exist: {inputs}")
    actual = {path.name for path in inputs.iterdir()}
    missing = sorted(set(expected).difference(actual))
    unexpected = sorted(actual.difference(expected))
    if missing or unexpected:
        details = ([f"missing {name}" for name in missing] + [f"unexpected {name}" for name in unexpected])
        raise ValueError("incomplete release input set: " + ", ".join(details))
    if any(not (inputs / name).is_file() or (inputs / name).is_symlink() for name in expected):
        raise ValueError("release inputs must be regular files")
    if inputs.resolve() == output.resolve() or inputs.resolve() in output.resolve().parents or output.resolve() in inputs.resolve().parents:
        raise ValueError("release output must be outside the immutable input directory")
    if output.is_symlink() or (output.exists() and not output.is_dir()):
        raise ValueError("release output must be a directory")
    backup = output.with_name(output.name + ".previous")
    if backup.exists():
        if output.exists():
            raise ValueError("both release output and its recovery backup exist")
        os.replace(backup, output)

    payload_hash = inspect_payload(inputs / expected[0], version, commit)
    inspect_windows(inputs / expected[1], inputs / expected[0])
    inspect_macos(inputs / expected[2], payload_hash, version)
    inspect_linux(inputs / expected[3], payload_hash)
    inspect_android(inputs / expected[4], payload_hash, version)

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    promoted = False
    try:
        for name in expected:
            shutil.copyfile(inputs / name, staging / name)
            if name.endswith(".AppImage"):
                (staging / name).chmod(0o755)
        checksums = "".join(f"{digest(staging / name)}  {name}\n" for name in sorted(expected))
        (staging / "SHA256SUMS").write_text(checksums, encoding="utf-8", newline="\n")
        if {path.name for path in staging.iterdir()} != {*expected, "SHA256SUMS"}:
            raise ValueError("release staging set is incomplete")
        if output.exists():
            os.replace(output, backup)
        try:
            os.replace(staging, output)
            promoted = True
        except BaseException:
            if backup.exists() and not output.exists():
                os.replace(backup, output)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if not promoted:
            shutil.rmtree(staging, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        collect(args.input.resolve(), args.output.resolve(), args.version, args.commit)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException,
            subprocess.SubprocessError, struct.error) as error:
        print(f"collect_release: {error}", file=sys.stderr)
        return 1
    print(f"collect_release: wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
