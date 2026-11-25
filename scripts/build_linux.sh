#!/usr/bin/env bash
# Repack the official LÖVE AppImage with one immutable product payload and NFDe.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
love_payload=""
version=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --love|--version|--output)
      [[ $# -ge 2 ]] || { echo "build_linux: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --love) love_payload="$2" ;;
        --version) version="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
      ;;
    *) echo "build_linux: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$love_payload" && -n "$version" && -n "$output" ]] || {
  echo "usage: scripts/build_linux.sh --love <payload.love> --version <SemVer> --output <linux.AppImage>" >&2
  exit 2
}
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
  echo "build_linux: this pinned builder requires Linux x86_64" >&2
  exit 1
}
[[ -f "$love_payload" ]] || { echo "build_linux: payload does not exist" >&2; exit 1; }
love_payload="$(realpath "$love_payload")"
mkdir -p "$(dirname "$output")"
output="$(realpath -m "$output")"
[[ "$love_payload" != "$output" ]] || { echo "build_linux: output must differ from payload" >&2; exit 2; }

payload_info="$(python3 - "$love_payload" "$version" <<'PY'
from pathlib import Path
import hashlib
import re
import sys
import zipfile
sys.path.insert(0, str(Path("scripts").resolve()))
from pack_love import validate_identity
payload, wanted = Path(sys.argv[1]), sys.argv[2]
if wanted == "dev":
    raise SystemExit("build_linux: release version must be a complete semantic version")
with zipfile.ZipFile(payload) as archive:
    identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
    version = re.search(r'version\s*=\s*"([^"]+)"', identity)
    commit = re.search(r'commit\s*=\s*"([0-9a-f]{40})"', identity)
    if version is None or commit is None or version.group(1) != wanted:
        raise SystemExit("build_linux: payload identity does not match --version")
    validate_identity(version.group(1), commit.group(1))
    if archive.testzip() is not None:
        raise SystemExit("build_linux: payload CRC verification failed")
print(commit.group(1))
print(hashlib.sha256(payload.read_bytes()).hexdigest())
PY
)"
mapfile -t payload_fields <<< "$payload_info"
[[ ${#payload_fields[@]} -eq 2 ]] || { echo "build_linux: invalid payload metadata" >&2; exit 1; }
payload_commit="${payload_fields[0]}"
payload_sha="${payload_fields[1]}"

for command in python3 curl tar make gcc ldd dpkg-query readelf desktop-file-validate; do
  command -v "$command" >/dev/null || { echo "build_linux: required host tool is missing: $command" >&2; exit 1; }
done

cache="${PORTEMON_BUILD_CACHE:-$repo/.agents/tmp/portemon-release/cache}"
mkdir -p "$cache"
fetch() {
  local url="$1" wanted="$2" target="$3"
  if [[ ! -f "$target" ]]; then
    curl --fail --location --retry 2 "$url" --output "$target"
  fi
  [[ "$(sha256sum "$target" | cut -d' ' -f1)" == "$wanted" ]] || {
    echo "build_linux: dependency checksum mismatch for $url" >&2
    exit 1
  }
}
mapfile -t pins < <(python3 - <<'PY'
import json
pins = json.load(open("scripts/packaging/pins.json"))
for group, name in (("love_desktop", "linux"), ("release_tools", "appimagetool"), ("release_tools", "squashfs_tools")):
    pin = pins[group][name]
    print(pin["file"] if "file" in pin else pin["url"].rsplit("/", 1)[-1])
    print(pin["url"])
    print(pin["archive"]["value"])
PY
)
[[ ${#pins[@]} -eq 9 ]] || { echo "build_linux: invalid release pins" >&2; exit 1; }
runtime="$cache/${pins[0]}"
appimagetool="$cache/${pins[3]}"
squashfs_archive="$cache/${pins[6]}"
fetch "${pins[1]}" "${pins[2]}" "$runtime"
fetch "${pins[4]}" "${pins[5]}" "$appimagetool"
fetch "${pins[7]}" "${pins[8]}" "$squashfs_archive"

stage="$(mktemp -d "$(dirname "$output")/.portemon-linux.XXXXXX")"
temporary_output="$stage/release.AppImage"
backup="$output.previous"
promoted=false
cleanup() {
  rm -rf -- "$stage"
  if ! $promoted; then rm -f -- "$temporary_output"; fi
}
trap cleanup EXIT

chmod +x "$runtime" "$appimagetool"
runtime_offset="$($runtime --appimage-offset)"
[[ "$runtime_offset" =~ ^[0-9]+$ ]] || { echo "build_linux: cannot resolve official AppImage offset" >&2; exit 1; }
mkdir -p "$stage/squashfs"
tar -xzf "$squashfs_archive" -C "$stage/squashfs"
squashfs_source="$stage/squashfs/squashfs-tools-4.6.1/squashfs-tools"
[[ -f "$squashfs_source/Makefile" ]] || { echo "build_linux: unexpected SquashFS tools archive" >&2; exit 1; }
make -C "$squashfs_source" -j"$(nproc)" >/dev/null
mksquashfs="$squashfs_source/mksquashfs"
unsquashfs="$squashfs_source/unsquashfs"
[[ -x "$mksquashfs" && -x "$unsquashfs" ]] || { echo "build_linux: SquashFS tools build omitted outputs" >&2; exit 1; }

appdir="$stage/AppDir"
"$unsquashfs" -no-xattrs -o "$runtime_offset" -d "$appdir" "$runtime" >/dev/null
[[ -x "$appdir/AppRun" && -x "$appdir/bin/love" && -f "$appdir/lib/liblove-11.5.so" ]] || {
  echo "build_linux: unexpected official AppDir layout" >&2
  exit 1
}
cp "$love_payload" "$appdir/game.love"
python3 - "$appdir/AppRun" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
marker = 'if [ -z "$FUSE_PATH" ]; then'
if marker not in text:
    raise SystemExit("build_linux: official AppRun launch seam changed")
text = text.replace(marker, 'FUSE_PATH="$APPDIR/game.love"\n\n' + marker, 1)
path.write_text(text)
PY
chmod +x "$appdir/AppRun"

nfd="$stage/nfd"
python3 scripts/packaging/build_nfd.py --platform linux --arch x64 --output "$nfd"
native="$appdir/app/native/linux/x64"
mkdir -p "$native"
cp "$nfd/libnfd.so" "$native/libnfd.so"
cp "$nfd/LICENSE" "$native/LICENSE"
cp LICENSE "$appdir/LICENSE"
cp "$repo/assets/branding/portemon-nitro.png" "$appdir/portemon.png"
mkdir -p "$appdir/share/pixmaps" "$appdir/share/icons/hicolor/256x256/apps"
cp "$repo/assets/branding/portemon-nitro.png" "$appdir/share/pixmaps/portemon.png"
cp "$repo/assets/branding/portemon-nitro.png" "$appdir/share/icons/hicolor/256x256/apps/portemon.png"

# NFDe's portal backend needs D-Bus. Bundle its non-system shared dependency
# closure and the corresponding distribution notices in the runtime lib path.
stage_dependency() {
  local library="$1" real name package copyright
  [[ -f "$library" ]] || { echo "build_linux: native dependency is missing: $library" >&2; exit 1; }
  real="$(readlink -f "$library")"
  name="$(basename "$library")"
  case "$name" in
    libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*.so.*|linux-vdso.so.*) return 0 ;;
  esac
  [[ -f "$appdir/lib/$name" ]] && return 0
  cp -L "$real" "$appdir/lib/$name"
  package="$(dpkg-query -S "$real" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  if [[ -n "$package" ]]; then
    copyright="/usr/share/doc/$package/copyright"
    if [[ -f "$copyright" ]]; then
      mkdir -p "$appdir/licenses"
      cp "$copyright" "$appdir/licenses/$name.copyright"
    fi
  fi
  while read -r dependency; do
    [[ -n "$dependency" ]] && stage_dependency "$dependency"
  done < <(ldd "$real" | awk '/=> \/.*\.so/{print $3} /^\s*\/.*\.so/{print $1}')
}
stage_dependency "$native/libnfd.so"
[[ -f "$appdir/lib/libdbus-1.so.3" ]] || {
  echo "build_linux: NFDe portal backend did not link the D-Bus client library" >&2
  exit 1
}

cat > "$appdir/portemon.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Portémon Nitro
Comment=ROM-independent game launcher
Exec=AppRun
Type=Application
Categories=Game;
Terminal=false
Icon=portemon
NoDisplay=false
DESKTOP
ln -sfn portemon.png "$appdir/.DirIcon"
rm -f "$appdir/love.desktop" "$appdir/love.svg" "$appdir/share/applications/love.desktop" \
  "$appdir/share/pixmaps/love.svg" \
  "$appdir/share/icons/hicolor/scalable/apps/love.svg" \
  "$appdir/share/icons/hicolor/256x256/apps/love.png" \
  "$appdir/share/pixmaps/love.png" \
  "$appdir/share/mime/packages/love.xml" \
  "$appdir/share/icons/hicolor/scalable/mimetypes/application-x-love-game.svg"
desktop-file-validate "$appdir/portemon.desktop"

mkdir -p "$stage/tool"
(cd "$stage/tool" && "$appimagetool" --appimage-extract >/dev/null)
toolrun="$stage/tool/squashfs-root/AppRun"
[[ -x "$toolrun" ]] || { echo "build_linux: appimagetool extraction failed" >&2; exit 1; }
PATH="$squashfs_source:$PATH" ARCH=x86_64 VERSION="$version" "$toolrun" "$appdir" "$temporary_output" >/dev/null
chmod +x "$temporary_output"

verify_offset="$($temporary_output --appimage-offset)"
[[ "$verify_offset" =~ ^[0-9]+$ ]] || { echo "build_linux: repacked AppImage offset is invalid" >&2; exit 1; }
mkdir "$stage/verify"
"$unsquashfs" -no-xattrs -o "$verify_offset" -d "$stage/verify" "$temporary_output" >/dev/null
cmp "$love_payload" "$stage/verify/game.love"
cmp "$repo/assets/branding/portemon-nitro.png" "$stage/verify/portemon.png"
cmp "$repo/assets/branding/portemon-nitro.png" "$stage/verify/.DirIcon"
grep -q '^Icon=portemon$' "$stage/verify/portemon.desktop"
test ! -e "$stage/verify/love.svg"
cmp "$nfd/libnfd.so" "$stage/verify/app/native/linux/x64/libnfd.so"
grep -q 'FUSE_PATH="$APPDIR/game.love"' "$stage/verify/AppRun"

smoke_root="$stage/smoke"
smoke_cwd="$smoke_root/unrelated-cwd"
mkdir -p "$smoke_cwd" "$smoke_root/home" "$smoke_root/data" "$smoke_root/cache"
smoke() {
  local label="$1"
  shift
  local out="$smoke_root/$label.out" err="$smoke_root/$label.err" pid
  (
    cd "$smoke_cwd"
    bash "$repo/scripts/packaging/smoke.sh" linux "$smoke_root" "$@" >"$out" 2>"$err" &
    pid=$!
    sleep 5
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      cat "$out" "$err" >&2
      echo "build_linux: $label packaged launch exited during startup" >&2
      exit 1
    fi
    if grep -E -i 'Error:|stack traceback|boot\.lua|\.lua:[0-9]+:' "$out" "$err"; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" || true
      echo "build_linux: $label packaged launch reported a boot error" >&2
      exit 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 15); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" || true
      echo "build_linux: $label packaged launch did not terminate" >&2
      exit 1
    fi
    wait "$pid" || true
  )
}
smoke extracted env APPDIR="$stage/verify" "$stage/verify/AppRun"
smoke appimage "$temporary_output"

if [[ -e "$output" ]]; then mv "$output" "$backup"; fi
if ! mv "$temporary_output" "$output"; then
  if [[ -e "$backup" && ! -e "$output" ]]; then mv "$backup" "$output"; fi
  exit 1
fi
promoted=true
rm -rf -- "$backup"
echo "build_linux: wrote $output (payload $payload_sha, commit $payload_commit)"
