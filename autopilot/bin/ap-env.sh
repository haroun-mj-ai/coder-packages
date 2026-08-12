#!/usr/bin/env bash
# shellcheck shell=bash
# Sourceable env setup for autopilot scripts. Not executed directly.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/ap-env.sh"
#
# Derives GITHUB_PERSONAL_ACCESS_TOKEN (headless shells skip ~/.bashrc's
# derivation), sources user config from ~/.autopilot/env if present, then
# fills in defaults for anything still unset.

# GitHub token: only derive if the caller (or a stub PATH in tests) hasn't
# already set one.
if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null || true)"
  export GITHUB_PERSONAL_ACCESS_TOKEN
fi

export AP_HOME="${AP_HOME:-$HOME/.autopilot}"

# User config: NTFY_TOPIC, SLACK_WEBHOOK_URL, AP_MAX_ISSUES_PER_DAY,
# AP_MAX_DAY_COST_USD, AP_TZ, AP_INBOX_REPO. Never overwritten by defaults
# below if already set here.
if [[ -f "$AP_HOME/env" ]]; then
  # shellcheck disable=SC1091
  source "$AP_HOME/env"
fi

export NTFY_TOPIC="${NTFY_TOPIC:-}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export AP_MAX_ISSUES_PER_DAY="${AP_MAX_ISSUES_PER_DAY:-3}"
export AP_MAX_DAY_COST_USD="${AP_MAX_DAY_COST_USD:-50}"
export AP_TZ="${AP_TZ:-UTC}"
export AP_INBOX_REPO="${AP_INBOX_REPO:-haroun-mj-ai/autopilot-inbox}"
