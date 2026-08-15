#!/usr/bin/env bash
# Test harness for ap-runs.py (the backend for ap runs|run|tail).
# Builds a fixture AP_HOME + fake transcript tree and asserts on the rendering.
# No network, no real claude, no dependence on the operator's own ~/.claude.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
RUNS_PY="$BIN_DIR/ap-runs.py"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export AP_HOME="$FIX/ap"
export AP_PROJECTS_DIR="$FIX/projects"
export AP_SESSIONS_DIR="$FIX/sessions"
# ap-runs.py's live_acts() now also queries this tmux session for persistent-
# mode act windows -- point it at one that can never be the real pipeline's,
# so a read-only `tmux list-windows` here never touches or depends on it.
export AP_TMUX_SESSION=ap-test-should-never-be-real
export NO_COLOR=1
mkdir -p "$AP_HOME/runs" "$AP_PROJECTS_DIR/proj" "$AP_SESSIONS_DIR"

SID_OK="aaaaaaaa-1111-2222-3333-444444444444"
SID_BAD="bbbbbbbb-1111-2222-3333-444444444444"
RUN_OK="$AP_HOME/runs/20260812T010000Z-111"
RUN_BAD="$AP_HOME/runs/20260812T020000Z-222"
mkdir -p "$RUN_OK" "$RUN_BAD"

# --- ledger: one DONE plan, one FAILED implement ------------------------------
cat >"$AP_HOME/runs/2026-08-12.jsonl" <<LEDGER
{"ts":"2026-08-12T01:10:00Z","issue":"ENG-1","phase":"poll","status":"plan","cost":0.01,"session_id":"cccccccc-0000-0000-0000-000000000000"}
{"ts":"2026-08-12T01:20:00Z","issue":"ENG-1","phase":"plan","status":"DONE","cost":7.5,"session_id":"$SID_OK"}
{"ts":"2026-08-12T02:20:00Z","issue":"ENG-2","phase":"implement","status":"FAILED","cost":3.25,"session_id":"$SID_BAD"}
LEDGER

# --- transcripts -------------------------------------------------------------
# The DONE plan: opus main loop, a sonnet subagent, one tool call, final text.
# Two lines share message id msg_1 to prove per-response dedupe (Claude Code
# writes one line per content block, each repeating the same usage object).
cat >"$AP_PROJECTS_DIR/proj/$SID_OK.jsonl" <<T1
{"type":"user","timestamp":"2026-08-12T01:00:00Z","message":{"content":"<command-args>/implement-issue --phase plan ENG-1 --headless --run-dir $RUN_OK</command-args>"}}
{"type":"assistant","timestamp":"2026-08-12T01:05:00Z","message":{"id":"msg_1","model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}}}
{"type":"assistant","timestamp":"2026-08-12T01:05:00Z","message":{"id":"msg_1","model":"claude-opus-5","content":[{"type":"text","text":"Plan committed."}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}}}
T1
mkdir -p "$AP_PROJECTS_DIR/proj/$SID_OK/subagents"
cat >"$AP_PROJECTS_DIR/proj/$SID_OK/subagents/agent-deadbeef.jsonl" <<T2
{"type":"assistant","timestamp":"2026-08-12T01:06:00Z","isSidechain":true,"message":{"id":"msg_2","model":"claude-sonnet-5","content":[{"type":"text","text":"explored"}],"usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":50}}}
T2
echo '{"status":"DONE","issue":"ENG-1","phase":"plan"}' >"$RUN_OK/status.json"

# The FAILED implement: no status.json, an api error, a stderr file.
cat >"$AP_PROJECTS_DIR/proj/$SID_BAD.jsonl" <<T3
{"type":"user","timestamp":"2026-08-12T02:00:00Z","message":{"content":"<command-args>/implement-issue --phase implement /x/docs/plans/2026-08-12-eng-2-thing.md --headless --run-dir $RUN_BAD</command-args>"}}
{"type":"assistant","timestamp":"2026-08-12T02:05:00Z","message":{"id":"msg_9","model":"claude-sonnet-5","content":[{"type":"text","text":"You've hit your session limit"}],"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3}},"isApiErrorMessage":true}
T3
echo "boom: something on stderr" >"$RUN_BAD/implement.stderr"

# --- list --------------------------------------------------------------------
out="$(python3 "$RUNS_PY" list -n 10 2>&1)"
assert "list: shows the DONE plan row" grep -q 'plan .*ENG-1 .*DONE' <<<"$out"
assert "list: shows the FAILED implement row" grep -q 'implement .*ENG-2 .*FAILED' <<<"$out"
assert "list: hides poll rows by default" bash -c "! grep -q 'poll' <<<\"\$1\"" _ "$out"
assert "list: poll rows appear with --all" bash -c \
  "python3 '$RUNS_PY' list -n 10 --all | grep -q poll"
# The subagent is sonnet and outnumbers nothing here, but the MODEL column must
# report the act's own loop (opus), not the modal model across subagents.
assert "list: MODEL column is the main-loop model, not the subagent's" \
  grep -q 'ENG-1 .*DONE .*opus-5' <<<"$out"

# A row that carries ap-cycle.sh's own model field is trusted over the
# transcript; the fixture above has no model field, so this proves the
# preference rather than the fallback.
cat >>"$AP_HOME/runs/2026-08-12.jsonl" <<LEDGER2
{"ts":"2026-08-12T03:00:00Z","issue":"ENG-3","phase":"ship","status":"DONE","cost":1.0,"session_id":"dddddddd-0000-0000-0000-000000000000","model":"sonnet"}
LEDGER2
assert "list: uses the ledger's model field when present (no transcript needed)" \
  bash -c "python3 '$RUNS_PY' list -n 10 | grep -q 'ENG-3 .*DONE .*sonnet'"

# --- show --------------------------------------------------------------------
out="$(python3 "$RUNS_PY" show "${SID_OK:0:8}" 2>&1)"
assert "show: resolves a session-id prefix" grep -q "$SID_OK" <<<"$out"
assert "show: reports the ledger cost" grep -q '7.5000' <<<"$out"
assert "show: recovers the run dir from the prompt (no XML tail)" \
  grep -qx "  run dir    $RUN_OK" <<<"$out"
# Three assistant lines exist (msg_1 twice + the subagent's msg_2). Counting
# responses rather than lines gives 2; a broken dedupe would report 3.
assert "show: dedupes one response written as two content-block lines" \
  grep -q 'requests 2' <<<"$out"
assert "show: counts the subagent" grep -q 'subagents 1' <<<"$out"
assert "show: names the main-loop model and the subagent mix separately" \
  grep -q 'opus-5.*+subagents: sonnet-5x1' <<<"$out"
assert "show: lists the tool mix" grep -q 'Bash 1' <<<"$out"
assert "show: prints status.json when present" grep -q '"status": *"DONE"' <<<"$out"
assert "show: prints the final message" grep -q 'Plan committed.' <<<"$out"

out="$(python3 "$RUNS_PY" show ENG-2 2>&1)"
assert "show: resolves by issue id" grep -q "$SID_BAD" <<<"$out"
assert "show: flags a missing status.json as the cause of FAILED" \
  grep -q 'MISSING' <<<"$out"
assert "show: surfaces stderr" grep -q 'boom: something on stderr' <<<"$out"
assert "show: counts api errors" grep -q 'api 1' <<<"$out"

out="$(python3 "$RUNS_PY" show ENG-1 --timeline 2>&1)"
assert "show --timeline: renders the tool call with its argument" \
  grep -q 'Bash(command=git status)' <<<"$out"

# --- cost/model: backend for ap-cycle.sh's/ap-resume.sh's persistent-mode
# ledger rows, which have no -p JSON blob to read total_cost_usd from ------
# SID_OK: opus main loop (in=10,out=20,cache_r=500,cache_w=100, no 1h/5m
# breakdown -> assumed 5m rate) + a sonnet subagent (in=5,out=7,cache_r=50).
# Hand-computed at the published per-Mtok rates: opus 0.004275 + sonnet
# 0.000135 = 0.00441 exactly.
out="$(python3 "$RUNS_PY" cost "$SID_OK" 2>/dev/null)"
assert "cost: estimates from token usage x published rates" \
  bash -c "[ \"\$1\" = '0.004410' ]" _ "$out"
out="$(python3 "$RUNS_PY" model "$SID_OK" 2>&1)"
assert "model: reports the main loop's model, not the subagent's" \
  bash -c "[ \"\$1\" = 'opus-5' ]" _ "$out"
assert "cost: unknown session prints 0, not an error" \
  bash -c "[ \"\$(python3 '$RUNS_PY' cost does-not-exist 2>/dev/null)\" = '0' ]"

# --- tail-text: backend for ap-cycle.sh's persistent-mode FAILED reconcile --
# A persistent act has no -p JSON blob, so stdout/stderr are blind to the
# EXTERNAL_SIGNATURE_REGEX classifier -- this is what mislabeled ENG-1308
# `failed` instead of re-queuing it on 2026-08-14, a real usage-limit
# interruption with nothing in stdout/stderr to classify it by. tail-text
# pulls the act's own final assistant message instead, which usually isn't
# blind (the model explains what happened, in-transcript).
SID_LIMIT="eeeeeeee-1111-2222-3333-444444444444"
cat >"$AP_PROJECTS_DIR/proj/$SID_LIMIT.jsonl" <<T4
{"type":"assistant","timestamp":"2026-08-14T16:00:00Z","message":{"id":"msg_limit","model":"claude-sonnet-5","content":[{"type":"text","text":"Both implementer agents were cut off by a session usage limit (external cause, not a plan defect)."}],"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1}}}
T4
out="$(python3 "$RUNS_PY" tail-text "$SID_LIMIT" 2>&1)"
assert "tail-text: surfaces the model's own explanation" \
  grep -qi 'session usage limit' <<<"$out"
assert "tail-text: unknown session prints empty, not an error" \
  bash -c "[ -z \"\$(python3 '$RUNS_PY' tail-text does-not-exist 2>/dev/null)\" ]"

# --- retry: manual re-queue for a FAILED act, backend for the dashboard's
# [r]etry action -- goes straight through ap_queue.transition() now, no gh
# call and no inbox issue number involved at all -----------------------------
# ENG-2's ledger row is phase=implement/FAILED (see LEDGER above), so a queue
# ticket must exist for it first (retry_act looks it up by eng_id, same as a
# live pipeline would have from `ap queue`/plan/implement already having run).
python3 "$BIN_DIR/ap_queue.py" --ap-home "$AP_HOME" new ENG-2 >/dev/null

out="$(python3 "$RUNS_PY" retry ENG-2 2>&1)"
assert "retry: re-queues a FAILED implement act to plan-review" \
  grep -q 'plan-review' <<<"$out"
assert "retry: reports the re-queue in eng-id terms, not a gh issue number" \
  grep -q 'ENG-2' <<<"$out"
ticket_state="$(python3 -c "
import json
print(json.load(open('$AP_HOME/queue/ENG-2.json'))['state'])
")"
assert "retry: queue ticket transitioned to plan-review on disk" \
  [ "$ticket_state" = "plan-review" ]
ticket_history="$(python3 -c "
import json
d = json.load(open('$AP_HOME/queue/ENG-2.json'))
print(d['history'][-1]['event'])
")"
assert "retry: history records the manual re-queue" \
  grep -qi 'manually re-queued' <<<"$ticket_history"
assert "retry: refuses a non-FAILED target" \
  bash -c "python3 '$RUNS_PY' retry ENG-1 2>&1 | grep -qi 'not FAILED'"
assert "retry: refuses an unknown target" \
  bash -c "! python3 '$RUNS_PY' retry nope-nope 2>/dev/null"
assert "retry: refuses a FAILED target with no queue ticket at all" \
  bash -c "
    cat >'$AP_HOME/runs/2026-08-13.jsonl' <<'LEDGER2'
{\"ts\":\"2026-08-13T01:20:00Z\",\"issue\":\"ENG-9\",\"phase\":\"implement\",\"status\":\"FAILED\",\"cost\":1.0,\"session_id\":\"dddddddd-0000-0000-0000-000000000000\"}
LEDGER2
    python3 '$RUNS_PY' retry ENG-9 2>&1 | grep -qi 'no queue entry'
  "

# --- sessions: non-interactive dashboard invocation must not hang ----------
out="$(echo | python3 "$RUNS_PY" sessions 2>&1)"
assert "sessions: non-interactive invocation prints the table and returns" \
  grep -q 'ISSUE' <<<"$out"
# ENG-2 was just retried above, so its FAILED ledger row is now superseded by
# a live queue ticket (plan-review) -- the dashboard correctly shows the
# queue state instead of the stale FAILED outcome (see _dashboard_rows()'s
# "live wins, then a pending queue state, then the ledger" precedence).
assert "sessions: retried ENG-2 shows its new queue state, not the stale FAILED ledger row" \
  grep -q 'ENG-2 .*PLAN-REVIEW' <<<"$out"
# ENG-9 (seeded above with no queue ticket) has no such supersession, so its
# FAILED outcome still surfaces normally.
assert "sessions: lists the FAILED implement row for an act with no queue ticket" \
  grep -q 'ENG-9 .*implement .*FAILED' <<<"$out"

# --- resolution failure ------------------------------------------------------
python3 "$RUNS_PY" show ZZZ-404 >/dev/null 2>&1
assert "show: unknown target exits non-zero" [ "$?" -ne 0 ]

# An issue id must match exactly. `ENG-1` substring-matching a live `ENG-1181`
# act is how `ap run ENG-1` used to report someone else's run.
out="$(python3 "$RUNS_PY" show ENG-1 2>&1)"
assert "show: issue match is exact, not a substring" grep -q "$SID_OK" <<<"$out"
assert "show: exact match does not leak another act's issue" \
  bash -c "! grep -qE 'ENG-1[0-9]' <<<\"\$1\"" _ "$out"

# --- tail --------------------------------------------------------------------
# A finished act has no live pid, so tail must replay and exit rather than hang.
out="$(timeout 10 python3 -u "$RUNS_PY" tail "${SID_OK:0:8}" --from-start 2>&1)"
rc=$?
assert "tail: exits on a finished act (does not hang)" [ "$rc" -eq 0 ]
assert "tail: replays the tool call" grep -q 'Bash(command=git status)' <<<"$out"
assert "tail: replays assistant text" grep -q 'Plan committed.' <<<"$out"

# --- watch with nothing live -------------------------------------------------
python3 "$RUNS_PY" watch >/dev/null 2>&1
assert "watch: exits non-zero when no act is live" [ "$?" -ne 0 ]

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
