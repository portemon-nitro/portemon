#!/usr/bin/env bash
# Launch LÖVE with the data home selected by the development/test command.
# LÖVE 11.5 uses XDG_DATA_HOME on Linux, but PhysFS's user home on macOS.
# Give only the child process a private home; the calling shell is untouched.
set -euo pipefail
if [ "$(uname -s)" = Darwin ] && [ -n "${XDG_DATA_HOME:-}" ]; then
  case "$XDG_DATA_HOME" in
    /*) ;;
    *) echo "love: XDG_DATA_HOME must be an absolute path" >&2; exit 1 ;;
  esac
  mkdir -p -- "$XDG_DATA_HOME"
  exec env HOME="$XDG_DATA_HOME" love "$@"
fi
exec love "$@"
