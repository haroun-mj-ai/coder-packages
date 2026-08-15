#!/usr/bin/env bash
# Self-contained test harness for ap-decide.sh / ap-decide.py. No network, no
# real gh, no comment parsing -- seeds $AP_HOME/queue/<ENG-ID>.json fixture
# files directly (the local queue that replaced the GitHub inbox, see
# ap_queue.py) and asserts on the printed decision JSON plus the resulting
# queue ticket's state/fields on disk after a --mode claim run.
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

# --- queue fixture helpers -----------------------------------------------------

# seed_ticket <ap-home> <eng-id> <state> [field=value ...]
# Writes a full-schema ticket (via ap_queue.new_ticket, so seq is assigned the
# same monotonic-counter way the real pipeline assigns it -- lower seq means
# "seeded earlier", the drop-in replacement for a lower GitHub issue number)
# then overwrites `state` and any extra fields given. Values are JSON-decoded
# when possible so `pending_approval=true` / `auto_approve=true` etc. work.
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

# ticket_field <ap-home> <eng-id> <field> -> the field's value (raw for
# strings/numbers/bools, JSON-encoded otherwise), or empty if absent/missing.
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

# append_ledger_row <ap-home> <eng-id> <ts>
append_ledger_row() {
  local ap_home="$1" eng_id="$2" ts="$3"
  mkdir -p "$ap_home/runs"
  printf '{"ts":"%s","issue":"%s","phase":"implement","status":"plan","cost":0.1}\n' \
    "$ts" "$eng_id" >>"$ap_home/runs/fixture.jsonl"
}

# --- fixture ------------------------------------------------------------------

setup_case() {
  CASE_AP_HOME="$(mktemp -d)"
  CASE_WORK_REPO="$(mktemp -d)"
  unset AP_AUTO_APPROVE
}

# run_decide <extra-args...> -> decision JSON on stdout (rc discarded, ap-decide.sh always exits 0)
run_decide() {
  AP_HOME="$CASE_AP_HOME" \
  AP_WORK_REPO="$CASE_WORK_REPO" \
    bash "$DECIDE" "$@" 2>"$CASE_AP_HOME/stderr.log"
}

# =============================================================================
# Tier 1: plan-review approved (pending_approval) -> implement, claim
# plan-review -> building, plan_path resolved via filesystem fallback since
# the ticket's own plan_path field points nowhere.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-100 plan-review pending_approval=true
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-100-fix.md"
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
assert "tier1: action=implement" [ "$action" = "implement" ]
assert "tier1: issue=ENG-100" [ "$issue" = "ENG-100" ]
assert "tier1: planPath falls back to filesystem listing (ticket's plan_path unset)" \
  bash -c "echo '$out' | grep -q 'eng-100-fix.md'"
assert "tier1(claim): ticket state -> building" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-100 state)" = "building" ]
assert "tier1(claim): pending_approval cleared" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-100 pending_approval)" = "False" ]
assert "tier1(claim): plan_path persisted on the ticket" \
  bash -c "echo '$(ticket_field "$CASE_AP_HOME" ENG-100 plan_path)' | grep -q 'eng-100-fix.md'"

# =============================================================================
# Tier 2: feedback BEATS approval -- a ticket with BOTH pending_approval and
# fresh feedback must replan, never implement (matches the old GitHub-comment
# suite's "feedback beats auto-approve" case one-for-one).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-101 plan-review \
  pending_approval=true auto_approve=true feedback='"actually, use postgres instead"'
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
feedback="$(json_field "$out" feedback)"
assert "tier2: feedback beats approval -> action=replan" [ "$action" = "replan" ]
assert "tier2: issue=ENG-101" [ "$issue" = "ENG-101" ]
assert "tier2: feedback text carried through" [ "$feedback" = "actually, use postgres instead" ]
assert "tier2(claim): ticket state -> planning" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-101 state)" = "planning" ]
assert "tier2(claim): feedback field cleared" \
  [ -z "$(ticket_field "$CASE_AP_HOME" ENG-101 feedback)" ]

# =============================================================================
# Tier 1: a ticket's own persistent auto_approve switch approves it exactly
# like pending_approval does, with no owner feedback in the way.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-102 plan-review auto_approve=true
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-102-thing.md"
out="$(run_decide --dry-run)"
action="$(json_field "$out" action)"
assert "tier1: auto_approve field (no pending_approval) -> implement" [ "$action" = "implement" ]
assert "tier1(dry-run): auto_approve case leaves the ticket untouched on disk" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-102 state)" = "plan-review" ]

# =============================================================================
# A plan-review ticket with neither feedback nor any approval signal (no
# pending_approval, no auto_approve, no global AP_AUTO_APPROVE) is simply
# left alone -- no action, no write. (Replaces the old suite's "agent-authored
# comments never count as owner input" case: there is no comment channel to
# misparse anymore, so the only way this happens now is an untouched ticket.)
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-103 plan-review
out="$(run_decide --dry-run)"
action="$(json_field "$out" action)"
assert "tier1/2: no approval signal, no feedback -> action=none" [ "$action" = "none" ]
assert "tier1/2(dry-run): ticket untouched" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-103 state)" = "plan-review" ]

# =============================================================================
# Tier 3: a needs-input ticket answered while phase_at_question=ship yields
# NO action (owner's interactive /ship-work session or tmux attach only) and
# leaves the ticket exactly as it was.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-104 needs-input \
  feedback='"just retry it"' phase_at_question='"ship"' \
  question='"the CI check is red, what should I do?"'
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
assert "tier3: phase_at_question=ship -> action=none" [ "$action" = "none" ]
assert "tier3: phase_at_question=ship -> ticket left in needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-104 state)" = "needs-input" ]
assert "tier3: phase_at_question=ship -> feedback left untouched (nothing acted on it)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-104 feedback)" = "just retry it" ]

# =============================================================================
# Tier 3: phase_at_question=implement (and a missing phase_at_question,
# defaulting to "plan") both fold into a replan.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-105 needs-input \
  feedback='"the users table"' phase_at_question='"implement"' \
  question='"which table should this use?"'
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
issue="$(json_field "$out" issue)"
feedback="$(json_field "$out" feedback)"
assert "tier3: phase_at_question=implement -> action=replan" [ "$action" = "replan" ]
assert "tier3: issue=ENG-105" [ "$issue" = "ENG-105" ]
assert "tier3: feedback carries the answer" [ "$feedback" = "the users table" ]
assert "tier3(claim): ticket state -> planning" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-105 state)" = "planning" ]
assert "tier3(claim): feedback/question/phase_at_question all cleared" \
  bash -c '[ -z "$(ticket_field "$1" ENG-105 feedback)" ] &&
           [ -z "$(ticket_field "$1" ENG-105 question)" ] &&
           [ -z "$(ticket_field "$1" ENG-105 phase_at_question)" ]' _ "$CASE_AP_HOME"

setup_case
seed_ticket "$CASE_AP_HOME" ENG-105b needs-input feedback='"sure, go ahead"'
out="$(run_decide --claim)"
assert "tier3: missing phase_at_question defaults to plan -> action=replan" \
  [ "$(json_field "$out" action)" = "replan" ]

# =============================================================================
# Tier 3: a parked needs-input ticket (a live persistent session already
# holds this exact question in its own tmux window) is skipped entirely --
# ap-cycle.sh's scan_parked_replies relays a fresh reply straight into that
# window, never through a fresh claim/dispatch here.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-105c needs-input feedback='"the answer"'
mkdir -p "$CASE_AP_HOME/parked"
echo '{}' >"$CASE_AP_HOME/parked/ENG-105c.json"
out="$(run_decide --claim)"
assert "tier3: parked ticket -> skipped, action=none" \
  [ "$(json_field "$out" action)" = "none" ]
assert "tier3: parked ticket -> left in needs-input, feedback untouched" \
  bash -c '[ "$(ticket_field "$1" ENG-105c state)" = "needs-input" ] &&
           [ "$(ticket_field "$1" ENG-105c feedback)" = "the answer" ]' _ "$CASE_AP_HOME"

# =============================================================================
# Tier 1/4: unresolvable planPath -> needs-input + no action, continues scan
# instead of crashing or wedging on the unresolved ticket.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-106 plan-review pending_approval=true
out="$(run_decide --claim)"
action="$(json_field "$out" action)"
assert "tier1: unresolvable planPath -> action=none (not implement)" [ "$action" = "none" ]
assert "tier1: unresolvable planPath -> ticket moved to needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-106 state)" = "needs-input" ]
assert "tier1: unresolvable planPath -> phase_at_question=plan" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-106 phase_at_question)" = "plan" ]

# =============================================================================
# Busy-lane skipping: build busy -> an otherwise-approved plan-review ticket
# is left untouched (no claim), and the invocation ends with action=none if
# nothing else applies.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-107 plan-review pending_approval=true
out="$(run_decide --claim --busy build)"
action="$(json_field "$out" action)"
assert "busy(build): approved item's lane is busy -> action=none" [ "$action" = "none" ]
assert "busy(build): ticket left untouched" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-107 state)" = "plan-review" ]

# =============================================================================
# Oldest-first within a tier: two approved plan-review tickets -- the one
# seeded FIRST (lower seq, ap_queue's oldest-first-by-seq replacement for
# oldest-first-by-issue-number) wins, regardless of ENG-id ordering.
# =============================================================================
setup_case
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-199-a.md"
touch "$CASE_WORK_REPO/docs/plans/eng-200-b.md"
seed_ticket "$CASE_AP_HOME" ENG-199 plan-review pending_approval=true
seed_ticket "$CASE_AP_HOME" ENG-200 plan-review pending_approval=true
out="$(run_decide --dry-run)"
issue="$(json_field "$out" issue)"
assert "oldest-first: lower seq (ENG-199, seeded first) wins over ENG-200" [ "$issue" = "ENG-199" ]

# =============================================================================
# --dry-run performs NO queue write; --claim performs exactly the expected
# state swap.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-300 ship-pending
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-300-thing.md"
out_dry="$(run_decide --dry-run)"
assert "dry-run: action=ship decided" [ "$(json_field "$out_dry" action)" = "ship" ]
assert "dry-run: ticket untouched on disk" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-300 state)" = "ship-pending" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-300 ship-pending
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-300-thing.md"
out_claim="$(run_decide --claim)"
assert "claim: action=ship decided" [ "$(json_field "$out_claim" action)" = "ship" ]
assert "claim: ticket state -> shipping" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-300 state)" = "shipping" ]

# =============================================================================
# Tier 4: ship-pending resolves planPath via filesystem fallback.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-301 ship-pending
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-301-thing.md"
out="$(run_decide --dry-run)"
assert "tier4: action=ship" [ "$(json_field "$out" action)" = "ship" ]
assert "tier4: planPath resolved via filesystem fallback" bash -c "echo '$out' | grep -q 'eng-301-thing.md'"

# =============================================================================
# Tier 5: happy path -- a queued ticket claims plan and carries its note
# through as feedback (drop-in for the old "title note" carry-through).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-400 queued note='"add the widget"'
out="$(run_decide --claim)"
assert "tier5: action=plan" [ "$(json_field "$out" action)" = "plan" ]
assert "tier5: issue=ENG-400" [ "$(json_field "$out" issue)" = "ENG-400" ]
assert "tier5: feedback carries the ticket's note" [ "$(json_field "$out" feedback)" = "add the widget" ]
assert "tier5(claim): ticket state -> planning" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-400 state)" = "planning" ]

# =============================================================================
# ap_queue itself rejects a bad ENG id at intake time (via its own `new`
# subcommand and ap-runs.py's cmd_queue) -- so, unlike the old GitHub-title
# parsing this replaced, an invalid id is simply never reachable as a queue
# ticket for ap-decide.py's tier5 to see. Confirms that assumption directly
# rather than leaving it silently unverified.
# =============================================================================
setup_case
rc=0
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" new "not-an-eng-id" 2>/dev/null || rc=$?
assert "intake: ap_queue.py new rejects a non-ENG-<n> id" [ "$rc" -ne 0 ]
assert "intake: no ticket file was created for the rejected id" \
  [ ! -f "$CASE_AP_HOME/queue/not-an-eng-id.json" ]

# =============================================================================
# Tier 6: nothing actionable -> {"action":"none"}, no queue writes.
# =============================================================================
setup_case
out="$(run_decide --claim)"
assert "tier6: action=none on an empty queue" [ "$(json_field "$out" action)" = "none" ]
assert "tier6: queue dir stays empty" \
  [ -z "$(ls "$CASE_AP_HOME/queue" 2>/dev/null | grep -v '^\.seq$')" ]

# =============================================================================
# Always exits 0 and prints a valid JSON object, even under --busy with every
# lane busy at once.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-500 plan-review pending_approval=true
seed_ticket "$CASE_AP_HOME" ENG-501 needs-input feedback='"an answer"'
seed_ticket "$CASE_AP_HOME" ENG-502 ship-pending
seed_ticket "$CASE_AP_HOME" ENG-503 queued
out="$(run_decide --claim --busy build,ship,plan)"
assert "all-lanes-busy: action=none" [ "$(json_field "$out" action)" = "none" ]
assert "all-lanes-busy: nothing was written" \
  bash -c '[ "$(ticket_field "$1" ENG-500 state)" = "plan-review" ] &&
           [ "$(ticket_field "$1" ENG-501 state)" = "needs-input" ] &&
           [ "$(ticket_field "$1" ENG-502 state)" = "ship-pending" ] &&
           [ "$(ticket_field "$1" ENG-503 state)" = "queued" ]' _ "$CASE_AP_HOME"

# =============================================================================
# NEW: stale-claim sweep (sweep_stale in ap-decide.py) -- previously untested
# either way. A ticket stuck in planning/building/shipping with NO active
# lane lock and NO ledger row in the last 3h is swept to failed; one with a
# recent ledger row, or one whose lock is actually held, is left alone.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-600 building
out="$(run_decide --claim)"
assert "stale-sweep: no lock, no recent ledger row -> swept to failed" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-600 state)" = "failed" ]
last_event="$(python3 -c "
import json
print(json.load(open('$CASE_AP_HOME/queue/ENG-600.json'))['history'][-1]['event'])
")"
assert "stale-sweep: history explains the sweep" grep -qi 'stale claim swept' <<<"$last_event"

setup_case
seed_ticket "$CASE_AP_HOME" ENG-601 building
append_ledger_row "$CASE_AP_HOME" ENG-601 "$(date -u +%FT%TZ)"
out="$(run_decide --claim)"
assert "stale-sweep: recent ledger row -> NOT swept, stays building" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-601 state)" = "building" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-602 planning
LOCKFILE="$CASE_AP_HOME/lock.issue.ENG-602"
(
  exec 9>"$LOCKFILE"
  flock -x 9
  sleep 5
) &
lock_pid=$!
# Give the background subshell time to actually acquire the flock before we
# race ap-decide.py's own probe against it.
sleep 0.3
out="$(run_decide --claim)"
kill "$lock_pid" 2>/dev/null
wait "$lock_pid" 2>/dev/null
assert "stale-sweep: lock actually held -> NOT swept, stays planning" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-602 state)" = "planning" ]

# =============================================================================
# NEW: approve/reply precedence -- approving always clears any pending
# feedback, and replying always clears pending_approval. This exact class of
# bug (approval/feedback precedence) has a real history of live incidents in
# this codebase, hence the dedicated coverage at the ap_queue.py level that
# every caller (ap-decide.py, ap-cycle.sh, ap-runs.py's `ap approve`/`ap
# reply`) shares.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-700 plan-review feedback='"old feedback nobody acted on"'
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" approve ENG-700 >/dev/null
assert "precedence: approve clears any pending feedback" \
  [ -z "$(ticket_field "$CASE_AP_HOME" ENG-700 feedback)" ]
assert "precedence: approve sets pending_approval" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-700 pending_approval)" = "True" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-701 plan-review pending_approval=true
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" reply ENG-701 "actually wait, use redis" >/dev/null
assert "precedence: reply clears pending_approval" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-701 pending_approval)" = "False" ]
assert "precedence: reply sets the new feedback text" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-701 feedback)" = "actually wait, use redis" ]

# End-to-end: approve-then-reply-then-approve nets out to "approved, no
# feedback" -- the newest human action always wins outright, never merges.
setup_case
seed_ticket "$CASE_AP_HOME" ENG-702 plan-review
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" approve ENG-702 >/dev/null
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" reply ENG-702 "wait, reconsider X" >/dev/null
python3 "$BIN_DIR/ap_queue.py" --ap-home "$CASE_AP_HOME" approve ENG-702 >/dev/null
assert "precedence: approve after reply after approve -> pending_approval true" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-702 pending_approval)" = "True" ]
assert "precedence: approve after reply after approve -> feedback cleared" \
  [ -z "$(ticket_field "$CASE_AP_HOME" ENG-702 feedback)" ]

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
