#!/usr/bin/env bash
# Build the pinned Android debug shell around one existing immutable payload.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

love_payload=""
version=""
version_code=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --love|--version|--version-code|--output)
      [[ $# -ge 2 ]] || { echo "build_android: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --love) love_payload="$2" ;;
        --version) version="$2" ;;
        --version-code) version_code="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
      ;;
    *) echo "build_android: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$love_payload" && -n "$version" && -n "$version_code" && -n "$output" ]] || {
  echo "usage: scripts/build_android.sh --love <payload.love> --version <version> --version-code <positive-int> --output <apk>" >&2
  exit 2
}
[[ "$version_code" =~ ^[1-9][0-9]*$ ]] || { echo "build_android: version code must be a positive integer" >&2; exit 2; }
[[ -f "$love_payload" ]] || { echo "build_android: payload does not exist: $love_payload" >&2; exit 1; }
love_payload="$(realpath "$love_payload")"
mkdir -p "$(dirname "$output")"
output="$(realpath -m "$output")"
[[ "$love_payload" != "$output" ]] || { echo "build_android: output must differ from payload" >&2; exit 2; }

payload_info="$(python3 - "$love_payload" "$version" <<'PY'
from pathlib import Path
import hashlib
import re
import sys
import zipfile
payload, wanted = Path(sys.argv[1]), sys.argv[2]
if wanted != "dev" and re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", wanted) is None:
    raise SystemExit("build_android: version must be dev or a complete semantic version")
with zipfile.ZipFile(payload) as archive:
    identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
    version = re.search(r'version\s*=\s*"([^"]+)"', identity)
    commit = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
    if version is None or commit is None or version.group(1) != wanted:
        raise SystemExit("build_android: payload identity does not match --version")
    if archive.testzip() is not None:
        raise SystemExit("build_android: payload CRC verification failed")
    print(version.group(1))
    print(commit.group(1))
    print(hashlib.sha256(payload.read_bytes()).hexdigest())
PY
)"
mapfile -t payload_fields <<< "$payload_info"
[[ ${#payload_fields[@]} -eq 3 ]] || { echo "build_android: invalid payload metadata" >&2; exit 1; }
payload_commit="${payload_fields[1]}"
payload_sha="${payload_fields[2]}"

[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
  echo "build_android: this pinned builder requires a Linux x86_64 host" >&2
  exit 1
}
for command in python3 curl tar patch make gcc luajit; do
  command -v "$command" >/dev/null || { echo "build_android: required host tool is missing: $command" >&2; exit 1; }
done
java_bin="${JAVA_HOME:+$JAVA_HOME/bin/java}"
[[ -x "$java_bin" ]] || java_bin="$(command -v java || true)"
[[ -n "$java_bin" && -x "$java_bin" ]] || { echo "build_android: JDK 17 is required" >&2; exit 1; }
java_major="$($java_bin -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)"
[[ "$java_major" == "17" ]] || { echo "build_android: JDK 17 is required, found major ${java_major:-unknown}" >&2; exit 1; }

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$sdk_root" ]] || { echo "build_android: ANDROID_SDK_ROOT is required" >&2; exit 1; }
ndk_root="${ANDROID_NDK_ROOT:-$sdk_root/ndk/28.2.13676358}"
build_tools="$sdk_root/build-tools/36.0.0"
platform="$sdk_root/platforms/android-36"
for path in "$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang" \
  "$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang" \
  "$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang" \
  "$build_tools/zipalign" "$platform/android.jar"; do
  [[ -e "$path" ]] || { echo "build_android: locked Android tool is missing: $path" >&2; exit 1; }
done
grep -qx 'Pkg.Revision = 28.2.13676358' "$ndk_root/source.properties" || {
  echo "build_android: ANDROID_NDK_ROOT is not locked NDK r28c" >&2
  exit 1
}
grep -qx 'Pkg.Revision = 36.0.0' "$build_tools/source.properties" || {
  echo "build_android: locked Build Tools 36.0.0 are required" >&2
  exit 1
}

mkdir -p "$repo/.agents/tmp/portemon-android"
stage="$(mktemp -d "$repo/.agents/tmp/portemon-android/build.XXXXXX")"
temporary_output=""
cleanup() {
  rm -rf -- "$stage"
  if [[ -n "$temporary_output" ]]; then
    rm -f -- "$temporary_output"
  fi
}
trap cleanup EXIT

# ARMv7 LuaJIT builds its host tools as 32-bit executables.
printf 'int main(void) { return 0; }\n' > "$stage/multilib.c"
if ! gcc -m32 "$stage/multilib.c" -o "$stage/multilib" >/dev/null 2>&1; then
  echo "build_android: working 32-bit GCC development files are required for armeabi-v7a LuaJIT" >&2
  exit 1
fi

fetch() {
  local url="$1" digest="$2" target="$3"
  curl --fail --location --retry 2 "$url" --output "$target"
  local actual
  actual="$(sha256sum "$target" | cut -d' ' -f1)"
  [[ "$actual" == "$digest" ]] || { echo "build_android: download checksum mismatch for $url" >&2; exit 1; }
}
love_android_commit="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love_android"]["commit"])')"
love_commit="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love"]["commit"])')"
love_android_sha="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love_android"]["archive"]["value"])')"
love_sha="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love"]["archive"]["value"])')"
love_android_url="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love_android"]["url"])')"
love_url="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["love"]["url"])')"
fetch "$love_android_url" "$love_android_sha" "$stage/love-android.tar.gz"
fetch "$love_url" "$love_sha" "$stage/love.tar.gz"
tar -xzf "$stage/love-android.tar.gz" -C "$stage"
tar -xzf "$stage/love.tar.gz" -C "$stage"
shell="$stage/love-android-$love_android_commit"
[[ -d "$shell" ]] || { echo "build_android: unexpected love-android archive layout" >&2; exit 1; }
wrapper_sha="$(python3 -c 'import json; print(json.load(open("scripts/packaging/pins.json"))["gradle"]["wrapper_jar"]["value"])')"
actual_wrapper_sha="$(sha256sum "$shell/gradle/wrapper/gradle-wrapper.jar" | cut -d' ' -f1)"
[[ "$actual_wrapper_sha" == "$wrapper_sha" ]] || { echo "build_android: pinned Gradle wrapper checksum mismatch" >&2; exit 1; }
rm -rf "$shell/love/src/jni/love"
mv "$stage/love-$love_commit" "$shell/love/src/jni/love"
patch --batch --forward -p1 -d "$shell" < scripts/packaging/android/toolchain-and-branding.patch
patch --batch --forward -p1 -d "$shell" < scripts/packaging/android/rom-picker.patch
cp scripts/packaging/android/RomPicker.java "$shell/love/src/main/java/org/love2d/android/RomPicker.java"

# Rebuild every static LuaJIT archive from the patched source at API 21. No
# checked-in upstream archive or filename-only cache is accepted as evidence.
toolchain="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin"
export LLVM_READELF="$toolchain/llvm-readelf"
for abi in arm64-v8a armeabi-v7a x86_64; do
  case "$abi" in
    arm64-v8a) driver="aarch64-linux-android21-clang"; host_cc="gcc" ;;
    armeabi-v7a) driver="armv7a-linux-androideabi21-clang"; host_cc="gcc -m32" ;;
    x86_64) driver="x86_64-linux-android21-clang"; host_cc="gcc" ;;
  esac
  source="$stage/LuaJIT-$abi"
  cp -R "$shell/love/src/jni/LuaJIT-2.1" "$source"
  (
    cd "$source/src"
    make clean >/dev/null
    make -j"$(nproc)" \
      HOST_LUA=luajit HOST_CC="$host_cc" CC=clang CROSS= \
      STATIC_CC="$toolchain/$driver -fPIC" \
      DYNAMIC_CC="$toolchain/$driver -fPIC" \
      TARGET_SYS=Linux TARGET_LD="$toolchain/$driver" TARGET_LDFLAGS=-fuse-ld=lld \
      TARGET_AR="$toolchain/llvm-ar rcus" TARGET_STRIP="$toolchain/llvm-strip" \
      TARGET_SONAME=libluajit.so CCDEBUG=-g \
      GIT_RELVER='cp ../.relver luajit_relver.txt' amalg
  )
  [[ -s "$source/src/libluajit.a" && -s "$source/src/luajit.h" ]] || {
    echo "build_android: LuaJIT rebuild omitted outputs for $abi" >&2
    exit 1
  }
done
for abi in arm64-v8a armeabi-v7a x86_64; do
  mkdir -p "$shell/love/src/jni/LuaJIT-2.1/android/$abi"
  cp "$stage/LuaJIT-$abi/src/libluajit.a" "$shell/love/src/jni/LuaJIT-2.1/android/$abi/libluajit.a"
  cp "$stage/LuaJIT-$abi/src/luajit.h" "$shell/love/src/jni/LuaJIT-2.1/android/$abi/luajit.h"
done

mkdir -p "$shell/app/src/embed/assets"
cp "$love_payload" "$shell/app/src/embed/assets/game.love"
export GRADLE_USER_HOME="$stage/gradle-home"
export ANDROID_USER_HOME="$stage/android-user"
export HOME="$stage/home"
mkdir -p "$HOME" "$ANDROID_USER_HOME"
(
  cd "$shell"
  ./gradlew --no-daemon assembleEmbedNoRecordDebug \
    -Papp.version_name="$version" -Papp.version_code="$version_code"
)

shopt -s nullglob
apks=("$shell"/app/build/outputs/apk/embedNoRecordDebug/*.apk)
[[ ${#apks[@]} -eq 1 ]] || { echo "build_android: expected exactly one debug APK" >&2; exit 1; }
apk="${apks[0]}"
python3 - "$apk" "$love_payload" "$payload_sha" <<'PY'
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
apk, payload, wanted = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
with zipfile.ZipFile(apk) as archive:
    names = archive.namelist()
    embedded = archive.read("assets/game.love")
    if hashlib.sha256(embedded).hexdigest() != wanted:
        raise SystemExit("build_android: embedded payload differs from input")
    for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
        for library in ("libc++_shared.so", "liblove.so"):
            if f"lib/{abi}/{library}" not in names:
                raise SystemExit(f"build_android: APK omitted {abi}/{library}")
    forbidden = ("assets/roms/", "assets/saves/", "assets/cache/", "assets/references/", "assets/.agents/")
    if any(name.startswith(forbidden) for name in names) or any(name.endswith((".nds", ".sav")) for name in names):
        raise SystemExit("build_android: APK contains user or reference data")
    native = [name for name in names if name.startswith("lib/") and name.endswith(".so")]
    if any(archive.getinfo(name).compress_type != zipfile.ZIP_STORED for name in native):
        raise SystemExit("build_android: native libraries must be stored uncompressed for alignment")
    with tempfile.TemporaryDirectory(dir=apk.parent) as directory:
        for name in native:
            target = Path(directory) / Path(name).name
            target.write_bytes(archive.read(name))
            listing = subprocess.check_output([
                os.environ.get("LLVM_READELF", "llvm-readelf"), "-lW", str(target)
            ], text=True)
            for line in listing.splitlines():
                if line.lstrip().startswith("LOAD "):
                    match = re.search(r"0x[0-9a-fA-F]+$", line)
                    if match is None or int(match.group(0), 16) < 0x4000:
                        raise SystemExit(f"build_android: {name} has a LOAD segment below 16KB alignment")
PY
"$build_tools/zipalign" -c -P 16 -v 4 "$apk" >/dev/null

temporary_output="$output.tmp.$$"
cp "$apk" "$temporary_output"
chmod 0644 "$temporary_output"
mv -f "$temporary_output" "$output"
echo "build_android: wrote $output (payload $payload_sha, commit $payload_commit)"
