#!/usr/bin/env bash
# ap-resume.sh <inbox-issue> [<reply-text>]
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
# mechanisms both deciding whether an issue is parked or dead:
#   - ap-cycle.sh's scan_parked_replies (a fresh GitHub inbox comment on a
#     parked issue) passes the comment text.
#   - ap-cycle.sh's sweep_manual_resumes (the parked act's status/window
#     already changed with no resume in flight) passes an empty string.
#
# Never drops a reply silently: if the window is gone, or no slot is free,
# this exits WITHOUT marking anything consumed and removes the (now-stale)
# registry entry, so the ordinary fallback path -- the next cron tick's
# scan_inbox_comments, once is_parked() no longer excludes this issue --
# picks the same comment up as a ordinary fresh reply, exactly as if this
# whole feature didn't exist.
#
# Known simplification, not silently: this reconcile does NOT replicate
# ap-cycle.sh's Stage 3 external-failure-signature requeue logic (a
# usage-limit/rate-limit/provider-outage FAILED gets requeued to its
# pre-act label there instead of dead-ending at `failed`). A resumed act
# that FAILs for an external cause here dead-ends at `failed` like any
# other failure; a human relabelling it is the fallback, same as this
# pipeline's behavior before that logic existed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

SETTINGS_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/settings/autopilot.json"

inbox_issue="${1:?usage: ap-resume.sh <inbox-issue> [<reply-text>] [<comment-id>]}"
reply_text="${2:-}"
comment_id="${3:-}"

mkdir -p "$AP_HOME/logs"

log() {
  echo "$(date -u +%FT%TZ) resume[$inbox_issue]: $*" >>"$AP_HOME/logs/cycle.log"
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

# park_registry_write <inbox-issue> <issue> <phase> <lane> <window> <run_dir> <plan_path> <fe_port> <be_port> <question>
# Same shape ap-cycle.sh's own park_registry_write writes -- kept as a
# single definition here (not duplicated per call site) since this script
# writes it from three places: re-parking after a resumed NEEDS_HUMAN, and
# parking the chained ship dispatch below.
park_registry_write() {
  local p_inbox="$1" p_issue="$2" p_phase="$3" p_lane="$4" p_window="$5" \
        p_run_dir="$6" p_plan_path="$7" p_fe="$8" p_be="$9" p_question="${10}"
  mkdir -p "$AP_HOME/parked"
  python3 - "$AP_HOME/parked/$p_inbox.json" "$p_inbox" "$p_issue" "$p_phase" "$p_lane" \
    "$p_window" "$p_run_dir" "$p_plan_path" "$p_fe" "$p_be" "$(date -u +%FT%TZ)" "$p_question" <<'PY'
import json, os, sys
(path, inbox_issue, issue, phase, lane, window,
 run_dir, plan_path, fe_port, be_port, parked_at, question) = sys.argv[1:13]
# Preserve last_relayed_comment_id across the overwrite -- same reasoning as
# ap-cycle.sh's copy of this function: losing it makes an already-handled
# comment look new again and re-inject into a session now parked on a
# different question. Applies both to a re-park after a resumed
# NEEDS_HUMAN, and to the chained-ship park (a new window, same inbox
# issue's comment thread).
last_relayed = None
try:
    with open(path) as f:
        last_relayed = json.load(f).get("last_relayed_comment_id")
except Exception:
    pass
d = {"inbox_issue": int(inbox_issue) if inbox_issue.isdigit() else inbox_issue,
     "issue": issue or None, "phase": phase or None, "lane": lane or None,
     "window": window or None, "session_id": None,
     "run_dir": run_dir or None, "plan_path": plan_path or None,
     "ports": {"fe": fe_port, "be": be_port} if fe_port else None,
     "parked_at": parked_at, "question": question or None,
     "last_relayed_comment_id": last_relayed}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)
PY
}

# launch_window_and_wait <window> <prompt> <model> -- fresh dispatch (not a
# resume): clears status.json first exactly like ap-cycle.sh's run_claude()
# does, launches the window, and blocks until a NEW status.json exists or
# the window disappears. Sets status_json/final_status globals.
launch_window_and_wait() {
  local window="$1" prompt="$2" model="$3"
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

registry_file="$AP_HOME/parked/$inbox_issue.json"
inbox_url="https://github.com/$AP_INBOX_REPO/issues/$inbox_issue"

# Non-blocking: a resume already in flight for this exact issue owns it --
# guards against a near-simultaneous second GitHub comment, or a comment
# racing a manual tmux attach.
exec {resume_fd}>"$AP_HOME/lock.resume.$inbox_issue"
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
issue="$(json_field "$registry_json" ".issue")"
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
    ap-notify.sh "live session gone for ${issue:-ENG-$inbox_issue}" \
      "the parked window disappeared; your reply will be picked up by a fresh run instead of the live one" \
      "$inbox_url" || true
  fi
  exit 0
fi

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

if [[ -n "$issue" ]]; then
  exec {issue_fd}>"$AP_HOME/lock.issue.$issue"
  if ! flock -n "$issue_fd"; then
    log "issue $issue is already locked by another act -- not consuming, retry later"
    exit 0
  fi
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
  # Mark the triggering comment consumed HERE, now that injection has
  # actually happened -- not in ap-cycle.sh's scan_parked_replies before
  # this script even ran. Marking it there was a real bug: every bail-out
  # above (no free slot, lock busy, window gone) is meant to be retried on
  # a later cycle, exactly like every other busy-lane skip in this
  # pipeline, but pre-marking would have made "no free slot" silently drop
  # the reply forever instead of retrying -- the same class of caught-live
  # bug this whole feature exists to avoid, not introduce.
  if [[ -n "$comment_id" ]]; then
    python3 - "$registry_file" "$comment_id" <<'PY'
import json, os, sys
path, cid = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
try:
    d["last_relayed_comment_id"] = int(cid)
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
      ap-notify.sh "ready to test: ${issue:-ENG-$inbox_issue}" "${pr_urls:-see inbox}" "$inbox_url" || true
    elif [[ "$phase" == "plan" || "$phase" == "replan" ]]; then
      teardown_window "$window"
      ap-notify.sh "plan ready for review: ${issue:-ENG-$inbox_issue}" "comment 'go' to build, anything else = feedback" "$inbox_url" || true
    elif [[ "$phase" == "implement" ]]; then
      # Same chain ap-cycle.sh's own implement arm runs: swap building ->
      # shipping, ping, then dispatch the ship phase in a NEW window on the
      # SAME slot -- this act's own window is done, ship gets its own.
      gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
        --add-label shipping --remove-label building \
        >>"$AP_HOME/logs/cycle.log" 2>&1 || true
      ap-notify.sh "shipping: ${issue:-ENG-$inbox_issue}" "implement done, opening the PR" "$inbox_url" || true
      teardown_window "$window"
      ship_window="act_build_${acquired_lock_file##*.}_${issue:-unknown}_ship"
      if window_alive "$ship_window"; then
        log "ship window $ship_window already exists -- refusing to dispatch a duplicate chained ship"
      else
        launch_window_and_wait "$ship_window" \
          "/ship-work $plan_path --headless --no-merge --ports fe=$fe_port,be=$be_port --run-dir $run_dir" \
          "${AP_SHIP_MODEL:-sonnet}"
        log "chained ship in $ship_window finished with status=$final_status"
        case "$final_status" in
          DONE)
            teardown_window "$ship_window"
            pr_urls="$(json_join "$status_json" ".pr_urls")"
            ap-notify.sh "ready to test: ${issue:-ENG-$inbox_issue}" "${pr_urls:-see inbox}" "$inbox_url" || true
            ;;
          NEEDS_HUMAN)
            question="$(json_field "$status_json" ".question")"
            gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" --body "Autopilot: needs input (phase ship).

$question" >>"$AP_HOME/logs/cycle.log" 2>&1 || true
            ap-notify.sh "autopilot needs input: ${issue:-ENG-$inbox_issue}" "${question:-see inbox}" "$inbox_url" || true
            park_registry_write "$inbox_issue" "$issue" ship build "$ship_window" "$run_dir" "$plan_path" "$fe_port" "$be_port" "$question"
            exit 0
            ;;
          *)
            gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
              --add-label failed --remove-label shipping >>"$AP_HOME/logs/cycle.log" 2>&1 || true
            ap-notify.sh "autopilot FAILED: ${issue:-ENG-$inbox_issue}" "ship phase failed after resume; see $ship_window's transcript" "$inbox_url" || true
            teardown_window "$ship_window"
            ;;
        esac
      fi
    fi
    ;;

  NEEDS_HUMAN)
    question="$(json_field "$status_json" ".question")"
    gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" --body "Autopilot: needs input (phase ${phase:-unknown}).

$question" >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    ap-notify.sh "autopilot needs input: ${issue:-ENG-$inbox_issue}" "${question:-see inbox}" "$inbox_url" || true
    # Re-park under the SAME window (still alive) -- everything is unchanged
    # from the original entry except parked_at/question.
    park_registry_write "$inbox_issue" "$issue" "$phase" "$lane" "$window" "$run_dir" "$plan_path" "$fe_port" "$be_port" "$question"
    ;;

  *)
    # FAILED (including "window disappeared mid-resume", which defaults
    # here since final_status was seeded FAILED when status_file is
    # missing). See this file's header for what's deliberately NOT
    # replicated (external-failure requeue classification).
    rm -f "$registry_file"
    teardown_window "$window"
    stdout_tail="transcript output isn't captured for a resumed persistent act; see $window's transcript via ap tail if it still exists"
    ap-notify.sh "autopilot FAILED: ${issue:-ENG-$inbox_issue}" "$stdout_tail" "$inbox_url" || true
    gh issue edit "$inbox_issue" --repo "$AP_INBOX_REPO" \
      --add-label failed --remove-label planning --remove-label building \
      --remove-label shipping --remove-label ship-pending \
      >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    gh issue comment "$inbox_issue" --repo "$AP_INBOX_REPO" --body "Autopilot: run failed after resume." \
      >>"$AP_HOME/logs/cycle.log" 2>&1 || true
    ;;
esac

log "reconciled: final_status=$final_status phase=${phase:-unknown}"
exit 0
