#!/usr/bin/env python3
"""ap-decide.py -- deterministic decision engine for autopilot's poll stage.

Reads/writes the local queue ($AP_HOME/queue/<ENG-ID>.json, see
ap_queue.py) instead of a GitHub inbox repo -- there is no longer a second,
model-invoked implementation of these tiers to keep in sync (the old
autopilot-poll/SKILL.md prose copy is deleted): this is the only decision
logic, always deterministic, always free.

Six priority tiers, in order: plan-review approve/replan, needs-input
answers, ship-pending, new intake (queued), then none. Every step is a
state check, a field check, a regex, or a state write -- no model call, no
judgement, no gh calls, and (unlike the old GitHub-comment channel) no
agent-vs-human disambiguation to get wrong, since human intent only ever
arrives via ap_queue.py's approve/reply writes, which nothing else touches.
"""
import argparse
import calendar
import glob
import json
import os
import re
import sys
import time

import ap_queue

ENG_ID_RE = re.compile(r"ENG-(\d+)", re.IGNORECASE)
STALE_WINDOW_SECONDS = 3 * 3600

TRACE = []


def trace(line):
    TRACE.append(line)


def resolve_plan_path(entry, work_repo):
    """entry['plan_path'] if it still exists on disk; else the newest
    docs/plans/*<eng-id-lower>*.md under work_repo/wt-*-root/, then under
    work_repo/ directly; else None."""
    plan_path = entry.get("plan_path")
    if plan_path and os.path.isfile(plan_path):
        return plan_path

    eng_lower = entry["eng_id"].lower()
    for base_pattern in (
        os.path.join(work_repo, "wt-*-root", "docs", "plans", "*%s*.md" % eng_lower),
        os.path.join(work_repo, "docs", "plans", "*%s*.md" % eng_lower),
    ):
        existing = [p for p in glob.glob(base_pattern) if os.path.isfile(p)]
        if existing:
            existing.sort(key=os.path.getmtime, reverse=True)
            return existing[0]
    return None


# --- stale-claim sweep --------------------------------------------------------

def ledger_has_recent_row(ap_home, eng_id, window_seconds=STALE_WINDOW_SECONDS):
    now = time.time()
    for path in sorted(glob.glob(os.path.join(ap_home, "runs", "*.jsonl"))):
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except Exception:
                        continue
                    if row.get("issue") != eng_id:
                        continue
                    try:
                        t = time.strptime(row.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")
                    except Exception:
                        continue
                    if now - calendar.timegm(t) <= window_seconds:
                        return True
        except OSError:
            continue
    return False


def sweep_stale(ap_home, mode):
    for state in ("planning", "building", "shipping"):
        for entry in ap_queue.list_queue(ap_home, state=state):
            eng_id = entry["eng_id"]
            lock_path = os.path.join(ap_home, "lock.issue.%s" % eng_id)
            if not ap_queue_lock_free(lock_path):
                trace("sweep: %s (%s) -- lock.issue.%s held, active run, not stale" % (eng_id, state, eng_id))
                continue
            if ledger_has_recent_row(ap_home, eng_id):
                trace("sweep: %s (%s) -- recent ledger row within 3h, not stale" % (eng_id, state))
                continue
            trace("sweep: %s (%s) -- STALE (no ledger row in 3h, no lock held) -> failed" % (eng_id, state))
            ap_queue.transition(ap_home, eng_id, mode, state="failed",
                                 event="stale claim swept: no active run")


def ap_queue_lock_free(path):
    """Non-destructive flock probe, same semantics as ap-cycle.sh's
    lane_free -- True if the lock is free."""
    import fcntl
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        return True
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


# --- priority tiers -----------------------------------------------------------

def decide(work_repo, ap_home, mode, busy, auto_approve_env):
    sweep_stale(ap_home, mode)

    build_busy = "build" in busy
    plan_busy = "plan" in busy
    ship_busy = "ship" in busy

    decision = None

    # --- Tiers 1 & 2: plan-review tickets -------------------------------------
    approve = []
    feedback = []
    if build_busy and plan_busy:
        trace("tier1/2: skipped (build and plan both busy)")
    else:
        pr_entries = ap_queue.list_queue(ap_home, state="plan-review")
        trace("tier1/2: %d plan-review ticket(s)" % len(pr_entries))
        for entry in pr_entries:
            if entry.get("feedback"):
                if not plan_busy:
                    feedback.append(entry)
                else:
                    trace("tier2: %s has feedback but plan lane busy -- leaving for next cycle" % entry["eng_id"])
            elif not build_busy and (
                entry.get("pending_approval")
                or entry.get("auto_approve")
                or auto_approve_env
            ):
                approve.append(entry)

    if approve:
        for entry in approve:
            eng_id = entry["eng_id"]
            plan_path = resolve_plan_path(entry, work_repo)
            if plan_path is None:
                trace("tier1: %s approved but planPath unresolved -> needs-input, continuing scan" % eng_id)
                ap_queue.transition(ap_home, eng_id, mode, state="needs-input",
                                     question="Could not resolve the plan file path for this ticket.",
                                     phase_at_question="plan",
                                     event="planPath unresolved")
                continue
            trace("tier1: %s approved, planPath=%s -> implement" % (eng_id, plan_path))
            ap_queue.transition(ap_home, eng_id, mode, state="building",
                                 pending_approval=False, plan_path=plan_path,
                                 event="approved -> implement")
            decision = {"action": "implement", "issue": eng_id, "planPath": plan_path}
            break

    if decision is None and feedback:
        entry = feedback[0]
        eng_id = entry["eng_id"]
        trace("tier2: %s has new feedback -> replan" % eng_id)
        fb = entry.get("feedback")
        ap_queue.transition(ap_home, eng_id, mode, state="planning",
                             feedback=None, event="feedback -> replan")
        decision = {"action": "replan", "issue": eng_id, "feedback": fb}

    # --- Tier 3: needs-input answers -----------------------------------------
    if decision is None:
        if plan_busy:
            trace("tier3: skipped (plan busy)")
        else:
            ni_entries = ap_queue.list_queue(ap_home, state="needs-input")
            trace("tier3: %d needs-input ticket(s)" % len(ni_entries))
            for entry in ni_entries:
                eng_id = entry["eng_id"]
                if os.path.isfile(os.path.join(ap_home, "parked", "%s.json" % eng_id)):
                    # Parked: a live persistent session is already sitting on
                    # this exact question -- ap-cycle.sh's scan_parked_replies
                    # relays a fresh reply straight into its tmux window, never
                    # through a fresh claim/dispatch here. Claiming it too
                    # would race a second act against the still-live one.
                    continue
                if not entry.get("feedback"):
                    continue
                phase = entry.get("phase_at_question") or "plan"
                if phase == "ship":
                    trace("tier3: %s answered but phase_at_question=ship -- needs the owner's interactive /ship-work session or tmux attach, no action" % eng_id)
                    continue
                trace("tier3: %s answered a %s-phase question -> replan" % (eng_id, phase))
                fb = entry.get("feedback")
                ap_queue.transition(ap_home, eng_id, mode, state="planning",
                                     feedback=None, question=None, phase_at_question=None,
                                     event="answered -> replan")
                decision = {"action": "replan", "issue": eng_id, "feedback": fb}
                break

    # --- Tier 4: ship-pending ---------------------------------------------
    if decision is None:
        if ship_busy:
            trace("tier4: skipped (ship busy)")
        else:
            sp_entries = ap_queue.list_queue(ap_home, state="ship-pending")
            trace("tier4: %d ship-pending ticket(s)" % len(sp_entries))
            for entry in sp_entries:
                eng_id = entry["eng_id"]
                plan_path = resolve_plan_path(entry, work_repo)
                if plan_path is None:
                    trace("tier4: %s planPath unresolved -> needs-input, continuing scan" % eng_id)
                    ap_queue.transition(ap_home, eng_id, mode, state="needs-input",
                                         question="Could not resolve the plan file path for this ticket.",
                                         phase_at_question="ship",
                                         event="planPath unresolved")
                    continue
                trace("tier4: %s ship-pending, planPath=%s -> ship" % (eng_id, plan_path))
                ap_queue.transition(ap_home, eng_id, mode, state="shipping",
                                     plan_path=plan_path, event="ship-pending -> ship")
                decision = {"action": "ship", "issue": eng_id, "planPath": plan_path}
                break

    # --- Tier 5: new intake (queued) ------------------------------------------
    if decision is None:
        if plan_busy:
            trace("tier5: skipped (plan busy)")
        else:
            candidates = ap_queue.list_queue(ap_home, state="queued")
            trace("tier5: %d queued/unclaimed ticket(s)" % len(candidates))
            for entry in candidates:
                eng_id = entry["eng_id"]
                trace("tier5: %s new delegation -> plan" % eng_id)
                ap_queue.transition(ap_home, eng_id, mode, state="planning",
                                     event="queued -> plan")
                decision = {"action": "plan", "issue": eng_id}
                if entry.get("note"):
                    decision["feedback"] = entry["note"]
                break

    if decision is None:
        trace("tier6: no actionable item -> none")
        decision = {"action": "none"}

    return decision


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["dry-run", "claim"], default="dry-run")
    ap.add_argument("--busy", default="")
    ap.add_argument("--ap-home", required=True)
    ap.add_argument("--work-repo", required=True)
    ap.add_argument("--auto-approve", default="0")
    args = ap.parse_args()

    busy = {b.strip().lower() for b in args.busy.split(",") if b.strip()}
    auto_approve_env = args.auto_approve == "1"

    try:
        decision = decide(args.work_repo, args.ap_home, args.mode, busy, auto_approve_env)
    except Exception as exc:  # defensive: never crash the cycle over this
        trace("internal error: %r" % (exc,))
        decision = {"action": "none"}

    for line in TRACE:
        print(line, file=sys.stderr)
    print(json.dumps(decision))


if __name__ == "__main__":
    main()
