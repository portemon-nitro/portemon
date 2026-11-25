#!/usr/bin/env bash
# Run one packaged smoke command with an owned platform user-data environment.
set -euo pipefail

platform="$1"
root="$2"
shift 2
smoke_environment_text="$(
  python3 "$(dirname "${BASH_SOURCE[0]}")/smoke_environment.py" \
    --platform "$platform" --root "$root" --format env
)"
mapfile -t smoke_environment <<< "$smoke_environment_text"
exec env "${smoke_environment[@]}" "$@"
