#!/usr/bin/env python3
"""Bind Android release acceptance evidence to the actual signed candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
from typing import BinaryIO
import zipfile


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack_love import validate_identity


APPLICATION_ID = "io.github.portemonnitro.portemon"
ANDROID_ABIS = {"arm64-v8a", "armeabi-v7a"}
JOURNEY_STEPS = (
    "startupAndImport",
    "touchNewGameNamingFieldMenu",
    "touchReturnToGameSelection",
    "touchRotationAndBackground",
    "managedRomAndSavePreserved",
)
# Device-side staging is per-run owned: every acceptance run mints a unique
# runId and stages only files carrying that identity. Cleanup removes only
# those owned paths, never fixed shared names, and capture shutdown signals
# only the recorder started by this run (matched via -f on its unique path).
APP_FILES = f"/data/data/{APPLICATION_ID}/files"
RECORDING_TIME_LIMIT_MAX = 180
RECORDING_TIME_LIMIT_DEFAULT = 150


def remote_rom(run_id: str) -> str:
    return f"/sdcard/Download/portemon-acceptance-{run_id}.nds"


def remote_recording(run_id: str, segment: int) -> str:
    return f"/sdcard/portemon-acceptance-{run_id}-seg{segment}.mp4"


def local_recording(workspace: Path, segment: int) -> Path:
    return workspace / f"screen-recording-seg{segment}.mp4"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha1(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stream_sha1(handle: BinaryIO) -> str:
    digest = hashlib.sha1()
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def adb(serial: str, *arguments: str, check: bool = True, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["adb", "-s", serial, *arguments], check=check, capture_output=True, text=True, timeout=timeout,
    )


def inspect_candidate(payload: Path, apk: Path, *, version: str, commit: str, version_code: int) -> dict[str, object]:
    validate_identity(version, commit)
    if version == "dev" or version_code <= 0:
        raise ValueError("a release version and positive versionCode are required")
    with zipfile.ZipFile(payload) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("candidate payload contains duplicate members")
        identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
        found_version = re.search(r'version\s*=\s*"([^"]+)"', identity)
        found_commit = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
        if found_version is None or found_commit is None or (found_version.group(1), found_commit.group(1)) != (version, commit):
            raise ValueError("payload identity does not match the release candidate")
        if archive.testzip() is not None:
            raise ValueError("candidate payload CRC verification failed")
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("candidate APK contains duplicate members")
        if archive.read("assets/game.love") != payload.read_bytes():
            raise ValueError("APK embedded payload differs from the release candidate")
        abis = {name.split("/")[1] for name in names if name.startswith("lib/") and name.endswith(".so")}
        if abis != ANDROID_ABIS or "AndroidManifest.xml" not in names:
            raise ValueError("candidate APK has an invalid release ABI set or manifest")
        if archive.testzip() is not None:
            raise ValueError("candidate APK CRC verification failed")
    sdk = Path(os.environ["ANDROID_SDK_ROOT"])
    tools = sdk / "build-tools" / "36.0.0"
    badging = subprocess.run(
        [str(tools / "aapt2"), "dump", "badging", str(apk)], check=True, capture_output=True, text=True,
    ).stdout
    if f"package: name='{APPLICATION_ID}'" not in badging:
        raise ValueError("candidate APK has the wrong application ID")
    if f"versionCode='{version_code}'" not in badging or f"versionName='{version}'" not in badging:
        raise ValueError("candidate APK version does not match the release identity")
    signed = subprocess.run(
        [str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    certificate = re.search(r"certificate SHA-256 digest: ([0-9a-fA-F]{64})", signed)
    if certificate is None:
        raise ValueError("candidate APK signature did not report a certificate")
    return {
        "applicationId": APPLICATION_ID,
        "commit": commit,
        "version": version,
        "versionCode": version_code,
        "payloadSha256": sha256(payload),
        "apkSha256": sha256(apk),
        "certificateSha256": certificate.group(1).lower(),
        "apkAbis": sorted(abis),
    }


def device_facts(serial: str) -> dict[str, object]:
    state = adb(serial, "get-state", check=False)
    if state.returncode != 0 or state.stdout.strip() != "device":
        raise ValueError("the explicitly selected Android device is unavailable")
    root = adb(serial, "shell", "id", "-u", check=False)
    if root.returncode != 0 or root.stdout.strip() != "0":
        raise ValueError("an isolated rooted Android test device is required")
    abi = adb(serial, "shell", "getprop", "ro.product.cpu.abi").stdout.strip()
    page_size = int(adb(serial, "shell", "getconf", "PAGE_SIZE").stdout.strip())
    if abi not in ANDROID_ABIS or page_size not in (4096, 16384):
        raise ValueError(f"unsupported acceptance device ABI/page size: {abi}/{page_size}")
    return {"serial": serial, "abi": abi, "pageSize": page_size}


def save_fixtures(root: Path) -> dict[str, str]:
    if not root.is_dir():
        raise ValueError("the private acceptance save fixture must be a directory")
    fixtures = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"acceptance save fixture contains a symlink: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if relative.parts[0] != "saves" or any(part in (".", "..") or re.fullmatch(r"[A-Za-z0-9._-]+", part) is None for part in relative.parts):
            raise ValueError(f"acceptance save fixture must contain safe saves/ paths: {relative}")
        fixtures[relative.as_posix()] = sha256(path)
    if not fixtures:
        raise ValueError("the private acceptance save fixture is empty")
    if not any(name.startswith("saves/games/") and name.endswith(".lua") for name in fixtures):
        raise ValueError("the private acceptance save fixture must include a published saves/games/*.lua payload")
    return fixtures


def prepare(args: argparse.Namespace) -> dict[str, object]:
    if not args.serial.strip():
        raise ValueError("an explicit device serial is required")
    recording_limit = getattr(args, "recording_time_limit", RECORDING_TIME_LIMIT_DEFAULT)
    if recording_limit <= 0 or recording_limit > RECORDING_TIME_LIMIT_MAX:
        raise ValueError(f"recording time limit must be 1..{RECORDING_TIME_LIMIT_MAX} seconds")
    if not args.payload.is_file() or not args.apk.is_file() or not args.rom.is_file() or not args.save.is_dir():
        raise ValueError("candidate payload/APK and private ROM/save fixtures are required")
    if args.timeout <= 0:
        raise ValueError("acceptance timeout must be positive")
    if not args.workspace.is_absolute() or not args.manifest.is_absolute():
        raise ValueError("acceptance workspace and manifest paths must be absolute")
    workspace = args.workspace.resolve()
    manifest = args.manifest.resolve()
    if workspace == Path(workspace.anchor) or workspace not in manifest.parents:
        raise ValueError("acceptance manifest must be inside a non-root owned workspace")
    if (args.workspace / "candidate.json").exists() or (args.workspace / "ownership.json").exists():
        raise ValueError("acceptance workspace already contains a candidate; clean the previous run first")
    args.workspace.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    template_path = args.workspace / "journey-manifest.template.json"
    if args.manifest.exists() or template_path.exists():
        raise ValueError("acceptance manifest already exists; start with a clean workspace")

    candidate = inspect_candidate(
        args.payload, args.apk, version=args.version, commit=args.commit, version_code=args.version_code,
    )
    device = device_facts(args.serial)
    installed = adb(args.serial, "shell", "pm", "path", APPLICATION_ID, check=False)
    if installed.stdout.strip():
        raise ValueError("refusing to touch a device that already has the shipping application installed")
    fixtures = save_fixtures(args.save)
    rom_sha1 = sha1(args.rom)
    run_id = f"{args.commit[:8]}-{args.version_code}-{uuid.uuid4().hex[:8]}"
    owned_rom = remote_rom(run_id)
    # Unique per-run staging: refuse only if our own unique path somehow
    # already exists; never touch fixed shared names or preexisting files.
    existing = adb(args.serial, "shell", "ls", owned_rom, check=False)
    if existing.returncode == 0 and existing.stdout.strip():
        raise ValueError("owned device staging already exists; retry with a fresh workspace")

    write_json(
        args.workspace / "ownership.json",
        {"serial": args.serial, "applicationId": APPLICATION_ID, "runId": run_id, "remoteRom": owned_rom},
    )
    adb(args.serial, "install", str(args.apk), timeout=300)
    adb(args.serial, "shell", "mkdir", "-p", APP_FILES)
    adb(args.serial, "push", str(args.rom), owned_rom, timeout=300)
    for relative in fixtures:
        remote = f"{APP_FILES}/{relative}"
        adb(args.serial, "shell", "mkdir", "-p", str(Path(remote).parent))
        adb(args.serial, "push", str(args.save / relative), remote, timeout=300)

    record = {
        "candidate": candidate,
        "device": device,
        "runId": run_id,
        "remoteRom": owned_rom,
        "managedRom": f"roms/{rom_sha1}.zip",
        "romSha1": rom_sha1,
        "saveFiles": fixtures,
    }
    write_json(args.workspace / "candidate.json", record)
    template = {
        "operator": "",
        "candidate": candidate,
        "device": device,
        "journey": {name: {"passed": False, "evidence": ""} for name in JOURNEY_STEPS},
    }
    write_json(template_path, template)
    print(f"Acceptance manifest template: {template_path}")
    print(f"Completed acceptance manifest: {args.manifest}")
    print(f"Private test ROM is available through the document picker at: {owned_rom}")
    print("Launch the installed Portémon Nitro app.")
    print("Use the touch-only journey; both edition slots are direct actions, with no separate Run or Add Game control.")
    print("Startup/import: interrupt boot from a slot, tap a missing edition, exercise SAF cancel and wrong-edition rejection, then import the matching ROM and observe its banner.")
    print("Game entry: tap the installed edition directly, complete New Game/naming/field/menu, and publish a new save.")
    print("Return: use the in-game route back to the two-slot selector without auto-launching another edition.")
    print("Rotation/background: rotate and background/resume at the selector and during the game, then repeat warm and cold startup and interrupt boot from a slot.")
    print("Set every existing journey entry to passed=true with observed evidence; the managed ROM and supplied saves/games/*.lua payload must remain unchanged.")
    print("The harness will verify the actual candidate, managed ROM, supplied save files, logcat, and screen recording.")
    return record


def verify_manifest(
    manifest: object,
    candidate: dict[str, object],
    device: dict[str, object] | None = None,
) -> list[str]:
    errors = []
    if not isinstance(manifest, dict) or set(manifest) != {"operator", "candidate", "device", "journey"}:
        return ["acceptance manifest has an invalid shape"]
    if not isinstance(manifest["operator"], str) or not manifest["operator"].strip():
        errors.append("acceptance operator is required")
    if manifest["candidate"] != candidate:
        errors.append("acceptance manifest is not bound to the actual candidate")
    if device is not None and manifest["device"] != device:
        errors.append("acceptance manifest is not bound to the selected device/ABI/page size")
    journey = manifest["journey"]
    if not isinstance(journey, dict) or set(journey) != set(JOURNEY_STEPS):
        errors.append("acceptance manifest must contain every required journey step")
    else:
        for name in JOURNEY_STEPS:
            entry = journey[name]
            if (
                not isinstance(entry, dict)
                or set(entry) != {"passed", "evidence"}
                or entry["passed"] is not True
                or not isinstance(entry["evidence"], str)
                or not entry["evidence"].strip()
            ):
                errors.append(f"acceptance journey lacks observed evidence: {name}")
    return errors


def start_captures(
    serial: str, workspace: Path, recording_time_limit: int, remote_recording: str,
) -> tuple[subprocess.Popen[bytes], subprocess.Popen[bytes]]:
    if recording_time_limit <= 0 or recording_time_limit > RECORDING_TIME_LIMIT_MAX:
        raise ValueError(f"recording time limit must be 1..{RECORDING_TIME_LIMIT_MAX} seconds")
    adb(serial, "logcat", "-c")
    adb(serial, "shell", "rm", "-f", remote_recording)
    log = (workspace / "logcat.txt").open("ab")
    try:
        logcat = subprocess.Popen(
            ["adb", "-s", serial, "logcat", "-v", "threadtime"], stdout=log, stderr=subprocess.STDOUT,
        )
    finally:
        log.close()
    try:
        recorder = subprocess.Popen(
            ["adb", "-s", serial, "shell", "screenrecord", "--time-limit", str(recording_time_limit), remote_recording],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except BaseException:
        logcat.terminate()
        try:
            logcat.wait(timeout=10)
        except subprocess.TimeoutExpired:
            logcat.kill()
            logcat.wait(timeout=5)
        raise
    return logcat, recorder


def stop_capture_segment(
    serial: str,
    workspace: Path,
    logcat: subprocess.Popen[bytes] | None,
    recorder: subprocess.Popen[bytes],
    remote_recording: str,
    local_path: Path,
    run_id: str,
    keep_logcat: bool = False,
) -> None:
    # Stop only this run's recorder: match its unique device path so an
    # unrelated screenrecord on the same device is never interrupted.
    adb(serial, "shell", "pkill", "-INT", "-f", f"screenrecord.*{run_id}", check=False)
    try:
        recorder.wait(timeout=20)
    except subprocess.TimeoutExpired:
        recorder.terminate()
        try:
            recorder.wait(timeout=10)
        except subprocess.TimeoutExpired:
            recorder.kill()
            recorder.wait(timeout=5)
    adb(serial, "pull", remote_recording, str(local_path), timeout=120)
    if not local_path.is_file() or local_path.stat().st_size == 0:
        raise ValueError("the acceptance screen recording segment is missing or empty")
    if not keep_logcat and logcat is not None and logcat.poll() is None:
        logcat.terminate()
        try:
            logcat.wait(timeout=10)
        except subprocess.TimeoutExpired:
            logcat.kill()
            logcat.wait(timeout=5)


def stop_captures(
    serial: str,
    workspace: Path,
    logcat: subprocess.Popen[bytes],
    recorder: subprocess.Popen[bytes],
    remote_recording: str,
    local_path: Path,
    run_id: str,
) -> None:
    stop_capture_segment(serial, workspace, logcat, recorder, remote_recording, local_path, run_id)


def verify_preserved_data(args: argparse.Namespace, record: dict[str, object]) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="device-data-", dir=args.workspace) as directory:
        root = Path(directory)
        managed = root / "managed.zip"
        adb(args.serial, "pull", f"{APP_FILES}/{record['managedRom']}", str(managed), timeout=300)
        with zipfile.ZipFile(managed) as archive:
            if archive.namelist() != ["game.nds"] or archive.testzip() is not None:
                raise ValueError("the imported managed ROM is not a valid one-member archive")
            with archive.open("game.nds") as member:
                rom_sha1 = stream_sha1(member)
        if rom_sha1 != record["romSha1"]:
            raise ValueError("the managed ROM bytes changed during acceptance")
        saves = root / "saves"
        adb(args.serial, "pull", f"{APP_FILES}/saves", str(saves), timeout=300)
        preserved = {}
        for relative, wanted in record["saveFiles"].items():
            if not relative.startswith("saves/games/"):
                continue
            local = root / relative
            if sha256(local) != wanted:
                raise ValueError(f"the supplied published save changed during acceptance: {relative}")
            preserved[relative] = wanted
        published = {
            path.relative_to(root).as_posix(): sha256(path)
            for path in sorted((root / "saves" / "games").glob("*.lua"))
        }
        fixture_saves = set(preserved)
        new_saves = sorted(set(published).difference(fixture_saves))
        if not new_saves:
            raise ValueError("the New Game journey did not publish a new save")
    return {
        "managedRomSha1": rom_sha1,
        "preservedSaveFiles": preserved,
        "publishedSaveFiles": published,
        "newPublishedSaveFiles": new_saves,
    }


def app_scoped_log(log: bytes) -> bytes:
    # Scope runtime failure detection to the tested app instead of failing
    # the release on unrelated device logs. Keep lines that name the app
    # package, the engine, or an Android runtime crash; unrelated chatter is
    # retained on disk but never gates publication.
    kept = []
    for line in log.splitlines(keepends=True):
        lowered = line.lower()
        if (
            APPLICATION_ID.encode() in line
            or b"portemon" in lowered
            or b"love" in lowered
            or b"androidruntime" in lowered
            or b"fatal exception" in lowered
        ):
            kept.append(line)
    return b"".join(kept)


def verify(args: argparse.Namespace, record: dict[str, object]) -> None:
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    errors = verify_manifest(manifest, record["candidate"], record["device"])
    if errors:
        raise ValueError("; ".join(errors))
    actual_candidate = inspect_candidate(
        args.payload, args.apk, version=args.version, commit=args.commit, version_code=args.version_code,
    )
    if actual_candidate != record["candidate"]:
        raise ValueError("candidate bytes or identity changed during acceptance")
    if device_facts(args.serial) != record["device"]:
        raise ValueError("selected device/ABI/page size changed during acceptance")
    installed = adb(args.serial, "shell", "dumpsys", "package", APPLICATION_ID).stdout
    if f"versionCode={args.version_code}" not in installed or f"versionName={args.version}" not in installed:
        raise ValueError("the installed package is not the accepted release candidate")
    preserved = verify_preserved_data(args, record)
    log = (args.workspace / "logcat.txt").read_bytes()
    segments = sorted(args.workspace.glob("screen-recording-seg*.mp4"))
    # Backwards compatibility: a single-segment run also publishes the legacy
    # screen-recording.mp4 alias alongside its segment file.
    legacy = args.workspace / "screen-recording.mp4"
    if legacy.is_file() and legacy not in segments:
        segments.append(legacy)
    if not log or not segments or any(not p.is_file() or p.stat().st_size == 0 for p in segments):
        raise ValueError("acceptance logcat and screen recording are required")
    scoped = app_scoped_log(log)
    if not scoped:
        raise ValueError("acceptance logcat contains no tested-app output")
    if re.search(rb"(?i)Error:|stack traceback|boot\.lua|\.lua:[0-9]+:|fatal exception", scoped):
        raise ValueError("acceptance logcat contains a tested-app runtime failure")
    evidence = {f"recording{index}Sha256": sha256(path) for index, path in enumerate(sorted(segments), start=1)}
    acceptance = {
        "verified": True,
        "candidate": actual_candidate,
        "device": record["device"],
        "runId": record.get("runId"),
        "journey": manifest["journey"],
        "operator": manifest["operator"],
        **preserved,
        "evidence": {
            "manifestSha256": sha256(args.manifest),
            "logcatSha256": sha256(args.workspace / "logcat.txt"),
            **evidence,
        },
    }
    write_json(args.workspace / "acceptance.json", acceptance)
    print(f"android_acceptance: verified actual candidate {args.commit} {args.version} {args.version_code}")


def manifest_ready(path: Path) -> bool:
    try:
        return isinstance(json.loads(path.read_text(encoding="utf-8")), dict)
    except (OSError, json.JSONDecodeError):
        return False


def run_acceptance(args: argparse.Namespace) -> None:
    recording_limit = getattr(args, "recording_time_limit", RECORDING_TIME_LIMIT_DEFAULT)
    if recording_limit <= 0 or recording_limit > RECORDING_TIME_LIMIT_MAX:
        raise ValueError(f"recording time limit must be 1..{RECORDING_TIME_LIMIT_MAX} seconds")
    record = prepare(args)
    run_id = str(record["runId"])
    logcat: subprocess.Popen[bytes] | None = None
    recorder: subprocess.Popen[bytes] | None = None
    segment = 1
    try:
        # Truncate the shared log once; segments append so rotation stages
        # stay in one evidence file while each screenrecord stays bounded.
        if (args.workspace / "logcat.txt").exists():
            (args.workspace / "logcat.txt").unlink()
        remote = remote_recording(run_id, segment)
        logcat, recorder = start_captures(args.serial, args.workspace, recording_limit, remote)
        deadline = time.monotonic() + args.timeout
        while not manifest_ready(args.manifest):
            assert recorder is not None
            if recorder.poll() is not None:
                # One bounded segment elapsed: pull it and start the next so
                # an hour-budget journey never assumes a single recording.
                local_path = local_recording(args.workspace, segment)
                stop_capture_segment(args.serial, args.workspace, logcat, recorder, remote, local_path, run_id, keep_logcat=True)
                # Keep the legacy alias pointing at the latest pulled segment
                # so existing evidence collectors keep working.
                legacy = args.workspace / "screen-recording.mp4"
                legacy.write_bytes(local_path.read_bytes())
                if time.monotonic() >= deadline:
                    raise ValueError("timed out waiting for the human acceptance manifest")
                segment += 1
                remote = remote_recording(run_id, segment)
                # New recorder segment; the logcat stream keeps appending.
                adb(args.serial, "shell", "rm", "-f", remote)
                recorder = subprocess.Popen(
                    ["adb", "-s", args.serial, "shell", "screenrecord", "--time-limit", str(recording_limit), remote],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                continue
            if time.monotonic() >= deadline:
                raise ValueError("timed out waiting for the human acceptance manifest")
            time.sleep(2)
        assert logcat is not None and recorder is not None
        local_path = local_recording(args.workspace, segment)
        stop_capture_segment(args.serial, args.workspace, logcat, recorder, remote, local_path, run_id)
        legacy = args.workspace / "screen-recording.mp4"
        legacy.write_bytes(local_path.read_bytes())
        logcat = recorder = None
        verify(args, record)
    finally:
        if logcat is not None and recorder is not None:
            try:
                local_path = local_recording(args.workspace, segment)
                stop_capture_segment(args.serial, args.workspace, logcat, recorder, remote_recording(run_id, segment), local_path, run_id)
            except Exception:
                if logcat.poll() is None:
                    logcat.terminate()
                if recorder.poll() is None:
                    recorder.terminate()


def cleanup(args: argparse.Namespace) -> None:
    marker = args.workspace / "ownership.json"
    if not marker.is_file():
        print("android_acceptance: no owned installation to clean")
        return
    ownership = json.loads(marker.read_text(encoding="utf-8"))
    if ownership.get("serial") != args.serial or ownership.get("applicationId") != APPLICATION_ID:
        raise ValueError("refusing to clean an acceptance installation owned by another device")
    run_id = ownership.get("runId")
    owned_rom = ownership.get("remoteRom")
    adb(args.serial, "uninstall", APPLICATION_ID, check=False)
    remaining = adb(args.serial, "shell", "pm", "path", APPLICATION_ID, check=False)
    if remaining.stdout.strip():
        raise ValueError("the isolated acceptance application could not be removed")
    # Remove only this run's owned device files. A failed prepare never
    # deletes a preexisting file it did not acquire.
    if isinstance(run_id, str) and run_id:
        targets = []
        if isinstance(owned_rom, str) and owned_rom:
            targets.append(owned_rom)
        # Segment recordings share the runId prefix; remove them without
        # touching unrelated screenrecord files on the device.
        listing = adb(args.serial, "shell", "ls", f"/sdcard/portemon-acceptance-{run_id}-seg*.mp4", check=False)
        if listing.returncode == 0:
            for name in listing.stdout.split():
                name = name.strip()
                if name.startswith(f"/sdcard/portemon-acceptance-{run_id}-seg"):
                    targets.append(name)
        if targets:
            adb(args.serial, "shell", "rm", "-f", *targets, check=False)
    marker.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--serial", required=True)
    run.add_argument("--payload", required=True, type=Path)
    run.add_argument("--apk", required=True, type=Path)
    run.add_argument("--commit", required=True)
    run.add_argument("--version", required=True)
    run.add_argument("--version-code", required=True, type=int)
    run.add_argument("--rom", required=True, type=Path)
    run.add_argument("--save", required=True, type=Path)
    run.add_argument("--workspace", required=True, type=Path)
    run.add_argument("--manifest", required=True, type=Path)
    run.add_argument("--timeout", required=True, type=int, help="overall human acceptance deadline in seconds")
    run.add_argument(
        "--recording-time-limit",
        required=False,
        type=int,
        default=RECORDING_TIME_LIMIT_DEFAULT,
        help=f"bounded per-segment screenrecord limit in seconds (1..{RECORDING_TIME_LIMIT_MAX})",
    )
    clean = subparsers.add_parser("cleanup")
    clean.add_argument("--serial", required=True)
    clean.add_argument("--workspace", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "run":
            run_acceptance(args)
        else:
            cleanup(args)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"android_acceptance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
