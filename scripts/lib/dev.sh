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

# scripts/lib/love.sh maps this data home to LÖVE's platform-specific base.
# Keep the shell's home directory unchanged for Git and contributor tools.
export XDG_DATA_HOME="$PORTEMON_SAVE_DIR"
