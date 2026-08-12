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
  *plan-issue*) phase="plan" ;;
  *implement-plan*) phase="implement" ;;
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

  chmod +x "$dir/claude" "$dir/gh" "$dir/ap-notify.sh"
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
    AP_TEST_GH_ISSUES_ALL_OPEN AP_TEST_POLL_CRASH AP_FULL_POLL_INTERVAL_MIN
}

run_case() {
  # runs ap-cycle.sh with the current fixture; stdout/stderr discarded to log.
  # Deliberately launched from a directory that is NOT the work repo (the
  # subshell cd) so the cwd-discipline case can catch a regression of the bug
  # where the poll ran in the inherited cwd and therefore found no skills.
  (
    cd /tmp || exit 1
    AP_HOME="$CASE_AP_HOME" \
    AP_WORK_REPO="$CASE_WORK_REPO" \
    AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
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
  assert "case4: act call prompt targets plan-issue ENG-4" bash -c "grep -q 'plan-issue ENG-4' '$act_args'"
  assert "case4: plan DONE pings the owner (plan ready for review)" bash -c \
    "grep -rl 'plan ready for review' '$CASE_STUB_DIR/notify_calls' >/dev/null"
else
  fail "case4: act call has --settings (no 2.args file)"
  fail "case4: act call settings path is absolute autopilot.json"
  fail "case4: act call prompt has --headless"
  fail "case4: act call prompt targets plan-issue ENG-4"
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
# Case 24: an ACTIONABLE poll must not mark the signals it didn't consume as
# seen. Two fresh delegations wake the poll; it acts on one (plan). The other
# must stay live so the next cycle re-wakes and drains it, instead of being
# stranded until the insurance poll. Regression for the live incident where
# 6 queued issues were all marked seen by the one poll that implemented an
# unrelated approval.
# =============================================================================
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":901,"labels":[{"name":"Queued"}]},{"number":902,"labels":[{"name":"Queued"}]}]'
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-901 AP_TEST_POLL_INBOX=901 run_case)"
assert "case24: first cycle exit 0" [ "$rc" -eq 0 ]
assert "case24: first cycle woke the poll" [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -ge 1 ]
assert "case24: unconsumed intake NOT marked seen after actionable poll" bash -c \
  "python3 -c \"import json; d=json.load(open('$CASE_AP_HOME/scan-state.json')); assert '902' not in d['new_intake_seen'] and '901' not in d['new_intake_seen'], d\""
calls_before="$(count_files "$CASE_STUB_DIR/claude_calls")"
rc2="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-902 AP_TEST_POLL_INBOX=902 run_case)"
assert "case24: second cycle exit 0" [ "$rc2" -eq 0 ]
assert "case24: second cycle re-woke the poll for the remaining intake" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -gt "$calls_before" ]

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
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":2001,"labels":[{"name":"Queued"}]}]'
hold_lane_lock "$CASE_AP_HOME/lock.build" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_TEST_POLL_ACTION=plan AP_TEST_POLL_ISSUE=ENG-2001 run_case)"
wait "$build_holder" 2>/dev/null
assert "laneB(i): exit 0" [ "$rc" -eq 0 ]
poll_args="$CASE_STUB_DIR/claude_calls/1.args"
assert "laneB(i): poll invoked with --busy-lanes build" bash -c \
  "[ -f '$poll_args' ] && grep -q -- '--busy-lanes build' '$poll_args'"
act_args="$CASE_STUB_DIR/claude_calls/2.args"
assert "laneB(i): plan act proceeded (plan lane free)" bash -c \
  "[ -f '$act_args' ] && grep -q 'plan-issue ENG-2001' '$act_args'"
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
  "[ -f '$act_args' ] && grep -q 'implement-plan' '$act_args'"
unset AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2002

# --- (iii) BOTH lanes held -> no claude call at all (not even the poll).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_ALL_OPEN='[{"number":2003,"labels":[{"name":"Queued"}]}]'
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2004}]'
export AP_TEST_GH_COMMENT_2004='[{"id":901,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.build" 3; build_holder="$LANE_HOLDER_PID"
hold_lane_lock "$CASE_AP_HOME/lock.plan" 3; plan_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_TEST_POLL_ACTION=none run_case)"
wait "$build_holder" "$plan_holder" 2>/dev/null
assert "laneB(iii): exit 0" [ "$rc" -eq 0 ]
assert "laneB(iii): no claude call at all (both lanes busy)" \
  [ "$(count_files "$CASE_STUB_DIR/claude_calls")" -eq 0 ]
unset AP_TEST_GH_ISSUES_ALL_OPEN AP_TEST_GH_ISSUES_PLAN_REVIEW AP_TEST_GH_COMMENT_2004

# --- (iv) go-approval present while build lane held -> NOT marked seen
# (re-fires once the lane frees).
setup_case
now_ts="$(date -u +%FT%TZ)"
printf '{"inbox":{},"new_intake_seen":[],"last_poll_ts":"%s"}' "$now_ts" >"$CASE_AP_HOME/scan-state.json"
export AP_TEST_GH_ISSUES_PLAN_REVIEW='[{"number":2005}]'
export AP_TEST_GH_COMMENT_2005='[{"id":902,"user":{"login":"haroun"},"body":"go"}]'
hold_lane_lock "$CASE_AP_HOME/lock.build" 3; build_holder="$LANE_HOLDER_PID"
sleep 0.4
rc="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2005 AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
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
rc2="$(AP_TEST_POLL_ACTION=implement AP_TEST_POLL_ISSUE=ENG-2005 AP_TEST_POLL_PLANPATH=docs/plans/x.md run_case)"
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
  "[ -f '$act_args' ] && grep -q 'implement-plan' '$act_args'"
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
  "[ -f '$act_args' ] && ! grep -q 'implement-plan' '$act_args'"
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
  "[ -f '$act_args' ] && grep -q 'implement-plan' '$act_args'"
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
  "[ -f '$act_args' ] && grep -q 'implement-plan' '$act_args'"
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

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
