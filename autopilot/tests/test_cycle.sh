#!/usr/bin/env bash
# Self-contained test harness for ap-cycle.sh. No network, no real claude/gh.
# Stubs claude/gh/ap-notify.sh on PATH, drives them via env vars, and asserts
# on their recorded argv + the ledger they cause ap-cycle.sh to write.
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

# --- stub bin dir ------------------------------------------------------------
# Written once; behavior is driven per-test by env vars read at call time.

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

is_poll=false
for a in "$@"; do
  [[ "$a" == "--json-schema" ]] && is_poll=true
done

if $is_poll; then
  if [[ "${AP_TEST_POLL_CRASH:-}" == "1" ]]; then
    echo "stub: poll crashed" >&2
    exit 1
  fi
  action="${AP_TEST_POLL_ACTION:-none}"
  issue="${AP_TEST_POLL_ISSUE:-}"
  planpath="${AP_TEST_POLL_PLANPATH:-}"
  inbox="${AP_TEST_POLL_INBOX:-}"
  feedback="${AP_TEST_POLL_FEEDBACK:-}"
  python3 - "$action" "$issue" "$planpath" "$inbox" "$feedback" <<'PY'
import json, sys
action, issue, planpath, inbox, feedback = sys.argv[1:6]
d = {"action": action}
if issue: d["issue"] = issue
if planpath: d["planPath"] = planpath
if inbox: d["inboxIssue"] = int(inbox)
if feedback: d["feedback"] = feedback
print(json.dumps({"structured_output": d, "total_cost_usd": 0.01, "session_id": "poll-session"}))
PY
  exit 0
fi

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
# this act's own issue (AP_TEST_POLL_ISSUE) so adhoc adoption's .issue match
# succeeds by default; AP_TEST_ADHOC_STATUS_ISSUE overrides it to simulate a
# DIFFERENT concurrent act's leftover file (a mismatch the wrapper must not
# adopt).
status_issue="${AP_TEST_ADHOC_STATUS_ISSUE:-${AP_TEST_POLL_ISSUE:-}}"
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

  cat >"$dir/gh" <<'STUB_GH'
#!/usr/bin/env bash
calls_dir="${AP_TEST_STUB_DIR}/gh_calls"
mkdir -p "$calls_dir"
n=$(find "$calls_dir" -maxdepth 1 -name '*.args' | wc -l)
n=$((n + 1))
printf '%s\n' "$@" >"$calls_dir/$n.args"
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  echo "stub-gh-token"
  exit 0
fi
# Pre-scan gate: `gh issue list --repo ... --label <label> --json number` for
# the plan-review/needs-input comment triggers, or `gh issue list --repo ...
# --json number,labels` (no --label) for the new-intake trigger.
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  label=""
  json_fields=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "--label" ]] && label="$a"
    [[ "$prev" == "--json" ]] && json_fields="$a"
    prev="$a"
  done
  if [[ -z "$label" && "$json_fields" == *labels* ]]; then
    echo "${AP_TEST_GH_ISSUES_ALL_OPEN:-[]}"
    exit 0
  fi
  case "$label" in
    plan-review) echo "${AP_TEST_GH_ISSUES_PLAN_REVIEW:-[]}" ;;
    needs-input) echo "${AP_TEST_GH_ISSUES_NEEDS_INPUT:-[]}" ;;
    ship-pending) echo "${AP_TEST_GH_ISSUES_SHIP_PENDING:-[]}" ;;
    *) echo "[]" ;;
  esac
  exit 0
fi
# Pre-scan gate: `gh api repos/OWNER/REPO/issues/<n>/comments?...`
if [[ "${1:-}" == "api" ]]; then
  path="${2:-}"
  num="$(printf '%s' "$path" | sed -n 's#.*/issues/\([0-9][0-9]*\)/comments.*#\1#p')"
  var="AP_TEST_GH_COMMENT_${num}"
  echo "${!var:-[]}"
  exit 0
fi
# Change C reconcile-time label check: `gh issue view <n> --repo ... --json labels`
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  num="${3:-}"
  var="AP_TEST_GH_ISSUE_VIEW_${num}"
  default_labels='{"labels":[]}'
  echo "${!var:-$default_labels}"
  exit 0
fi
exit 0
STUB_GH

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

  chmod +x "$dir/claude" "$dir/gh" "$dir/ap-notify.sh" "$dir/tmux"
}

# --- per-case fixture --------------------------------------------------------

AP_TEST_VARS=(
  AP_TEST_POLL_ACTION AP_TEST_POLL_ISSUE AP_TEST_POLL_PLANPATH AP_TEST_POLL_INBOX
  AP_TEST_POLL_FEEDBACK AP_TEST_ACT_STATUS AP_TEST_IMPLEMENT_STATUS
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
  unset GITHUB_PERSONAL_ACCESS_TOKEN NTFY_TOPIC SLACK_WEBHOOK_URL
  # Pre-scan gate knobs: default to no-signal-but-fallback-wakes (no
  # scan-state -> stale -> wake), matching the pre-gate behavior every
  # pre-existing case below already assumes (claude poll always runs).
  unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_ISSUES_NEEDS_INPUT \
    AP_TEST_GH_ISSUES_ALL_OPEN AP_TEST_GH_ISSUES_SHIP_PENDING AP_TEST_POLL_CRASH \
    AP_FULL_POLL_INTERVAL_MIN AP_BUILD_SLOTS AP_SHIP_SLOTS AP_LIMIT_COOLDOWN_MIN
}

run_case() {
  # runs ap-cycle.sh with the current fixture; stdout/stderr discarded to log.
  # Deliberately launched from a directory that is NOT the work repo (the
  # subshell cd) so the cwd-discipline case can catch a regression of the bug
  # where the poll ran in the inherited cwd and therefore found no skills.
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
# Case 1: pause file -> exits 0, claude never called
# =============================================================================
setup_case
touch "$CASE_AP_HOME/pause"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-1 run_case)"
assert "case1: pause -> exit 0" [ "$rc" -eq 0 ]
assert "case1: pause -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 2: lock.poll held by a slow first run -> second invocation exits
# without calling claude (lock.poll serializes the decision path; a single
# $AP_HOME/lock no longer exists)
# =============================================================================
setup_case
(
  exec 9>"$CASE_AP_HOME/lock.poll" 2>/dev/null || { mkdir -p "$CASE_AP_HOME"; exec 9>"$CASE_AP_HOME/lock.poll"; }
  flock 9
  sleep 3
) &
holder_pid=$!
sleep 0.4
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2 run_case)"
wait "$holder_pid" 2>/dev/null
assert "case2: locked -> exit 0" [ "$rc" -eq 0 ]
assert "case2: locked -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 3: ledger pre-seeded at the issue cap -> stage 2 never runs
# =============================================================================
setup_case
mkdir -p "$CASE_AP_HOME/runs"
seed_ledger="$CASE_AP_HOME/runs/$(date -u +%F).jsonl"
echo '{"ts":"2026-01-01T00:00:00Z","issue":"ENG-OLD","phase":"implement","status":"DONE","cost":1.0,"session_id":"s1"}' >"$seed_ledger"
rc="$(AP_MAX_ISSUES_PER_DAY=1 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-3 AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
assert "case3: at cap -> exit 0" [ "$rc" -eq 0 ]
assert "case3: at cap -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 4: poll returns plan -> plan invocation has --settings <path> and
# "--headless" in the prompt arg
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-4 run_case)"
assert "case4: exit 0" [ "$rc" -eq 0 ]
assert "case4: two claude calls (poll + plan)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
if [[ -f "$poll_args" ]]; then
  assert "case4: poll call has --settings" bash -c "grep -qx -- '--settings' '$poll_args'"
  assert "case4: poll call settings path is absolute autopilot.json" bash -c "grep -q '/autopilot/settings/autopilot.json$' '$poll_args'"
else
  fail "case4: poll call has --settings (no 1.args file)"
  fail "case4: poll call settings path is absolute autopilot.json"
fi
act_args="$CASE_STUB_DIR/claude_calls/2.args"
if [[ -f "$act_args" ]]; then
  assert "case4: act call has --settings" bash -c "grep -qx -- '--settings' '$act_args'"
  assert "case4: act call settings path is absolute autopilot.json" bash -c "grep -q '/autopilot/settings/autopilot.json$' '$act_args'"
  assert "case4: act call prompt has --headless" bash -c "grep -q -- '--headless' '$act_args'"
  assert "case4: act call prompt has --run-dir with the run path" bash -c "grep -q -- '--run-dir /' '$act_args'"
  assert "case4: act call prompt targets implement-issue --phase plan ENG-4" bash -c "grep -q 'implement-issue --phase plan ENG-4' '$act_args'"
  assert "case4: plan DONE pings the owner (plan ready for review)" bash -c \
    "grep -rl 'plan ready for review' '$CASE_STUB_DIR/notify_calls' >/dev/null"
else
  fail "case4: act call has --settings (no 2.args file)"
  fail "case4: act call settings path is absolute autopilot.json"
  fail "case4: act call prompt has --headless"
  fail "case4: act call prompt targets implement-issue --phase plan ENG-4"
fi

# =============================================================================
# Case 5: status NEEDS_HUMAN with question -> notify stub called with inbox URL
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-5 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=42 AP_TEST_ACT_STATUS=NEEDS_HUMAN AP_TEST_QUESTION="which project?" run_case)"
assert "case5: exit 0" [ "$rc" -eq 0 ]
assert "case5: notify called" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 1 ]
assert "case5: notify includes inbox issue URL" bash -c \
  "grep -rl 'issues/42' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case5: notify includes question text" bash -c \
  "grep -rl 'which project?' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# =============================================================================
# Case 6: status file EXISTS with FAILED -> gh stub called (label swap +
# comment) AND notify called (wrapper authority over written-FAILED)
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-6 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=7 AP_TEST_ACT_STATUS=FAILED run_case)"
assert "case6: exit 0" [ "$rc" -eq 0 ]
assert "case6: gh issue edit (label swap) called" bash -c \
  "grep -rl '^issue$' '$CASE_STUB_DIR/gh_calls' | xargs -r grep -l '^edit$' >/dev/null 2>&1 || grep -rl 'add-label' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "case6: gh issue comment called" bash -c "grep -rl '^comment$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "case6: notify called" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 1 ]

# =============================================================================
# Case 7: no status.json -> same failed handling; a second consecutive
# failure -> pause file exists + notify
# Pre-scan gate adaptation: both runs share CASE_AP_HOME, and run1's
# successful poll would refresh last_poll_ts, so the fallback leg alone
# wouldn't wake run2. Give each run its own unseen inbox comment so both
# cycles wake on the inbox leg regardless of the fallback timer.
# =============================================================================
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":700}]'
export AP_TEST_GH_COMMENT_700='[{"id":1,"user":{"login":"haroun"},"body":"go"}]'
rc1="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-7 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=9 AP_TEST_ACT_MODE=no_status run_case)"
assert "case7: run1 exit 0" [ "$rc1" -eq 0 ]
assert "case7: run1 no pause yet" [ ! -e "$CASE_AP_HOME/pause" ]
assert "case7: run1 fail_count=1" bash -c "[ \"\$(cat '$CASE_AP_HOME/fail_count')\" = 1 ]"
export AP_TEST_GH_COMMENT_700='[{"id":2,"user":{"login":"haroun"},"body":"go"}]'
rc2="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-7b AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=9 AP_TEST_ACT_MODE=no_status run_case)"
assert "case7: run2 exit 0" [ "$rc2" -eq 0 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_700
assert "case7: run2 (2nd consecutive failure) -> pause file exists" [ -e "$CASE_AP_HOME/pause" ]
assert "case7: run2 -> notify called (failed + auto-paused)" [ "$(count_files "$CASE_STUB_DIR/notify_calls")" -ge 3 ]

# =============================================================================
# Case 8: every scenario appends exactly one valid JSON line per claude call
# to the ledger
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-8 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SHIP_STATUS=DONE run_case)"
ledger="$(today_ledger)"
assert "case8: exit 0" [ "$rc" -eq 0 ]
assert "case8: ledger exists" [ -f "$ledger" ]
assert "case8: ledger has 3 lines (poll+implement+ship)" bash -c "[ \"\$(wc -l < '$ledger')\" -eq 3 ]"
assert "case8: ledger is all valid JSON" ledger_all_valid_json "$ledger"
assert "case8: 3 claude calls were made" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 3 ]

# Re-check ledger validity for a couple of the earlier single-call cases too.
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-8b run_case)"
ledger="$(today_ledger)"
assert "case8b: exit 0" [ "$rc" -eq 0 ]
assert "case8b: ledger has 2 lines (poll+plan)" bash -c "[ \"\$(wc -l < '$ledger')\" -eq 2 ]"
assert "case8b: ledger is all valid JSON" ledger_all_valid_json "$ledger"

# =============================================================================
# Case 9: symlink layout (defect 1) — ap-cycle.sh invoked through a flat
# symlinked bin dir, mirroring scripts/install-autopilot.sh's real layout
# (autopilot/bin/* symlinked into ~/.local/bin). The --settings argument to
# the act-stage claude call must resolve to the real, existing
# autopilot/settings/autopilot.json — not a path relative to the symlink's
# own directory (which pre-fix would be a nonexistent ~/.local/settings/...).
# =============================================================================
setup_case
SYMLINK_BIN="$(mktemp -d)"
for f in ap ap-cycle.sh ap-brief.sh ap-env.sh ap-notify.sh; do
  ln -s "$BIN_DIR/$f" "$SYMLINK_BIN/$f"
done
rc="$(
  AP_HOME="$CASE_AP_HOME" \
  AP_WORK_REPO="$CASE_WORK_REPO" \
  AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
  AP_ACT_LAUNCH_MODE=oneshot \
  AP_TMUX_SESSION=ap-test-should-never-be-real \
  AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-SYM \
  PATH="$CASE_STUB_DIR:$PATH" \
    bash "$SYMLINK_BIN/ap-cycle.sh" >"$CASE_AP_HOME/stdout.log" 2>"$CASE_AP_HOME/stderr.log"
  echo $?
)"
assert "case9: symlinked ap-cycle.sh exits 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
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
utc_date="$(date -u +%F)"
tz_candidate="Etc/GMT+12"
tz_date="$(TZ="$tz_candidate" date +%F)"
if [[ "$tz_date" == "$utc_date" ]]; then
  tz_candidate="Etc/GMT-12"
  tz_date="$(TZ="$tz_candidate" date +%F)"
fi
rc="$(AP_TZ="$tz_candidate" AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-TZ \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
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
# Case 13: FAILED reconcile body (defect 3) — the inbox comment / notify body
# must include the acting claude call's stderr tail (e.g. a permission-denial
# string) labeled separately from the stdout tail, not stdout alone.
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-13 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=13 AP_TEST_ACT_STATUS=FAILED \
  AP_TEST_ACT_STDERR="permission denied: Bash(rm -rf /tmp/x)" run_case)"
assert "case13: exit 0" [ "$rc" -eq 0 ]
assert "case13: gh issue comment includes stderr denial text" bash -c \
  "grep -rl 'permission denied' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "case13: gh issue comment labels the STDERR section" bash -c \
  "grep -rl 'STDERR' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "case13: gh issue comment labels the STDOUT section" bash -c \
  "grep -rl 'STDOUT' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "case13: notify body includes stderr denial text" bash -c \
  "grep -rl 'permission denied' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# =============================================================================
# Case 14 (bug 1): stale status.json across phases. implement writes DONE,
# ship exits non-zero WITHOUT writing its own status.json. The leftover
# implement status.json must NOT be read as the ship result -- ship must be
# treated as FAILED (failed notify, no "ready to test"), and the ledger row
# for the ship phase must record FAILED, not DONE.
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-14 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SKIP_STATUS_SHIP=1 AP_TEST_EXIT_CODE_SHIP=1 run_case)"
ledger="$(today_ledger)"
assert "case14: exit 0" [ "$rc" -eq 0 ]
assert "case14: 3 claude calls (poll+implement+ship)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 3 ]
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
# REAL ap-notify.sh (not the stub) against a fake curl on PATH.
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
rc="$(AP_TEST_POLL_ACTION=replan AP_TEST_POLL_ISSUE=ENG-16 AP_TEST_POLL_FEEDBACK="$raw_feedback" run_case)"
assert "case16: exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
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
# Case 17 (pre-scan gate): idle cycle -- no labeled inbox issues, no new
# intake, and a fresh last_poll_ts (so the fallback timer isn't stale either)
# -> claude is never called at all, no ledger row is written, exit 0.
# Fails pre-gate: the poll always ran unconditionally, so this would call
# claude and write a ledger row regardless of any of this fixture.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-IDLE run_case)"
assert "case17: idle -> exit 0" [ "$rc" -eq 0 ]
assert "case17: idle -> claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "case17: idle -> no ledger file written" [ ! -f "$(today_ledger)" ]

# =============================================================================
# Case 18 (pre-scan gate): inbox wake -- a plan-review issue whose newest
# comment ("go", no agent marker) is unseen wakes the poll; scan-state
# records that comment id after the cycle; an identical second cycle (same
# comment, now seen) does not wake again.
# Fails pre-gate: no scan-state tracking exists, so the "identical second
# cycle does not wake" assertion (count stays at 1) would fail -- the poll
# always ran on every cycle.
# =============================================================================
setup_case
# Ascending order, as the real per-issue comments endpoint returns (it
# ignores sort/direction): the agent's plan post first, the owner's go LAST.
# Regression for the live bug where element 0 (the marker post) was read as
# "newest" and suppressed the wake forever.
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":101}]'
export AP_TEST_GH_COMMENT_101='[{"id":550,"user":{"login":"haroun"},"body":"Plan file: /x/plan.md\nthe plan"},{"id":555,"user":{"login":"haroun"},"body":"go"}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case18: inbox wake -> exit 0" [ "$rc" -eq 0 ]
assert "case18: inbox wake -> claude called once (poll)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
assert "case18: scan-state records comment id 555 for issue 101" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert d['inbox'].get('101') == 555, d\""
rc2="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case18: second identical cycle -> exit 0" [ "$rc2" -eq 0 ]
assert "case18: second identical cycle -> claude NOT called again" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_101

# =============================================================================
# Case 19 (pre-scan gate): marker suppression -- a needs-input issue whose
# newest comment's first line starts with the agent marker `Phase:` is
# agent-authored, not human input, so it must NOT wake the poll. A fresh
# last_poll_ts rules out the fallback leg as the reason.
# Fails pre-gate: the poll always ran regardless, so "claude NOT called"
# would fail.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_NEEDS_INPUT='[{"number":202}]'
export AP_TEST_GH_COMMENT_202='[{"id":9,"user":{"login":"agent"},"body":"Phase: plan\nsome details"}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case19: marker suppression -> exit 0" [ "$rc" -eq 0 ]
assert "case19: marker suppression -> claude NOT called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_NEEDS_INPUT AP_TEST_GH_COMMENT_202

# =============================================================================
# Case 20 (pre-scan gate): new-intake wake -- an open inbox issue carrying the
# `Queued` label and none of the six state labels (an owner delegation) wakes
# the poll; scan-state records it as seen after the cycle; an identical
# second cycle (same issue, now seen) does not wake again.
# Fails pre-gate: no new-intake leg (nor any Linear leg -- that's been
# removed) exists at all; more concretely, the "second cycle does not wake
# again" assertion would fail since the poll always ran on every cycle.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":501,"labels":[{"name":"Queued"}]}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case20: new-intake wake -> exit 0" [ "$rc" -eq 0 ]
assert "case20: new-intake wake -> claude called once (poll)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
assert "case20: scan-state new_intake_seen includes 501" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '501' in d['new_intake_seen'], d\""
rc2="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case20: second identical cycle -> exit 0" [ "$rc2" -eq 0 ]
assert "case20: second identical cycle -> claude NOT called again" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
unset AP_TEST_GH_ISSUES_ALL_OPEN

# =============================================================================
# Case 20b (Queued intake, Change A): a genuinely unlabeled open inbox issue
# is a DRAFT -- the pipeline ignores it entirely, never wakes the poll.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":601,"labels":[]}]'
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-601 run_case)"
assert "case20b: unlabeled draft -> exit 0" [ "$rc" -eq 0 ]
assert "case20b: unlabeled draft -> claude NEVER called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "case20b: unlabeled draft -> not recorded as seen (never considered intake at all)" bash -c \
  "[ ! -f '$CASE_AP_HOME/scan-state.json' ] || python3 -c \"
import json
with open('$CASE_AP_HOME/scan-state.json') as f:
    d = json.load(f)
assert '601' not in d.get('new_intake_seen', []), d
\""
unset AP_TEST_GH_ISSUES_ALL_OPEN

# =============================================================================
# Case 21 (pre-scan gate): fallback full poll -- a stale last_poll_ts (more
# than AP_FULL_POLL_INTERVAL_MIN minutes old) wakes the poll; a fresh
# last_poll_ts does not.
# Fails pre-gate: the "fresh timestamp -> claude NOT called" assertion would
# fail, since the poll always ran regardless of any timestamp.
# =============================================================================
setup_case
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"2020-01-01T00:00:00Z"}' >"$CASE_AP_HOME/scan-state.json"
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case21: fallback stale -> exit 0" [ "$rc" -eq 0 ]
assert "case21: fallback stale -> claude called once (poll)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]

setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "case21: fallback fresh -> exit 0" [ "$rc" -eq 0 ]
assert "case21: fallback fresh -> claude NOT called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 21b (pre-scan gate): AP_FULL_POLL_INTERVAL_MIN=0 disables the fallback
# leg entirely -- even a very stale last_poll_ts must NOT wake the poll (the
# scan legs above remain the only wake source).
# Fails pre-gate: the fallback leg (and the 0-disables-it rule) doesn't
# exist at all, so the poll would always run regardless.
# =============================================================================
setup_case
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"2020-01-01T00:00:00Z"}' >"$CASE_AP_HOME/scan-state.json"
rc="$(AP_FULL_POLL_INTERVAL_MIN=0 AP_TEST_POLL_ACTION=none run_case)"
assert "case21b: fallback disabled (0) -> exit 0" [ "$rc" -eq 0 ]
assert "case21b: fallback disabled (0) -> claude NOT called despite stale ts" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# =============================================================================
# Case 22 (pre-scan gate): crash retry -- human input is found (wakes the
# gate), but the claude poll invocation itself crashes (non-zero exit).
# scan-state must NOT record the comment id, so the same comment retries
# (wakes again) next cycle instead of being silently dropped.
# Fails pre-gate: scan-state.json doesn't exist pre-gate at all, so this
# assertion has no pre-gate equivalent; more relevantly, this is exactly the
# deferred-write behavior the gate introduces.
# =============================================================================
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":303}]'
export AP_TEST_GH_COMMENT_303='[{"id":777,"user":{"login":"haroun"},"body":"go now"}]'
export AP_TEST_POLL_CRASH=1
rc="$(run_case)"
assert "case22: crash retry -> exit 0" [ "$rc" -eq 0 ]
assert "case22: crash retry -> comment id NOT recorded in scan-state" bash -c \
  "[ ! -f '$CASE_AP_HOME/scan-state.json' ] || python3 -c \"
import json
with open('$CASE_AP_HOME/scan-state.json') as f:
    d = json.load(f)
assert d.get('inbox', {}).get('303') is None, d
\""
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_303 AP_TEST_POLL_CRASH

# =============================================================================

# =============================================================================
# Case 23: session writes status.json to the adhoc fallback (could not resolve
# the run dir) -> wrapper adopts it instead of declaring FAILED
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-23 AP_TEST_STATUS_TO_ADHOC=1 run_case)"
assert "case23: exit 0" [ "$rc" -eq 0 ]
assert "case23: ledger plan row adopted DONE from adhoc" bash -c \
  "cat '$CASE_AP_HOME/runs/'*.jsonl | python3 -c 'import json,sys; rows=[json.loads(l) for l in sys.stdin if l.strip()]; sys.exit(0 if any(r[\"phase\"]==\"plan\" and r[\"status\"]==\"DONE\" for r in rows) else 1)'"
assert "case23: no failed-label gh call" bash -c \
  "! grep -rl 'add-label failed' '$CASE_STUB_DIR/gh_calls' >/dev/null 2>&1"
assert "case23: adhoc file consumed (moved, not left stale)" bash -c \
  "[ ! -f '$CASE_AP_HOME/runs/adhoc/status.json' ]"

# =============================================================================
# Case 24: an ACTIONABLE poll marks ONLY the signal it consumed as seen; every
# OTHER pending signal from the same scan stays live so the next cycle re-wakes
# and drains it. Two fresh delegations wake the poll; it acts on one (plan for
# 901). 901 must be marked (or the next cycle replans it AGAIN with the same
# stale input -- the live bug on ENG-1308, 2026-08-14: a "discard the
# worktrees" comment was consumed by a replan, never marked seen, and a later
# cycle saw it as still-new and replanned again, clobbering a genuinely new
# NEEDS_HUMAN question that had landed in between). 902 must NOT be marked --
# the prior incident this case also guards, where one poll's actionable
# response stranded every OTHER queued issue until the 6h insurance poll.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":901,"labels":[{"name":"Queued"}]},{"number":902,"labels":[{"name":"Queued"}]}]'
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-901 AP_TEST_POLL_INBOX=901 run_case)"
assert "case24: first cycle exit 0" [ "$rc" -eq 0 ]
assert "case24: first cycle woke the poll" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
assert "case24: the CONSUMED issue (901) IS marked seen" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '901' in d['new_intake_seen'], d\""
assert "case24: the UNCONSUMED issue (902) is NOT marked seen" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '902' not in d['new_intake_seen'], d\""
calls_before="$(count_files "$CASE_STUB_DIR/claude_calls")"
rc2="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-902 AP_TEST_POLL_INBOX=902 run_case)"
assert "case24: second cycle exit 0" [ "$rc2" -eq 0 ]
assert "case24: second cycle re-woke the poll for the remaining intake" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -gt "$calls_before" ]
assert "case24: both issues are now marked seen after being drained" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '901' in d['new_intake_seen'] and '902' in d['new_intake_seen'], d\""

# =============================================================================
# Case 23b (adhoc adoption hardening, needed for two-lane concurrency): the
# adhoc status.json's .issue does NOT match THIS act's issue -- a different
# concurrent act's leftover file sharing the one adhoc path. Must NOT be
# adopted: left in place, this act is treated as FAILED (no status.json ever
# resolved for it), and the mismatched file survives for its real owner.
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-23B AP_TEST_STATUS_TO_ADHOC=1 \
  AP_TEST_ADHOC_STATUS_ISSUE=ENG-OTHER run_case)"
assert "case23b: exit 0" [ "$rc" -eq 0 ]
assert "case23b: ledger plan row is FAILED, not adopted from the mismatched adhoc file" bash -c \
  "cat '$CASE_AP_HOME/runs/'*.jsonl | python3 -c 'import json,sys; rows=[json.loads(l) for l in sys.stdin if l.strip()]; sys.exit(0 if any(r[\"phase\"]==\"plan\" and r[\"status\"]==\"FAILED\" for r in rows) else 1)'"
assert "case23b: mismatched adhoc file left in place (not consumed)" bash -c \
  "[ -f '$CASE_AP_HOME/runs/adhoc/status.json' ]"

# =============================================================================
# Two-lane concurrency (Change B). lock.build / lock.plan are stubbed busy by
# grabbing the lock file with a background `flock <file> sleep <n> &`.
# =============================================================================

# --- (i) build lane held + Queued intake present -> poll runs with
# "--busy-lanes build" in argv, and a plan act proceeds (plan lane is free).
# AP_BUILD_SLOTS=1 here: this exercises the "lane busy" boundary itself
# (single-slot semantics), not slot-count behavior -- that's covered
# separately below (build slot concurrency, Feature 1).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":2001,"labels":[{"name":"Queued"}]}]'
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-2001 run_case)"
wait "$build_holder" 2>/dev/null
assert "laneB(i): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "laneB(i): poll invoked with --busy-lanes build" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes build' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "laneB(i): plan act proceeded (plan lane free)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-2001' '$act_args'"
unset AP_TEST_GH_ISSUES_ALL_OPEN

# --- (ii) plan lane held + go-approval present -> implement proceeds with
# "--busy-lanes plan" (build lane is free).
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2002}]'
export AP_TEST_GH_COMMENT_2002='[{"id":900,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2002 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=2002 run_case)"
wait "$plan_holder" 2>/dev/null
assert "laneB(ii): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "laneB(ii): poll invoked with --busy-lanes plan" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes plan' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "laneB(ii): implement act proceeded (build lane free)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2002

# --- (iii) BOTH lanes held -> no claude call at all (not even the poll).
# AP_BUILD_SLOTS=1 (single-slot boundary, not slot-count behavior).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":2003,"labels":[{"name":"Queued"}]}]'
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2004}]'
export AP_TEST_GH_COMMENT_2004='[{"id":901,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=none run_case)"
wait "$build_holder" "$plan_holder" 2>/dev/null
assert "laneB(iii): exit 0" [ "$rc" -eq 0 ]
assert "laneB(iii): no claude call at all (both lanes busy)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_ALL_OPEN AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2004

# --- (iv) go-approval present while build lane held -> NOT marked seen
# (re-fires once the lane frees). AP_BUILD_SLOTS=1 (single-slot boundary).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2005}]'
export AP_TEST_GH_COMMENT_2005='[{"id":902,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2005 AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
wait "$build_holder" 2>/dev/null
assert "laneB(iv): exit 0 (build busy -> no free-lane signal, poll not woken)" [ "$rc" -eq 0 ]
assert "laneB(iv): claude NOT called (signal's lane busy)" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "laneB(iv): comment NOT marked seen" bash -c \
  "[ ! -f '$CASE_AP_HOME/scan-state.json' ] || python3 -c \"
import json
with open('$CASE_AP_HOME/scan-state.json') as f:
    d = json.load(f)
assert d.get('inbox', {}).get('2005') is None, d
\""
rc2="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2005 AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
assert "laneB(iv): second cycle (lane free) exit 0" [ "$rc2" -eq 0 ]
assert "laneB(iv): second cycle -> claude called (re-fired)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2005

# =============================================================================
# Auto-approve (Change C).
# =============================================================================

# --- (a) global auto-approve on + plan-review issue with only an
# agent-marker comment -> implement claimed, --auto-approve in poll argv.
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":3001,"labels":[]}]'
export AP_TEST_GH_COMMENT_3001='[{"id":10,"user":{"login":"agent"},"body":"Plan file: /x/plan.md\nthe plan"}]'
rc="$(AP_AUTO_APPROVE=1 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-3001 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_POLL_INBOX=3001 run_case)"
assert "autoC(a): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "autoC(a): poll invoked with --auto-approve" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--auto-approve' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "autoC(a): implement act proceeded (auto-approved, no 'go' needed)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_3001

# --- (b) same, but a FRESH owner comment that is feedback (not go/auto) ->
# feedback wins: the wrapper wakes the PLAN lane for it, not build, and the
# replan action (as the poll -- stubbed here -- decides) proceeds normally.
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":3002,"labels":[]}]'
export AP_TEST_GH_COMMENT_3002='[{"id":11,"user":{"login":"haroun"},"body":"please use a different table name"}]'
rc="$(AP_AUTO_APPROVE=1 AP_TEST_POLL_ACTION=replan AP_TEST_POLL_ISSUE=ENG-3002 \
  AP_TEST_POLL_FEEDBACK="please use a different table name" AP_TEST_POLL_INBOX=3002 run_case)"
assert "autoC(b): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "autoC(b): replan act proceeded (feedback wins over auto-approve)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--feedback' '$act_args'"
assert "autoC(b): NOT implement" bash -c \
  "[ -f '$act_args' ] && ! grep -q -- '--phase implement' '$act_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_3002

# --- (c) auto-approve on + needs-input issue with no new comment -> no
# action at all (needs-input is NEVER auto-approved).
setup_case
export AP_TEST_GH_ISSUES_NEEDS_INPUT='[{"number":3003}]'
export AP_TEST_GH_COMMENT_3003='[{"id":12,"user":{"login":"agent"},"body":"Phase: plan\nsome details"}]'
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{"3003":12},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
rc="$(AP_AUTO_APPROVE=1 AP_TEST_POLL_ACTION=none run_case)"
assert "autoC(c): exit 0" [ "$rc" -eq 0 ]
assert "autoC(c): claude NOT called (needs-input never auto-approves)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_NEEDS_INPUT AP_TEST_GH_COMMENT_3003

# --- (d) auto-approve OFF + plan-review with no owner comment (marker only)
# -> no action, unchanged from today.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":3004,"labels":[]}]'
export AP_TEST_GH_COMMENT_3004='[{"id":13,"user":{"login":"agent"},"body":"Plan file: /x/plan.md\nthe plan"}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "autoC(d): exit 0" [ "$rc" -eq 0 ]
assert "autoC(d): claude NOT called (auto-approve off, no 'go')" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_3004

# --- (e) per-issue `auto` label with global OFF -> implement claimed.
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":3005,"labels":[{"name":"auto"}]}]'
export AP_TEST_GH_COMMENT_3005='[{"id":14,"user":{"login":"agent"},"body":"Plan file: /x/plan.md\nthe plan"}]'
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-3005 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=3005 run_case)"
assert "autoC(e): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "autoC(e): implement act proceeded (per-issue auto label, global off)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "autoC(e): poll invoked WITHOUT --auto-approve (global flag stays off)" bash -c \
  "[ -f '$poll_args' ] && ! grep -q -- '--auto-approve' '$poll_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_3005

# --- (refinement) an `auto` first-line comment on a plan-review issue claims
# implement, NOT replan -- "auto" is a directive like "go", never feedback.
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":3006,"labels":[]}]'
export AP_TEST_GH_COMMENT_3006='[{"id":15,"user":{"login":"haroun"},"body":"auto"}]'
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-3006 AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=3006 run_case)"
assert "autoC(comment): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "autoC(comment): implement act proceeded ('auto' comment is a directive, not feedback)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_3006

# =============================================================================
# Case 25: cwd discipline -- EVERY claude invocation (the poll included) must
# run from the work repo, because Claude Code discovers project skills from the
# cwd. run_case deliberately launches the cycle from /tmp; a cycle that does
# not cd would hand the poll a directory with no .claude/skills, which fails
# OPEN (no skill, $0 cost, instant action:none, every minute, nothing logged).
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-25 run_case)"
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
# implement/ship execute a settled plan and get sonnet; poll stays haiku.
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
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-26 run_case)"
assert "case26: exit 0" [ "$rc" -eq 0 ]
assert_model "case26: poll" "$CASE_STUB_DIR/claude_calls/1.args" haiku
assert_model "case26: plan" "$CASE_STUB_DIR/claude_calls/2.args" opus

# implement + ship in one cycle -> both sonnet
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-26 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_IMPLEMENT_STATUS=DONE run_case)"
assert "case26: implement cycle exit 0" [ "$rc" -eq 0 ]
assert_model "case26: implement" "$CASE_STUB_DIR/claude_calls/2.args" sonnet
assert_model "case26: ship" "$CASE_STUB_DIR/claude_calls/3.args" sonnet

# env override wins, so a hard ticket can be raised without changing the default
setup_case
rc="$(AP_PLAN_MODEL=fable AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-26 run_case)"
assert "case26: override cycle exit 0" [ "$rc" -eq 0 ]
assert_model "case26: plan honours AP_PLAN_MODEL" "$CASE_STUB_DIR/claude_calls/2.args" fable

# =============================================================================
# Case 27: the ledger row records the model the act ran on. Without it the only
# way to learn what a run cost money on is to dig its transcript out of
# ~/.claude, which is how a pipeline on fable-5 went unnoticed for a day.
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-27 run_case)"
ledger="$(today_ledger)"
assert "case27: exit 0" [ "$rc" -eq 0 ]
assert "case27: poll row records the poll model, act row records the act model" bash -c \
  "python3 -c \"
import json
rows = [json.loads(l) for l in open('$ledger') if l.strip()]
poll = [r for r in rows if r['phase'] == 'poll']
plan = [r for r in rows if r['phase'] == 'plan']
assert len(poll) == 1 and len(plan) == 1, rows
assert poll[0]['model'] == 'haiku', poll[0]
assert plan[0]['model'] == 'opus', plan[0]
\""

# the override must reach the ledger too, not just the argv
setup_case
rc="$(AP_PLAN_MODEL=fable AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-27 run_case)"
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
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; slot1_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=2 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-SLOTS1 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
wait "$slot1_holder" 2>/dev/null
assert "slots(1): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "slots(1): implement act proceeded (slot 1 busy, slot 2 free)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--phase implement' '$act_args'"
assert "slots(1): prompt carries --ports fe=5175,be=8002 (slot 2)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5175,be=8002' '$act_args'"
[[ -f "$act_args" ]] && grep -h -- '--ports fe=' "$act_args" >>"$PORTS_SEEN_FILE"

# --- (2) both slots held: an approval signal (build lane) does NOT reach the
# poll as actionable -- reported busy in --busy-lanes -- while a plan-lane
# signal (Queued intake) still wakes it and proceeds.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":2101,"labels":[{"name":"Queued"}]}]'
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2102}]'
export AP_TEST_GH_COMMENT_2102='[{"id":950,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; b1_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.build.2" 3; b2_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=2 AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-2101 run_case)"
wait "$b1_holder" "$b2_holder" 2>/dev/null
assert "slots(2): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "slots(2): poll invoked with --busy-lanes build (all slots full)" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes build' '$poll_args'"
assert "slots(2): busy-lanes does NOT report plan (plan lane free)" bash -c \
  "[ -f '$poll_args' ] && ! grep -q -- '--busy-lanes build,plan' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "slots(2): plan act proceeded (plan lane free, build's go-approval skipped)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-2101' '$act_args'"
unset AP_TEST_GH_ISSUES_ALL_OPEN AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2102

# --- (3) neither slot held -> lowest free wins (slot 1); prompt carries
# --ports fe=5174,be=8001.
setup_case
rc="$(AP_BUILD_SLOTS=2 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-SLOTS3 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
assert "slots(3): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "slots(3): prompt carries --ports fe=5174,be=8001 (slot 1)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5174,be=8001' '$act_args'"
[[ -f "$act_args" ]] && grep -h -- '--ports fe=' "$act_args" >>"$PORTS_SEEN_FILE"

# --- (4) AP_BUILD_SLOTS=1 reproduces today's single-lane behavior exactly:
# one slot, assigned the same slot-1 ports as case (3) above.
setup_case
rc="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-SLOTS4 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
assert "slots(4): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
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
echo "usage-limit" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-A \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
assert "limit(a): exit 0" [ "$rc" -eq 0 ]
assert "limit(a): pause file cleared" [ ! -e "$CASE_AP_HOME/pause" ]
assert "limit(a): cycle proceeded (claude called)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]

# --- (b) reason usage-limit + fresh mtime -> still paused, no claude call.
setup_case
echo "usage-limit" >"$CASE_AP_HOME/pause"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-B run_case)"
assert "limit(b): exit 0" [ "$rc" -eq 0 ]
assert "limit(b): still paused (fresh cooldown)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(b): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (c) reason failures + old mtime -> still paused (not a usage-limit
# reason, so cooldown never applies).
setup_case
echo "failures" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-C run_case)"
assert "limit(c): exit 0" [ "$rc" -eq 0 ]
assert "limit(c): still paused (reason=failures never auto-clears)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(c): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (d) reason manual + old mtime -> still paused (manual pauses never
# auto-clear, regardless of age).
setup_case
echo "manual" >"$CASE_AP_HOME/pause"
touch -d "@$(( $(date -u +%s) - 3700 ))" "$CASE_AP_HOME/pause"
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-D run_case)"
assert "limit(d): exit 0" [ "$rc" -eq 0 ]
assert "limit(d): still paused (reason=manual never auto-clears)" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(d): claude never called" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- (e) two consecutive act failures whose stderr matches a usage-limit
# signature -> the pause file the wrapper writes carries reason usage-limit.
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":800}]'
export AP_TEST_GH_COMMENT_800='[{"id":1,"user":{"login":"haroun"},"body":"go"}]'
rc1="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-E1 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_POLL_INBOX=800 \
  AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="Claude usage limit reached" run_case)"
assert "limit(e): run1 exit 0" [ "$rc1" -eq 0 ]
assert "limit(e): run1 no pause yet" [ ! -e "$CASE_AP_HOME/pause" ]
export AP_TEST_GH_COMMENT_800='[{"id":2,"user":{"login":"haroun"},"body":"go"}]'
rc2="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-LIMIT-E2 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_POLL_INBOX=800 \
  AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="Claude usage limit reached" run_case)"
assert "limit(e): run2 exit 0" [ "$rc2" -eq 0 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_800
assert "limit(e): pause file written after 2nd consecutive failure" [ -e "$CASE_AP_HOME/pause" ]
assert "limit(e): pause reason is usage-limit" bash -c \
  "[ \"\$(head -n1 '$CASE_AP_HOME/pause')\" = 'usage-limit' ]"

# =============================================================================
# Feature: visible ship stage (`shipping` label). Held only while
# `/ship-work --headless --no-merge` runs, swapped in by the WRAPPER (not the
# skill) right before invoking that phase, with its own ping.
# =============================================================================

# --- (a)/(c) implement DONE -> ship runs: the wrapper swaps
# building->shipping with its own "shipping:"-titled ping BEFORE the ship
# call, and the existing "ready to test" ping still fires on ship DONE.
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-SHIP-A \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_POLL_INBOX=850 \
  AP_TEST_IMPLEMENT_STATUS=DONE AP_TEST_SHIP_STATUS=DONE run_case)"
assert "ship-label(a): exit 0" [ "$rc" -eq 0 ]
assert "ship-label(a): 3 claude calls (poll+implement+ship)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 3 ]
assert "ship-label(a): gh issue edit adds the shipping label" bash -c \
  "grep -rl '^shipping\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "ship-label(a): notify title starts with 'shipping:'" bash -c \
  "grep -rl '^shipping: ENG-SHIP-A\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "ship-label(c): existing ready-to-test ping still fires on ship DONE" bash -c \
  "grep -rl 'ready to test' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (b) a shipping-labelled issue is NOT picked up by the intake scan even
# if it also (stale-)carries the Queued label.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":880,"labels":[{"name":"Queued"},{"name":"shipping"}]}]'
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-880 run_case)"
assert "ship-label(b): exit 0" [ "$rc" -eq 0 ]
assert "ship-label(b): claude never called (shipping excludes it from intake)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_ALL_OPEN

# =============================================================================
# External-cause failures (Change 1): a FAILED act whose stderr matches the
# EXTERNAL signature is re-queued to the state its phase started from instead
# of dead-ending at `failed` -- see ap-cycle.sh's FAILED reconcile branch.
# =============================================================================

# --- (a) implement act, session-limit stderr -> plan-review (not failed),
# notify title says requeued.
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-EXT-A AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=601 AP_TEST_ACT_STATUS=FAILED \
  AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(a): exit 0" [ "$rc" -eq 0 ]
assert "external(a): gh issue edit adds plan-review" bash -c \
  "grep -rl 'plan-review' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(a): gh issue edit removes building" bash -c \
  "grep -rl '^building\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(a): NOT labeled failed" bash -c \
  "! grep -rl '^failed\$' '$CASE_STUB_DIR/gh_calls' >/dev/null 2>&1"
assert "external(a): notify title says requeued after external failure" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-A\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "external(a): notify does NOT use the old FAILED title" bash -c \
  "! grep -rl '^autopilot FAILED' '$CASE_STUB_DIR/notify_calls' >/dev/null 2>&1"
assert "external(a): inbox comment includes the matched signature line" bash -c \
  "grep -rl 'session limit' '$CASE_STUB_DIR/gh_calls' >/dev/null"

# --- (b) same, for a plan act -> Queued.
setup_case
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-EXT-B AP_TEST_POLL_INBOX=602 \
  AP_TEST_ACT_STATUS=FAILED AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(b): exit 0" [ "$rc" -eq 0 ]
assert "external(b): gh issue edit adds Queued" bash -c \
  "grep -rl '^Queued\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(b): gh issue edit removes planning" bash -c \
  "grep -rl '^planning\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(b): NOT labeled failed" bash -c \
  "! grep -rl '^failed\$' '$CASE_STUB_DIR/gh_calls' >/dev/null 2>&1"
assert "external(b): notify title says requeued" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-B\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (c) same, for a standalone ship act -> ship-pending.
setup_case
rc="$(AP_TEST_POLL_ACTION=ship AP_TEST_POLL_ISSUE=ENG-EXT-C AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=603 AP_TEST_ACT_STATUS=FAILED \
  AP_TEST_ACT_STDERR="You've hit your session limit" run_case)"
assert "external(c): exit 0" [ "$rc" -eq 0 ]
assert "external(c): gh issue edit adds ship-pending" bash -c \
  "grep -rl '^ship-pending\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(c): gh issue edit removes shipping" bash -c \
  "grep -rl '^shipping\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(c): NOT labeled failed" bash -c \
  "! grep -rl '^failed\$' '$CASE_STUB_DIR/gh_calls' >/dev/null 2>&1"
assert "external(c): notify title says requeued" bash -c \
  "grep -rl '^requeued after external failure: ENG-EXT-C\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"

# --- (d) regression: a non-external failure still gets `failed` + the old
# FAILED notify title, no requeue.
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-EXT-D AP_TEST_POLL_PLANPATH=docs/plans/x.md \
  AP_TEST_POLL_INBOX=604 AP_TEST_ACT_STATUS=FAILED \
  AP_TEST_ACT_STDERR="assertion error: unexpected None" run_case)"
assert "external(d): exit 0" [ "$rc" -eq 0 ]
assert "external(d): gh issue edit adds failed" bash -c \
  "grep -rl '^failed\$' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "external(d): notify title is the old FAILED wording" bash -c \
  "grep -rl '^autopilot FAILED: ENG-EXT-D\$' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "external(d): notify title does NOT say requeued" bash -c \
  "! grep -rl 'requeued' '$CASE_STUB_DIR/notify_calls' >/dev/null 2>&1"

# =============================================================================
# Ship-only action, ship lane (Change: ship gets its OWN lane, not build).
# poll can emit action=ship for a ship-pending issue; dispatched as
# /ship-work --headless --no-merge --ports, on its own slot pool
# (lock.ship.1 .. lock.ship.N) and its own port base (5180+n/8010+n) --
# never the build lane's ports, never the human's baseline.
# =============================================================================

# --- (e) action=ship dispatches /ship-work with --no-merge and --ports from
# the ship base, slot 1 (fe=5181,be=8011).
setup_case
rc="$(AP_TEST_POLL_ACTION=ship AP_TEST_POLL_ISSUE=ENG-SHIP-ONLY \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_SHIP_STATUS=DONE run_case)"
assert "shipOnly(e): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "shipOnly(e): act call recorded" [ -f "$act_args" ]
assert "shipOnly(e): dispatches /ship-work" bash -c \
  "[ -f '$act_args' ] && grep -q 'ship-work' '$act_args'"
assert "shipOnly(e): includes --no-merge" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--no-merge' '$act_args'"
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

# --- (h) ship lane slot mechanics: ship slot 1 held -> a second standalone
# ship takes slot 2 (fe=5182,be=8012), still never a build slot's pair or the
# human baseline.
setup_case
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; ship1_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_SHIP_SLOTS=2 AP_TEST_POLL_ACTION=ship AP_TEST_POLL_ISSUE=ENG-SHIP-SLOT2 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_SHIP_STATUS=DONE run_case)"
wait "$ship1_holder" 2>/dev/null
assert "shipOnly(h): exit 0" [ "$rc" -eq 0 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "shipOnly(h): took ship slot 2 (fe=5182,be=8012)" bash -c \
  "[ -f '$act_args' ] && grep -q -- '--ports fe=5182,be=8012' '$act_args'"
assert "shipOnly(h): never assigns fe=5173" bash -c "[ -f '$act_args' ] && ! grep -q 'fe=5173' '$act_args'"
assert "shipOnly(h): never assigns be=8000" bash -c "[ -f '$act_args' ] && ! grep -q 'be=8000' '$act_args'"

# --- (i) implement->ship CHAIN regression: an implement whose status comes
# back DONE still chains into ship in the SAME cycle, and that trailing ship
# call KEEPS the build slot's own ports (fe=5174,be=8001 for slot 1) --
# NEVER the ship lane's base. This is the non-obvious part of the feature:
# only a STANDALONE ship (action=ship, from a ship-pending issue) uses the
# ship lane; the chain never re-enters the case statement that assigns it.
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-CHAIN \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_IMPLEMENT_STATUS=DONE \
  AP_TEST_SHIP_STATUS=DONE run_case)"
assert "chain(i): exit 0" [ "$rc" -eq 0 ]
assert "chain(i): 3 claude calls (poll+implement+ship)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 3 ]
implement_args="$CASE_STUB_DIR/claude_calls/2.args"
ship_args="$CASE_STUB_DIR/claude_calls/3.args"
assert "chain(i): implement call carries build slot 1 ports" bash -c \
  "[ -f '$implement_args' ] && grep -q -- '--ports fe=5174,be=8001' '$implement_args'"
assert "chain(i): chained ship call carries the SAME build slot ports, not the ship base" bash -c \
  "[ -f '$ship_args' ] && grep -q -- '--ports fe=5174,be=8001' '$ship_args' && ! grep -q 'fe=5181' '$ship_args'"

# =============================================================================
# Ship-pending wake now belongs to the SHIP lane, not build (the bug this
# feature fixes -- ship-pending must not queue behind a full build lane).
# =============================================================================

# --- (a) all build slots busy + a ship-pending signal -> poll still runs and
# dispatches ship (proves ship no longer blocks on build).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_SHIP_PENDING='[{"number":704}]'
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; a_build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_TEST_POLL_ACTION=ship AP_TEST_POLL_ISSUE=ENG-704 \
  AP_TEST_POLL_PLANPATH=docs/plans/x.md AP_TEST_SHIP_STATUS=DONE run_case)"
wait "$a_build_holder" 2>/dev/null
assert "shipLane(a): exit 0" [ "$rc" -eq 0 ]
assert "shipLane(a): poll ran despite build lane full" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "shipLane(a): dispatched ship" bash -c \
  "[ -f '$act_args' ] && grep -q 'ship-work' '$act_args'"
unset AP_TEST_GH_ISSUES_SHIP_PENDING

# --- (b) all ship slots busy + a ship-pending signal -> the signal is
# skipped (not actionable, not marked seen); --busy-lanes reports ship when
# something else (a plan-lane signal) independently wakes the poll.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_SHIP_PENDING='[{"number":705}]'
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":706,"labels":[{"name":"Queued"}]}]'
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; b_ship_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_SHIP_SLOTS=1 AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-706 run_case)"
wait "$b_ship_holder" 2>/dev/null
assert "shipLane(b): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "shipLane(b): poll invoked with --busy-lanes ship" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes ship' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "shipLane(b): plan act proceeded (plan lane free, ship-pending skipped)" bash -c \
  "[ -f '$act_args' ] && grep -q 'implement-issue --phase plan ENG-706' '$act_args'"
assert "shipLane(b): ship-pending item NOT marked seen (re-fires once free)" bash -c \
  "[ ! -f '$CASE_AP_HOME/scan-state.json' ] || python3 -c \"
import json
with open('$CASE_AP_HOME/scan-state.json') as f:
    d = json.load(f)
assert '705' not in d.get('ship_pending_seen', []), d
\""
unset AP_TEST_GH_ISSUES_SHIP_PENDING AP_TEST_GH_ISSUES_ALL_OPEN

# --- (busy_lanes all three) fallback wake (stale ts, never lane-gated) with
# plan, build and ship all busy -> poll still runs, and --busy-lanes carries
# all three names.
setup_case
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"2020-01-01T00:00:00Z"}' >"$CASE_AP_HOME/scan-state.json"
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; abc_build_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; abc_ship_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; abc_plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_BUILD_SLOTS=1 AP_SHIP_SLOTS=1 AP_TEST_POLL_ACTION=none run_case)"
wait "$abc_build_holder" "$abc_ship_holder" "$abc_plan_holder" 2>/dev/null
assert "busyLanes(all-three): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "busyLanes(all-three): poll invoked (fallback isn't lane-gated)" [ -f "$poll_args" ]
assert "busyLanes(all-three): --busy-lanes carries build,ship,plan" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes build,ship,plan' '$poll_args'"

# =============================================================================
# Ship-pending wake + seen-tracking, unaffected by these changes (same pattern
# as the new-intake leg's case20).
# =============================================================================

# --- (f) a ship-pending issue wakes the scan (poll runs); a non-actionable
# poll (action:none, e.g. it's not the oldest item) commits it as seen so it
# stops re-waking every minute -- same pattern as the new-intake leg's case20.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_SHIP_PENDING='[{"number":701}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "shipPending(f): wake -> exit 0" [ "$rc" -eq 0 ]
assert "shipPending(f): wake -> claude called (poll woke)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
assert "shipPending(f): scan-state records 701 as seen" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '701' in d.get('ship_pending_seen', []), d\""
rc2="$(AP_TEST_POLL_ACTION=none run_case)"
assert "shipPending(f): second identical cycle -> claude NOT called again" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]

setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_SHIP_PENDING='[{"number":702}]'
hold_lane_lock "$CASE_AP_HOME/lock.ship.1" 3; sp_ship_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_SHIP_SLOTS=1 AP_TEST_POLL_ACTION=none run_case)"
wait "$sp_ship_holder" 2>/dev/null
assert "shipPending(f): ship-lane-full -> exit 0" [ "$rc" -eq 0 ]
assert "shipPending(f): ship-lane-full -> claude NOT called" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "shipPending(f): ship-lane-full -> NOT marked seen (re-fires once free)" bash -c \
  "[ ! -f '$CASE_AP_HOME/scan-state.json' ] || python3 -c \"
import json
with open('$CASE_AP_HOME/scan-state.json') as f:
    d = json.load(f)
assert '702' not in d.get('ship_pending_seen', []), d
\""
unset AP_TEST_GH_ISSUES_SHIP_PENDING

# --- (g) a ship-pending issue is not treated as new intake even with a
# Queued label.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"ship_pending_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":703,"labels":[{"name":"Queued"},{"name":"ship-pending"}]}]'
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-703 run_case)"
assert "shipPending(g): exit 0" [ "$rc" -eq 0 ]
assert "shipPending(g): claude never called (ship-pending excludes it from intake)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_ALL_OPEN

# =============================================================================
# Case: marker discipline -- an agent-authored comment must never be read as
# owner input. The pipeline comments with the owner's own gh credentials, so
# author.login cannot distinguish them; the first-line marker is the only
# defence. Regression for the live loop on ENG-1137, where the wrapper's own
# unmarked failure comment ("STDERR (last 20 lines):") was read as feedback and
# re-triggered a re-plan whose comment re-triggered the next.
# =============================================================================
for marker in "Plan file: /x/p.md" "Phase: plan -- re-plan complete (FYI)" "Autopilot: run failed."; do
  setup_case
  now_ts="$(date -u +%FT%TZ)"
  printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
  export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":770}]'
  export AP_TEST_GH_COMMENT_770="[{\"id\":900,\"user\":{\"login\":\"haroun\"},\"body\":\"$marker\"}]"
  rc="$(AP_TEST_POLL_ACTION=none run_case)"
  assert "marker(${marker:0:11}): exit 0" [ "$rc" -eq 0 ]
  assert "marker(${marker:0:11}): agent comment did NOT wake the poll" \
    [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
  unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_770
done
# Control: a genuinely unmarked human comment MUST still wake it.
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":771}]'
export AP_TEST_GH_COMMENT_771='[{"id":901,"user":{"login":"haroun"},"body":"use a different table name"}]'
rc="$(AP_TEST_POLL_ACTION=none run_case)"
assert "marker(control): a real owner comment still wakes the poll" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_771

# =============================================================================
# Case: per-issue lock -- the lane locks cap concurrency but do NOT stop the
# SAME issue entering two different slots. Claiming is the poll skill's job
# (a label swap in prose), so a lagged or skipped swap lets the next cycle
# re-claim the same issue and race two implementers on one worktree. Observed
# on ENG-1308: polls at 03:50:53 and 03:51:53 both emitted implement for it.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
# No scan-state seeded on purpose: absent last_poll_ts -> the fallback leg
# wakes the poll, which is what these two cases need to exercise.
# Simulate a cycle already acting on ENG-77 by holding its per-issue lock.
hold_lane_lock "$CASE_AP_HOME/lock.issue.ENG-77" 8
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-77 AP_TEST_POLL_PLANPATH=/x/p.md AP_TEST_POLL_INBOX=77 run_case)"
assert "issueLock: exit 0" [ "$rc" -eq 0 ]
assert "issueLock: poll ran but NO act was dispatched for the in-flight issue" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
kill "$LANE_HOLDER_PID" 2>/dev/null; wait "$LANE_HOLDER_PID" 2>/dev/null
# Control: with the lock free, the same action DOES dispatch its act.
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-77 AP_TEST_POLL_PLANPATH=/x/p.md AP_TEST_POLL_INBOX=77 run_case)"
assert "issueLock(control): lock free -> act dispatched" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 2 ]

# =============================================================================
# Case: the wrapper's NEEDS_HUMAN echo of status.json's `question` must carry a
# marker. It is a SEPARATE, LATER comment than the skill's own marked one, so
# unmarked it becomes the newest and the next scan reads the pipeline's own
# question as owner feedback -> re-plan -> NEEDS_HUMAN -> echo -> loop.
# ENG-1308 burned ~$17 in five re-plans on exactly this.
# =============================================================================
setup_case
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-78 AP_TEST_POLL_PLANPATH=/x/p.md AP_TEST_POLL_INBOX=78 \
  AP_TEST_IMPLEMENT_STATUS=NEEDS_HUMAN AP_TEST_QUESTION="which table should this use" run_case)"
assert "questionEcho: exit 0" [ "$rc" -eq 0 ]
assert "questionEcho: the echoed question comment is marked Autopilot:" bash -c \
  "grep -rl 'Autopilot: needs input' '$CASE_STUB_DIR/gh_calls' >/dev/null"
assert "questionEcho: the question text is still included" bash -c \
  "grep -rl 'which table should this use' '$CASE_STUB_DIR/gh_calls' >/dev/null"

# =============================================================================
# AP_POLL_MODE=deterministic, case A: empty inbox -> ap-decide.sh (invoked at
# its real absolute path, not through the stubbed PATH) does the deciding
# itself, purely off the stubbed `gh`. Proven two ways: no claude call for
# the poll (a --json-schema call never appears), and the gh stub recorded a
# call carrying ap-decide.py's own distinctive tier1/2 query shape
# (--json number,title,labels, which the pre-scan gate itself never asks
# for). action=none on an empty inbox -> no act stage either, so claude is
# never invoked AT ALL this cycle.
# =============================================================================
setup_case
rc="$(AP_POLL_MODE=deterministic run_case)"
assert "detMode(A): exit 0" [ "$rc" -eq 0 ]
assert "detMode(A): claude never invoked (deterministic poll + action=none)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
assert "detMode(A): gh was asked ap-decide.py's tier1/2 query shape" bash -c \
  "grep -rl 'number,title,labels' '$CASE_STUB_DIR/gh_calls' >/dev/null"
ledger="$(today_ledger)"
assert "detMode(A): poll ledger row has session_id=deterministic" bash -c \
  "grep -q '\"session_id\":\"deterministic\"' '$ledger' 2>/dev/null || grep -q '\"session_id\": \"deterministic\"' '$ledger'"
assert "detMode(A): poll ledger row has model=none" bash -c \
  "grep -q '\"model\":\"none\"' '$ledger' 2>/dev/null || grep -q '\"model\": \"none\"' '$ledger'"

# =============================================================================
# AP_POLL_MODE=deterministic, case B: a ship-pending issue with a resolvable
# plan file -> ap-decide.sh itself performs the ship-pending -> shipping
# claim (no model poll did it), and the wrapper still dispatches the ship
# act exactly as it would for the model poll's "ship" action. Proves
# deterministic mode drives the SAME downstream act pipeline, and that the
# poll step itself never touches claude (only the act stage does, and that
# call carries no --json-schema).
# =============================================================================
setup_case
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-900-thing.md"
export AP_TEST_GH_ISSUES_SHIP_PENDING='[{"number":900,"title":"ENG-900: thing","labels":[{"name":"ship-pending"}]}]'
export AP_TEST_GH_COMMENT_900='[]'
rc="$(AP_POLL_MODE=deterministic run_case)"
unset AP_TEST_GH_ISSUES_SHIP_PENDING AP_TEST_GH_COMMENT_900
assert "detMode(B): exit 0" [ "$rc" -eq 0 ]
assert "detMode(B): exactly one claude call (the ship act; no model poll call)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 1 ]
assert "detMode(B): that one claude call is NOT the --json-schema poll shape" bash -c \
  "! grep -qx -- '--json-schema' '$CASE_STUB_DIR/claude_calls/1.args'"
assert "detMode(B): ap-decide.sh itself swapped ship-pending -> shipping" bash -c \
  "grep -rl '^ship-pending$' '$CASE_STUB_DIR/gh_calls' | xargs -r grep -l '^shipping$' >/dev/null"
assert "detMode(B): act call targets ship-work for ENG-900" bash -c \
  "grep -q 'ship-work.*ENG-900\|ENG-900.*ship-work' '$CASE_STUB_DIR/claude_calls/1.args' || grep -q 'ship-work' '$CASE_STUB_DIR/claude_calls/1.args'"

# =============================================================================
# Case: ENG-1308-shaped regression (2026-08-14 live incident). An owner
# feedback comment on a plan-review issue is consumed by a replan. A SECOND
# cycle, with the SAME comment still the newest on the issue (nothing new
# posted), must NOT replan again off it -- the comment was already marked
# seen by the first cycle's commit. Before the fix, the actionable-poll
# branch committed /dev/null for everything, so the consumed comment was
# never recorded and every later cycle treated it as still-new: a real run
# replanned the identical feedback twice, and the second pass clobbered the
# label back over a genuinely new NEEDS_HUMAN question that had landed
# in between.
# =============================================================================
setup_case
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":1308}]'
export AP_TEST_GH_COMMENT_1308='[{"id":5280390731,"user":{"login":"haroun"},"body":"discard the worktrees; take the full fix"}]'
rc1="$(AP_TEST_POLL_ACTION=replan AP_TEST_POLL_ISSUE=ENG-1308 AP_TEST_POLL_INBOX=1308 \
  AP_TEST_POLL_FEEDBACK="discard the worktrees; take the full fix" run_case)"
assert "eng1308: first cycle exit 0" [ "$rc1" -eq 0 ]
assert "eng1308: first cycle actually replanned (one act call)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 2 ]
assert "eng1308: the feedback comment IS marked seen after being consumed" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert d['inbox'].get('1308') == 5280390731, d\""
calls_before="$(count_files "$CASE_STUB_DIR/claude_calls")"
# Second cycle: same fixture, nothing new posted (comment id unchanged).
rc2="$(AP_TEST_POLL_ACTION=none run_case)"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_1308
assert "eng1308: second cycle exit 0" [ "$rc2" -eq 0 ]
assert "eng1308: second cycle did NOT wake the poll (comment already consumed)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq "$calls_before" ]

# =============================================================================
# Persistent mode (AP_ACT_LAUNCH_MODE=persistent): parking and window
# lifecycle, against the fake tmux in make_stub_dir. What real tmux/claude
# interaction actually does (does a resumed session pick up an injected
# reply) was verified live against a real tmux session, not re-tested here
# -- these cases only check ap-cycle.sh's own bookkeeping: does a
# NEEDS_HUMAN act write the parked registry and leave its window up; does a
# DONE/FAILED act tear its window down; does a parked issue get skipped by
# the ordinary comment-scan legs.
# =============================================================================

# --- persist(A): NEEDS_HUMAN parks -- registry written, window left alive --
setup_case
export AP_ACT_LAUNCH_MODE=persistent
export AP_TMUX_SESSION=ap-test-should-never-be-real
export AP_TEST_ACT_STATUS=NEEDS_HUMAN
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-PA AP_TEST_POLL_INBOX=601 run_case)"
assert "persist(A): exit 0" [ "$rc" -eq 0 ]
assert "persist(A): parked registry written for inbox issue 601" \
  [ -f "$CASE_AP_HOME/parked/601.json" ]
assert "persist(A): registry records the right issue/phase/lane" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/601.json')); assert d['issue']=='ENG-PA' and d['phase']=='plan' and d['lane']=='plan', d\""
assert "persist(A): registry records the question" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/601.json')); assert d.get('question'), d\""
assert "persist(A): window was NOT torn down (still tracked by fake tmux)" bash -c \
  "ls '$CASE_AP_HOME/.test-tmux/'act_plan_ENG-PA_plan.meta >/dev/null 2>&1"
unset AP_ACT_LAUNCH_MODE AP_TMUX_SESSION AP_TEST_ACT_STATUS

# --- persist(B): DONE tears the window down ---------------------------------
setup_case
export AP_ACT_LAUNCH_MODE=persistent
export AP_TMUX_SESSION=ap-test-should-never-be-real
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-PB AP_TEST_POLL_INBOX=602 run_case)"
assert "persist(B): exit 0" [ "$rc" -eq 0 ]
assert "persist(B): no parked registry (DONE, not NEEDS_HUMAN)" \
  bash -c "[ ! -f '$CASE_AP_HOME/parked/602.json' ]"
assert "persist(B): window WAS torn down" bash -c \
  "[ ! -f '$CASE_AP_HOME/.test-tmux/act_plan_ENG-PB_plan.meta' ]"
unset AP_ACT_LAUNCH_MODE AP_TMUX_SESSION

# --- persist(C): a parked issue is skipped by the ordinary comment scan -----
# A fresh, unmarked plan-review comment on an issue that ALSO has a live
# parked-registry entry must not be treated as a normal replan signal --
# is_parked() must exclude it, the same ENG-1308-class guard extended to
# the parked interval.
setup_case
mkdir -p "$CASE_AP_HOME/parked"
cat >"$CASE_AP_HOME/parked/603.json" <<'EOF'
{"inbox_issue": 603, "issue": "ENG-PC", "phase": "implement", "lane": "build",
 "window": "act_build_1_ENG-PC_implement", "run_dir": "/tmp/does-not-matter",
 "plan_path": "docs/plans/x.md", "ports": {"fe": "5174", "be": "8001"},
 "parked_at": "2026-08-14T00:00:00Z", "question": "which approach?"}
EOF
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":603}]'
export AP_TEST_GH_COMMENT_603='[{"id":9001,"user":{"login":"haroun"},"body":"go with option B"}]'
rc="$(AP_FULL_POLL_INTERVAL_MIN=0 AP_TEST_POLL_ACTION=none run_case)"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_603
assert "persist(C): exit 0" [ "$rc" -eq 0 ]
assert "persist(C): claude was never invoked at all (parked issue's comment did not even wake the poll)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]

# --- persist(D): ap-resume.sh must NOT mark a comment consumed when it bails
# on "no free slot" -- this is a real bug that was caught and fixed while
# testing this feature live: scan_parked_replies used to mark
# last_relayed_comment_id BEFORE knowing whether ap-resume.sh would actually
# inject, so a busy lane silently dropped the reply forever instead of
# retrying (the same "no free slot -> retry next cycle" shape every other
# busy-lane skip in this file already has). Invoke ap-resume.sh directly
# (not through the backgrounded scan_parked_replies path, to avoid timing
# flakiness) with both build slots deliberately held busy.
setup_case
mkdir -p "$CASE_AP_HOME/parked" "$CASE_AP_HOME/.test-tmux"
cat >"$CASE_AP_HOME/parked/604.json" <<'EOF'
{"inbox_issue": 604, "issue": "ENG-PD", "phase": "implement", "lane": "build",
 "window": "act_build_1_ENG-PD_implement", "run_dir": "/tmp/does-not-matter",
 "plan_path": "docs/plans/x.md", "ports": {"fe": "5174", "be": "8001"},
 "parked_at": "2026-08-14T00:00:00Z", "question": "which approach?"}
EOF
# Fake tmux window "alive" so ap-resume.sh gets past the window_alive gate.
echo "99999" >"$CASE_AP_HOME/.test-tmux/act_build_1_ENG-PD_implement.meta"
hold_lane_lock "$CASE_AP_HOME/lock.build.1" 3; slot1_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.build.2" 3; slot2_holder="$LANE_HOLDER_PID"
AP_HOME="$CASE_AP_HOME" AP_WORK_REPO="$CASE_WORK_REPO" AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
AP_TMUX_SESSION=ap-test-should-never-be-real AP_BUILD_SLOTS=2 \
PATH="$CASE_STUB_DIR:$PATH" \
  bash "$BIN_DIR/ap-resume.sh" 604 "go with option B" 9001 \
  >"$CASE_AP_HOME/resume-d.stdout.log" 2>"$CASE_AP_HOME/resume-d.stderr.log"
resume_rc=$?
wait "$slot1_holder" "$slot2_holder" 2>/dev/null
assert "persist(D): ap-resume.sh exits 0 even when it bails" [ "$resume_rc" -eq 0 ]
assert "persist(D): registry entry still exists (not dropped)" \
  [ -f "$CASE_AP_HOME/parked/604.json" ]
assert "persist(D): last_relayed_comment_id was NOT set (comment 9001 not consumed)" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/parked/604.json')); assert d.get('last_relayed_comment_id') is None, d\""
assert "persist(D): cycle.log records the 'no free slot' bail reason" \
  bash -c "grep -q 'no free slot' '$CASE_AP_HOME/logs/cycle.log'"

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
