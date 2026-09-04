#!/usr/bin/env python3
"""ap-decide.py -- deterministic decision engine for autopilot's poll stage.

Reads/writes the local queue ($AP_HOME/queue/<ENG-ID>.json, see
ap_queue.py) instead of a GitHub inbox repo -- there is no longer a second,
model-invoked implementation of these tiers to keep in sync (the old
autopilot-poll/SKILL.md prose copy is deleted): this is the only decision
logic, always deterministic, always free.

Six priority tiers, in order: shared draft-review approve/replan
(plan-review + piv-draft-review, both `kind`s, seq-ordered together),
needs-input answers (routed by `phase_at_question` alone), shared
ready-for-next-phase (ship-pending + piv-review-pending, each with its own
per-entry lane check), new intake (queued, routed by `kind`), then none.
Every step is a state check, a field check, a regex, or a state write -- no
model call, no judgement, no gh calls, and (unlike the old GitHub-comment
channel) no agent-vs-human disambiguation to get wrong, since human intent
only ever arrives via ap_queue.py's approve/reply writes, which nothing else
touches.

`ap_queue.ticket_kind()` is read in exactly two places: the `queued` intake
tier (tier 5) and the shared draft-review tier (tiers 1/2). Every other
tier is determined by state alone (tier 4, the stale sweep) or by
`phase_at_question` alone (tier 3) -- phase names are globally unique per
kind/pipeline, so `phase_at_question` already encodes the fork. The legacy
`plan-review`/`ship-pending` states are the kind-agnostic, deliberate manual
escape hatch (only reachable by a human hand-setting the state via `ap
sessions [s]`) and dispatch their original `implement`/`ship` actions
unchanged.
"""
import argparse
import calendar
import glob
import json
import os
import re
import sys
import time
from collections import namedtuple

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


def resolve_rca_path(entry, work_repo):
    """entry['artifact_path'] if it still exists on disk; else the RCA for
    this ticket under work_repo/wt-*-root/docs/issues/, then work_repo/docs/
    issues/ directly -- an exact case-insensitive `issue-<eng-id>.md`
    basename match preferred within a base, falling back to a substring
    match on the full `eng-<n>` token; newest by mtime among ties; else
    None.

    Deliberately NOT a copy of resolve_plan_path's glob (`*%s*.md`), which
    also matches `eng-1234` while looking for `eng-123` -- a latent
    mis-resolution left as-is there (fixing it is out of scope here).
    Exact-match-first avoids inheriting it. RCA filenames are mixed-case in
    the work repo (`issue-ENG-1124.md`), so basenames are compared
    lowercased throughout, never assumed.
    """
    artifact_path = entry.get("artifact_path")
    if artifact_path and os.path.isfile(artifact_path):
        return artifact_path

    eng_lower = entry["eng_id"].lower()
    exact_name = "issue-%s.md" % eng_lower
    for base_pattern in (
        os.path.join(work_repo, "wt-*-root", "docs", "issues", "*.md"),
        os.path.join(work_repo, "docs", "issues", "*.md"),
    ):
        candidates = [p for p in glob.glob(base_pattern) if os.path.isfile(p)]
        exact = [p for p in candidates if os.path.basename(p).lower() == exact_name]
        pool = exact or [p for p in candidates if eng_lower in os.path.basename(p).lower()]
        if pool:
            pool.sort(key=os.path.getmtime, reverse=True)
            return pool[0]
    return None


def resolve_piv_plan_path(entry, work_repo):
    """entry['artifact_path'] if it still exists on disk; else the piv
    (feature-fork) implementation plan for this ticket under
    work_repo/wt-*-root/docs/plans/, then work_repo/docs/plans/ directly --
    a lowercased basename that either equals `<eng-id>.md` or **starts with
    `<eng-id>-`** (the trailing hyphen is load-bearing); newest by mtime
    among ties; else None.

    Never reuses resolve_plan_path: that one resolves the LEGACY
    implement-issue plan location (`docs/plans/*<eng-lower>*.md`,
    date-prefixed filenames) and carries a known substring hazard
    (`*eng-123*` also matches `eng-1234-foo.md`) that is deliberately not
    fixed there. Anchoring on `^<eng-id>-` here kills that hazard --
    `eng-1234-foo.md` does not start with `eng-123-`, since the character
    after `123` is `4`, not `-` -- and also means a legacy plan (date-
    prefixed) can never be resolved by this function: the two forks'
    artifacts are distinguishable by filename shape alone. Basenames are
    compared lowercased throughout (real filenames are mixed-case, e.g.
    `2026-06-12-ENG-461-orchestration-conformance.md`).
    """
    artifact_path = entry.get("artifact_path")
    if artifact_path and os.path.isfile(artifact_path):
        return artifact_path

    eng_lower = entry["eng_id"].lower()
    exact_name = "%s.md" % eng_lower
    prefix = "%s-" % eng_lower
    for base_pattern in (
        os.path.join(work_repo, "wt-*-root", "docs", "plans", "*.md"),
        os.path.join(work_repo, "docs", "plans", "*.md"),
    ):
        candidates = [p for p in glob.glob(base_pattern) if os.path.isfile(p)]
        matches = []
        for p in candidates:
            b = os.path.basename(p).lower()
            if b == exact_name or b.startswith(prefix):
                matches.append(p)
        if matches:
            matches.sort(key=os.path.getmtime, reverse=True)
            return matches[0]
    return None


# --- shared draft-review tier (plan-review + piv-draft-review) ---------------

DraftReviewFork = namedtuple("DraftReviewFork", [
    "approve_action", "approve_claim_state", "resolver", "decision_key",
    "artifact_field", "artifact_label", "feedback_action", "feedback_claim_state",
    "first_phase",
])


def _draft_review_fork(entry):
    """Given a plan-review/piv-draft-review entry, return its fork config.

    `plan-review` is the legacy, kind-agnostic row -- it predates `kind`
    entirely and is untouched: still reachable only by a human hand-setting
    the state via `ap sessions [s]`, the deliberate manual escape hatch,
    dispatching its original `implement`/`replan` actions unchanged.
    `piv-draft-review` is shared by both kinds and branches on
    `ap_queue.ticket_kind()` -- this and the `queued` intake tier are the
    ONLY two places the decider reads `kind`; every other tier is
    determined by state (tier 4, the stale sweep) or by `phase_at_question`
    alone (tier 3), because phase names are globally unique per kind.
    """
    if entry["state"] == "plan-review":
        return DraftReviewFork("implement", "building", resolve_plan_path,
                                "planPath", "plan_path", "plan file path",
                                "replan", "planning", "plan")
    if ap_queue.ticket_kind(entry) == "bug":
        return DraftReviewFork("fix", "piv-implementing", resolve_rca_path,
                                "artifactPath", "artifact_path", "RCA path",
                                "re-investigate", "piv-drafting", "investigate")
    return DraftReviewFork("build", "piv-implementing", resolve_piv_plan_path,
                            "artifactPath", "artifact_path", "plan path",
                            "redesign", "piv-drafting", "design")


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
    # The three legacy running states plus the three shared piv running
    # states -- "piv-draft-review"/"piv-review-pending" are NOT here, same
    # as "plan-review"/"ship-pending" never were: those are approval/queue
    # states, not "an act is actively running" states, and are covered by
    # tiers 1/2/4 instead.
    for state in ("planning", "building", "shipping",
                  "piv-drafting", "piv-implementing", "piv-reviewing"):
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


def _issue_lock_free(ap_home, eng_id):
    """Whether lock.issue.<eng_id> is free right now -- see ap_queue_lock_free.
    Every tier below checks this immediately before claiming a ticket (not
    just the stale-claim sweep), because the ticket's own state-write can
    happen several real steps before the wrapper that's still finishing the
    PRECEDING phase notices completion and releases this exact lock (a plan
    act's headless "End state" writes plan-review directly, then still has
    kata/logging/etc. left before it writes status.json) -- claiming inside
    that window orphans the claim: state flips forward but no act is ever
    actually dispatched for it, recoverable only by the 3h stale sweep, with
    no diagnostic beyond "no active run"."""
    return ap_queue_lock_free(os.path.join(ap_home, "lock.issue.%s" % eng_id))


# --- priority tiers -----------------------------------------------------------

def decide(work_repo, ap_home, mode, busy, auto_approve_env, suppress_new_intake=False):
    sweep_stale(ap_home, mode)

    build_busy = "build" in busy
    plan_busy = "plan" in busy
    ship_busy = "ship" in busy
    review_busy = "review" in busy

    decision = None

    # --- Tiers 1 & 2: shared draft-review tier ---------------------------------
    # plan-review (legacy, kind-agnostic) + piv-draft-review (shared by both
    # kinds), scanned together in one seq-ordered list_queue call so the two
    # forks interleave FIFO instead of one starving the other. Fork-specific
    # behavior (action names, claim states, artifact resolver, decision key)
    # comes from _draft_review_fork(); everything else -- feedback beats a
    # stale approval, the lane-busy guards, the lock check, the
    # unresolved-artifact -> needs-input + continue shape -- is unchanged and
    # shared verbatim by both forks.
    approve = []
    feedback = []
    if build_busy and plan_busy:
        trace("tier1/2: skipped (build and plan both busy)")
    else:
        dr_entries = ap_queue.list_queue(ap_home, ("plan-review", "piv-draft-review"))
        trace("tier1/2: %d draft-review ticket(s) (plan-review + piv-draft-review)" % len(dr_entries))
        for entry in dr_entries:
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
            if not _issue_lock_free(ap_home, eng_id):
                # The act that produced this draft-review row can self-write
                # the state transition (see implement-issue/SKILL.md's and
                # piv-investigate-issue/SKILL.md's headless "End state")
                # several steps before it finishes and ap-cycle.sh's wrapper
                # notices status.json and releases lock.issue.<id> --
                # claiming here in that window would orphan the claim: the
                # queue flips forward but no act was ever actually dispatched
                # for it (the wrapper's own lock.issue check would refuse to
                # start one), and nothing recovers it until the 3h
                # stale-claim sweep, with no real diagnostic beyond "no
                # active run" (this exact sequence hit ENG-1327 live on
                # 2026-08-16, and applies identically to piv-draft-review).
                # Skip and let a later cycle, once the lock is genuinely
                # free, claim it cleanly instead.
                trace("tier1: %s approved but its issue lock is still held (act mid-shutdown) -- leaving for next cycle" % eng_id)
                continue
            fork = _draft_review_fork(entry)
            artifact_path = fork.resolver(entry, work_repo)
            if artifact_path is None:
                trace("tier1: %s approved but %s unresolved -> needs-input, continuing scan" % (eng_id, fork.artifact_label))
                ap_queue.transition(ap_home, eng_id, mode, state="needs-input",
                                     question="Could not resolve the %s for this ticket." % fork.artifact_label,
                                     phase_at_question=fork.first_phase,
                                     event="%s unresolved" % fork.artifact_label)
                continue
            trace("tier1: %s approved, %s=%s -> %s" % (eng_id, fork.artifact_field, artifact_path, fork.approve_action))
            ap_queue.transition(ap_home, eng_id, mode, state=fork.approve_claim_state,
                                 pending_approval=False, event="approved -> %s" % fork.approve_action,
                                 **{fork.artifact_field: artifact_path})
            decision = {"action": fork.approve_action, "issue": eng_id, fork.decision_key: artifact_path}
            break

    if decision is None:
        for entry in feedback:
            eng_id = entry["eng_id"]
            if not _issue_lock_free(ap_home, eng_id):
                trace("tier2: %s has feedback but its issue lock is still held (act mid-shutdown) -- leaving for next cycle" % eng_id)
                continue
            fork = _draft_review_fork(entry)
            trace("tier2: %s has new feedback -> %s" % (eng_id, fork.feedback_action))
            fb = entry.get("feedback")
            ap_queue.transition(ap_home, eng_id, mode, state=fork.feedback_claim_state,
                                 feedback=None, event="feedback -> %s" % fork.feedback_action)
            decision = {"action": fork.feedback_action, "issue": eng_id, "feedback": fb}
            break

    # --- Tier 3: needs-input answers, routed by phase_at_question alone --------
    # This tier reads no `kind`: every phase name below is bug-only,
    # piv-feature-only, or the legacy feature-path's own name, so
    # phase_at_question already determines the fork. This and the
    # draft-review tier above are the ONLY two places the decider reads
    # `kind` at all. The fallback for a value not on this table fails
    # CLOSED to needs-input -- it must never silently dispatch the legacy
    # `replan` against a ticket that may be mid-piv-pipeline with an open PR
    # and uncommitted worktree state already.
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
                if not _issue_lock_free(ap_home, eng_id):
                    trace("tier3: %s answered but its issue lock is still held (act mid-shutdown) -- leaving for next cycle" % eng_id)
                    continue
                phase = entry.get("phase_at_question")
                if phase in ("plan", "implement", "replan", None):
                    # Legacy -- real values the legacy path itself can
                    # produce (its status.json phase vocabulary is
                    # plan/replan/implement/ship, per the shared headless
                    # contract's pipeline table), or the field is simply
                    # absent -- not a fallback.
                    action, claim_state = "replan", "planning"
                elif phase in ("design", "redesign", "build"):
                    # `build` re-plans rather than re-builds -- heavy-handed
                    # but consistent: a mid-build parked question still gets
                    # routed back through the drafting phase.
                    action, claim_state = "redesign", "piv-drafting"
                elif phase in ("investigate", "re-investigate", "fix"):
                    action, claim_state = "re-investigate", "piv-drafting"
                elif phase in ("ship", "review"):
                    trace("tier3: %s answered but phase_at_question=%s -- needs the owner's interactive session or tmux attach, no action" % (eng_id, phase))
                    continue
                else:
                    # Fail closed: an unrecognized value (a renamed phase, a
                    # future pipeline's phase name not yet added above, a
                    # hand-edit) must never fall through to the legacy
                    # replan dispatch -- see the tier-3 docstring above.
                    trace("tier3: %s answered but phase_at_question=%r is unrecognized -> needs-input (fail closed), continuing scan" % (eng_id, phase))
                    ap_queue.transition(ap_home, eng_id, mode, state="needs-input",
                                         feedback=None,
                                         question="unrecognized phase_at_question value: '%s' -- routing unknown, needs a human decision" % phase,
                                         event="unrecognized phase_at_question '%s'" % phase)
                    continue
                trace("tier3: %s answered a %s-phase question -> %s" % (eng_id, phase, action))
                fb = entry.get("feedback")
                ap_queue.transition(ap_home, eng_id, mode, state=claim_state,
                                     feedback=None, question=None, phase_at_question=None,
                                     event="answered -> %s" % action)
                decision = {"action": action, "issue": eng_id, "feedback": fb}
                break

    # --- Tier 4: shared ready-for-next-phase (ship-pending + piv-review-pending)
    # Scanned together, seq-ordered, but with a PER-ENTRY lane check (ship
    # lane for ship-pending, review lane for piv-review-pending) so a busy
    # review lane never blocks a free ship lane, or vice versa -- `continue`
    # on a busy/unresolved entry, never `break`, same as every other tier.
    if decision is None:
        sp_entries = ap_queue.list_queue(ap_home, ("ship-pending", "piv-review-pending"))
        trace("tier4: %d ship-pending/piv-review-pending ticket(s)" % len(sp_entries))
        for entry in sp_entries:
            eng_id = entry["eng_id"]
            if entry["state"] == "ship-pending":
                if ship_busy:
                    trace("tier4: %s ship-pending but ship lane busy -- leaving for next cycle" % eng_id)
                    continue
                if not _issue_lock_free(ap_home, eng_id):
                    trace("tier4: %s ship-pending but its issue lock is still held (act mid-shutdown) -- leaving for next cycle" % eng_id)
                    continue
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
            else:  # piv-review-pending
                if review_busy:
                    trace("tier4: %s piv-review-pending but review lane busy -- leaving for next cycle" % eng_id)
                    continue
                if not _issue_lock_free(ap_home, eng_id):
                    trace("tier4: %s piv-review-pending but its issue lock is still held (act mid-shutdown) -- leaving for next cycle" % eng_id)
                    continue
                pr_urls = entry.get("pr_urls") or []
                pr_url = pr_urls[0] if pr_urls else None
                if not pr_url:
                    trace("tier4: %s piv-review-pending but PR unresolved -> needs-input, continuing scan" % eng_id)
                    ap_queue.transition(ap_home, eng_id, mode, state="needs-input",
                                         question="Could not resolve the PR for this ticket.",
                                         phase_at_question="review",
                                         event="PR unresolved")
                    continue
                trace("tier4: %s piv-review-pending, prUrl=%s -> review" % (eng_id, pr_url))
                ap_queue.transition(ap_home, eng_id, mode, state="piv-reviewing",
                                     event="piv-review-pending -> review")
                decision = {"action": "review", "issue": eng_id, "prUrl": pr_url}
                break

    # --- Tier 5: new intake (queued), routed by kind ----------------------------
    # The other of the two places the decider reads `kind` (see the module
    # docstring and the draft-review tier above).
    if decision is None:
        if suppress_new_intake:
            # Daily issues/cost cap reached. This throttles *new* tickets
            # entering the pipeline only -- tiers 1-4 above are all
            # continuing work already claimed earlier (an approval, a
            # feedback reply, a ready-for-next-phase pickup), and blocking
            # those too just because the cap was hit stalls an
            # already-approved ticket for the rest of the day for no reason
            # (hit live 2026-08-19: ENG-1373 approved, then stuck until
            # midnight).
            trace("tier5: skipped (daily issue/cost budget reached -- new intake suppressed)")
        elif plan_busy:
            trace("tier5: skipped (plan busy)")
        else:
            candidates = ap_queue.list_queue(ap_home, state="queued")
            trace("tier5: %d queued/unclaimed ticket(s)" % len(candidates))
            for entry in candidates:
                eng_id = entry["eng_id"]
                kind = ap_queue.ticket_kind(entry)
                if kind == "bug":
                    action, claim_state = "investigate", "piv-drafting"
                else:
                    action, claim_state = "design", "piv-drafting"
                trace("tier5: %s new delegation (kind=%s) -> %s" % (eng_id, kind, action))
                ap_queue.transition(ap_home, eng_id, mode, state=claim_state,
                                     event="queued -> %s" % action)
                decision = {"action": action, "issue": eng_id}
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
    ap.add_argument("--suppress-new-intake", default="0")
    args = ap.parse_args()

    busy = {b.strip().lower() for b in args.busy.split(",") if b.strip()}
    auto_approve_env = args.auto_approve == "1"
    suppress_new_intake = args.suppress_new_intake == "1"

    try:
        decision = decide(args.work_repo, args.ap_home, args.mode, busy, auto_approve_env,
                           suppress_new_intake=suppress_new_intake)
    except Exception as exc:  # defensive: never crash the cycle over this
        trace("internal error: %r" % (exc,))
        decision = {"action": "none"}

    for line in TRACE:
        print(line, file=sys.stderr)
    print(json.dumps(decision))


if __name__ == "__main__":
    main()
