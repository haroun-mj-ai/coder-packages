#!/usr/bin/env python3
"""ap-decide.py -- deterministic decision engine for autopilot's poll stage.

Implements the tiers, keywords and claim rules in
claude/skills/autopilot-poll/SKILL.md exactly: every step here is a label
query, a first-line marker check, an exact-word match, a regex, a priority
ordering, or a label swap -- no model call, no judgement. Invoked by
ap-decide.sh, which owns flag parsing, env sourcing and logging; this script
only decides (and, in --claim mode, performs the claiming gh writes) and
prints one JSON object to stdout.

No Linear write happens here (no credential available to this script -- see
claude/skills/plan-issue/SKILL.md's headless section for where the Linear
claim now lives).
"""
import argparse
import calendar
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

AGENT_MARKERS = ("Plan file:", "Phase:", "Autopilot:")
PLAN_FILE_PREFIX = "Plan file:"
PHASE_PREFIX = "Phase:"
STATE_LABELS = {
    "planning", "plan-review", "building", "shipping",
    "ready-to-test", "needs-input", "failed", "ship-pending",
}
ENG_ID_RE = re.compile(r"ENG-(\d+)", re.IGNORECASE)
STALE_WINDOW_SECONDS = 3 * 3600

TRACE = []


def trace(line):
    TRACE.append(line)


# --- gh plumbing -------------------------------------------------------------

def gh(args):
    """Run gh with a single argv list; return stdout ('' on any failure)."""
    try:
        out = subprocess.run(["gh"] + args, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        trace("gh not found on PATH")
        return ""
    if out.returncode != 0:
        trace("gh %s -> rc=%d stderr=%s" % (" ".join(args), out.returncode, out.stderr.strip()[:200]))
        return ""
    return out.stdout


def gh_json(args, default):
    raw = gh(args)
    if not raw.strip():
        return default
    try:
        return json.loads(raw)
    except Exception:
        return default


def list_issues(repo, label=None, extra_fields=""):
    fields = "number,title,labels" + ("," + extra_fields if extra_fields else "")
    args = ["issue", "list", "--repo", repo, "--state", "open", "--json", fields]
    if label:
        args += ["--label", label]
    else:
        args += ["--limit", "100"]
    data = gh_json(args, [])
    if not isinstance(data, list):
        data = []
    # Oldest-first: issue numbers increase monotonically with creation time
    # within a repo, same proxy ap-cycle.sh's pre-scan gate already uses.
    data.sort(key=lambda i: i.get("number", 0))
    return data


def fetch_comments(repo, num):
    raw = gh(["api", "repos/%s/issues/%s/comments?per_page=100" % (repo, num)])
    if not raw.strip():
        return []
    try:
        data = json.loads(raw)
    except Exception:
        return []
    return data if isinstance(data, list) else []


def fetch_body(repo, num):
    data = gh_json(["issue", "view", str(num), "--repo", repo, "--json", "body"], {})
    if not isinstance(data, dict):
        return ""
    return data.get("body") or ""


def gh_edit(repo, num, remove_label, add_label, mode):
    if mode != "claim":
        trace("[dry-run] would: gh issue edit %s --remove-label %s --add-label %s" % (num, remove_label, add_label))
        return
    gh(["issue", "edit", str(num), "--repo", repo, "--remove-label", remove_label, "--add-label", add_label])


def gh_comment(repo, num, body, mode):
    if mode != "claim":
        trace("[dry-run] would comment on %s: %s" % (num, body.splitlines()[0] if body else ""))
        return
    gh(["issue", "comment", str(num), "--repo", repo, "--body", body])


# --- comment/label helpers ---------------------------------------------------

def first_line(body):
    return (body or "").split("\n", 1)[0].strip()


def is_agent_marked(body):
    fl = first_line(body)
    return any(fl.startswith(m) for m in AGENT_MARKERS)


def labels_of(issue):
    return [str(l.get("name", "")) for l in (issue.get("labels") or [])]


def labels_lower(issue):
    return {n.lower() for n in labels_of(issue)}


def extract_eng_id(title):
    m = ENG_ID_RE.search(title or "")
    if not m:
        return None
    return "ENG-%s" % m.group(1)


def extract_note(title, eng_id):
    """Text in the title after the ENG-<id> match, stripped of leading
    separator punctuation/whitespace."""
    m = ENG_ID_RE.search(title or "")
    if not m:
        return ""
    return title[m.end():].lstrip(":- \t").strip()


def last_marker_index(comments, prefix):
    """Index of the LAST comment whose first line starts with prefix, or -1."""
    idx = -1
    for i, c in enumerate(comments):
        if first_line(c.get("body", "")).startswith(prefix):
            idx = i
    return idx


def newest_new_owner_comment(comments, marker_prefix):
    """The newest comment strictly after the last comment marked
    marker_prefix, skipping any agent-authored comment found along the way
    (loop-prevention invariant: agent-authored comments are NEVER owner
    input, wherever they land in the thread). None if there isn't one."""
    start = last_marker_index(comments, marker_prefix) + 1
    for c in reversed(comments[start:]):
        if not is_agent_marked(c.get("body", "")):
            return c
    return None


def is_directive_word(body):
    word = (body or "").strip().lower()
    return word in ("go", "auto")


def any_comment_first_line_auto(comments):
    for c in comments:
        body = c.get("body", "")
        if is_agent_marked(body):
            continue
        if first_line(body).lower() == "auto":
            return True
    return False


def resolve_plan_path(repo, num, comments, eng_id, work_repo):
    """Newest `Plan file: <abs path>` line (comments, then body) if it
    exists on disk; else the newest docs/plans/*<eng-id-lower>*.md under
    work_repo/wt-*-root/, then under work_repo/ directly; else None."""
    newest_line_path = None
    for c in reversed(comments):
        fl = first_line(c.get("body", ""))
        if fl.startswith(PLAN_FILE_PREFIX):
            newest_line_path = fl[len(PLAN_FILE_PREFIX):].strip()
            break
    if newest_line_path is None:
        fl = first_line(fetch_body(repo, num))
        if fl.startswith(PLAN_FILE_PREFIX):
            newest_line_path = fl[len(PLAN_FILE_PREFIX):].strip()
    if newest_line_path and os.path.isfile(newest_line_path):
        return newest_line_path

    eng_lower = eng_id.lower()
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

def lock_free(path):
    """Non-destructive flock probe, same semantics as ap-cycle.sh's
    lane_free -- True if the lock is free."""
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


def sweep_stale(repo, ap_home, mode):
    for label in ("planning", "building", "shipping"):
        for iss in list_issues(repo, label=label):
            num = iss.get("number")
            eng_id = extract_eng_id(iss.get("title", ""))
            if not eng_id:
                trace("sweep: issue %s (%s) has no ENG id -- cannot check ledger/lock, skipping" % (num, label))
                continue
            lock_path = os.path.join(ap_home, "lock.issue.%s" % eng_id)
            if not lock_free(lock_path):
                trace("sweep: %s (%s) -- lock.issue.%s held, active run, not stale" % (eng_id, label, eng_id))
                continue
            if ledger_has_recent_row(ap_home, eng_id):
                trace("sweep: %s (%s) -- recent ledger row within 3h, not stale" % (eng_id, label))
                continue
            trace("sweep: %s (%s) -- STALE (no ledger row in 3h, no lock held) -> failed" % (eng_id, label))
            gh_edit(repo, num, label, "failed", mode)
            gh_comment(repo, num, "Autopilot: stale claim swept: no active run", mode)


# --- priority tiers -----------------------------------------------------------

def decide(repo, work_repo, ap_home, mode, busy, auto_approve_env):
    sweep_stale(repo, ap_home, mode)

    build_busy = "build" in busy
    plan_busy = "plan" in busy
    ship_busy = "ship" in busy

    decision = None

    # --- Tiers 1 & 2: plan-review issues -------------------------------------
    approve = []
    feedback = []
    if build_busy and plan_busy:
        trace("tier1/2: skipped (build and plan both busy)")
    else:
        pr_issues = list_issues(repo, label="plan-review")
        trace("tier1/2: %d plan-review issue(s)" % len(pr_issues))
        for iss in pr_issues:
            num = iss["number"]
            comments = fetch_comments(repo, num)
            new_comment = newest_new_owner_comment(comments, PLAN_FILE_PREFIX)
            if new_comment is not None:
                if is_directive_word(new_comment.get("body", "")):
                    if not build_busy:
                        approve.append({"iss": iss, "comments": comments})
                    else:
                        trace("tier1: issue %s approved but build lane busy -- leaving for next cycle" % num)
                else:
                    if not plan_busy:
                        feedback.append({"iss": iss, "comment": new_comment})
                    else:
                        trace("tier2: issue %s has feedback but plan lane busy -- leaving for next cycle" % num)
            elif not build_busy and (
                auto_approve_env
                or "auto" in labels_lower(iss)
                or any_comment_first_line_auto(comments)
            ):
                approve.append({"iss": iss, "comments": comments})

    if approve:
        for entry in approve:
            iss, comments = entry["iss"], entry["comments"]
            num = iss["number"]
            eng_id = extract_eng_id(iss.get("title", ""))
            if not eng_id:
                trace("tier1: issue %s approved but title has no ENG id -- cannot act, skipping" % num)
                continue
            plan_path = resolve_plan_path(repo, num, comments, eng_id, work_repo)
            if plan_path is None:
                trace("tier1: %s approved but planPath unresolved -> needs-input, continuing scan" % eng_id)
                gh_edit(repo, num, "plan-review", "needs-input", mode)
                gh_comment(repo, num, "Autopilot: could not resolve the plan file path for this issue.", mode)
                continue
            trace("tier1: %s approved, planPath=%s -> implement" % (eng_id, plan_path))
            gh_edit(repo, num, "plan-review", "building", mode)
            decision = {"action": "implement", "issue": eng_id, "planPath": plan_path, "inboxIssue": num}
            break

    if decision is None and feedback:
        entry = feedback[0]
        iss, comment = entry["iss"], entry["comment"]
        num = iss["number"]
        eng_id = extract_eng_id(iss.get("title", ""))
        if eng_id:
            trace("tier2: %s has new feedback -> replan" % eng_id)
            gh_edit(repo, num, "plan-review", "planning", mode)
            decision = {"action": "replan", "issue": eng_id, "inboxIssue": num, "feedback": comment.get("body", "")}
        else:
            trace("tier2: issue %s has feedback but title has no ENG id -- cannot act" % num)

    # --- Tier 3: needs-input answers -----------------------------------------
    if decision is None:
        if plan_busy:
            trace("tier3: skipped (plan busy)")
        else:
            ni_issues = list_issues(repo, label="needs-input")
            trace("tier3: %d needs-input issue(s)" % len(ni_issues))
            for iss in ni_issues:
                num = iss["number"]
                comments = fetch_comments(repo, num)
                phase_idx = last_marker_index(comments, PHASE_PREFIX)
                new_comment = newest_new_owner_comment(comments, PHASE_PREFIX)
                if new_comment is None:
                    continue
                phase = "plan"
                if phase_idx >= 0:
                    phase_word = first_line(comments[phase_idx].get("body", ""))[len(PHASE_PREFIX):].strip().lower()
                    if phase_word.startswith("ship"):
                        phase = "ship"
                    elif phase_word.startswith("implement"):
                        phase = "implement"
                    else:
                        phase = "plan"
                if phase == "ship":
                    trace("tier3: issue %s answered but Phase: ship -- needs the owner's interactive /ship-work session, no action" % num)
                    continue
                eng_id = extract_eng_id(iss.get("title", ""))
                if not eng_id:
                    trace("tier3: issue %s answered but title has no ENG id -- cannot act" % num)
                    continue
                trace("tier3: %s answered a Phase:%s question -> replan" % (eng_id, phase))
                gh_edit(repo, num, "needs-input", "planning", mode)
                decision = {"action": "replan", "issue": eng_id, "inboxIssue": num, "feedback": new_comment.get("body", "")}
                break

    # --- Tier 4: ship-pending -------------------------------------------------
    if decision is None:
        if ship_busy:
            trace("tier4: skipped (ship busy)")
        else:
            sp_issues = list_issues(repo, label="ship-pending")
            trace("tier4: %d ship-pending issue(s)" % len(sp_issues))
            for iss in sp_issues:
                num = iss["number"]
                eng_id = extract_eng_id(iss.get("title", ""))
                if not eng_id:
                    trace("tier4: issue %s has no ENG id -- cannot act" % num)
                    continue
                comments = fetch_comments(repo, num)
                plan_path = resolve_plan_path(repo, num, comments, eng_id, work_repo)
                if plan_path is None:
                    trace("tier4: %s planPath unresolved -> needs-input, continuing scan" % eng_id)
                    gh_edit(repo, num, "ship-pending", "needs-input", mode)
                    gh_comment(repo, num, "Autopilot: could not resolve the plan file path for this issue.", mode)
                    continue
                trace("tier4: %s ship-pending, planPath=%s -> ship" % (eng_id, plan_path))
                gh_edit(repo, num, "ship-pending", "shipping", mode)
                decision = {"action": "ship", "issue": eng_id, "planPath": plan_path, "inboxIssue": num}
                break

    # --- Tier 5: new intake (Queued, no state label) --------------------------
    if decision is None:
        if plan_busy:
            trace("tier5: skipped (plan busy)")
        else:
            all_open = list_issues(repo, extra_fields="body")
            candidates = []
            for iss in all_open:
                names_lower = labels_lower(iss)
                if "queued" not in names_lower:
                    continue
                if names_lower & STATE_LABELS:
                    continue
                candidates.append(iss)
            trace("tier5: %d Queued/unclaimed issue(s)" % len(candidates))
            for iss in candidates:
                num = iss["number"]
                title = iss.get("title", "")
                eng_id = extract_eng_id(title)
                if not eng_id:
                    trace("tier5: issue %s has no ENG id in title -- asking for one" % num)
                    gh_edit(repo, num, "Queued", "needs-input", mode)
                    gh_comment(
                        repo, num,
                        "Autopilot: Add the Linear issue id, `ENG-<n>`, to the title and I'll pick this up.",
                        mode,
                    )
                    continue
                feedback_text = extract_note(title, eng_id) or (iss.get("body") or "").strip()
                trace("tier5: %s new delegation -> plan" % eng_id)
                gh_edit(repo, num, "Queued", "planning", mode)
                decision = {"action": "plan", "issue": eng_id, "inboxIssue": num}
                if feedback_text:
                    decision["feedback"] = feedback_text
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
    ap.add_argument("--inbox-repo", required=True)
    ap.add_argument("--work-repo", required=True)
    ap.add_argument("--auto-approve", default="0")
    args = ap.parse_args()

    busy = {b.strip().lower() for b in args.busy.split(",") if b.strip()}
    auto_approve_env = args.auto_approve == "1"

    try:
        decision = decide(args.inbox_repo, args.work_repo, args.ap_home, args.mode, busy, auto_approve_env)
    except Exception as exc:  # defensive: never crash the cycle over this
        trace("internal error: %r" % (exc,))
        decision = {"action": "none"}

    for line in TRACE:
        print(line, file=sys.stderr)
    print(json.dumps(decision))


if __name__ == "__main__":
    main()
