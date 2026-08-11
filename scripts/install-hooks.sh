#!/usr/bin/env bash
set -euo pipefail

# Point one or more git repos at this repo's shared hooks, so commits get the
# author's Co-Authored-By trailers automatically.
#
# Usage: ./scripts/install-hooks.sh [--check] [repo ...]
#   --check   Report which repos are wired up; change nothing. Exit 1 if any
#             named repo is missing the hook, so it is usable in CI.
#
# With no repo arguments it wires every git repo it finds under the JourneyAI
# root checkout, if one exists at the usual place.
#
# Safe to re-run. core.hooksPath lives in each repo's .git/config, which git
# does not track, so this has to run once per clone per machine. The hook
# script itself is tracked here, so the behaviour travels with the repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$ROOT_DIR/hooks"

DEFAULT_ROOT="${JOURNEY_ROOT:-$HOME/root-for-local}"

CHECK_ONLY=false
REPOS=()
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
    *) REPOS+=("$arg") ;;
  esac
done

if [[ ! -x "$HOOKS_DIR/commit-msg" ]]; then
  echo "Error: $HOOKS_DIR/commit-msg is missing or not executable" >&2
  exit 1
fi

# Default target set: the JourneyAI root checkout plus its sibling clones.
if [[ ${#REPOS[@]} -eq 0 ]]; then
  if [[ -d "$DEFAULT_ROOT/.git" ]]; then
    REPOS+=("$DEFAULT_ROOT")
    for folder in backend frontend assistants observability triage-service; do
      [[ -d "$DEFAULT_ROOT/$folder/.git" ]] && REPOS+=("$DEFAULT_ROOT/$folder")
    done
  else
    echo "No repos given and no checkout at $DEFAULT_ROOT." >&2
    echo "Usage: $0 [--check] [repo ...]   (or set JOURNEY_ROOT)" >&2
    exit 1
  fi
fi

failed=0
for repo in "${REPOS[@]}"; do
  name="$(basename "$repo")"

  if [[ ! -d "$repo/.git" ]]; then
    echo "  SKIP     $name (not a git repo)" >&2
    continue
  fi

  current="$(git -C "$repo" config --local --get core.hooksPath 2>/dev/null || true)"

  if [[ "$current" == "$HOOKS_DIR" ]]; then
    echo "  ok       $name"
    continue
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    echo "  MISSING  $name (core.hooksPath=${current:-unset})"
    failed=1
    continue
  fi

  # Warn rather than silently stomping a hooks dir someone set deliberately —
  # roborev, for one, installs its post-commit hook into whatever this points at.
  if [[ -n "$current" ]]; then
    echo "  Warning: $name already had core.hooksPath=$current — overwriting" >&2
  fi

  git -C "$repo" config --local core.hooksPath "$HOOKS_DIR"
  echo "  wired    $name"
done

if [[ "$CHECK_ONLY" == true && $failed -eq 1 ]]; then
  echo "Some repos are not wired up. Run $0" >&2
  exit 1
fi

echo "Done."
