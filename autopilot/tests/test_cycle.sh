#!/usr/bin/env bash
# Self-contained test harness for ap-cycle.sh (+ ap-resume.sh). No network, no
# real claude/tmux. Stubs claude/ap-notify.sh/tmux on PATH, seeds
# $AP_HOME/queue/<ENG-ID>.json fixture files directly (the local queue that
# replaced the GitHub inbox + the haiku poll -- see ap_queue.py/ap-decide.py),
# and asserts on the recorded claude/tmux argv plus the resulting queue
# ticket/ledger state ap-cycle.sh (a REAL, unstubbed ap-decide.py runs every
# cycle now -- deciding is free) produces.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
CYCLE="$BIN_DIR/ap-cycle.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# assert_true <description> <command...>
assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# --- queue fixture helpers (same design as tests/test_decide.sh) -------------

# seed_ticket <ap-home> <eng-id> <state> [field=value ...]
seed_ticket() {
  local ap_home="$1" eng_id="$2" state="$3"; shift 3
  python3 - "$BIN_DIR" "$ap_home" "$eng_id" "$state" "$@" <<'PY'
import sys, json
bin_dir, ap_home, eng_id, state = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, bin_dir)
import ap_queue
entry = ap_queue.new_ticket(ap_home, eng_id)
entry["state"] = state
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    try:
        v = json.loads(v)
    except Exception:
        pass
    entry[k] = v
ap_queue.write_ticket(ap_home, eng_id, entry)
PY
}

# ticket_field <ap-home> <eng-id> <field> -> the field's value, or empty.
ticket_field() {
  python3 -c '
import json, sys
ap_home, eng_id, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(f"{ap_home}/queue/{eng_id}.json") as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
v = d.get(field)
if v is None:
    sys.exit(0)
print(v if isinstance(v, (str, int, float, bool)) else json.dumps(v))
' "$1" "$2" "$3" 2>/dev/null
}
export -f ticket_field

# ticket_history_has <ap-home> <eng-id> <substring> -> rc 0 if the ticket's
# most recent history event contains substring.
ticket_history_has() {
  python3 -c '
import json, sys
ap_home, eng_id, needle = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(f"{ap_home}/queue/{eng_id}.json") as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
hist = d.get("history") or []
sys.exit(0 if hist and needle.lower() in hist[-1].get("event", "").lower() else 1)
' "$1" "$2" "$3" 2>/dev/null
}
export -f ticket_history_has

# seed_plan_file <work-repo> <eng-id> -- a resolvable docs/plans/*.md fallback
# match for ap-decide.py's resolve_plan_path(), same fixture shape as
# test_decide.sh.
seed_plan_file() {
  local work_repo="$1" eng_id="$2"
  local slug
  slug="$(printf '%s' "$eng_id" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$work_repo/docs/plans"
  touch "$work_repo/docs/plans/${slug}-thing.md"
}

# --- stub bin dir --------------------------------------------------------------
# Written once; behavior is driven per-test by env vars read at call time.
# No `gh` stub anymore: ap-cycle.sh/ap-decide.py/ap-resume.sh make no gh calls
# at all -- intake/approval/feedback/retry are all local queue writes now.

make_stub_dir() {
  local dir="$1"
  mkdir -p "$dir"

  cat >"$dir/claude" <<'STUB_CLAUDE'
#!/usr/bin/env bash
calls_dir="${AP_TEST_STUB_DIR}/claude_calls"
mkdir -p "$calls_dir"
n=$(find "$calls_dir" -maxdepth 1 -name '*.args' | wc -l)
n=$((n + 1))
printf '%s\n' "$@" >"$calls_dir/$n.args"
# Record the cwd every claude invocation inherits: skill discovery is
# cwd-based, so a cycle running from anywhere but the work repo finds no
# skills and fails open with action:none.
pwd >"$calls_dir/$n.pwd"

prompt="$2"
phase="unknown"
case "$prompt" in
  *"--phase plan"*) phase="plan" ;;
  *"--phase implement"*) phase="implement" ;;
  *ship-work*) phase="ship" ;;
esac
[[ "$prompt" == *--feedback* ]] && phase="replan"

status="${AP_TEST_ACT_STATUS:-DONE}"
if [[ "$phase" == "implement" && -n "${AP_TEST_IMPLEMENT_STATUS:-}" ]]; then
  status="$AP_TEST_IMPLEMENT_STATUS"
fi
if [[ "$phase" == "ship" && -n "${AP_TEST_SHIP_STATUS:-}" ]]; then
  status="$AP_TEST_SHIP_STATUS"
fi

if [[ -n "${AP_TEST_ACT_STDERR:-}" ]]; then
  printf '%s\n' "$AP_TEST_ACT_STDERR" >&2
fi

phase_upper="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
skip_status_var="AP_TEST_SKIP_STATUS_$phase_upper"
exit_code_var="AP_TEST_EXIT_CODE_$phase_upper"
skip_status="${!skip_status_var:-}"
exit_code="${!exit_code_var:-}"

# Legacy global knobs (still used by pre-existing cases): apply to every
# phase unless a phase-specific override above already set the behavior.
if [[ -z "$skip_status" && "${AP_TEST_ACT_MODE:-normal}" == "no_status" ]]; then
  skip_status=1
fi
if [[ -z "$exit_code" && "${AP_TEST_ACT_MODE:-normal}" == "exit_nonzero" ]]; then
  exit_code=1
fi

status_dest="$AP_RUN_DIR/status.json"
if [[ "${AP_TEST_STATUS_TO_ADHOC:-}" == "1" ]]; then
  # Simulate a session that could not resolve the run dir and used the
  # documented adhoc fallback instead.
  mkdir -p "$AP_HOME/runs/adhoc"
  status_dest="$AP_HOME/runs/adhoc/status.json"
fi
# status.json always carries "issue" per the protocol's shape. Defaults to
# this act's own issue (AP_TEST_ACT_ISSUE) so adhoc adoption's .issue match
# succeeds by default; AP_TEST_ADHOC_STATUS_ISSUE overrides it to simulate a
# DIFFERENT concurrent act's leftover file (a mismatch the wrapper must not
# adopt).
status_issue="${AP_TEST_ADHOC_STATUS_ISSUE:-${AP_TEST_ACT_ISSUE:-}}"
if [[ "$skip_status" != "1" && -n "${AP_RUN_DIR:-}" ]]; then
  mkdir -p "$AP_RUN_DIR"
  python3 - "$status" "${AP_TEST_QUESTION:-what should I do}" "${AP_TEST_PR_URL:-https://github.com/x/y/pull/1}" "$status_issue" <<'PY' >"$status_dest"
import json, sys
status, question, pr_url, issue = sys.argv[1:5]
d = {"status": status, "issue": (issue or None)}
if status == "NEEDS_HUMAN":
    d["question"] = question
if status == "DONE":
    d["pr_urls"] = [pr_url]
print(json.dumps(d))
PY
fi

echo '{"total_cost_usd": 0.05, "session_id": "act-session"}'

if [[ "$exit_code" == "1" ]]; then
  exit 1
fi
exit 0
STUB_CLAUDE

  cat >"$dir/ap-notify.sh" <<'STUB_NOTIFY'
#!/usr/bin/env bash
calls_dir="${AP_TEST_STUB_DIR}/notify_calls"
mkdir -p "$calls_dir"
n=$(find "$calls_dir" -maxdepth 1 -name '*.args' | wc -l)
n=$((n + 1))
printf '%s\n' "$@" >"$calls_dir/$n.args"
exit 0
STUB_NOTIFY

  # Minimal fake tmux for AP_ACT_LAUNCH_MODE=persistent cases, so they never
  # touch a real tmux server. State lives under $AP_HOME/.test-tmux/ (one
  # file per window, line 1 = tracked pid), which resets with the rest of
  # CASE_AP_HOME every setup_case -- real interactive-injection semantics
  # (does send-keys + a separate Enter actually submit) were verified live
  # against a real tmux session + real claude, not re-tested here; this
  # stub only exercises ap-cycle.sh/ap-resume.sh's own bookkeeping.
  cat >"$dir/tmux" <<'STUB_TMUX'
#!/usr/bin/env bash
state_dir="${AP_HOME:-/tmp}/.test-tmux"
mkdir -p "$state_dir"
cmd="${1:-}"; shift || true
case "$cmd" in
  new-window)
    name="" args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) shift 2 ;;
        -n) name="$2"; shift 2 ;;
        -d) shift ;;
        --) shift; args=("$@"); break ;;
        *) shift ;;
      esac
    done
    "${args[@]}" &
    pid=$!
    echo "$pid" >"$state_dir/$name.meta"
    exit 0
    ;;
  list-windows)
    fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -F) fmt="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    for f in "$state_dir"/*.meta; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f" .meta)"
      pid="$(cat "$f" 2>/dev/null)"
      if [[ "$fmt" == *pane_pid* ]]; then
        echo "$name $pid"
      else
        echo "$name"
      fi
    done
    exit 0
    ;;
  list-panes)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    name="${target#*:}"
    [[ -f "$state_dir/$name.meta" ]] && cat "$state_dir/$name.meta"
    exit 0
    ;;
  kill-window)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    name="${target#*:}"
    if [[ -f "$state_dir/$name.meta" ]]; then
      pid="$(cat "$state_dir/$name.meta" 2>/dev/null)"
      kill "$pid" 2>/dev/null || true
      rm -f "$state_dir/$name.meta"
    fi
    exit 0
    ;;
  send-keys)
    calls_dir="${AP_TEST_STUB_DIR}/tmux_sendkeys_calls"
    mkdir -p "$calls_dir"
    n=$(find "$calls_dir" -maxdepth 1 -name '*.args' 2>/dev/null | wc -l)
    n=$((n + 1))
    printf '%s\n' "$@" >"$calls_dir/$n.args"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB_TMUX

  chmod +x "$dir/claude" "$dir/ap-notify.sh" "$dir/tmux"
}

# --- per-case fixture --------------------------------------------------------

AP_TEST_VARS=(
  AP_TEST_ACT_ISSUE AP_TEST_ACT_STATUS AP_TEST_IMPLEMENT_STATUS
  AP_TEST_SHIP_STATUS AP_TEST_ACT_MODE AP_TEST_QUESTION AP_TEST_PR_URL
  AP_TEST_ACT_STDERR
  AP_TEST_SKIP_STATUS_IMPLEMENT AP_TEST_SKIP_STATUS_SHIP AP_TEST_SKIP_STATUS_PLAN
  AP_TEST_SKIP_STATUS_REPLAN AP_TEST_STATUS_TO_ADHOC AP_TEST_ADHOC_STATUS_ISSUE
  AP_TEST_EXIT_CODE_IMPLEMENT AP_TEST_EXIT_CODE_SHIP AP_TEST_EXIT_CODE_PLAN
  AP_TEST_EXIT_CODE_REPLAN
)

setup_case() {
  CASE_AP_HOME="$(mktemp -d)"
  CASE_STUB_DIR="$(mktemp -d)"
  CASE_WORK_REPO="$(mktemp -d)"
  make_stub_dir "$CASE_STUB_DIR"
  for v in "${AP_TEST_VARS[@]}"; do unset "$v"; done
  unset AP_BUILD_SLOTS AP_SHIP_SLOTS AP_LIMIT_COOLDOWN_MIN AP_AUTO_APPROVE
}

run_case() {
  # runs ap-cycle.sh with the current fixture; stdout/stderr discarded to log.
  # Deliberately launched from a directory that is NOT the work repo (the
  # subshell cd) so the cwd-discipline case can catch a regression of the bug
  # where an act ran in the inherited cwd and therefore found no skills.
  #
  # AP_ACT_LAUNCH_MODE defaults to oneshot HERE (not ap-env.sh's real default,
  # persistent) so every pre-existing case below keeps exercising exactly the
  # one-shot `claude -p` code path it was written against, never real tmux.
  # A persistent-mode case sets AP_ACT_LAUNCH_MODE=persistent (and its own
  # isolated AP_TMUX_SESSION, backed by the stub dir's fake tmux -- see
  # make_stub_dir) before calling run_case, overriding this default.
  (
    cd /tmp || exit 1
    AP_HOME="$CASE_AP_HOME" \
    AP_WORK_REPO="$CASE_WORK_REPO" \
    AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
    AP_ACT_LAUNCH_MODE="${AP_ACT_LAUNCH_MODE:-oneshot}" \
    AP_TMUX_SESSION="${AP_TMUX_SESSION:-ap-test-should-never-be-real}" \
    PATH="$CASE_STUB_DIR:$PATH" \
      bash "$CYCLE" >"$CASE_AP_HOME/stdout.log" 2>"$CASE_AP_HOME/stderr.log"
  )
  echo $?
}

# hold_lane_lock <lock-file> <seconds> -> sets $LANE_HOLDER_PID. Stubs a
# concurrently-running act by grabbing the lane's flock in a background
# process for the given duration; caller should `wait "$LANE_HOLDER_PID"
# 2>/dev/null` (or let it expire) once done. NOT invoked via `$(...)`
# command substitution -- that runs the function (and its `&` background
# job) inside a throwaway subshell, and this sandbox reaps that subshell's
# orphaned children the moment the subshell exits, so the lock would never
# actually be held by the time the caller checks it.
hold_lane_lock() {
  local lock_file="$1" secs="$2"
  flock "$lock_file" sleep "$secs" &
  LANE_HOLDER_PID=$!
  # Wait until the lock is genuinely held before returning: backgrounding
  # flock and immediately running the cycle is a race, and a race here makes
  # the test pass for the wrong reason (cycle ran before the lock existed).
  local i=0
  while flock -n "$lock_file" true 2>/dev/null; do
    i=$((i + 1)); [[ "$i" -gt 100 ]] && break
    sleep 0.05
  done
}

count_files() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -maxdepth 1 -name '*.args' | wc -l
}

today_ledger() {
  echo "$CASE_AP_HOME/runs/$(date -u +%F).jsonl"
}

# shellcheck disable=SC2329 # invoked indirectly via `assert ... ledger_all_valid_json ...`
ledger_all_valid_json() {
  local ledger="$1"
  [[ -f "$ledger" ]] || return 1
  python3 - "$ledger" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        lines = [l for l in f.read().splitlines() if l.strip()]
    if not lines:
        sys.exit(1)
    for l in lines:
        json.loads(l)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# =============================================================================
# Case 1: pause file -> exits 0, claude never called, an otherwise-actionable
# queued ticket is left completely untouched.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-1 queued
touch "$CASE_AP_HOME/pause"
rc="$(run_case)"
assert "case1: pause -> exit 0" [ "$rc" -eq 0 ]
assert "case1: pause -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "case1: pause -> ticket untouched" [ "$(ticket_field "$CASE_AP_HOME" ENG-1 state)" = "queued" ]

# =============================================================================
# Case 2: lock.poll held by a slow first run -> second invocation exits
# without ever deciding (lock.poll serializes the decision path).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2 queued
(
  exec 9>"$CASE_AP_HOME/lock.poll" 2>/dev/null || { mkdir -p "$CASE_AP_HOME"; exec 9>"$CASE_AP_HOME/lock.poll"; }
  flock 9
  sleep 3
) &
holder_pid=$!
sleep 0.4
rc="$(run_case)"
wait "$holder_pid" 2>/dev/null
assert "case2: locked -> exit 0" [ "$rc" -eq 0 ]
assert "case2: locked -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "case2: locked -> ticket untouched (decide never ran)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-2 state)" = "queued" ]

# =============================================================================
# Case 3: ledger pre-seeded at the issue cap -> stage 2 never runs.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3 queued
mkdir -p "$CASE_AP_HOME/runs"
seed_ledger="$CASE_AP_HOME/runs/$(date -u +%F).jsonl"
echo '{"ts":"2026-01-01T00:00:00Z","issue":"ENG-OLD","phase":"implement","status":"DONE","cost":1.0,"session_id":"s1"}' >"$seed_ledger"
rc="$(AP_MAX_ISSUES_PER_DAY=1 run_case)"
assert "case3: at cap -> exit 0" [ "$rc" -eq 0 ]
assert "case3: at cap -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 4: decide (real, unstubbed) claims a queued ticket -> ONE claude call
# (the plan act itself -- deciding is free, no model call for it anymore) with
# --settings <path> and "--headless" in the prompt arg.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-4 queued
rc="$(run_case)"
assert "case4: exit 0" [ "$rc" -eq 0 ]
assert "case4: exactly one claude call (the plan act; decide is free)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
if [[ -f "$act_args" ]]; then
  assert "case4: act call has --settings" bash -c "grep -qx -- '--settings' '$act_args'"
  assert "case4: act call settings path is absolute autopilot.json" bash -c "grep -q '/autopilot/settings/autopilot.json$' '$act_args'"
  assert "case4: act call prompt has --headless" bash -c "grep -q -- '--headless' '$act_args'"
  assert "case4: act call prompt has --run-dir with the run path" bash -c "grep -q -- '--run-dir /' '$act_args'"
  assert "case4: act call prompt targets implement-issue --phase plan ENG-4" bash -c "grep -q 'implement-issue --phase plan ENG-4' '$act_args'"
  assert "case4: plan DONE pings the owner (plan ready for review)" bash -c \
    "grep -rl 'plan ready for review' '$CASE_STUB_DIR/notify_calls' >/dev/null"
else
  fail "case4: act call has --settings (no 1.args file)"
  fail "case4: act call settings path is absolute autopilot.json"
  fail "case4: act call prompt has --headless"
  fail "case4: act call prompt targets implement-issue --phase plan ENG-4"
fi
assert "case4(claim): ticket state -> planning" [ "$(ticket_field "$CASE_AP_HOME" ENG-4 state)" = "planning" ]

# =============================================================================
# Case 5: status NEEDS_HUMAN with question -> notify stub called with the
# question text; the queue ticket's own question/phase_at_question fields are
# also written (the local replacement for the old inbox-comment echo).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-5 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-5
rc="$(AP_TEST_ACT_STATUS=NEEDS_HUMAN AP_TEST_QUESTION="which project?" run_case)"
assert "case5: exit 0" [ "$rc" -eq 0 ]
assert "case5: notify called" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 1 ]
assert "case5: notify includes question text" bash -c \
  "grep -rl 'which project?' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case5: ticket state -> needs-input" [ "$(ticket_field "$CASE_AP_HOME" ENG-5 state)" = "needs-input" ]
assert "case5: ticket question field recorded" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-5 question)" = "which project?" ]
assert "case5: ticket phase_at_question=implement" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-5 phase_at_question)" = "implement" ]

# =============================================================================
# Case 6: status file EXISTS with FAILED -> ticket moved to failed (a local
# queue write, no gh call anymore) AND notify called (wrapper authority over
# written-FAILED).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-6 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-6
rc="$(AP_TEST_ACT_STATUS=FAILED run_case)"
assert "case6: exit 0" [ "$rc" -eq 0 ]
assert "case6: ticket state -> failed" [ "$(ticket_field "$CASE_AP_HOME" ENG-6 state)" = "failed" ]
assert "case6: history records the failure" ticket_history_has "$CASE_AP_HOME" ENG-6 "run failed"
assert "case6: notify called" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 1 ]

# =============================================================================
# Case 7: no status.json -> same failed handling; a second consecutive
# failure -> pause file exists + notify.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-7 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-7
rc1="$(AP_TEST_ACT_MODE=no_status run_case)"
assert "case7: run1 exit 0" [ "$rc1" -eq 0 ]
assert "case7: run1 no pause yet" [ ! -e "$CASE_AP_HOME/pause" ]
assert "case7: run1 fail_count=1" bash -c "[ \"\$(cat '$CASE_AP_HOME/fail_count')\" = 1 ]"
seed_ticket "$CASE_AP_HOME" ENG-7b plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-7b
rc2="$(AP_TEST_ACT_MODE=no_status run_case)"
assert "case7: run2 exit 0" [ "$rc2" -eq 0 ]
assert "case7: run2 (2nd consecutive failure) -> pause file exists" [ -e "$CASE_AP_HOME/pause" ]
assert "case7: run2 -> notify called (failed + auto-paused)" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 2 ]

# =============================================================================
# Case 8: every scenario appends exactly one valid JSON line per claude call
# to the ledger, PLUS the one free poll row Stage 1 always writes -- and
# claude itself is only ever called for real acts (implement+ship = 2 calls
# here, not 3: the poll row costs nothing).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-8 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-8
rc="$(AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SHIP_STATUS=DONE run_case)"
ledger="$(today_ledger)"
assert "case8: exit 0" [ "$rc" -eq 0 ]
assert "case8: ledger exists" [ -f "$ledger" ]
assert "case8: ledger has 3 lines (poll+implement+ship)" bash -c "[ \"\$(wc -l < '$ledger')\" -eq 3 ]"
assert "case8: ledger is all valid JSON" ledger_all_valid_json "$ledger"
assert "case8: only 2 claude calls were made (implement+ship; the poll row is free)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]

# Re-check ledger validity for a couple of the earlier single-call cases too.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-8b queued
rc="$(run_case)"
ledger="$(today_ledger)"
assert "case8b: exit 0" [ "$rc" -eq 0 ]
assert "case8b: ledger has 2 lines (poll+plan)" bash -c "[ \"\$(wc -l < '$ledger')\" -eq 2 ]"
assert "case8b: ledger is all valid JSON" ledger_all_valid_json "$ledger"
assert "case8b: only 1 claude call (the plan act)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]

# =============================================================================
# Case 9: symlink layout (defect 1) — ap-cycle.sh invoked through a flat
# symlinked bin dir, mirroring scripts/install-autopilot.sh's real layout
# (autopilot/bin/* symlinked into ~/.local/bin). The --settings argument to
# the act-stage claude call must resolve to the real, existing
# autopilot/settings/autopilot.json — not a path relative to the symlink's
# own directory (which pre-fix would be a nonexistent ~/.local/settings/...).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SYM queued
SYMLINK_BIN="$(mktemp -d)"
for f in ap ap-cycle.sh ap-decide.sh ap-decide.py ap_queue.py ap-env.sh ap-notify.sh ap-runs.py; do
  ln -s "$BIN_DIR/$f" "$SYMLINK_BIN/$f"
done
rc="$(
  AP_HOME="$CASE_AP_HOME" \
  AP_WORK_REPO="$CASE_WORK_REPO" \
  AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
  AP_ACT_LAUNCH_MODE=oneshot \
  AP_TMUX_SESSION=ap-test-should-never-be-real \
  PATH="$CASE_STUB_DIR:$PATH" \
    bash "$SYMLINK_BIN/ap-cycle.sh" >"$CASE_AP_HOME/stdout.log" 2>"$CASE_AP_HOME/stderr.log"
  echo $?
)"
assert "case9: symlinked ap-cycle.sh exits 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
settings_path=""
if [[ -f "$act_args" ]]; then
  settings_path="$(awk '/^--settings$/{getline; print; exit}' "$act_args")"
fi
assert "case9: symlinked act call recorded a --settings path" [ -n "$settings_path" ]
assert "case9: symlinked act call --settings path exists on disk" bash -c "[ -n '$settings_path' ] && [ -f '$settings_path' ]"

# =============================================================================
# Case 10: `ap up`'s crontab resolution (defect 1) via a flat symlinked bin
# dir. Using the --print-paths debug flag (rather than stubbing tmux) to
# assert the resolved CRONTAB_TEMPLATE/CRONTAB_RENDERED both exist on disk —
# pre-fix, `ap` would resolve these relative to the symlink's own directory
# (~/.local/crontab), which does not exist.
# =============================================================================
setup_case
SYMLINK_BIN2="$(mktemp -d)"
for f in ap ap-env.sh; do
  ln -s "$BIN_DIR/$f" "$SYMLINK_BIN2/$f"
done
paths_out="$(AP_HOME="$CASE_AP_HOME" bash "$SYMLINK_BIN2/ap" --print-paths)"
template_path="$(printf '%s\n' "$paths_out" | grep '^CRONTAB_TEMPLATE=' | cut -d= -f2-)"
rendered_path="$(printf '%s\n' "$paths_out" | grep '^CRONTAB_RENDERED=' | cut -d= -f2-)"
assert "case10: --print-paths reports a CRONTAB_TEMPLATE that exists" bash -c "[ -n '$template_path' ] && [ -f '$template_path' ]"
assert "case10: --print-paths reports a CRONTAB_RENDERED that exists" bash -c "[ -n '$rendered_path' ] && [ -f '$rendered_path' ]"

# =============================================================================
# Case 11: AP_TZ governs the ledger filename's calendar day, not UTC's. Uses
# whichever of Etc/GMT+12 / Etc/GMT-12 currently differs from UTC's date
# (guaranteed except at the instant of UTC midnight) for a deterministic,
# unambiguous check.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-TZ queued
utc_date="$(date -u +%F)"
tz_candidate="Etc/GMT+12"
tz_date="$(TZ="$tz_candidate" date +%F)"
if [[ "$tz_date" == "$utc_date" ]]; then
  tz_candidate="Etc/GMT-12"
  tz_date="$(TZ="$tz_candidate" date +%F)"
fi
rc="$(AP_TZ="$tz_candidate" run_case)"
expected_ledger="$CASE_AP_HOME/runs/$tz_date.jsonl"
assert "case11: exit 0" [ "$rc" -eq 0 ]
assert "case11: ledger filename equals TZ=\$AP_TZ date +%F, not UTC's date" [ -f "$expected_ledger" ]

# =============================================================================
# Case 12: crontab CRON_TZ render (defect 2) — `ap --print-paths` renders the
# crontab template with the CRON_TZ line replaced by AP_TZ, and supercronic
# accepts the rendered result.
# =============================================================================
setup_case
paths_out="$(AP_HOME="$CASE_AP_HOME" AP_TZ=Europe/Paris bash "$BIN_DIR/ap" --print-paths)"
rendered_path="$(printf '%s\n' "$paths_out" | grep '^CRONTAB_RENDERED=' | cut -d= -f2-)"
assert "case12: rendered crontab exists" [ -f "$rendered_path" ]
assert "case12: rendered crontab has CRON_TZ=Europe/Paris" bash -c "grep -qx 'CRON_TZ=Europe/Paris' '$rendered_path'"
if command -v supercronic >/dev/null 2>&1; then
  assert "case12: supercronic -test accepts rendered crontab" supercronic -test "$rendered_path"
else
  echo "SKIP: case12 supercronic -test (supercronic not on PATH)"
fi

# =============================================================================
# Case 13: FAILED reconcile body (defect 3) — the notify body must include
# the acting claude call's stderr tail (e.g. a permission-denial string)
# labeled separately from the stdout tail, not stdout alone. (There is no gh
# comment anymore -- ap-notify.sh is the only carrier of the failure body.)
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-13 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-13
rc="$(AP_TEST_ACT_STATUS=FAILED \
  AP_TEST_ACT_STDERR="permission denied: Bash(rm -rf /tmp/x)" run_case)"
assert "case13: exit 0" [ "$rc" -eq 0 ]
assert "case13: notify body includes stderr denial text" bash -c \
  "grep -rl 'permission denied' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case13: notify body labels the STDERR section" bash -c \
  "grep -rl 'STDERR' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case13: notify body labels the STDOUT section" bash -c \
  "grep -rl 'STDOUT' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# =============================================================================
# Case 14 (bug 1): stale status.json across phases. implement writes DONE,
# ship exits non-zero WITHOUT writing its own status.json. The leftover
# implement status.json must NOT be read as the ship result -- ship must be
# treated as FAILED (failed notify, no "ready to test"), and the ledger row
# for the ship phase must record FAILED, not DONE.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-14 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-14
rc="$(AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SKIP_STATUS_SHIP=1 AP_TEST_EXIT_CODE_SHIP=1 run_case)"
ledger="$(today_ledger)"
assert "case14: exit 0" [ "$rc" -eq 0 ]
assert "case14: 2 claude calls (implement+ship)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]
assert "case14: notify called (failed), not ready-to-test" bash -c \
  "! grep -rl 'ready to test' '$CASE_STUB_DIR/notify_calls' >/dev/null 2>&1"
assert "case14: notify called with FAILED title" bash -c \
  "grep -rl 'FAILED' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case14: ship ledger row is FAILED, not the leftover implement DONE" bash -c \
  "python3 -c \"
import json
with open('$ledger') as f:
    rows = [json.loads(l) for l in f if l.strip()]
ship_rows = [r for r in rows if r['phase'] == 'ship']
assert len(ship_rows) == 1, ship_rows
assert ship_rows[0]['status'] == 'FAILED', ship_rows[0]
\""

# =============================================================================
# Case 15 (bug 2): ap-notify.sh JSON payload must be properly escaped, and
# the ntfy Title header must not carry an embedded newline. Exercises the
# REAL ap-notify.sh (not the stub) against a fake curl on PATH. Unrelated to
# the inbox/queue refactor -- unchanged.
# =============================================================================
NOTIFY_AP_HOME="$(mktemp -d)"
NOTIFY_STUB_DIR="$(mktemp -d)"
NOTIFY_CALLS_DIR="$NOTIFY_AP_HOME/curl_calls"
mkdir -p "$NOTIFY_CALLS_DIR"
cat >"$NOTIFY_STUB_DIR/curl" <<'STUB_CURL'
#!/usr/bin/env bash
calls_dir="${AP_TEST_NOTIFY_CALLS_DIR}"
n=$(find "$calls_dir" -maxdepth 1 -name '*.data' 2>/dev/null | wc -l)
n=$((n + 1))
: >"$calls_dir/$n.data"
: >"$calls_dir/$n.headers"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-d" || "$prev" == "--data" ]]; then
    printf '%s' "$a" >"$calls_dir/$n.data"
  fi
  if [[ "$prev" == "-H" ]]; then
    printf '%s\n' "$a" >>"$calls_dir/$n.headers"
  fi
  prev="$a"
done
exit 0
STUB_CURL
chmod +x "$NOTIFY_STUB_DIR/curl"

notify_title="Title Line1
Title Line2"
notify_body='line one with "quotes" and \backslash
line two'
notify_url="https://example.com/x"

AP_HOME="$NOTIFY_AP_HOME" \
AP_TEST_NOTIFY_CALLS_DIR="$NOTIFY_CALLS_DIR" \
NTFY_TOPIC="test-topic" \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
PATH="$NOTIFY_STUB_DIR:$PATH" \
  bash "$BIN_DIR/ap-notify.sh" "$notify_title" "$notify_body" "$notify_url" \
  >/dev/null 2>"$NOTIFY_AP_HOME/stderr.log"

# call 1 = ntfy (Title header), call 2 = slack (JSON payload) -- ap-notify.sh
# runs the ntfy block before the slack block.
assert "case15: ntfy call recorded" [ -f "$NOTIFY_CALLS_DIR/1.headers" ]
# The Title header must be exactly one line ("Title: ..."); pre-fix, a
# multi-line title produces an extra bare continuation line with no header
# name at all (HTTP headers can't embed a raw newline).
assert "case15: ntfy Title header has no embedded newline" bash -c \
  "[ \"\$(grep -c '^Title:' '$NOTIFY_CALLS_DIR/1.headers')\" -eq 1 ] && \
   [ \"\$(grep -vc '^\(Title\|Click\):' '$NOTIFY_CALLS_DIR/1.headers')\" -eq 0 ]"
assert "case15: slack call recorded" [ -f "$NOTIFY_CALLS_DIR/2.data" ]
title_sanitized="${notify_title//$'\n'/ }"
expected_text="*${title_sanitized}*\n${notify_body}\n${notify_url}"
check_payload_script="$NOTIFY_AP_HOME/check_payload.py"
cat >"$check_payload_script" <<'PY'
import json, sys
data_file, expected = sys.argv[1:3]
with open(data_file) as f:
    payload = json.load(f)
if payload.get("text") != expected:
    print("mismatch: got %r want %r" % (payload.get("text"), expected), file=sys.stderr)
    sys.exit(1)
PY
assert "case15: slack payload is valid JSON with exact .text" \
  python3 "$check_payload_script" "$NOTIFY_CALLS_DIR/2.data" "$expected_text"

# =============================================================================
# Case 16 (bug 3): replan feedback containing apostrophes must survive intact
# into the claude prompt -- not truncated/corrupted by the literal single
# quotes wrapping --feedback.
# =============================================================================
setup_case
raw_feedback="don't merge, it's wrong"
seed_ticket "$CASE_AP_HOME" ENG-16 plan-review feedback="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$raw_feedback")"
rc="$(run_case)"
assert "case16: exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "case16: act call recorded" [ -f "$act_args" ]
feedback_check_rc=1
if [[ -f "$act_args" ]]; then
  # Parse the recorded prompt line with shlex (POSIX shell quoting rules),
  # the same "'...' with embedded '\'' escapes" convention the fix uses.
  # Pre-fix, the apostrophes inside a literal '...'-wrapped value break the
  # quoting and shlex reconstructs a mangled token (apostrophes silently
  # dropped) instead of the original feedback text.
  python3 - "$act_args" "$raw_feedback" <<'PY'
import shlex, sys
args_file, raw_feedback = sys.argv[1:3]
with open(args_file) as f:
    lines = f.read().splitlines()
prompt_lines = [l for l in lines if "--feedback" in l]
if not prompt_lines:
    print("no --feedback line found in recorded args", file=sys.stderr)
    sys.exit(1)
line = prompt_lines[0]
try:
    tokens = shlex.split(line, posix=True)
except ValueError as e:
    print("shlex could not parse prompt line: %s (%s)" % (line, e), file=sys.stderr)
    sys.exit(1)
if "--feedback" not in tokens:
    print("--feedback token missing after shlex parse: " + line, file=sys.stderr)
    sys.exit(1)
value = tokens[tokens.index("--feedback") + 1]
if value != raw_feedback:
    print("feedback corrupted: got %r want %r" % (value, raw_feedback), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
  feedback_check_rc=$?
fi
assert "case16: recorded prompt's --feedback unescapes back to the original text" [ "$feedback_check_rc" -eq 0 ]

# =============================================================================
# NOTE on removed cases (17-24 in the pre-refactor suite): the entire "Stage
# 0.5 pre-scan gate" they exercised (scan-state.json, wake-on-comment,
# fallback full-poll interval, marker-suppressed wakes, per-signal
# seen-tracking) no longer exists -- ap-decide.sh now runs unconditionally,
# every cycle, because deciding against the local queue is free. There is no
# replacement gate to test; case 4/8b above already cover "decide runs and
# claude is only called for the resulting act, never for deciding itself".
# =============================================================================

# =============================================================================
# Case 23: session writes status.json to the adhoc fallback (could not resolve
# the run dir) -> wrapper adopts it instead of declaring FAILED.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-23 queued
rc="$(AP_TEST_STATUS_TO_ADHOC=1 AP_TEST_ACT_ISSUE=ENG-23 run_case)"
assert "case23: exit 0" [ "$rc" -eq 0 ]
assert "case23: ledger plan row adopted DONE from adhoc" bash -c \
  "cat '$CASE_AP_HOME/runs/'*.jsonl | python3 -c 'import json,sys; rows=[json.loads(l) for l in sys.stdin if l.strip()]; sys.exit(0 if any(r[\"phase\"]==\"plan\" and r[\"status\"]==\"DONE\" for r in rows) else 1)'"
assert "case23: ticket not moved to failed" [ "$(ticket_field "$CASE_AP_HOME" ENG-23 state)" != "failed" ]
assert "case23: adhoc file consumed (moved, not left stale)" bash -c \
  "[ ! -f '$CASE_AP_HOME/runs/adhoc/status.json' ]"

# =============================================================================
# Case 23b (adhoc adoption hardening, needed for two-lane concurrency): the
# adhoc status.json's .issue does NOT match THIS act's issue -- a different
# concurrent act's leftover file sharing the one adhoc path. Must NOT be
# adopted: left in place, this act is treated as FAILED (no status.json ever
# resolved for it), and the mismatched file survives for its real owner.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-23B queued
rc="$(AP_TEST_STATUS_TO_ADHOC=1 AP_TEST_ACT_ISSUE=ENG-23B \
  AP_TEST_ADHOC_STATUS_ISSUE=ENG-OTHER run_case)"
assert "case23b: exit 0" [ "$rc" -eq 0 ]
assert "case23b: ledger plan row is FAILED, not adopted from the mismatched adhoc file" bash -c \
  "cat '$CASE_AP_HOME/runs/'*.jsonl | python3 -c 'import json,sys; rows=[json.loads(l) for l in sys.stdin if l.strip()]; sys.exit(0 if any(r[\"phase\"]==\"plan\" and r[\"status\"]==\"FAILED\" for r in rows) else 1)'"
assert "case23b: mismatched adhoc file left in place (not consumed)" bash -c \
  "[ -f '$CASE_AP_HOME/runs/adhoc/status.json' ]"

# =============================================================================
# Two-lane concurrency (Change B). lock.build / lock.plan are stubbed busy by
# grabbing the lock file with a background `flock <file> sleep <n> &`. decide
# is now real (not stubbed), so these assert on the OUTCOME (which ticket got
# claimed, which act ran) rather than on any --busy argv (there is no longer
# a recorded call to inspect for the free decide step itself).
# =============================================================================

# --- (i) build lane held + a queued ticket present -> a plan act proceeds
# (plan lane is free) despite the build lane being full.
# AP_BUILD_SLOTS=1 here: this exercises the "lane busy" boundary itself
# (single-slot semantics), not slot-count behavior -- that's covered
# separately below (build slot concurrency, Feature 1).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2001 queued
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 run_case)"
wait "$build_holder" 2>/dev/null
assert "laneB(i): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "laneB(i): plan act proceeded (plan lane free)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-2001' '$act_args'"

# --- (ii) plan lane held + an approved plan-review ticket present ->
# implement proceeds (build lane is free).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2002 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-2002
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(run_case)"
wait "$plan_holder" 2>/dev/null
assert "laneB(ii): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "laneB(ii): implement act proceeded (build lane free)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"

# --- (iii) BOTH lanes held -> no claude call at all.
# AP_BUILD_SLOTS=1 (single-slot boundary, not slot-count behavior).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2003 queued
seed_ticket "$CASE_AP_HOME" ENG-2004 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-2004
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 run_case)"
wait "$build_holder" "$plan_holder" 2>/dev/null
assert "laneB(iii): exit 0" [ "$rc" -eq 0 ]
assert "laneB(iii): no claude call at all (both lanes busy)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "laneB(iii): neither ticket was claimed" bash -c \
  '[ "$(ticket_field "$1" ENG-2003 state)" = "queued" ] &&
   [ "$(ticket_field "$1" ENG-2004 state)" = "plan-review" ]' _ "$CASE_AP_HOME"

# --- (iv) an approved plan-review ticket while the build lane is held is NOT
# claimed (re-fires once the lane frees).
# AP_BUILD_SLOTS=1 (single-slot boundary).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2005 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-2005
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 run_case)"
wait "$build_holder" 2>/dev/null
assert "laneB(iv): exit 0 (build busy -> not claimed)" [ "$rc" -eq 0 ]
assert "laneB(iv): claude NOT called (signal's lane busy)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "laneB(iv): ticket NOT claimed" [ "$(ticket_field "$CASE_AP_HOME" ENG-2005 state)" = "plan-review" ]
rc2="$(AP_BUILD_SLOTS=1 run_case)"
assert "laneB(iv): second cycle (lane free) exit 0" [ "$rc2" -eq 0 ]
assert "laneB(iv): second cycle -> claude called (re-fired)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
# The default stub status is DONE, so implement chains straight into ship in
# the same cycle -- the ticket ends up "shipping", not "building" (proving it
# was claimed away from plan-review either way).
assert "laneB(iv): second cycle -> ticket claimed" [ "$(ticket_field "$CASE_AP_HOME" ENG-2005 state)" = "shipping" ]

# =============================================================================
# Auto-approve (Change C).
# =============================================================================

# --- (a) global auto-approve on + plan-review ticket with no reply at all ->
# implement claimed straight away, no `ap approve` needed.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3001 plan-review
seed_plan_file "$CASE_WORK_REPO" ENG-3001
rc="$(AP_AUTO_APPROVE=1 run_case)"
assert "autoC(a): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "autoC(a): implement act proceeded (auto-approved, no 'ap approve' needed)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"

# --- (b) same, but the ticket has FRESH feedback (not an approval) -> feedback
# wins: the wrapper replans instead of building.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3002 plan-review feedback='"please use a different table name"'
rc="$(AP_AUTO_APPROVE=1 run_case)"
assert "autoC(b): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "autoC(b): replan act proceeded (feedback wins over auto-approve)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--feedback' '$act_args'"
assert "autoC(b): NOT implement" bash -c \
  "[ -f '$act_args' ] && ! grep -q -- '--phase implement' '$act_args'"

# --- (c) auto-approve on + needs-input ticket with no answer -> no action at
# all (needs-input is NEVER auto-approved).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3003 needs-input phase_at_question='"implement"'
rc="$(AP_AUTO_APPROVE=1 run_case)"
assert "autoC(c): exit 0" [ "$rc" -eq 0 ]
assert "autoC(c): claude NOT called (needs-input never auto-approves)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (d) auto-approve OFF + plan-review with no approval signal -> no
# action, unchanged from today.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3004 plan-review
rc="$(run_case)"
assert "autoC(d): exit 0" [ "$rc" -eq 0 ]
assert "autoC(d): claude NOT called (auto-approve off, no approval)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (e) per-ticket auto_approve field with global OFF -> implement claimed.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-3005 plan-review auto_approve=true
seed_plan_file "$CASE_WORK_REPO" ENG-3005
rc="$(run_case)"
assert "autoC(e): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "autoC(e): implement act proceeded (per-ticket auto_approve, global off)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"

# =============================================================================
# Case 25: cwd discipline -- EVERY claude invocation must run from the work
# repo, because Claude Code discovers project skills from the cwd. run_case
# deliberately launches the cycle from /tmp; a cycle that does not cd would
# hand the act a directory with no .claude/skills, which fails OPEN (no
# skill, instant crash-shaped FAILED, nothing sensible logged).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-25 queued
rc="$(run_case)"
assert "case25: exit 0" [ "$rc" -eq 0 ]
for f in "$CASE_STUB_DIR"/claude_calls/*.pwd; do
  [[ -e "$f" ]] || continue
  assert "case25: $(basename "$f" .pwd) ran in the work repo" \
    [ "$(cat "$f")" = "$CASE_WORK_REPO" ]
done

# =============================================================================
# Case 26: every claude invocation must pin --model explicitly. Without it the
# act inherits ~/.claude/settings.json, so an interactive `/model` change
# silently reprices or downgrades the whole pipeline. Planning gets opus;
# implement/ship execute a settled plan and get sonnet. (There is no "poll"
# model anymore -- deciding never calls claude at all; its ledger row's model
# is the fixed literal "none", checked separately in case27 below.)
# =============================================================================

# assert_model <desc> <args-file> <expected-model>
# args files hold one argv entry per line, so --model must be followed by the
# model on the next line.
assert_model() {
  local desc="$1" args="$2" want="$3"
  if [[ ! -f "$args" ]]; then
    fail "$desc (no args file $args)"
    return
  fi
  local got
  got="$(grep -A1 -x -- '--model' "$args" | sed -n '2p')"
  assert "$desc (want --model $want, got '${got:-none}')" [ "$got" = "$want" ]
}

setup_case
seed_ticket "$CASE_AP_HOME" ENG-26 queued
rc="$(run_case)"
assert "case26: exit 0" [ "$rc" -eq 0 ]
assert_model "case26: plan" "$CASE_STUB_DIR/claude_calls/1.args" opus

# implement + ship in one cycle -> both sonnet
setup_case
seed_ticket "$CASE_AP_HOME" ENG-26B plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-26B
rc="$(AP_TEST_IMPLEMENT_STATUS=DONE run_case)"
assert "case26: implement cycle exit 0" [ "$rc" -eq 0 ]
assert_model "case26: implement" "$CASE_STUB_DIR/claude_calls/1.args" sonnet
assert_model "case26: ship" "$CASE_STUB_DIR/claude_calls/2.args" sonnet

# env override wins, so a hard ticket can be raised without changing the default
setup_case
seed_ticket "$CASE_AP_HOME" ENG-26C queued
rc="$(AP_PLAN_MODEL=fable run_case)"
assert "case26: override cycle exit 0" [ "$rc" -eq 0 ]
assert_model "case26: plan honours AP_PLAN_MODEL" "$CASE_STUB_DIR/claude_calls/1.args" fable

# =============================================================================
# Case 27: the ledger row records the model the act ran on. Without it the only
# way to learn what a run cost money on is to dig its transcript out of
# ~/.claude, which is how a pipeline on fable-5 went unnoticed for a day. The
# poll row itself always records the fixed literal model "none" and
# session_id "deterministic" -- merged in from the old suite's
# AP_POLL_MODE=deterministic case A, now that deterministic is the only mode.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-27 queued
rc="$(run_case)"
ledger="$(today_ledger)"
assert "case27: exit 0" [ "$rc" -eq 0 ]
assert "case27: poll row records model=none, session=deterministic; act row records the act model" bash -c \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$ledger') if l.strip()]
poll = [r for r in rows if r['phase'] == 'poll']
plan = [r for r in rows if r['phase'] == 'plan']
assert len(poll) == 1 and len(plan) == 1, rows
assert poll[0]['model'] == 'none', poll[0]
assert poll[0]['session_id'] == 'deterministic', poll[0]
assert plan[0]['model'] == 'opus', plan[0]
\""

# the override must reach the ledger too, not just the argv
setup_case
seed_ticket "$CASE_AP_HOME" ENG-27B queued
rc="$(AP_PLAN_MODEL=fable run_case)"
ledger="$(today_ledger)"
assert "case27: override cycle exit 0" [ "$rc" -eq 0 ]
assert "case27: ledger records the overridden model" bash -c \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$ledger') if l.strip()]
plan = [r for r in rows if r['phase'] == 'plan']
assert plan and plan[0]['model'] == 'fable', plan
\""

# =============================================================================
# Feature: N concurrent build slots. AP_BUILD_SLOTS=2 unless stated. Port
# formula: fe=5173+slot, be=8000+slot, slot 1..N -- so slot 1 never collides
# with the human's baseline pair (5173/8000).
# =============================================================================

PORTS_SEEN_FILE="$(mktemp)"
: >"$PORTS_SEEN_FILE"

# --- (1) slot 1 held -> implement proceeds and takes slot 2; its prompt
# carries --ports fe=5175,be=8002.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SLOTS1 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-SLOTS1
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; slot1_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=2 run_case)"
wait "$slot1_holder" 2>/dev/null
assert "slots(1): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "slots(1): implement act proceeded (slot 1 busy, slot 2 free)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
assert "slots(1): prompt carries --ports fe=5175,be=8002 (slot 2)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5175,be=8002' '$act_args'"
[[ -f "$act_args" ]] && grep -h -- '--ports fe=' "$act_args" >>"$PORTS_SEEN_FILE"

# --- (2) both slots held: an approved plan-review ticket does NOT get
# claimed (build lane full), while a queued ticket (plan lane free) still
# proceeds.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-2101 queued
seed_ticket "$CASE_AP_HOME" ENG-2102 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-2102
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; b1_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.build.2" 3; b2_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=2 run_case)"
wait "$b1_holder" "$b2_holder" 2>/dev/null
assert "slots(2): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "slots(2): plan act proceeded (plan lane free, build's approval skipped)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-2101' '$act_args'"
assert "slots(2): the approved-but-build-busy ticket was left untouched" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-2102 state)" = "plan-review" ]

# --- (3) neither slot held -> lowest free wins (slot 1); prompt carries
# --ports fe=5174,be=8001.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SLOTS3 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-SLOTS3
rc="$(AP_BUILD_SLOTS=2 run_case)"
assert "slots(3): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "slots(3): prompt carries --ports fe=5174,be=8001 (slot 1)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5174,be=8001' '$act_args'"
[[ -f "$act_args" ]] && grep -h -- '--ports fe=' "$act_args" >>"$PORTS_SEEN_FILE"

# --- (4) AP_BUILD_SLOTS=1 reproduces today's single-lane behavior exactly:
# one slot, assigned the same slot-1 ports as case (3) above.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SLOTS4 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-SLOTS4
rc="$(AP_BUILD_SLOTS=1 run_case)"
assert "slots(4): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "slots(4): AP_BUILD_SLOTS=1 -> implement proceeded on the one slot" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
assert "slots(4): AP_BUILD_SLOTS=1 -> same slot-1 ports as multi-slot case" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5174,be=8001' '$act_args'"
[[ -f "$act_args" ]] && grep -h -- '--ports fe=' "$act_args" >>"$PORTS_SEEN_FILE"

# --- (5) no slot, across every case above, is ever assigned the human's
# baseline pair (5173/8000).
assert "slots(5): at least 3 --ports lines were recorded to check" \
  bash -c "[ \"\$(wc -l < '$PORTS_SEEN_FILE')\" -ge 3 ]"
assert "slots(5): no recorded prompt ever assigns fe=5173" \
  bash -c "! grep -q 'fe=5173' '$PORTS_SEEN_FILE'"
assert "slots(5): no recorded prompt ever assigns be=8000" \
  bash -c "! grep -q 'be=8000' '$PORTS_SEEN_FILE'"
rm -f "$PORTS_SEEN_FILE"

# =============================================================================
# Feature: limit-aware auto-resume. AP_LIMIT_COOLDOWN_MIN default is 60
# (minutes); "old" mtimes below are set well past that.
# =============================================================================

# --- (a) reason usage-limit + old mtime -> cycle proceeds normally, and the
# pause file is gone.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-A plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-LIMIT-A
echo "usage-limit" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(run_case)"
assert "limit(a): exit 0" [ "$rc" -eq 0 ]
assert "limit(a): pause file cleared" [ ! -e "$CASE_AP_HOME/pause" ]
assert "limit(a): cycle proceeded (claude called)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]

# --- (b) reason usage-limit + fresh mtime -> still paused, no claude call.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-B queued
echo "usage-limit" >"$CASE_AP_HOME/pause"
rc="$(run_case)"
assert "limit(b): exit 0" [ "$rc" -eq 0 ]
assert "limit(b): still paused (fresh cooldown)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(b): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (c) reason failures + old mtime -> still paused (not a usage-limit
# reason, so cooldown never applies).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-C queued
echo "failures" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(run_case)"
assert "limit(c): exit 0" [ "$rc" -eq 0 ]
assert "limit(c): still paused (reason=failures never auto-clears)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(c): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (d) reason manual + old mtime -> still paused (manual pauses never
# auto-clear, regardless of age).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-D queued
echo "manual" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(run_case)"
assert "limit(d): exit 0" [ "$rc" -eq 0 ]
assert "limit(d): still paused (reason=manual never auto-clears)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(d): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (e) two consecutive act failures whose stderr matches a usage-limit
# signature -> the pause file the wrapper writes carries reason usage-limit.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-E1 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-LIMIT-E1
rc1="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="Claude usage limit reached" run_case)"
assert "limit(e): run1 exit 0" [ "$rc1" -eq 0 ]
assert "limit(e): run1 no pause yet" [ ! -e "$CASE_AP_HOME/pause" ]
seed_ticket "$CASE_AP_HOME" ENG-LIMIT-E2 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-LIMIT-E2
rc2="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="Claude usage limit reached" run_case)"
assert "limit(e): run2 exit 0" [ "$rc2" -eq 0 ]
assert "limit(e): pause file written after 2nd consecutive failure" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(e): pause reason is usage-limit" bash -c \
  "[ \"\$(head -n1 '$CASE_AP_HOME/pause')\" = 'usage-limit' ]"

# =============================================================================
# Feature: visible ship stage (`shipping` state). Set only while
# `/ship-work --headless` runs, swapped in by the WRAPPER (not the
# skill) right before invoking that phase, with its own ping.
# =============================================================================

# --- (a)/(c) implement DONE -> ship runs: the wrapper swaps the ticket
# building->shipping with its own "shipping:"-titled ping BEFORE the ship
# call, and the existing "ready to test" ping still fires on ship DONE.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SHIP-A plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-SHIP-A
rc="$(AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SHIP_STATUS=DONE run_case)"
assert "ship-label(a): exit 0" [ "$rc" -eq 0 ]
assert "ship-label(a): 2 claude calls (implement+ship)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]
assert "ship-label(a): notify title starts with 'shipping:'" bash -c \
  "grep -rl '^shipping: ENG-SHIP-A\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "ship-label(c): existing ready-to-test ping still fires on ship DONE" bash -c \
  "grep -rl 'ready to test' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# =============================================================================
# External-cause failures (Change 1): a FAILED act whose stderr matches the
# EXTERNAL signature is re-queued to the state its phase started from instead
# of dead-ending at `failed` -- see ap-cycle.sh's FAILED reconcile branch.
# =============================================================================

# --- (a) implement act, session-limit stderr -> plan-review (not failed),
# notify title says requeued.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-EXT-A plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-EXT-A
rc="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(a): exit 0" [ "$rc" -eq 0 ]
assert "external(a): ticket state -> plan-review (requeued, not failed)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-EXT-A state)" = "plan-review" ]
assert "external(a): history records the external-failure requeue" \
  ticket_history_has "$CASE_AP_HOME" ENG-EXT-A "external failure"
assert "external(a): notify title says requeued after external failure" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-A\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "external(a): notify does NOT use the old FAILED title" bash -c \
  "! grep -rl '^autopilot FAILED' '$CASE_STUB_DIR/notify_calls' >/dev/null 2>&1"
assert "external(a): notify includes the matched signature line" bash -c \
  "grep -rl 'session limit' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (b) same, for a plan act -> queued.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-EXT-B queued
rc="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(b): exit 0" [ "$rc" -eq 0 ]
assert "external(b): ticket state -> queued (requeued, not failed)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-EXT-B state)" = "queued" ]
assert "external(b): notify title says requeued" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-B\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (c) same, for a standalone ship act -> ship-pending.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-EXT-C ship-pending
seed_plan_file "$CASE_WORK_REPO" ENG-EXT-C
rc="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(c): exit 0" [ "$rc" -eq 0 ]
assert "external(c): ticket state -> ship-pending (requeued, not failed)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-EXT-C state)" = "ship-pending" ]
assert "external(c): notify title says requeued" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-C\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (d) regression: a non-external failure still gets `failed`, the old
# FAILED notify title, no requeue.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-EXT-D plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-EXT-D
rc="$(AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="assertion error: unexpected None" run_case)"
assert "external(d): exit 0" [ "$rc" -eq 0 ]
assert "external(d): ticket state -> failed" [ "$(ticket_field "$CASE_AP_HOME" ENG-EXT-D state)" = "failed" ]
assert "external(d): notify title is the old FAILED wording" bash -c \
  "grep -rl '^autopilot FAILED: ENG-EXT-D\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "external(d): notify title does NOT say requeued" bash -c \
  "! grep -rl 'requeued' '$CASE_STUB_DIR/notify_calls' >/dev/null 2>&1"

# =============================================================================
# Ship-only action, ship lane (Change: ship gets its OWN lane, not build).
# decide can emit action=ship for a ship-pending ticket; dispatched as
# /ship-work --headless --ports, on its own slot pool
# (lock.ship.1 .. lock.ship.N) and its own port base (5180+n/8010+n) --
# never the build lane's ports, never the human's baseline. `ship-work` never
# merges regardless of flags (there is no `--no-merge` flag anymore), so
# nothing needs disabling here. (This subsumes the old suite's
# AP_POLL_MODE=deterministic case B: a real decide claim of a ship-pending
# ticket, dispatching a real ship act -- there is no separate "deterministic
# mode" anymore, this IS the only mode.)
# =============================================================================

# --- (e) action=ship dispatches /ship-work with --ports from
# the ship base, slot 1 (fe=5181,be=8011).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SHIP-ONLY ship-pending
seed_plan_file "$CASE_WORK_REPO" ENG-SHIP-ONLY
rc="$(AP_TEST_SHIP_STATUS=DONE run_case)"
assert "shipOnly(e): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "shipOnly(e): act call recorded" [ -f "$act_args" ]
assert "shipOnly(e): dispatches /ship-work" bash -c \
  "[ -f '$act_args' ] && grep -q 'ship-work' '$act_args'"
assert "shipOnly(e): never passes a stale --no-merge flag" bash -c \
  "[ -f '$act_args' ] && ! grep -q -- '--no-merge' '$act_args'"
assert "shipOnly(e): --ports from the ship base, slot 1 (fe=5181,be=8011)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5181,be=8011' '$act_args'"
assert "shipOnly(e): never assigns fe=5173 nor be=8000 (human baseline)" bash -c \
  "[ -f '$act_args' ] && ! grep -q 'fe=5173' '$act_args' && ! grep -q 'be=8000' '$act_args'"
assert "shipOnly(e): ledger has a ship phase row" bash -c \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$(today_ledger)') if l.strip()]
assert any(r['phase'] == 'ship' for r in rows), rows
\""
assert "shipOnly(e): ap-decide.py itself (real, unstubbed) claimed ship-pending -> shipping before the act ran" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-SHIP-ONLY state)" = "shipping" ]

# --- (h) ship lane slot mechanics: ship slot 1 held -> a second standalone
# ship takes slot 2 (fe=5182,be=8012), still never a build slot's pair or the
# human baseline.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-SHIP-SLOT2 ship-pending
seed_plan_file "$CASE_WORK_REPO" ENG-SHIP-SLOT2
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; ship1_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_SHIP_SLOTS=2 AP_TEST_SHIP_STATUS=DONE run_case)"
wait "$ship1_holder" 2>/dev/null
assert "shipOnly(h): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "shipOnly(h): took ship slot 2 (fe=5182,be=8012)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5182,be=8012' '$act_args'"
assert "shipOnly(h): never assigns fe=5173" bash -c "[ -f '$act_args' ] && ! grep -q 'fe=5173' '$act_args'"
assert "shipOnly(h): never assigns be=8000" bash -c "[ -f '$act_args' ] && ! grep -q 'be=8000' '$act_args'"

# --- (i) implement->ship CHAIN regression: an implement whose status comes
# back DONE still chains into ship in the SAME cycle, and that trailing ship
# call KEEPS the build slot's own ports (fe=5174,be=8001 for slot 1) --
# NEVER the ship lane's base. This is the non-obvious part of the feature:
# only a STANDALONE ship (action=ship, from a ship-pending ticket) uses the
# ship lane; the chain never re-enters the case statement that assigns it.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-CHAIN plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-CHAIN
rc="$(AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SHIP_STATUS=DONE run_case)"
assert "chain(i): exit 0" [ "$rc" -eq 0 ]
assert "chain(i): 2 claude calls (implement+ship)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]
implement_args="$CASE_STUB_DIR/claude_calls/1.args"
ship_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "chain(i): implement call carries build slot 1 ports" bash -c \
  "[ -f '$implement_args' ] && grep -q -- '--ports fe=5174,be=8001' '$implement_args'"
assert "chain(i): chained ship call carries the SAME build slot ports, not the ship base" bash -c \
  "[ -f '$ship_args' ] && grep -q -- '--ports fe=5174,be=8001' '$ship_args' && ! grep -q 'fe=5181' '$ship_args'"

# =============================================================================
# Ship-pending wake now belongs to the SHIP lane, not build (the bug this
# feature fixes -- ship-pending must not queue behind a full build lane).
# =============================================================================

# --- (a) all build slots busy + a ship-pending ticket -> decide still claims
# and dispatches ship (proves ship no longer blocks on build).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-704 ship-pending
seed_plan_file "$CASE_WORK_REPO" ENG-704
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; a_build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_TEST_SHIP_STATUS=DONE run_case)"
wait "$a_build_holder" 2>/dev/null
assert "shipLane(a): exit 0" [ "$rc" -eq 0 ]
assert "shipLane(a): decide ran despite build lane full" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "shipLane(a): dispatched ship" bash -c \
  "[ -f '$act_args' ] && grep -q 'ship-work' '$act_args'"

# --- (b) all ship slots busy + a ship-pending ticket -> the ticket is left
# untouched (not claimed, re-fires once free) while a plan-lane ticket
# proceeds independently.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-705 ship-pending
seed_plan_file "$CASE_WORK_REPO" ENG-705
seed_ticket "$CASE_AP_HOME" ENG-706 queued
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; b_ship_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_SHIP_SLOTS=1 run_case)"
wait "$b_ship_holder" 2>/dev/null
assert "shipLane(b): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "shipLane(b): plan act proceeded (plan lane free, ship-pending skipped)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-706' '$act_args'"
assert "shipLane(b): ship-pending ticket NOT claimed (re-fires once free)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-705 state)" = "ship-pending" ]

# =============================================================================
# Case: per-issue lock -- the lane locks cap concurrency but do NOT stop the
# SAME issue entering two different slots. Claiming is ap-decide.py's job (a
# state write), and this lock makes the claim enforced rather than advisory,
# so a duplicate-dispatch race cannot recur however the decider behaves.
# Observed live on ENG-1308, 2026-08-13: two polls both emitted implement for
# the same issue a minute apart.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-77 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-77
# Simulate a cycle already acting on ENG-77 by holding its per-issue lock.
# ap-decide.py's own claim write (plan-review -> building) still happens --
# it has no notion of the issue lock -- but ap-cycle.sh's act-dispatch stage
# below refuses to start a second act on it.
hold_lane_lock "$CASE_AP_HOME/lock.issue.ENG-77" 3
rc="$(run_case)"
kill "$LANE_HOLDER_PID" 2>/dev/null; wait "$LANE_HOLDER_PID" 2>/dev/null
assert "issueLock: exit 0" [ "$rc" -eq 0 ]
assert "issueLock: NO act was dispatched for the in-flight issue" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
# Control: with the lock free, the same ticket DOES dispatch its act.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-77 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-77
rc="$(run_case)"
assert "issueLock(control): lock free -> act dispatched" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]

# =============================================================================
# Case: the wrapper writes status.json's `question` onto the queue ticket AND
# pings -- a SEPARATE write from the skill's own marked reasoning, so it must
# reach the ticket the owner actually reads (`ap sessions`), not just a log.
# ENG-1308 burned ~$17 in five re-plans on the old inbox-comment equivalent of
# this echo looping back on itself; there is no comment channel to loop on
# anymore, but the ticket write itself is still worth its own direct check.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-78 plan-review pending_approval=true
seed_plan_file "$CASE_WORK_REPO" ENG-78
rc="$(AP_TEST_IMPLEMENT_STATUS=NEEDS_HUMAN AP_TEST_QUESTION="which table should this use" run_case)"
assert "questionEcho: exit 0" [ "$rc" -eq 0 ]
assert "questionEcho: the ticket's question field carries the text" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-78 question)" = "which table should this use" ]
assert "questionEcho: history is marked as a needs-input event" \
  ticket_history_has "$CASE_AP_HOME" ENG-78 "needs input"

# =============================================================================
# Persistent mode (AP_ACT_LAUNCH_MODE=persistent): parking and window
# lifecycle, against the fake tmux in make_stub_dir. What real tmux/claude
# interaction actually does (does a resumed session pick up an injected
# reply) was verified live against a real tmux session, not re-tested here
# -- these cases only check ap-cycle.sh/ap-resume.sh's own bookkeeping: does a
# NEEDS_HUMAN act write the parked registry and leave its window up; does a
# DONE/FAILED act tear its window down; does a parked ticket get skipped by
# ap-decide.py's tier3 parked-exclusion end-to-end through ap-cycle.sh.
# =============================================================================

# --- persist(A): NEEDS_HUMAN parks -- registry written, window left alive --
setup_case
export AP_ACT_LAUNCH_MODE=persistent
export AP_TMUX_SESSION=ap-test-should-never-be-real
export AP_TEST_ACT_STATUS=NEEDS_HUMAN
seed_ticket "$CASE_AP_HOME" ENG-PA queued
rc="$(run_case)"
assert "persist(A): exit 0" [ "$rc" -eq 0 ]
assert "persist(A): parked registry written, keyed by ENG-id filename" \
  [ -f "$CASE_AP_HOME/parked/ENG-PA.json" ]
assert "persist(A): registry records the right issue/phase/lane" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/ENG-PA.json')); assert d['issue']=='ENG-PA' and d['phase']=='plan' and d['lane']=='plan', d\""
assert "persist(A): registry records the question" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/ENG-PA.json')); assert d.get('question'), d\""
assert "persist(A): window was NOT torn down (still tracked by fake tmux)" bash -c \
  "ls '$CASE_AP_HOME/.test-tmux/'act_plan_ENG-PA_plan.meta >/dev/null 2>&1"
unset AP_ACT_LAUNCH_MODE AP_TMUX_SESSION AP_TEST_ACT_STATUS

# --- persist(B): DONE tears the window down ---------------------------------
setup_case
export AP_ACT_LAUNCH_MODE=persistent
export AP_TMUX_SESSION=ap-test-should-never-be-real
seed_ticket "$CASE_AP_HOME" ENG-PB queued
rc="$(run_case)"
assert "persist(B): exit 0" [ "$rc" -eq 0 ]
assert "persist(B): no parked registry (DONE, not NEEDS_HUMAN)" \
  bash -c "[ ! -f '$CASE_AP_HOME/parked/ENG-PB.json' ]"
assert "persist(B): window WAS torn down" bash -c \
  "[ ! -f '$CASE_AP_HOME/.test-tmux/act_plan_ENG-PB_plan.meta' ]"
unset AP_ACT_LAUNCH_MODE AP_TMUX_SESSION

# --- persist(C): a parked ticket is skipped by ap-decide.py's tier3, end to
# end through ap-cycle.sh -- fresh feedback on a needs-input ticket that ALSO
# has a live parked-registry entry must not be treated as a normal replan
# signal (is_parked() excludes it; scan_parked_replies, not a fresh
# claim/dispatch, is what's supposed to relay it -- exercised separately in
# persist(D) below).
setup_case
seed_ticket "$CASE_AP_HOME" ENG-PC needs-input feedback='"go with option B"' phase_at_question='"implement"'
mkdir -p "$CASE_AP_HOME/parked"
echo '{"issue":"ENG-PC"}' >"$CASE_AP_HOME/parked/ENG-PC.json"
rc="$(run_case)"
assert "persist(C): exit 0" [ "$rc" -eq 0 ]
assert "persist(C): claude was never invoked at all (parked ticket's feedback did not get claimed)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "persist(C): ticket left exactly as it was (still needs-input, feedback untouched)" \
  bash -c '[ "$(ticket_field "$1" ENG-PC state)" = "needs-input" ] &&
           [ "$(ticket_field "$1" ENG-PC feedback)" = "go with option B" ]' _ "$CASE_AP_HOME"

# --- persist(D): ap-resume.sh must NOT mark a reply consumed when it bails
# on "no free slot" -- this is a real bug that was caught and fixed while
# testing this feature live: scan_parked_replies used to mark
# last_relayed_feedback_seq BEFORE knowing whether ap-resume.sh would actually
# inject, so a busy lane silently dropped the reply forever instead of
# retrying (the same "no free slot -> retry next cycle" shape every other
# busy-lane skip in this file already has). Invoke ap-resume.sh directly
# (not through the backgrounded scan_parked_replies path, to avoid timing
# flakiness) with both build slots deliberately held busy.
setup_case
mkdir -p "$CASE_AP_HOME/parked" "$CASE_AP_HOME/.test-tmux"
cat >"$CASE_AP_HOME/parked/ENG-PD.json" <<'EOF'
{"issue": "ENG-PD", "phase": "implement", "lane": "build",
 "window": "act_build_1_ENG-PD_implement", "run_dir": "/tmp/does-not-matter",
 "plan_path": "docs/plans/x.md", "ports": {"fe": "5174", "be": "8001"},
 "parked_at": "2026-08-14T00:00:00Z", "question": "which approach?",
 "last_relayed_feedback_seq": 0}
EOF
# Fake tmux window "alive" so ap-resume.sh gets past the window_alive gate.
echo "99999" >"$CASE_AP_HOME/.test-tmux/act_build_1_ENG-PD_implement.meta"
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; slot1_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.build.2" 3; slot2_holder="$LANE_HOLDER_PID"
AP_HOME="$CASE_AP_HOME" AP_WORK_REPO="$CASE_WORK_REPO" AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
AP_TMUX_SESSION=ap-test-should-never-be-real AP_BUILD_SLOTS=2 \
PATH="$CASE_STUB_DIR:$PATH" \
  bash "$BIN_DIR/ap-resume.sh" ENG-PD "go with option B" 1 \
  >"$CASE_AP_HOME/resume-d.stdout.log" 2>"$CASE_AP_HOME/resume-d.stderr.log"
resume_rc=$?
wait "$slot1_holder" "$slot2_holder" 2>/dev/null
assert "persist(D): ap-resume.sh exits 0 even when it bails" [ "$resume_rc" -eq 0 ]
assert "persist(D): registry entry still exists (not dropped)" \
  [ -f "$CASE_AP_HOME/parked/ENG-PD.json" ]
assert "persist(D): last_relayed_feedback_seq was NOT advanced (feedback_seq 1 not consumed)" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/ENG-PD.json')); assert d.get('last_relayed_feedback_seq') == 0, d\""
assert "persist(D): cycle.log records the 'no free slot' bail reason" \
  bash -c "grep -q 'no free slot' '$CASE_AP_HOME/logs/cycle.log'"

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
