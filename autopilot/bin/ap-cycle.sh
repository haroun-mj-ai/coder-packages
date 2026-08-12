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

# EVERY claude invocation in this cycle -- the poll included -- must run from
# the work repo: Claude Code discovers project skills from the cwd, so a cycle
# that inherits some other directory (whatever `ap up` happened to be typed
# in) silently runs the poll with NO /autopilot-poll skill at all. That fails
# OPEN: $0 cost, instant action:none, every minute, and nothing in the log to
# say why. cd here, at the top -- not just before the act stage.
cd "$WORK_REPO" || exit 1

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
# for the LAST element, or empty if the array is empty/unparseable. The
# per-issue comments endpoint ignores sort/direction and returns ascending
# order, so the newest comment is the last element, never element 0.
extract_newest_comment() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.[-1] | select(.) | [(.id|tostring), ((.body // "") | split("\n")[0])] | @tsv' 2>/dev/null
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
c = d[-1]
if not isinstance(c, dict):
    sys.exit(0)
cid = c.get('id')
body = c.get('body') or ''
first_line = body.split('\n', 1)[0]
if cid is not None:
    print('%s\t%s' % (cid, first_line))
" 2>/dev/null
}

# issue_labeled_auto <inbox-issue-number> -> rc 0 if the issue carries the
# `auto` label (case-insensitive; Change C's per-issue auto-approve switch),
# rc 1 otherwise (including "couldn't tell" -- err on not-auto-approving).
issue_labeled_auto() {
  local num="$1" json
  json="$(gh issue view "$num" --repo "$AP_INBOX_REPO" --json labels 2>>"$AP_HOME/logs/cycle.log")"
  [[ -z "$json" ]] && return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -e '(.labels // []) | map(.name | ascii_downcase) | any(. == "auto")' >/dev/null 2>&1
    return
  fi
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names = {str(l.get('name', '')).lower() for l in (d.get('labels') or []) if isinstance(l, dict)}
sys.exit(0 if 'auto' in names else 1)
"
}

# extract_new_intake_issues <gh-issue-list-json (number,labels)> -> issue
# numbers, one per line, for open issues carrying the `Queued` label
# (case-insensitive; the repo label is "Queued") and NONE of the six state
# labels below -- i.e. an owner delegation (create the inbox issue, add
# Queued), not an unlabeled draft, which the pipeline ignores entirely.
NEW_INTAKE_STATE_LABELS='["planning","plan-review","building","ready-to-test","needs-input","failed"]'
extract_new_intake_issues() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --argjson state_labels "$NEW_INTAKE_STATE_LABELS" '
      .[]? |
      (((.labels // []) | map(.name))) as $names |
      select(
        ($names | map(ascii_downcase) | any(. == "queued")) and
        (($state_labels | any(. as $s | $names | index($s))) | not)
      ) | .number
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
    names_lower = {str(n).lower() for n in names if n is not None}
    if 'queued' not in names_lower:
        continue
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
# Two-lane concurrency: a build act and a plan act can both be appending to
# TODAY's ledger file at the same moment. That's fine -- each call here is a
# single `>>` write of one already-fully-formed line, and POSIX guarantees
# O_APPEND writes of that shape don't interleave/corrupt each other even
# across processes. No locking needed for this file.
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

# --- Stage 0: pause / lock.poll / budget ------------------------------------
# Three locks, not one: lock.poll serializes the decision path (at most one
# cycle deciding at a time); lock.build and lock.plan are held only for the
# duration of an actual act (implement's ship chain counts as part of the
# build lane; plan/replan is the plan lane). This lets a plan keep flowing
# while a build runs -- at most one build AND one plan concurrently, plus the
# one cycle currently deciding. See autopilot/README.md's concurrency section.

if [[ -e "$AP_HOME/pause" ]]; then
  exit 0
fi

exec 9>"$AP_HOME/lock.poll"
if ! flock -n 9; then
  # Another cycle is already deciding -- not busy-waiting, just exit; the
  # next cron minute tries again.
  exit 0
fi

# lane_free <lock-file> -- probes a lane lock non-destructively: opens it on
# a spare fd, flock -n; on success unlock+close immediately (lane free) and
# return 0; on failure close and return 1 (lane busy). Never blocks.
lane_free() {
  local lock_file="$1"
  local fd
  exec {fd}>"$lock_file" || return 1
  if flock -n "$fd"; then
    flock -u "$fd"
    exec {fd}>&-
    return 0
  fi
  exec {fd}>&-
  return 1
}

busy_build=false
busy_plan=false
lane_free "$AP_HOME/lock.build" || busy_build=true
lane_free "$AP_HOME/lock.plan" || busy_plan=true

busy_lanes=""
[[ "$busy_build" == true ]] && busy_lanes="build"
if [[ "$busy_plan" == true ]]; then
  busy_lanes="${busy_lanes:+$busy_lanes,}plan"
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

# scan_inbox_comments <issue-numbers> <fixed-lane-or-empty>
# Two-lane concurrency: a tier-1 approval ("go" on plan-review) claims the
# BUILD lane (it becomes `implement`); everything else here -- plan-review
# feedback (-> replan) and needs-input answers (-> replan) -- claims the PLAN
# lane. fixed_lane forces the lane (needs-input is always plan); empty means
# classify from the comment text (plan-review: exact "go" -> build, else
# plan). A signal whose lane is currently busy is skipped entirely: not
# recorded as pending, so it is neither acted on nor marked seen -- it
# re-fires next cycle once the lane frees.
scan_inbox_comments() {
  local numbers="$1" fixed_lane="$2"
  [[ -z "$numbers" ]] && return
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    # Ascending order (sort/direction are ignored on this endpoint); fetch a
    # full page and let extract_newest_comment take the last element. Inbox
    # threads are short; >100 comments would need pagination we skip for now.
    local comment_json comment_line comment_id comment_first_line recorded_id signal_lane comment_lower
    comment_json="$(gh api "repos/$AP_INBOX_REPO/issues/$num/comments?per_page=100" 2>>"$AP_HOME/logs/cycle.log")"
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
      if [[ -n "$fixed_lane" ]]; then
        signal_lane="$fixed_lane"
      else
        # "auto" joins "go" as a directive (Change C): posted on a
        # plan-review issue it means build now, exactly like "go" -- never
        # feedback, so it must not fall into the plan lane below.
        comment_lower="$(printf '%s' "$comment_first_line" | tr '[:upper:]' '[:lower:]')"
        if [[ "$comment_lower" == "go" || "$comment_lower" == "auto" ]]; then
          signal_lane="build"
        else
          signal_lane="plan"
        fi
      fi
      if [[ "$signal_lane" == "build" && "$busy_build" == true ]] || \
         [[ "$signal_lane" == "plan" && "$busy_plan" == true ]]; then
        continue
      fi
      wake=true
      wake_reason="${wake_reason:+$wake_reason,}inbox:$num"
      printf '%s\t%s\n' "$num" "$comment_id" >>"$pending_inbox_tsv"
    fi
  done <<<"$numbers"
}

scan_inbox_comments "$(extract_issue_numbers "${inbox_list_plan_review:-[]}" | sort -un)" ""
scan_inbox_comments "$(extract_issue_numbers "${inbox_list_needs_input:-[]}" | sort -un)" "plan"

# --- Auto-approve leg (Change C): a plan-review issue is a build-lane
# approval signal even with NO new owner comment when auto-approve applies
# to it -- global $AP_AUTO_APPROVE=1, or the issue itself carries the `auto`
# label (case-insensitive). This is deliberately a superset of what the
# comment leg above already wakes for (a fresh "go"/"auto" comment, or a
# fresh non-directive comment that must win as feedback in the PLAN lane
# instead): the poll skill, not this bash gate, is the one that reads the
# full thread and decides which tier actually applies, so an extra wake here
# is harmless (never marked seen, no pending write -- just a cheap re-check
# every cycle until claimed, same as any other biased-toward-waking signal).
# NEVER extended to needs-input: a blocking question always waits for the
# owner, auto-approve or not.
if [[ "$busy_build" != true ]]; then
  inbox_list_plan_review_labeled="$(gh issue list --repo "$AP_INBOX_REPO" --state open --label plan-review --json number,labels 2>>"$AP_HOME/logs/cycle.log")"
  auto_approve_numbers="$(
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "${inbox_list_plan_review_labeled:-[]}" | jq -r --arg auto_on "$AP_AUTO_APPROVE" '
        .[]? | select($auto_on == "1" or ((.labels // []) | map(.name | ascii_downcase) | any(. == "auto"))) | .number
      ' 2>/dev/null
    else
      printf '%s' "${inbox_list_plan_review_labeled:-[]}" | python3 -c "
import json, os, sys
auto_on = os.environ.get('AP_AUTO_APPROVE', '0') == '1'
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
for item in d if isinstance(d, list) else []:
    if not isinstance(item, dict):
        continue
    names = {str(l.get('name', '')).lower() for l in (item.get('labels') or []) if isinstance(l, dict)}
    if auto_on or 'auto' in names:
        num = item.get('number')
        if num is not None:
            print(num)
"
    fi
  )"
  if [[ -n "$auto_approve_numbers" ]]; then
    while IFS= read -r num; do
      [[ -z "$num" ]] && continue
      wake=true
      wake_reason="${wake_reason:+$wake_reason,}auto-approve:$num"
    done <<<"$auto_approve_numbers"
  fi
fi

# --- Inbox leg, trigger 3: new intake -- an open issue carrying the `Queued`
# label (case-insensitive) and none of the six state labels is an owner
# delegation (titled with the Linear id, e.g. "ENG-1234"); an unlabeled open
# issue is a draft the pipeline ignores entirely.
inbox_list_all_open="$(gh issue list --repo "$AP_INBOX_REPO" --state open --json number,labels --limit 100 2>>"$AP_HOME/logs/cycle.log")"
new_intake_numbers="$(extract_new_intake_issues "${inbox_list_all_open:-[]}")"

if [[ -n "$new_intake_numbers" ]]; then
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    if ! list_contains "$new_intake_seen_json" "$num"; then
      # Queued intake claims the PLAN lane (it becomes `plan`); busy -> skip,
      # not marked seen, re-fires next cycle once the plan lane frees.
      if [[ "$busy_plan" == true ]]; then
        continue
      fi
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
  flock -u 9
  exit 0
fi

log "scan: waking poll ($wake_reason) busy-lanes=${busy_lanes:-none}"

# --- Stage 1: poll (haiku) --------------------------------------------------

POLL_SCHEMA='{"type":"object","properties":{"action":{"type":"string","enum":["plan","implement","replan","none"]},"issue":{"type":"string"},"planPath":{"type":"string"},"inboxIssue":{"type":"number"},"feedback":{"type":"string"}},"required":["action"]}'

# Tells the poll skill which lanes are currently occupied by an act in a
# DIFFERENT, still-running cycle, so it skips tiers whose action would target
# a busy lane rather than emitting one the wrapper would just have to reject
# (see the lane-lock acquisition below). Omitted entirely when no lane is
# busy.
poll_prompt="/autopilot-poll"
[[ -n "$busy_lanes" ]] && poll_prompt="$poll_prompt --busy-lanes $busy_lanes"
# Global auto-approve only -- per-issue (`auto` label or an `auto` comment)
# the skill reads itself from the labels/comments it already fetches.
[[ "$AP_AUTO_APPROVE" == "1" ]] && poll_prompt="$poll_prompt --auto-approve"

poll_rc=0
poll_output="$(claude -p "$poll_prompt" --model haiku --settings "$SETTINGS_PATH" --output-format json --json-schema "$POLL_SCHEMA" 2>>"$AP_HOME/logs/cycle.log")" || poll_rc=$?

if [[ $poll_rc -ne 0 ]]; then
  log "poll invocation failed rc=$poll_rc"
  append_ledger "" "poll" "FAILED" 0 "unknown"
  flock -u 9
  exit 0
fi

poll_json="$(json_field "$poll_output" ".structured_output")"
if [[ -z "$poll_json" || "$poll_json" == "null" ]]; then
  poll_json="$(json_field "$poll_output" ".result")"
fi

action_peek="$(json_field "$poll_json" ".action")"
# The poll ran (didn't crash) -- commit scan findings, but only as much as
# the poll actually consumed. The poll takes at most ONE action per cycle:
# when it acted, the label swap it performed is the real bookkeeping, and
# the OTHER pending signals must stay live so the next cycle re-wakes and
# drains them one by one (previously they were all marked seen and stranded
# until the insurance poll). When the poll found nothing actionable (none),
# commit everything so non-actionable signals stop re-waking us every
# minute. Either way last_poll_ts refreshes.
if [[ "$action_peek" == "none" ]]; then
  commit_scan_state "$scan_state_path" "$pending_inbox_tsv" "$pending_new_intake_txt" "$(date -u +%FT%TZ)"
else
  commit_scan_state "$scan_state_path" /dev/null /dev/null "$(date -u +%FT%TZ)"
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
  flock -u 9
  exit 0
fi

log "poll: action=$action issue=${issue:-} plan=${plan_path:-} inbox=${inbox_issue:-}"

# --- Lane lock: acquire the lane this action needs, THEN release lock.poll -
# so a plan can be decided (and start) while this cycle's build runs, or vice
# versa. act_lane is derived from the SAME probe the scan filtered signals
# against, so this acquisition should always succeed; a failure here is a
# real anomaly, not ordinary contention, since lock.poll serializes deciders
# to exactly one at a time.
act_lane=""
act_lock_file=""
case "$action" in
  plan|replan) act_lane="plan"; act_lock_file="$AP_HOME/lock.plan" ;;
  implement) act_lane="build"; act_lock_file="$AP_HOME/lock.build" ;;
esac

if [[ -z "$act_lane" ]]; then
  log "poll: unknown action '$action'"
  flock -u 9
  exit 0
fi

exec {lane_fd}>"$act_lock_file"
if ! flock -n "$lane_fd"; then
  log "act: lane lock '$act_lane' unexpectedly busy right after a free probe under lock.poll -- not acting this cycle; the poll's own label swap will be caught by the stale-claim sweep"
  flock -u 9
  exit 0
fi

# The lane lock (held for the rest of this script, released by process exit
# either way -- crash semantics preserved) is now the only thing guarding
# this act. Release lock.poll so the NEXT cycle can start deciding the other
# lane immediately, instead of waiting on this act to finish.
flock -u 9

# --- Stage 2: act (full model) ---------------------------------------------

run_ts="$(date -u +%Y%m%dT%H%M%SZ)"
export AP_RUN_DIR="$AP_HOME/runs/$run_ts-$$"
mkdir -p "$AP_RUN_DIR"

status_file="$AP_RUN_DIR/status.json"
final_phase=""
final_status=""

# Model per act phase. MUST be pinned explicitly: without --model the act
# inherits whatever ~/.claude/settings.json happens to say, so an interactive
# `/model` change silently reprices (or downgrades) the whole pipeline. That is
# how plan/implement/ship ran on fable-5 at 2x opus cost until 2026-08-12.
# Design vs execution: planning is the judgement-heavy half and gets opus;
# implement/ship execute an already-approved plan and get sonnet, matching the
# sonnet subagents those skills dispatch.
act_model() {
  case "$1" in
    plan|replan) echo "${AP_PLAN_MODEL:-opus}" ;;
    implement)   echo "${AP_IMPLEMENT_MODEL:-sonnet}" ;;
    ship)        echo "${AP_SHIP_MODEL:-sonnet}" ;;
    *)           echo "${AP_ACT_MODEL:-sonnet}" ;;
  esac
}

run_claude() {
  # run_claude <phase> <prompt-arg...>  -- appends ledger row for this call
  local phase="$1"; shift
  local rc=0
  local out
  local model
  model="$(act_model "$phase")"
  local stderr_file="$AP_RUN_DIR/$phase.stderr"
  local adhoc_status="$AP_HOME/runs/adhoc/status.json"
  # Remove any status.json left behind by a prior phase in this same run
  # (e.g. implement's DONE) so a crash that skips this phase's own write is
  # correctly seen as FAILED for THIS phase, not a stale leftover status.
  # Same for a stale adhoc fallback from an earlier run.
  rm -f "$status_file" "$adhoc_status"
  # The dontAsk profile is path-scoped to the project, so the session cannot
  # read $AP_RUN_DIR from its environment; --run-dir hands it the path as
  # literal prompt text (see autopilot-protocol.md).
  set -- "$1 --run-dir $AP_RUN_DIR" "${@:2}"
  # Act runs park long test suites in background tasks; the -p harness kills
  # the session after its background-wait ceiling (default 10 min), which is
  # how a healthy 28-min implement died with no result record. Give acts a
  # 60-min ceiling (override via AP_BG_WAIT_CEILING_MS).
  log "act: phase=$phase model=$model"
  out="$(CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${AP_BG_WAIT_CEILING_MS:-3600000}" \
    claude -p "$@" --model "$model" --settings "$SETTINGS_PATH" --output-format json 2>"$stderr_file")" || rc=$?
  cat "$stderr_file" >>"$AP_HOME/logs/cycle.log" 2>/dev/null || true
  local cost session_id st
  cost="$(json_field "$out" ".total_cost_usd")"
  session_id="$(json_field "$out" ".session_id")"
  if [[ ! -f "$status_file" && -f "$adhoc_status" ]]; then
    # Session fell back to the documented adhoc path (could not resolve the
    # run dir). $AP_HOME/runs/adhoc/status.json is a SINGLE shared path, and
    # two-lane concurrency means a build act and a plan act can both be
    # running right now -- either could have left this file. Freshly cleared
    # above (so a hit here postdates that clear), but that alone no longer
    # proves it's THIS act's: parse .issue and adopt only on an exact match;
    # otherwise leave the file untouched and treat it as missing (the other
    # act still needs to find it).
    local adhoc_issue
    adhoc_issue="$(json_field "$(cat "$adhoc_status" 2>/dev/null)" ".issue")"
    if [[ "$adhoc_issue" == "${issue:-}" ]]; then
      mv "$adhoc_status" "$status_file" 2>/dev/null || cp "$adhoc_status" "$status_file"
      log "act: adopted adhoc status.json for phase=$phase"
    else
      log "act: adhoc status.json .issue mismatch (want='${issue:-}' got='$adhoc_issue') for phase=$phase -- leaving it for its actual owner, treating as missing"
    fi
  fi
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

    # Two-lane concurrency: a plan-lane FAILED and a build-lane FAILED can
    # read-increment-write this file at the same moment -- an unguarded
    # read-modify-write, so one increment can be lost to the other (both read
    # "1", both write "2" instead of "2" then "3"). Acceptable: it only makes
    # auto-pause slightly less prompt in the rare case of a genuinely
    # simultaneous plan+build failure, never less safe (never fails to pause
    # eventually, since each lane's own next failure re-reads and increments
    # again), and a lock here would fight the very concurrency this feature
    # exists for.
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
    elif [[ "$final_phase" == "plan" || "$final_phase" == "replan" ]]; then
      # The approval gate is the whole point: the owner must know a plan is
      # waiting for review the moment it lands -- UNLESS auto-approve already
      # applies to this issue (global flag, or its own `auto` label/comment
      # history, which the poll skill would already have promoted to the
      # `auto` label per autopilot-protocol.md), in which case it's about to
      # build without a `go`, and the ping should say so instead of asking
      # for one -- the owner must be able to tell the two apart at a glance.
      auto_will_build=false
      if [[ "$AP_AUTO_APPROVE" == "1" ]]; then
        auto_will_build=true
      elif [[ -n "$inbox_issue" && "$inbox_issue" != "null" ]] && issue_labeled_auto "$inbox_issue"; then
        auto_will_build=true
      fi
      if [[ "$auto_will_build" == true ]]; then
        ap-notify.sh "plan auto-approved, building: ${issue:-$action}" "no 'go' needed -- auto-approve is on for this issue; comment to override with feedback before it starts" "$inbox_url" || true
      else
        ap-notify.sh "plan ready for review: ${issue:-$action}" "comment 'go' to build, anything else = feedback" "$inbox_url" || true
      fi
    fi
    ;;
esac

log "reconcile: done phase=$final_phase status=$final_status"
exit 0
