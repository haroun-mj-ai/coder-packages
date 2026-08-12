#!/usr/bin/env bash
# Cron entrypoint for autopilot. Fired every 20 minutes by supercronic.
# Stages: pause/lock/budget gate -> poll (haiku) -> act (full model) ->
# reconcile (wrapper is authoritative for terminal states) -> ledger.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

SETTINGS_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/settings/autopilot.json"
WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"

mkdir -p "$AP_HOME" "$AP_HOME/runs" "$AP_HOME/logs"

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$AP_HOME/logs/cycle.log"
}

# --- JSON helpers: jq if present, python3 fallback -------------------------

# json_field <json-text> <.dotted.path>  ->  scalar value, or empty string
json_field() {
  local json="$1" filter="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "${filter} // empty" 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
path = '$filter'.lstrip('.').split('.')
cur = d
try:
    for p in path:
        if p == '':
            continue
        cur = cur[p]
    if cur is None:
        sys.exit(0)
    print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur))
except Exception:
    sys.exit(0)
" 2>/dev/null
}

# json_join <json-text> <.dotted.path>  ->  comma-joined array values
json_join() {
  local json="$1" filter="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "(${filter} // []) | join(\", \")" 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
path = '$filter'.lstrip('.').split('.')
cur = d
try:
    for p in path:
        if p == '':
            continue
        cur = cur[p]
except Exception:
    cur = []
if not isinstance(cur, list):
    cur = []
print(', '.join(str(x) for x in cur))
" 2>/dev/null
}

ledger_path() {
  echo "$AP_HOME/runs/$(TZ="$AP_TZ" date +%F).jsonl"
}

# append_ledger <issue> <phase> <status> <cost> <session_id>
append_ledger() {
  local issue="$1" phase="$2" status="$3" cost="$4" session_id="$5"
  local ts ledger_file
  ts="$(date -u +%FT%TZ)"
  ledger_file="$(ledger_path)"
  mkdir -p "$(dirname "$ledger_file")"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$ts" --arg issue "$issue" --arg phase "$phase" \
      --arg status "$status" --arg session_id "${session_id:-unknown}" \
      --argjson cost "${cost:-0}" \
      '{ts:$ts, issue: (if $issue=="" then null else $issue end), phase:$phase, status:$status, cost:$cost, session_id:$session_id}' \
      >>"$ledger_file" 2>>"$AP_HOME/logs/cycle.log"
  else
    python3 - "$ts" "$issue" "$phase" "$status" "$cost" "$session_id" >>"$ledger_file" <<'PYEOF'
import json, sys
ts, issue, phase, status, cost, session_id = sys.argv[1:7]
try:
    cost_val = float(cost) if cost not in ("", "null") else 0.0
except ValueError:
    cost_val = 0.0
line = {
    "ts": ts,
    "issue": issue if issue not in ("", "null") else None,
    "phase": phase,
    "status": status,
    "cost": cost_val,
    "session_id": session_id if session_id not in ("", "null") else "unknown",
}
print(json.dumps(line))
PYEOF
  fi
}

# --- Stage 0: pause / lock / budget ----------------------------------------

if [[ -e "$AP_HOME/pause" ]]; then
  exit 0
fi

exec 9>"$AP_HOME/lock"
if ! flock -n 9; then
  exit 0
fi

today="$(TZ="$AP_TZ" date +%F)"
ledger_file="$(ledger_path)"

read -r issues_today cost_today < <(
  if [[ -f "$ledger_file" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -s '{i: ([.[] | select(.phase != "poll" and .issue != null) | .issue] | unique | length), c: ([.[] | .cost] | add // 0)}' "$ledger_file" 2>/dev/null | jq -r '"\(.i) \(.c)"'
    else
      python3 - "$ledger_file" <<'PYEOF'
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
PYEOF
    fi
  else
    echo "0 0"
  fi
)
issues_today="${issues_today:-0}"
cost_today="${cost_today:-0}"

over_budget=false
if [[ "$issues_today" -ge "$AP_MAX_ISSUES_PER_DAY" ]]; then
  over_budget=true
fi
if awk -v a="$cost_today" -v b="$AP_MAX_DAY_COST_USD" 'BEGIN{exit !(a>=b)}'; then
  over_budget=true
fi

if [[ "$over_budget" == true ]]; then
  log "budget cap reached: issues=$issues_today/$AP_MAX_ISSUES_PER_DAY cost=$cost_today/$AP_MAX_DAY_COST_USD"
  marker="$AP_HOME/logs/.budget-notified-$today"
  if [[ ! -e "$marker" ]]; then
    ap-notify.sh "autopilot budget reached" "issues=$issues_today/$AP_MAX_ISSUES_PER_DAY cost=\$$cost_today/\$$AP_MAX_DAY_COST_USD" || true
    touch "$marker"
  fi
  exit 0
fi

# --- Stage 1: poll (haiku) --------------------------------------------------

POLL_SCHEMA='{"type":"object","properties":{"action":{"type":"string","enum":["plan","implement","replan","none"]},"issue":{"type":"string"},"planPath":{"type":"string"},"inboxIssue":{"type":"number"},"feedback":{"type":"string"}},"required":["action"]}'

poll_rc=0
poll_output="$(claude -p "/autopilot-poll" --model haiku --output-format json --json-schema "$POLL_SCHEMA" 2>>"$AP_HOME/logs/cycle.log")" || poll_rc=$?

if [[ $poll_rc -ne 0 ]]; then
  log "poll invocation failed rc=$poll_rc"
  append_ledger "" "poll" "FAILED" 0 "unknown"
  exit 0
fi

poll_json="$(json_field "$poll_output" ".structured_output")"
if [[ -z "$poll_json" || "$poll_json" == "null" ]]; then
  poll_json="$(json_field "$poll_output" ".result")"
fi

action="$(json_field "$poll_json" ".action")"
issue="$(json_field "$poll_json" ".issue")"
plan_path="$(json_field "$poll_json" ".planPath")"
inbox_issue="$(json_field "$poll_json" ".inboxIssue")"
feedback="$(json_field "$poll_json" ".feedback")"

poll_cost="$(json_field "$poll_output" ".total_cost_usd")"
poll_session="$(json_field "$poll_output" ".session_id")"
append_ledger "$issue" "poll" "${action:-none}" "${poll_cost:-0}" "${poll_session:-unknown}"

if [[ -z "$action" || "$action" == "none" ]]; then
  log "poll: no action"
  exit 0
fi

log "poll: action=$action issue=${issue:-} plan=${plan_path:-} inbox=${inbox_issue:-}"

# --- Stage 2: act (full model) ---------------------------------------------

run_ts="$(date -u +%Y%m%dT%H%M%SZ)"
export AP_RUN_DIR="$AP_HOME/runs/$run_ts-$$"
mkdir -p "$AP_RUN_DIR"

status_file="$AP_RUN_DIR/status.json"
final_phase=""
final_status=""

run_claude() {
  # run_claude <phase> <prompt-arg...>  -- appends ledger row for this call
  local phase="$1"; shift
  local rc=0
  local out
  local stderr_file="$AP_RUN_DIR/$phase.stderr"
  # Remove any status.json left behind by a prior phase in this same run
  # (e.g. implement's DONE) so a crash that skips this phase's own write is
  # correctly seen as FAILED for THIS phase, not a stale leftover status.
  rm -f "$status_file"
  out="$(claude -p "$@" --settings "$SETTINGS_PATH" --output-format json 2>"$stderr_file")" || rc=$?
  cat "$stderr_file" >>"$AP_HOME/logs/cycle.log" 2>/dev/null || true
  local cost session_id st
  cost="$(json_field "$out" ".total_cost_usd")"
  session_id="$(json_field "$out" ".session_id")"
  if [[ -f "$status_file" ]]; then
    st="$(json_field "$(cat "$status_file")" ".status")"
  fi
  if [[ -z "${st:-}" ]]; then
    st="FAILED"
  fi
  append_ledger "$issue" "$phase" "$st" "${cost:-0}" "${session_id:-unknown}"
  final_phase="$phase"
  final_status="$st"
  LAST_ACT_OUTPUT="$out"
  LAST_ACT_RC="$rc"
  LAST_ACT_STDERR_FILE="$stderr_file"
  : "$LAST_ACT_RC" # not currently branched on; kept for future use/logging
}

pushd "$WORK_REPO" >/dev/null 2>&1 || cd "$WORK_REPO" || exit 1

case "$action" in
  plan)
    run_claude "plan" "/plan-issue $issue --headless"
    ;;
  replan)
    # Escape embedded single quotes ' -> '\'' so a feedback body containing
    # an apostrophe doesn't break out of the single-quoted --feedback value.
    feedback_escaped="${feedback//\'/\'\\\'\'}"
    run_claude "replan" "/plan-issue $issue --headless --feedback '$feedback_escaped'"
    ;;
  implement)
    run_claude "implement" "/implement-plan $plan_path --headless"
    if [[ "$final_status" == "DONE" ]]; then
      run_claude "ship" "/ship-work $plan_path --headless --no-merge"
    fi
    ;;
  *)
    log "poll: unknown action '$action'"
    popd >/dev/null 2>&1 || true
    exit 0
    ;;
esac

popd >/dev/null 2>&1 || true

log "act: phase=$final_phase status=$final_status issue=${issue:-}"

# --- Stage 3: reconcile (wrapper is authoritative for terminal states) ----

status_json=""
[[ -f "$status_file" ]] && status_json="$(cat "$status_file")"

inbox_url=""
if [[ -n "$inbox_issue" && "$inbox_issue" != "null" ]]; then
  inbox_url="https://github.com/$AP_INBOX_REPO/issues/$inbox_issue"
fi

case "$final_status" in
  FAILED)
    stdout_tail="$(printf '%s' "${LAST_ACT_OUTPUT:-}" | tail -c 4000)"
    stderr_tail=""
    if [[ -n "${LAST_ACT_STDERR_FILE:-}" && -f "$LAST_ACT_STDERR_FILE" ]]; then
      stderr_tail="$(tail -n 20 "$LAST_ACT_STDERR_FILE")"
    fi
    failure_body="STDERR (last 20 lines):
${stderr_tail:-<empty>}

STDOUT (tail):
${stdout_tail:-no output captured}"
    if [[ -n "$inbox_issue" && "$inbox_issue" != "null" ]]; then
      gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
        --add-label failed --remove-label planning --remove-label building \
        >>"$AP_HOME/logs/cycle.log" 2>&1 || true
      gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" \
        --body "$failure_body" \
        >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    fi
    ap-notify.sh "autopilot FAILED: ${issue:-$action}" "$failure_body" "$inbox_url" || true

    fail_count=0
    [[ -f "$AP_HOME/fail_count" ]] && fail_count="$(cat "$AP_HOME/fail_count")"
    fail_count=$(( fail_count + 1 ))
    echo "$fail_count" >"$AP_HOME/fail_count"
    if [[ "$fail_count" -ge 2 ]]; then
      touch "$AP_HOME/pause"
      ap-notify.sh "autopilot auto-paused" "2 consecutive failures. rm $AP_HOME/pause to resume." || true
    fi
    ;;

  NEEDS_HUMAN)
    question="$(json_field "$status_json" ".question")"
    if [[ -n "$inbox_issue" && "$inbox_issue" != "null" && -n "$question" && "$question" != "null" ]]; then
      gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" --body "$question" \
        >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    fi
    ap-notify.sh "autopilot needs input: ${issue:-$action}" "${question:-see inbox}" "$inbox_url" || true
    echo 0 >"$AP_HOME/fail_count"
    ;;

  DONE)
    echo 0 >"$AP_HOME/fail_count"
    if [[ "$final_phase" == "ship" ]]; then
      pr_urls="$(json_join "$status_json" ".pr_urls")"
      ap-notify.sh "ready to test: ${issue:-$action}" "${pr_urls:-see inbox}" "$inbox_url" || true
    fi
    ;;
esac

log "reconcile: done phase=$final_phase status=$final_status"
exit 0
