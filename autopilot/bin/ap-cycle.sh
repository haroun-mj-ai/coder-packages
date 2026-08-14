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
# The poll only triages, so it stays on the cheapest model. Declared here, and
# used both for the invocation and for the ledger row, so the two cannot drift.
POLL_MODEL="${AP_POLL_MODEL:-haiku}"
WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"

# EVERY claude invocation in this cycle -- the poll included -- must run from
# the work repo: Claude Code discovers project skills from the cwd, so a cycle
# that inherits some other directory (whatever `ap up` happened to be typed
# in) silently runs the poll with NO /autopilot-poll skill at all. That fails
# OPEN: $0 cost, instant action:none, every minute, and nothing in the log to
# say why. cd here, at the top -- not just before the act stage.
cd "$WORK_REPO" || exit 1

mkdir -p "$AP_HOME" "$AP_HOME/runs" "$AP_HOME/logs"

# window_alive <window-name> -> rc 0 if that window still exists in the
# autopilot tmux session, rc 1 otherwise (including "tmux/session not up",
# which is always "not alive" here rather than an error worth surfacing).
# Defined this early (rather than down by run_claude()) because the
# manual-resume sweep in Stage 0.5 needs it too.
window_alive() {
  local name="$1"
  tmux list-windows -t "$AP_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$name"
}

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
# (case-insensitive; the repo label is "Queued") and NONE of the eight state
# labels below -- i.e. an owner delegation (create the inbox issue, add
# Queued), not an unlabeled draft, which the pipeline ignores entirely.
NEW_INTAKE_STATE_LABELS='["planning","plan-review","building","shipping","ready-to-test","needs-input","failed","ship-pending"]'
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

# commit_scan_state <state-path> <pending-inbox-tsv> <pending-new-intake-txt> <now-ts> [<pending-ship-pending-txt>]
# Merges pending inbox-comment / new-intake / ship-pending updates recorded
# during the scan into the on-disk scan-state.json, refreshing last_poll_ts.
# ship-pending defaults to /dev/null (empty) for callers that don't track it.
# Called only after the claude poll stage has actually run (so a crashed poll leaves
# state untouched and retries next cycle).
commit_scan_state() {
  local state_path="$1" inbox_tsv="$2" new_intake_txt="$3" now_ts="$4" ship_pending_txt="${5:-/dev/null}"
  local old_json='{}'
  [[ -f "$state_path" ]] && old_json="$(cat "$state_path")"
  [[ -z "$old_json" ]] && old_json='{}'
  local tmp="$state_path.tmp.$$"
  python3 - "$old_json" "$inbox_tsv" "$new_intake_txt" "$now_ts" "$ship_pending_txt" >"$tmp" <<'PYEOF'
import json, sys
old_json, inbox_tsv, new_intake_txt, now_ts, ship_pending_txt = sys.argv[1:6]
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
ship_pending_seen = list(old.get("ship_pending_seen") or [])
with open(ship_pending_txt) as f:
    for line in f:
        line = line.strip()
        if line and line not in ship_pending_seen:
            ship_pending_seen.append(line)
new_state = {"inbox": inbox, "new_intake_seen": new_intake_seen,
             "ship_pending_seen": ship_pending_seen, "last_poll_ts": now_ts}
print(json.dumps(new_state))
PYEOF
  mv "$tmp" "$state_path"
}

ledger_path() {
  echo "$AP_HOME/runs/$(TZ="$AP_TZ" date +%F).jsonl"
}

# append_ledger <issue> <phase> <status> <cost> <session_id> [model]
# `model` is the model the act actually ran on. Recorded because otherwise the
# only way to learn it is to dig the transcript out of ~/.claude and read the
# per-message model field -- which is how a pipeline silently running fable-5
# went unnoticed for a day.
# Two-lane concurrency: a build act and a plan act can both be appending to
# TODAY's ledger file at the same moment. That's fine -- each call here is a
# single `>>` write of one already-fully-formed line, and POSIX guarantees
# O_APPEND writes of that shape don't interleave/corrupt each other even
# across processes. No locking needed for this file.
append_ledger() {
  local issue="$1" phase="$2" status="$3" cost="$4" session_id="$5" model="${6:-}"
  local ts ledger_file
  ts="$(date -u +%FT%TZ)"
  ledger_file="$(ledger_path)"
  mkdir -p "$(dirname "$ledger_file")"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$ts" --arg issue "$issue" --arg phase "$phase" \
      --arg status "$status" --arg session_id "${session_id:-unknown}" \
      --arg model "$model" \
      --argjson cost "${cost:-0}" \
      '{ts:$ts, issue: (if $issue=="" then null else $issue end), phase:$phase, status:$status, cost:$cost, session_id:$session_id, model: (if $model=="" then null else $model end)}' \
      >>"$ledger_file" 2>>"$AP_HOME/logs/cycle.log"
  else
    python3 - "$ts" "$issue" "$phase" "$status" "$cost" "$session_id" "$model" >>"$ledger_file" <<'PYEOF'
import json, sys
ts, issue, phase, status, cost, session_id, model = sys.argv[1:8]
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
    "model": model if model not in ("", "null") else None,
}
print(json.dumps(line))
PYEOF
  fi
}

# --- Stage 0: pause / lock.poll / budget ------------------------------------
# Locks, not one: lock.poll serializes the decision path (at most one cycle
# deciding at a time); lock.plan, the AP_BUILD_SLOTS build slots
# (lock.build.1 .. lock.build.N), and the AP_SHIP_SLOTS ship slots
# (lock.ship.1 .. lock.ship.N) are held only for the duration of an actual
# act. Three lanes: plan (plan/replan), build (implement, and the ship half
# of an implement->ship CHAIN -- that chain keeps the SAME build slot for
# both halves, see the implement case arm below for why), and ship (a
# STANDALONE ship-only retry, i.e. action=ship from a ship-pending issue --
# never the chained ship above). This lets a plan, a build, and a standalone
# ship all keep flowing concurrently -- up to AP_BUILD_SLOTS builds, up to
# AP_SHIP_SLOTS standalone ships, and one plan, plus the one cycle currently
# deciding. See autopilot/README.md's concurrency section.

# A usage-limit failure (a rate/quota trip, not a real bug) auto-pauses the
# pipeline exactly like a real failure would, and then would otherwise wait
# for a human forever -- costing a whole night of throughput for something
# that clears itself. So a pause file with reason "usage-limit" self-clears
# once it's older than AP_LIMIT_COOLDOWN_MIN; any other reason ("failures",
# "manual", or none at all -- an old-style empty pause file) keeps today's
# behavior: exit 0, stay paused until `ap resume`.
if [[ -e "$AP_HOME/pause" ]]; then
  pause_reason="$(head -n1 "$AP_HOME/pause" 2>/dev/null)"
  auto_resumed=false
  if [[ "$pause_reason" == "usage-limit" && "${AP_LIMIT_COOLDOWN_MIN:-60}" -gt 0 ]]; then
    pause_mtime="$(stat -c %Y "$AP_HOME/pause" 2>/dev/null || echo 0)"
    now_epoch_pause="$(date -u +%s)"
    pause_age_min=$(( (now_epoch_pause - pause_mtime) / 60 ))
    [[ "$pause_age_min" -ge "$AP_LIMIT_COOLDOWN_MIN" ]] && auto_resumed=true
  fi
  if [[ "$auto_resumed" == true ]]; then
    rm -f "$AP_HOME/pause"
    echo 0 >"$AP_HOME/fail_count"
    log "pause: usage-limit cooldown elapsed, auto-resuming"
    ap-notify.sh "autopilot auto-resumed" "usage-limit cooldown (${AP_LIMIT_COOLDOWN_MIN}m) elapsed; resuming automatically." || true
  else
    exit 0
  fi
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

# Build lane = AP_BUILD_SLOTS independent slots (lock.build.1 .. lock.build.N),
# so several implement->ship chains can run at once (see ap-env.sh for why
# that's safe here: mongomock per-test + per-build worktrees). Ship lane =
# AP_SHIP_SLOTS independent slots (lock.ship.1 .. lock.ship.N) for STANDALONE
# ship-only retries (never the ship half of an implement->ship chain -- that
# stays on its build slot). Both lanes count as busy to the poll ONLY when
# every slot in that lane is occupied; probing lowest-first so the same slot
# number is reused preferentially over higher ones.
busy_build=false
busy_plan=false
busy_ship=false
free_build_slot=""
free_ship_slot=""
for ((build_slot_n = 1; build_slot_n <= AP_BUILD_SLOTS; build_slot_n++)); do
  if lane_free "$AP_HOME/lock.build.$build_slot_n"; then
    free_build_slot="$build_slot_n"
    break
  fi
done
[[ -z "$free_build_slot" ]] && busy_build=true
for ((ship_slot_n = 1; ship_slot_n <= AP_SHIP_SLOTS; ship_slot_n++)); do
  if lane_free "$AP_HOME/lock.ship.$ship_slot_n"; then
    free_ship_slot="$ship_slot_n"
    break
  fi
done
[[ -z "$free_ship_slot" ]] && busy_ship=true
lane_free "$AP_HOME/lock.plan" || busy_plan=true

busy_lanes=""
[[ "$busy_build" == true ]] && busy_lanes="build"
[[ "$busy_ship" == true ]] && busy_lanes="${busy_lanes:+$busy_lanes,}ship"
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
ship_pending_seen_json="$(json_field "$old_state_json" ".ship_pending_seen")"
[[ -z "$ship_pending_seen_json" || "$ship_pending_seen_json" == "null" ]] && ship_pending_seen_json='[]'
last_poll_ts="$(json_field "$old_state_json" ".last_poll_ts")"

scan_pending_dir="$(mktemp -d "$AP_HOME/.scan-pending.XXXXXX")"
pending_inbox_tsv="$scan_pending_dir/inbox.tsv"
pending_new_intake_txt="$scan_pending_dir/new-intake.txt"
pending_ship_pending_txt="$scan_pending_dir/ship-pending.txt"
: >"$pending_inbox_tsv"
: >"$pending_new_intake_txt"
: >"$pending_ship_pending_txt"
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
# is_parked <inbox-issue> -> rc 0 if a live parked-registry entry exists for
# it -- the only legal next action for such an issue is `resume`
# (scan_parked_replies below), never a fresh claim/replan/implement/ship.
# This is the direct extension of the ENG-1308 per-issue-lock fix to cover
# the parked interval, when no flock is held (the process that would hold
# it exited at park time -- see run_claude()'s persistent-mode branch).
is_parked() {
  [[ -f "$AP_HOME/parked/$1.json" ]]
}

scan_inbox_comments() {
  local numbers="$1" fixed_lane="$2"
  [[ -z "$numbers" ]] && return
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    is_parked "$num" && continue
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
    # human reply never starts a comment this way. The marker is the ONLY
    # defence: the pipeline comments with the owner's own gh credentials, so
    # `author.login` is identical for both and useless as a signal. An unmarked
    # agent comment is therefore read as owner feedback and triggers a re-plan,
    # whose own comment triggers the next -- an unbounded, money-burning loop
    # observed on ENG-1137 (two re-plans in seven minutes). Every comment any
    # part of this pipeline writes MUST begin with one of these markers:
    #   Plan file:  a plan post (also the machine-readable planPath source)
    #   Phase:      a NEEDS_HUMAN question or a phase-scoped informational post
    #   Autopilot:  anything the wrapper itself writes (failures, re-queues)
    if [[ "$comment_first_line" == "Plan file:"* \
       || "$comment_first_line" == "Phase:"* \
       || "$comment_first_line" == "Autopilot:"* ]]; then
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

# --- Parked-act replies: relay directly, never through the poll -----------
# scan_parked_replies -- for every currently-parked act (persistent mode
# only; empty dir in oneshot mode, so this is a no-op there), check whether
# a fresh, unmarked (owner) comment landed on its inbox issue since it
# parked (or since whichever reply was last relayed) and if so, background
# ap-resume.sh to inject it directly into the still-live window. Never sets
# `wake=true`: routing a reply to an already-parked act needs no
# poll/claim judgement call at all -- the live session's own next turn
# interprets it with full context, which is the entire efficiency point of
# parking instead of re-deriving from the plan file.
scan_parked_replies() {
  [[ -d "$AP_HOME/parked" ]] || return
  local f num comment_json comment_line comment_id comment_first_line recorded_id comment_body
  for f in "$AP_HOME"/parked/*.json; do
    [[ -e "$f" ]] || continue
    num="$(basename "$f" .json)"
    comment_json="$(gh api "repos/$AP_INBOX_REPO/issues/$num/comments?per_page=100" 2>>"$AP_HOME/logs/cycle.log")"
    [[ -z "$comment_json" ]] && continue
    comment_line="$(extract_newest_comment "$comment_json")"
    [[ -z "$comment_line" ]] && continue
    comment_id="${comment_line%%$'\t'*}"
    comment_first_line="${comment_line#*$'\t'}"
    # Same agent-authored-marker check as scan_inbox_comments -- a comment
    # this pipeline wrote itself (the NEEDS_HUMAN echo, a `Plan file:` post)
    # is never owner input, parked act or not.
    if [[ "$comment_first_line" == "Plan file:"* \
       || "$comment_first_line" == "Phase:"* \
       || "$comment_first_line" == "Autopilot:"* ]]; then
      continue
    fi
    recorded_id="$(json_field "$(cat "$f" 2>/dev/null)" ".last_relayed_comment_id")"
    recorded_id="${recorded_id:-0}"
    if [[ "$comment_id" =~ ^[0-9]+$ ]] && [[ "$comment_id" -gt "$recorded_id" ]] 2>/dev/null; then
      comment_body="$(json_field "$comment_json" ".[-1].body")"
      [[ -z "$comment_body" ]] && comment_body="$comment_first_line"
      log "scan: parked issue $num has a fresh reply (comment $comment_id), backgrounding ap-resume.sh"
      # Do NOT mark last_relayed_comment_id here. ap-resume.sh itself marks
      # it, and only once it has actually committed to injecting (acquired
      # the resume lock, confirmed the window alive, acquired a lane slot) --
      # never here, before we know any of that succeeded. Marking it
      # pre-emptively was a real bug: if ap-resume.sh then bailed on "no free
      # slot right now" (a normal, expected, retry-later condition -- the
      # same shape as every other busy-lane skip in this file), the comment
      # would have been silently treated as consumed forever, since nothing
      # would make comment_id > recorded_id true again. Passing $comment_id
      # through lets ap-resume.sh mark it at the right moment; every cycle
      # until then just re-backgrounds a cheap, harmless ap-resume.sh retry
      # (its own lock.resume.<n> makes a second concurrent one a fast no-op).
      nohup "$SCRIPT_DIR/ap-resume.sh" "$num" "$comment_body" "$comment_id" >>"$AP_HOME/logs/cycle.log" 2>&1 &
      disown
    fi
  done
}
scan_parked_replies

# --- Manual tmux-attach resumes: detect and reconcile ----------------------
# sweep_manual_resumes -- a parked act's window can be resumed by the owner
# attaching to it directly (`tmux attach -t autopilot`) and typing an
# answer, entirely bypassing ap-resume.sh and the bookkeeping it would have
# done. That's a deliberate feature of using a real pty, not a bug -- but it
# means nothing has yet reconciled the lane/issue locks or cleaned up the
# registry for it. Detect this for every parked entry with no resume
# currently in flight (lane_free on its own lock.resume.<n>): if its
# status.json has moved off NEEDS_HUMAN (a new terminal or re-parked
# state), or its window is simply gone, hand it to ap-resume.sh with no
# reply text -- same reconcile path, it just has nothing new to inject.
sweep_manual_resumes() {
  [[ -d "$AP_HOME/parked" ]] || return
  local f num registry_json run_dir window cur_status
  for f in "$AP_HOME"/parked/*.json; do
    [[ -e "$f" ]] || continue
    num="$(basename "$f" .json)"
    lane_free "$AP_HOME/lock.resume.$num" || continue
    registry_json="$(cat "$f" 2>/dev/null)"
    run_dir="$(json_field "$registry_json" ".run_dir")"
    window="$(json_field "$registry_json" ".window")"
    [[ -z "$run_dir" || -z "$window" ]] && continue
    cur_status=""
    [[ -f "$run_dir/status.json" ]] && cur_status="$(json_field "$(cat "$run_dir/status.json")" ".status")"
    if [[ "$cur_status" != "NEEDS_HUMAN" ]] || ! window_alive "$window"; then
      log "scan: parked issue $num looks manually resumed (status=${cur_status:-missing}) -- reconciling via ap-resume.sh"
      nohup "$SCRIPT_DIR/ap-resume.sh" "$num" "" >>"$AP_HOME/logs/cycle.log" 2>&1 &
      disown
    fi
  done
}
sweep_manual_resumes

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

# --- Inbox leg, trigger 3: ship-pending -- implement finished and committed,
# ship still owed (Change 2: a ship-only retry after a ship phase failed
# externally, or a human relabelled by hand). A wake signal like the two
# above, tracked in scan-state (ship_pending_seen) the same way new-intake
# is, so a non-actionable one does not re-wake every minute. Claims the SHIP
# lane -- its own slot pool, separate from build (a standalone ship act is
# almost pure CI-wait, so it must never queue behind a build slot; see
# ap-env.sh's AP_SHIP_SLOTS comment for why). NOT the same lane the
# implement->ship chain uses for its trailing ship call -- that chain never
# reaches this leg at all, since it isn't a scan signal.
inbox_list_ship_pending="$(gh issue list --repo "$AP_INBOX_REPO" --state open --label ship-pending --json number 2>>"$AP_HOME/logs/cycle.log")"
ship_pending_numbers="$(extract_issue_numbers "${inbox_list_ship_pending:-[]}" | sort -un)"
if [[ -n "$ship_pending_numbers" ]]; then
  while IFS= read -r num; do
    [[ -z "$num" ]] && continue
    if ! list_contains "$ship_pending_seen_json" "$num"; then
      if [[ "$busy_ship" == true ]]; then
        continue
      fi
      wake=true
      wake_reason="${wake_reason:+$wake_reason,}ship-pending:$num"
      printf '%s\n' "$num" >>"$pending_ship_pending_txt"
    fi
  done <<<"$ship_pending_numbers"
fi

# --- Inbox leg, trigger 4: new intake -- an open issue carrying the `Queued`
# label (case-insensitive) and none of the eight state labels is an owner
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

# --- Stage 1: poll (haiku, or the deterministic decider) -------------------
# AP_POLL_MODE=deterministic replaces the haiku /autopilot-poll call with
# ap-decide.sh, which implements the exact same tiers/keywords/claim rules
# against live `gh` data for $0 -- see ap-decide.sh's header comment. Default
# stays "model": no behaviour change until the owner flips it. Compare the
# two with `ap decide` before flipping (see autopilot/README.md).

poll_json=""

if [[ "${AP_POLL_MODE:-model}" == "deterministic" ]]; then
  decide_rc=0
  poll_json="$("$SCRIPT_DIR/ap-decide.sh" --claim --busy "$busy_lanes" 2>>"$AP_HOME/logs/cycle.log")" || decide_rc=$?
  if [[ $decide_rc -ne 0 || -z "$poll_json" ]]; then
    log "ap-decide.sh invocation failed rc=$decide_rc"
    poll_json='{"action":"none"}'
  fi
  poll_cost=0
  poll_session="deterministic"
  poll_model_for_ledger="none"
else
  POLL_SCHEMA='{"type":"object","properties":{"action":{"type":"string","enum":["plan","implement","replan","ship","none"]},"issue":{"type":"string"},"planPath":{"type":"string"},"inboxIssue":{"type":"number"},"feedback":{"type":"string"}},"required":["action"]}'

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
  poll_output="$(claude -p "$poll_prompt" --model "$POLL_MODEL" --settings "$SETTINGS_PATH" --output-format json --json-schema "$POLL_SCHEMA" 2>>"$AP_HOME/logs/cycle.log")" || poll_rc=$?

  if [[ $poll_rc -ne 0 ]]; then
    log "poll invocation failed rc=$poll_rc"
    append_ledger "" "poll" "FAILED" 0 "unknown" "$POLL_MODEL"
    flock -u 9
    exit 0
  fi

  poll_json="$(json_field "$poll_output" ".structured_output")"
  if [[ -z "$poll_json" || "$poll_json" == "null" ]]; then
    poll_json="$(json_field "$poll_output" ".result")"
  fi

  poll_cost="$(json_field "$poll_output" ".total_cost_usd")"
  poll_session="$(json_field "$poll_output" ".session_id")"
  poll_model_for_ledger="$POLL_MODEL"
fi

action_peek="$(json_field "$poll_json" ".action")"
inbox_issue_peek="$(json_field "$poll_json" ".inboxIssue")"
# The poll ran (didn't crash) -- commit scan findings, but only as much as
# the poll actually consumed. The poll takes at most ONE action per cycle:
# when it acted, the label swap it performed is the real bookkeeping, and
# the OTHER pending signals must stay live so the next cycle re-wakes and
# drains them one by one (previously they were all marked seen and stranded
# until the insurance poll). When the poll found nothing actionable (none),
# commit everything so non-actionable signals stop re-waking us every
# minute. Either way last_poll_ts refreshes.
#
# BUT the ONE signal the poll DID consume must still be marked seen here --
# not left for a later cycle, and not marked via the "none" branch above
# (which never runs for an actionable poll). Filter each pending file down
# to just the consumed issue's line, from the SAME data the scan already
# collected this cycle (no extra gh call, no re-fetch race). Missing this
# is exactly the bug hit live on ENG-1308 (2026-08-14): a "discard the
# worktrees" comment was consumed by a replan, never marked seen, and a
# later cycle saw it as still-new and replanned AGAIN with the same stale
# feedback -- burning a redundant run and, worse, clobbering the label back
# over a genuinely new NEEDS_HUMAN question that had landed in between.
if [[ "$action_peek" == "none" ]]; then
  commit_scan_state "$scan_state_path" "$pending_inbox_tsv" "$pending_new_intake_txt" "$(date -u +%FT%TZ)" "$pending_ship_pending_txt"
else
  consumed_inbox_tsv="$(mktemp)"
  consumed_new_intake_txt="$(mktemp)"
  consumed_ship_pending_txt="$(mktemp)"
  if [[ -n "$inbox_issue_peek" && "$inbox_issue_peek" =~ ^[0-9]+$ ]]; then
    grep -m1 -P "^${inbox_issue_peek}\t" "$pending_inbox_tsv" >"$consumed_inbox_tsv" 2>/dev/null || :
    grep -m1 -x "$inbox_issue_peek" "$pending_new_intake_txt" >"$consumed_new_intake_txt" 2>/dev/null || :
    grep -m1 -x "$inbox_issue_peek" "$pending_ship_pending_txt" >"$consumed_ship_pending_txt" 2>/dev/null || :
  fi
  commit_scan_state "$scan_state_path" "$consumed_inbox_tsv" "$consumed_new_intake_txt" "$(date -u +%FT%TZ)" "$consumed_ship_pending_txt"
  rm -f "$consumed_inbox_tsv" "$consumed_new_intake_txt" "$consumed_ship_pending_txt"
fi

action="$action_peek"
issue="$(json_field "$poll_json" ".issue")"
plan_path="$(json_field "$poll_json" ".planPath")"
inbox_issue="$inbox_issue_peek"
feedback="$(json_field "$poll_json" ".feedback")"

append_ledger "$issue" "poll" "${action:-none}" "${poll_cost:-0}" "${poll_session:-unknown}" "$poll_model_for_ledger"

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
build_slot=""
ship_slot=""
fe_port=""
be_port=""
case "$action" in
  plan|replan) act_lane="plan"; act_lock_file="$AP_HOME/lock.plan" ;;
  implement)
    act_lane="build"
    build_slot="$free_build_slot"
    if [[ -n "$build_slot" ]]; then
      act_lock_file="$AP_HOME/lock.build.$build_slot"
      # Port pair for this slot, so two concurrent builds never bind the same
      # port. 5173/8000 are the human's baseline pair (README's four-server
      # comparison) and must never be handed to a slot, hence n starting at 1.
      # This same fe_port/be_port pair is reused below, unchanged, for the
      # trailing `ship` call of an implement->ship CHAIN in this same
      # process -- that chain keeps its build slot for both halves; it never
      # goes through the standalone `ship)` arm below.
      fe_port=$((5173 + build_slot))
      be_port=$((8000 + build_slot))
    fi
    ;;
  ship)
    # STANDALONE ship-only retry ONLY (poll emitted action=ship for a
    # ship-pending issue -- see autopilot-poll's tier 4). This is the
    # non-obvious part: this arm is NOT how the implement->ship chain ships.
    # That chain's action is "implement", handled above; when its status
    # comes back DONE, the SAME process makes a second run_claude("ship", ...)
    # call further down using the build_slot/fe_port/be_port already
    # acquired for the implement half -- it never re-enters this case
    # statement, so it never touches the ship lane at all. Only a fresh cycle
    # whose poll action is literally "ship" lands here, and gets its own
    # lane/slot/ports instead.
    act_lane="ship"
    ship_slot="$free_ship_slot"
    if [[ -n "$ship_slot" ]]; then
      act_lock_file="$AP_HOME/lock.ship.$ship_slot"
      # Ship base (5180/8010) is deliberately non-overlapping with both the
      # build base (5173/8000, slots land at 5174..5177/8001..8004 for
      # AP_BUILD_SLOTS<=4) and the human's own 5173/8000 -- so a standalone
      # ship's local gates can never collide with a running build or the
      # human's baseline. ship-work serves no UI, so these ports only matter
      # for gate isolation; the frontend CORS allowlist is irrelevant here for
      # the same reason (see implement-issue's headless section for where CORS
      # actually matters, for the build lane).
      fe_port=$((5180 + ship_slot))
      be_port=$((8010 + ship_slot))
    fi
    ;;
esac

if [[ -z "$act_lane" ]]; then
  log "poll: unknown action '$action'"
  flock -u 9
  exit 0
fi

if [[ ( "$act_lane" == "build" || "$act_lane" == "ship" ) && -z "$act_lock_file" ]]; then
  log "act: no free $act_lane slot right after a free probe under lock.poll -- not acting this cycle; the poll's own label swap will be caught by the stale-claim sweep"
  flock -u 9
  exit 0
fi

exec {lane_fd}>"$act_lock_file"
if ! flock -n "$lane_fd"; then
  log "act: lane lock '$act_lane' unexpectedly busy right after a free probe under lock.poll -- not acting this cycle; the poll's own label swap will be caught by the stale-claim sweep"
  flock -u 9
  exit 0
fi

# PER-ISSUE lock, on top of the lane lock. The lane locks cap how many acts
# run at once; they do NOT stop the SAME issue entering two different slots.
# Claiming is the poll skill's job (the plan-review -> building label swap),
# and that is prose executed by a model: if the swap lags or is skipped, the
# next cycle re-claims the same issue a minute later and two implementers race
# on one worktree. That happened on ENG-1308 (2026-08-13): polls at 03:50:53
# and 03:51:53 both emitted implement for it, and an implementer only caught
# it by noticing files change between its own reads. This lock makes the claim
# enforced rather than advisory, so the failure cannot recur however the poll
# behaves. Held for the life of the act; released by process exit.
if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
  issue_lock_file="$AP_HOME/lock.issue.$issue"
  exec {issue_fd}>"$issue_lock_file"
  if ! flock -n "$issue_fd"; then
    log "act: issue $issue is ALREADY being acted on by another cycle -- refusing to start a second act on the same worktrees (see lock.issue.$issue)"
    flock -u 9
    exit 0
  fi
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

# window_name_for <phase> -> the tmux window name this act's persistent
# session runs in, e.g. act_plan_ENG-1234_plan, act_build_1_ENG-1234_implement,
# act_ship_2_ENG-1234_ship. Reads act_lane/build_slot/ship_slot/issue -- all
# already-set globals by the time any act runs (the lane-lock acquisition
# above sets them before dispatching). One window name scheme, so `ap
# status`/`ap runs` (see ap-runs.py) can parse lane/slot/phase/issue back out
# of it without a second source of truth.
#
# Underscore-separated, NOT dot-separated: tmux's own target syntax is
# session:window.pane, so a window name containing dots gets misparsed by
# tmux itself the moment anything (kill-window, send-keys, list-panes)
# targets it by name -- caught live, not theoretically, when a first version
# of this used dots and `tmux capture-pane -t "autopilot:act.plan.ENG-1.plan"`
# failed with "can't find pane". Underscores are never special to tmux.
window_name_for() {
  local phase="$1"
  case "$act_lane" in
    plan)  printf 'act_plan_%s_%s' "${issue:-unknown}" "$phase" ;;
    build) printf 'act_build_%s_%s_%s' "${build_slot:-0}" "${issue:-unknown}" "$phase" ;;
    ship)  printf 'act_ship_%s_%s_%s' "${ship_slot:-0}" "${issue:-unknown}" "$phase" ;;
    *)     printf 'act_unknown_%s_%s' "${issue:-unknown}" "$phase" ;;
  esac
}

# park_registry_write <inbox-issue> <question> -- persists everything a
# later `ap-resume.sh` (or the manual-resume sweep) needs to re-acquire this
# act's slot and inject a reply into its still-live window. Called only from
# Stage 3's NEEDS_HUMAN branch, only in persistent mode.
park_registry_write() {
  local inbox_issue="$1" question="$2"
  mkdir -p "$AP_HOME/parked"
  local now_ts
  now_ts="$(date -u +%FT%TZ)"
  python3 - "$AP_HOME/parked/$inbox_issue.json" "$inbox_issue" "${issue:-}" \
    "${final_phase:-}" "${act_lane:-}" "${LAST_ACT_WINDOW:-}" "${LAST_ACT_SESSION_ID:-}" \
    "${AP_RUN_DIR:-}" "${plan_path:-}" "${fe_port:-}" "${be_port:-}" "$now_ts" "$question" <<'PY'
import json, sys
(path, inbox_issue, issue, phase, lane, window, session_id,
 run_dir, plan_path, fe_port, be_port, parked_at, question) = sys.argv[1:14]
# Preserve last_relayed_comment_id across a re-park if this issue was
# already parked once before (a resume that led straight back to another
# NEEDS_HUMAN). Losing it here would make the OLD comment that triggered
# the first resume look "new" again on the next scan and get re-injected
# into a session now waiting on a completely different question -- the
# exact "circling back on the same issue" failure mode this registry
# exists to prevent, not cause.
last_relayed = None
try:
    with open(path) as f:
        last_relayed = json.load(f).get("last_relayed_comment_id")
except Exception:
    pass
d = {
    "inbox_issue": int(inbox_issue) if inbox_issue.isdigit() else inbox_issue,
    "issue": issue or None,
    "phase": phase or None,
    "lane": lane or None,
    "window": window or None,
    "session_id": session_id or None,
    "run_dir": run_dir or None,
    "plan_path": plan_path or None,
    "ports": {"fe": fe_port, "be": be_port} if fe_port else None,
    "parked_at": parked_at,
    "question": question or None,
    "last_relayed_comment_id": last_relayed,
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
import os
os.replace(tmp, path)
PY
}

# park_registry_remove <inbox-issue> -- called once an act resumes and
# reaches its next terminal (or re-parked -- see park_registry_write again)
# state. Removing this is what tells the parked-issue filter in the scan
# legs below that the issue is claimable again.
park_registry_remove() {
  rm -f "$AP_HOME/parked/$1.json"
}

run_claude() {
  # run_claude <phase> <prompt-arg...>  -- appends ledger row for this call
  local phase="$1"; shift
  local rc=0
  local out=""
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
  log "act: phase=$phase model=$model"

  LAST_ACT_WINDOW=""
  LAST_ACT_SESSION_ID=""

  if [[ "$AP_ACT_LAUNCH_MODE" == "oneshot" ]]; then
    # Exactly today's behavior: one-shot claude -p, blocks on process exit,
    # no tmux window, no parking possible -- NEEDS_HUMAN just ends the run,
    # same as always.
    #
    # Act runs park long test suites in background tasks; the -p harness
    # kills the session after its background-wait ceiling (default 10 min),
    # which is how a healthy 28-min implement died with no result record.
    # Give acts a 60-min ceiling (override via AP_BG_WAIT_CEILING_MS).
    out="$(CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${AP_BG_WAIT_CEILING_MS:-3600000}" \
      claude -p "$@" --model "$model" --settings "$SETTINGS_PATH" --output-format json 2>"$stderr_file")" || rc=$?
    cat "$stderr_file" >>"$AP_HOME/logs/cycle.log" 2>/dev/null || true
  else
    # Persistent: launch as a real interactive `claude` session (no -p) in
    # its own tmux window, so a NEEDS_HUMAN stop can park alive instead of
    # exiting. Launched via `bash -c 'exec claude ...'` rather than directly,
    # so stderr can still be redirected to a file the same way -p's -- exec
    # replaces the shell with claude in place, so #{pane_pid} is still
    # unambiguously the claude process, not the wrapping shell.
    local window launch_ok=true
    window="$(window_name_for "$phase")"
    LAST_ACT_WINDOW="$window"
    if window_alive "$window"; then
      log "act: window $window already exists -- refusing to launch a duplicate (stale window from a prior crash?), treating this act as FAILED"
      launch_ok=false
    else
      tmux new-window -t "$AP_TMUX_SESSION" -n "$window" -d -- \
        bash -c 'exec env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$1" claude --settings "$2" --model "$3" "$4" 2>"$5"' \
        _ "${AP_BG_WAIT_CEILING_MS:-3600000}" "$SETTINGS_PATH" "$model" "$1" "$stderr_file"
    fi
    if [[ "$launch_ok" == true ]]; then
      # Poll for the skill's own status.json (any status -- DONE, FAILED, or
      # NEEDS_HUMAN all just end this loop; Stage 3 below decides what each
      # one means) or the window disappearing with none written (a crash).
      while true; do
        [[ -f "$status_file" ]] && break
        if ! window_alive "$window"; then
          log "act: window $window disappeared before writing status.json -- treating as crash"
          break
        fi
        sleep 5
      done
    fi
    cat "$stderr_file" >>"$AP_HOME/logs/cycle.log" 2>/dev/null || true
  fi

  local cost="0" session_id="" st
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

  if [[ "$AP_ACT_LAUNCH_MODE" == "oneshot" ]]; then
    cost="$(json_field "$out" ".total_cost_usd")"
    session_id="$(json_field "$out" ".session_id")"
  elif [[ -n "$LAST_ACT_WINDOW" ]] && window_alive "$LAST_ACT_WINDOW"; then
    # No -p JSON blob in persistent mode, so total_cost_usd isn't handed to
    # us directly -- session id comes from the pane's own pid ->
    # ~/.claude/sessions/<pid>.json (the same registry ap-runs.py already
    # reads), then `ap-runs.py cost` reconstructs an estimate from that
    # session's own transcript (token usage x published per-model rates).
    # An estimate, not the real billed figure -- see autopilot/README.md.
    local pane_pid
    pane_pid="$(tmux list-panes -t "$AP_TMUX_SESSION:$LAST_ACT_WINDOW" -F '#{pane_pid}' 2>/dev/null | head -1)"
    if [[ -n "$pane_pid" ]]; then
      session_id="$(json_field "$(cat "${AP_SESSIONS_DIR:-$HOME/.claude/sessions}/$pane_pid.json" 2>/dev/null)" ".sessionId")"
    fi
    LAST_ACT_SESSION_ID="$session_id"
    if [[ -n "$session_id" ]]; then
      local estimated_cost
      estimated_cost="$(python3 "$SCRIPT_DIR/ap-runs.py" cost "$session_id" 2>>"$AP_HOME/logs/cycle.log")"
      [[ "$estimated_cost" =~ ^[0-9.]+$ ]] && cost="$estimated_cost"
    fi
    if [[ "$st" == "DONE" || "$st" == "FAILED" ]]; then
      # Short debounce before tearing down: status.json is itself the last
      # tool call the skill makes, so the transcript is already complete by
      # the time we see it exist; this only covers a trailing text turn
      # printed right after that write.
      sleep 3
      tmux kill-window -t "$AP_TMUX_SESSION:$LAST_ACT_WINDOW" 2>/dev/null || true
    fi
    # NEEDS_HUMAN: window deliberately left alive here. Stage 3 below is
    # what decides to park it (write the registry entry) -- this function
    # only ever launches/tears down, never parks.
  fi

  append_ledger "$issue" "$phase" "$st" "${cost:-0}" "${session_id:-unknown}" "$model"
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
    run_claude "plan" "/implement-issue --phase plan $issue --headless"
    ;;
  replan)
    # Escape embedded single quotes ' -> '\'' so a feedback body containing
    # an apostrophe doesn't break out of the single-quoted --feedback value.
    feedback_escaped="${feedback//\'/\'\\\'\'}"
    run_claude "replan" "/implement-issue --phase plan $issue --headless --feedback '$feedback_escaped'"
    ;;
  implement)
    # --ports is literal prompt text, same mechanism as --run-dir (the
    # dontAsk profile is path-scoped, so the session cannot read env): tells
    # this slot's implement (and, harmlessly, ship) which changed-pair ports
    # to bind so concurrent build slots never collide. See
    # claude/skills/implement-issue/SKILL.md's headless section.
    run_claude "implement" "/implement-issue --phase implement $plan_path --headless --ports fe=$fe_port,be=$be_port"
    if [[ "$final_status" == "DONE" ]]; then
      # The wrapper, not the skill, owns this swap and its ping -- reliable
      # even if the ship session dies before writing anything. `shipping` is
      # held only for the duration of this phase (push, PR, CI wait), so the
      # owner can tell "still building" apart from "opening the PR" instead
      # of the inbox going silently quiet between building and ready-to-test.
      if [[ -n "$inbox_issue" && "$inbox_issue" != "null" ]]; then
        gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
          --add-label shipping --remove-label building \
          >>"$AP_HOME/logs/cycle.log" 2>&1 || true
        ap-notify.sh "shipping: ${issue:-$action}" "implement done, opening the PR" \
          "https://github.com/$AP_INBOX_REPO/issues/$inbox_issue" || true
      fi
      run_claude "ship" "/ship-work $plan_path --headless --no-merge --ports fe=$fe_port,be=$be_port"
    fi
    ;;
  ship)
    # A ship-only retry (Change 2): implement already committed, ship still
    # owed -- either a prior ship phase failed externally and got re-queued
    # to `ship-pending` (Change 1), or a human relabelled by hand. The poll
    # skill already swapped ship-pending -> shipping before emitting this
    # action, so there's no wrapper-side label swap to do here (unlike the
    # implement->ship chain above, which swaps building -> shipping itself).
    run_claude "ship" "/ship-work $plan_path --headless --no-merge --ports fe=$fe_port,be=$be_port"
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
    # Persistent-mode acts have no -p JSON blob, so LAST_ACT_OUTPUT is always
    # empty and stderr rarely carries anything useful (interactive claude
    # doesn't write to it the way -p does) -- both classifier inputs below
    # are effectively blind for this launch mode. The transcript itself is
    # usually NOT blind (e.g. the model's own "cut off by a session usage
    # limit" explanation lives there, not in stderr), so pull its final
    # message in too. This is exactly the gap that mislabeled ENG-1308
    # `failed` instead of re-queuing it on 2026-08-14: an external usage-limit
    # interruption with nothing in stdout/stderr to classify it by.
    transcript_tail=""
    if [[ -n "${LAST_ACT_SESSION_ID:-}" ]]; then
      transcript_tail="$(python3 "$SCRIPT_DIR/ap-runs.py" tail-text "$LAST_ACT_SESSION_ID" 2>>"$AP_HOME/logs/cycle.log" | tail -c 4000)"
    fi
    failure_body="STDERR (last 20 lines):
${stderr_tail:-<empty>}

STDOUT (tail):
${stdout_tail:-no output captured}${transcript_tail:+

TRANSCRIPT (final message):
$transcript_tail}"

    # failure_signature: the full stderr+stdout+transcript-tail of the
    # failing run, used to classify EVERY failure below -- both "was this
    # caused by something outside our control" (EXTERNAL_SIGNATURE_REGEX,
    # this reconcile branch) and "should the auto-pause tag itself
    # usage-limit" (further down). One classifier, two consumers -- a
    # session/rate/quota trip that looks external here should also be the
    # thing that makes the pause self-clearing.
    failure_signature="${stderr_tail:-} ${LAST_ACT_OUTPUT:-} ${transcript_tail:-}"
    if [[ -n "${LAST_ACT_STDERR_FILE:-}" && -f "$LAST_ACT_STDERR_FILE" ]]; then
      failure_signature="$(cat "$LAST_ACT_STDERR_FILE" 2>/dev/null) ${LAST_ACT_OUTPUT:-} ${transcript_tail:-}"
    fi
    # EXTERNAL_SIGNATURE_REGEX: causes that are not a bug in the plan or the
    # code -- the owner's own usage/session limit, a provider-side rate/quota
    # trip, or the provider itself erroring out (overloaded/529/"API
    # Error"). The night five acts died mid-run to the owner's session limit
    # and every one of them dead-ended at `failed` -- a label nothing ever
    # wakes on -- stalling the whole queue until a human relabelled seven
    # issues by hand. A failure matching this signature is re-queued instead
    # (see below); anything else keeps today's `failed` behavior unchanged.
    EXTERNAL_SIGNATURE_REGEX='usage limit|rate limit|429|quota|overloaded|529|api error|session limit'
    external_failure_line=""
    if printf '%s' "$failure_signature" | grep -qiE "$EXTERNAL_SIGNATURE_REGEX"; then
      external_failure_line="$(printf '%s\n' "$failure_signature" | grep -iE "$EXTERNAL_SIGNATURE_REGEX" | head -n1)"
    fi

    if [[ -n "$external_failure_line" ]]; then
      # Restore the state this phase started from, so the SAME work is
      # picked up again once the cooldown/pause clears -- never `failed`,
      # which is a dead end no wake signal ever fires on.
      requeue_label="" requeue_remove=""
      case "$final_phase" in
        plan|replan) requeue_label="Queued";     requeue_remove="planning" ;;
        implement)   requeue_label="plan-review"; requeue_remove="building" ;;
        ship)        requeue_label="ship-pending"; requeue_remove="shipping" ;;
      esac
      if [[ -n "$inbox_issue" && "$inbox_issue" != "null" && -n "$requeue_label" ]]; then
        gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
          --add-label "$requeue_label" --remove-label "$requeue_remove" \
          >>"$AP_HOME/logs/cycle.log" 2>&1 || true
        gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" \
          --body "Autopilot: external failure, re-queued (matched: \`$external_failure_line\`).

$failure_body" \
          >>"$AP_HOME/logs/cycle.log" 2>&1 || true
      fi
      ap-notify.sh "requeued after external failure: ${issue:-$action}" "$failure_body" "$inbox_url" || true
    else
      if [[ -n "$inbox_issue" && "$inbox_issue" != "null" ]]; then
        gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
          --add-label failed --remove-label planning --remove-label building \
          --remove-label shipping --remove-label ship-pending \
          >>"$AP_HOME/logs/cycle.log" 2>&1 || true
        gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" \
          --body "Autopilot: run failed.

$failure_body" \
          >>"$AP_HOME/logs/cycle.log" 2>&1 || true
      fi
      ap-notify.sh "autopilot FAILED: ${issue:-$action}" "$failure_body" "$inbox_url" || true
    fi

    # Two-lane concurrency: a plan-lane FAILED and a build-lane FAILED can
    # read-increment-write this file at the same moment -- an unguarded
    # read-modify-write, so one increment can be lost to the other (both read
    # "1", both write "2" instead of "2" then "3"). Acceptable: it only makes
    # auto-pause slightly less prompt in the rare case of a genuinely
    # simultaneous plan+build failure, never less safe (never fails to pause
    # eventually, since each lane's own next failure re-reads and increments
    # again), and a lock here would fight the very concurrency this feature
    # exists for.
    #
    # fail_count++ happens for BOTH external and non-external causes,
    # deliberately -- an external failure is exempt from the `failed` label
    # and its dead-end comment, but NOT from this counter. The existing
    # 2-consecutive-failure auto-pause, plus the usage-limit cooldown that
    # tags it self-clearing, IS the backoff that stops a re-queue from
    # thrashing (act, fail externally, re-queue, act again, fail again,
    # ...); carving external causes out of the counter would defeat the
    # reason it exists. Do not "fix" this later.
    fail_count=0
    [[ -f "$AP_HOME/fail_count" ]] && fail_count="$(cat "$AP_HOME/fail_count")"
    fail_count=$(( fail_count + 1 ))
    echo "$fail_count" >"$AP_HOME/fail_count"
    if [[ "$fail_count" -ge 2 ]]; then
      # A usage/rate-limit trip is not a real bug -- it clears itself, so tag
      # the pause with a reason the top-of-cycle check can act on (see Stage
      # 0's pause handling). Any other failure gets "failures", which never
      # auto-clears. Reuses the narrower slice of EXTERNAL_SIGNATURE_REGEX
      # that is specifically a limit/quota trip (not every external cause --
      # a provider outage tagged "overloaded" clears on its own timeline, not
      # a fixed cooldown, so it still gets "failures" and waits for a human).
      pause_reason="failures"
      if printf '%s' "$failure_signature" | grep -qiE 'usage limit|rate limit|429|quota|session limit'; then
        pause_reason="usage-limit"
      fi
      echo "$pause_reason" >"$AP_HOME/pause"
      ap-notify.sh "autopilot auto-paused" "2 consecutive failures (reason: $pause_reason). rm $AP_HOME/pause to resume." || true
    fi
    ;;

  NEEDS_HUMAN)
    question="$(json_field "$status_json" ".question")"
    if [[ -n "$inbox_issue" && "$inbox_issue" != "null" && -n "$question" && "$question" != "null" ]]; then
      # MUST carry a marker. This is the wrapper ECHOING the skill's question,
      # and the echo is a separate comment from the skill's own marked one --
      # posted later, so it becomes the newest. Unmarked, the next scan reads
      # the pipeline's own question as owner feedback and re-plans; that
      # re-plan ends NEEDS_HUMAN, the wrapper echoes again, and it loops.
      # Observed on ENG-1308: five re-plans, ~$17, all from this one echo.
      # Prefix unconditionally rather than trusting `question` to be marked --
      # a duplicated marker line is harmless, a missing one is a loop.
      gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" \
        --body "Autopilot: needs input (phase ${final_phase:-unknown}).

$question" \
        >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    fi
    ap-notify.sh "autopilot needs input: ${issue:-$action}" "${question:-see inbox}" "$inbox_url" || true
    echo 0 >"$AP_HOME/fail_count"
    # Persistent mode: the window is still alive (run_claude() deliberately
    # didn't kill it for NEEDS_HUMAN) -- park it. Oneshot mode: nothing to
    # park, the process already exited, exactly as before this feature.
    if [[ "$AP_ACT_LAUNCH_MODE" != "oneshot" && -n "$LAST_ACT_WINDOW" \
       && -n "$inbox_issue" && "$inbox_issue" != "null" ]]; then
      park_registry_write "$inbox_issue" "${question:-}"
    fi
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
