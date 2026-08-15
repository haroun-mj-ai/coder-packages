#!/usr/bin/env bash
# ap-resume.sh <eng-id> [<reply-text>] [<feedback-seq>]
#
# Resumes a parked act (see ap-cycle.sh's persistent-mode NEEDS_HUMAN
# handling and park_registry_write): re-acquires its original lane slot,
# optionally injects <reply-text> into its still-live tmux window (empty =
# just reconcile whatever state it's already in -- the manual-tmux-attach
# case, invoked by ap-cycle.sh's sweep_manual_resumes), then polls for the
# next terminal/park state and reconciles it, cleaning up the parked
# registry and both locks either way.
#
# Two callers, same script, same locking -- never two independent
# mechanisms both deciding whether a ticket is parked or dead:
#   - ap-cycle.sh's scan_parked_replies (the ticket's feedback_seq advanced,
#     via `ap reply`) passes the reply text and the new feedback_seq.
#   - ap-cycle.sh's sweep_manual_resumes (the parked act's status/window
#     already changed with no resume in flight) passes an empty string.
#
# Never drops a reply silently: if the window is gone, or no slot is free,
# this exits WITHOUT marking anything consumed and removes the (now-stale)
# registry entry, so the ordinary fallback path -- ap-decide.py's tier3,
# once its parked-exclusion no longer applies -- picks the same reply up as
# an ordinary fresh answer, exactly as if this whole feature didn't exist.
#
# Known simplification, not silently: this reconcile does NOT replicate
# ap-cycle.sh's Stage 3 external-failure-signature requeue logic (a
# usage-limit/rate-limit/provider-outage FAILED gets requeued to its
# pre-act state there instead of dead-ending at `failed`). A resumed act
# that FAILs for an external cause here dead-ends at `failed` like any
# other failure; `ap retry` is the fallback, same as this pipeline's
# behavior before that logic existed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

SETTINGS_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/settings/autopilot.json"
QUEUE_PY="$SCRIPT_DIR/ap_queue.py"

eng_id="${1:?usage: ap-resume.sh <eng-id> [<reply-text>] [<feedback-seq>]}"
reply_text="${2:-}"
feedback_seq="${3:-}"

mkdir -p "$AP_HOME/logs"

log() {
  echo "$(date -u +%FT%TZ) resume[$eng_id]: $*" >>"$AP_HOME/logs/cycle.log"
}

queue_set() {
  python3 "$QUEUE_PY" --ap-home "$AP_HOME" set "$eng_id" "$@" >>"$AP_HOME/logs/cycle.log" 2>&1 || true
}

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

window_alive() {
  tmux list-windows -t "$AP_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$1"
}

# Same pid -> ~/.claude/sessions/<pid>.json join ap-cycle.sh's run_claude()
# uses -- resolves the live claude session id from a window name.
session_id_for_window() {
  local w="$1" pane_pid
  pane_pid="$(tmux list-panes -t "$AP_TMUX_SESSION:$w" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [[ -z "$pane_pid" ]] && return 0
  json_field "$(cat "${AP_SESSIONS_DIR:-$HOME/.claude/sessions}/$pane_pid.json" 2>/dev/null)" ".sessionId"
}

# ledger_path/append_ledger -- same shape and O_APPEND-is-safe reasoning as
# ap-cycle.sh's copy (see there for the full comment); duplicated rather
# than sourced for the same reason window_alive/park_registry_write already
# are here. Without this, every act that gets parked-and-resumed (a reply or
# manual tmux attach) would vanish from `ap runs`/`ap status` entirely once
# its window is torn down -- a blind spot on exactly the acts this feature
# exists to support, not just an inaccurate cost figure.
ledger_path() {
  echo "$AP_HOME/runs/$(TZ="$AP_TZ" date +%F).jsonl"
}

append_ledger() {
  local issue="$1" phase="$2" status="$3" cost="$4" session_id="$5" model="${6:-}"
  local ts ledger_file
  ts="$(date -u +%FT%TZ)"
  ledger_file="$(ledger_path)"
  mkdir -p "$(dirname "$ledger_file")"
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
}

# cost/model for a still-live session's transcript-so-far, same estimate
# ap-cycle.sh's run_claude() now uses for a persistent-mode act -- see
# ap-runs.py's `cost`/`model` subcommands.
cost_for_session() {
  local sid="$1" v
  [[ -z "$sid" ]] && { echo "0"; return; }
  v="$(python3 "$SCRIPT_DIR/ap-runs.py" cost "$sid" 2>>"$AP_HOME/logs/cycle.log")"
  [[ "$v" =~ ^[0-9.]+$ ]] && echo "$v" || echo "0"
}

model_for_session() {
  local sid="$1"
  [[ -z "$sid" ]] && { echo ""; return; }
  python3 "$SCRIPT_DIR/ap-runs.py" model "$sid" 2>>"$AP_HOME/logs/cycle.log"
}

# park_registry_write <eng-id> <phase> <lane> <window> <session_id> <run_dir> <plan_path> <fe_port> <be_port> <question>
# Same shape ap-cycle.sh's own park_registry_write writes -- kept as a
# single definition here (not duplicated per call site) since this script
# writes it from two places: re-parking after a resumed NEEDS_HUMAN, and
# parking the chained ship dispatch below.
park_registry_write() {
  local p_eng="$1" p_phase="$2" p_lane="$3" p_window="$4" p_session_id="$5" \
        p_run_dir="$6" p_plan_path="$7" p_fe="$8" p_be="$9" p_question="${10}"
  mkdir -p "$AP_HOME/parked"
  python3 - "$AP_HOME/parked/$p_eng.json" "$p_eng" "$p_phase" "$p_lane" \
    "$p_window" "$p_session_id" "$p_run_dir" "$p_plan_path" "$p_fe" "$p_be" "$(date -u +%FT%TZ)" "$p_question" <<'PY'
import json, os, sys
(path, issue, phase, lane, window, session_id,
 run_dir, plan_path, fe_port, be_port, parked_at, question) = sys.argv[1:13]
# Preserve last_relayed_feedback_seq across the overwrite -- same reasoning
# as ap-cycle.sh's copy of this function: losing it makes an already-handled
# reply look new again and re-inject into a session now parked on a
# different question. Applies both to a re-park after a resumed
# NEEDS_HUMAN, and to the chained-ship park (a new window, same ticket).
last_relayed = 0
try:
    with open(path) as f:
        last_relayed = json.load(f).get("last_relayed_feedback_seq", 0)
except Exception:
    pass
d = {"issue": issue or None, "phase": phase or None, "lane": lane or None,
     "window": window or None, "session_id": session_id or None,
     "run_dir": run_dir or None, "plan_path": plan_path or None,
     "ports": {"fe": fe_port, "be": be_port} if fe_port else None,
     "parked_at": parked_at, "question": question or None,
     "last_relayed_feedback_seq": last_relayed}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)
PY
}

# launch_window_and_wait <window> <prompt> <model> <ledger-issue> <ledger-phase> --
# fresh dispatch (not a resume): clears status.json first exactly like
# ap-cycle.sh's run_claude() does, launches the window, and blocks until a
# NEW status.json exists or the window disappears. Sets
# status_json/final_status/launch_session_id globals, and appends this
# dispatch's own ledger row (mirroring run_claude()'s one-row-per-invocation
# behavior in ap-cycle.sh) -- this is the chained-ship dispatch's only
# ledger entry, so skipping it would leave that phase invisible to `ap
# runs`/`ap status` even though a real session ran and spent real tokens.
launch_window_and_wait() {
  local window="$1" prompt="$2" model="$3" ledger_issue="$4" ledger_phase="$5"
  rm -f "$status_file"
  tmux new-window -t "$AP_TMUX_SESSION" -n "$window" -d -- \
    bash -c 'exec env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$1" claude --settings "$2" --model "$3" "$4"' \
    _ "${AP_BG_WAIT_CEILING_MS:-3600000}" "$SETTINGS_PATH" "$model" "$prompt"
  while true; do
    [[ -f "$status_file" ]] && break
    window_alive "$window" || { log "window $window disappeared before writing status.json"; break; }
    sleep 5
  done
  status_json=""
  [[ -f "$status_file" ]] && status_json="$(cat "$status_file")"
  final_status="$(json_field "$status_json" ".status")"
  [[ -z "$final_status" ]] && final_status="FAILED"
  launch_session_id="$(session_id_for_window "$window")"
  append_ledger "$ledger_issue" "$ledger_phase" "$final_status" \
    "$(cost_for_session "$launch_session_id")" "$launch_session_id" "$model"
}

# Same non-destructive probe-then-flock idiom ap-cycle.sh's lane_free() uses.
lane_free() {
  local lock_file="$1" fd
  exec {fd}>"$lock_file" || return 1
  if flock -n "$fd"; then
    flock -u "$fd"
    exec {fd}>&-
    return 0
  fi
  exec {fd}>&-
  return 1
}

registry_file="$AP_HOME/parked/$eng_id.json"

# Non-blocking: a resume already in flight for this exact ticket owns it --
# guards against a near-simultaneous second `ap reply`, or a reply racing a
# manual tmux attach.
exec {resume_fd}>"$AP_HOME/lock.resume.$eng_id"
if ! flock -n "$resume_fd"; then
  log "already has a resume in flight -- not double-injecting"
  exit 0
fi

if [[ ! -f "$registry_file" ]]; then
  log "no parked-registry entry -- nothing to resume (already reconciled, or never parked)"
  exit 0
fi

registry_json="$(cat "$registry_file" 2>/dev/null)"
window="$(json_field "$registry_json" ".window")"
lane="$(json_field "$registry_json" ".lane")"
phase="$(json_field "$registry_json" ".phase")"
run_dir="$(json_field "$registry_json" ".run_dir")"
plan_path="$(json_field "$registry_json" ".plan_path")"
fe_port="$(json_field "$registry_json" ".ports.fe")"
be_port="$(json_field "$registry_json" ".ports.be")"
status_file="$run_dir/status.json"

if [[ -z "$window" ]] || ! window_alive "$window"; then
  log "window ($window) is gone -- falling back to the ordinary re-derive-from-plan-file path, reply NOT consumed"
  rm -f "$registry_file"
  if [[ -n "$reply_text" ]]; then
    ap-notify.sh "live session gone for $eng_id" \
      "the parked window disappeared; your reply will be picked up by a fresh run instead of the live one" || true
  fi
  exit 0
fi

# Same session throughout every park/resume cycle -- resolved once here (not
# trusted from the registry, which historically hardcoded this to null) and
# reused for both re-parking (so session_id survives a re-park) and this
# resumed act's own ledger row below.
session_id="$(session_id_for_window "$window")"
model="$(model_for_session "$session_id")"

# Re-acquire the act's original lane slot, same pattern ap-cycle.sh's own
# initial dispatch uses (probe lowest-first). Never drop the reply if none
# is free -- leave the registry in place so this same trigger re-fires.
acquired_lock_file=""
case "$lane" in
  plan)
    lane_free "$AP_HOME/lock.plan" && acquired_lock_file="$AP_HOME/lock.plan"
    ;;
  build)
    for ((n = 1; n <= AP_BUILD_SLOTS; n++)); do
      if lane_free "$AP_HOME/lock.build.$n"; then
        acquired_lock_file="$AP_HOME/lock.build.$n"
        break
      fi
    done
    ;;
  ship)
    for ((n = 1; n <= AP_SHIP_SLOTS; n++)); do
      if lane_free "$AP_HOME/lock.ship.$n"; then
        acquired_lock_file="$AP_HOME/lock.ship.$n"
        break
      fi
    done
    ;;
esac

if [[ -z "$acquired_lock_file" ]]; then
  log "lane ($lane) has no free slot right now -- not consuming, will retry next time this trigger fires"
  exit 0
fi

exec {lane_fd}>"$acquired_lock_file"
if ! flock -n "$lane_fd"; then
  log "lane lock $acquired_lock_file unexpectedly busy right after a free probe -- not consuming, retry later"
  exit 0
fi

exec {issue_fd}>"$AP_HOME/lock.issue.$eng_id"
if ! flock -n "$issue_fd"; then
  log "ticket $eng_id is already locked by another act -- not consuming, retry later"
  exit 0
fi

old_status_content="$(cat "$status_file" 2>/dev/null)"

if [[ -n "$reply_text" ]]; then
  # Two SEPARATE send-keys calls, not one with a trailing `Enter` argument --
  # verified live: Claude Code's TUI does not reliably submit when the text
  # and Enter arrive in the same send-keys invocation (looks like paste-mode
  # detection wants Enter as its own distinctly-timed keystroke). Text first,
  # a beat to let the TUI register it, then Enter on its own.
  tmux send-keys -t "$AP_TMUX_SESSION:$window" -- "$reply_text"
  sleep 1
  tmux send-keys -t "$AP_TMUX_SESSION:$window" Enter
  log "injected reply into $window"
  # Mark the triggering reply consumed HERE, now that injection has actually
  # happened -- not in ap-cycle.sh's scan_parked_replies before this script
  # even ran. Marking it there was a real bug: every bail-out above (no free
  # slot, lock busy, window gone) is meant to be retried on a later cycle,
  # exactly like every other busy-lane skip in this pipeline, but
  # pre-marking would have made "no free slot" silently drop the reply
  # forever instead of retrying -- the same class of caught-live bug this
  # whole feature exists to avoid, not introduce.
  if [[ -n "$feedback_seq" ]]; then
    python3 - "$registry_file" "$feedback_seq" <<'PY'
import json, os, sys
path, seq = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
try:
    d["last_relayed_feedback_seq"] = int(seq)
except ValueError:
    pass
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)
PY
  fi
else
  log "no reply text (manual-resume reconcile) -- polling for whatever it's already moved to"
fi

while true; do
  if [[ -f "$status_file" ]]; then
    new_status_content="$(cat "$status_file" 2>/dev/null)"
    [[ "$new_status_content" != "$old_status_content" ]] && break
  fi
  if ! window_alive "$window"; then
    log "window $window disappeared mid-resume -- treating as crash"
    break
  fi
  sleep 5
done

status_json=""
[[ -f "$status_file" ]] && status_json="$(cat "$status_file")"
final_status="$(json_field "$status_json" ".status")"
[[ -z "$final_status" ]] && final_status="FAILED"

# One ledger row for THIS resumed act's own outcome, regardless of which of
# DONE/NEEDS_HUMAN/FAILED it landed on -- mirrors ap-cycle.sh's run_claude(),
# which logs once per invocation no matter the status. Without this, a
# parked-and-resumed act (a reply or manual tmux attach) is invisible to
# `ap runs`/`ap status` entirely, not just missing its cost.
append_ledger "$eng_id" "${phase:-unknown}" "$final_status" \
  "$(cost_for_session "$session_id")" "$session_id" "$model"

# Debounce before tearing down, same reasoning as ap-cycle.sh's run_claude().
teardown_window() {
  local w="$1"
  sleep 3
  tmux kill-window -t "$AP_TMUX_SESSION:$w" 2>/dev/null || true
}

case "$final_status" in
  DONE)
    rm -f "$registry_file"
    if [[ "$phase" == "ship" ]]; then
      teardown_window "$window"
      pr_urls="$(json_join "$status_json" ".pr_urls")"
      ap-notify.sh "ready to test: $eng_id" "${pr_urls:-see ap sessions}" || true
    elif [[ "$phase" == "plan" || "$phase" == "replan" ]]; then
      teardown_window "$window"
      ap-notify.sh "plan ready for review: $eng_id" "\`ap approve $eng_id\` to build, \`ap reply $eng_id \"...\"\` = feedback" || true
    elif [[ "$phase" == "implement" ]]; then
      # Same chain ap-cycle.sh's own implement arm runs: swap building ->
      # shipping, ping, then dispatch the ship phase in a NEW window on the
      # SAME slot -- this act's own window is done, ship gets its own.
      queue_set --state shipping --event "implement done, PR open -> shipping"
      ap-notify.sh "shipping: $eng_id" "implement done, PR open, waiting on CI" || true
      teardown_window "$window"
      ship_window="act_build_${acquired_lock_file##*.}_${eng_id}_ship"
      if window_alive "$ship_window"; then
        log "ship window $ship_window already exists -- refusing to dispatch a duplicate chained ship"
      else
        launch_window_and_wait "$ship_window" \
          "/ship-work $plan_path --headless --ports fe=$fe_port,be=$be_port --run-dir $run_dir" \
          "${AP_SHIP_MODEL:-sonnet}" "$eng_id" ship
        log "chained ship in $ship_window finished with status=$final_status"
        case "$final_status" in
          DONE)
            teardown_window "$ship_window"
            pr_urls="$(json_join "$status_json" ".pr_urls")"
            ap-notify.sh "ready to test: $eng_id" "${pr_urls:-see ap sessions}" || true
            ;;
          NEEDS_HUMAN)
            question="$(json_field "$status_json" ".question")"
            queue_set --state needs-input \
              --field "question=$(printf '%s' "$question" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
              --field 'phase_at_question="ship"' \
              --event "needs input (phase ship)"
            ap-notify.sh "autopilot needs input: $eng_id" "${question:-see ap sessions}" || true
            park_registry_write "$eng_id" ship build "$ship_window" "$launch_session_id" "$run_dir" "$plan_path" "$fe_port" "$be_port" "$question"
            exit 0
            ;;
          *)
            queue_set --state failed --event "ship phase failed after resume"
            ap-notify.sh "autopilot FAILED: $eng_id" "ship phase failed after resume; see $ship_window's transcript" || true
            teardown_window "$ship_window"
            ;;
        esac
      fi
    fi
    ;;

  NEEDS_HUMAN)
    question="$(json_field "$status_json" ".question")"
    queue_set --state needs-input \
      --field "question=$(printf '%s' "$question" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      --field "phase_at_question=\"${phase:-plan}\"" \
      --event "needs input (phase ${phase:-unknown})"
    ap-notify.sh "autopilot needs input: $eng_id" "${question:-see ap sessions}" || true
    # Re-park under the SAME window (still alive) -- everything is unchanged
    # from the original entry except parked_at/question.
    park_registry_write "$eng_id" "$phase" "$lane" "$window" "$session_id" "$run_dir" "$plan_path" "$fe_port" "$be_port" "$question"
    ;;

  *)
    # FAILED (including "window disappeared mid-resume", which defaults
    # here since final_status was seeded FAILED when status_file is
    # missing). See this file's header for what's deliberately NOT
    # replicated (external-failure requeue classification).
    rm -f "$registry_file"
    teardown_window "$window"
    stdout_tail="transcript output isn't captured for a resumed persistent act; see $window's transcript via ap tail if it still exists"
    ap-notify.sh "autopilot FAILED: $eng_id" "$stdout_tail" || true
    queue_set --state failed --event "run failed after resume"
    ;;
esac

log "reconciled: final_status=$final_status phase=${phase:-unknown}"
exit 0
