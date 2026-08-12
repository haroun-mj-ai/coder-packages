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
# Converges five things, in order:
#   1. tmux + supercronic present on PATH (nix profile install if missing)
#   2. ~/.autopilot/{runs,briefs,logs} exist
#   3. ~/.autopilot/env seeded from a commented template (never overwritten)
#   4. autopilot/bin/* symlinked into ~/.local/bin
#   5. a managed block in ~/.bashrc self-heals the scheduler on login
#
# Honors $HOME throughout (tests run with HOME=$(mktemp -d)); the only
# hardcoded path is locating this repo checkout itself.

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

current_block=""
if [[ -f "$BASHRC" ]] && grep -qF "$BLOCK_START" "$BASHRC" 2>/dev/null; then
  current_block="$(sed -n "/^${BLOCK_START//\//\\/}\$/,/^${BLOCK_END//\//\\/}\$/p" "$BASHRC")"
fi

desired_block="$BLOCK_START
$BLOCK_BODY
$BLOCK_END"

if [[ "$current_block" == "$desired_block" ]]; then
  report ok "$BASHRC autopilot block up to date"
elif [[ "$CHECK_ONLY" == true ]]; then
  if [[ -n "$current_block" ]]; then
    report MISSING "$BASHRC autopilot block present but stale"
  else
    report MISSING "$BASHRC autopilot block absent"
  fi
else
  touch "$BASHRC"
  if [[ -n "$current_block" ]]; then
    # Replace the existing block in place (do not duplicate).
    tmp="$(mktemp)"
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
      $0 == start { print; skip=1; next }
      $0 == end && skip { print; skip=0; next }
      skip { next }
      { print }
    ' "$BASHRC" >"$tmp"
    # Substitute the (now-empty-body) block back to the desired content.
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" -v body="$BLOCK_BODY" '
      $0 == start { print; print body; next }
      { print }
    ' "$tmp" >"$BASHRC"
    rm -f "$tmp"
    report DID "replaced stale autopilot block in $BASHRC"
  else
    {
      echo ""
      echo "$desired_block"
    } >>"$BASHRC"
    report DID "appended autopilot block to $BASHRC"
  fi
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
