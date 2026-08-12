#!/usr/bin/env bash
set -uo pipefail

# Idempotent installer for the autopilot scheduler (see autopilot/README.md).
# Modeled on scripts/install-hooks.sh: same --check convention, same
# per-item report, safe to re-run.
#
# Usage: ./scripts/install-autopilot.sh [--check]
#   --check   Report convergence; change nothing. Exit 1 if anything is
#             missing/stale, so it is usable in CI or as a health check.
#
# Converges six things, in order:
#   1. tmux + supercronic present on PATH (nix profile install if missing)
#   2. ~/.autopilot/{runs,briefs,logs} exist
#   3. ~/.autopilot/env seeded from a commented template (never overwritten)
#   4. autopilot/bin/* symlinked into ~/.local/bin
#   5. a managed block in ~/.bashrc self-heals the scheduler on login
#   6. the JourneyAI checkout's .claude/skills/* symlinked into this repo's
#      claude/skills/* (single source of truth), tracked paths underneath
#      skip-worktree'd, and the untracked symlink names hidden via
#      .git/info/exclude
#
# Honors $HOME throughout (tests run with HOME=$(mktemp -d)); step 6 honors
# $AP_WORK_REPO (default /home/coder/root-for-local) for the same reason.
# The only hardcoded path is locating this repo checkout itself.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOPILOT_BIN_DIR="$ROOT_DIR/autopilot/bin"

AP_HOME="$HOME/.autopilot"
LOCAL_BIN="$HOME/.local/bin"
BASHRC="$HOME/.bashrc"

BLOCK_START="# >>> autopilot >>>"
BLOCK_END="# <<< autopilot <<<"
BLOCK_BODY="# Self-heals the autopilot scheduler on interactive login. Managed by
# scripts/install-autopilot.sh — do not edit by hand between the markers.
command -v ap >/dev/null 2>&1 && ap up --quiet"

CHECK_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
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

# ensure_managed_block <file> <start-marker> <end-marker> <desired-body> <label>
# Idempotently converges a marked fence block in <file>: appends if absent,
# replaces in place if stale, leaves untouched if already correct, never
# duplicates. Shared by the ~/.bashrc self-heal block (step 5) and the
# .git/info/exclude autopilot-skills block (step 6). Honors $CHECK_ONLY.
ensure_managed_block() {
  local file="$1" start="$2" end="$3" body="$4" label="$5"
  local current_block=""
  if [[ -f "$file" ]] && grep -qF "$start" "$file" 2>/dev/null; then
    current_block="$(sed -n "/^${start//\//\\/}\$/,/^${end//\//\\/}\$/p" "$file")"
  fi

  local desired_block="$start
$body
$end"

  if [[ "$current_block" == "$desired_block" ]]; then
    report ok "$label up to date"
    return
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    if [[ -n "$current_block" ]]; then
      report MISSING "$label present but stale"
    else
      report MISSING "$label absent"
    fi
    return
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"
  if [[ -n "$current_block" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk -v start="$start" -v end="$end" '
      $0 == start { print; skip=1; next }
      $0 == end && skip { print; skip=0; next }
      skip { next }
      { print }
    ' "$file" >"$tmp"
    awk -v start="$start" -v body="$body" '
      $0 == start { print; print body; next }
      { print }
    ' "$tmp" >"$file"
    rm -f "$tmp"
    report DID "replaced stale $label"
  else
    {
      echo ""
      echo "$desired_block"
    } >>"$file"
    report DID "appended $label"
  fi
}

# --- 1. tmux + supercronic --------------------------------------------------

for bin in tmux supercronic; do
  if command -v "$bin" >/dev/null 2>&1; then
    report ok "$bin present ($(command -v "$bin"))"
    continue
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "$bin not on PATH"
    continue
  fi

  if nix profile install "nixpkgs#$bin" >/dev/null 2>&1; then
    report DID "installed $bin via nix profile"
  else
    report MISSING "failed to install $bin via nix profile"
  fi
done

# --- 2. ~/.autopilot dirs ---------------------------------------------------

for sub in runs briefs logs; do
  dir="$AP_HOME/$sub"
  if [[ -d "$dir" ]]; then
    report ok "$dir exists"
    continue
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "$dir"
    continue
  fi

  mkdir -p "$dir"
  report DID "created $dir"
done

# --- 3. ~/.autopilot/env template -------------------------------------------

ENV_FILE="$AP_HOME/env"
if [[ -f "$ENV_FILE" ]]; then
  report ok "$ENV_FILE already present (not overwritten)"
else
  if [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "$ENV_FILE"
  else
    mkdir -p "$AP_HOME"
    cat >"$ENV_FILE" <<'ENVEOF'
# ~/.autopilot/env — autopilot user configuration.
# Sourced by autopilot/bin/ap-env.sh. Never overwritten by the installer once
# this file exists — edit freely.

# Notification channel(s). Set one or both; unset means notifications are
# logged to ~/.autopilot/logs/notify.log instead of sent anywhere.
#   NTFY_TOPIC: an unguessable topic string on ntfy.sh (no account needed —
#     pick a random slug, e.g. `openssl rand -hex 16`, and subscribe to
#     https://ntfy.sh/<topic> in the ntfy mobile app).
#   SLACK_WEBHOOK_URL: an "Incoming Webhook" URL from a Slack app
#     (https://api.slack.com/apps -> your app -> Incoming Webhooks).
# NTFY_TOPIC=
# SLACK_WEBHOOK_URL=

# Per-rolling-day budget caps.
# AP_MAX_ISSUES_PER_DAY=3
# AP_MAX_DAY_COST_USD=50

# Timezone for "day" boundaries (ledger, crontab, budget resets).
# AP_TZ=UTC

# Private GitHub repo used as the plan-review inbox (owner/repo).
# AP_INBOX_REPO=haroun-mj-ai/autopilot-inbox

# Minutes between the pre-scan gate's fallback full poll -- pure insurance
# against a misclassified inbox comment or a crash-stranded claim, not a
# queue-pickup mechanism. Set to 0 to disable this leg entirely.
# AP_FULL_POLL_INTERVAL_MIN=360

# Global auto-approve: skip waiting for a "go" comment on EVERY plan-review
# issue and build as soon as the plan lands (still never merges -- ship-work
# always runs --no-merge). Never applies to a needs-input stop (a blocking
# question always waits for you). Prefer the per-issue `auto` label or an
# `auto` comment on one delegation instead of turning this on globally.
# AP_AUTO_APPROVE=0

# Concurrent build slots -- how many implement->ship chains can run at once.
# Clamped to 1-4. Safe to raise here specifically because backend tests run
# on mongomock (in-memory, per-test) and every build works in its own git
# worktree, so concurrent builds never share a database or a checkout.
# AP_BUILD_SLOTS=2

# Minutes a usage/rate/session-limit auto-pause (as opposed to a real-bug or
# manual pause) waits before clearing itself. 0 disables auto-resume entirely.
# AP_LIMIT_COOLDOWN_MIN=60
ENVEOF
    report DID "seeded $ENV_FILE"
  fi
fi

# --- 4. symlink autopilot/bin/* into ~/.local/bin ---------------------------

if [[ "$CHECK_ONLY" != true ]]; then
  mkdir -p "$LOCAL_BIN"
elif [[ ! -d "$LOCAL_BIN" ]]; then
  report MISSING "$LOCAL_BIN does not exist"
fi

for src in "$AUTOPILOT_BIN_DIR"/*; do
  [[ -f "$src" ]] || continue
  name="$(basename "$src")"
  dest="$LOCAL_BIN/$name"

  if [[ -L "$dest" ]]; then
    current_target="$(readlink "$dest")"
    if [[ "$current_target" == "$src" ]]; then
      report ok "$name -> $src"
      continue
    fi

    if [[ "$CHECK_ONLY" == true ]]; then
      report MISSING "$name symlink points at $current_target, expected $src"
      continue
    fi

    rm -f "$dest"
    ln -s "$src" "$dest"
    report DID "relinked $name -> $src"
    continue
  fi

  if [[ -e "$dest" ]]; then
    if [[ "$CHECK_ONLY" == true ]]; then
      report MISSING "$name exists at $dest but is not the expected symlink"
      continue
    fi
    echo "  Warning: $dest exists and is not a symlink — overwriting" >&2
    rm -f "$dest"
    ln -s "$src" "$dest"
    report DID "linked $name -> $src"
    continue
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    report MISSING "$name not linked into $LOCAL_BIN"
    continue
  fi

  ln -s "$src" "$dest"
  report DID "linked $name -> $src"
done

# --- 5. managed ~/.bashrc block ---------------------------------------------

ensure_managed_block "$BASHRC" "$BLOCK_START" "$BLOCK_END" "$BLOCK_BODY" \
  "$BASHRC autopilot block"

# --- 6. autopilot skills wiring in the JourneyAI checkout -------------------
# Reproduces (idempotently) the manual wiring this feature depends on: the
# JourneyAI checkout's .claude/skills/<name> entries are symlinks into this
# repo's claude/skills/<name> (the single source of truth). Any path git
# already tracks underneath a replaced entry is skip-worktree'd so the
# substitution never shows in `git status` or gets committed there, and the
# (untracked) symlink names themselves are hidden via .git/info/exclude.

AP_WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"
SKILLS_SRC_DIR="$ROOT_DIR/claude/skills"
SKILLS_DEST_DIR="$AP_WORK_REPO/.claude/skills"
SKILL_NAMES=(plan-issue implement-plan ship-work autopilot-poll daily-brief autopilot-protocol.md)

if [[ ! -d "$AP_WORK_REPO/.git" ]]; then
  report MISSING "$AP_WORK_REPO is not a git checkout (skipping autopilot skills wiring)"
else
  for name in "${SKILL_NAMES[@]}"; do
    src="$SKILLS_SRC_DIR/$name"
    dest="$SKILLS_DEST_DIR/$name"

    if [[ ! -e "$src" ]]; then
      report MISSING "skills source missing: $src"
      continue
    fi

    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
      report ok "$name -> $src"
    elif [[ "$CHECK_ONLY" == true ]]; then
      report MISSING "$name not correctly symlinked at $dest (expected -> $src)"
    else
      mkdir -p "$SKILLS_DEST_DIR"
      rm -rf "$dest"
      ln -s "$src" "$dest"
      report DID "linked $name -> $src"
    fi

    # Any path git already tracks under this entry must be skip-worktree'd
    # so the symlink substitution above never shows in status/commits there.
    tracked="$(git -C "$AP_WORK_REPO" ls-files -- ".claude/skills/$name" 2>/dev/null)"
    [[ -z "$tracked" ]] && continue

    while IFS= read -r tracked_file; do
      [[ -z "$tracked_file" ]] && continue
      bit="$(git -C "$AP_WORK_REPO" ls-files -v -- "$tracked_file" | cut -c1)"
      if [[ "$bit" == "s" || "$bit" == "S" ]]; then
        report ok "skip-worktree set: $tracked_file"
      elif [[ "$CHECK_ONLY" == true ]]; then
        report MISSING "skip-worktree not set: $tracked_file"
      else
        git -C "$AP_WORK_REPO" update-index --skip-worktree -- "$tracked_file"
        report DID "set skip-worktree: $tracked_file"
      fi
    done <<<"$tracked"
  done

  EXCLUDE_FILE="$AP_WORK_REPO/.git/info/exclude"
  EXCLUDE_START="# >>> autopilot skills >>>"
  EXCLUDE_END="# <<< autopilot skills <<<"
  EXCLUDE_BODY="# autopilot runtime symlinks (real files live in coder-packages/claude/skills)
.claude/skills/plan-issue
.claude/skills/implement-plan
.claude/skills/ship-work
.claude/skills/autopilot-poll
.claude/skills/daily-brief
.claude/skills/autopilot-protocol.md"

  ensure_managed_block "$EXCLUDE_FILE" "$EXCLUDE_START" "$EXCLUDE_END" "$EXCLUDE_BODY" \
    "$EXCLUDE_FILE autopilot skills block"
fi

if [[ "$CHECK_ONLY" == true ]]; then
  if [[ "$converged" -eq 1 ]]; then
    echo "Converged."
    exit 0
  else
    echo "Not converged — run $0" >&2
    exit 1
  fi
fi

echo "Done."
