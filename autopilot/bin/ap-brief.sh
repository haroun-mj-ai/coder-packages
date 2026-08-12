#!/usr/bin/env bash
# Cron entrypoint for the daily brief. Fired once a day (07:00 AP_TZ) by
# supercronic. Runs the /daily-brief skill headless and pushes the digest
# out via ap-notify.sh. Always exits 0 — the cron job must not flap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"
MAX_BODY_CHARS=3500

mkdir -p "$AP_HOME" "$AP_HOME/logs" "$AP_HOME/briefs"

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$AP_HOME/logs/brief.log"
}

pushd "$WORK_REPO" >/dev/null 2>&1 || cd "$WORK_REPO" || exit 0

rc=0
digest="$(claude -p "/daily-brief" --model haiku 2>>"$AP_HOME/logs/brief.log")" || rc=$?

popd >/dev/null 2>&1 || true

if [[ $rc -ne 0 ]]; then
  log "claude invocation failed rc=$rc"
  err_tail="$(printf '%s' "$digest" | tail -c 2000)"
  ap-notify.sh "daily brief failed" "${err_tail:-no output captured}" || true
  exit 0
fi

body="$digest"
if [[ "${#body}" -gt "$MAX_BODY_CHARS" ]]; then
  body="${body:0:$MAX_BODY_CHARS}"$'\n'"(truncated — full brief in ~/.autopilot/briefs/)"
fi

ap-notify.sh "autopilot daily brief" "$body" || true

exit 0
