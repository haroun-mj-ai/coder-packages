#!/usr/bin/env bash
# Cron entrypoint for autopilot. Fired every minute by supercronic.
# Stages: pause/lock/budget gate -> parked-relay/manual-resume reconcile ->
# decide (deterministic, local queue, always $0) -> act (full model) ->
# reconcile (wrapper is authoritative for terminal states) -> ledger.
#
# There is no GitHub inbox and no haiku poll anymore: intake, plan approval,
# blocking-question answers and ship retries are all local
# ($AP_HOME/queue/<ENG-ID>.json, written by `ap queue`/`ap approve`/
# `ap reply`/`ap retry` -- see ap_queue.py), and the decision logic
# (ap-decide.py) is deterministic and free, so there's no longer a reason to
# gate whether it runs -- it runs every cycle, unconditionally.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

SETTINGS_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/settings/autopilot.json"
WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"

# EVERY claude invocation in this cycle must run from the work repo: Claude
# Code discovers project skills from the cwd, so a cycle that inherits some
# other directory (whatever `ap up` happened to be typed in) silently runs
# with no skills at all. cd here, at the top -- not just before the act stage.
cd "$WORK_REPO" || exit 1

mkdir -p "$AP_HOME" "$AP_HOME/runs" "$AP_HOME/logs"

QUEUE_PY="$SCRIPT_DIR/ap_queue.py"
queue_get() { python3 "$QUEUE_PY" --ap-home "$AP_HOME" get "$1" 2>/dev/null; }
# queue_set <eng-id> --state X [--field k=v ...] [--event "..."] -- thin
# wrapper so call sites read like the rest of this file's bash idiom.
queue_set() {
  local eng_id="$1"; shift
  python3 "$QUEUE_PY" --ap-home "$AP_HOME" set "$eng_id" "$@" >>"$AP_HOME/logs/cycle.log" 2>&1 || true
}

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
# Still used for status.json/registry parsing throughout the act/reconcile
# stages below (unrelated to the old inbox scan, which is gone).

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
# deciding at a time); the AP_PLAN_SLOTS plan slots (lock.plan, then
# lock.plan.2 .. lock.plan.N), the AP_BUILD_SLOTS build slots
# (lock.build.1 .. lock.build.N), the AP_SHIP_SLOTS ship slots
# (lock.ship.1 .. lock.ship.N), and the AP_REVIEW_SLOTS review slots
# (lock.review.1 .. lock.review.N) are held only for the duration of an
# actual act. Four lanes: plan (legacy plan/replan -- dead, ap-decide.py
# emits neither any more, kept inert for the `ap sessions [s]` manual escape
# hatch; piv design/redesign for a feature; piv investigate/re-investigate
# for a bug), build (legacy implement, and the ship half of an
# implement->ship CHAIN -- that chain keeps the SAME build slot for both
# halves, see the implement case arm below for why -- also dead/inert for the
# same reason; piv fix for a bug, piv build for a feature -- neither chains
# into review, see the fix|build case arm below), ship (a STANDALONE
# ship-only retry, i.e. action=ship from a ship-pending ticket -- never the
# chained ship above; also dead/inert -- no decider tier can produce
# ship-pending any more once both piv forks are live, since neither writes
# it), and review (piv review -- shared by both piv kinds, a fresh cycle's
# decided action, never chained into from fix or build). This lets a plan, a
# build, a standalone ship, and a review all keep flowing concurrently -- up
# to AP_BUILD_SLOTS builds, up to AP_SHIP_SLOTS standalone ships, up to
# AP_REVIEW_SLOTS reviews, and up to AP_PLAN_SLOTS plans, plus the one cycle
# currently deciding. See autopilot/README.md's concurrency section.
#
# See docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md and
# docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md for the piv
# fork/design. Legacy plan/replan/implement/ship (and the implement->ship
# chain) are kept deliberately inert, not deleted: a hand-set legacy state
# via `ap sessions [s]` still reaches them, which is the manual escape hatch
# while the piv pipeline is unproven. Removal belongs to a later
# legacy-cleanup plan.

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
# stays on its build slot). Both lanes count as busy to the decider ONLY when
# every slot in that lane is occupied; probing lowest-first so the same slot
# number is reused preferentially over higher ones.
busy_build=false
busy_plan=false
busy_ship=false
busy_review=false
free_build_slot=""
free_ship_slot=""
free_plan_slot=""
free_review_slot=""
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
# Review lane = AP_REVIEW_SLOTS independent slots (lock.review.1 ..
# lock.review.N), same lowest-slot-first probe and same
# "busy only when EVERY slot is taken" accounting as build and ship above.
# `piv-review-pr` (debate-review + babysit-pr) for a bug- or feature-path PR
# -- shared by both piv kinds, a fresh cycle's own decided action, never
# chained into from fix or build (see the fix|build case arm below for why).
for ((review_slot_n = 1; review_slot_n <= AP_REVIEW_SLOTS; review_slot_n++)); do
  if lane_free "$AP_HOME/lock.review.$review_slot_n"; then
    free_review_slot="$review_slot_n"
    break
  fi
done
[[ -z "$free_review_slot" ]] && busy_review=true
# Plan lane = AP_PLAN_SLOTS independent slots (slot 1 is lock.plan, slots
# 2..N are lock.plan.$n -- see ap-env.sh's plan_lock_file). Same
# lowest-slot-first probe and same "busy only when EVERY slot is taken"
# accounting as build and ship above; before AP_PLAN_SLOTS existed this was
# one hard-coded lane, which serialized all new intake (ap-decide.py tier 5).
for ((plan_slot_n = 1; plan_slot_n <= AP_PLAN_SLOTS; plan_slot_n++)); do
  if lane_free "$(plan_lock_file "$plan_slot_n")"; then
    free_plan_slot="$plan_slot_n"
    break
  fi
done
[[ -z "$free_plan_slot" ]] && busy_plan=true

busy_lanes=""
[[ "$busy_build" == true ]] && busy_lanes="build"
[[ "$busy_ship" == true ]] && busy_lanes="${busy_lanes:+$busy_lanes,}ship"
[[ "$busy_review" == true ]] && busy_lanes="${busy_lanes:+$busy_lanes,}review"
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

# Over budget suppresses NEW intake only (tier 5, queued -> plan) -- it does
# NOT exit the whole cycle. An earlier version exited here outright, which
# meant an already-approved/answered/ship-pending ticket (tiers 1-4, all
# continuing work claimed before the cap was hit) sat stuck until midnight
# alongside genuinely new tickets, for no reason: hit live 2026-08-19,
# ENG-1373 approved at plan-review, then invisible to every cycle for the
# rest of the day because this exited before Stage 1 ever ran.
suppress_new_intake="0"
if [[ "$over_budget" == true ]]; then
  suppress_new_intake="1"
  log "budget cap reached: issues=$issues_today/$AP_MAX_ISSUES_PER_DAY cost=$cost_today/$AP_MAX_DAY_COST_USD -- suppressing new intake only"
  marker="$AP_HOME/logs/.budget-notified-$today"
  if [[ ! -e "$marker" ]]; then
    ap-notify.sh "autopilot budget reached" "issues=$issues_today/$AP_MAX_ISSUES_PER_DAY cost=\$$cost_today/\$$AP_MAX_DAY_COST_USD" || true
    touch "$marker"
  fi
fi

# --- Stage 0.5: parked-act relay + manual-resume reconcile ------------------
# Not a "should we bother deciding" gate anymore (deciding is free) -- these
# two sweeps exist for an orthogonal reason: a parked act's tmux window needs
# a fresh reply relayed DIRECTLY into it, never through a fresh
# claim/dispatch (ap-decide.py's tier3 already excludes anything with a live
# parked-registry entry -- see its own comment).

is_parked() {
  [[ -f "$AP_HOME/parked/$1.json" ]]
}

# scan_parked_replies -- for every currently-parked act (persistent mode
# only; empty dir in oneshot mode, so this is a no-op there), check whether
# the ticket's `feedback_seq` has advanced since whichever reply was last
# relayed, and if so, background ap-resume.sh to inject the current
# `feedback` text directly into the still-live window. Never claims a lane:
# routing a reply to an already-parked act needs no decider/claim judgement
# call at all -- the live session's own next turn interprets it with full
# context, which is the entire efficiency point of parking instead of
# re-deriving from the plan file.
scan_parked_replies() {
  [[ -d "$AP_HOME/parked" ]] || return
  local f eng_id ticket_json feedback_seq recorded_seq feedback_text
  for f in "$AP_HOME"/parked/*.json; do
    [[ -e "$f" ]] || continue
    eng_id="$(basename "$f" .json)"
    ticket_json="$(queue_get "$eng_id")"
    [[ -z "$ticket_json" || "$ticket_json" == "null" ]] && continue
    feedback_text="$(json_field "$ticket_json" ".feedback")"
    [[ -z "$feedback_text" ]] && continue
    feedback_seq="$(json_field "$ticket_json" ".feedback_seq")"
    feedback_seq="${feedback_seq:-0}"
    recorded_seq="$(json_field "$(cat "$f" 2>/dev/null)" ".last_relayed_feedback_seq")"
    recorded_seq="${recorded_seq:-0}"
    if [[ "$feedback_seq" =~ ^[0-9]+$ ]] && [[ "$feedback_seq" -gt "$recorded_seq" ]] 2>/dev/null; then
      log "scan: parked ticket $eng_id has a fresh reply (feedback_seq $feedback_seq), backgrounding ap-resume.sh"
      # Do NOT mark last_relayed_feedback_seq here. ap-resume.sh itself marks
      # it, and only once it has actually committed to injecting (acquired
      # the resume lock, confirmed the window alive, acquired a lane slot) --
      # never here, before we know any of that succeeded. Marking it
      # pre-emptively was a real bug in the old inbox-comment version of this
      # sweep: if ap-resume.sh then bailed on "no free slot right now" (a
      # normal, expected, retry-later condition), the reply would have been
      # silently treated as consumed forever. Every cycle until then just
      # re-backgrounds a cheap, harmless ap-resume.sh retry (its own
      # lock.resume.<n> makes a second concurrent one a fast no-op).
      nohup "$SCRIPT_DIR/ap-resume.sh" "$eng_id" "$feedback_text" "$feedback_seq" >>"$AP_HOME/logs/cycle.log" 2>&1 &
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
  local f eng_id registry_json run_dir window cur_status
  for f in "$AP_HOME"/parked/*.json; do
    [[ -e "$f" ]] || continue
    eng_id="$(basename "$f" .json)"
    lane_free "$AP_HOME/lock.resume.$eng_id" || continue
    registry_json="$(cat "$f" 2>/dev/null)"
    run_dir="$(json_field "$registry_json" ".run_dir")"
    window="$(json_field "$registry_json" ".window")"
    [[ -z "$run_dir" || -z "$window" ]] && continue
    cur_status=""
    [[ -f "$run_dir/status.json" ]] && cur_status="$(json_field "$(cat "$run_dir/status.json")" ".status")"
    if [[ "$cur_status" != "NEEDS_HUMAN" ]] || ! window_alive "$window"; then
      log "scan: parked ticket $eng_id looks manually resumed (status=${cur_status:-missing}) -- reconciling via ap-resume.sh"
      nohup "$SCRIPT_DIR/ap-resume.sh" "$eng_id" "" >>"$AP_HOME/logs/cycle.log" 2>&1 &
      disown
    fi
  done
}
sweep_manual_resumes

# --- Stage 1: decide (deterministic, always, always $0) ---------------------

decide_rc=0
decide_flags=(--claim --busy "$busy_lanes")
[[ "$suppress_new_intake" == "1" ]] && decide_flags+=(--suppress-new-intake)
poll_json="$("$SCRIPT_DIR/ap-decide.sh" "${decide_flags[@]}" 2>>"$AP_HOME/logs/cycle.log")" || decide_rc=$?
if [[ $decide_rc -ne 0 || -z "$poll_json" ]]; then
  log "ap-decide.sh invocation failed rc=$decide_rc"
  poll_json='{"action":"none"}'
fi

action="$(json_field "$poll_json" ".action")"
issue="$(json_field "$poll_json" ".issue")"
plan_path="$(json_field "$poll_json" ".planPath")"
feedback="$(json_field "$poll_json" ".feedback")"
# artifact_path/pr_url: the piv fork's decision keys (both kinds). planPath
# stays as-is, legacy-only -- resolve_plan_path reads plan_path directly, and
# the piv fork's artifact (a committed RCA for a bug, a committed
# implementation plan for a feature) is resolved kind-specifically by the
# decider and handed back as artifactPath instead.
artifact_path="$(json_field "$poll_json" ".artifactPath")"
pr_url="$(json_field "$poll_json" ".prUrl")"

append_ledger "$issue" "poll" "${action:-none}" 0 "deterministic" "none"

if [[ -z "$action" || "$action" == "none" ]]; then
  log "decide: no action"
  flock -u 9
  exit 0
fi

log "decide: action=$action issue=${issue:-} plan=${plan_path:-}"

# --- Lane lock: acquire the lane this action needs, THEN release lock.poll -
# so a plan can be decided (and start) while this cycle's build runs, or vice
# versa. act_lane is derived from the SAME probe the decider was told about,
# so this acquisition should always succeed; a failure here is a real
# anomaly, not ordinary contention, since lock.poll serializes deciders to
# exactly one at a time.
act_lane=""
act_lock_file=""
build_slot=""
ship_slot=""
plan_slot=""
review_slot=""
fe_port=""
be_port=""
case "$action" in
  # DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md -- no
  # decider tier emits `plan`/`replan` any more (see ap-decide.py's tier 5
  # and the shared draft-review tier). Kept deliberately inert, not deleted:
  # a hand-set legacy state via `ap sessions [s]` still reaches it, which is
  # the manual escape hatch while the piv pipeline is unproven. Removal
  # belongs to the legacy-cleanup plan. `design`/`redesign` (piv feature) and
  # `investigate`/`re-investigate` (piv bug) join this same arm -- same lane,
  # same "no port pair" reasoning, they just start no dev servers either.
  plan|replan|design|redesign|investigate|re-investigate)
    act_lane="plan"
    plan_slot="$free_plan_slot"
    # No port pair, unlike build/ship: a plan act starts no dev servers, so
    # concurrent plans need nothing but their own per-issue worktrees.
    [[ -n "$plan_slot" ]] && act_lock_file="$(plan_lock_file "$plan_slot")"
    ;;
  # DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md -- no
  # decider tier emits `implement` any more, same escape-hatch reasoning as
  # above; the implement->ship CHAIN below (see the `implement)` dispatch arm
  # further down) is unreachable along with it. `fix` (piv bug) and `build`
  # (piv feature) join this same arm for lock/slot/port acquisition only --
  # they never chain into ship or review the way `implement` chains into
  # ship; see the `fix|build)` dispatch arm further down for why.
  implement|fix|build)
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
      # goes through the standalone `ship)` arm below. `fix`/`build` never
      # chain at all (no second run_claude call), so for them this pair is
      # simply the slot's own port pair.
      fe_port=$((5173 + build_slot))
      be_port=$((8000 + build_slot))
    fi
    ;;
  # DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md -- no
  # decider tier can produce `ship-pending` any more once both piv forks are
  # live (neither writes it), so this standalone retry arm is unreachable via
  # normal decide flow; same escape-hatch reasoning as above.
  ship)
    # STANDALONE ship-only retry ONLY (decide emitted action=ship for a
    # ship-pending ticket -- see ap-decide.py's tier 4). This is the
    # non-obvious part: this arm is NOT how the implement->ship chain ships.
    # That chain's action is "implement", handled above; when its status
    # comes back DONE, the SAME process makes a second run_claude("ship", ...)
    # call further down using the build_slot/fe_port/be_port already
    # acquired for the implement half -- it never re-enters this case
    # statement, so it never touches the ship lane at all. Only a fresh cycle
    # whose decided action is literally "ship" lands here, and gets its own
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
  review)
    # piv review (shared by both kinds -- bug's `fix` and feature's `build`
    # both write piv-review-pending, and a LATER, fresh cycle claims it on
    # this lane; a bug's `fix` (or a feature's `build`) act never chains into
    # review the way legacy `implement` chains into `ship` -- see the
    # `fix|build)` dispatch arm's own comment for why. `review` is therefore
    # always a fresh cycle's decided action here, never reachable from the
    # build lane's own case arm above.
    act_lane="review"
    review_slot="$free_review_slot"
    if [[ -n "$review_slot" ]]; then
      act_lock_file="$AP_HOME/lock.review.$review_slot"
      # Non-overlapping with build (5174-5177/8001-8004 for AP_BUILD_SLOTS<=4),
      # ship (5181-5186/8011-8016 for AP_SHIP_SLOTS<=6), and the human's own
      # 5173/8000 -- 5187/8020 is the next free base. Like ship, `piv-review-pr`
      # serves no UI, so these ports exist only to isolate its local gates from
      # a concurrent build; the CORS allowlist is irrelevant for the same
      # reason. Provisioned for isolation-safety and consistency with every
      # other lane's own pattern, but likely unused in practice -- nothing in
      # piv-review-pr's Phase 3 (which runs through piv-validate) or
      # babysit-pr binds a server.
      fe_port=$((5187 + review_slot))
      be_port=$((8020 + review_slot))
    fi
    ;;
esac

if [[ -z "$act_lane" ]]; then
  # ap-decide.py claims a ticket (writes its new state) BEFORE returning the
  # decision here -- an unrecognized action left unhandled would leave the
  # ticket claimed but never dispatched, with no diagnostic and no recovery
  # path (the new state isn't in sweep_stale's tuple either). Fail closed and
  # loud instead: hand it back to a human rather than stranding it silently.
  # Mirrors `ap retry`'s own REQUEUE_STATE.get(phase)-miss pattern.
  log "decide: unrecognized action '$action' from the decider -- routing unknown, needs a human decision"
  if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
    queue_set "$issue" --state needs-input \
      --field "question=$(printf '%s' "unrecognized action '$action' from the decider -- routing unknown, needs a human decision" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      --event "unrecognized action '$action' -- routed to needs-input"
  fi
  flock -u 9
  exit 0
fi

if [[ -z "$act_lock_file" ]]; then
  log "act: no free $act_lane slot right after a free probe under lock.poll -- not acting this cycle; the decider's own stale-claim sweep will catch it"
  flock -u 9
  exit 0
fi

exec {lane_fd}>"$act_lock_file"
if ! flock -n "$lane_fd"; then
  log "act: lane lock '$act_lane' unexpectedly busy right after a free probe under lock.poll -- not acting this cycle; the decider's own stale-claim sweep will catch it"
  flock -u 9
  exit 0
fi

# PER-ISSUE lock, on top of the lane lock. The lane locks cap how many acts
# run at once; they do NOT stop the SAME issue entering two different slots.
# Claiming is ap-decide.py's job (the plan-review -> building state write),
# and this lock makes the claim enforced rather than advisory, so a
# duplicate-dispatch race (seen live on ENG-1308, 2026-08-13: two polls both
# emitted implement for the same issue a minute apart) cannot recur however
# the decider behaves. Held for the life of the act; released by process exit.
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
# sonnet subagents those skills dispatch. The piv fork extends the same
# reasoning: investigation (5-Whys synthesis, guard-behaviour reasoning, the
# adversarial gate) and design (strategic reasoning, the audit, the gate) are
# both the judgement-heavy half and get opus, exactly as legacy planning does;
# fix and build both execute an already-settled artifact (an RCA or a plan)
# and get sonnet, matching the sonnet subagents/implementer they dispatch;
# review drives delegated debate/triage scripts, where the heavy reasoning
# happens inside debate-review's own lanes, and gets sonnet. `plan`/`replan`/
# `implement`/`ship` (legacy) are dead but present for the manual escape
# hatch -- see the case statement above.
act_model() {
  case "$1" in
    plan|replan) echo "${AP_PLAN_MODEL:-opus}" ;;
    implement)   echo "${AP_IMPLEMENT_MODEL:-sonnet}" ;;
    ship)        echo "${AP_SHIP_MODEL:-sonnet}" ;;
    investigate|re-investigate) echo "${AP_INVESTIGATE_MODEL:-opus}" ;;
    design|redesign)            echo "${AP_DESIGN_MODEL:-opus}" ;;
    fix)                        echo "${AP_FIX_MODEL:-sonnet}" ;;
    build)                      echo "${AP_BUILD_MODEL:-sonnet}" ;;
    review)                     echo "${AP_REVIEW_MODEL:-sonnet}" ;;
    *)           echo "${AP_ACT_MODEL:-sonnet}" ;;
  esac
}

# window_name_for <phase> -> the tmux window name this act's persistent
# session runs in, e.g. act_plan_ENG-1234_plan, act_build_1_ENG-1234_implement,
# act_ship_2_ENG-1234_ship, act_review_1_ENG-1234_review. Reads
# act_lane/build_slot/ship_slot/review_slot/issue -- all already-set globals
# by the time any act runs (the lane-lock acquisition above sets them before
# dispatching). One window name scheme, so `ap status`/`ap runs` (see
# ap-runs.py) can parse lane/slot/phase/issue back out of it without a second
# source of truth. `design`/`redesign` (plan lane) and `fix`/`build` (build
# lane) need no new arm here -- they run on the existing plan/build lanes,
# whose arms already exist, and none of their phase names contain an
# underscore (ap-runs.py's `_ACT_WINDOW_RE` phase group is `[^_]+`), so e.g.
# `act_plan_ENG-1400_design` and `act_build_2_ENG-1400_build` both parse.
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
    plan)   printf 'act_plan_%s_%s' "${issue:-unknown}" "$phase" ;;
    build)  printf 'act_build_%s_%s_%s' "${build_slot:-0}" "${issue:-unknown}" "$phase" ;;
    ship)   printf 'act_ship_%s_%s_%s' "${ship_slot:-0}" "${issue:-unknown}" "$phase" ;;
    review) printf 'act_review_%s_%s_%s' "${review_slot:-0}" "${issue:-unknown}" "$phase" ;;
    *)      printf 'act_unknown_%s_%s' "${issue:-unknown}" "$phase" ;;
  esac
}

# park_registry_write <eng-id> <question> -- persists everything a later
# `ap-resume.sh` (or the manual-resume sweep) needs to re-acquire this act's
# slot and inject a reply into its still-live window. Called only from Stage
# 3's NEEDS_HUMAN branch, only in persistent mode. Keyed by ENG-id (the
# ticket's own key in $AP_HOME/queue/), not a GitHub issue number.
park_registry_write() {
  local eng_id="$1" question="$2"
  mkdir -p "$AP_HOME/parked"
  local now_ts
  now_ts="$(date -u +%FT%TZ)"
  python3 - "$AP_HOME/parked/$eng_id.json" "$eng_id" \
    "${final_phase:-}" "${act_lane:-}" "${LAST_ACT_WINDOW:-}" "${LAST_ACT_SESSION_ID:-}" \
    "${AP_RUN_DIR:-}" "${plan_path:-}" "${fe_port:-}" "${be_port:-}" "$now_ts" "$question" <<'PY'
import json, sys
(path, issue, phase, lane, window, session_id,
 run_dir, plan_path, fe_port, be_port, parked_at, question) = sys.argv[1:13]
# Preserve last_relayed_feedback_seq across a re-park if this ticket was
# already parked once before (a resume that led straight back to another
# NEEDS_HUMAN). Losing it here would make the OLD reply that triggered the
# first resume look "new" again on the next scan and get re-injected into a
# session now waiting on a completely different question -- the exact
# "circling back on the same issue" failure mode this registry exists to
# prevent, not cause.
last_relayed = 0
try:
    with open(path) as f:
        last_relayed = json.load(f).get("last_relayed_feedback_seq", 0)
except Exception:
    pass
d = {
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
    "last_relayed_feedback_seq": last_relayed,
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
import os
os.replace(tmp, path)
PY
}

# park_registry_remove <eng-id> -- called once an act resumes and reaches its
# next terminal (or re-parked -- see park_registry_write again) state.
# Removing this is what tells ap-decide.py's tier3 parked-exclusion that the
# ticket is claimable again.
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
  # DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md -- no
  # decider tier emits `plan`/`replan`/`implement`/`ship` any more (see
  # ap-decide.py's tier 5 and the shared draft-review tier). Kept
  # deliberately inert, not deleted: a hand-set legacy state via
  # `ap sessions [s]` still reaches these arms, which is the manual escape
  # hatch while the piv pipeline is unproven, and the pre-existing
  # test_cycle.sh cases assert on this exact prompt text -- proof the legacy
  # path was not modified. Removal belongs to the legacy-cleanup plan. Same
  # marker applies to the implement->ship chain inside the `implement)` arm
  # below, which is unreachable along with it.
  plan)
    run_claude "plan" "/implement-issue --phase plan $issue --headless"
    ;;
  replan)
    # Escape embedded single quotes ' -> '\'' so a feedback body containing
    # an apostrophe doesn't break out of the single-quoted --feedback value.
    feedback_escaped="${feedback//\'/\'\\\'\'}"
    run_claude "replan" "/implement-issue --phase plan $issue --headless --feedback '$feedback_escaped'"
    ;;
  design)
    run_claude "design" "/piv-plan-implementation $issue --headless"
    ;;
  redesign)
    # Same apostrophe-escaping as `replan)` above.
    feedback_escaped="${feedback//\'/\'\\\'\'}"
    run_claude "redesign" "/piv-plan-implementation $issue --headless --feedback '$feedback_escaped'"
    ;;
  investigate)
    run_claude "investigate" "/piv-investigate-issue $issue --headless"
    ;;
  re-investigate)
    # Same apostrophe-escaping as `replan)` above.
    feedback_escaped="${feedback//\'/\'\\\'\'}"
    run_claude "re-investigate" "/piv-investigate-issue $issue --headless --feedback '$feedback_escaped'"
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
      # even if the ship session dies before writing anything. Implement's
      # own last step (Phase B step 13) already pushed and opened the PR(s)
      # before writing this DONE, so `shipping` now covers only the CI wait
      # and merge prep, not the push/PR-open -- the owner can still tell
      # "still building" apart from "PR open, waiting on CI" instead of the
      # queue entry going silently quiet between building and ready-to-test.
      if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
        queue_set "$issue" --state shipping --event "implement done, PR open -> shipping"
        ap-notify.sh "shipping: ${issue:-$action}" "implement done, PR open, waiting on CI" || true
      fi
      run_claude "ship" "/ship-work $plan_path --headless --ports fe=$fe_port,be=$be_port"
    fi
    ;;
  fix|build)
    # piv bug's `fix` and piv feature's `build` share this arm: both execute
    # an already-approved artifact (an RCA or a plan) and, on DONE, both
    # write the SAME next state -- one shared block, not two arms kept in
    # sync by hand (exactly the drift generator ap-resume.sh's own DONE
    # branch warns about, since it is a second, independent reconciliation
    # implementation from this file's own).
    #
    # There is deliberately NO chained review dispatch here, unlike
    # implement's chained ship above: review is 20-60 minutes of mostly
    # waiting on bot rounds, and pinning a build slot for that whole time is
    # exactly what the separate review lane exists to avoid. The review act
    # is claimed later, by an ordinary fresh cycle, on its own lane/slot/
    # ports (see the `review)` arm below and the `review)` lane arm above).
    case "$action" in
      fix)
        run_claude "fix" "/piv-implement-issue $issue --headless --rca $artifact_path --ports fe=$fe_port,be=$be_port"
        ;;
      build)
        run_claude "build" "/piv-implement --headless --plan $artifact_path --issue $issue --ports fe=$fe_port,be=$be_port"
        ;;
    esac
    if [[ "$final_status" == "DONE" ]]; then
      # Wrapper-side, not skill-side, for the same reason building->shipping
      # is above: it must hold even if the fix/build session dies immediately
      # after its last tool call. Per each headless section, neither `fix`
      # nor `build` writes ticket state itself.
      if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
        # Belt-and-suspenders on pr_urls: each headless section also tells the
        # skill to record pr_urls on the ticket itself in its own last write
        # ("Record on the ticket in one write: --field pr_urls=..."), but a
        # session that completes every other step and skips just that one
        # extra CLI call still writes a DONE status.json with pr_urls filled
        # (confirmed live on ENG-1594, 2026-09-05: status.json had the PR,
        # the ticket's own pr_urls stayed [], and review parked with "Could
        # not resolve the PR"). status_file is still the completed act's own
        # file here -- read straight from it rather than trust the skill's
        # side channel landed.
        done_pr_urls="$(json_field "$(cat "$status_file" 2>/dev/null)" ".pr_urls")"
        pr_urls_args=()
        if [[ -n "$done_pr_urls" && "$done_pr_urls" != "null" ]]; then
          pr_urls_args=(--field "pr_urls=$done_pr_urls")
        fi
        queue_set "$issue" --state piv-review-pending "${pr_urls_args[@]}" --event "$final_phase done, PR open -> review pending"
        ap-notify.sh "review pending: ${issue:-$action}" "$final_phase committed, PR open, agentic review queued" || true
      fi
    fi
    ;;
  # DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md -- see
  # the marker above the `plan)` arm.
  ship)
    # A ship-only retry: implement already committed, pushed, and opened the
    # PR(s), ship still owed -- either a prior ship phase failed externally
    # and got re-queued to `ship-pending`, or the human manually retried via
    # `ap retry`. ap-decide.py already wrote shipping (from ship-pending)
    # before emitting this action, so there's no wrapper-side state write to
    # do here (unlike the implement->ship chain above, which writes shipping
    # itself).
    run_claude "ship" "/ship-work $plan_path --headless --ports fe=$fe_port,be=$be_port"
    ;;
  review)
    # Shared by both piv kinds -- a bug's `fix` and a feature's `build` both
    # land here via a fresh cycle claiming `piv-review-pending` (never
    # chained, see the `fix|build)` arm above). $pr_url comes from the
    # decider's resolved PR URL (ap-decide.py tier 4), not a worktree/branch
    # path.
    run_claude "review" "/piv-review-pr $pr_url --headless --issue $issue --ports fe=$fe_port,be=$be_port"
    ;;
  *)
    log "decide: unknown action '$action'"
    popd >/dev/null 2>&1 || true
    exit 0
    ;;
esac

popd >/dev/null 2>&1 || true

log "act: phase=$final_phase status=$final_status issue=${issue:-}"

# --- Stage 3: reconcile (wrapper is authoritative for terminal states) ----

status_json=""
[[ -f "$status_file" ]] && status_json="$(cat "$status_file")"

# The outer FAILED/NEEDS_HUMAN/DONE dispatch on $final_status is already
# phase-agnostic -- only the requeue map inside FAILED and the ready/RCA
# ping inside DONE branch on $final_phase (both extended above for the piv
# fork). Confirmed by reading, per both piv plans' instruction not to add a
# redundant top-level branch here.
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
    # and every one of them dead-ended at `failed` -- a state nothing ever
    # wakes on -- stalling the whole queue until a human relabelled seven
    # tickets by hand. A failure matching this signature is re-queued instead
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
      #
      # This map MUST stay identical to ap-runs.py's REQUEUE_STATE (same
      # table, two files, per this repo's duplicate-small-helpers
      # convention) -- including any phase either fork adds later. Legacy
      # rows (plan/replan/implement/ship) are dead but kept, per the case
      # statement above's inert-marker comments.
      requeue_state=""
      requeue_unrecognized=false
      case "$final_phase" in
        plan|replan) requeue_state="queued" ;;
        implement)   requeue_state="plan-review" ;;
        ship)        requeue_state="ship-pending" ;;
        investigate|re-investigate) requeue_state="queued" ;;
        fix)                        requeue_state="piv-draft-review" ;;
        design|redesign)            requeue_state="queued" ;;
        build)                      requeue_state="piv-draft-review" ;;
        review)                     requeue_state="piv-review-pending" ;;
        *)                          requeue_unrecognized=true ;;
      esac
      if [[ -n "${issue:-}" && "$issue" != "null" && -n "$requeue_state" ]]; then
        queue_set "$issue" --state "$requeue_state" \
          --event "external failure, re-queued (matched: $external_failure_line)"
      elif [[ "$requeue_unrecognized" == true ]]; then
        # An unmatched $final_phase must never silently skip the queue
        # write -- fail closed and loud instead, mirroring `ap retry`'s own
        # REQUEUE_STATE.get(phase)-miss pattern, rather than leaving the
        # ticket with no state change and no diagnostic beyond whatever the
        # FAILED path above already recorded.
        log "reconcile: unrecognized phase '$final_phase' in the external-failure requeue map for issue ${issue:-unknown} -- routing unknown, needs a human decision"
        if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
          queue_set "$issue" --state needs-input \
            --field "question=$(printf '%s' "unrecognized phase '$final_phase' in the external-failure requeue map -- routing unknown, needs a human decision" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
            --event "external failure, unrecognized phase '$final_phase' -- routed to needs-input"
        fi
      fi
      ap-notify.sh "requeued after external failure: ${issue:-$action}" "$failure_body" || true
    else
      if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
        # A bare "run failed" event told you nothing beyond the STATUS
        # column already showing FAILED -- this is exactly what "I should
        # be able to see the reason" was missing. status.json's own
        # `detail` (falling back to `question`) is preferred when present:
        # it's the session's own structured account of what went wrong,
        # written deliberately, not scraped -- the transcript/stderr grep
        # below can otherwise pick up a stray fragment of the model's own
        # conversational narration (confirmed live, ENG-1549: "That works.
        # Let me find AP_HOME.") or miss a fully-populated detail entirely
        # (confirmed live, ENG-17990: detail had the real reason -- a
        # nonexistent ticket ID plus Bash denied wholesale -- while this
        # grep produced only "no stderr/transcript captured").
        fail_reason="$(json_field "$status_json" ".detail")"
        [[ -z "$fail_reason" ]] && fail_reason="$(json_field "$status_json" ".question")"
        if [[ -z "$fail_reason" ]]; then
          fail_reason="$(printf '%s' "${transcript_tail:-$stderr_tail}" | grep -m1 -v '^[[:space:]]*$' | tr -d '\n' | cut -c1-200)"
        fi
        fail_reason="$(printf '%s' "$fail_reason" | tr -d '\n' | cut -c1-200)"
        [[ -z "$fail_reason" ]] && fail_reason="no stderr/transcript captured"
        queue_set "$issue" --state failed --event "run failed: $fail_reason"
      fi
      ap-notify.sh "autopilot FAILED: ${issue:-$action}" "$failure_body" || true
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
    # deliberately -- an external failure is exempt from the `failed` state
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

  # NEEDS_HUMAN below is already phase-agnostic -- it reads ${final_phase:-}
  # generically (park_registry_write records it as-is) with no phase branch,
  # so it needs no piv-specific change. Confirmed by reading, per both piv
  # plans' own instruction not to add a redundant branch here.
  NEEDS_HUMAN)
    question="$(json_field "$status_json" ".question")"
    if [[ -n "${issue:-}" && "$issue" != "null" ]]; then
      queue_set "$issue" --state needs-input \
        --field "question=$(printf '%s' "$question" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        --field "phase_at_question=\"${final_phase:-plan}\"" \
        --event "needs input (phase ${final_phase:-unknown})"
    fi
    ap-notify.sh "autopilot needs input: ${issue:-$action}" "${question:-see ap sessions}" || true
    echo 0 >"$AP_HOME/fail_count"
    # Persistent mode: the window is still alive (run_claude() deliberately
    # didn't kill it for NEEDS_HUMAN) -- park it. Oneshot mode: nothing to
    # park, the process already exited, exactly as before this feature.
    if [[ "$AP_ACT_LAUNCH_MODE" != "oneshot" && -n "$LAST_ACT_WINDOW" \
       && -n "${issue:-}" && "$issue" != "null" ]]; then
      park_registry_write "$issue" "${question:-}"
    fi
    ;;

  DONE)
    echo 0 >"$AP_HOME/fail_count"
    if [[ "$final_phase" == "ship" || "$final_phase" == "review" ]]; then
      # `review` (piv, both kinds) lands here alongside legacy `ship` --
      # both are the "PR(s) ready to test" terminal DONE.
      pr_urls="$(json_join "$status_json" ".pr_urls")"
      ap-notify.sh "ready to test: ${issue:-$action}" "${pr_urls:-see ap sessions}" || true
    elif [[ "$final_phase" == "plan" || "$final_phase" == "replan" \
         || "$final_phase" == "design" || "$final_phase" == "redesign" \
         || "$final_phase" == "investigate" || "$final_phase" == "re-investigate" ]]; then
      # The approval gate is the whole point: the owner must know an artifact
      # (a plan, or an RCA) is waiting for review the moment it lands --
      # UNLESS auto-approve already applies to this ticket (global flag, or
      # its own per-ticket auto_approve field, set via `ap queue --auto`/
      # `ap approve --auto`), in which case it's about to build/fix without
      # an `ap approve`, and the ping should say so instead of asking for
      # one -- the owner must be able to tell the two apart at a glance.
      auto_will_build=false
      if [[ "$AP_AUTO_APPROVE" == "1" ]]; then
        auto_will_build=true
      elif [[ -n "${issue:-}" && "$issue" != "null" ]]; then
        ticket_auto="$(json_field "$(queue_get "$issue")" ".auto_approve")"
        [[ "$ticket_auto" == "True" || "$ticket_auto" == "true" ]] && auto_will_build=true
      fi
      # investigate/re-investigate produce an RCA, not a plan -- swap the
      # wording so the ping names the right artifact and the right next
      # verb (`fix`, not `build`). design/redesign still produce a plan, so
      # they share the legacy plan/replan wording verbatim.
      if [[ "$final_phase" == "investigate" || "$final_phase" == "re-investigate" ]]; then
        artifact_label="RCA"
        approve_verb="fix"
        building_word="piv-implementing"
      else
        artifact_label="plan"
        approve_verb="build"
        building_word="building"
      fi
      if [[ "$auto_will_build" == true ]]; then
        ap-notify.sh "$artifact_label auto-approved, $building_word: ${issue:-$action}" "no 'ap approve' needed -- auto-approve is on for this ticket; \`ap reply\` to override with feedback before it starts" || true
      else
        ap-notify.sh "$artifact_label ready for review: ${issue:-$action}" "\`ap approve $issue\` to $approve_verb, \`ap reply $issue \"...\"\` = feedback" || true
      fi
    fi
    ;;
esac

log "reconcile: done phase=$final_phase status=$final_status"
exit 0
