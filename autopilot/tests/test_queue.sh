#!/usr/bin/env bash
# Unit tests for ap_queue.py's `kind` field, the ticket_kind() hardening
# fix, and list_queue's multi-state form -- see
# docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md's
# `CREATE autopilot/tests/test_queue.sh` task. That task originally named
# the fresh-ticket field `rca_path`; a later amendment in the same document
# (search "artifact_path: null" there) renamed it to `artifact_path`, so
# this file tests for `artifact_path: null`, not `rca_path`.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
QUEUE_PY="$BIN_DIR/ap_queue.py"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# mktemp -d per case and never touch the real $AP_HOME -- same discipline as
# test_decide.sh, since this harness runs ap_queue.py writes directly.
setup_case() {
  CASE_AP_HOME="$(mktemp -d)"
}

# =============================================================================
# new_ticket's default kind is "feature" when no kind is passed at all.
# =============================================================================
setup_case
out="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
entry = ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-900')
print(entry['kind'])
")"
assert "new_ticket: default kind is feature" [ "$out" = "feature" ]

# =============================================================================
# `ap_queue.py new --kind bug` sets kind=bug on the written ticket.
# =============================================================================
setup_case
python3 "$QUEUE_PY" --ap-home "$CASE_AP_HOME" new ENG-901 --kind bug >/dev/null
kind="$(python3 -c "
import json
print(json.load(open('$CASE_AP_HOME/queue/ENG-901.json'))['kind'])
")"
assert "CLI: --kind bug sets kind=bug" [ "$kind" = "bug" ]

# =============================================================================
# An invalid --kind is rejected by argparse (choices=["feature","bug"]) --
# non-zero exit, no ticket file written.
# =============================================================================
setup_case
rc=0
python3 "$QUEUE_PY" --ap-home "$CASE_AP_HOME" new ENG-902 --kind bogus >/dev/null 2>&1 || rc=$?
assert "CLI: --kind bogus is rejected by argparse (non-zero exit)" [ "$rc" -ne 0 ]
assert "CLI: --kind bogus writes no ticket file" [ ! -f "$CASE_AP_HOME/queue/ENG-902.json" ]

# =============================================================================
# A hand-written ticket file (dict) with no `kind` key reads as "feature" via
# ticket_kind -- back-compat by omission for every ticket written before
# this field existed.
# =============================================================================
out="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
print(ap_queue.ticket_kind({}))
")"
assert "ticket_kind: a ticket dict with no kind key defaults to feature" [ "$out" = "feature" ]

# =============================================================================
# Hardening fix: ticket_kind() validates against KINDS, not just truthiness.
# A present-but-invalid value ("Bug", wrong case) is truthy and must NOT
# pass through as itself -- it must fall back to the "feature" default,
# same as a missing key. This is what stops a hand-edited or mis-cased kind
# from silently failing every `== "bug"` check downstream.
# =============================================================================
out="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
print(ap_queue.ticket_kind({'kind': 'Bug'}))
")"
assert "ticket_kind: wrong-case 'Bug' is invalid -> falls back to 'feature', not 'Bug' itself" \
  [ "$out" = "feature" ]

# =============================================================================
# list_queue with a single string state behaves exactly as before --
# filters to that one state only.
# =============================================================================
setup_case
python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-910')  # stays queued
e = ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-911')
e['state'] = 'planning'
ap_queue.write_ticket('$CASE_AP_HOME', 'ENG-911', e)
"
out="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
print([e['eng_id'] for e in ap_queue.list_queue('$CASE_AP_HOME', 'planning')])
")"
assert "list_queue: single string state filters to that state only (unchanged behavior)" \
  [ "$out" = "['ENG-911']" ]

# =============================================================================
# list_queue with a two-state iterable returns tickets in BOTH states,
# oldest-first by seq -- the multi-state form new_ticket's caller uses to
# scan both piv-fork states in one fair pass.
# =============================================================================
setup_case
python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
e1 = ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-920')  # seq 1
e1['state'] = 'piv-draft-review'
ap_queue.write_ticket('$CASE_AP_HOME', 'ENG-920', e1)
e2 = ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-921')  # seq 2
e2['state'] = 'piv-review-pending'
ap_queue.write_ticket('$CASE_AP_HOME', 'ENG-921', e2)
ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-922')  # seq 3, stays queued -- must NOT match
"
out="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
print([e['eng_id'] for e in
       ap_queue.list_queue('$CASE_AP_HOME', ['piv-draft-review', 'piv-review-pending'])])
")"
assert "list_queue: two-state iterable returns both, seq-ordered oldest-first" \
  [ "$out" = "['ENG-920', 'ENG-921']" ]

# =============================================================================
# A fresh ticket carries artifact_path: null. NOTE: the task text that
# introduced this test originally said `rca_path: null` -- a later
# amendment in the same plan document renamed the field to `artifact_path`
# (grep "artifact_path: null" there), so this asserts the corrected,
# current field name.
# =============================================================================
setup_case
out="$(python3 -c "
import sys, json
sys.path.insert(0, '$BIN_DIR')
import ap_queue
entry = ap_queue.new_ticket('$CASE_AP_HOME', 'ENG-930')
print(json.dumps(entry.get('artifact_path')))
")"
assert "new_ticket: fresh ticket carries artifact_path: null" [ "$out" = "null" ]

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
