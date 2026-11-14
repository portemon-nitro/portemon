#!/usr/bin/env bash
# Targeted Portemon asset preparation plus logical-byte extraction or listing.
set -euo pipefail
cd "$(dirname "$0")/../../../.."

usage() {
  echo "usage: .agents/skills/read-asset/scripts/read-asset.sh --version <heartgold|soulsilver> --require <kind:key> (--path <cache-relative-file> | --list <cache-relative-directory>) [--rom-source <path>] [--rebuild]" >&2
  exit 2
}

version=""
requirement=""
asset_path=""
list_dir=""
rom_source=""
rebuild=false
while (( $# > 0 )); do
  case "$1" in
    --version|--require|--path|--list|--rom-source)
      (( $# >= 2 )) || usage
      [[ -n "$2" && "$2" != --* ]] || usage
      case "$1" in
        --version) [[ -z "$version" ]] || usage; version="$2" ;;
        --require) [[ -z "$requirement" ]] || usage; requirement="$2" ;;
        --path) [[ -z "$asset_path" ]] || usage; asset_path="$2" ;;
        --list) [[ -z "$list_dir" ]] || usage; list_dir="$2" ;;
        --rom-source) [[ -z "$rom_source" ]] || usage; rom_source="$2" ;;
      esac
      shift 2
      ;;
    --rebuild)
      [[ "$rebuild" == false ]] || usage
      rebuild=true
      shift
      ;;
    *) usage ;;
  esac
done
[[ "$version" == heartgold || "$version" == soulsilver ]] || usage
[[ "$requirement" == *:* ]] || usage
if [[ -n "$asset_path" && -n "$list_dir" ]] || [[ -z "$asset_path" && -z "$list_dir" ]]; then
  usage
fi

source scripts/lib/dev.sh

if [[ -n "$rom_source" ]]; then
  probe="$(scripts/lib/love.sh romdump/ --probe-rom "$rom_source")"
  if ! grep -Fxq -- "version=$version" <<< "$probe"; then
    echo "read-asset: ROM does not match requested version $version" >&2
    exit 2
  fi
  scripts/lib/love.sh romdump/ --import-rom "$rom_source"
fi

prepare=(--prepare-cache --dev --version "$version" --require "$requirement")
if [[ "$rebuild" == true ]]; then
  prepare+=(--rebuild "$requirement")
fi
scripts/lib/love.sh romdump/ "${prepare[@]}"

reader=(--repo-root "$PWD" --version "$version")
if [[ -n "$list_dir" ]]; then
  reader+=(--list "$list_dir")
else
  mkdir -p .agents/tmp
  scratch="$(mktemp -d .agents/tmp/read-asset.XXXXXXXX)"
  filename="${asset_path##*/}"
  if [[ -z "$filename" || "$filename" == . || "$filename" == .. ]]; then
    echo "read-asset: invalid output filename" >&2
    rmdir -- "$scratch"
    exit 2
  fi
  output="$PWD/$scratch/$filename"
  reader+=(--path "$asset_path" --output "$output")
fi
scripts/lib/love.sh .agents/skills/read-asset/reader/ "${reader[@]}"
