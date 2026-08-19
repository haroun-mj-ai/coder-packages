#!/usr/bin/env bash
# The ONLY decision path (the haiku-model /autopilot-poll and its
# AP_POLL_MODE switch are gone): implements the exact tiers/priority
# ordering against the local queue ($AP_HOME/queue/<ENG-ID>.json, see
# ap_queue.py) -- every step there is a state check, a field check, a
# regex, or a state write, always deterministic, always free. The decision
# logic itself lives in ap-decide.py (plain Python is easier to get exactly
# right and to unit-test than another layer of bash-JSON plumbing); this
# script only parses flags, sources env, and logs.
#
# Prints ONE JSON object to stdout, always, exit 0 always:
#   {"action":"plan|implement|ship|replan|none","issue":"ENG-<id>",
#    "planPath":"...","feedback":"..."}
# (fields present only when relevant; "action" always present.)
#
# Flags:
#   --dry-run       decide and print; perform NO queue writes (default).
#   --claim         decide, perform the claiming state writes, then print.
#   --busy <lanes>  comma-separated subset of build,ship,plan to skip.
#   --suppress-new-intake   skip tier 5 (queued -> plan) only -- used when
#                   the daily issues/cost cap is reached, so an
#                   already-approved/answered/ship-pending ticket (tiers
#                   1-4) still gets serviced instead of stalling for the
#                   rest of the day alongside genuinely new tickets.
#
# No Linear write happens here -- see claude/skills/implement-issue/SKILL.md's
# headless section (--phase plan) for where that claim now lives.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ap-env.sh"

WORK_REPO="${AP_WORK_REPO:-/home/coder/root-for-local}"

mkdir -p "$AP_HOME/logs"

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$AP_HOME/logs/decide.log"
}

mode="dry-run"
busy=""
suppress_new_intake="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --claim)
      mode="claim"
      shift
      ;;
    --busy)
      busy="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --suppress-new-intake)
      suppress_new_intake="1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

decide_out="$(mktemp "$AP_HOME/.decide-out.XXXXXX")"
decide_err="$(mktemp "$AP_HOME/.decide-err.XXXXXX")"
# shellcheck disable=SC2329 # invoked via trap, not directly
cleanup_decide_tmp() { rm -f "$decide_out" "$decide_err"; }
trap cleanup_decide_tmp EXIT

rc=0
python3 "$SCRIPT_DIR/ap-decide.py" \
  --mode "$mode" --busy "$busy" \
  --ap-home "$AP_HOME" --work-repo "$WORK_REPO" \
  --auto-approve "$AP_AUTO_APPROVE" \
  --suppress-new-intake "$suppress_new_intake" \
  >"$decide_out" 2>"$decide_err" || rc=$?

# The trace (one line per tier evaluated) always lands in the log, even on
# an internal-error exit, so a stranded decision is diagnosable after the
# fact -- and echoes to our own stderr too, so `ap decide` can capture it
# directly for its side-by-side pretty-print.
while IFS= read -r trace_line; do
  log "$trace_line"
  echo "$trace_line" >&2
done <"$decide_err"

if [[ $rc -ne 0 ]]; then
  log "ap-decide.py exited rc=$rc -- falling back to action:none"
  echo '{"action":"none"}'
  exit 0
fi

decision="$(cat "$decide_out")"
if [[ -z "$decision" ]]; then
  log "ap-decide.py produced no stdout -- falling back to action:none"
  echo '{"action":"none"}'
  exit 0
fi

printf '%s\n' "$decision"
exit 0
