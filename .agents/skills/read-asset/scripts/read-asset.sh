#!/usr/bin/env bash
# Targeted Portemon asset preparation plus logical-byte extraction, directory
# listing, or human-readable message-bank export.
set -euo pipefail
cd "$(dirname "$0")/../../../.."

usage() {
  echo "usage: .agents/skills/read-asset/scripts/read-asset.sh --version <heartgold|soulsilver> --require <kind:key> (--path <cache-relative-file> | --list <cache-relative-directory> | --message-text <cache-relative-bank>) [--rom-source <path>] [--rebuild]" >&2
  exit 2
}

version=""
requirement=""
asset_path=""
list_dir=""
message_text=""
rom_source=""
rebuild=false
while (( $# > 0 )); do
  case "$1" in
    --version|--require|--path|--list|--message-text|--rom-source)
      (( $# >= 2 )) || usage
      [[ -n "$2" && "$2" != --* ]] || usage
      case "$1" in
        --version) [[ -z "$version" ]] || usage; version="$2" ;;
        --require) [[ -z "$requirement" ]] || usage; requirement="$2" ;;
        --path) [[ -z "$asset_path" ]] || usage; asset_path="$2" ;;
        --list) [[ -z "$list_dir" ]] || usage; list_dir="$2" ;;
        --message-text) [[ -z "$message_text" ]] || usage; message_text="$2" ;;
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
modes=0
if [[ -n "$asset_path" ]]; then modes=$((modes + 1)); fi
if [[ -n "$list_dir" ]]; then modes=$((modes + 1)); fi
if [[ -n "$message_text" ]]; then modes=$((modes + 1)); fi
if (( modes != 1 )); then
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
  requested="$asset_path"
  if [[ -n "$message_text" ]]; then
    requested="$message_text"
  fi
  scratch_parent=.agents/tmp
  if [[ ! -w "$scratch_parent" ]]; then
    scratch_parent="${TMPDIR:-/tmp}"
  fi
  mkdir -p "$scratch_parent"
  scratch="$(mktemp -d "$scratch_parent/read-asset.XXXXXXXX")"
  filename="${requested##*/}"
  if [[ -z "$filename" || "$filename" == . || "$filename" == .. ]]; then
    echo "read-asset: invalid output filename" >&2
    rmdir -- "$scratch"
    exit 2
  fi
  if [[ -n "$message_text" ]]; then
    output="$PWD/$scratch/${filename%.g4msg}.messages.lua"
    reader+=(--message-text "$message_text" --output "$output")
  else
    output="$PWD/$scratch/$filename"
    reader+=(--path "$asset_path" --output "$output")
  fi
fi
scripts/lib/love.sh .agents/skills/read-asset/reader/ "${reader[@]}"
