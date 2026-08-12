#!/usr/bin/env bash
# Cron entrypoint for autopilot. Fired every minute by supercronic.
# Stages: pause/lock/budget gate -> scan (zero-token bash pre-scan; wakes the
# poll only when there's plausibly something to act on) -> poll (haiku) ->
# act (full model) -> reconcile (wrapper is authoritative for terminal
# states) -> ledger.
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

# dict_get <json-object> <key> -> value at that string key, or empty
dict_get() {
  local json="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
key = sys.argv[1]
v = d.get(key) if isinstance(d, dict) else None
if v is not None:
    print(v)
" "$key" 2>/dev/null
}

# list_contains <json-array> <value> -> rc 0 if value (compared as string) is present
list_contains() {
  local json="$1" value="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -e --arg v "$value" 'any(.[]?; (. | tostring) == $v)' >/dev/null 2>&1
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = sys.argv[1]
sys.exit(0 if (isinstance(arr, list) and value in [str(x) for x in arr]) else 1)
" "$value"
}

# extract_issue_numbers <gh-issue-list-json> -> issue numbers, one per line
extract_issue_numbers() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.[]?.number' 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, list):
    for item in d:
        if isinstance(item, dict) and item.get('number') is not None:
            print(item['number'])
" 2>/dev/null
}

# extract_newest_comment <gh-api-comments-json (array)> -> "<id>\t<first body line>"
# for element 0, or empty if the array is empty/unparseable.
extract_newest_comment() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.[0] | select(.) | [(.id|tostring), ((.body // "") | split("\n")[0])] | @tsv' 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, list) or not d:
    sys.exit(0)
c = d[0]
if not isinstance(c, dict):
    sys.exit(0)
cid = c.get('id')
body = c.get('body') or ''
first_line = body.split('\n', 1)[0]
if cid is not None:
    print('%s\t%s' % (cid, first_line))
" 2>/dev/null
}

# extract_new_intake_issues <gh-issue-list-json (number,labels)> -> issue
# numbers, one per line, for open issues carrying NONE of the six state
# labels below -- i.e. a fresh delegation the user just opened from the
# GitHub mobile app, titled with the Linear id (e.g. "ENG-1234").
NEW_INTAKE_STATE_LABELS='["planning","plan-review","building","ready-to-test","needs-input","failed"]'
extract_new_intake_issues() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --argjson state_labels "$NEW_INTAKE_STATE_LABELS" '
      .[]? | select(((.labels // []) | map(.name)) as $names | ($state_labels | any(. as $s | $names | index($s))) | not) | .number
    ' 2>/dev/null
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
state_labels = set(json.loads('$NEW_INTAKE_STATE_LABELS'))
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, list):
    sys.exit(0)
for item in d:
    if not isinstance(item, dict):
        continue
    names = {l.get('name') for l in (item.get('labels') or []) if isinstance(l, dict)}
    if names & state_labels:
        continue
    if item.get('number') is not None:
        print(item['number'])
" 2>/dev/null
}

# commit_scan_state <state-path> <pending-inbox-tsv> <pending-new-intake-txt> <now-ts>
# Merges pending inbox-comment / new-intake updates recorded during the scan
# into the on-disk scan-state.json, refreshing last_poll_ts. Called only
# after the claude poll stage has actually run (so a crashed poll leaves
# state untouched and retries next cycle).
commit_scan_state() {
  local state_path="$1" inbox_tsv="$2" new_intake_txt="$3" now_ts="$4"
  local old_json='{}'
  [[ -f "$state_path" ]] && old_json="$(cat "$state_path")"
  [[ -z "$old_json" ]] && old_json='{}'
  local tmp="$state_path.tmp.$$"
  python3 - "$old_json" "$inbox_tsv" "$new_intake_txt" "$now_ts" >"$tmp" <<'PYEOF'
import json, sys
old_json, inbox_tsv, new_intake_txt, now_ts = sys.argv[1:5]
try:
    old = json.loads(old_json)
except Exception:
    old = {}
if not isinstance(old, dict):
    old = {}
inbox = dict(old.get("inbox") or {})
with open(inbox_tsv) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        k, v = line.split("\t", 1)
        try:
            inbox[k] = int(v)
        except ValueError:
            continue
new_intake_seen = list(old.get("new_intake_seen") or [])
with open(new_intake_txt) as f:
    for line in f:
        line = line.strip()
        if line and line not in new_intake_seen:
            new_intake_seen.append(line)
new_state = {"inbox": inbox, "new_intake_seen": new_intake_seen, "last_poll_ts": now_ts}
print(json.dumps(new_state))
PYEOF
  mv "$tmp" "$state_path"
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

# --- Stage 0.5: deterministic pre-scan gate ---------------------------------
# Zero-token bash gate: only wake the haiku poll when there's plausibly
# something to act on. A wrong "maybe" costs one idle haiku poll, so this
# is deliberately biased toward waking. Haiku remains the decider (claiming,
# priority, go-vs-feedback); this only gates whether it runs at all.

scan_state_path="$AP_HOME/scan-state.json"
old_state_json='{}'
[[ -f "$scan_state_path" ]] && old_state_json="$(cat "$scan_state_path")"
[[ -z "$old_state_json" ]] && old_state_json='{}'

inbox_state_json="$(json_field "$old_state_json" ".inbox")"
[[ -z "$inbox_state_json" || "$inbox_state_json" == "null" ]] && inbox_state_json='{}'
new_intake_seen_json="$(json_field "$old_state_json" ".new_intake_seen")"
[[ -z "$new_intake_seen_json" || "$new_intake_seen_json" == "null" ]] && new_intake_seen_json='[]'
last_poll_ts="$(json_field "$old_state_json" ".last_poll_ts")"

scan_pending_dir="$(mktemp -d "$AP_HOME/.scan-pending.XXXXXX")"
pending_inbox_tsv="$scan_pending_dir/inbox.tsv"
pending_new_intake_txt="$scan_pending_dir/new-intake.txt"
: >"$pending_inbox_tsv"
: >"$pending_new_intake_txt"
# shellcheck disable=SC2317,SC2329 # invoked via trap, not directly
cleanup_scan_pending() { rm -rf "$scan_pending_dir"; }
trap cleanup_scan_pending EXIT

wake=false
wake_reason=""

# --- Inbox leg, trigger 1+2: plan-review / needs-input issues -------------
# Two separate `gh issue list` calls: --label ANDs on a single call, so OR-ing
# the two labels needs two queries.
inbox_list_plan_review="$(gh issue list --repo "$AP_INBOX_REPO" --state open --label plan-review --json number 2>>"$AP_HOME/logs/cycle.log")"
inbox_list_needs_input="$(gh issue list --repo "$AP_INBOX_REPO" --state open --label needs-input --json number 2>>"$AP_HOME/logs/cycle.log")"

inbox_issue_numbers="$(
  { extract_issue_numbers "${inbox_list_plan_review:-[]}"; extract_issue_numbers "${inbox_list_needs_input:-[]}"; } \
    | sort -un
)"

if [[ -n "$inbox_issue_numbers" ]]; then
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    comment_json="$(gh api "repos/$AP_INBOX_REPO/issues/$num/comments?sort=created&direction=desc&per_page=1" 2>>"$AP_HOME/logs/cycle.log")"
    [[ -z "$comment_json" ]] && continue
    comment_line="$(extract_newest_comment "$comment_json")"
    [[ -z "$comment_line" ]] && continue
    comment_id="${comment_line%%$'\t'*}"
    comment_first_line="${comment_line#*$'\t'}"
    # Agent-authored posts are always stamped with one of these markers; a
    # human reply never starts a comment this way.
    if [[ "$comment_first_line" == "Plan file:"* || "$comment_first_line" == "Phase:"* ]]; then
      continue
    fi
    recorded_id="$(dict_get "$inbox_state_json" "$num")"
    recorded_id="${recorded_id:-0}"
    if [[ "$comment_id" =~ ^[0-9]+$ ]] && [[ "$comment_id" -gt "$recorded_id" ]] 2>/dev/null; then
      wake=true
      wake_reason="${wake_reason:+$wake_reason,}inbox:$num"
      printf '%s\t%s\n' "$num" "$comment_id" >>"$pending_inbox_tsv"
    fi
  done <<<"$inbox_issue_numbers"
fi

# --- Inbox leg, trigger 3: new intake -- an open issue with none of the six
# state labels is a fresh delegation the user just opened (titled with the
# Linear id, e.g. "ENG-1234") from the GitHub mobile app.
inbox_list_all_open="$(gh issue list --repo "$AP_INBOX_REPO" --state open --json number,labels --limit 100 2>>"$AP_HOME/logs/cycle.log")"
new_intake_numbers="$(extract_new_intake_issues "${inbox_list_all_open:-[]}")"

if [[ -n "$new_intake_numbers" ]]; then
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    if ! list_contains "$new_intake_seen_json" "$num"; then
      wake=true
      wake_reason="${wake_reason:+$wake_reason,}new-intake:$num"
      printf '%s\n' "$num" >>"$pending_new_intake_txt"
    fi
  done <<<"$new_intake_numbers"
fi

# --- Fallback full poll: pure insurance, not a queue-pickup mechanism ------
# Intake is now fully deterministic (the two inbox legs above), so this only
# exists to catch (a) a human comment misclassified as agent-authored by the
# `Plan file:` / `Phase:` marker heuristic, and (b) a claim stranded by a
# mid-cycle crash that the poll skill's own stale-claim sweep would recover.
# AP_FULL_POLL_INTERVAL_MIN=0 disables this leg entirely -- the scan legs
# above remain the only wake source.
full_poll_interval_min="${AP_FULL_POLL_INTERVAL_MIN:-360}"
stale=false
if [[ "$full_poll_interval_min" -gt 0 ]]; then
  stale=true
  if [[ -n "$last_poll_ts" && "$last_poll_ts" != "null" ]]; then
    last_epoch="$(date -u -d "$last_poll_ts" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    elapsed_min=$(( (now_epoch - last_epoch) / 60 ))
    if [[ "$elapsed_min" -le "$full_poll_interval_min" ]]; then
      stale=false
    fi
  fi
fi
if [[ "$stale" == true ]]; then
  wake=true
  wake_reason="${wake_reason:+$wake_reason,}fallback"
fi

if [[ "$wake" != true ]]; then
  log "scan: no signal, skipping poll"
  exit 0
fi

log "scan: waking poll ($wake_reason)"

# --- Stage 1: poll (haiku) --------------------------------------------------

POLL_SCHEMA='{"type":"object","properties":{"action":{"type":"string","enum":["plan","implement","replan","none"]},"issue":{"type":"string"},"planPath":{"type":"string"},"inboxIssue":{"type":"number"},"feedback":{"type":"string"}},"required":["action"]}'

poll_rc=0
poll_output="$(claude -p "/autopilot-poll" --model haiku --settings "$SETTINGS_PATH" --output-format json --json-schema "$POLL_SCHEMA" 2>>"$AP_HOME/logs/cycle.log")" || poll_rc=$?

if [[ $poll_rc -ne 0 ]]; then
  log "poll invocation failed rc=$poll_rc"
  append_ledger "" "poll" "FAILED" 0 "unknown"
  exit 0
fi

# The poll stage actually ran (didn't crash) -- commit this cycle's scan
# findings now, not before. A crash above leaves scan-state untouched so the
# same human input / Linear issue / stale timer retries next cycle.
commit_scan_state "$scan_state_path" "$pending_inbox_tsv" "$pending_new_intake_txt" "$(date -u +%FT%TZ)"

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
