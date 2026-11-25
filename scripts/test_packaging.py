#!/usr/bin/env python3
"""Black-box closure and replacement contracts for the portable LÖVE payload."""

from __future__ import annotations

from pathlib import Path
import argparse
import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
PACKER = REPO_ROOT / "scripts" / "pack_love.py"
COMMIT = "0123456789abcdef0123456789abcdef01234567"

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

AUDIO_FILES = tuple(
    f"assets/audio/launcher/{name}.ogg"
    for name in ("boot", "focus", "confirm", "back", "error")
) + tuple(
    f"assets/audio/launcher/{name}.txt"
    for name in ("boot", "focus", "confirm", "back", "error")
)

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
    for relative in FONT_FILES + ICON_FILES:
        write_file(root, relative, b"isolated packaging fixture\n")
    for relative in AUDIO_FILES:
        write_file(root, relative, b"TEST FIXTURE; synthetic bytes; not release provenance\n")
    for relative in EXCLUDED_FILES:
        write_file(root, relative, b"must not ship\n")
    if PACKER.is_file():
        target = root / "scripts" / "pack_love.py"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PACKER, target)


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
            *ICON_FILES,
            *AUDIO_FILES,
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
        save = root / "save"
        cache = root / "cache"
        for path in (untouched_dir, probe_dir, cwd, save, cache):
            path.mkdir()
        untouched = untouched_dir / "portemon.love"
        shutil.copyfile(payload, untouched)
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(root / "home"),
                "XDG_DATA_HOME": str(save),
                "XDG_CACHE_HOME": str(cache),
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
                if info.filename != "main.lua":
                    archive.writestr(info, source_archive.read(info.filename))
            archive.writestr("main.lua", wrapper)
        wrapped.replace(probe)
        result = subprocess.run(
            [love, str(probe)], cwd=cwd, env=environment, capture_output=True, text=True, timeout=45,
        )
        if result.returncode != 0 or "ARCHIVE_SMOKE_OK" not in result.stdout:
            raise RuntimeError(f"archive probe failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        if {path.name for path in probe_dir.iterdir()} != {"probe.love"}:
            raise RuntimeError("archive probe wrote beside its payload")

    if hashlib.sha256(payload.read_bytes()).hexdigest() != original_hash:
        raise RuntimeError("archive smoke mutated the original payload")
    with zipfile.ZipFile(payload) as archive:
        if member_digest(archive) != before:
            raise RuntimeError("archive smoke mutated packaged members")
    print(f"archive smoke passed: {version} {commit} {original_hash}")


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
                for relative in SOURCE_FILES[2:] + FONT_FILES + ICON_FILES + AUDIO_FILES:
                    self.assertIn(relative, names)
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

            development = root / "development.love"
            development_listing = root / "development.txt"
            result = run_packer(root, development, development_listing, version="dev")
            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(development) as archive:
                identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
                self.assertRegex(identity, r'version\s*=\s*"dev"')
                self.assertRegex(identity, rf'commit\s*=\s*"{COMMIT}"')

    def test_missing_required_source_or_asset_preserves_the_previous_payload_and_listing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portemon.love"
            listing = root / "listing.txt"
            for relative in ("gen4/battle.lua", "assets/audio/launcher/boot.ogg"):
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
