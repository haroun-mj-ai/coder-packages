#!/usr/bin/env bash
# Post-merge worktree cleanup. For every wt-eng* worktree of the root repo and
# of the backend/frontend/assistants/observability siblings, remove the
# worktree and delete its local branch ONLY IF the branch is merged into its
# base AND the worktree has no uncommitted changes. Never --force, never
# `branch -D`. Defaults to --dry-run (report only); pass --yes to act.
#
#   ap-sweep.sh              # dry run: report kept/removed/refused, change nothing
#   ap-sweep.sh --dry-run    # same as above, explicit
#   ap-sweep.sh --yes        # actually remove eligible worktrees + branches
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"

DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --yes) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    *)
      echo "usage: ap-sweep.sh [--dry-run|--yes]" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$AP_HOME" "$AP_HOME/logs"

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$AP_HOME/logs/sweep.log"
}

if $DRY_RUN; then
  log "starting sweep (dry-run)"
else
  log "starting sweep (--yes)"
fi

# repo_path:base_branch pairs. root/backend/frontend land on dev; the two
# repos with no dev branch land on main, per ship-work's repo map.
REPOS=(
  "$WORK_REPO:dev"
  "$WORK_REPO/backend:dev"
  "$WORK_REPO/frontend:dev"
  "$WORK_REPO/assistants:main"
  "$WORK_REPO/observability:main"
)

# list_worktrees <repo> -> one "<path>\t<branch>" line per worktree that has
# a branch checked out (skips detached-HEAD worktrees, which this convention
# never produces but which we must not misparse as mergeable).
list_worktrees() {
  local repo="$1"
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { path=substr($0, 10) }
    /^branch refs\/heads\// { branch=substr($0, 19); print path "\t" branch; path=""; branch="" }
    /^detached/ { path="" }
  '
}

removed_count=0
refused_count=0
kept_count=0

for entry in "${REPOS[@]}"; do
  repo_path="${entry%%:*}"
  base="${entry##*:}"

  [[ -d "$repo_path/.git" || -f "$repo_path/.git" ]] || continue

  # Best-effort fetch of the base branch so "merged" reflects the real
  # remote, not a stale local ref. Never fatal: an offline sweep still runs,
  # just against whatever origin/<base> the repo already has.
  git -C "$repo_path" fetch origin "$base" --quiet 2>/dev/null || true

  while IFS=$'\t' read -r wt_path wt_branch; do
    [[ -n "$wt_path" ]] || continue
    base_name="$(basename "$wt_path")"
    [[ "$base_name" == wt-eng* ]] || continue

    label="$base_name ($wt_branch)"

    if [[ -z "$wt_branch" ]]; then
      echo "$label: REFUSED - detached HEAD, no branch to evaluate"
      log "refused $wt_path: detached HEAD"
      refused_count=$((refused_count + 1))
      continue
    fi

    if [[ ! -e "$wt_path" ]]; then
      echo "$label: REFUSED - worktree path missing ($wt_path)"
      log "refused $wt_path: path missing"
      refused_count=$((refused_count + 1))
      continue
    fi

    if ! git -C "$repo_path" rev-parse --verify -q "origin/$base" >/dev/null; then
      echo "$label: REFUSED - no origin/$base ref to compare against"
      log "refused $wt_path: missing origin/$base"
      refused_count=$((refused_count + 1))
      continue
    fi

    if ! git -C "$repo_path" merge-base --is-ancestor "$wt_branch" "origin/$base" 2>/dev/null; then
      echo "$label: REFUSED - not merged into origin/$base"
      log "refused $wt_path: not merged into origin/$base"
      refused_count=$((refused_count + 1))
      continue
    fi

    dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null)"
    if [[ -n "$dirty" ]]; then
      echo "$label: REFUSED - worktree has uncommitted changes"
      log "refused $wt_path: dirty worktree"
      refused_count=$((refused_count + 1))
      continue
    fi

    if $DRY_RUN; then
      echo "$label: KEPT (dry-run) - merged into origin/$base and clean, would remove"
      log "would-remove $wt_path (branch $wt_branch, merged+clean)"
      kept_count=$((kept_count + 1))
      continue
    fi

    if git -C "$repo_path" worktree remove "$wt_path" 2>>"$AP_HOME/logs/sweep.log"; then
      if git -C "$repo_path" branch -d "$wt_branch" >>"$AP_HOME/logs/sweep.log" 2>&1; then
        echo "$label: REMOVED - merged into origin/$base, clean; branch deleted"
        log "removed $wt_path and branch $wt_branch"
        removed_count=$((removed_count + 1))
      else
        echo "$label: REFUSED - worktree removed but 'git branch -d $wt_branch' refused (see sweep.log)"
        log "worktree $wt_path removed but branch -d $wt_branch refused"
        refused_count=$((refused_count + 1))
      fi
    else
      echo "$label: REFUSED - 'git worktree remove' failed (see sweep.log)"
      log "worktree remove failed for $wt_path"
      refused_count=$((refused_count + 1))
    fi
  done < <(list_worktrees "$repo_path")
done

echo "---"
if $DRY_RUN; then
  echo "dry-run: $kept_count would be removed, $refused_count refused"
else
  echo "$removed_count removed, $refused_count refused"
fi

log "sweep finished: removed=$removed_count kept=$kept_count refused=$refused_count"
exit 0
