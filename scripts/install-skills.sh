#!/usr/bin/env bash
set -uo pipefail

# Link this repo's Claude Code skills into the JourneyAI checkout, so
# claude/skills/ here stays the single source of truth.
#
# Usage: ./scripts/install-skills.sh [--check]
#   --check   Report convergence; change nothing. Exit 1 if anything is
#             missing or stale, so it is usable as a health check.
#
# For every entry in claude/skills/ (directory or .md file) it:
#   1. symlinks <checkout>/.claude/skills/<name> -> claude/skills/<name>
#   2. skip-worktrees any path git already tracks under that entry, so the
#      substitution never shows in `git status` or gets committed there
#   3. lists the symlink name in a managed block in .git/info/exclude
# It also removes symlinks that point into claude/skills/ at an entry that no
# longer exists, so deleting a skill here unlinks it there on the next run.
#
# The skill list is read from claude/skills/ itself — add or remove a skill
# there and re-run; there is no list to keep in sync.
#
# Safe to re-run. Honors $JOURNEY_ROOT (default ~/root-for-local).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_SRC_DIR="$ROOT_DIR/claude/skills"

JOURNEY_ROOT="${JOURNEY_ROOT:-$HOME/root-for-local}"
SKILLS_DEST_DIR="$JOURNEY_ROOT/.claude/skills"
EXCLUDE_FILE="$JOURNEY_ROOT/.git/info/exclude"

BLOCK_START="# >>> coder-packages skills >>>"
BLOCK_END="# <<< coder-packages skills <<<"
# Written by the retired install-autopilot.sh; superseded by the block above.
LEGACY_START="# >>> autopilot skills >>>"
LEGACY_END="# <<< autopilot skills <<<"

CHECK_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

converged=1
report() {
  # report <status> <message>   status: ok | MISSING | DID
  local status="$1"; shift
  echo "  $status  $*"
  [[ "$status" == "ok" || "$status" == "DID" ]] || converged=0
}

# extract_block <file> <start> <end> -> the fenced block, markers included
extract_block() {
  [[ -f "$1" ]] || return 0
  awk -v s="$2" -v e="$3" '$0 == s {on=1} on {print} on && $0 == e {exit}' "$1"
}

# strip_block <file> <start> <end> — remove the fenced block in place
strip_block() {
  local tmp
  tmp="$(mktemp)"
  awk -v s="$2" -v e="$3" '$0 == s {skip=1; next} skip && $0 == e {skip=0; next} !skip' "$1" >"$tmp"
  cat "$tmp" >"$1"
  rm -f "$tmp"
}

if [[ ! -d "$SKILLS_SRC_DIR" ]]; then
  echo "No skills directory at $SKILLS_SRC_DIR" >&2
  exit 1
fi
if [[ ! -d "$JOURNEY_ROOT/.git" ]]; then
  echo "$JOURNEY_ROOT is not a git checkout (set JOURNEY_ROOT)" >&2
  exit 1
fi

echo "Skills: $SKILLS_SRC_DIR -> $SKILLS_DEST_DIR"

SKILL_NAMES=()
for src in "$SKILLS_SRC_DIR"/*; do
  [[ -d "$src" || "$src" == *.md ]] && SKILL_NAMES+=("$(basename "$src")")
done

# --- 1 + 2. symlink each skill, skip-worktree what git tracks under it -------

for name in "${SKILL_NAMES[@]}"; do
  src="$SKILLS_SRC_DIR/$name"
  dest="$SKILLS_DEST_DIR/$name"

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    report ok "$name"
  elif [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "$name not linked at $dest"
  else
    mkdir -p "$SKILLS_DEST_DIR"
    rm -rf "$dest"
    ln -s "$src" "$dest"
    report DID "linked $name"
  fi

  while IFS= read -r tracked_file; do
    [[ -z "$tracked_file" ]] && continue
    bit="$(git -C "$JOURNEY_ROOT" ls-files -v -- "$tracked_file" | cut -c1)"
    if [[ "$bit" == "s" || "$bit" == "S" ]]; then
      continue
    elif [[ "$CHECK_ONLY" == true ]]; then
      report MISSING "skip-worktree not set: $tracked_file"
    else
      git -C "$JOURNEY_ROOT" update-index --skip-worktree -- "$tracked_file"
      report DID "set skip-worktree: $tracked_file"
    fi
  done < <(git -C "$JOURNEY_ROOT" ls-files -- ".claude/skills/$name" 2>/dev/null)
done

# --- prune links to skills that no longer exist here -------------------------

for dest in "$SKILLS_DEST_DIR"/*; do
  [[ -L "$dest" ]] || continue
  target="$(readlink "$dest")"
  [[ "$target" == "$SKILLS_SRC_DIR/"* && ! -e "$target" ]] || continue
  if [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "stale link: $(basename "$dest") -> $target"
  else
    rm -f "$dest"
    report DID "removed stale link $(basename "$dest")"
  fi
done

# --- 3. managed .git/info/exclude block --------------------------------------

desired="$BLOCK_START
# symlinks into coder-packages/claude/skills (managed by scripts/install-skills.sh)"
for name in "${SKILL_NAMES[@]}"; do
  desired+=$'\n'".claude/skills/$name"
done
desired+=$'\n'"$BLOCK_END"

current="$(extract_block "$EXCLUDE_FILE" "$BLOCK_START" "$BLOCK_END")"
legacy="$(extract_block "$EXCLUDE_FILE" "$LEGACY_START" "$LEGACY_END")"

if [[ "$current" == "$desired" && -z "$legacy" ]]; then
  report ok "exclude block up to date"
elif [[ "$CHECK_ONLY" == true ]]; then
  if [[ -z "$current" ]]; then report MISSING "exclude block absent"
  elif [[ "$current" != "$desired" ]]; then report MISSING "exclude block stale"
  fi
  [[ -z "$legacy" ]] || report MISSING "legacy autopilot exclude block still present"
else
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  touch "$EXCLUDE_FILE"
  [[ -n "$legacy" ]] && strip_block "$EXCLUDE_FILE" "$LEGACY_START" "$LEGACY_END" \
    && report DID "removed legacy autopilot exclude block"
  if [[ "$current" != "$desired" ]]; then
    [[ -n "$current" ]] && strip_block "$EXCLUDE_FILE" "$BLOCK_START" "$BLOCK_END"
    printf '%s\n' "$desired" >>"$EXCLUDE_FILE"
    report DID "wrote exclude block (${#SKILL_NAMES[@]} entries)"
  fi
fi

if [[ "$CHECK_ONLY" == true ]]; then
  if [[ "$converged" -eq 1 ]]; then echo "Converged."; exit 0; fi
  echo "Not converged — run $0" >&2
  exit 1
fi
echo "Done."
