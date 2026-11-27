#!/usr/bin/env python3
"""Focused contracts for commit-bound Android release-candidate acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "packaging"))
import android_acceptance


COMMIT = "0123456789abcdef0123456789abcdef01234567"
VERSION = "0.1.0-alpha.1"
VERSION_CODE = 42
CERTIFICATE = "a" * 64


def candidate_fixture(root: Path) -> tuple[Path, Path]:
    identity = f'return {{ version = "{VERSION}", commit = "{COMMIT}" }}\n'.encode()
    payload = root / "candidate.love"
    with zipfile.ZipFile(payload, "w") as archive:
        archive.writestr("app/src/BuildInfo.lua", identity)
        archive.writestr("main.lua", "-- fixture\n")
    apk = root / "candidate.apk"
    with zipfile.ZipFile(apk, "w") as archive:
        archive.writestr("assets/game.love", payload.read_bytes())
        archive.writestr("AndroidManifest.xml", b"binary manifest fixture\n")
        archive.writestr("lib/arm64-v8a/liblove.so", b"arm64 fixture\n")
        archive.writestr("lib/armeabi-v7a/liblove.so", b"armv7 fixture\n")
    return payload, apk


def tool_result(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    if command[1:3] == ["dump", "badging"]:
        output = (
            f"package: name='{android_acceptance.APPLICATION_ID}' versionCode='{VERSION_CODE}' "
            f"versionName='{VERSION}'\n"
        )
    else:
        output = f"Signer #1 certificate SHA-256 digest: {CERTIFICATE}\n"
    return subprocess.CompletedProcess(command, 0, output, "")


def valid_manifest(candidate: dict[str, object]) -> dict[str, object]:
    return {
        "operator": "acceptance operator",
        "candidate": candidate,
        "device": {"serial": "emulator-5554", "abi": "arm64-v8a", "pageSize": 16384},
        "journey": {
            name: {"passed": True, "evidence": f"observed {name}"}
            for name in android_acceptance.JOURNEY_STEPS
        },
    }


class AndroidCandidateAcceptanceTest(unittest.TestCase):
    def test_candidate_inspection_binds_real_payload_apk_identity_and_signature(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            payload, apk = candidate_fixture(Path(directory))
            sdk = Path(directory) / "sdk"
            aapt2 = sdk / "build-tools" / "36.0.0" / "aapt2"
            apksigner = sdk / "build-tools" / "36.0.0" / "apksigner"
            aapt2.parent.mkdir(parents=True)
            aapt2.write_bytes(b"")
            apksigner.write_bytes(b"")
            with (
                mock.patch.dict("os.environ", {"ANDROID_SDK_ROOT": str(sdk)}),
                mock.patch.object(android_acceptance.subprocess, "run", side_effect=tool_result),
            ):
                candidate = android_acceptance.inspect_candidate(
                    payload, apk, version=VERSION, commit=COMMIT, version_code=VERSION_CODE,
                )
            self.assertEqual(candidate["commit"], COMMIT)
            self.assertEqual(candidate["version"], VERSION)
            self.assertEqual(candidate["versionCode"], VERSION_CODE)
            self.assertEqual(candidate["applicationId"], android_acceptance.APPLICATION_ID)
            self.assertEqual(candidate["certificateSha256"], CERTIFICATE)
            self.assertEqual(candidate["apkAbis"], ["arm64-v8a", "armeabi-v7a"])
            self.assertEqual(candidate["payloadSha256"], hashlib.sha256(payload.read_bytes()).hexdigest())
            self.assertEqual(candidate["apkSha256"], hashlib.sha256(apk.read_bytes()).hexdigest())

            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("assets/game.love", b"different payload\n")
            with (
                mock.patch.dict("os.environ", {"ANDROID_SDK_ROOT": str(sdk)}),
                mock.patch.object(android_acceptance.subprocess, "run", side_effect=tool_result),
                self.assertRaisesRegex(ValueError, "embedded payload"),
            ):
                android_acceptance.inspect_candidate(
                    payload, apk, version=VERSION, commit=COMMIT, version_code=VERSION_CODE,
                )

    def test_candidate_inspection_rejects_wrong_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, apk = candidate_fixture(root)
            with self.assertRaisesRegex(ValueError, "payload identity"):
                android_acceptance.inspect_candidate(
                    payload, apk, version=VERSION, commit="f" * 40, version_code=VERSION_CODE,
                )
            sdk = root / "sdk"
            aapt2 = sdk / "build-tools" / "36.0.0" / "aapt2"
            aapt2.parent.mkdir(parents=True)
            aapt2.write_bytes(b"")
            with (
                mock.patch.dict("os.environ", {"ANDROID_SDK_ROOT": str(sdk)}),
                mock.patch.object(android_acceptance.subprocess, "run", side_effect=tool_result),
                self.assertRaisesRegex(ValueError, "version does not match"),
            ):
                android_acceptance.inspect_candidate(
                    payload, apk, version=VERSION, commit=COMMIT, version_code=VERSION_CODE + 1,
                )

    def test_manifest_requires_every_actual_candidate_and_touch_journey_fact(self) -> None:
        candidate = {
            "applicationId": android_acceptance.APPLICATION_ID,
            "commit": COMMIT,
            "version": VERSION,
            "versionCode": VERSION_CODE,
            "payloadSha256": "b" * 64,
            "apkSha256": "c" * 64,
            "certificateSha256": CERTIFICATE,
        }
        manifest = valid_manifest(candidate)
        expected_device = manifest["device"]
        self.assertEqual(android_acceptance.verify_manifest(manifest, candidate, expected_device), [])

        mutations = []
        for key, value in (
            ("commit", "f" * 40),
            ("version", "0.1.0-alpha.2"),
            ("versionCode", 43),
            ("payloadSha256", "d" * 64),
            ("apkSha256", "e" * 64),
        ):
            changed = json.loads(json.dumps(manifest))
            changed["candidate"][key] = value
            mutations.append((key, changed))
        changed = json.loads(json.dumps(manifest))
        changed["device"]["pageSize"] = 4096
        mutations.append(("pageSize", changed))
        for step in android_acceptance.JOURNEY_STEPS:
            changed = json.loads(json.dumps(manifest))
            changed["journey"][step]["passed"] = False
            mutations.append((step, changed))
            changed = json.loads(json.dumps(manifest))
            del changed["journey"][step]
            mutations.append((f"missing {step}", changed))
        for label, changed in mutations:
            with self.subTest(case=label):
                self.assertTrue(android_acceptance.verify_manifest(changed, candidate, expected_device))

    def test_private_save_fixture_requires_a_published_game_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "saves").mkdir()
            (root / "saves" / "catalog.lua").write_bytes(b"catalog fixture\n")
            with self.assertRaisesRegex(ValueError, "published saves/games"):
                android_acceptance.save_fixtures(root)
            game = root / "saves" / "games" / "save-00000001.lua"
            game.parent.mkdir()
            game.write_bytes(b"published save fixture\n")
            self.assertEqual(
                android_acceptance.save_fixtures(root)["saves/games/save-00000001.lua"],
                hashlib.sha256(game.read_bytes()).hexdigest(),
            )

    def test_preservation_check_keeps_the_supplied_save_and_requires_the_new_game_save(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rom = b"private ROM fixture"
            original_save = b"original published save"
            record = {
                "managedRom": "roms/" + hashlib.sha1(rom).hexdigest() + ".zip",
                "romSha1": hashlib.sha1(rom).hexdigest(),
                "saveFiles": {
                    "saves/catalog.lua": hashlib.sha256(b"old catalog").hexdigest(),
                    "saves/games/save-00000001.lua": hashlib.sha256(original_save).hexdigest(),
                },
            }
            args = argparse.Namespace(serial="emulator-5554", workspace=root)

            def adb_result(_serial: str, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
                if arguments[0] == "pull":
                    source, destination = arguments[1], Path(arguments[2])
                    if source.endswith(record["managedRom"]):
                        with zipfile.ZipFile(destination, "w") as archive:
                            archive.writestr("game.nds", rom)
                    elif source.endswith("/saves"):
                        games = destination / "games"
                        games.mkdir(parents=True)
                        (games / "save-00000001.lua").write_bytes(original_save)
                        (games / "save-00000002.lua").write_bytes(b"new game save")
                        (destination / "catalog.lua").write_bytes(b"updated catalog")
                    else:
                        raise AssertionError(f"unexpected pull: {source}")
                return subprocess.CompletedProcess(["adb"], 0, "", "")

            with mock.patch.object(android_acceptance, "adb", side_effect=adb_result):
                preserved = android_acceptance.verify_preserved_data(args, record)
            self.assertEqual(preserved["managedRomSha1"], record["romSha1"])
            self.assertEqual(set(preserved["preservedSaveFiles"]), {"saves/games/save-00000001.lua"})
            self.assertEqual(preserved["newPublishedSaveFiles"], ["saves/games/save-00000002.lua"])

            def missing_new_save(_serial: str, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
                if arguments[0] == "pull":
                    source, destination = arguments[1], Path(arguments[2])
                    if source.endswith(record["managedRom"]):
                        with zipfile.ZipFile(destination, "w") as archive:
                            archive.writestr("game.nds", rom)
                    elif source.endswith("/saves"):
                        games = destination / "games"
                        games.mkdir(parents=True)
                        (games / "save-00000001.lua").write_bytes(original_save)
                return subprocess.CompletedProcess(["adb"], 0, "", "")

            with (
                mock.patch.object(android_acceptance, "adb", side_effect=missing_new_save),
                self.assertRaisesRegex(ValueError, "did not publish a new save"),
            ):
                android_acceptance.verify_preserved_data(args, record)

    def test_cleanup_only_removes_the_installation_owned_by_the_selected_device(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "ownership.json"
            owned = {
                "serial": "emulator-5554",
                "applicationId": android_acceptance.APPLICATION_ID,
                "runId": "abc12345",
                "remoteRom": "/sdcard/Download/portemon-acceptance-abc12345.nds",
            }
            marker.write_text(json.dumps(owned))
            with self.assertRaisesRegex(ValueError, "another device"):
                android_acceptance.cleanup(argparse.Namespace(serial="emulator-5556", workspace=root))
            self.assertTrue(marker.exists())

            seen_rm: list[tuple[str, ...]] = []

            def adb_result(_serial: str, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
                if arguments[:2] == ("shell", "ls"):
                    return subprocess.CompletedProcess(["adb"], 1, "", "No such file")
                if arguments[:2] == ("shell", "rm"):
                    seen_rm.append(arguments)
                    for target in arguments[2:]:
                        if target.startswith("-"):
                            continue
                        self.assertIn("abc12345", target, "cleanup must remove only its owned run files")
                    return subprocess.CompletedProcess(["adb"], 0, "", "")
                return subprocess.CompletedProcess(["adb"], 0, "", "")

            with mock.patch.object(android_acceptance, "adb", side_effect=adb_result):
                android_acceptance.cleanup(argparse.Namespace(serial="emulator-5554", workspace=root))
            self.assertFalse(marker.exists())
            self.assertTrue(seen_rm, "cleanup removes its owned device files")

            marker.write_text(json.dumps(owned))
            with (
                mock.patch.object(android_acceptance, "adb", return_value=subprocess.CompletedProcess(["adb"], 0, "package:/base.apk\n", "")),
                self.assertRaisesRegex(ValueError, "could not be removed"),
            ):
                android_acceptance.cleanup(argparse.Namespace(serial="emulator-5554", workspace=root))
            self.assertTrue(marker.exists(), "failed cleanup must retain ownership for retry")

    def test_owned_staging_uses_unique_run_paths_and_scoped_recorder_stop(self) -> None:
        run_id = "deadbeef"
        self.assertIn(run_id, android_acceptance.remote_rom(run_id))
        self.assertIn(run_id, android_acceptance.remote_recording(run_id, 1))
        self.assertNotEqual(
            android_acceptance.remote_recording(run_id, 1), android_acceptance.remote_recording(run_id, 2)
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logcat = mock.Mock()
            logcat.poll.return_value = 1
            recorder = mock.Mock()
            recorder.poll.return_value = 1
            recorder.wait.return_value = 0
            segment_local = root / "screen-recording-seg1.mp4"

            def adb_pull(_serial: str, *arguments: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
                if arguments[0] == "pull":
                    Path(arguments[2]).write_bytes(b"segment fixture")
                return subprocess.CompletedProcess(["adb"], 0, "", "")

            with mock.patch.object(android_acceptance, "adb", side_effect=adb_pull) as adb_mock:
                android_acceptance.stop_capture_segment(
                    "emulator-5554", root, logcat, recorder,
                    android_acceptance.remote_recording(run_id, 1),
                    segment_local, run_id,
                )
            pkill = [call for call in adb_mock.call_args_list if "pkill" in str(call)]
            self.assertTrue(pkill, "recorder shutdown must go through pkill")
            self.assertIn(run_id, str(pkill[0]), "recorder shutdown must match only this run")

    def test_recording_limit_is_bounded_independently_of_acceptance_timeout(self) -> None:
        with self.assertRaisesRegex(ValueError, "recording time limit"):
            android_acceptance.start_captures("emulator-5554", Path("/tmp"), 3600, "/sdcard/owned.mp4")
        with self.assertRaisesRegex(ValueError, "recording time limit"):
            android_acceptance.prepare(
                argparse.Namespace(
                    serial="emulator-5554", payload=Path("missing"), apk=Path("missing"),
                    rom=Path("missing"), save=Path("missing"), timeout=3600,
                    recording_time_limit=3600, workspace=Path("/tmp/ws"), manifest=Path("/tmp/ws/m.json"),
                    version=VERSION, commit=COMMIT, version_code=VERSION_CODE,
                )
            )

    def test_scoped_logcat_ignores_unrelated_device_noise(self) -> None:
        unrelated = b"01-01 00:00:00.000  123  456 I OtherApp: Error: unrelated failure\n"
        scoped = android_acceptance.app_scoped_log(unrelated)
        self.assertEqual(scoped, b"", "unrelated device logs must not gate the release")
        app_log = (
            b"01-01 00:00:00.000  123  456 I portemon: starting\n"
            + unrelated
            + b"01-01 00:00:01.000  123  456 E portemon: Error: boot failed\n"
        )
        self.assertIn(b"Error", android_acceptance.app_scoped_log(app_log))

    def test_run_waits_for_the_completed_human_manifest_before_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "journey-manifest.json"
            args = argparse.Namespace(
                serial="emulator-5554", workspace=root, manifest=manifest, timeout=30,
                recording_time_limit=150, version=VERSION, commit=COMMIT, version_code=VERSION_CODE,
            )
            logcat = mock.Mock()
            recorder = mock.Mock()
            recorder.poll.return_value = None

            def finish_journey(_: float) -> None:
                manifest.write_text("{}\n")

            record = {"candidate": {}, "runId": "abc12345", "device": {}}

            def fake_stop(serial, workspace, logcat_arg, recorder_arg, remote, local_path, run_id, **kwargs):
                Path(local_path).write_bytes(b"segment fixture")

            with (
                mock.patch.object(android_acceptance, "prepare", return_value=record),
                mock.patch.object(android_acceptance, "start_captures", return_value=(logcat, recorder)),
                mock.patch.object(android_acceptance.time, "monotonic", return_value=0.0),
                mock.patch.object(android_acceptance.time, "sleep", side_effect=finish_journey),
                mock.patch.object(android_acceptance, "stop_capture_segment", side_effect=fake_stop) as stop,
                mock.patch.object(android_acceptance, "verify") as verify,
            ):
                android_acceptance.run_acceptance(args)
            self.assertTrue(stop.called, "bounded recording segments must be pulled")
            verify.assert_called_once_with(args, record)
            self.assertTrue((root / "screen-recording.mp4").is_file())

    def test_required_mode_rejects_a_missing_explicit_device_before_candidate_io(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for serial, expected in (("", "serial"), ("emulator-5554", "private rom/save")):
                with self.subTest(serial=serial):
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(REPO_ROOT / "scripts" / "packaging" / "android_acceptance.py"),
                            "run",
                            "--serial", serial,
                            "--payload", str(root / "missing.love"),
                            "--apk", str(root / "missing.apk"),
                            "--commit", COMMIT,
                            "--version", VERSION,
                            "--version-code", str(VERSION_CODE),
                            "--rom", str(root / "missing.nds"),
                            "--save", str(root / "missing-save"),
                            "--workspace", str(root / "workspace"),
                            "--manifest", str(root / "workspace" / "manifest.json"),
                            "--timeout", "1",
                        ],
                        cwd=REPO_ROOT, check=False, capture_output=True, text=True, timeout=15,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, (result.stdout + result.stderr).lower())


if __name__ == "__main__":
    unittest.main()
