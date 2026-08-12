#!/usr/bin/env bash
# Cron entrypoint for the daily brief. Fired once a day (07:00 AP_TZ) by
# supercronic. The headless `claude -p` session runs under a dontAsk profile
# that is PATH-SCOPED to the project, so it cannot read ~/.autopilot (ledger,
# env, marker) itself. This wrapper (plain bash, unrestricted) gathers
# everything the digest needs, hands it to the session as a single JSON file
# inside the project, and owns every write (brief file, marker, input file
# cleanup) -- the session is a pure transform that writes nothing outside the
# project. Always exits 0 -- the cron job must not flap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"
SETTINGS_PATH="$(cd "$SCRIPT_DIR/../settings" && pwd)/autopilot.json"
INPUT_FILE="$WORK_REPO/.autopilot-brief-input.json"
MAX_BODY_CHARS=3500

mkdir -p "$AP_HOME" "$AP_HOME/logs" "$AP_HOME/briefs"

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$AP_HOME/logs/brief.log"
}

# --- json helpers: jq if present, python3 fallback -------------------------

# ledger_since <since-ts> -> JSON array of ledger rows with ts >= since-ts,
# across every $AP_HOME/runs/*.jsonl file.
ledger_since() {
  local since="$1"
  local runs_dir="$AP_HOME/runs"
  shopt -s nullglob
  local files=("$runs_dir"/*.jsonl)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    echo '[]'
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -sc --arg since "$since" '[.[] | select(.ts >= $since)]' "${files[@]}" 2>/dev/null
    return
  fi
  python3 - "$since" "${files[@]}" <<'PY'
import json, sys
since = sys.argv[1]
rows = []
for path in sys.argv[2:]:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("ts", "") >= since:
                rows.append(d)
print(json.dumps(rows))
PY
}

# newest_ledger_ts -> ISO ts of the newest entry across ALL ledger files
# (not just the brief window), or empty if there is no ledger activity ever.
newest_ledger_ts() {
  local runs_dir="$AP_HOME/runs"
  shopt -s nullglob
  local files=("$runs_dir"/*.jsonl)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    echo ''
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -rs 'map(.ts) | max // empty' "${files[@]}" 2>/dev/null
    return
  fi
  python3 - "${files[@]}" <<'PY'
import json, sys
maxts = None
for path in sys.argv[1:]:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts = d.get("ts")
            if ts and (maxts is None or ts > maxts):
                maxts = ts
print(maxts or "")
PY
}

# compose_input <since> <now> <ledger-json> <inbox-json> <max_issues>
#   <max_cost> <today_cost> <today_issues> <newest_age_min-or-empty>
#   <paused: true|false> <scheduler_alive: true|false>
compose_input() {
  local since="$1" now="$2" ledger_json="$3" inbox_json="$4" \
    max_issues="$5" max_cost="$6" today_cost="$7" today_issues="$8" \
    newest_age_min="$9" paused="${10}" scheduler_alive="${11}"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg since "$since" --arg now "$now" \
      --argjson ledger "$ledger_json" --argjson inbox "$inbox_json" \
      --argjson max_issues "$max_issues" --argjson max_cost "$max_cost" \
      --argjson today_cost "$today_cost" --argjson today_issues "$today_issues" \
      --argjson newest_entry_age_min "${newest_age_min:-null}" \
      --argjson paused "$paused" --argjson scheduler_alive "$scheduler_alive" \
      '{since: $since, now: $now, ledger: $ledger, inbox: $inbox,
        budget: {max_issues: $max_issues, max_cost: $max_cost,
                 today_cost: $today_cost, today_issues: $today_issues},
        health: {newest_entry_age_min: $newest_entry_age_min,
                  paused: $paused, scheduler_alive: $scheduler_alive}}'
    return
  fi
  python3 - "$since" "$now" "$ledger_json" "$inbox_json" "$max_issues" \
    "$max_cost" "$today_cost" "$today_issues" "$newest_age_min" "$paused" \
    "$scheduler_alive" <<'PY'
import json, sys
(since, now, ledger_json, inbox_json, max_issues, max_cost, today_cost,
 today_issues, newest_age_min, paused, scheduler_alive) = sys.argv[1:12]
try:
    ledger = json.loads(ledger_json)
except Exception:
    ledger = []
try:
    inbox = json.loads(inbox_json)
except Exception:
    inbox = []
doc = {
    "since": since,
    "now": now,
    "ledger": ledger,
    "inbox": inbox,
    "budget": {
        "max_issues": int(max_issues),
        "max_cost": float(max_cost),
        "today_cost": float(today_cost),
        "today_issues": int(today_issues),
    },
    "health": {
        "newest_entry_age_min": (int(newest_age_min) if newest_age_min else None),
        "paused": paused == "true",
        "scheduler_alive": scheduler_alive == "true",
    },
}
print(json.dumps(doc))
PY
}

# --- gather -----------------------------------------------------------------

now="$(date -u +%FT%TZ)"

marker_file="$AP_HOME/briefs/.last-brief-ts"
if [[ -f "$marker_file" ]]; then
  since="$(cat "$marker_file")"
else
  since="$(date -u -d '24 hours ago' +%FT%TZ)"
fi

ledger_json="$(ledger_since "$since")"
[[ -z "$ledger_json" ]] && ledger_json='[]'

inbox_json="$(gh issue list -R "$AP_INBOX_REPO" --state open --json number,title,labels,url 2>>"$AP_HOME/logs/brief.log")"
[[ -z "$inbox_json" ]] && inbox_json='[]'

# Today's spend/issue count: same computation the cycle's budget gate uses --
# scoped to today's ledger file (AP_TZ calendar day), excluding poll rows,
# unique issues.
today="$(TZ="$AP_TZ" date +%F)"
today_ledger_file="$AP_HOME/runs/$today.jsonl"
read -r today_issues today_cost < <(
  if [[ -f "$today_ledger_file" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -s '{i: ([.[] | select(.phase != "poll" and .issue != null) | .issue] | unique | length), c: ([.[] | .cost] | add // 0)}' "$today_ledger_file" 2>/dev/null | jq -r '"\(.i) \(.c)"'
    else
      python3 - "$today_ledger_file" <<'PY'
import json, sys
issues = set()
cost = 0.0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        cost += float(d.get("cost") or 0)
        if d.get("phase") != "poll" and d.get("issue"):
            issues.add(d["issue"])
print(len(issues), cost)
PY
    fi
  else
    echo "0 0"
  fi
)
today_issues="${today_issues:-0}"
today_cost="${today_cost:-0}"

newest_ts="$(newest_ledger_ts)"
newest_age_min=""
if [[ -n "$newest_ts" ]]; then
  newest_epoch="$(date -u -d "$newest_ts" +%s 2>/dev/null || echo "")"
  now_epoch="$(date -u +%s)"
  if [[ -n "$newest_epoch" ]]; then
    newest_age_min=$(( (now_epoch - newest_epoch) / 60 ))
  fi
fi

paused=false
[[ -e "$AP_HOME/pause" ]] && paused=true

scheduler_alive=false
tmux has-session -t autopilot >/dev/null 2>&1 && scheduler_alive=true

input_json="$(compose_input "$since" "$now" "$ledger_json" "$inbox_json" \
  "$AP_MAX_ISSUES_PER_DAY" "$AP_MAX_DAY_COST_USD" "$today_cost" "$today_issues" \
  "$newest_age_min" "$paused" "$scheduler_alive")"

printf '%s\n' "$input_json" >"$INPUT_FILE"

# --- keep the input file out of the project's own git status ---------------

git_dir="$(git -C "$WORK_REPO" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -n "$git_dir" ]]; then
  exclude_file="$git_dir/info/exclude"
  mkdir -p "$git_dir/info"
  fence_start="# >>> autopilot ap-brief.sh (managed) >>>"
  fence_end="# <<< autopilot ap-brief.sh (managed) <<<"
  if [[ ! -f "$exclude_file" ]] || ! grep -qF "$fence_start" "$exclude_file" 2>/dev/null; then
    {
      echo "$fence_start"
      echo ".autopilot-brief-input.json"
      echo "$fence_end"
    } >>"$exclude_file"
  fi
fi

# --- invoke the skill (pure transform over the input file) -----------------

stderr_file="$AP_HOME/logs/.brief-stderr.$$"
rc=0
digest="$(cd "$WORK_REPO" && claude -p "/daily-brief --input $INPUT_FILE" --model haiku --settings "$SETTINGS_PATH" 2>"$stderr_file")" || rc=$?
cat "$stderr_file" >>"$AP_HOME/logs/brief.log" 2>/dev/null || true

if [[ $rc -ne 0 ]]; then
  log "claude invocation failed rc=$rc"
  err_tail="$(tail -c 2000 "$stderr_file" 2>/dev/null)"
  rm -f "$stderr_file" "$INPUT_FILE"
  ap-notify.sh "daily brief failed" "${err_tail:-no output captured}" || true
  exit 0
fi
rm -f "$stderr_file"

# --- wrapper owns every write: brief file, marker, input file cleanup ------

mkdir -p "$AP_HOME/briefs"
echo "$digest" >"$AP_HOME/briefs/$today.md"
printf '%s' "$now" >"$marker_file"
rm -f "$INPUT_FILE"

body="$digest"
if [[ "${#body}" -gt "$MAX_BODY_CHARS" ]]; then
  body="${body:0:$MAX_BODY_CHARS}"$'\n'"(truncated — full brief in ~/.autopilot/briefs/)"
fi

ap-notify.sh "autopilot daily brief" "$body" || true

exit 0
