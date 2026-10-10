#!/usr/bin/env bash
# p4-nightly-check: a daily, read-only review of last night's action-item
# cleanup on PRODUCTION.
#
#   run.sh [YYYY-MM-DD] [--if-missing]
#
# 1. Pipes probe.py into the prod backend container over `railway ssh`. The
#    probe is read-only and returns counts and id prefixes only.
# 2. Hands that JSON (plus yesterday's) to a tool-less headless Claude with
#    prompt.md, which writes the report. Claude itself never touches prod.
# 3. Saves both under $P4C_HOME/reports and pings the desktop notify bridge.
#
# --if-missing: do nothing unless it is past 08:40 ET and today's report is
# missing (the login catch-up path).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
P4C_HOME="${P4C_HOME:-$HOME/.p4-nightly-check}"
REPORTS="$P4C_HOME/reports"
RAILWAY_PROJECT="3800e068-5f96-432c-b470-de3c9f6b4f54"  # journeyai-backend
MODEL="${P4C_MODEL:-sonnet}"
mkdir -p "$REPORTS"
chmod 700 "$P4C_HOME"

DATE="" IF_MISSING=0
for arg in "$@"; do
  case "$arg" in
    --if-missing) IF_MISSING=1 ;;
    ????-??-??) DATE="$arg" ;;
    *) echo "usage: run.sh [YYYY-MM-DD] [--if-missing]" >&2; exit 2 ;;
  esac
done
DATE="${DATE:-$(TZ=America/New_York date +%F)}"
JSON="$REPORTS/$DATE.json" MD="$REPORTS/$DATE.md" LOG="$P4C_HOME/run.log"

if (( IF_MISSING )); then
  [[ -s "$MD" ]] && exit 0
  (( 10#$(TZ=America/New_York date +%H%M) >= 840 )) || exit 0
fi

exec 9>"$P4C_HOME/.lock"
flock -n 9 || { echo "another run holds the lock" >&2; exit 0; }

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
notify() { curl -s -m 2 -X POST --data "$1" http://127.0.0.1:8765/ >/dev/null 2>&1 || true; }
fail() { log "$DATE FAILED: $1"; notify "P4 nightly check FAILED ($DATE): $1"; exit 1; }

log "$DATE start"
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT
sed "s/__CHECK_DATE__/$DATE/" "$HERE/probe.py" \
  | timeout 600 railway ssh -p "$RAILWAY_PROJECT" --environment production \
      --service journeyai-backend -- poetry run python - >"$RAW" 2>&1 \
  || fail "probe exited non-zero (tail: $(grep -v '^{"time"' "$RAW" | tail -1 | cut -c1-150))"
grep -m1 '^OUT_JSON ' "$RAW" | sed 's/^OUT_JSON //' >"$JSON"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON" 2>/dev/null \
  || fail "probe printed no valid JSON"
chmod 600 "$JSON"

PREV="$REPORTS/$(date -d "$DATE -1 day" +%F).json"
{
  cat "$HERE/prompt.md"
  printf '\n## TODAY (%s)\n```json\n' "$DATE"; cat "$JSON"; printf '\n```\n'
  if [[ -s "$PREV" ]]; then
    printf '\n## YESTERDAY\n```json\n'; cat "$PREV"; printf '\n```\n'
  fi
} | (cd "$P4C_HOME" && timeout 900 claude -p --model "$MODEL" --tools "" \
      --no-session-persistence --setting-sources "" --max-budget-usd 2) >"$MD.tmp" 2>>"$LOG" \
  || fail "claude analysis failed (see $LOG)"
[[ -s "$MD.tmp" ]] || fail "claude returned an empty report"
mv "$MD.tmp" "$MD"; chmod 600 "$MD"

HEADLINE="$(grep -m1 '^HEADLINE:' "$MD" | sed 's/^HEADLINE: *//')"
log "$DATE done: ${HEADLINE:-no headline}"
notify "P4 nightly ($DATE): ${HEADLINE:-report ready} — $MD"
echo "$MD"
