# Shared script setup. Source after cd-ing to the repo root.
#
# scripts/bin/ holds contributor-local installs from
# scripts/lib/repo-setup.sh; it leads PATH so repo scripts use them
# without further setup, then repo-setup ensures the Git hook path and
# the `love` runtime (lint.sh additionally ensures its toolchain with
# `repo-setup.sh --dev` after sourcing this file).
case ":${PATH:-}:" in
  *":$PWD/scripts/bin:"*) ;;
  *) export PATH="$PWD/scripts/bin${PATH:+:$PATH}" ;;
esac

# This file (not .envrc) owns script defaults: .envrc is personal direnv
# state for interactive shells, and scripts must not change behavior with
# unreviewed local edits to it. An inherited PORTEMON_SAVE_DIR (e.g. via
# direnv) still wins through the environment, which is the correct channel
# for personal overrides.
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
  scripts/lib/repo-setup.sh
fi

# Local default keeps ROM-derived data out of $HOME during development.
export PORTEMON_SAVE_DIR="${PORTEMON_SAVE_DIR:-$PWD/.cache}"

# Apply the single app-level save-directory override onto the variable
# LÖVE/PhysFS reads for its save-dir base. This is the one seam a future
# portable mode will reuse; when PORTEMON_SAVE_DIR is unset, LÖVE uses
# the OS default per-user location.
if [ -n "${PORTEMON_SAVE_DIR:-}" ]; then
  case "$(uname -s)" in
    # Linux/BSD: PhysFS derives the save-dir base from XDG_DATA_HOME.
    Linux|*BSD) export XDG_DATA_HOME="$PORTEMON_SAVE_DIR" ;;
    # macOS/Windows use fixed appdata roots; wire their overrides in when
    # portable mode lands. For now this keeps dev on those platforms explicit.
    *) export XDG_DATA_HOME="$PORTEMON_SAVE_DIR" ;;
  esac
fi
