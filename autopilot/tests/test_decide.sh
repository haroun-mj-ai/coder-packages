#!/usr/bin/env bash
# Self-contained test harness for ap-decide.sh / ap-decide.py. No network, no
# real gh. Stubs gh on PATH, drives it via env vars, and asserts on the
# printed decision JSON plus the recorded gh argv (claim vs dry-run).
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
DECIDE="$BIN_DIR/ap-decide.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# json_field <json-text> <key> -> top-level string/number value, or empty
json_field() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if v is not None:
    print(v)
' "$1" "$2" 2>/dev/null
}

# --- stub gh -----------------------------------------------------------------

make_stub_dir() {
  local dir="$1"
  mkdir -p "$dir"
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
  label=""
  json_fields=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "--label" ]] && label="$a"
    [[ "$prev" == "--json" ]] && json_fields="$a"
    prev="$a"
  done
  if [[ -z "$label" && "$json_fields" == *body* ]]; then
    echo "${AP_TEST_GH_ALL_OPEN:-[]}"
    exit 0
  fi
  case "$label" in
    plan-review) echo "${AP_TEST_GH_PLAN_REVIEW:-[]}" ;;
    needs-input) echo "${AP_TEST_GH_NEEDS_INPUT:-[]}" ;;
    ship-pending) echo "${AP_TEST_GH_SHIP_PENDING:-[]}" ;;
    planning) echo "${AP_TEST_GH_PLANNING:-[]}" ;;
    building) echo "${AP_TEST_GH_BUILDING:-[]}" ;;
    shipping) echo "${AP_TEST_GH_SHIPPING:-[]}" ;;
    *) echo "[]" ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  path="${2:-}"
  num="$(printf '%s' "$path" | sed -n 's#.*/issues/\([0-9][0-9]*\)/comments.*#\1#p')"
  var="AP_TEST_GH_COMMENTS_${num}"
  echo "${!var:-[]}"
  exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  num="${3:-}"
  var="AP_TEST_GH_BODY_${num}"
  echo "${!var:-{\"body\":null\}}"
  exit 0
fi

# issue edit / issue comment: recording the call above is enough.
exit 0
STUB_GH
  chmod +x "$dir/gh"
}

# --- fixture ------------------------------------------------------------------

AP_TEST_VARS=(
  AP_TEST_GH_PLAN_REVIEW AP_TEST_GH_NEEDS_INPUT AP_TEST_GH_SHIP_PENDING
  AP_TEST_GH_PLANNING AP_TEST_GH_BUILDING AP_TEST_GH_SHIPPING AP_TEST_GH_ALL_OPEN
  AP_AUTO_APPROVE
)

setup_case() {
  CASE_AP_HOME="$(mktemp -d)"
  CASE_STUB_DIR="$(mktemp -d)"
  CASE_WORK_REPO="$(mktemp -d)"
  make_stub_dir "$CASE_STUB_DIR"
  for v in "${AP_TEST_VARS[@]}"; do unset "$v"; done
  # Clear any AP_TEST_GH_COMMENTS_*/AP_TEST_GH_BODY_* from a previous case.
  while IFS='=' read -r name _; do
    [[ "$name" == AP_TEST_GH_COMMENTS_* || "$name" == AP_TEST_GH_BODY_* ]] && unset "$name"
  done < <(env)
  unset GITHUB_PERSONAL_ACCESS_TOKEN
}

# run_decide <extra-args...> -> decision JSON on stdout (rc discarded, ap-decide.sh always exits 0)
run_decide() {
  AP_HOME="$CASE_AP_HOME" \
  AP_WORK_REPO="$CASE_WORK_REPO" \
  AP_TEST_STUB_DIR="$CASE_STUB_DIR" \
  PATH="$CASE_STUB_DIR:$PATH" \
    bash "$DECIDE" "$@" 2>"$CASE_AP_HOME/stderr.log"
}

gh_edit_calls() {
  grep -rl '^edit$' "$CASE_STUB_DIR/gh_calls" 2>/dev/null
}

gh_comment_calls() {
  grep -rl '^comment$' "$CASE_STUB_DIR/gh_calls" 2>/dev/null
}

# =============================================================================
# Tier 1: plan-review approved via "go" -> implement, claim plan-review->building
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":10,"title":"ENG-100: fix thing","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_10="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Plan file: /tmp/does-not-exist/plan.md\nsome plan text"},
  {"id":2,"body":"go"}
]))')"
export AP_TEST_GH_COMMENTS_10
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-100-fix.md"
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
assert "tier1: action=implement" [ "$action" = "implement" ]
assert "tier1: issue=ENG-100" [ "$issue" = "ENG-100" ]
assert "tier1: planPath falls back to filesystem listing (Plan file: path missing)" bash -c \
  "echo '$out' | grep -q 'eng-100-fix.md'"
assert "tier1(claim): exactly one gh issue edit call" [ "$(gh_edit_calls | wc -l)" -eq 1 ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier1(claim): edit call removes plan-review" bash -c "grep -qx 'plan-review' '$edit_file'"
assert "tier1(claim): edit call adds building" bash -c "grep -qx 'building' '$edit_file'"

# =============================================================================
# Tier 2: feedback BEATS auto-approve -- a new non-directive comment on an
# `auto`-labeled plan-review issue must replan, never implement.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":11,"title":"ENG-101: thing","labels":[{"name":"plan-review"},{"name":"auto"}]}]'
AP_TEST_GH_COMMENTS_11="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Plan file: /tmp/x/plan.md\nplan text"},
  {"id":2,"body":"actually, use postgres instead"}
]))')"
export AP_TEST_GH_COMMENTS_11
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
feedback="$(json_field "$out" feedback)"
assert "tier2: feedback beats auto-approve -> action=replan" [ "$action" = "replan" ]
assert "tier2: issue=ENG-101" [ "$issue" = "ENG-101" ]
assert "tier2: feedback text carried through" [ "$feedback" = "actually, use postgres instead" ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier2(claim): edit call removes plan-review" bash -c "grep -qx 'plan-review' '$edit_file'"
assert "tier2(claim): edit call adds planning" bash -c "grep -qx 'planning' '$edit_file'"

# =============================================================================
# Tier 1: "auto" is a directive (build now), never feedback, even though it
# is not the literal word "go".
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":12,"title":"ENG-102: thing","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_12="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Plan file: /tmp/x/plan.md\nplan text"},
  {"id":2,"body":"AUTO"}
]))')"
export AP_TEST_GH_COMMENTS_12
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-102-thing.md"
out="$(run_decide --dry-run)"
action="$(json_field "$out" action)"
assert "tier1: 'auto' comment (any case) is a directive -> implement, not replan" [ "$action" = "implement" ]

# =============================================================================
# Agent-authored comments (all three markers) never count as owner input.
# Only agent comments exist after the plan post -> no directive, no
# feedback, and (no auto-approve switch active) no action for this issue.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":13,"title":"ENG-103: thing","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_13="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Plan file: /tmp/x/plan.md\nplan text"},
  {"id":2,"body":"Phase: implement\nsome question"},
  {"id":3,"body":"Autopilot: needs input (phase implement).\n\nsome question"}
]))')"
export AP_TEST_GH_COMMENTS_13
out="$(run_decide --dry-run)"
action="$(json_field "$out" action)"
assert "agent markers: Phase:/Autopilot: comments are never owner input -> action=none" [ "$action" = "none" ]
assert "agent markers(dry-run): no gh edit calls" [ -z "$(gh_edit_calls)" ]

# =============================================================================
# Tier 3: Phase: ship needs-input yields NO action (owner's interactive
# session only).
# =============================================================================
setup_case
export AP_TEST_GH_NEEDS_INPUT='[{"number":14,"title":"ENG-104: thing","labels":[{"name":"needs-input"}]}]'
AP_TEST_GH_COMMENTS_14="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Phase: ship\nthe CI check is red, what should I do?"},
  {"id":2,"body":"just retry it"}
]))')"
export AP_TEST_GH_COMMENTS_14
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
assert "tier3: Phase: ship -> action=none" [ "$action" = "none" ]
assert "tier3: Phase: ship -> no gh edit performed" [ -z "$(gh_edit_calls)" ]

# =============================================================================
# Tier 3: Phase: implement (and missing Phase: line) fold into a replan.
# =============================================================================
setup_case
export AP_TEST_GH_NEEDS_INPUT='[{"number":15,"title":"ENG-105: thing","labels":[{"name":"needs-input"}]}]'
AP_TEST_GH_COMMENTS_15="$(python3 -c 'import json; print(json.dumps([
  {"id":1,"body":"Phase: implement\nwhich table should this use?"},
  {"id":2,"body":"the users table"}
]))')"
export AP_TEST_GH_COMMENTS_15
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
feedback="$(json_field "$out" feedback)"
assert "tier3: Phase: implement -> action=replan" [ "$action" = "replan" ]
assert "tier3: issue=ENG-105" [ "$issue" = "ENG-105" ]
assert "tier3: feedback carries the answer" [ "$feedback" = "the users table" ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier3(claim): edit removes needs-input" bash -c "grep -qx 'needs-input' '$edit_file'"
assert "tier3(claim): edit adds planning" bash -c "grep -qx 'planning' '$edit_file'"

# =============================================================================
# Tier 5: missing ENG id in title -> needs-input + no action, continues scan.
# =============================================================================
setup_case
export AP_TEST_GH_ALL_OPEN='[{"number":20,"title":"fix the thing (no id)","labels":[{"name":"Queued"}],"body":""}]'
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
assert "tier5: missing ENG id -> action=none" [ "$action" = "none" ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier5: missing id -> edit removes Queued" bash -c "grep -qx 'Queued' '$edit_file'"
assert "tier5: missing id -> edit adds needs-input" bash -c "grep -qx 'needs-input' '$edit_file'"
assert "tier5: missing id -> a comment asking for the id was posted" [ -n "$(gh_comment_calls)" ]

# =============================================================================
# Tier 1/4: unresolvable planPath -> needs-input + no action, continues scan.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":21,"title":"ENG-106: thing","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_21="$(python3 -c 'import json; print(json.dumps([{"id":1,"body":"go"}]))')"
export AP_TEST_GH_COMMENTS_21
export AP_TEST_GH_BODY_21='{"body":null}'
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
assert "tier1: unresolvable planPath -> action=none (not implement)" [ "$action" = "none" ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier1: unresolvable planPath -> edit removes plan-review" bash -c "grep -qx 'plan-review' '$edit_file'"
assert "tier1: unresolvable planPath -> edit adds needs-input" bash -c "grep -qx 'needs-input' '$edit_file'"

# =============================================================================
# Busy-lane skipping: build busy -> an otherwise-approved plan-review issue
# is left untouched (no claim), and the invocation ends with action=none if
# nothing else applies.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":22,"title":"ENG-107: thing","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_22="$(python3 -c 'import json; print(json.dumps([{"id":1,"body":"go"}]))')"
export AP_TEST_GH_COMMENTS_22
out="$(run_decide --claim --busy build)"
action="$(json_field "$out" action)"
assert "busy(build): approved item's lane is busy -> action=none" [ "$action" = "none" ]
assert "busy(build): no gh edit performed on the skipped item" [ -z "$(gh_edit_calls)" ]

# =============================================================================
# Oldest-first within a tier: two approved plan-review issues, lower number
# wins.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":30,"title":"ENG-200: b","labels":[{"name":"plan-review"}]},{"number":25,"title":"ENG-199: a","labels":[{"name":"plan-review"}]}]'
AP_TEST_GH_COMMENTS_30="$(python3 -c 'import json; print(json.dumps([{"id":1,"body":"go"}]))')"
export AP_TEST_GH_COMMENTS_30
AP_TEST_GH_COMMENTS_25="$(python3 -c 'import json; print(json.dumps([{"id":1,"body":"go"}]))')"
export AP_TEST_GH_COMMENTS_25
export AP_TEST_GH_BODY_30='{"body":null}'
export AP_TEST_GH_BODY_25='{"body":null}'
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-199-a.md"
touch "$CASE_WORK_REPO/docs/plans/eng-200-b.md"
out="$(run_decide --dry-run)"
issue="$(json_field "$out" issue)"
assert "oldest-first: lower issue number (25/ENG-199) wins over 30/ENG-200" [ "$issue" = "ENG-199" ]

# =============================================================================
# --dry-run performs NO gh writes; --claim performs exactly the expected swap.
# =============================================================================
setup_case
export AP_TEST_GH_SHIP_PENDING='[{"number":40,"title":"ENG-300: thing","labels":[{"name":"ship-pending"}]}]'
export AP_TEST_GH_COMMENTS_40='[]'
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-300-thing.md"
out_dry="$(run_decide --dry-run)"
assert "dry-run: action=ship decided" [ "$(json_field "$out_dry" action)" = "ship" ]
assert "dry-run: no gh edit calls at all" [ -z "$(gh_edit_calls)" ]
assert "dry-run: no gh comment calls at all" [ -z "$(gh_comment_calls)" ]

setup_case
export AP_TEST_GH_SHIP_PENDING='[{"number":40,"title":"ENG-300: thing","labels":[{"name":"ship-pending"}]}]'
export AP_TEST_GH_COMMENTS_40='[]'
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-300-thing.md"
out_claim="$(run_decide --claim)"
assert "claim: action=ship decided" [ "$(json_field "$out_claim" action)" = "ship" ]
edits="$(gh_edit_calls)"
assert "claim: exactly one edit call" [ "$(echo "$edits" | wc -l)" -eq 1 ]
edit_file="$(echo "$edits" | head -1)"
assert "claim: edit removes ship-pending" bash -c "grep -qx 'ship-pending' '$edit_file'"
assert "claim: edit adds shipping" bash -c "grep -qx 'shipping' '$edit_file'"
assert "claim: edit targets issue 40" bash -c "grep -qx '40' '$edit_file'"

# =============================================================================
# Tier 4: ship-pending emits planPath and inboxIssue.
# =============================================================================
setup_case
export AP_TEST_GH_SHIP_PENDING='[{"number":41,"title":"ENG-301: thing","labels":[{"name":"ship-pending"}]}]'
AP_TEST_GH_COMMENTS_41="$(python3 -c 'import json; print(json.dumps([{"id":1,"body":"Plan file: /tmp/nonexist/p.md"}]))')"
export AP_TEST_GH_COMMENTS_41
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-301-thing.md"
out="$(run_decide --dry-run)"
assert "tier4: action=ship" [ "$(json_field "$out" action)" = "ship" ]
assert "tier4: inboxIssue=41" [ "$(json_field "$out" inboxIssue)" = "41" ]
assert "tier4: planPath resolved via filesystem fallback" bash -c "echo '$out' | grep -q 'eng-301-thing.md'"

# =============================================================================
# Tier 5: happy path -- Queued issue with a real ENG id claims plan and
# carries the title note as feedback.
# =============================================================================
setup_case
export AP_TEST_GH_ALL_OPEN='[{"number":50,"title":"ENG-400: add the widget","labels":[{"name":"Queued"}],"body":""}]'
out="$(run_decide --claim)"
assert "tier5: action=plan" [ "$(json_field "$out" action)" = "plan" ]
assert "tier5: issue=ENG-400" [ "$(json_field "$out" issue)" = "ENG-400" ]
assert "tier5: feedback carries the title note" [ "$(json_field "$out" feedback)" = "add the widget" ]
edit_file="$(gh_edit_calls | head -1)"
assert "tier5(claim): edit removes Queued" bash -c "grep -qx 'Queued' '$edit_file'"
assert "tier5(claim): edit adds planning" bash -c "grep -qx 'planning' '$edit_file'"

# =============================================================================
# Tier 6: nothing actionable -> {"action":"none"}, no gh writes.
# =============================================================================
setup_case
out="$(run_decide --claim)"
assert "tier6: action=none on an empty inbox" [ "$(json_field "$out" action)" = "none" ]
assert "tier6: no gh edit calls" [ -z "$(gh_edit_calls)" ]

# =============================================================================
# Always exits 0 and prints a valid JSON object, even under --busy with
# every lane busy at once.
# =============================================================================
setup_case
export AP_TEST_GH_PLAN_REVIEW='[{"number":60,"title":"ENG-500: thing","labels":[{"name":"plan-review"}]}]'
export AP_TEST_GH_NEEDS_INPUT='[{"number":61,"title":"ENG-501: thing","labels":[{"name":"needs-input"}]}]'
export AP_TEST_GH_SHIP_PENDING='[{"number":62,"title":"ENG-502: thing","labels":[{"name":"ship-pending"}]}]'
export AP_TEST_GH_ALL_OPEN='[{"number":63,"title":"ENG-503: thing","labels":[{"name":"Queued"}],"body":""}]'
out="$(run_decide --claim --busy build,ship,plan)"
assert "all-lanes-busy: action=none" [ "$(json_field "$out" action)" = "none" ]
assert "all-lanes-busy: no gh edit calls" [ -z "$(gh_edit_calls)" ]

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
