#!/usr/bin/env bash
# Deterministic replacement for the haiku-model /autopilot-poll: implements
# the exact tiers, keywords and claim rules in
# claude/skills/autopilot-poll/SKILL.md against live `gh` data -- every step
# there is a label query, a first-line marker check, an exact-word match, a
# regex, a priority ordering, or a label swap, so a model call buys nothing.
# The decision logic itself lives in ap-decide.py (plain Python is easier to
# get exactly right and to unit-test than another layer of bash-JSON
# plumbing); this script only parses flags, sources env, and logs.
#
# Prints ONE JSON object to stdout, always, exit 0 always:
#   {"action":"plan|implement|ship|replan|none","issue":"ENG-<id>",
#    "planPath":"...","inboxIssue":<n>,"feedback":"..."}
# (fields present only when relevant; "action" always present.)
#
# Flags:
#   --dry-run       decide and print; perform NO gh writes (default).
#   --claim         decide, perform the claiming label swaps, then print.
#   --busy <lanes>  comma-separated subset of build,ship,plan to skip.
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
  --ap-home "$AP_HOME" --inbox-repo "$AP_INBOX_REPO" --work-repo "$WORK_REPO" \
  --auto-approve "$AP_AUTO_APPROVE" \
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
