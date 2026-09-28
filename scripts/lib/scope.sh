#!/usr/bin/env bash
# The single implementation of the executable-production-Lua scope: the file
# list both the lint gate and code-health analysis read, one repo-relative
# path per line, sorted. `candidates` lists tracked production files minus
# declarative sources for analysis; `lint` additionally admits new
# not-yet-tracked production files so an uncommitted production file is
# still formatted while uncommitted tests or tooling stay out exactly like
# their tracked siblings.
#
# The taxonomy here is the authority: tests (any `tests` directory),
# tooling, generated, reference, ignored, vendor, and type roots stay out;
# `app`, `game`, `gen4`, `libs`, and `romdump` stay in except declarative
# prefixes and header-marked data modules. A tracked path the taxonomy
# cannot classify is a hard error, so a new root forces an explicit
# decision here; an unclassifiable untracked path is skipped.
set -euo pipefail

MARKER="-- codehealth: declarative"
MARKER_SCAN_LINES=5

MODE=""
ROOT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      [ "$#" -ge 2 ] || {
        echo "scope: --mode requires lint|candidates" >&2
        exit 2
      }
      MODE="$2"
      shift 2
      ;;
    --repository-root)
      [ "$#" -ge 2 ] || {
        echo "scope: --repository-root requires a path" >&2
        exit 2
      }
      ROOT="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: scripts/lib/scope.sh --mode lint|candidates --repository-root PATH"
      exit 0
      ;;
    *)
      echo "usage: scripts/lib/scope.sh --mode lint|candidates --repository-root PATH" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  lint | candidates) ;;
  *)
    echo "scope: --mode requires lint|candidates" >&2
    exit 2
    ;;
esac

[ -n "$ROOT" ] || {
  echo "scope: --repository-root requires a path" >&2
  exit 2
}

CANONICAL="$(cd -- "$ROOT" && pwd -P)" || {
  echo "scope: repository root is not a directory: $ROOT" >&2
  exit 1
}
TOPLEVEL="$(git -C "$CANONICAL" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "scope: repository root is not a git worktree: $ROOT" >&2
  exit 1
}
TOPLEVEL_CANONICAL="$(cd -- "$TOPLEVEL" && pwd -P)"
[ "$TOPLEVEL_CANONICAL" = "$CANONICAL" ] || {
  echo "scope: repository root is not a worktree top level: $ROOT" >&2
  exit 1
}

WORK_LIST="$(mktemp)"
TRACKED_LIST="$(mktemp)"
UNTRACKED_LIST="$(mktemp)"
trap 'rm -f -- "$WORK_LIST" "$TRACKED_LIST" "$UNTRACKED_LIST"' EXIT

# A repo-relative Lua path with no absolute, parent, empty, drive-letter,
# or non-Lua form. Anything else is rejected rather than classified.
portable_lua_path() {
  case "$1" in
    *.lua) ;;
    *) return 1 ;;
  esac
  case "$1" in
    /* | */ | *//* | .. | ../* | */../* | */..) return 1 ;;
  esac
  case "$1" in
    ?:[\\/]* | ?:) return 1 ;;
  esac
  return 0
}

# Whether a portable path is in the production scope. Unknown roots fail
# the caller: tracked callers turn this into a hard error, untracked
# callers skip the file.
in_production_scope() {
  case "$1" in
    tests/* | */tests/*) return 1 ;;
    vendor/* | types/*) return 1 ;;
    site/* | data/generated/*) return 1 ;;
    .agents/* | .cache/* | .claude/* | import-output/* | log/* | tmp/*) return 1 ;;
    scripts/* | tools/* | .github/*) return 1 ;;
    data/*) return 1 ;;
    app/* | game/* | gen4/* | libs/* | romdump/*) return 0 ;;
    *) return 2 ;;
  esac
}

# Whether the file's first lines carry the declarative marker. Pure bash so
# the check costs no fork per file.
has_declarative_marker() {
  local line="" trimmed="" count=0
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    [ "$count" -gt "$MARKER_SCAN_LINES" ] && break
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ "$trimmed" = "$MARKER" ] && return 0
  done <"$1"
  return 1
}

# Admit one validated path into the scope list unless it is declarative.
# $1 is the repo-relative path, $2 is "strict" (tracked: unknown roots and
# unreadable files fail) or "lenient" (untracked: they are skipped).
admit() {
  local relative="$1" strict="$2" absolute=""
  case "$relative" in
    romdump/src/config/* | romdump/src/reference/*) return 0 ;;
  esac
  absolute="$CANONICAL/$relative"
  if [ ! -r "$absolute" ]; then
    if [ "$strict" = "strict" ]; then
      echo "scope: cannot read candidate source $relative" >&2
      exit 1
    fi
    return 0
  fi
  if has_declarative_marker "$absolute"; then
    return 0
  fi
  printf '%s\n' "$relative" >>"$WORK_LIST"
}

git -C "$CANONICAL" ls-files -- '*.lua' >"$TRACKED_LIST" 2>/dev/null || {
  echo "scope: cannot enumerate tracked Lua paths" >&2
  exit 1
}
: >"$WORK_LIST"

path=""
while IFS= read -r path || [ -n "$path" ]; do
  portable_lua_path "$path" || {
    echo "scope: non-portable Lua path: '$path'" >&2
    exit 1
  }
  if in_production_scope "$path"; then
    admit "$path" strict
  else
    status=$?
    if [ "$status" -gt 1 ]; then
      echo "scope: unclassified tracked Lua path: $path" >&2
      exit 1
    fi
  fi
done <"$TRACKED_LIST"

if [ "$MODE" = "lint" ]; then
  git -C "$CANONICAL" ls-files --others --exclude-standard -- '*.lua' >"$UNTRACKED_LIST" 2>/dev/null || {
    echo "scope: cannot enumerate untracked Lua paths" >&2
    exit 1
  }
  while IFS= read -r path || [ -n "$path" ]; do
    portable_lua_path "$path" || {
      echo "scope: non-portable Lua path: '$path'" >&2
      exit 1
    }
    if in_production_scope "$path"; then
      admit "$path" lenient
    fi
  done <"$UNTRACKED_LIST"
fi

[ -s "$WORK_LIST" ] || {
  echo "scope: code-health scope is empty" >&2
  exit 1
}
LC_ALL=C sort "$WORK_LIST"
