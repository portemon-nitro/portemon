#!/usr/bin/env bash
# Developer-loop static checks: formatting (stylua), repository-owned
# static/policy/invariant checks, and a codehealth-scoped LuaLS check that
# runs in the background while the other checks execute, so lint.sh's wall
# time is roughly the slower of the two rather than their sum.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$#:${1:-}" in
  0:) STYLUA_ARGS=() ;;
  1:--check) STYLUA_ARGS=(--check) ;;
  *) echo "usage: scripts/lint.sh [--check]" >&2; exit 2 ;;
esac

for tool in stylua lua-language-server git; do
  command -v "$tool" >/dev/null || {
    echo "lint: $tool not found in PATH (see README 'Requirements')" >&2
    exit 1
  }
done

LUALS_LOG_DIR="$(mktemp -d)"
LUALS_OUTPUT="$(mktemp)"
STYLUA_FILES="$(mktemp)"
luals_pid=""
cleanup() {
  local status=$?
  if [ -n "$luals_pid" ]; then
    kill "$luals_pid" 2>/dev/null || true
    wait "$luals_pid" 2>/dev/null || true
  fi
  rm -rf -- "$LUALS_LOG_DIR" "$LUALS_OUTPUT" "$STYLUA_FILES"
  exit "$status"
}
trap cleanup EXIT

# The linted set comes from the shared scope helper both lint and
# codehealth analysis read (scripts/lib/scope.sh), newline separated:
# tracked candidates plus new not-yet-tracked production files.
scripts/lib/scope.sh --mode lint --repository-root . >"$STYLUA_FILES"
# The LuaLS workspace check covers the same scope through the committed
# .luarc.json ignoreDir.
# data/ as a whole stays checked: production code requires data reference
# modules, so ignoring the directory would trade resolution for scope,
# while the report names only data/generated and data/scripts/overrides as
# excluded. Declarative sources are ignorable by directory because both
# prefixes are whole directories.
echo "==> lua-language-server --check (running in background)"
lua-language-server --check . --num_threads="2" --checklevel=Hint --logpath="$LUALS_LOG_DIR" \
  >"$LUALS_OUTPUT" 2>&1 &
luals_pid=$!

mapfile -t LUA_FILES <"$STYLUA_FILES"
if [ "${#STYLUA_ARGS[@]}" -eq 0 ]; then
  echo "==> stylua"
else
  echo "==> stylua --check"
fi
stylua "${STYLUA_ARGS[@]}" "${LUA_FILES[@]}"

scripts/lib/check-repository.sh
scripts/lib/check-invariants.sh

# Reject references to the planning spec ("tmp/spec", "spec section N",
# "Workstream N", "milestone N", "slice N", "WS N"), planning language
# ("under development", "provisional", "may change in a future API"), and
# temporary phase/deliverable identifiers ("D12", "DEV-06", "pre-D4") in
# source, tests, data, and permanent docs. The patterns are narrow on
# purpose: bare "section"/"slice" and project concepts like the playable
# "New Bark slice" stay legal. lint.sh is excluded because it contains the
# patterns itself.
permanent_prose_roots=(README.md docs data libs game romdump tests scripts gen4 .agents/docs)
if grep -RInE --include='*.lua' --include='*.md' --include='*.sh' --include='*.toml' \
  -e 'tmp/spec' -e 'spec section' -e 'Workstream' -e 'milestone [0-9]' -e 'slice [0-9]' \
  -e 'WS[0-9]' -e 'under development' -e 'provisional' -e 'may change in a future API' \
  -e '\bD[0-9]+\b' -e '\bDEV-[0-9]+\b' -e 'pre-D[0-9]+' \
  --exclude='lint.sh' \
  "${permanent_prose_roots[@]}"; then
  echo "lint: temporary-spec references found; replace them with durable reasoning" >&2
  exit 1
fi

echo "==> waiting for lua-language-server --check"
luals_status=0
wait "$luals_pid" || luals_status=$?
luals_pid=""
if [ "$luals_status" -ne 0 ]; then
  cat "$LUALS_OUTPUT" >&2
  echo "lint: LuaLS check failed" >&2
  exit 1
fi
