#!/usr/bin/env bash
# Build a universal, ad-hoc-signed macOS app around one immutable payload.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
love_payload=""
version=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --love|--version|--output)
      [[ $# -ge 2 ]] || { echo "build_macos: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --love) love_payload="$2" ;;
        --version) version="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
      ;;
    *) echo "build_macos: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$love_payload" && -n "$version" && -n "$output" ]] || {
  echo "usage: scripts/build_macos.sh --love <payload.love> --version <SemVer> --output <macos.zip>" >&2
  exit 2
}
[[ "$(uname -s)" == "Darwin" ]] || { echo "build_macos: this builder requires macOS" >&2; exit 1; }
[[ -f "$love_payload" ]] || { echo "build_macos: payload does not exist" >&2; exit 1; }
love_payload="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$love_payload")"
mkdir -p "$(dirname "$output")"
output="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).absolute())' "$output")"
[[ "$love_payload" != "$output" ]] || { echo "build_macos: output must differ from payload" >&2; exit 2; }

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
    raise SystemExit("build_macos: release version must be a complete semantic version")
with zipfile.ZipFile(payload) as archive:
    identity = archive.read("app/src/BuildInfo.lua").decode("utf-8")
    version = re.search(r'version\s*=\s*"([^"]+)"', identity)
    if version is None or version.group(1) != wanted:
        raise SystemExit("build_macos: payload identity does not match --version")
    validate_identity(version.group(1))
    if archive.testzip() is not None:
        raise SystemExit("build_macos: payload CRC verification failed")
print(hashlib.sha256(payload.read_bytes()).hexdigest())
PY
)"
mapfile -t payload_fields <<< "$payload_info"
[[ ${#payload_fields[@]} -eq 1 ]] || { echo "build_macos: invalid payload metadata" >&2; exit 1; }
payload_sha="${payload_fields[0]}"

pin_info="$(python3 - <<'PY'
import json
pin = json.load(open("scripts/packaging/pins.json"))["love_desktop"]["macos"]
print(pin["file"])
print(pin["url"])
print(pin["archive"]["value"])
print(pin["bytes"])
PY
)"
mapfile -t runtime_fields <<< "$pin_info"
[[ ${#runtime_fields[@]} -eq 4 ]] || { echo "build_macos: invalid runtime pins" >&2; exit 1; }
runtime_file="${runtime_fields[0]}"
runtime_url="${runtime_fields[1]}"
runtime_sha="${runtime_fields[2]}"
runtime_bytes="${runtime_fields[3]}"
cache="${PORTEMON_BUILD_CACHE:-$repo/.agents/tmp/portemon-release/cache}"
mkdir -p "$cache"
runtime="$cache/$runtime_file"
if [[ ! -f "$runtime" ]]; then
  curl --fail --location --retry 2 "$runtime_url" --output "$runtime"
fi
[[ "$(shasum -a 256 "$runtime" | cut -d' ' -f1)" == "$runtime_sha" ]] || {
  echo "build_macos: official runtime checksum mismatch" >&2
  exit 1
}
[[ "$(stat -f%z "$runtime")" == "$runtime_bytes" ]] || {
  echo "build_macos: official runtime size differs from its pin" >&2
  exit 1
}

stage="$(mktemp -d "$(dirname "$output")/.portemon-macos.XXXXXX")"
temporary_output="$stage/release.zip"
backup="$output.previous"
promoted=false
cleanup() {
  rm -rf -- "$stage"
  if ! $promoted; then rm -f -- "$temporary_output"; fi
}
trap cleanup EXIT
unzip -q "$runtime" -d "$stage/runtime"
bundle="$stage/Portemon Nitro.app"
mv "$stage/runtime/love.app" "$bundle"
resources="$bundle/Contents/Resources"
executable="$bundle/Contents/MacOS/love"
entitlements="$stage/entitlements.plist"
if codesign -d --entitlements "$entitlements" "$executable" >/dev/null 2>&1 && [[ -s "$entitlements" ]]; then
  :
else
  rm -f "$entitlements"
fi
mv "$executable" "$bundle/Contents/MacOS/portemon"
find "$resources" -maxdepth 1 -name '*.love' -delete
upstream_icon="$stage/upstream-love.icns"
[[ -f "$resources/love.icns" ]] || { echo "build_macos: official runtime omitted its shell icon" >&2; exit 1; }
cp "$resources/love.icns" "$upstream_icon"
rm -f "$resources/love.icns"
cp "$upstream_icon" "$resources/portemon.icns"
cp "$love_payload" "$resources/game.love"

core="${version%%-*}"
core="${core%%+*}"
plist="$bundle/Contents/Info.plist"
python3 scripts/packaging/macos_metadata.py --plist "$plist" --version "$core"

nfd="$stage/nfd"
python3 scripts/packaging/build_nfd.py --platform macos --arch universal --output "$nfd"
for arch in x64 arm64; do
  destination="$resources/app/native/macos/$arch"
  mkdir -p "$destination"
  cp "$nfd/macos/$arch/libnfd.dylib" "$destination/libnfd.dylib"
  [[ "$(lipo -archs "$destination/libnfd.dylib")" == *"$([[ "$arch" == x64 ]] && echo x86_64 || echo arm64)"* ]] || {
    echo "build_macos: NFDe $arch slice is missing" >&2
    exit 1
  }
done
cp "$nfd/LICENSE" "$resources/app/native/macos/LICENSE"
cp LICENSE "$resources/LICENSE"

for arch in x64 arm64; do
  codesign --force --sign - "$resources/app/native/macos/$arch/libnfd.dylib"
done
sign_args=(--force --sign -)
if [[ -s "$entitlements" ]]; then
  sign_args+=(--entitlements "$entitlements")
fi
codesign "${sign_args[@]}" "$bundle/Contents/MacOS/portemon"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
python3 - "$resources/game.love" "$love_payload" "$payload_sha" <<'PY'
from pathlib import Path
import hashlib
import sys
packaged, source, wanted = map(Path, sys.argv[1:4])
if packaged.read_bytes() != source.read_bytes() or hashlib.sha256(packaged.read_bytes()).hexdigest() != wanted:
    raise SystemExit("build_macos: packaged payload differs")
PY
python3 scripts/packaging/macos_metadata.py --plist "$plist" --version "$core" --verify
cmp "$upstream_icon" "$resources/portemon.icns"
test ! -e "$resources/love.icns"

ditto -c -k --sequesterRsrc --keepParent "$bundle" "$temporary_output"

smoke_root="$stage/smoke"
smoke_cwd="$smoke_root/unrelated-cwd"
mkdir -p "$smoke_cwd" "$smoke_root/home" "$smoke_root/data" "$smoke_root/cache"
smoke_out="$smoke_root/stdout.log"
smoke_err="$smoke_root/stderr.log"
(
  cd "$smoke_cwd"
  bash "$repo/scripts/packaging/smoke.sh" macos "$smoke_root" \
    "$bundle/Contents/MacOS/portemon" >"$smoke_out" 2>"$smoke_err" &
  smoke_pid=$!
  sleep 5
  if ! kill -0 "$smoke_pid" 2>/dev/null; then
    wait "$smoke_pid" || true
    cat "$smoke_out" "$smoke_err" >&2
    echo "build_macos: packaged application exited during startup" >&2
    exit 1
  fi
  if grep -E -i 'Error:|stack traceback|boot\.lua|\.lua:[0-9]+:' "$smoke_out" "$smoke_err"; then
    kill -TERM "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" || true
    echo "build_macos: packaged application reported a boot error" >&2
    exit 1
  fi
  kill -TERM "$smoke_pid" 2>/dev/null || true
  for _ in $(seq 1 15); do
    kill -0 "$smoke_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$smoke_pid" 2>/dev/null; then
    kill -KILL "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" || true
    echo "build_macos: packaged application did not terminate" >&2
    exit 1
  fi
  wait "$smoke_pid" || true
)

if [[ -e "$output" ]]; then mv "$output" "$backup"; fi
if ! mv "$temporary_output" "$output"; then
  if [[ -e "$backup" && ! -e "$output" ]]; then mv "$backup" "$output"; fi
  exit 1
fi
promoted=true
rm -rf -- "$backup"
echo "build_macos: wrote $output (payload $payload_sha)"
