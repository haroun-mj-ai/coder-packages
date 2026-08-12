#!/usr/bin/env bash
# Send a notification to whatever channel is configured (ntfy and/or Slack).
# Falls back to a log file when neither is configured. Always exits 0 —
# a notify failure must never take down the cycle that called it.
#
# Usage: ap-notify.sh "<title>" "<body>" [url]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

title="${1:-}"
body="${2:-}"
url="${3:-}"

mkdir -p "$AP_HOME/logs"

# HTTP headers cannot contain newlines (or CR); flatten a multi-line title
# before it's used anywhere, including inside the Slack text blob.
title="${title//$'\r'/ }"
title="${title//$'\n'/ }"

if [[ -n "$NTFY_TOPIC" ]]; then
  headers=(-H "Title: $title")
  if [[ -n "$url" ]]; then
    headers+=(-H "Click: $url")
  fi
  if ! curl -fsS -m 10 "${headers[@]}" -d "$body" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>>"$AP_HOME/logs/notify.log"; then
    echo "$(date -u +%FT%TZ) ntfy send failed: $title" >>"$AP_HOME/logs/notify.log"
  fi
fi

if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
  text="*${title}*\n${body}"
  if [[ -n "$url" ]]; then
    text="${text}\n${url}"
  fi
  # JSON-encode the payload -- body may contain quotes, backslashes, or
  # newlines (every FAILED body embeds STDERR/STDOUT tails).
  if command -v jq >/dev/null 2>&1; then
    payload="$(jq -nc --arg text "$text" '{text: $text}')"
  else
    payload="$(printf '%s' "$text" | python3 -c 'import json, sys; print(json.dumps({"text": sys.stdin.read()}))')"
  fi
  if ! curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>>"$AP_HOME/logs/notify.log"; then
    echo "$(date -u +%FT%TZ) slack send failed: $title" >>"$AP_HOME/logs/notify.log"
  fi
fi

if [[ -z "$NTFY_TOPIC" && -z "$SLACK_WEBHOOK_URL" ]]; then
  {
    echo "$(date -u +%FT%TZ) $title"
    echo "  $body"
    [[ -n "$url" ]] && echo "  $url"
  } >>"$AP_HOME/logs/notify.log"
fi

exit 0
