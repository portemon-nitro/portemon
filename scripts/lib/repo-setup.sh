#!/usr/bin/env bash
# Local repository setup: Git hook path plus required external tools.
#
# Usage: scripts/lib/repo-setup.sh [--dev] [--yes]
#
# Without flags this ensures the local core.hooksPath and the `love`
# runtime; --dev additionally ensures the lint tools `stylua` and
# `lua-language-server`. Every missing tool is offered for install, one
# tool at a time, into scripts/bin/ from that tool's official release
# download; --yes accepts every install without prompting. Repo scripts
# put scripts/bin/ on PATH through scripts/lib/dev.sh, so an install
# takes effect for them right away. For an interactive shell, export the
# directory onto PATH using the hint printed after an install.
#
# Pinned versions match CI (.github/workflows/ci.yml) and the dev
# container (Containerfile) so a local install agrees with the gates.
set -euo pipefail

LOVE_VERSION="11.5"
LUALS_VERSION="3.19.0"
STYLUA_VERSION="2.5.2"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="$REPO_ROOT/scripts/bin"

WITH_DEV=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dev) WITH_DEV=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "usage: scripts/lib/repo-setup.sh [--dev] [--yes]" >&2
      exit 0
      ;;
    *)
      echo "usage: scripts/lib/repo-setup.sh [--dev] [--yes]" >&2
      exit 2
      ;;
  esac
done

cd "$REPO_ROOT"
export PATH="$BIN_DIR:$PATH"

# Stage downloads inside the worktree (never TMPDIR): moving a whole
# extracted tree onto scripts/bin/ then stays on one filesystem, so it is
# a rename rather than a cross-device copy.
STAGE_ROOT="$REPO_ROOT/tmp/repo-setup"
WORK_DIR=""
cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
  rmdir -- "$STAGE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

ensure_work_dir() {
  if [ -z "$WORK_DIR" ]; then
    mkdir -p -- "$STAGE_ROOT"
    WORK_DIR="$(mktemp -d "$STAGE_ROOT/work.XXXXXX")"
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "repo-setup: $1 is required to install $2" >&2
    exit 1
  fi
}

download() {
  curl --fail --location --retry 3 --show-error --output "$2" "$1"
}

ensure_hooks() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  local hooks_path=""
  if hooks_path="$(git config --local --get core.hooksPath 2>/dev/null)"; then
    if [ "$hooks_path" = "scripts/hooks" ]; then
      return 0
    fi
  else
    local config_status="$?"
    if [ "$config_status" -ne 1 ]; then
      exit "$config_status"
    fi
  fi
  git config --local core.hooksPath scripts/hooks
  echo "core.hooksPath -> scripts/hooks (pre-commit runs full lint over worktree and staged index)"
}

# Each platform helper prints the release asset's platform token and
# fails with a manual-install pointer when this host has no official
# asset to download.
stylua_platform() {
  local os="$1" arch="$2"
  case "$os" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *)
      echo "repo-setup: no official StyLua download for $os; install it manually (https://github.com/JohnnyMorganz/StyLua/releases)" >&2
      return 1
      ;;
  esac
  case "$arch" in
    x86_64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *)
      echo "repo-setup: no official StyLua download for $arch; install it manually (https://github.com/JohnnyMorganz/StyLua/releases)" >&2
      return 1
      ;;
  esac
  echo "$os-$arch"
}

luals_platform() {
  local os="$1" arch="$2"
  case "$os" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "repo-setup: no official lua-language-server download for $os; install it manually (https://github.com/LuaLS/lua-language-server/releases)" >&2
      return 1
      ;;
  esac
  case "$arch" in
    x86_64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "repo-setup: no official lua-language-server download for $arch; install it manually (https://github.com/LuaLS/lua-language-server/releases)" >&2
      return 1
      ;;
  esac
  echo "$os-$arch"
}

# Prints one of: appimage (Linux x86_64), macos (any Mac), and fails
# with a pointer for hosts without an official LÖVE download.
love_kind() {
  local os="$1" arch="$2"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64) echo "appimage" ;;
        *)
          echo "repo-setup: no official LÖVE download for Linux $arch; install it from your package manager (e.g. the ppa:bartbes/love-stable PPA used by Containerfile), then re-run this script" >&2
          return 1
          ;;
      esac
      ;;
    Darwin) echo "macos" ;;
    *)
      echo "repo-setup: no official LÖVE download for $os; install LÖVE $LOVE_VERSION from https://love2d.org/, then re-run this script" >&2
      return 1
      ;;
  esac
}

write_shim() {
  mkdir -p -- "$BIN_DIR"
  {
    printf '#!/bin/sh\n'
    # The dirname call must stay literal; it resolves inside the generated shim.
    # shellcheck disable=SC2016
    printf 'exec "$(dirname "$0")/%s" "$@"\n' "$2"
  } >"$BIN_DIR/$1"
  chmod 0755 "$BIN_DIR/$1"
}

install_stylua() {
  need_cmd curl stylua
  need_cmd unzip stylua
  local platform asset url
  platform="$(stylua_platform "$(uname -s)" "$(uname -m)")" || return 1
  asset="stylua-${platform}.zip"
  url="https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/${asset}"
  ensure_work_dir
  echo "repo-setup: downloading $asset ..."
  download "$url" "$WORK_DIR/$asset"
  mkdir -p -- "$BIN_DIR"
  unzip -j -o -q "$WORK_DIR/$asset" stylua -d "$BIN_DIR"
  chmod 0755 "$BIN_DIR/stylua"
  "$BIN_DIR/stylua" --version
}

install_luals() {
  need_cmd curl lua-language-server
  need_cmd tar lua-language-server
  local platform asset url dest
  platform="$(luals_platform "$(uname -s)" "$(uname -m)")" || return 1
  asset="lua-language-server-${LUALS_VERSION}-${platform}.tar.gz"
  url="https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/${asset}"
  dest="$BIN_DIR/lua-language-server-${LUALS_VERSION}-${platform}"
  ensure_work_dir
  echo "repo-setup: downloading $asset ..."
  download "$url" "$WORK_DIR/$asset"
  rm -rf -- "$BIN_DIR"/lua-language-server-*/
  mkdir -p -- "$dest"
  tar -xzf "$WORK_DIR/$asset" -C "$dest"
  if [ ! -x "$dest/bin/lua-language-server" ]; then
    echo "repo-setup: unexpected $asset layout (no bin/lua-language-server); remove $dest and install LuaLS $LUALS_VERSION manually" >&2
    return 1
  fi
  write_shim lua-language-server "lua-language-server-${LUALS_VERSION}-${platform}/bin/lua-language-server"
  "$BIN_DIR/lua-language-server" --version
}

install_love() {
  need_cmd curl love
  local kind
  kind="$(love_kind "$(uname -s)" "$(uname -m)")" || return 1
  case "$kind" in
    appimage) install_love_appimage ;;
    macos) install_love_macos ;;
  esac
}

install_love_appimage() {
  local asset url
  asset="love-${LOVE_VERSION}-x86_64.AppImage"
  url="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${asset}"
  ensure_work_dir
  echo "repo-setup: downloading $asset ..."
  download "$url" "$WORK_DIR/$asset"
  chmod +x "$WORK_DIR/$asset"
  mkdir -p -- "$WORK_DIR/love-extract"
  (
    cd "$WORK_DIR/love-extract"
    "$WORK_DIR/$asset" --appimage-extract >/dev/null
  )
  if [ ! -x "$WORK_DIR/love-extract/squashfs-root/AppRun" ]; then
    echo "repo-setup: $asset did not extract an AppRun entrypoint" >&2
    return 1
  fi
  rm -rf -- "$BIN_DIR/love-appimage"
  mkdir -p -- "$BIN_DIR/love-appimage"
  mv -- "$WORK_DIR/love-extract/squashfs-root" "$BIN_DIR/love-appimage/squashfs-root"
  write_shim love "love-appimage/squashfs-root/AppRun"
  "$BIN_DIR/love" --version
}

install_love_macos() {
  need_cmd unzip love
  local asset url
  asset="love-${LOVE_VERSION}-macos.zip"
  url="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${asset}"
  ensure_work_dir
  echo "repo-setup: downloading $asset ..."
  download "$url" "$WORK_DIR/$asset"
  rm -rf -- "$WORK_DIR/love-macos" "$BIN_DIR/love.app"
  mkdir -p -- "$WORK_DIR/love-macos"
  unzip -q -o "$WORK_DIR/$asset" -d "$WORK_DIR/love-macos"
  mv -- "$WORK_DIR/love-macos/love.app" "$BIN_DIR/love.app"
  write_shim love "love.app/Contents/MacOS/love"
  "$BIN_DIR/love" --version
}

install_tool() {
  mkdir -p -- "$BIN_DIR"
  case "$1" in
    love) install_love ;;
    stylua) install_stylua ;;
    lua-language-server) install_luals ;;
  esac
}

describe_tool() {
  case "$1" in
    love) echo "love (the LÖVE $LOVE_VERSION runtime that runs the game and tests)" ;;
    stylua) echo "stylua (the StyLua $STYLUA_VERSION formatter required by scripts/lint.sh)" ;;
    lua-language-server) echo "lua-language-server (the LuaLS $LUALS_VERSION analyzer required by scripts/lint.sh)" ;;
  esac
}

manual_hint() {
  case "$1" in
    love) echo "repo-setup: install LÖVE $LOVE_VERSION from https://love2d.org/ (or re-run with --yes once ready), then re-run your command" >&2 ;;
    stylua) echo "repo-setup: install StyLua $STYLUA_VERSION from https://github.com/JohnnyMorganz/StyLua/releases (or re-run with --yes once ready), then re-run your command" >&2 ;;
    lua-language-server) echo "repo-setup: install LuaLS $LUALS_VERSION from https://github.com/LuaLS/lua-language-server/releases (or re-run with --yes once ready), then re-run your command" >&2 ;;
  esac
}

offer_install() {
  local tool="$1"
  echo "repo-setup: $(describe_tool "$tool") was not found on PATH." >&2
  if [ "$ASSUME_YES" = 1 ]; then
    install_tool "$tool"
    return "$?"
  fi
  if [ ! -t 0 ]; then
    echo "repo-setup: no prompt possible without a terminal; re-run with --yes to install into scripts/bin automatically." >&2
    manual_hint "$tool"
    return 1
  fi
  local reply=""
  printf 'Install it into scripts/bin from the official release download? [y/N] ' >&2
  read -r reply || reply=""
  case "$reply" in
    [yY] | [yY][eE][sS]) install_tool "$tool" ;;
    *)
      manual_hint "$tool"
      return 1
      ;;
  esac
}

ensure_hooks

tools=(love)
if [ "$WITH_DEV" = 1 ]; then
  tools+=(stylua lua-language-server)
fi
installed_any=0
for tool in "${tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    continue
  fi
  offer_install "$tool" || exit "$?"
  installed_any=1
done

if [ "$installed_any" = 1 ]; then
  echo "repo-setup: scripts/bin is on PATH for repo scripts via scripts/lib/dev.sh." >&2
  echo "repo-setup: for an interactive shell: export PATH=\"$BIN_DIR:\$PATH\"" >&2
fi
