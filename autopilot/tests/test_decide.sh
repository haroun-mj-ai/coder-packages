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

# seed_rca_file <work-repo> <eng-id> -- writes the exact-match RCA basename
# resolve_rca_path prefers (issue-<eng-id-lower>.md) under docs/issues/.
seed_rca_file() {
  local work_repo="$1" eng_id="$2"
  mkdir -p "$work_repo/docs/issues"
  local lower
  lower="$(echo "$eng_id" | tr '[:upper:]' '[:lower:]')"
  touch "$work_repo/docs/issues/issue-${lower}.md"
}

# seed_piv_plan_file <work-repo> <eng-id> <slug> -- writes the
# docs/plans/<ENG-ID>-<slug>.md shape resolve_piv_plan_path anchors on
# (basename == <eng-lower>.md or starts with <eng-lower>-).
seed_piv_plan_file() {
  local work_repo="$1" eng_id="$2" slug="$3"
  mkdir -p "$work_repo/docs/plans"
  touch "$work_repo/docs/plans/${eng_id}-${slug}.md"
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
# Tier 5: happy path -- a queued ticket (kind defaults to feature) claims
# design and carries its note through as feedback (drop-in for the old
# "title note" carry-through). REWRITTEN, not preserved: per the piv
# feature-fork plan's own audit, `queued` never produces `action: plan`
# again once intake is cut over to the shared piv states -- a feature-kind
# ticket now claims piv-drafting via `design`, not legacy `planning` via
# `plan`.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-400 queued note='"add the widget"'
out="$(run_decide --claim)"
assert "tier5: action=design (feature kind, default)" [ "$(json_field "$out" action)" = "design" ]
assert "tier5: issue=ENG-400" [ "$(json_field "$out" issue)" = "ENG-400" ]
assert "tier5: feedback carries the ticket's note" [ "$(json_field "$out" feedback)" = "add the widget" ]
assert "tier5(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-400 state)" = "piv-drafting" ]

# =============================================================================
# Tier 5: kind=bug at intake claims investigate/piv-drafting instead.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-401 queued kind='"bug"'
out="$(run_decide --claim)"
assert "tier5: action=investigate (bug kind)" [ "$(json_field "$out" action)" = "investigate" ]
assert "tier5(claim): ticket state -> piv-drafting (bug)" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-401 state)" = "piv-drafting" ]

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
# piv-draft-review (bug kind): approved + a resolvable RCA fixture -> fix,
# artifactPath set, state -> piv-implementing.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-800 piv-draft-review pending_approval=true kind='"bug"'
seed_rca_file "$CASE_WORK_REPO" ENG-800
out="$(run_decide --claim)"
assert "piv-draft-review(bug): action=fix" [ "$(json_field "$out" action)" = "fix" ]
assert "piv-draft-review(bug): artifactPath set" \
  bash -c "echo '$out' | grep -q 'issue-eng-800.md'"
assert "piv-draft-review(bug)(claim): ticket state -> piv-implementing" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-800 state)" = "piv-implementing" ]

# =============================================================================
# piv-draft-review (bug kind): feedback -> re-investigate, feedback relayed,
# state -> piv-drafting, feedback cleared.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-801 piv-draft-review kind='"bug"' \
  feedback='"the repro is flaky, check the retry path too"'
out="$(run_decide --claim)"
assert "piv-draft-review(bug): feedback -> action=re-investigate" \
  [ "$(json_field "$out" action)" = "re-investigate" ]
assert "piv-draft-review(bug): feedback relayed" \
  [ "$(json_field "$out" feedback)" = "the repro is flaky, check the retry path too" ]
assert "piv-draft-review(bug)(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-801 state)" = "piv-drafting" ]
assert "piv-draft-review(bug)(claim): feedback cleared" \
  [ -z "$(ticket_field "$CASE_AP_HOME" ENG-801 feedback)" ]

# =============================================================================
# piv-draft-review (bug kind): feedback + pending_approval -> feedback wins
# (mirrors the legacy plan-review precedence case).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-802 piv-draft-review kind='"bug"' \
  pending_approval=true feedback='"wrong root cause, look again"'
out="$(run_decide --claim)"
assert "piv-draft-review(bug): feedback beats approval -> action=re-investigate" \
  [ "$(json_field "$out" action)" = "re-investigate" ]
assert "piv-draft-review(bug)(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-802 state)" = "piv-drafting" ]

# =============================================================================
# piv-draft-review (bug kind): approved, RCA unresolvable -> needs-input,
# phase_at_question=investigate, scan continues (never crashes/wedges).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-803 piv-draft-review pending_approval=true kind='"bug"'
out="$(run_decide --claim)"
assert "piv-draft-review(bug): unresolvable RCA -> action=none" [ "$(json_field "$out" action)" = "none" ]
assert "piv-draft-review(bug): unresolvable RCA -> ticket moved to needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-803 state)" = "needs-input" ]
assert "piv-draft-review(bug): unresolvable RCA -> phase_at_question=investigate" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-803 phase_at_question)" = "investigate" ]

# =============================================================================
# piv-review-pending: pr_urls non-empty + review lane free -> review,
# prUrl set, state -> piv-reviewing.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-804 piv-review-pending pr_urls='["https://github.com/x/y/pull/1"]'
out="$(run_decide --claim)"
assert "piv-review-pending: action=review" [ "$(json_field "$out" action)" = "review" ]
assert "piv-review-pending: prUrl set" \
  [ "$(json_field "$out" prUrl)" = "https://github.com/x/y/pull/1" ]
assert "piv-review-pending(claim): ticket state -> piv-reviewing" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-804 state)" = "piv-reviewing" ]

# =============================================================================
# piv-review-pending: empty pr_urls -> needs-input, phase_at_question=review.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-805 piv-review-pending pr_urls='[]'
out="$(run_decide --claim)"
assert "piv-review-pending: empty pr_urls -> action=none" [ "$(json_field "$out" action)" = "none" ]
assert "piv-review-pending: empty pr_urls -> ticket moved to needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-805 state)" = "needs-input" ]
assert "piv-review-pending: empty pr_urls -> phase_at_question=review" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-805 phase_at_question)" = "review" ]

# =============================================================================
# --busy review: a piv-review-pending ticket and a ship-pending ticket ->
# the ship is claimed, the review is not (per-entry lane check at tier4,
# no cross-lane starvation between ship and review).
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-806 piv-review-pending pr_urls='["https://github.com/x/y/pull/2"]'
seed_ticket "$CASE_AP_HOME" ENG-807 ship-pending
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-807-thing.md"
out="$(run_decide --claim --busy review)"
assert "tier4 per-entry lane: busy review -> ship-pending still claimed" \
  [ "$(json_field "$out" action)" = "ship" ]
assert "tier4 per-entry lane: busy review -> issue=ENG-807 (ship)" \
  [ "$(json_field "$out" issue)" = "ENG-807" ]
assert "tier4 per-entry lane: busy review -> piv-review-pending ticket left untouched" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-806 state)" = "piv-review-pending" ]

# =============================================================================
# Cross-fork FIFO fairness at the shared draft-review gate: a plan-review
# (legacy) ticket and an older-seq piv-draft-review (bug) ticket both
# approved, build lane free -> the older seq wins, regardless of which
# fork it belongs to.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-808 piv-draft-review pending_approval=true kind='"bug"'
seed_rca_file "$CASE_WORK_REPO" ENG-808
seed_ticket "$CASE_AP_HOME" ENG-809 plan-review pending_approval=true
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-809-thing.md"
out="$(run_decide --dry-run)"
assert "cross-fork FIFO: older seq (piv-draft-review, seeded first) wins" \
  [ "$(json_field "$out" issue)" = "ENG-808" ]
assert "cross-fork FIFO: older seq's own fork action (fix) is used" \
  [ "$(json_field "$out" action)" = "fix" ]

# =============================================================================
# Tier 3: phase routing for the bug fork's own phase names.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-810 needs-input \
  feedback='"the retry path"' phase_at_question='"fix"' \
  question='"why did the retry loop not fire?"'
out="$(run_decide --claim)"
assert "tier3: phase_at_question=fix -> action=re-investigate" \
  [ "$(json_field "$out" action)" = "re-investigate" ]
assert "tier3(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-810 state)" = "piv-drafting" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-811 needs-input \
  feedback='"just retry it"' phase_at_question='"review"' \
  question='"the bot review is red, what should I do?"'
out="$(run_decide --claim)"
assert "tier3: phase_at_question=review -> action=none" [ "$(json_field "$out" action)" = "none" ]
assert "tier3: phase_at_question=review -> ticket left in needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-811 state)" = "needs-input" ]

# =============================================================================
# Shared stale-sweep: the three shared piv "running" states -- piv-drafting,
# piv-implementing, piv-reviewing -- with no ledger row in 3h and no lock
# held, are swept to failed exactly like the legacy running states.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-812 piv-drafting kind='"bug"'
seed_ticket "$CASE_AP_HOME" ENG-813 piv-implementing kind='"bug"'
seed_ticket "$CASE_AP_HOME" ENG-814 piv-reviewing kind='"bug"'
out="$(run_decide --claim)"
assert "stale-sweep(shared): piv-drafting swept to failed" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-812 state)" = "failed" ]
assert "stale-sweep(shared): piv-implementing swept to failed" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-813 state)" = "failed" ]
assert "stale-sweep(shared): piv-reviewing swept to failed" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-814 state)" = "failed" ]

# =============================================================================
# piv-draft-review (feature kind): approved + a resolvable plan fixture ->
# build, artifactPath set, state -> piv-implementing.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-900 piv-draft-review pending_approval=true kind='"feature"'
seed_piv_plan_file "$CASE_WORK_REPO" ENG-900 "widget"
out="$(run_decide --claim)"
assert "piv-draft-review(feature): action=build" [ "$(json_field "$out" action)" = "build" ]
assert "piv-draft-review(feature): artifactPath set" \
  bash -c "echo '$out' | grep -q 'ENG-900-widget.md'"
assert "piv-draft-review(feature)(claim): ticket state -> piv-implementing" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-900 state)" = "piv-implementing" ]

# =============================================================================
# piv-draft-review (feature kind): feedback -> redesign, feedback relayed,
# state -> piv-drafting, feedback cleared.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-901 piv-draft-review kind='"feature"' \
  feedback='"actually make the widget configurable"'
out="$(run_decide --claim)"
assert "piv-draft-review(feature): feedback -> action=redesign" \
  [ "$(json_field "$out" action)" = "redesign" ]
assert "piv-draft-review(feature): feedback relayed" \
  [ "$(json_field "$out" feedback)" = "actually make the widget configurable" ]
assert "piv-draft-review(feature)(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-901 state)" = "piv-drafting" ]
assert "piv-draft-review(feature)(claim): feedback cleared" \
  [ -z "$(ticket_field "$CASE_AP_HOME" ENG-901 feedback)" ]

# =============================================================================
# piv-draft-review (feature kind): feedback + pending_approval -> feedback
# wins.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-902 piv-draft-review kind='"feature"' \
  pending_approval=true feedback='"wrong approach, redo it"'
out="$(run_decide --claim)"
assert "piv-draft-review(feature): feedback beats approval -> action=redesign" \
  [ "$(json_field "$out" action)" = "redesign" ]
assert "piv-draft-review(feature)(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-902 state)" = "piv-drafting" ]

# =============================================================================
# piv-draft-review (feature kind): approved, plan unresolvable ->
# needs-input, phase_at_question=design, scan continues.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-903 piv-draft-review pending_approval=true kind='"feature"'
out="$(run_decide --claim)"
assert "piv-draft-review(feature): unresolvable plan -> action=none" [ "$(json_field "$out" action)" = "none" ]
assert "piv-draft-review(feature): unresolvable plan -> ticket moved to needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-903 state)" = "needs-input" ]
assert "piv-draft-review(feature): unresolvable plan -> phase_at_question=design" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-903 phase_at_question)" = "design" ]

# =============================================================================
# Cross-kind fairness at the shared draft-review gate: a bug ticket and an
# older-seq feature ticket, both at piv-draft-review, both approved, build
# lane free -> the older seq (feature) wins and gets action=build. Neither
# kind starves the other at the one state they share.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-904 piv-draft-review pending_approval=true kind='"feature"'
seed_piv_plan_file "$CASE_WORK_REPO" ENG-904 "older-feature"
seed_ticket "$CASE_AP_HOME" ENG-905 piv-draft-review pending_approval=true kind='"bug"'
seed_rca_file "$CASE_WORK_REPO" ENG-905
out="$(run_decide --dry-run)"
assert "cross-kind fairness: older seq (feature, seeded first) wins" \
  [ "$(json_field "$out" issue)" = "ENG-904" ]
assert "cross-kind fairness: older seq's own fork action (build) is used" \
  [ "$(json_field "$out" action)" = "build" ]

# =============================================================================
# Tier 3: phase routing for the feature fork's own phase names, including
# second-round re-entry names (redesign/re-investigate), which a wrapper
# writes when a ticket is parked a second time -- these must not fall
# through to the legacy `replan` default.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-906 needs-input \
  feedback='"use a modal instead"' phase_at_question='"build"' \
  question='"inline panel or modal?"'
out="$(run_decide --claim)"
assert "tier3: phase_at_question=build -> action=redesign" \
  [ "$(json_field "$out" action)" = "redesign" ]
assert "tier3(claim): ticket state -> piv-drafting" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-906 state)" = "piv-drafting" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-907 needs-input \
  feedback='"the users table"' phase_at_question='"design"' \
  question='"which table?"'
out="$(run_decide --claim)"
assert "tier3: phase_at_question=design -> action=redesign" \
  [ "$(json_field "$out" action)" = "redesign" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-908 needs-input \
  feedback='"still the users table"' phase_at_question='"redesign"' \
  question='"which table, take 2?"'
out="$(run_decide --claim)"
assert "tier3(re-entry): phase_at_question=redesign -> action=redesign (not legacy replan)" \
  [ "$(json_field "$out" action)" = "redesign" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-909 needs-input \
  feedback='"check the retry path again"' phase_at_question='"re-investigate"' \
  question='"still flaky?"'
out="$(run_decide --claim)"
assert "tier3(re-entry): phase_at_question=re-investigate -> action=re-investigate" \
  [ "$(json_field "$out" action)" = "re-investigate" ]

# =============================================================================
# Resolver anchoring regression: resolve_piv_plan_path must anchor on
# `<eng-id>-` (a trailing hyphen), never a bare substring match --
# ENG-123 must not resolve ENG-1234-other.md.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-123 piv-draft-review pending_approval=true kind='"feature"'
seed_piv_plan_file "$CASE_WORK_REPO" ENG-1234 "other"
seed_piv_plan_file "$CASE_WORK_REPO" ENG-123 "mine"
out="$(run_decide --dry-run)"
assert "resolver anchoring: action=build (a real plan was found)" [ "$(json_field "$out" action)" = "build" ]
assert "resolver anchoring: resolves ENG-123-mine.md, not ENG-1234-other.md" \
  bash -c "echo '$out' | grep -q 'ENG-123-mine.md' && ! echo '$out' | grep -q 'ENG-1234-other.md'"

setup_case
seed_ticket "$CASE_AP_HOME" ENG-124 piv-draft-review pending_approval=true kind='"feature"'
seed_piv_plan_file "$CASE_WORK_REPO" ENG-1245 "other"
out="$(run_decide --dry-run)"
assert "resolver anchoring: ENG-1245-other.md must not satisfy ENG-124 -> needs-input" \
  [ "$(json_field "$out" action)" = "none" ]

# =============================================================================
# Legacy inertness: a `queued` ticket (either kind) never produces
# action=plan any more; the plan-review/ship-pending hand-set escape
# hatches still work unmodified.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-910 queued
out="$(run_decide --dry-run)"
assert "legacy inertness: queued never produces action=plan" \
  [ "$(json_field "$out" action)" != "plan" ]
assert "legacy inertness: queued (default kind) produces action=design instead" \
  [ "$(json_field "$out" action)" = "design" ]

setup_case
seed_ticket "$CASE_AP_HOME" ENG-911 plan-review pending_approval=true
mkdir -p "$CASE_WORK_REPO/docs/plans"
touch "$CASE_WORK_REPO/docs/plans/eng-911-thing.md"
out="$(run_decide --dry-run)"
assert "legacy inertness: hand-set plan-review still produces action=implement" \
  [ "$(json_field "$out" action)" = "implement" ]
assert "legacy inertness: hand-set plan-review still resolves planPath" \
  bash -c "echo '$out' | grep -q 'eng-911-thing.md'"

# =============================================================================
# kind validation at intake: a present-but-invalid kind value ("Bug", wrong
# case) resolves to the safe feature default, never bug -- regression test
# for ticket_kind()'s truthiness gap.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-912 queued kind='"Bug"'
out="$(run_decide --claim)"
assert "kind validation: kind=\"Bug\" (wrong case) resolves to feature -> action=design" \
  [ "$(json_field "$out" action)" = "design" ]
assert "kind validation: kind=\"Bug\" (wrong case) never dispatches as bug" \
  [ "$(json_field "$out" action)" != "investigate" ]

# =============================================================================
# Fail-closed fallback: an unrecognized phase_at_question value must never
# silently dispatch the legacy `replan` action against a ticket that may be
# mid-piv-pipeline with an open PR and uncommitted worktree state already.
# =============================================================================
setup_case
seed_ticket "$CASE_AP_HOME" ENG-913 needs-input \
  feedback='"an answer"' phase_at_question='"some-future-phase-nothing-defines"' \
  question='"a stale question"'
out="$(run_decide --claim)"
assert "fail-closed: unrecognized phase_at_question -> action=none (not replan)" \
  [ "$(json_field "$out" action)" = "none" ]
assert "fail-closed: unrecognized phase_at_question -> ticket moved to needs-input" \
  [ "$(ticket_field "$CASE_AP_HOME" ENG-913 state)" = "needs-input" ]
assert "fail-closed: unrecognized phase_at_question -> question names the unrecognized value" \
  bash -c 'echo "$(ticket_field "$1" ENG-913 question)" | grep -q "some-future-phase-nothing-defines"' _ "$CASE_AP_HOME"

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
