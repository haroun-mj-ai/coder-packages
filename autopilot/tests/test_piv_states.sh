#!/usr/bin/env bash
# Guard tests for the piv state-machine invariants the piv pipelines' design
# rests on -- see docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md's
# `CREATE autopilot/tests/test_piv_states.sh` task (optional but
# recommended). Asserts properties no other test harness asserts directly:
# the generalized STATES set, the no-substring-collision naming rule, the
# underscore-free phase names _ACT_WINDOW_RE depends on, ap-cycle.sh's
# requeue map staying in sync with ap-runs.py's REQUEUE_STATE, and every
# state rendering a real ap-runs.py `_queue_note` (not the bare state name).
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# =============================================================================
# 1. ap_queue.STATES is exactly the expected set: shared five, legacy
#    feature-path five, piv five -- no more, no fewer.
# =============================================================================
expected_states=(
  queued needs-input ready-to-test failed done
  planning plan-review building shipping ship-pending
  piv-drafting piv-draft-review piv-implementing piv-review-pending piv-reviewing
)
actual_states="$(python3 -c "
import sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
print('\n'.join(sorted(ap_queue.STATES)))
")"
expected_sorted="$(printf '%s\n' "${expected_states[@]}" | sort)"
assert "ap_queue.STATES is exactly the expected 15-state set (shared + legacy + piv)" \
  bash -c '[ "$1" = "$2" ]' _ "$actual_states" "$expected_sorted"

# =============================================================================
# 2. No piv state name contains a legacy state name as a substring -- the
#    grep-honesty rule both pipeline plans' naming rationale states
#    explicitly (e.g. `piv-implementing` was chosen over `piv-building`
#    specifically because the latter contains `building`).
# =============================================================================
piv_states=(piv-drafting piv-draft-review piv-implementing piv-review-pending piv-reviewing)
legacy_states=(planning plan-review building shipping ship-pending)
substr_hit=""
for piv in "${piv_states[@]}"; do
  for legacy in "${legacy_states[@]}"; do
    if [[ "$piv" == *"$legacy"* ]]; then
      substr_hit="$piv contains $legacy"
    fi
  done
done
assert "no piv state name contains a legacy state name as a substring" \
  bash -c '[ -z "$1" ]' _ "$substr_hit"

# =============================================================================
# 3. No phase name (REQUEUE_STATE's keys, from ap-runs.py) contains an
#    underscore -- ap-runs.py's _ACT_WINDOW_RE matches a phase against
#    `[^_]+` inside an underscore-delimited window name, so a phase with an
#    underscore would silently stop `ap runs`/`ap status`/`ap tail` from
#    seeing that act.
# =============================================================================
phase_check="$(python3 -c "
import importlib.util, sys
sys.path.insert(0, '$BIN_DIR')
spec = importlib.util.spec_from_file_location('ap_runs_mod', '$BIN_DIR/ap-runs.py')
m = importlib.util.module_from_spec(spec)
sys.modules['ap_runs_mod'] = m
spec.loader.exec_module(m)
bad = [p for p in m.REQUEUE_STATE if '_' in p]
for p in sorted(m.REQUEUE_STATE):
    window = 'act_plan_ENG-1_' + p
    if not m._ACT_WINDOW_RE.match(window):
        bad.append(p + ' (does not match _ACT_WINDOW_RE)')
print('OK' if not bad else 'BAD:' + ','.join(bad))
")"
assert "no REQUEUE_STATE phase name contains an underscore; each matches _ACT_WINDOW_RE" \
  [ "$phase_check" = "OK" ]

# =============================================================================
# 4. ap-cycle.sh's requeue map and ap-runs.py's REQUEUE_STATE agree.
#
# Extracting the bash `case "$final_phase" in ... esac` block reliably is
# more brittle than the value it adds here, so per this task's own GOTCHA
# ("if extracting the bash map is too brittle, hand-assert it with a
# comment naming both file:line sites, and accept the manual coupling
# honestly rather than skipping the check"), this is a hand-transcribed
# literal of ap-cycle.sh's requeue map --
# autopilot/bin/ap-cycle.sh:1119-1129, the `case "$final_phase" in ... esac`
# block immediately below its "This map MUST stay identical to
# ap-runs.py's REQUEUE_STATE" comment -- compared against the live
# REQUEUE_STATE dict imported from autopilot/bin/ap-runs.py:1419-1435.
# Whoever next edits either map must update this literal to match, exactly
# the same discipline the two source files already require of each other.
# =============================================================================
cycle_sh_map='{
  "plan": "queued", "replan": "queued",
  "implement": "plan-review",
  "ship": "ship-pending",
  "investigate": "queued", "re-investigate": "queued",
  "fix": "piv-draft-review",
  "design": "queued", "redesign": "queued",
  "build": "piv-draft-review",
  "review": "piv-review-pending"
}'
requeue_check="$(python3 -c "
import importlib.util, sys, json
sys.path.insert(0, '$BIN_DIR')
spec = importlib.util.spec_from_file_location('ap_runs_mod', '$BIN_DIR/ap-runs.py')
m = importlib.util.module_from_spec(spec)
sys.modules['ap_runs_mod'] = m
spec.loader.exec_module(m)
cycle_map = json.loads('''$cycle_sh_map''')
if cycle_map == m.REQUEUE_STATE:
    print('OK')
else:
    print('MISMATCH: %r vs %r' % (cycle_map, m.REQUEUE_STATE))
")"
assert "ap-cycle.sh's requeue map (hand-transcribed, see comment) agrees with ap-runs.py's REQUEUE_STATE" \
  [ "$requeue_check" = "OK" ]

# =============================================================================
# 5. Every state in ap_queue.STATES renders a real note via ap-runs.py's
#    _queue_note -- not empty, and not the bare state name itself (promotes
#    the feature-fork plan's Level-5 ad-hoc check into a permanent test).
# =============================================================================
note_check="$(python3 -c "
import importlib.util, sys
sys.path.insert(0, '$BIN_DIR')
import ap_queue
spec = importlib.util.spec_from_file_location('ap_runs_mod', '$BIN_DIR/ap-runs.py')
m = importlib.util.module_from_spec(spec)
sys.modules['ap_runs_mod'] = m
spec.loader.exec_module(m)
bad = []
for state in sorted(ap_queue.STATES):
    note = m._queue_note({'state': state})
    if not note or note == state:
        bad.append(state + ' -> ' + repr(note))
print('OK' if not bad else 'BAD:' + '; '.join(bad))
")"
assert "every ap_queue.STATES entry renders a real (non-bare-state-name) note via _queue_note" \
  [ "$note_check" = "OK" ]

# =============================================================================

if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
