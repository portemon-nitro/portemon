#!/usr/bin/env python3
"""Build the pinned NFDe 1.3.0 C ABI for the finite desktop release targets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request


REPO_ROOT = Path(__file__).resolve().parents[2]
PINS = REPO_ROOT / "scripts" / "packaging" / "pins.json"
SYMBOLS = ("NFD_Init", "NFD_Quit", "NFD_OpenDialogU8", "NFD_FreePathU8", "NFD_GetError")
TARGETS = {
    "windows": ("x64",),
    "macos": ("x64", "arm64"),
    "linux": ("x64",),
}


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def fetch_verified(url: str, wanted: str, target: Path) -> None:
    temporary = target.with_name(target.name + ".download")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        if sha256(temporary) != wanted:
            raise ValueError(f"download checksum mismatch for {url}")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def source_tree(cache: Path, pin: dict[str, object]) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    archive_pin = pin["archive"]
    assert isinstance(archive_pin, dict)
    wanted = archive_pin["value"]
    assert isinstance(wanted, str)
    archive = cache / f"nfde-{pin['commit']}.tar.gz"
    if not archive.is_file():
        fetch_verified(str(pin["url"]), wanted, archive)
    if sha256(archive) != wanted:
        raise ValueError("cached NFDe source checksum mismatch")
    stage = Path(tempfile.mkdtemp(prefix="nfde-source-", dir=cache))
    try:
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(stage)], check=True)
        source = stage / f"nativefiledialog-extended-{pin['commit']}"
        if not (source / "CMakeLists.txt").is_file():
            raise ValueError("unexpected NFDe source archive layout")
        return source
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def run(command: list[str]) -> None:
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        raise ValueError("NFDe build command failed: " + " ".join(command))


def configure(source: Path, build: Path, target: str, arch: str, standard: str) -> list[str]:
    common = [
        "cmake", "-S", str(source), "-B", str(build),
        "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=ON",
        "-DNFD_BUILD_TESTS=OFF", "-DNFD_BUILD_SDL2_TESTS=OFF", "-DNFD_INSTALL=OFF",
        "-DCMAKE_CXX_STANDARD=" + standard, "-DCMAKE_CXX_STANDARD_REQUIRED=ON",
    ]
    if target == "windows":
        return [*common, "-G", "Visual Studio 17 2022", "-A", "x64",
                "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
    if target == "macos":
        cmake_arch = "x86_64" if arch == "x64" else arch
        return [*common, f"-DCMAKE_OSX_ARCHITECTURES={cmake_arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=10.11"]
    return [*common, "-DNFD_PORTAL=ON"]


def build_library(source: Path, build: Path, target: str, arch: str, standard: str) -> Path:
    run(configure(source, build, target, arch, standard))
    run(["cmake", "--build", str(build), "--config", "Release", "--parallel", str(os.cpu_count() or 1)])
    if target == "windows":
        candidates = [build / "src" / "Release" / "nfd.dll"]
    elif target == "macos":
        candidates = [build / "src" / "libnfd.1.3.0.dylib"]
    else:
        candidates = [build / "src" / "libnfd.so.1.3.0"]
    existing = [path for path in candidates if path.is_file()]
    if len(existing) != 1:
        raise ValueError(f"NFDe {target}/{arch} build omitted its shared library")
    return existing[0]


def verify_symbols(library: Path, target: str) -> None:
    if target == "windows":
        command = ["dumpbin", "/exports", str(library)]
    elif target == "macos":
        command = ["nm", "-gU", str(library)]
    else:
        command = ["nm", "-D", "--defined-only", str(library)]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError(f"cannot inspect NFDe exports for {library.name}: {result.stderr.strip()}")
    missing = [symbol for symbol in SYMBOLS if symbol not in result.stdout]
    if missing:
        raise ValueError(f"NFDe library is missing C ABI symbol {missing[0]}")


def verify_architecture(library: Path, target: str, wanted: set[str]) -> None:
    if target == "windows":
        result = subprocess.run(["dumpbin", "/headers", str(library)], check=False, capture_output=True, text=True)
        if result.returncode != 0 or "x64" not in result.stdout:
            raise ValueError("NFDe Windows library is not x64")
        dependencies = subprocess.run(
            ["dumpbin", "/dependents", str(library)], check=False, capture_output=True, text=True
        )
        if dependencies.returncode != 0 or any(
            name in dependencies.stdout.lower() for name in ("vcruntime", "msvcp")
        ):
            raise ValueError("NFDe Windows library must use the statically linked VC runtime")
        return
    if target == "macos":
        result = subprocess.run(["lipo", "-archs", str(library)], check=False, capture_output=True, text=True)
        if result.returncode != 0 or set(result.stdout.split()) != {"x86_64" if arch == "x64" else arch for arch in wanted}:
            raise ValueError(f"NFDe macOS library has wrong architectures: {result.stdout.strip()}")
        return
    result = subprocess.run(["readelf", "-h", str(library)], check=False, capture_output=True, text=True)
    if result.returncode != 0 or "X86-64" not in result.stdout:
        raise ValueError("NFDe Linux library is not x86_64")


def stage_library(library: Path, staging: Path, target: str, arch: str) -> None:
    directory = staging / target / arch if target == "macos" else staging
    directory.mkdir(parents=True, exist_ok=True)
    name = {"windows": "nfd.dll", "linux": "libnfd.so", "macos": "libnfd.dylib"}[target]
    shutil.copyfile(library, directory / name)


def build(output: Path, target: str) -> None:
    if target not in TARGETS:
        raise ValueError("platform must be windows, macos, or linux")
    pins = json.loads(PINS.read_text())
    pin = pins["nfde"]
    host = platform.system()
    expected_host = {"windows": "Windows", "macos": "Darwin", "linux": "Linux"}[target]
    if host != expected_host:
        raise ValueError(f"NFDe {target} builds require {expected_host}")
    if target == "linux" and platform.machine() != "x86_64":
        raise ValueError("NFDe Linux release builds require x86_64")
    for command in ("cmake", "tar"):
        if shutil.which(command) is None:
            raise ValueError(f"required NFDe build tool is missing: {command}")
    cmake = subprocess.run(["cmake", "--version"], check=True, capture_output=True, text=True).stdout
    version = cmake.splitlines()[0].split()[-1]
    minimum = tuple(int(part) for part in pin["cmake_minimum"].split("."))
    if tuple(int(part) for part in version.split(".")[:2]) < minimum:
        raise ValueError(f"NFDe requires CMake {pin['cmake_minimum']} or newer")

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.is_symlink() or (output.exists() and not output.is_dir()):
        raise ValueError("NFDe output must be a directory")
    backup = output.with_name(output.name + ".previous")
    if backup.exists():
        if output.exists():
            raise ValueError("both NFDe output and its recovery backup exist")
        os.replace(backup, output)
    cache = Path(os.environ.get("PORTEMON_BUILD_CACHE", REPO_ROOT / ".agents/tmp/portemon-release/cache"))
    source = source_tree(cache, pin)
    temporary = Path(tempfile.mkdtemp(prefix="nfde-build-", dir=cache))
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging.", dir=output.parent))
    promoted = False
    try:
        for arch in TARGETS[target]:
            library = build_library(source, temporary / f"build-{arch}", target, arch, pin["cxx_standard"])
            verify_symbols(library, target)
            verify_architecture(library, target, {arch})
            stage_library(library, staging, target, arch)
        if target == "macos":
            slices = [staging / "macos" / arch / "libnfd.dylib" for arch in TARGETS[target]]
            universal = staging / "macos" / "universal" / "libnfd.dylib"
            universal.parent.mkdir(parents=True, exist_ok=True)
            run(["lipo", "-create", *(str(path) for path in slices), "-output", str(universal)])
            verify_symbols(universal, target)
            verify_architecture(universal, target, set(TARGETS[target]))
        license_source = source / "LICENSE"
        if sha256(license_source) != pin["license"]["value"]:
            raise ValueError("NFDe source license checksum mismatch")
        shutil.copyfile(license_source, staging / "LICENSE")
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
        shutil.rmtree(temporary, ignore_errors=True)
        shutil.rmtree(source.parent, ignore_errors=True)
        if not promoted:
            shutil.rmtree(staging, ignore_errors=True)
            if backup.exists() and not output.exists():
                os.replace(backup, output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=tuple(TARGETS))
    parser.add_argument("--arch", required=True, choices=("x64", "universal"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    expected_arch = "universal" if args.platform == "macos" else "x64"
    if args.arch != expected_arch:
        parser.error(f"--platform {args.platform} requires --arch {expected_arch}")
    try:
        build(args.output.resolve(), args.platform)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"build_nfd: {error}", file=sys.stderr)
        return 1
    print(f"build_nfd: wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
