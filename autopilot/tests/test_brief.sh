#!/usr/bin/env bash
# Self-contained test harness for ap-brief.sh. No network, no real
# claude/gh/tmux. Stubs claude/gh/ap-notify.sh on PATH, drives them via env
# vars, and asserts on the input file it wrote, the digest it produced, and
# the marker/brief-file bookkeeping.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
BRIEF="$BIN_DIR/ap-brief.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# --- stub bin dir ------------------------------------------------------------

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

# Record the --input file's contents at call time, before ap-brief.sh
# deletes it, so tests can assert on exactly what the session was handed.
# The path rides inside the single "/daily-brief --input <path>" prompt arg
# (one -p argument), not as its own argv token.
for a in "$@"; do
  if [[ "$a" == *"--input "* ]]; then
    input_path="${a#*--input }"
    cp "$input_path" "$calls_dir/$n.input.json" 2>/dev/null || true
  fi
done

if [[ "${AP_TEST_CLAUDE_CRASH:-}" == "1" ]]; then
  echo "stub: claude crashed" >&2
  exit 1
fi

printf '%s' "${AP_TEST_DIGEST:-canned digest}"
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
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  echo "${AP_TEST_GH_INBOX_ISSUES:-[]}"
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

  cat >"$dir/tmux" <<'STUB_TMUX'
#!/usr/bin/env bash
if [[ "${1:-}" == "has-session" ]]; then
  [[ "${AP_TEST_TMUX_ALIVE:-0}" == "1" ]] && exit 0
  exit 1
fi
exit 0
STUB_TMUX

  chmod +x "$dir/claude" "$dir/gh" "$dir/ap-notify.sh" "$dir/tmux"
}

# --- per-case fixture --------------------------------------------------------

AP_TEST_VARS=(AP_TEST_CLAUDE_CRASH AP_TEST_DIGEST AP_TEST_GH_INBOX_ISSUES AP_TEST_TMUX_ALIVE)

setup_case() {
  CASE_AP_HOME="$(mktemp -d)"
  CASE_STUB_DIR="$(mktemp -d)"
  CASE_WORK_REPO="$(mktemp -d)"
  (cd "$CASE_WORK_REPO" && git init -q && git config user.email t@t.com && git config user.name t)
  make_stub_dir "$CASE_STUB_DIR"
  for v in "${AP_TEST_VARS[@]}"; do unset "$v"; done
  unset GITHUB_PERSONAL_ACCESS_TOKEN NTFY_TOPIC SLACK_WEBHOOK_URL
}

run_case() {
  AP_HOME="$CASE_AP_HOME" \
  AP_WORK_REPO="$CASE_WORK_REPO" \
  AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
  PATH="$CASE_STUB_DIR:$PATH" \
    bash "$BRIEF" >"$CASE_AP_HOME/stdout.log" 2>"$CASE_AP_HOME/stderr.log"
  echo $?
}

today_brief_file() {
  echo "$CASE_AP_HOME/briefs/$(date -u +%F).md"
}

# =============================================================================
# Case (a): input JSON is written before claude runs, is valid JSON, and
# contains a seeded ledger row + the budget numbers.
# =============================================================================
setup_case
mkdir -p "$CASE_AP_HOME/runs"
recent_ts="$(date -u +%FT%TZ)"
echo "{\"ts\":\"$recent_ts\",\"issue\":\"ENG-1\",\"phase\":\"implement\",\"status\":\"DONE\",\"cost\":1.5,\"session_id\":\"s1\"}" \
  >"$CASE_AP_HOME/runs/$(date -u +%F).jsonl"
export AP_MAX_ISSUES_PER_DAY=7
export AP_MAX_DAY_COST_USD=42
rc="$(run_case)"
assert "case_a: exit 0" [ "$rc" -eq 0 ]
input_capture="$CASE_STUB_DIR/claude_calls/1.input.json"
assert "case_a: input file was captured (existed at claude call time)" [ -f "$input_capture" ]
assert "case_a: input file is valid JSON" bash -c "python3 -c \"import json; json.load(open('$input_capture'))\""
assert "case_a: input file contains the seeded ledger row" bash -c \
  "python3 -c \"
import json
d = json.load(open('$input_capture'))
assert any(r.get('issue') == 'ENG-1' and r.get('cost') == 1.5 for r in d['ledger']), d['ledger']
\""
assert "case_a: input file's budget carries max_issues/max_cost" bash -c \
  "python3 -c \"
import json
d = json.load(open('$input_capture'))
assert d['budget']['max_issues'] == 7, d['budget']
assert d['budget']['max_cost'] == 42, d['budget']
\""
unset AP_MAX_ISSUES_PER_DAY AP_MAX_DAY_COST_USD

# =============================================================================
# Case (b): claude argv includes --input <path> and --settings.
# =============================================================================
setup_case
rc="$(run_case)"
args_file="$CASE_STUB_DIR/claude_calls/1.args"
assert "case_b: exit 0" [ "$rc" -eq 0 ]
assert "case_b: claude call recorded" [ -f "$args_file" ]
assert "case_b: claude argv has --input" bash -c "grep -q -- '--input' '$args_file'"
assert "case_b: --input path points at the project" bash -c \
  "grep -q -- '--input $CASE_WORK_REPO/.autopilot-brief-input.json' '$args_file'"
assert "case_b: claude argv has --settings" bash -c "grep -qx -- '--settings' '$args_file'"
assert "case_b: --settings path is absolute autopilot.json" bash -c \
  "grep -q '/autopilot/settings/autopilot.json$' '$args_file'"

# =============================================================================
# Case (c): digest lands in $AP_HOME/briefs/YYYY-MM-DD.md, marker updated,
# input file deleted, notify called with the digest.
# =============================================================================
setup_case
export AP_TEST_DIGEST="hello digest body"
rc="$(run_case)"
assert "case_c: exit 0" [ "$rc" -eq 0 ]
brief_file="$(today_brief_file)"
assert "case_c: brief file written" [ -f "$brief_file" ]
assert "case_c: brief file contains the digest" bash -c "grep -q 'hello digest body' '$brief_file'"
assert "case_c: marker updated" [ -f "$CASE_AP_HOME/briefs/.last-brief-ts" ]
assert "case_c: input file deleted from the project" [ ! -f "$CASE_WORK_REPO/.autopilot-brief-input.json" ]
assert "case_c: notify called with the digest" bash -c \
  "grep -rl 'hello digest body' '$CASE_STUB_DIR/notify_calls' >/dev/null"
unset AP_TEST_DIGEST

# =============================================================================
# Case (d): claude stub exits 1 -> notify called with "daily brief failed",
# exit 0, marker NOT updated.
# =============================================================================
setup_case
export AP_TEST_CLAUDE_CRASH=1
rc="$(run_case)"
assert "case_d: exit 0" [ "$rc" -eq 0 ]
assert "case_d: notify called with failure title" bash -c \
  "grep -rl 'daily brief failed' '$CASE_STUB_DIR/notify_calls' >/dev/null"
assert "case_d: marker NOT updated" [ ! -f "$CASE_AP_HOME/briefs/.last-brief-ts" ]
assert "case_d: no brief file written" [ ! -f "$(today_brief_file)" ]
unset AP_TEST_CLAUDE_CRASH

# =============================================================================
# Case (e): exclude fence added once; second run doesn't duplicate it.
# =============================================================================
setup_case
rc1="$(run_case)"
assert "case_e: run1 exit 0" [ "$rc1" -eq 0 ]
exclude_file="$CASE_WORK_REPO/.git/info/exclude"
assert "case_e: exclude file has the input filename" bash -c \
  "grep -qx '.autopilot-brief-input.json' '$exclude_file'"
fence_count_1="$(grep -c 'autopilot ap-brief.sh (managed)' "$exclude_file")"
rc2="$(run_case)"
assert "case_e: run2 exit 0" [ "$rc2" -eq 0 ]
fence_count_2="$(grep -c 'autopilot ap-brief.sh (managed)' "$exclude_file")"
assert "case_e: fence not duplicated on second run" [ "$fence_count_1" -eq "$fence_count_2" ]
entry_count="$(grep -cx '.autopilot-brief-input.json' "$exclude_file")"
assert "case_e: input filename entry appears exactly once" [ "$entry_count" -eq 1 ]

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
