#!/usr/bin/env python3
"""Black-box portable payload and release packaging contracts."""

from __future__ import annotations

from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock
import zipfile
import zlib


REPO_ROOT = Path(__file__).resolve().parents[1]
PACKER = REPO_ROOT / "scripts" / "pack_love.py"
ANDROID_BUILDER = REPO_ROOT / "scripts" / "build_android.sh"
COLLECTOR = REPO_ROOT / "scripts" / "collect_release.py"
MACOS_METADATA = REPO_ROOT / "scripts" / "packaging" / "macos_metadata.py"
SMOKE_ENVIRONMENT = REPO_ROOT / "scripts" / "packaging" / "smoke_environment.py"
SMOKE_ENVIRONMENT_SPEC = importlib.util.spec_from_file_location(
    "portemon_smoke_environment", SMOKE_ENVIRONMENT
)
assert SMOKE_ENVIRONMENT_SPEC is not None and SMOKE_ENVIRONMENT_SPEC.loader is not None
SMOKE_ENVIRONMENT_MODULE = importlib.util.module_from_spec(SMOKE_ENVIRONMENT_SPEC)
SMOKE_ENVIRONMENT_SPEC.loader.exec_module(SMOKE_ENVIRONMENT_MODULE)
SMOKE_RUNNER = REPO_ROOT / "scripts" / "packaging" / "smoke.sh"
NFD_BUILDER = REPO_ROOT / "scripts" / "packaging" / "build_nfd.py"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
RELEASE_VERSION = "0.1.0-alpha.1"
APPIMAGE_HEADER = b"#!/bin/sh\n" + bytes(4096)
ANDROID_SIGNING_VARIABLES = (
    "PORTEMON_ANDROID_KEYSTORE",
    "PORTEMON_ANDROID_KEYSTORE_PASSWORD",
    "PORTEMON_ANDROID_KEY_ALIAS",
    "PORTEMON_ANDROID_KEY_PASSWORD",
)

SOURCE_FILES = (
    "app/main.lua",
    "app/conf.lua",
    "app/src/BuildInfo.lua",
    "gen4/script.lua",
    "gen4/battle.lua",
    "app/src/App.lua",
    "app/src/launcher/NativeRomPicker.lua",
    "game/src/WindowConfig.lua",
    "libs/storage/src/RepoFs.lua",
    "libs/nds/src/love/shaders/map.glsl",
    "romdump/src/source/RomImporter.lua",
    "data/manifests/field_presentation.lua",
    "data/scripts/manifests/overrides.lua",
    "data/scripts/overrides/common.pokecenter_pc.lua",
    "LICENSE",
)

FONT_FILES = (
    "assets/fonts/galmuri/Galmuri9.ttf",
    "assets/fonts/galmuri/Galmuri11.ttf",
    "assets/fonts/galmuri/Galmuri11-Bold.ttf",
    "assets/fonts/galmuri/LICENSE.txt",
)

LAUNCHER_FONT_FILES = (
    "assets/fonts/galmuri/Galmuri11-Bold.ttf",
    "assets/fonts/galmuri/Galmuri9.ttf",
)

LAUNCHER_ICON_FILES: tuple[str, ...] = ()
BOOT_LOGO_FILE = "assets/logo.png"
MAIN_MENU_ICON_FILES = (
    "assets/ui/mainmenu/sign-out-left.png",
    "assets/ui/mainmenu/LICENSE.phosphor.txt",
)
MAIN_MENU_ICON_SOURCE = "assets/ui/mainmenu/sign-out.svg"
OBSOLETE_LAUNCHER_FILES = tuple(
    f"assets/ui/launcher/icons/{name}.png"
    for name in ("add-game", "back", "check", "close", "play", "warning")
) + ("assets/ui/launcher/LICENSE.txt",)

CUSTOM_BRANDING_FILES = (
    "assets/branding/portemon-nitro.png",
    "assets/branding/portemon-nitro.ico",
    "assets/branding/portemon-nitro.icns",
)

AUDIO_FILES = tuple(
    f"assets/audio/launcher/{name}.ogg"
    for name in ("boot", "focus", "confirm", "back", "error")
) + ("assets/audio/launcher/README.md",)

EXCLUDED_FILES = (
    "assets/ui/launcher/icons-src/source.svg",
    "assets/not-allowlisted/private.txt",
    "references/ds/crop.png",
    "tests/unit.lua",
    ".agents/tmp/private.txt",
    ".git/config",
    "app/native/linux/x64/libnfd.so",
    "data/generated/catalog.lua",
    "roms/0123456789abcdef0123456789abcdef01234567.zip",
    "saves/heartgold/field-session.lua",
    "cache/heartgold/cache.zip",
)


def write_file(root: Path, relative: str, data: bytes) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def fixture_png(width: int, height: int) -> bytes:
    """A decodable RGBA fixture so the archive probe can exercise real image decode."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(
            ">I", zlib.crc32(kind + data) & 0xFFFFFFFF
        )

    scanlines = b"".join(b"\x00" + b"\x00\x00\x00\x00" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(scanlines))
        + chunk(b"IEND", b"")
    )


def make_fixture(root: Path) -> None:
    for tree in (
        "app/src", "game/src", "game/hgss/src", "romdump/src", "data/manifests",
        "data/scripts/manifests", "data/scripts/overrides",
    ):
        (root / tree).mkdir(parents=True, exist_ok=True)
    for relative in SOURCE_FILES:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO_ROOT / relative, target)
    for relative in FONT_FILES + OBSOLETE_LAUNCHER_FILES + CUSTOM_BRANDING_FILES:
        write_file(root, relative, b"isolated packaging fixture\n")
    write_file(root, BOOT_LOGO_FILE, fixture_png(451, 115))
    for relative in MAIN_MENU_ICON_FILES:
        write_file(root, relative, fixture_png(20, 20) if relative.endswith(".png") else b"MIT fixture notice\n")
    write_file(root, MAIN_MENU_ICON_SOURCE, b"source-only fixture\n")
    for relative in AUDIO_FILES:
        write_file(root, relative, b"TEST FIXTURE; synthetic bytes; not release provenance\n")
    for relative in EXCLUDED_FILES:
        write_file(root, relative, b"must not ship\n")
    if PACKER.is_file():
        target = root / "scripts" / "pack_love.py"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PACKER, target)


def release_artifacts(version: str) -> tuple[str, ...]:
    return (
        f"portemon-nitro-{version}.love",
        f"portemon-nitro-{version}-windows-x86_64.zip",
        f"portemon-nitro-{version}-macos-universal.zip",
        f"portemon-nitro-{version}-linux-x86_64.AppImage",
        f"portemon-nitro-{version}-android.apk",
    )


def write_zip(path: Path, members: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in members.items():
            executable = name.endswith("AppRun") or ".app/Contents/MacOS/" in name
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)


def make_payload(root: Path, *, version: str = RELEASE_VERSION, commit: str = COMMIT) -> Path:
    source = root / "source"
    make_fixture(source)
    output = root / f"portemon-nitro-{version}.love"
    listing = root / "listing.txt"
    result = run_packer(source, output, listing, version=version, commit=commit)
    if result.returncode != 0:
        raise RuntimeError(f"packaging fixture could not build its payload: {result.stderr}")
    return output


def payload_with_members(payload: Path, members: dict[str, bytes]) -> Path:
    descriptor, temporary_name = tempfile.mkstemp(prefix="payload-variant-", suffix=".love")
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(payload) as source, zipfile.ZipFile(temporary, "w") as archive:
            for info in source.infolist():
                archive.writestr(info, source.read(info.filename))
            for name, data in members.items():
                archive.writestr(name, data)
        return temporary
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def write_windows_artifact(path: Path, payload: Path, extra: dict[str, bytes] | None = None) -> None:
    folder = "Portemon Nitro"
    members = {
        f"{folder}/Portemon Nitro.exe": b"MZ synthetic runtime\n" + payload.read_bytes(),
        f"{folder}/app/native/windows/x64/nfd.dll": b"synthetic nfd x64\n",
        f"{folder}/LICENSE": b"fixture license\n",
    }
    members.update({f"{folder}/{name}": data for name, data in (extra or {}).items()})
    write_zip(path, members)


def write_macos_artifact(
    path: Path, payload: Path, version: str, extra: dict[str, bytes] | None = None
) -> None:
    bundle = "Portemon Nitro.app"
    core = version.split("-", 1)[0].split("+", 1)[0]
    info = plistlib.dumps(
        {
            "CFBundleIdentifier": "io.github.portemonnitro.portemon",
            "CFBundleName": "Portémon Nitro",
            "CFBundleShortVersionString": core,
            "CFBundleVersion": core,
            "CFBundleDisplayName": "Portémon Nitro",
            "CFBundleExecutable": "portemon",
            "CFBundleIconFile": "portemon",
        }
    )
    members = {
        f"{bundle}/Contents/Info.plist": info,
        f"{bundle}/Contents/MacOS/portemon": b"synthetic universal runtime\n",
        f"{bundle}/Contents/Resources/game.love": payload.read_bytes(),
        f"{bundle}/Contents/Resources/portemon.icns": b"synthetic upstream shell artwork\n",
        f"{bundle}/Contents/Resources/app/native/macos/x64/libnfd.dylib": b"synthetic nfd x64\n",
        f"{bundle}/Contents/Resources/app/native/macos/arm64/libnfd.dylib": b"synthetic nfd arm64\n",
        f"{bundle}/Contents/Resources/LICENSE": b"fixture license\n",
    }
    members.update({f"{bundle}/Contents/Resources/{name}": data for name, data in (extra or {}).items()})
    write_zip(path, members)


def write_linux_artifact(
    path: Path, payload: Path, extra: dict[str, bytes] | None = None, omit: set[str] | None = None
) -> None:
    mksquashfs = shutil.which("mksquashfs")
    if mksquashfs is None:
        raise RuntimeError("mksquashfs is required for the synthetic AppImage fixture")
    with tempfile.TemporaryDirectory(prefix="portemon-appimage-fixture-") as directory:
        root = Path(directory)
        appdir = root / "AppDir"
        files = {
            "game.love": payload.read_bytes(),
            "app/native/linux/x64/libnfd.so": b"synthetic nfd x64\n",
            "AppRun": b'#!/bin/sh\nexec "$(dirname "$0")/love" "$(dirname "$0")/game.love"\n',
            "portemon.desktop": (
                "[Desktop Entry]\nName=Portémon Nitro\nExec=AppRun\nType=Application\n"
                "Icon=portemon\nTerminal=false\n"
            ).encode(),
            "portemon.png": b"synthetic upstream shell artwork\n",
            "share/pixmaps/portemon.png": b"synthetic upstream shell artwork\n",
            "share/icons/hicolor/256x256/apps/portemon.png": b"synthetic upstream shell artwork\n",
            "LICENSE": b"fixture license\n",
        }
        files.update(extra or {})
        for relative, data in files.items():
            if omit and relative in omit:
                continue
            target = appdir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (appdir / "AppRun").chmod(0o755)
        (appdir / ".DirIcon").symlink_to("portemon.png")
        squashfs = root / "root.squashfs"
        result = subprocess.run(
            [mksquashfs, str(appdir), str(squashfs), "-noappend", "-all-root", "-no-progress"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"synthetic AppImage fixture failed: {result.stderr}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(APPIMAGE_HEADER + squashfs.read_bytes())
        path.chmod(0o755)


def make_android_sdk(root: Path, version: str) -> Path:
    sdk = root / "android-sdk"
    tools = sdk / "build-tools" / "36.0.0"
    tools.mkdir(parents=True, exist_ok=True)
    aapt2 = tools / "aapt2"
    aapt2.write_text(
        "#!/bin/sh\n"
        "cat <<'EOF'\n"
        "package: name='io.github.portemonnitro.portemon'\n"
        f"versionCode='42'\nversionName='{version}'\n"
        "EOF\n",
        encoding="utf-8",
    )
    apksigner = tools / "apksigner"
    apksigner.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' 'certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'\n",
        encoding="utf-8",
    )
    aapt2.chmod(0o755)
    apksigner.chmod(0o755)
    return sdk


def write_android_artifact(path: Path, payload: Path, extra: dict[str, bytes] | None = None) -> None:
    members = {
        "assets/game.love": payload.read_bytes(),
        "AndroidManifest.xml": b"synthetic binary manifest fixture\n",
        "lib/arm64-v8a/liblove.so": b"synthetic arm64 runtime\n",
        "lib/armeabi-v7a/liblove.so": b"synthetic armv7 runtime\n",
        "META-INF/MANIFEST.MF": b"Manifest-Version: 1.0\n\n",
    }
    members.update(extra or {})
    write_zip(path, members)


def write_release_artifacts(
    directory: Path,
    payload: Path,
    *,
    version: str = RELEASE_VERSION,
    extras: dict[str, dict[str, bytes]] | None = None,
) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    names = release_artifacts(version)
    shutil.copyfile(payload, directory / names[0])
    write_windows_artifact(directory / names[1], payload, (extras or {}).get(names[1]))
    write_macos_artifact(directory / names[2], payload, version, (extras or {}).get(names[2]))
    write_linux_artifact(directory / names[3], payload, (extras or {}).get(names[3]))
    write_android_artifact(directory / names[4], payload, (extras or {}).get(names[4]))


def make_release_fixture(root: Path, *, version: str = RELEASE_VERSION) -> tuple[Path, Path]:
    payload = make_payload(root, version=version)
    inputs = root / "inputs"
    write_release_artifacts(inputs, payload, version=version)
    make_android_sdk(root, version)
    return payload, inputs


def run_collector(
    inputs: Path, output: Path, *, version: str = RELEASE_VERSION, commit: str = COMMIT
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["ANDROID_SDK_ROOT"] = str(inputs.parent / "android-sdk")
    return subprocess.run(
        [
            sys.executable,
            str(COLLECTOR),
            "--version",
            version,
            "--commit",
            commit,
            "--input",
            str(inputs),
            "--output",
            str(output),
        ],
        cwd=REPO_ROOT,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )


def omit_zip_members(path: Path, omitted: set[str]) -> None:
    with zipfile.ZipFile(path) as archive:
        members = {name: archive.read(name) for name in archive.namelist() if name not in omitted}
    write_zip(path, members)


def tree_snapshot(root: Path) -> dict[str, tuple[str, int]]:
    return {
        path.relative_to(root).as_posix(): (hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode))
        for path in root.rglob("*")
        if path.is_file()
    }


def assert_embedded_payload(test: unittest.TestCase, artifact: Path, payload: Path) -> None:
    wanted = payload.read_bytes()
    if artifact.name.endswith("-windows-x86_64.zip"):
        with zipfile.ZipFile(artifact) as archive:
            executables = [name for name in archive.namelist() if name.endswith(".exe")]
            test.assertEqual(len(executables), 1)
            test.assertTrue(archive.read(executables[0]).endswith(wanted), "Windows payload bytes differ")
    elif artifact.name.endswith("-macos-universal.zip"):
        with zipfile.ZipFile(artifact) as archive:
            names = [name for name in archive.namelist() if name.endswith(".app/Contents/Resources/game.love")]
            test.assertEqual(len(names), 1)
            test.assertEqual(archive.read(names[0]), wanted, "macOS payload bytes differ")
    elif artifact.name.endswith("-linux-x86_64.AppImage"):
        unsquashfs = shutil.which("unsquashfs")
        test.assertIsNotNone(unsquashfs, "unsquashfs is required to inspect the synthetic AppImage")
        result = subprocess.run(
            [unsquashfs, "-o", str(len(APPIMAGE_HEADER)), "-cat", str(artifact), "game.love"],
            check=False,
            capture_output=True,
        )
        test.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        test.assertEqual(result.stdout, wanted, "Linux payload bytes differ")
    elif artifact.name.endswith("-android.apk"):
        with zipfile.ZipFile(artifact) as archive:
            test.assertEqual(archive.read("assets/game.love"), wanted, "Android payload bytes differ")
    else:
        test.fail(f"unknown release artifact: {artifact.name}")


def run_android(
    payload: Path,
    output: Path,
    *,
    version: str = RELEASE_VERSION,
    version_code: str | None = "1",
    release: bool = False,
    environment: dict[str, str] | None = None,
    timeout: int | None = 30,
) -> subprocess.CompletedProcess[str]:
    command = ["bash", str(ANDROID_BUILDER)]
    if release:
        command.append("--release")
    command.extend(
        [
            "--love",
            str(payload),
            "--version",
            version,
            "--output",
            str(output),
        ]
    )
    if version_code is not None:
        command.extend(["--version-code", version_code])
    env = os.environ.copy()
    for name in ANDROID_SIGNING_VARIABLES:
        env.pop(name, None)
    env.update(environment or {})
    return subprocess.run(command, cwd=REPO_ROOT, env=env, check=False, capture_output=True, text=True, timeout=timeout)


def run_packer(
    root: Path,
    output: Path,
    listing: Path,
    *,
    version: str = "1.2.3",
    commit: str = COMMIT,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(root / "scripts" / "pack_love.py"),
            "--version",
            version,
            "--commit",
            commit,
            "--output",
            str(output),
            "--listing",
            str(listing),
        ],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )


def member_digest(archive: zipfile.ZipFile) -> dict[str, str]:
    return {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()}


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def host_smoke_platform() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    raise RuntimeError(f"archive smoke has no owned user-data environment for {sys.platform}")


def archive_probe_conf(original: bytes) -> bytes:
    return original + b"\n" + textwrap.dedent(
        """\
        local packagedConf = love.conf
        function love.conf(t)
          packagedConf(t)
          t.modules.audio = false
        end
        """
    ).encode("utf-8")


def smoke_payload(payload: Path, listing: Path | None = None) -> None:
    love = os.environ.get("LOVE_BIN") or shutil.which("love")
    if love is None:
        raise RuntimeError("LÖVE 11.5 is required for archive smoke")
    version_result = subprocess.run([love, "--version"], check=True, capture_output=True, text=True)
    if "11.5" not in version_result.stdout:
        raise RuntimeError(f"archive smoke requires LÖVE 11.5, found: {version_result.stdout.strip()}")

    original_hash = hashlib.sha256(payload.read_bytes()).hexdigest()
    with zipfile.ZipFile(payload) as archive:
        names = archive.namelist()
        if names != sorted(names) or len(names) != len(set(names)):
            raise RuntimeError("archive members must be unique and sorted")
        required = {
            "main.lua",
            "conf.lua",
            "LICENSE",
            "app/src/App.lua",
            "app/src/BuildInfo.lua",
            "gen4/script.lua",
            "gen4/battle.lua",
            "app/src/launcher/NativeRomPicker.lua",
            "data/scripts/overrides/common.pokecenter_pc.lua",
            "libs/nds/src/love/shaders/map.glsl",
            *FONT_FILES,
            *AUDIO_FILES,
            BOOT_LOGO_FILE,
            *MAIN_MENU_ICON_FILES,
        }
        missing = sorted(required.difference(names))
        if missing:
            raise RuntimeError("archive is missing required members: " + ", ".join(missing))
        forbidden = ("tests/", ".agents/", ".git/", "references/", "icons-src/", "roms/", "saves/", "cache/")
        if any(name.startswith(forbidden) for name in names):
            raise RuntimeError("archive contains test, private, reference, or user data")
        if archive.testzip() is not None:
            raise RuntimeError("archive CRC verification failed")
        identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
        version_match = re.search(r'version\s*=\s*"([^"]+)"', identity)
        commit_match = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
        if version_match is None or commit_match is None:
            raise RuntimeError("archive has no valid stamped identity")
        version, commit = version_match.group(1), commit_match.group(1)
        if listing is not None and listing.read_text().splitlines() != names:
            raise RuntimeError("listing does not match archive members")
        before = member_digest(archive)

    with tempfile.TemporaryDirectory(prefix="portemon-archive-smoke-") as directory:
        root = Path(directory)
        untouched_dir = root / "untouched"
        probe_dir = root / "probe"
        cwd = root / "unrelated-cwd"
        for path in (untouched_dir, probe_dir, cwd):
            path.mkdir()
        untouched = untouched_dir / "portemon.love"
        shutil.copyfile(payload, untouched)
        owned_roots = SMOKE_ENVIRONMENT_MODULE.environment(host_smoke_platform(), root)
        for name, owned_root in owned_roots.items():
            if name != "ALSOFT_DRIVERS":
                Path(owned_root).mkdir(parents=True, exist_ok=True)
        environment = os.environ.copy()
        environment.update(owned_roots)
        environment.update(
            {
                "SDL_VIDEODRIVER": "offscreen",
                "LIBGL_ALWAYS_SOFTWARE": "1",
                "PORTEMON_SMOKE_VERSION": version,
                "PORTEMON_SMOKE_COMMIT": commit,
            }
        )
        environment.pop("LUA_PATH", None)
        environment.pop("LUA_CPATH", None)
        process = subprocess.Popen(
            [love, str(untouched)], cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            time.sleep(3)
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                raise RuntimeError(f"untouched payload exited during boot ({process.returncode}): {stdout!r} {stderr!r}")
        finally:
            stop_process(process)
        if {path.name for path in untouched_dir.iterdir()} != {"portemon.love"}:
            raise RuntimeError("untouched payload wrote beside its archive")

        probe = probe_dir / "probe.love"
        shutil.copyfile(payload, probe)
        wrapper = (REPO_ROOT / "scripts" / "packaging" / "smoke.lua").read_bytes()
        wrapped = probe_dir / "wrapped.love"
        with zipfile.ZipFile(probe) as source_archive, zipfile.ZipFile(wrapped, "w") as archive:
            for info in source_archive.infolist():
                if info.filename not in ("main.lua", "conf.lua"):
                    archive.writestr(info, source_archive.read(info.filename))
            archive.writestr("main.lua", wrapper)
            archive.writestr("conf.lua", archive_probe_conf(source_archive.read("conf.lua")))
        wrapped.replace(probe)
        result = subprocess.run(
            [love, str(probe)], cwd=cwd, env=environment, capture_output=True, text=True, timeout=45,
        )
        if result.returncode != 0 or "ARCHIVE_SMOKE_OK" not in result.stdout:
            raise RuntimeError(f"archive probe failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        marker = next(line for line in result.stdout.splitlines() if line.startswith("ARCHIVE_SMOKE_OK "))
        if {path.name for path in probe_dir.iterdir()} != {"probe.love"}:
            raise RuntimeError("archive probe wrote beside its payload")

    if hashlib.sha256(payload.read_bytes()).hexdigest() != original_hash:
        raise RuntimeError("archive smoke mutated the original payload")
    with zipfile.ZipFile(payload) as archive:
        if member_digest(archive) != before:
            raise RuntimeError("archive smoke mutated packaged members")
    print(f"archive smoke passed: {version} {commit} {original_hash}; {marker}")


ANDROID_JAVA_STUBS = {
    "android/content/Context.java": """
        package android.content;
        public class Context {
            private final ContentResolver resolver;
            public Context(ContentResolver resolver) { this.resolver = resolver; }
            public ContentResolver getContentResolver() { return resolver; }
        }
    """,
    "android/app/Activity.java": """
        package android.app;
        import android.content.ContentResolver;
        import android.content.Context;
        import android.content.Intent;
        public class Activity extends Context {
            public static final int RESULT_OK = -1;
            public static final int RESULT_CANCELED = 0;
            public Activity(ContentResolver resolver) { super(resolver); }
            public Context getApplicationContext() { return this; }
            public boolean isFinishing() { return false; }
            public void runOnUiThread(Runnable action) { action.run(); }
            public void startActivityForResult(Intent intent, int requestCode) {}
        }
    """,
    "android/content/ContentResolver.java": """
        package android.content;
        import android.database.Cursor;
        import android.net.Uri;
        import java.io.IOException;
        import java.io.InputStream;
        public class ContentResolver {
            public Cursor query(Uri uri, String[] projection, Object selection, String[] selectionArgs, Object order) {
                throw new UnsupportedOperationException();
            }
            public InputStream openInputStream(Uri uri) throws IOException {
                throw new UnsupportedOperationException();
            }
        }
    """,
    "android/content/Intent.java": """
        package android.content;
        import android.net.Uri;
        public class Intent {
            public static final String ACTION_OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT";
            public static final String CATEGORY_OPENABLE = "android.intent.category.OPENABLE";
            public static final String EXTRA_ALLOW_MULTIPLE = "android.intent.extra.ALLOW_MULTIPLE";
            private Uri data;
            public Intent(String action) {}
            public Intent addCategory(String category) { return this; }
            public Intent setType(String type) { return this; }
            public Intent putExtra(String name, boolean value) { return this; }
            public Intent setData(Uri data) { this.data = data; return this; }
            public Uri getData() { return data; }
        }
    """,
    "android/database/Cursor.java": """
        package android.database;
        public interface Cursor {
            boolean moveToFirst();
            int getColumnIndex(String name);
            String getString(int index);
            void close();
        }
    """,
    "android/net/Uri.java": """
        package android.net;
        public class Uri {}
    """,
    "android/os/Bundle.java": """
        package android.os;
        import java.util.HashMap;
        import java.util.Map;
        public class Bundle {
            private final Map<String, String> values = new HashMap<>();
            public void putString(String key, String value) { values.put(key, value); }
            public boolean containsKey(String key) { return values.containsKey(key); }
            public String getString(String key) { return values.get(key); }
        }
    """,
    "android/provider/OpenableColumns.java": """
        package android.provider;
        public class OpenableColumns { public static final String DISPLAY_NAME = "_display_name"; }
    """,
    "androidx/annotation/Keep.java": """
        package androidx.annotation;
        public @interface Keep {}
    """,
    "org/love2d/android/GameActivity.java": """
        package org.love2d.android;
        import android.app.Activity;
        import android.content.ContentResolver;
        import android.content.Context;
        import android.content.Intent;
        public class GameActivity extends Activity {
            private final Context application;
            private int launches;
            public GameActivity(Context application) { super(null); this.application = application; }
            @Override public Context getApplicationContext() { return application; }
            @Override public ContentResolver getContentResolver() {
                throw new AssertionError("the copy worker used a recreatable Activity resolver");
            }
            @Override public void startActivityForResult(Intent intent, int requestCode) { launches++; }
            public int launches() { return launches; }
        }
    """,
}

ROM_PICKER_HOST_HARNESS = """
    package org.love2d.android;

    import android.app.Activity;
    import android.content.ContentResolver;
    import android.content.Context;
    import android.content.Intent;
    import android.database.Cursor;
    import android.net.Uri;
    import android.os.Bundle;
    import android.provider.OpenableColumns;
    import java.io.ByteArrayInputStream;
    import java.io.InputStream;
    import java.nio.charset.StandardCharsets;
    import java.nio.file.Files;
    import java.nio.file.Path;
    import java.util.Arrays;
    import org.love2d.android.GameActivity;
    import org.love2d.android.RomPicker;

    public final class RomPickerHostHarness {
        private static final int REQUEST_CODE = 0x5041;
        private static final byte[] CONTENT = "TEST FIXTURE ROM BYTES".getBytes(StandardCharsets.US_ASCII);

        private static final class FixtureResolver extends ContentResolver {
            int queries;
            int opens;
            boolean cursorClosed;
            @Override public Cursor query(Uri uri, String[] projection, Object selection, String[] args, Object order) {
                queries++;
                return new Cursor() {
                    public boolean moveToFirst() { return true; }
                    public int getColumnIndex(String name) { return OpenableColumns.DISPLAY_NAME.equals(name) ? 0 : -1; }
                    public String getString(int index) { return "Rotated fixture.NDS"; }
                    public void close() { cursorClosed = true; }
                };
            }
            @Override public InputStream openInputStream(Uri uri) {
                opens++;
                return new ByteArrayInputStream(CONTENT);
            }
        }

        private static void check(boolean condition, String message) {
            if (!condition) throw new AssertionError(message);
        }

        private static void run(String directory) throws Exception {
            Path save = Path.of(directory);
            Files.createDirectories(save);
            FixtureResolver resolver = new FixtureResolver();
            Context application = new Context(resolver);
            GameActivity original = new GameActivity(application);
            String[] opened = RomPicker.open(original, save.toString());
            check(opened.length == 1 && opened[0] != null, "picker did not reserve a request");
            check(original.launches() == 1, "picker did not launch exactly once");

            Bundle state = new Bundle();
            RomPicker.saveState(state);
            GameActivity recreated = new GameActivity(application);
            RomPicker.restore(recreated, state);
            check(recreated.launches() == 0, "recreation reopened the document picker");

            Intent data = new Intent(Intent.ACTION_OPEN_DOCUMENT).setData(new Uri());
            RomPicker.onActivityResult(REQUEST_CODE, Activity.RESULT_OK, data);
            String[] result = null;
            long deadline = System.nanoTime() + 5_000_000_000L;
            while (System.nanoTime() < deadline && result == null) {
                result = RomPicker.poll();
                if (result == null) Thread.sleep(10);
            }
            check(result != null, "copy did not finish after Activity recreation");
            String relative = "imports/" + opened[0] + ".nds";
            check(Arrays.equals(result, new String[] {
                opened[0], "path", relative, "Rotated fixture.NDS", null
            }), "unexpected picker result: " + Arrays.toString(result));
            check(Arrays.equals(Files.readAllBytes(save.resolve(relative)), CONTENT), "copied bytes differ");
            check(resolver.queries == 1 && resolver.opens == 1 && resolver.cursorClosed,
                "copy did not use and close the application ContentResolver");
            check(RomPicker.poll() == null, "terminal result was not consumed exactly once");
            System.out.println("ROMPICKER_HOST_OK");
        }

        public static void main(String[] args) {
            int status = 1;
            try {
                check(args.length == 1, "save directory argument is required");
                run(args[0]);
                status = 0;
            } catch (Throwable error) {
                error.printStackTrace();
            } finally {
                System.exit(status);
            }
        }
    }
"""


def host_java_tool(name: str) -> str | None:
    java_home = os.environ.get("JAVA_HOME")
    candidate = Path(java_home) / "bin" / name if java_home else None
    if candidate is not None and candidate.is_file():
        return str(candidate)
    return shutil.which(name)


def compile_rom_picker(root: Path, *, harness: bool = False) -> Path:
    classes = root / "classes"
    classes.mkdir()
    sources = dict(ANDROID_JAVA_STUBS)
    if harness:
        sources["org/love2d/android/RomPickerHostHarness.java"] = ROM_PICKER_HOST_HARNESS
    paths = []
    for relative, content in sources.items():
        target = root / "stubs" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
        paths.append(target)
    paths.append(REPO_ROOT / "scripts" / "packaging" / "android" / "RomPicker.java")
    result = subprocess.run(
        [host_java_tool("javac"), "--release", "17", "-d", str(classes), *map(str, paths)],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise AssertionError(f"host javac smoke failed:\n{result.stdout}\n{result.stderr}")
    return classes


class AndroidRomPickerHostTest(unittest.TestCase):
    def test_rom_picker_compiles_against_temporary_android_stubs(self) -> None:
        if host_java_tool("javac") is None:
            self.skipTest("host javac is required for the Android Java smoke")
        with tempfile.TemporaryDirectory(prefix="portemon-rom-picker-compile-") as directory:
            compile_rom_picker(Path(directory))

    def test_copy_survives_activity_recreation_using_application_context(self) -> None:
        javac = host_java_tool("javac")
        java = host_java_tool("java")
        if javac is None or java is None:
            self.skipTest("host javac and java are required for the Android picker lifecycle smoke")
        with tempfile.TemporaryDirectory(prefix="portemon-rom-picker-recreation-") as directory:
            root = Path(directory)
            classes = compile_rom_picker(root, harness=True)
            result = subprocess.run(
                [java, "-cp", str(classes), "org.love2d.android.RomPickerHostHarness", str(root / "save")],
                check=False, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ROMPICKER_HOST_OK", result.stdout)


class PackagingContractTest(unittest.TestCase):
    def test_payload_is_complete_deterministic_and_free_of_editable_or_user_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture(root)
            source_identity = (root / "app" / "src" / "BuildInfo.lua").read_bytes()
            first = root / "first.love"
            second = root / "second.love"
            first_listing = root / "first.txt"
            second_listing = root / "second.txt"

            result = run_packer(root, first, first_listing)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = run_packer(root, second, second_listing)
            self.assertEqual(result.returncode, 0, result.stderr)

            self.assertEqual(first.read_bytes(), second.read_bytes(), "repeated inputs must produce identical ZIP bytes")
            self.assertEqual(first_listing.read_bytes(), second_listing.read_bytes())
            self.assertEqual(
                (root / "app" / "src" / "BuildInfo.lua").read_bytes(),
                source_identity,
                "stamping must never mutate checkout identity",
            )

            with zipfile.ZipFile(first) as archive:
                names = archive.namelist()
                self.assertEqual(names, sorted(names), "archive order must be stable and sorted")
                self.assertEqual(len(names), len(set(names)), "archive members must be unique")
                self.assertIn("main.lua", names)
                self.assertIn("conf.lua", names)
                self.assertNotIn("app/main.lua", names)
                self.assertNotIn("app/conf.lua", names)
                for relative in SOURCE_FILES[2:] + FONT_FILES + AUDIO_FILES + (BOOT_LOGO_FILE,) + MAIN_MENU_ICON_FILES:
                    self.assertIn(relative, names)
                self.assertNotIn(MAIN_MENU_ICON_SOURCE, names, "source artwork is not a runtime member")
                self.assertEqual(
                    [name for name in names if name.startswith("assets/ui/launcher/icons/")],
                    list(LAUNCHER_ICON_FILES),
                )
                self.assertFalse(any(name.startswith("assets/branding/") for name in names))
                self.assertNotIn("assets/ui/launcher/LICENSE.txt", names)
                for relative in EXCLUDED_FILES:
                    self.assertNotIn(relative, names)
                self.assertFalse(any("icons-src/" in name for name in names))
                self.assertFalse(any(name.startswith(("tests/", ".agents/", ".git/")) for name in names))
                self.assertFalse(any("\\" in name for name in names))
                self.assertFalse(
                    any(name.startswith("gen4/") and name not in ("gen4/battle.lua", "gen4/script.lua") for name in names),
                    "only the required generation-IV facade modules may be packaged",
                )

                identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
                self.assertRegex(identity, r'version\s*=\s*"1\.2\.3"')
                self.assertRegex(identity, rf'commit\s*=\s*"{COMMIT}"')
                self.assertNotIn("development", identity)

                timestamps = {info.date_time for info in archive.infolist()}
                attributes = {info.external_attr for info in archive.infolist()}
                self.assertEqual(len(timestamps), 1, "ZIP timestamps must be fixed")
                self.assertNotIn(0, attributes, "archive permissions must be explicit")
                with zipfile.ZipFile(second) as repeated:
                    self.assertEqual(
                        [(info.filename, info.external_attr) for info in archive.infolist()],
                        [(info.filename, info.external_attr) for info in repeated.infolist()],
                    )

            self.assertEqual(first_listing.read_text().splitlines(), names)
            self.assertIn("assets/audio/launcher/README.md", names)
            self.assertFalse(any(name.endswith("/boot.txt") for name in names))

            development = root / "development.love"
            development_listing = root / "development.txt"
            result = run_packer(root, development, development_listing, version="dev")
            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(development) as archive:
                identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
                self.assertRegex(identity, r'version\s*=\s*"dev"')
                self.assertRegex(identity, rf'commit\s*=\s*"{COMMIT}"')

    def test_native_shell_art_is_excluded_from_the_runtime_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture(root)
            write_file(root, "assets/branding/nested/unreviewed.icns", b"unapproved shell artwork fixture\n")
            output = root / "runtime.love"

            result = run_packer(root, output, root / "listing.txt")

            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
            self.assertFalse(any(name.startswith("assets/branding/") for name in names))

    def test_obsolete_art_is_not_required_and_unreviewed_shell_art_is_never_packaged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture(root)
            for relative in OBSOLETE_LAUNCHER_FILES + CUSTOM_BRANDING_FILES:
                (root / relative).unlink()
            write_file(root, "assets/branding/unreviewed.png", b"unapproved shell artwork fixture\n")
            write_file(root, "assets/branding/unreviewed.ico", b"unapproved shell artwork fixture\n")
            output = root / "runtime-only.love"

            result = run_packer(root, output, root / "listing.txt")

            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
            self.assertFalse(any(name.startswith("assets/branding/") for name in names))
            self.assertFalse(any(name.startswith("assets/ui/launcher/icons/") for name in names))

    def test_missing_required_source_or_asset_preserves_the_previous_payload_and_listing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            for relative in (
                "gen4/battle.lua",
                "assets/fonts/galmuri/Galmuri11.ttf",
                "assets/fonts/galmuri/Galmuri11-Bold.ttf",
                "assets/audio/launcher/boot.ogg",
                "assets/audio/launcher/focus.ogg",
                "assets/audio/launcher/README.md",
            ):
                with self.subTest(missing=relative):
                    make_fixture(root)
                    result = run_packer(root, output, listing)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    previous_payload = output.read_bytes()
                    previous_listing = listing.read_bytes()
                    (root / relative).unlink()

                    result = run_packer(root, output, listing)

                    self.assertNotEqual(result.returncode, 0, "missing required runtime input must fail the build")
                    self.assertIn(relative, result.stderr + result.stdout)
                    self.assertEqual(output.read_bytes(), previous_payload)
                    self.assertEqual(listing.read_bytes(), previous_listing)

    def test_launcher_font_members_are_required_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            for relative in LAUNCHER_FONT_FILES:
                with self.subTest(member=relative):
                    make_fixture(root)
                    for present in LAUNCHER_FONT_FILES:
                        write_file(root, present, b"isolated packaging fixture\n")
                    result = run_packer(root, output, listing)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    with zipfile.ZipFile(output) as archive:
                        self.assertIn(relative, archive.namelist(), "the licensed font must join the payload")
                    previous_payload = output.read_bytes()
                    previous_listing = listing.read_bytes()

                    (root / relative).unlink()

                    result = run_packer(root, output, listing)

                    self.assertNotEqual(result.returncode, 0, "a missing launcher font must fail the build")
                    self.assertIn(relative, result.stderr + result.stdout)
                    self.assertEqual(output.read_bytes(), previous_payload)
                    self.assertEqual(listing.read_bytes(), previous_listing)

    def test_boot_logo_member_is_required_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            make_fixture(root)
            result = run_packer(root, output, listing)
            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(output) as archive:
                self.assertIn(BOOT_LOGO_FILE, archive.namelist(), "the boot logo must join the payload")
            previous_payload = output.read_bytes()
            previous_listing = listing.read_bytes()

            (root / BOOT_LOGO_FILE).unlink()

            result = run_packer(root, output, listing)

            self.assertNotEqual(result.returncode, 0, "a missing boot logo must fail the build")
            self.assertIn(BOOT_LOGO_FILE, result.stderr + result.stdout)
            self.assertEqual(output.read_bytes(), previous_payload)
            self.assertEqual(listing.read_bytes(), previous_listing)

    def test_main_menu_icon_members_are_required_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            for relative in MAIN_MENU_ICON_FILES:
                with self.subTest(member=relative):
                    make_fixture(root)
                    result = run_packer(root, output, listing)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    with zipfile.ZipFile(output) as archive:
                        self.assertIn(relative, archive.namelist(), "the licensed icon must join the payload")
                    previous_payload = output.read_bytes()
                    previous_listing = listing.read_bytes()

                    (root / relative).unlink()

                    result = run_packer(root, output, listing)

                    self.assertNotEqual(result.returncode, 0, "a missing icon member must fail the build")
                    self.assertIn(relative, result.stderr + result.stdout)
                    self.assertEqual(output.read_bytes(), previous_payload)
                    self.assertEqual(listing.read_bytes(), previous_listing)

    def test_missing_source_tree_or_aliased_listing_cannot_publish_a_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            make_fixture(source)
            output = root / "portemon.love"
            result = run_packer(source, output, None)
            self.assertEqual(result.returncode, 0, result.stderr)
            previous = output.read_bytes()

            aliased = run_packer(source, output, output)
            self.assertNotEqual(aliased.returncode, 0, "a listing cannot overwrite its own payload")
            self.assertEqual(output.read_bytes(), previous)

            shutil.rmtree(source / "game/hgss/src")
            missing = run_packer(source, output, None)
            self.assertNotEqual(missing.returncode, 0, "a missing required source tree must fail before publication")
            self.assertIn("game/hgss/src", missing.stderr + missing.stdout)
            self.assertEqual(output.read_bytes(), previous)

    def test_invalid_build_identity_is_rejected_without_replacing_valid_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture(root)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            result = run_packer(root, output, listing)
            self.assertEqual(result.returncode, 0, result.stderr)
            previous_payload = output.read_bytes()
            previous_listing = listing.read_bytes()
            for version, commit in (("1.2", COMMIT), ("1.2.3", "development"), ("1.2.3", "abc123")):
                with self.subTest(version=version, commit=commit):
                    result = run_packer(root, output, listing, version=version, commit=commit)
                    self.assertNotEqual(result.returncode, 0, "invalid build identity must fail before publication")
                    self.assertEqual(output.read_bytes(), previous_payload)
                    self.assertEqual(listing.read_bytes(), previous_listing)


def android_build_blocker() -> str | None:
    if not sys.platform.startswith("linux") or os.uname().machine != "x86_64":
        return "Android packaging requires a Linux x86_64 host"
    for command in ("python3", "curl", "tar", "patch", "make", "gcc", "luajit", "keytool"):
        if shutil.which(command) is None:
            return f"required Android packaging tool is missing: {command}"
    java = os.environ.get("JAVA_HOME")
    java_bin = Path(java) / "bin" / "java" if java else Path(shutil.which("java") or "")
    if not java_bin.is_file():
        return "JDK 17 is required for Android packaging"
    result = subprocess.run([str(java_bin), "-version"], check=False, capture_output=True, text=True)
    match = re.search(r'version "(\d+)"', result.stdout + result.stderr)
    if match is None or match.group(1) != "17":
        return "JDK 17 is required for Android packaging"
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not sdk:
        return "ANDROID_SDK_ROOT is required for Android packaging"
    sdk_root = Path(sdk)
    ndk = Path(os.environ.get("ANDROID_NDK_ROOT", sdk_root / "ndk" / "28.2.13676358"))
    build_tools = sdk_root / "build-tools" / "36.0.0"
    required = (
        ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang",
        ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang",
        ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang",
        build_tools / "zipalign",
        build_tools / "aapt2",
        build_tools / "apksigner",
        sdk_root / "platforms/android-36/android.jar",
    )
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        return "locked Android tool is missing: " + missing[0]
    return None


def apk_badging(apk: Path) -> str:
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ["ANDROID_HOME"])
    aapt2 = sdk / "build-tools" / "36.0.0" / "aapt2"
    return subprocess.run(
        [str(aapt2), "dump", "badging", str(apk)], check=True, capture_output=True, text=True
    ).stdout


def apk_certificate_digest(apk: Path) -> str:
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ["ANDROID_HOME"])
    apksigner = sdk / "build-tools" / "36.0.0" / "apksigner"
    result = subprocess.run(
        [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"APK signature verification failed: {result.stdout}\n{result.stderr}")
    match = re.search(r"Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]+)", result.stdout)
    if match is None:
        raise RuntimeError(f"APK verifier did not report a certificate digest: {result.stdout}")
    return match.group(1).lower()


class ReleaseVersionContractTest(unittest.TestCase):
    def test_semver_prerelease_and_build_metadata_are_preserved_exactly(self) -> None:
        version = "0.1.0-alpha.1+build.007"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root, version=version)
            with zipfile.ZipFile(payload) as archive:
                identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
            self.assertIn(f'version = "{version}"', identity)
            self.assertIn(f'commit = "{COMMIT}"', identity)

    def test_invalid_semver_never_replaces_a_valid_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            make_fixture(source)
            output = root / "release.love"
            listing = root / "release.txt"
            result = run_packer(source, output, listing, version=RELEASE_VERSION)
            self.assertEqual(result.returncode, 0, result.stderr)
            previous = (output.read_bytes(), listing.read_bytes())
            for version in (
                "v0.1.0",
                "00.1.0",
                "0.1",
                "0.1.0-01",
                "0.1.0-alpha.01",
                "0.1.0-alpha..1",
                "0.1.0+",
                "0.1.0-alpha_1",
                "0.1.0\n",
            ):
                with self.subTest(version=version):
                    output.write_bytes(previous[0])
                    listing.write_bytes(previous[1])
                    result = run_packer(source, output, listing, version=version)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("version", result.stderr + result.stdout)
                    self.assertEqual((output.read_bytes(), listing.read_bytes()), previous)

    def test_android_version_code_is_explicit_and_must_match_payload_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "previous.apk"
            output.write_bytes(b"previous validated APK\n")
            result = run_android(payload, output, version_code=None)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("version-code", result.stdout + result.stderr)
            self.assertEqual(output.read_bytes(), b"previous validated APK\n")
            result = run_android(payload, output, version="0.1.0-alpha.2")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("identity", result.stdout + result.stderr)
            self.assertEqual(output.read_bytes(), b"previous validated APK\n")

    def test_android_version_code_must_be_a_positive_integer_before_host_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "previous.apk"
            output.write_bytes(b"previous validated APK\n")
            for version_code in ("0", "-1", "+1", "01", "1.0", "one", " 1", "1 "):
                with self.subTest(version_code=version_code):
                    result = run_android(payload, output, version_code=version_code)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("version code", result.stderr + result.stdout)
                    self.assertEqual(output.read_bytes(), b"previous validated APK\n")


class MacosMetadataContractTest(unittest.TestCase):
    def test_builder_metadata_sets_and_verifies_the_renamed_product_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plist = Path(directory) / "Info.plist"
            plist.write_bytes(plistlib.dumps({"CFBundleExecutable": "love", "LSMinimumSystemVersion": "10.11"}))
            result = subprocess.run(
                [sys.executable, str(MACOS_METADATA), "--plist", str(plist), "--version", "0.1.0"],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            info = plistlib.loads(plist.read_bytes())
            self.assertEqual(info["CFBundleExecutable"], "portemon")
            self.assertEqual(info["CFBundleIdentifier"], "io.github.portemonnitro.portemon")
            self.assertEqual(info["CFBundleName"], "Portémon Nitro")
            self.assertEqual(info["CFBundleDisplayName"], "Portémon Nitro")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
            self.assertEqual(info["CFBundleVersion"], "0.1.0")
            self.assertEqual(info["CFBundleIconFile"], "portemon")
            self.assertEqual(info["LSMinimumSystemVersion"], "10.11")
            self.assertEqual(info["UTExportedTypeDeclarations"][0]["UTTypeIdentifier"], "io.github.portemonnitro.nds-rom")

            verified = subprocess.run(
                [sys.executable, str(MACOS_METADATA), "--plist", str(plist), "--version", "0.1.0", "--verify"],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            info["CFBundleExecutable"] = "love"
            info["CFBundleIconFile"] = "love"
            plist.write_bytes(plistlib.dumps(info))
            verified = subprocess.run(
                [sys.executable, str(MACOS_METADATA), "--plist", str(plist), "--version", "0.1.0", "--verify"],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("CFBundleExecutable", verified.stdout + verified.stderr)


class PackagedSmokeEnvironmentTest(unittest.TestCase):
    def test_every_desktop_smoke_environment_selects_the_null_audio_backend(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for platform in ("linux", "macos", "windows"):
                with self.subTest(platform=platform):
                    environment = SMOKE_ENVIRONMENT_MODULE.environment(platform, root)
                    self.assertEqual(environment["ALSOFT_DRIVERS"], "null")
                    self.assertTrue(all(Path(value).is_absolute() for name, value in environment.items() if name != "ALSOFT_DRIVERS"))

    def test_posix_smoke_process_receives_owned_roots_without_mutating_its_parent(self) -> None:
        sentinels = {
            "HOME": str(REPO_ROOT / "real-home"),
            "XDG_DATA_HOME": str(REPO_ROOT / "real-data"),
            "XDG_CACHE_HOME": str(REPO_ROOT / "real-cache"),
            "PORTEMON_SAVE_DIR": str(REPO_ROOT / "real-save"),
            "ALSOFT_DRIVERS": "pulse",
        }
        expected = {
            "linux": {
                "HOME": "home",
                "XDG_DATA_HOME": "data",
                "XDG_CACHE_HOME": "cache",
                "PORTEMON_SAVE_DIR": "data",
            },
            "macos": {"HOME": "home", "PORTEMON_SAVE_DIR": "data"},
        }
        probe = (
            "import json, os, pathlib, sys; "
            "pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(os.environ)))"
        )
        with mock.patch.dict(os.environ, sentinels):
            for platform, roots in expected.items():
                with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory) / "smoke root é"
                    root.mkdir()
                    captured = root / "environment.json"
                    result = subprocess.run(
                        ["bash", str(SMOKE_RUNNER), platform, str(root), sys.executable, "-c", probe, str(captured)],
                        cwd=REPO_ROOT, check=False, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    environment = json.loads(captured.read_text())
                    self.assertEqual(environment["ALSOFT_DRIVERS"], "null")
                    for name, relative in roots.items():
                        self.assertEqual(environment[name], str(root / relative))
                    for name, value in sentinels.items():
                        self.assertEqual(os.environ[name], value, "smoke setup must not mutate the builder environment")

    def test_smoke_runner_fails_closed_when_environment_generation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            python = tools / "python3"
            python.write_text("#!/bin/sh\nexit 1\n")
            python.chmod(0o755)
            marker = root / "launched"
            environment = os.environ.copy()
            environment["PATH"] = str(tools) + os.pathsep + environment.get("PATH", "")
            result = subprocess.run(
                ["bash", str(SMOKE_RUNNER), "linux", str(root), "touch", str(marker)],
                cwd=REPO_ROOT, env=environment, check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), "a smoke process must never launch without its isolated environment")

    def test_windows_smoke_environment_owns_every_native_user_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "smoke root é"
            root.mkdir()
            result = subprocess.run(
                [sys.executable, str(SMOKE_ENVIRONMENT), "--platform", "windows", "--root", str(root)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {
                    "APPDATA": str(root / "roaming"),
                    "LOCALAPPDATA": str(root / "local"),
                    "USERPROFILE": str(root / "home"),
                    "PORTEMON_SAVE_DIR": str(root / "data"),
                    "ALSOFT_DRIVERS": "null",
                },
            )

    def test_archive_smoke_uses_owned_platform_roots_for_every_child(self) -> None:
        expected = {
            "linux": {"HOME": "home", "XDG_DATA_HOME": "data", "XDG_CACHE_HOME": "cache", "PORTEMON_SAVE_DIR": "data"},
            "windows": {
                "APPDATA": "roaming",
                "LOCALAPPDATA": "local",
                "USERPROFILE": "home",
                "PORTEMON_SAVE_DIR": "data",
            },
            "macos": {"HOME": "home", "PORTEMON_SAVE_DIR": "data"},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            with zipfile.ZipFile(payload) as archive:
                original_conf = archive.read("conf.lua")
            environment_module = SMOKE_ENVIRONMENT_MODULE
            packaged_environment = environment_module.environment

            def environment_with_audio(platform, owned_root):
                values = packaged_environment(platform, owned_root)
                values["ALSOFT_DRIVERS"] = "null"
                return values

            for platform, roots in expected.items():
                with self.subTest(platform=platform):
                    launches = []

                    def check_environment(environment):
                        root = Path(environment["PORTEMON_SAVE_DIR"]).parent
                        self.assertEqual(environment["PORTEMON_SMOKE_PARENT_SENTINEL"], "preserved")
                        self.assertEqual(environment["ALSOFT_DRIVERS"], "null")
                        for name, relative in roots.items():
                            owned = root / relative
                            self.assertEqual(environment[name], str(owned))
                            self.assertTrue(owned.is_dir(), f"{name} root must exist before launch")
                        self.assertNotIn("LUA_PATH", environment)
                        self.assertNotIn("LUA_CPATH", environment)
                        launches.append(environment.copy())

                    def run(command, **kwargs):
                        if "--version" in command:
                            return subprocess.CompletedProcess(command, 0, "LOVE 11.5 (fixture)\n", "")
                        check_environment(kwargs["env"])
                        with zipfile.ZipFile(Path(command[1])) as archive:
                            self.assertEqual(archive.read("conf.lua"), archive_probe_conf(original_conf))
                        return subprocess.CompletedProcess(command, 0, "ARCHIVE_SMOKE_OK version=fixture commit=fixture frames=2\n", "")

                    def popen(command, **kwargs):
                        check_environment(kwargs["env"])
                        with zipfile.ZipFile(Path(command[1])) as archive:
                            self.assertEqual(archive.read("conf.lua"), original_conf)
                        return process

                    process = mock.Mock()
                    process.poll.return_value = None
                    parent = os.environ.copy()
                    parent.update({
                        "LOVE_BIN": "/fixture/love",
                        "PORTEMON_SMOKE_PARENT_SENTINEL": "preserved",
                        "LUA_PATH": "/real/lua/path",
                        "LUA_CPATH": "/real/lua/cpath",
                        "ALSOFT_DRIVERS": "pulse",
                    })
                    with (
                        mock.patch.dict(os.environ, parent, clear=True),
                        mock.patch(f"{__name__}.host_smoke_platform", return_value=platform),
                        mock.patch.object(environment_module, "environment", side_effect=environment_with_audio),
                        mock.patch(f"{__name__}.subprocess.run", side_effect=run),
                        mock.patch(f"{__name__}.subprocess.Popen", side_effect=popen),
                        mock.patch(f"{__name__}.stop_process"),
                        mock.patch(f"{__name__}.time.sleep"),
                    ):
                        smoke_payload(payload)
                        self.assertEqual(os.environ["ALSOFT_DRIVERS"], "pulse")

                    self.assertEqual(len(launches), 2, "untouched and probe launches must use the same owned environment")
                    self.assertEqual(launches[0], launches[1])
                    self.assertFalse((root / "null").exists(), "the audio backend value is not an owned directory")


class ReleaseCollectorContractTest(unittest.TestCase):
    def collect_valid(self, inputs: Path, output: Path) -> None:
        result = run_collector(inputs, output)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_complete_set_has_exact_names_immutable_inputs_and_sorted_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            before = tree_snapshot(inputs)
            output = root / "release"
            self.collect_valid(inputs, output)

            names = release_artifacts(RELEASE_VERSION)
            self.assertEqual({path.name for path in output.iterdir()}, {*names, "SHA256SUMS"})
            self.assertEqual(tree_snapshot(inputs), before, "collection must not mutate build inputs")
            for name in names:
                self.assertEqual((output / name).read_bytes(), (inputs / name).read_bytes())
                if name.endswith((".zip", ".apk", ".AppImage")):
                    assert_embedded_payload(self, output / name, payload)
            self.assertTrue((output / names[3]).stat().st_mode & stat.S_IXUSR)
            with zipfile.ZipFile(output / names[2]) as archive:
                bundle_info = plistlib.loads(archive.read("Portemon Nitro.app/Contents/Info.plist"))
            self.assertEqual(bundle_info["CFBundleIdentifier"], "io.github.portemonnitro.portemon")
            self.assertEqual(bundle_info["CFBundleShortVersionString"], "0.1.0")
            self.assertEqual(bundle_info["CFBundleVersion"], "0.1.0")
            self.assertEqual(bundle_info["CFBundleExecutable"], "portemon")
            self.assertEqual(bundle_info["CFBundleIconFile"], "portemon")
            expected = "".join(
                f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n"
                for name in sorted(names)
            )
            self.assertEqual((output / "SHA256SUMS").read_text(), expected)
            self.assertNotIn("SHA256SUMS", (output / "SHA256SUMS").read_text())

    def test_macos_bundle_must_name_the_product_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            artifact = inputs / release_artifacts(RELEASE_VERSION)[2]
            info_name = "Portemon Nitro.app/Contents/Info.plist"
            for executable in (None, "love", "Portemon Nitro"):
                with self.subTest(executable=executable):
                    write_release_artifacts(inputs, payload)
                    with zipfile.ZipFile(artifact) as archive:
                        members = {name: archive.read(name) for name in archive.namelist()}
                    info = plistlib.loads(members[info_name])
                    if executable is None:
                        info.pop("CFBundleExecutable")
                    else:
                        info["CFBundleExecutable"] = executable
                    members[info_name] = plistlib.dumps(info)
                    write_zip(artifact, members)

                    result = run_collector(inputs, output)

                    self.assertNotEqual(result.returncode, 0, "the bundle must launch its renamed executable")
                    self.assertIn("CFBundleExecutable", result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)

    def test_every_platform_payload_must_equal_the_shared_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            variant = payload_with_members(payload, {"release-fixture.txt": b"different valid payload\n"})
            self.addCleanup(variant.unlink, missing_ok=True)
            names = release_artifacts(RELEASE_VERSION)
            for name in names[1:]:
                with self.subTest(artifact=name):
                    write_release_artifacts(inputs, payload)
                    target = inputs / name
                    if name.endswith("-windows-x86_64.zip"):
                        write_windows_artifact(target, variant)
                    elif name.endswith("-macos-universal.zip"):
                        write_macos_artifact(target, variant, RELEASE_VERSION)
                    elif name.endswith("-linux-x86_64.AppImage"):
                        write_linux_artifact(target, variant)
                    else:
                        write_android_artifact(target, variant)
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0, "a mismatched embedded payload must fail")
                    self.assertIn(name, result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)

    def test_missing_or_unexpected_artifacts_preserve_the_previous_complete_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            for name in release_artifacts(RELEASE_VERSION):
                with self.subTest(missing=name):
                    target = inputs / name
                    saved = target.read_bytes()
                    mode = stat.S_IMODE(target.stat().st_mode)
                    target.unlink()
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)
                    target.write_bytes(saved)
                    target.chmod(mode)
            extra = inputs / f"portemon-nitro-{RELEASE_VERSION}-debug.apk"
            extra.write_bytes(b"not a release artifact\n")
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0, "the input set must be the finite release matrix")
            self.assertIn(extra.name, result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

    def test_missing_native_libraries_or_required_abis_preserve_the_previous_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            names = release_artifacts(RELEASE_VERSION)
            windows_library = "Portemon Nitro/app/native/windows/x64/nfd.dll"
            macos_library = "Portemon Nitro.app/Contents/Resources/app/native/macos/arm64/libnfd.dylib"
            for name, omitted in (
                (names[1], {windows_library}),
                (names[2], {macos_library}),
                (names[4], {"lib/arm64-v8a/liblove.so"}),
            ):
                with self.subTest(artifact=name, missing=next(iter(omitted))):
                    write_release_artifacts(inputs, payload)
                    omit_zip_members(inputs / name, omitted)
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)
            with self.subTest(artifact=names[3], missing="app/native/linux/x64/libnfd.so"):
                write_release_artifacts(inputs, payload)
                write_linux_artifact(inputs / names[3], payload, omit={"app/native/linux/x64/libnfd.so"})
                result = run_collector(inputs, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(names[3], result.stdout + result.stderr)
                self.assertEqual(tree_snapshot(output), previous)
            with self.subTest(artifact=names[4], unexpected="lib/x86_64/liblove.so"):
                write_release_artifacts(
                    inputs,
                    payload,
                    extras={names[4]: {"lib/x86_64/liblove.so": b"unexpected release ABI\n"}},
                )
                result = run_collector(inputs, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(names[4], result.stdout + result.stderr)
                self.assertEqual(tree_snapshot(output), previous)

    def test_android_manifest_and_signature_are_mandatory_for_collection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            names = release_artifacts(RELEASE_VERSION)
            android = inputs / names[4]

            write_release_artifacts(inputs, payload)
            omit_zip_members(android, {"AndroidManifest.xml"})
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0, "an APK without its binary manifest is not a release")
            self.assertIn("AndroidManifest.xml", result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

            write_release_artifacts(inputs, payload)
            apksigner = root / "android-sdk/build-tools/36.0.0/apksigner"
            apksigner.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            apksigner.chmod(0o755)
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0, "an unverifiable signature blocks collection")
            self.assertIn("signature", result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

    def test_forbidden_payload_or_outer_files_preserve_the_previous_complete_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            forbidden_payload = payload_with_members(
                payload,
                {
                    "roms/user.nds": b"synthetic ROM\n",
                    "saves/heartgold/field-session.lua": b"synthetic save\n",
                    "cache/heartgold/catalog.lua": b"synthetic cache\n",
                    "references/ds/crop.png": b"synthetic reference\n",
                    "tests/unit.lua": b"test harness\n",
                    ".agents/tmp/private.txt": b"private note\n",
                    "assets/ui/launcher/icons-src/source.svg": b"reference source\n",
                    "release.keystore": b"private key fixture\n",
                },
            )
            self.addCleanup(forbidden_payload.unlink, missing_ok=True)
            write_release_artifacts(inputs, forbidden_payload)
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0, "forbidden files inside the shared payload must fail")
            self.assertEqual(tree_snapshot(output), previous)

            names = release_artifacts(RELEASE_VERSION)
            cases = (
                (names[1], {"roms/user.nds": b"synthetic ROM\n"}),
                (names[2], {"references/ds/crop.png": b"synthetic reference\n"}),
                (names[3], {"saves/heartgold/field-session.lua": b"synthetic save\n"}),
                (names[4], {"assets/portemon.keystore": b"private key fixture\n"}),
            )
            for name, extra in cases:
                with self.subTest(artifact=name):
                    write_release_artifacts(inputs, payload, extras={name: extra})
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0, "forbidden outer package files must fail")
                    self.assertIn(name, result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)

    def test_invalid_release_identity_preserves_the_previous_complete_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            self.collect_valid(inputs, output)
            previous = tree_snapshot(output)
            cases = (
                ("0.1.0-01", COMMIT),
                ("v0.1.0-alpha.1", COMMIT),
                ("0.1.0-alpha.1", COMMIT[:12]),
                ("0.1.0-alpha.1", COMMIT.upper()),
                ("0.1.0-alpha.1", "g" * 40),
                ("0.1.0-alpha.2", COMMIT),
                ("0.1.0-alpha.1", "f" * 40),
            )
            for version, commit in cases:
                with self.subTest(version=version, commit=commit):
                    result = run_collector(inputs, output, version=version, commit=commit)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(tree_snapshot(output), previous)


class NativeShellArtworkContractTest(unittest.TestCase):
    def test_windows_uses_the_fused_executable_icon_without_a_standalone_custom_icon(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            result = run_collector(inputs, output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            artifact = inputs / release_artifacts(RELEASE_VERSION)[1]
            with zipfile.ZipFile(artifact) as archive:
                names = archive.namelist()
            self.assertFalse(any(name.endswith(".ico") for name in names))
            self.assertEqual([name for name in names if name.endswith(".exe")], ["Portemon Nitro/Portemon Nitro.exe"])
            assert_embedded_payload(self, artifact, payload)

    def test_macos_requires_exactly_one_product_named_icon(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            result = run_collector(inputs, output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            previous = tree_snapshot(output)
            artifact = inputs / release_artifacts(RELEASE_VERSION)[2]
            icon = "Portemon Nitro.app/Contents/Resources/portemon.icns"
            write_release_artifacts(inputs, payload)
            omit_zip_members(artifact, {icon})
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(icon, result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

            write_release_artifacts(
                inputs, payload,
                extras={artifact.name: {"Portemon Nitro.app/Contents/Resources/love.icns": b"stale upstream name\n"}},
            )
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("only the product icon", result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

    def test_linux_keeps_matching_product_icon_paths_and_rejects_stale_desktop_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, inputs = make_release_fixture(root)
            output = root / "release"
            result = run_collector(inputs, output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            previous = tree_snapshot(output)
            artifact = inputs / release_artifacts(RELEASE_VERSION)[3]
            icons = (
                "portemon.png",
                "share/pixmaps/portemon.png",
                "share/icons/hicolor/256x256/apps/portemon.png",
            )
            for relative in icons:
                with self.subTest(missing=relative):
                    write_linux_artifact(artifact, payload, omit={relative})
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(relative, result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)

            for relative in icons[1:]:
                with self.subTest(mismatched=relative):
                    write_linux_artifact(artifact, payload, extra={relative: b"different shell artwork\n"})
                    result = run_collector(inputs, output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("icon", result.stdout + result.stderr)
                    self.assertEqual(tree_snapshot(output), previous)

            write_release_artifacts(
                inputs, payload,
                extras={artifact.name: {"portemon.desktop": b"[Desktop Entry]\nName=Portemon Nitro\nIcon=love\n"}},
            )
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Icon=portemon", result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)

            write_release_artifacts(
                inputs, payload, extras={artifact.name: {"love.svg": b"stale upstream desktop identity\n"}},
            )
            result = run_collector(inputs, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("upstream LÖVE desktop identity files", result.stdout + result.stderr)
            self.assertEqual(tree_snapshot(output), previous)


class DesktopBuilderContractTest(unittest.TestCase):
    def test_linux_wrapper_rejects_payload_identity_mismatch_before_dependencies(self) -> None:
        if not sys.platform.startswith("linux") or os.uname().machine != "x86_64":
            self.skipTest("unverified native Linux gate: requires Linux x86_64")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "previous.AppImage"
            output.write_bytes(b"previous validated AppImage\n")
            result = subprocess.run(
                [str(REPO_ROOT / "scripts/build_linux.sh"), "--love", str(payload),
                 "--version", "0.1.0-alpha.2", "--output", str(output)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("identity", result.stdout + result.stderr)
            self.assertEqual(output.read_bytes(), b"previous validated AppImage\n")

    def test_nfd_refuses_a_foreign_platform_without_replacing_output(self) -> None:
        target = "windows" if sys.platform.startswith("linux") else "linux"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nfd"
            output.mkdir()
            marker = output / "previous.txt"
            marker.write_bytes(b"previous validated output\n")
            result = subprocess.run(
                [sys.executable, str(REPO_ROOT / "scripts/packaging/build_nfd.py"),
                 "--platform", target, "--arch", "x64", "--output", str(output)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("require", result.stdout + result.stderr)
            self.assertEqual(marker.read_bytes(), b"previous validated output\n")

    def test_nfd_never_promotes_a_stale_staging_tree(self) -> None:
        sys.path.insert(0, str(NFD_BUILDER.parent))
        import build_nfd

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "nfd"
            stale = output.with_name(output.name + ".staging")
            write_file(stale, "interrupted.txt", b"must never be promoted\n")
            source = root / "cache" / "source" / "nativefiledialog-extended-fixture"
            source.mkdir(parents=True)
            shutil.copyfile(REPO_ROOT / "app" / "native" / "LICENSE", source / "LICENSE")
            library = root / "fixture-libnfd.so"
            library.write_bytes(b"fixture NFDe library\n")
            cmake = subprocess.CompletedProcess(["cmake", "--version"], 0, "cmake version 3.30.0\n", "")
            pins = json.loads((REPO_ROOT / "scripts" / "packaging" / "pins.json").read_text())
            real_sha256 = build_nfd.sha256

            def fixture_sha256(path: Path) -> str:
                if path == source / "LICENSE":
                    return str(pins["nfde"]["license"]["value"])
                return real_sha256(path)

            with (
                mock.patch.dict(os.environ, {"PORTEMON_BUILD_CACHE": str(root / "cache")}),
                mock.patch.object(build_nfd.platform, "system", return_value="Linux"),
                mock.patch.object(build_nfd.platform, "machine", return_value="x86_64"),
                mock.patch.object(build_nfd.shutil, "which", return_value="/fixture/tool"),
                mock.patch.object(build_nfd.subprocess, "run", return_value=cmake),
                mock.patch.object(build_nfd, "sha256", side_effect=fixture_sha256),
                mock.patch.object(build_nfd, "source_tree", return_value=source),
                mock.patch.object(build_nfd, "build_library", return_value=library),
                mock.patch.object(build_nfd, "verify_symbols"),
                mock.patch.object(build_nfd, "verify_architecture"),
            ):
                build_nfd.build(output, "linux")

            self.assertEqual((output / "libnfd.so").read_bytes(), library.read_bytes())
            self.assertEqual((output / "LICENSE").read_bytes(), (REPO_ROOT / "app" / "native" / "LICENSE").read_bytes())
            self.assertEqual({path.name for path in output.iterdir()}, {"libnfd.so", "LICENSE"})
            self.assertTrue((stale / "interrupted.txt").is_file(), "foreign stale staging must not be reused or deleted")

    def test_appimage_offset_is_derived_from_elf_metadata_not_literal_magic(self) -> None:
        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        import collect_release

        ident = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
        header = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 0, 128, 0, 64, 56, 0, 64, 1, 0)
        data = bytearray(header + b"hsqs" + bytes(60) + bytes(64) + b"hsqs")
        self.assertEqual(collect_release.elf_squashfs_offset(bytes(data)), 192)


class ReleaseWorkflowIdentityTest(unittest.TestCase):
    def job_block(self, name: str) -> list[str]:
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text().splitlines()
        start = workflow.index(f"  {name}:")
        end = next((index for index in range(start + 1, len(workflow))
                    if workflow[index].startswith("  ") and not workflow[index].startswith("    ")), len(workflow))
        return workflow[start:end]

    def step_command(self, job: str, name: str) -> str:
        block = self.job_block(job)
        start = block.index(f"      - name: {name}") + 1
        while block[start].strip() != "run: |":
            start += 1
        command = []
        for line in block[start + 1:]:
            if line.strip() and not line.startswith("          "):
                break
            command.append(line[10:] if line.startswith("          ") else "")
        return "\n".join(command)

    def validation_command(self) -> str:
        return self.step_command("version", "Validate release identity")

    def download_steps(self, job: str) -> list[str]:
        block = self.job_block(job)
        downloads = []
        index = 0
        while index < len(block):
            if block[index].strip() != "- uses: actions/download-artifact@v6":
                index += 1
                continue
            end = index + 1
            while end < len(block) and not block[end].startswith("      - "):
                end += 1
            downloads.append("\n".join(block[index:end]))
            index = end
        return downloads

    def validate(self, command: str, *, event: str, tag: str, version: str) -> subprocess.CompletedProcess[str]:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()
        with tempfile.TemporaryDirectory(prefix="portemon-release-workflow-") as directory:
            environment = os.environ.copy()
            environment.update({
                "RELEASE_EVENT": event,
                "RELEASE_TAG": tag,
                "RELEASE_VERSION": version,
                "RELEASE_COMMIT": commit,
                "GITHUB_OUTPUT": str(Path(directory) / "outputs"),
            })
            return subprocess.run(
                ["bash", "-e", "-c", command], cwd=REPO_ROOT, env=environment,
                check=False, capture_output=True, text=True,
            )

    def test_workflow_validates_matching_tags_dispatch_and_malformed_versions(self) -> None:
        command = self.validation_command()
        valid = (
            ("push", "v0.1.0-alpha.1", ""),
            ("workflow_dispatch", "", "0.1.0-alpha.1+build.007"),
        )
        for event, tag, version in valid:
            with self.subTest(event=event, tag=tag, version=version):
                result = self.validate(command, event=event, tag=tag, version=version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        invalid = (
            ("workflow_dispatch", "v0.1.0-alpha.1", "0.1.0-alpha.2"),
            ("workflow_dispatch", "", "v0.1.0-alpha.1"),
            ("workflow_dispatch", "", "0.1.0-01"),
            ("push", "0.1.0-alpha.1", ""),
            ("push", "v0.1.0-01", ""),
            ("push", "v0.1", ""),
        )
        for event, tag, version in invalid:
            with self.subTest(event=event, tag=tag, version=version):
                result = self.validate(command, event=event, tag=tag, version=version)
                self.assertNotEqual(result.returncode, 0, "invalid release identity must fail before packaging")

    def test_android_build_uses_a_hosted_runner_without_a_device_prerequisite(self) -> None:
        android = "\n".join(self.job_block("android"))
        self.assertIn("runs-on: ubuntu-22.04", android)
        self.assertNotIn("self-hosted", android)
        self.assertNotIn("PORTEMON_ANDROID_TEST_SERIAL", android)
        self.assertNotIn("PORTEMON_ANDROID_DEVICE_REQUIRED", android)
        self.assertNotIn("supplemental signed Android install/upgrade device gate", android)
        self.assertLess(
            android.index("Check release signing preflight"),
            android.index("Materialize the private signing key"),
        )
        collect = "\n".join(self.job_block("collect"))
        draft = "\n".join(self.job_block("draft"))
        self.assertIn("needs: [version, payload, windows, macos, linux, android, android-acceptance]", collect)
        self.assertIn("needs: [version, collect, android, android-acceptance]", draft)

    def test_collector_downloads_only_the_five_explicit_distributables(self) -> None:
        downloads = self.download_steps("collect")
        names = [re.search(r"^          name: (.+)$", step, re.MULTILINE).group(1) for step in downloads]
        self.assertEqual(names, ["release-payload", "release-windows", "release-macos", "release-linux", "release-android"])
        for step in downloads:
            self.assertIn("          path: artifacts", step)
            self.assertNotIn("pattern:", step)
            self.assertNotIn("merge-multiple:", step)

    def test_actual_candidate_acceptance_is_required_before_collection(self) -> None:
        acceptance = "\n".join(self.job_block("android-acceptance"))
        self.assertIn("needs: [version, android]", acceptance)
        self.assertIn("environment: android-device-acceptance", acceptance)
        self.assertIn("self-hosted", acceptance)
        self.assertIn("android-device", acceptance)
        self.assertNotIn("runs-on: ubuntu-22.04", acceptance)
        self.assertIn("PORTEMON_ANDROID_TEST_SERIAL: ${{ vars.PORTEMON_ANDROID_TEST_SERIAL }}", acceptance)
        self.assertIn("PORTEMON_ANDROID_TEST_ROM: ${{ vars.PORTEMON_ANDROID_TEST_ROM }}", acceptance)
        self.assertIn("PORTEMON_ANDROID_TEST_SAVE: ${{ vars.PORTEMON_ANDROID_TEST_SAVE }}", acceptance)
        self.assertIn("PORTEMON_ANDROID_DEVICE_REQUIRED: '1'", acceptance)
        downloads = self.download_steps("android-acceptance")
        self.assertEqual(
            [re.search(r"^          name: (.+)$", step, re.MULTILINE).group(1) for step in downloads],
            ["release-payload", "release-android"],
        )
        command = self.step_command("android-acceptance", "Run actual Android release-candidate acceptance")
        for argument in (
            "scripts/packaging/android_acceptance.py", "--payload", "--apk", "--commit", "--version",
            "--version-code", "--rom", "--save", "--serial", "--workspace", "--manifest",
            "--timeout", "--recording-time-limit",
        ):
            self.assertIn(argument, command)
        self.assertIn("android-acceptance-evidence", acceptance)
        self.assertIn("acceptance.json", acceptance)
        self.assertIn("screen-recording-seg", acceptance)
        self.assertIn("screen-recording.mp4", acceptance)
        self.assertIn("if-no-files-found: error", acceptance)
        self.assertIn('test -s "$ACCEPTANCE_WORKSPACE/acceptance.json"', command)
        self.assertIn("python3 scripts/test_android_acceptance.py -v", "\n".join(self.job_block("payload")))
        collect = "\n".join(self.job_block("collect"))
        draft = "\n".join(self.job_block("draft"))
        self.assertIn("needs: [version, payload, windows, macos, linux, android, android-acceptance]", collect)
        self.assertIn("needs: [version, collect, android, android-acceptance]", draft)

    def test_actual_candidate_acceptance_fails_without_a_selected_device_or_private_fixtures(self) -> None:
        command = self.step_command("android-acceptance", "Run actual Android release-candidate acceptance")
        with tempfile.TemporaryDirectory(prefix="portemon-actual-candidate-gate-") as directory:
            environment = os.environ.copy()
            environment.update({
                "COMMIT": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip(),
                "VERSION": RELEASE_VERSION,
                "VERSION_CODE": "42",
                "RUNNER_TEMP": directory,
                "PORTEMON_ANDROID_TEST_SERIAL": "",
                "PORTEMON_ANDROID_TEST_ROM": "",
                "PORTEMON_ANDROID_TEST_SAVE": "",
                "PORTEMON_ANDROID_DEVICE_REQUIRED": "1",
            })
            result = subprocess.run(
                ["bash", "-e", "-c", command], cwd=REPO_ROOT, env=environment,
                check=False, capture_output=True, text=True, timeout=60,
            )
            self.assertNotEqual(result.returncode, 0, "missing actual-candidate inputs must block collection")
            self.assertIn("serial", (result.stdout + result.stderr).lower())
            self.assertFalse((Path(directory) / "android-acceptance" / "acceptance.json").exists())


class AndroidReleaseContractTest(unittest.TestCase):
    def test_release_requires_every_signing_input_before_host_tools(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "previous.apk"
            output.write_bytes(b"previous validated APK\n")
            keystore = root / "ephemeral.keystore"
            keystore.write_bytes(b"not a real key; negative preflight fixture\n")
            values = {
                "PORTEMON_ANDROID_KEYSTORE": str(keystore),
                "PORTEMON_ANDROID_KEYSTORE_PASSWORD": "password-value-must-not-be-logged",
                "PORTEMON_ANDROID_KEY_ALIAS": "alias-value-must-not-be-logged",
                "PORTEMON_ANDROID_KEY_PASSWORD": "key-password-value-must-not-be-logged",
            }
            for missing in ANDROID_SIGNING_VARIABLES:
                for missing_value in (None, ""):
                    with self.subTest(missing=missing, empty=missing_value == ""):
                        environment = dict(values)
                        if missing_value is None:
                            environment.pop(missing)
                        else:
                            environment[missing] = missing_value
                        result = run_android(payload, output, release=True, environment=environment)
                        diagnostics = result.stdout + result.stderr
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(missing, diagnostics)
                        for name in ANDROID_SIGNING_VARIABLES[1:]:
                            self.assertNotIn(values[name], diagnostics)
                        self.assertEqual(output.read_bytes(), b"previous validated APK\n")

    def test_release_rejects_an_unreadable_keystore_without_replacing_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "previous.apk"
            output.write_bytes(b"previous validated APK\n")
            environment = {
                "PORTEMON_ANDROID_KEYSTORE": str(root / "missing.keystore"),
                "PORTEMON_ANDROID_KEYSTORE_PASSWORD": "password-value-must-not-be-logged",
                "PORTEMON_ANDROID_KEY_ALIAS": "alias-value-must-not-be-logged",
                "PORTEMON_ANDROID_KEY_PASSWORD": "key-password-value-must-not-be-logged",
            }
            result = run_android(payload, output, release=True, environment=environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PORTEMON_ANDROID_KEYSTORE", result.stdout + result.stderr)
            for name in ANDROID_SIGNING_VARIABLES[1:]:
                self.assertNotIn(environment[name], result.stdout + result.stderr)
            self.assertEqual(output.read_bytes(), b"previous validated APK\n")

    def test_debug_build_keeps_its_default_identity_without_signing_credentials(self) -> None:
        blocker = android_build_blocker()
        if blocker is not None:
            self.skipTest(f"unverified native Android gate: {blocker}")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_payload(root)
            output = root / "debug.apk"
            result = run_android(payload, output, version_code="7", timeout=1800)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read("assets/game.love"), payload.read_bytes())
            badging = apk_badging(output)
            self.assertIn("package: name='io.github.portemonnitro.portemon.dev'", badging)
            self.assertIn("versionCode='7'", badging)
            self.assertIn(f"versionName='{RELEASE_VERSION}'", badging)

    def test_ephemeral_same_key_release_installs_in_place_and_preserves_isolated_data(self) -> None:
        serial = os.environ.get("PORTEMON_ANDROID_TEST_SERIAL", "").strip()
        adb = shutil.which("adb")
        required = os.environ.get("PORTEMON_ANDROID_DEVICE_REQUIRED") == "1"
        evidence_path = Path(os.environ["PORTEMON_ANDROID_TEST_EVIDENCE"]) if os.environ.get("PORTEMON_ANDROID_TEST_EVIDENCE") else None
        if evidence_path is not None:
            evidence_path.unlink(missing_ok=True)

        def unavailable(message: str) -> None:
            detail = "unverified native Android install/upgrade gate: " + message
            if required:
                self.fail("required release device gate: " + detail)
            self.skipTest(detail)

        if not serial or adb is None:
            unavailable("adb and PORTEMON_ANDROID_TEST_SERIAL are required")
        blocker = android_build_blocker()
        if blocker is not None:
            unavailable(blocker)
        adb_command = [adb, "-s", serial]
        state = subprocess.run(adb_command + ["get-state"], check=False, capture_output=True, text=True)
        if state.returncode != 0 or state.stdout.strip() != "device":
            unavailable("the explicitly selected test device is unavailable")
        root_check = subprocess.run(adb_command + ["shell", "id", "-u"], check=False, capture_output=True, text=True)
        if root_check.returncode != 0 or root_check.stdout.strip() != "0":
            unavailable("an isolated rooted emulator is required")
        package = "io.github.portemonnitro.portemon"
        installed = subprocess.run(adb_command + ["shell", "pm", "path", package], check=False, capture_output=True, text=True)
        if installed.stdout.strip():
            self.fail("refusing to touch a device that already has the shipping application installed")

        with tempfile.TemporaryDirectory(prefix="portemon-android-signing-fixture-") as directory:
            root = Path(directory)
            keystore = root / "ephemeral.keystore"
            password = "ephemeral-test-password"
            alias = "portemon-ephemeral-test"
            keytool = shutil.which("keytool")
            self.assertIsNotNone(keytool)
            subprocess.run(
                [
                    keytool,
                    "-genkeypair",
                    "-keystore",
                    str(keystore),
                    "-storetype",
                    "PKCS12",
                    "-storepass",
                    password,
                    "-keypass",
                    password,
                    "-alias",
                    alias,
                    "-dname",
                    "CN=Portemon Ephemeral Packaging Test",
                    "-keyalg",
                    "RSA",
                    "-keysize",
                    "2048",
                    "-validity",
                    "2",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            environment = {
                "PORTEMON_ANDROID_KEYSTORE": str(keystore),
                "PORTEMON_ANDROID_KEYSTORE_PASSWORD": password,
                "PORTEMON_ANDROID_KEY_ALIAS": alias,
                "PORTEMON_ANDROID_KEY_PASSWORD": password,
            }
            first_version = "0.1.0-alpha.1"
            second_version = "0.1.0-alpha.2"
            first_payload = make_payload(root / "first", version=first_version)
            second_payload = make_payload(root / "second", version=second_version)
            first_apk = root / "first.apk"
            second_apk = root / "second.apk"
            installed_here = False
            try:
                for payload, apk, version, version_code in (
                    (first_payload, first_apk, first_version, "101"),
                    (second_payload, second_apk, second_version, "102"),
                ):
                    result = run_android(
                        payload,
                        apk,
                        version=version,
                        version_code=version_code,
                        release=True,
                        environment=environment,
                        timeout=1800,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn(password, result.stdout + result.stderr)
                    with zipfile.ZipFile(apk) as archive:
                        self.assertEqual(archive.read("assets/game.love"), payload.read_bytes())
                        self.assertFalse(any(name.startswith("lib/x86_64/") for name in archive.namelist()))
                    badging = apk_badging(apk)
                    self.assertIn(f"package: name='{package}'", badging)
                    self.assertNotIn(package + ".dev", badging)
                    self.assertIn(f"versionCode='{version_code}'", badging)
                    self.assertIn(f"versionName='{version}'", badging)
                first_certificate = apk_certificate_digest(first_apk)
                second_certificate = apk_certificate_digest(second_apk)
                self.assertEqual(first_certificate, second_certificate)
                certificate = first_certificate
                first_digest = hashlib.sha256(first_apk.read_bytes()).hexdigest()
                second_digest = hashlib.sha256(second_apk.read_bytes()).hexdigest()

                first_install = subprocess.run(
                    adb_command + ["install", str(first_apk)], check=False, capture_output=True, text=True, timeout=180
                )
                self.assertEqual(first_install.returncode, 0, first_install.stdout + first_install.stderr)
                installed_here = True
                subprocess.run(
                    adb_command + ["shell", "monkey", "-p", package, "1"],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    process = subprocess.run(
                        adb_command + ["shell", "pidof", package], check=False, capture_output=True, text=True
                    )
                    if process.returncode == 0 and process.stdout.strip():
                        break
                    time.sleep(0.2)
                else:
                    self.fail("installed release did not start")
                subprocess.run(adb_command + ["shell", "am", "force-stop", package], check=True)
                marker = f"/data/data/{package}/files/release-upgrade-marker"
                subprocess.run(
                    adb_command + ["shell", "mkdir", "-p", f"/data/data/{package}/files"], check=True
                )
                subprocess.run(
                    adb_command + ["shell", "sh", "-c", f"printf preserved > {marker}"], check=True
                )
                upgrade = subprocess.run(
                    adb_command + ["install", "-r", str(second_apk)],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=180,
                )
                self.assertEqual(upgrade.returncode, 0, upgrade.stdout + upgrade.stderr)
                preserved = subprocess.run(
                    adb_command + ["shell", "cat", marker], check=False, capture_output=True, text=True
                )
                self.assertEqual(preserved.returncode, 0, preserved.stderr)
                self.assertEqual(preserved.stdout, "preserved")
                installed_version = subprocess.run(
                    adb_command + ["shell", "dumpsys", "package", package],
                    check=True, capture_output=True, text=True,
                )
                self.assertIn("versionCode=102", installed_version.stdout)
                subprocess.run(
                    adb_command + ["shell", "monkey", "-p", package, "1"],
                    check=True, capture_output=True, text=True,
                )
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    process = subprocess.run(
                        adb_command + ["shell", "pidof", package], check=False, capture_output=True, text=True
                    )
                    if process.returncode == 0 and process.stdout.strip():
                        break
                    time.sleep(0.2)
                else:
                    self.fail("upgraded release did not relaunch")
                subprocess.run(adb_command + ["shell", "am", "force-stop", package], check=True)
            finally:
                if installed_here:
                    cleanup = subprocess.run(
                        adb_command + ["uninstall", package], check=False, capture_output=True, text=True
                    )
                    self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
                    remaining = subprocess.run(
                        adb_command + ["shell", "pm", "path", package], check=False, capture_output=True, text=True
                    )
                    self.assertFalse(remaining.stdout.strip(), "the isolated test application was not removed")
        self.assertFalse(keystore.exists(), "the ephemeral signing key must be removed with its fixture")
        if evidence_path is not None:
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps({
                "deviceSerial": serial,
                "applicationId": package,
                "firstVersion": first_version,
                "firstVersionCode": 101,
                "secondVersion": second_version,
                "secondVersionCode": 102,
                "firstApkSha256": first_digest,
                "secondApkSha256": second_digest,
                "certificateSha256": certificate,
                "inPlaceInstallAccepted": True,
                "isolatedDataPreserved": True,
                "relaunchedAfterUpgrade": True,
                "applicationRemovedAfterTest": True,
            }, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--love", type=Path, help="validate and smoke an existing payload without rebuilding it")
    parser.add_argument("--listing", type=Path, help="optional listing to compare with the existing payload")
    args, remaining = parser.parse_known_args()
    if args.love is not None:
        try:
            smoke_payload(args.love.resolve(), args.listing.resolve() if args.listing else None)
        except (OSError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            print(f"archive smoke failed: {error}", file=sys.stderr)
            raise SystemExit(1)
        raise SystemExit(0)
    unittest.main(argv=[sys.argv[0], *remaining])
