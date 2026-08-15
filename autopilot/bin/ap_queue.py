#!/usr/bin/env python3
"""ap_queue.py -- the local, CLI-only replacement for autopilot's GitHub
inbox: one JSON file per ticket under $AP_HOME/queue/<ENG-ID>.json, holding
the same state a GitHub issue label used to carry plus the same directives
a GitHub comment used to carry.

This is the ONE shared implementation of queue read/write, used two ways:
- imported directly by ap-decide.py and ap-runs.py (same process, Python)
- shelled out to as a CLI by ap-cycle.sh and ap-resume.sh (bash), e.g.
  `python3 ap_queue.py set ENG-1234 --state building --event "..."`

Deliberately the one shared-not-duplicated piece in an otherwise
duplicate-small-helpers codebase (see ap-resume.sh's own header comment on
that convention) -- queue read/write correctness matters more here than the
coupling that convention otherwise protects against.
"""
import argparse
import fcntl
import glob
import json
import os
import re
import sys
import time

STATES = {
    "queued", "planning", "plan-review", "needs-input", "building",
    "shipping", "ship-pending", "ready-to-test", "failed", "done",
}
ENG_ID_RE = re.compile(r"^ENG-\d+$", re.IGNORECASE)


def valid_eng_id(s):
    return bool(ENG_ID_RE.match(s or ""))


def _queue_dir(ap_home):
    d = os.path.join(ap_home, "queue")
    os.makedirs(d, exist_ok=True)
    return d


def _path(ap_home, eng_id):
    return os.path.join(_queue_dir(ap_home), "%s.json" % eng_id)


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def next_seq(ap_home):
    """Flock-incremented monotonic counter -- same flat-marker-file
    convention as $AP_HOME/pause and $AP_HOME/fail_count -- replacing
    GitHub issue numbers as the oldest-first time proxy."""
    path = os.path.join(_queue_dir(ap_home), ".seq")
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        raw = os.read(fd, 64).decode().strip()
        n = (int(raw) if raw else 0) + 1
        os.lseek(fd, 0, os.SEEK_SET)
        os.ftruncate(fd, 0)
        os.write(fd, str(n).encode())
        return n
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def read_ticket(ap_home, eng_id):
    path = _path(ap_home, eng_id)
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def write_ticket(ap_home, eng_id, entry):
    """Atomic write (tmp + rename) -- no torn reads for any concurrent
    reader, matching the ledger/scan-state atomic-write convention."""
    entry["updated_at"] = _now()
    path = _path(ap_home, eng_id)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(entry, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def list_queue(ap_home, state=None):
    """Every ticket, optionally filtered by state, oldest-first by seq --
    drop-in replacement for list_issues(repo, label=...)'s oldest-first-by-
    issue-number ordering."""
    out = []
    for p in glob.glob(os.path.join(_queue_dir(ap_home), "*.json")):
        try:
            with open(p) as f:
                entry = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if state and entry.get("state") != state:
            continue
        out.append(entry)
    out.sort(key=lambda e: e.get("seq", 0))
    return out


def append_history(entry, event, actor="autopilot"):
    entry.setdefault("history", []).append(
        {"ts": _now(), "event": event, "actor": actor})


def new_ticket(ap_home, eng_id, note="", auto_approve=False, actor="human"):
    entry = {
        "eng_id": eng_id,
        "state": "queued",
        "seq": next_seq(ap_home),
        "created_at": _now(),
        "updated_at": _now(),
        "note": note or "",
        "auto_approve": bool(auto_approve),
        "pending_approval": False,
        "feedback": None,
        "phase_at_question": None,
        "question": None,
        "plan_path": None,
        "pr_urls": [],
        "feedback_seq": 0,
        "history": [],
    }
    append_history(entry, "queued", actor)
    write_ticket(ap_home, eng_id, entry)
    return entry


def force_state(ap_home, eng_id, state, event=None, actor="human"):
    """Like transition(), but creates the ticket first (nothing to fail on)
    if it doesn't already exist -- backs `ap sessions`' direct status-change
    action, including marking a stale ledger-only row (one with no queue
    file at all, e.g. an old NEEDS_HUMAN/FAILED outcome the human already
    resolved by hand outside the pipeline) as done/resolved."""
    entry = read_ticket(ap_home, eng_id)
    if entry is None:
        entry = new_ticket(ap_home, eng_id, actor=actor)
    entry["state"] = state
    append_history(entry, event or f"status set to {state}", actor)
    write_ticket(ap_home, eng_id, entry)
    return entry


def set_note(ap_home, eng_id, note, actor="human", initial_state=None):
    """Set/clear a ticket's free-text note without touching its state --
    creates the ticket first if it doesn't exist yet, same get-or-create
    convenience as force_state. `ap sessions`'s NOTE column prefers this
    over its own state-derived default text (except for needs-input, where
    the blocking question stays primary and the custom note is appended
    instead).

    `initial_state`, when creating a brand-new ticket, overrides the
    otherwise-default `queued` -- callers that already know a ledger-only
    row's real historical outcome (done/failed/needs-input) should pass it,
    or editing a note on it would silently flip its displayed status to
    "queued" as a side effect, which is not what setting a note means."""
    entry = read_ticket(ap_home, eng_id)
    if entry is None:
        entry = new_ticket(ap_home, eng_id, actor=actor)
        if initial_state:
            entry["state"] = initial_state
    entry["note"] = note
    append_history(entry, f"note set: {note}" if note else "note cleared", actor)
    write_ticket(ap_home, eng_id, entry)
    return entry


def transition(ap_home, eng_id, mode, event=None, actor="autopilot", **fields):
    """Read-merge-write: apply `fields` (may include `state`), log `event`
    to history. mode='dry-run' returns the would-be entry without writing
    (mirrors gh_edit/gh_comment's dry-run-vs-claim convention)."""
    entry = read_ticket(ap_home, eng_id)
    if entry is None:
        return None
    entry.update(fields)
    if event:
        append_history(entry, event, actor)
    if mode != "claim":
        return entry
    write_ticket(ap_home, eng_id, entry)
    return entry


def approve_ticket(ap_home, eng_id, auto=False):
    entry = read_ticket(ap_home, eng_id)
    if entry is None:
        return None
    entry["pending_approval"] = True
    entry["feedback"] = None
    if auto:
        entry["auto_approve"] = True
    append_history(entry, "approved" + (" (auto)" if auto else ""), "human")
    write_ticket(ap_home, eng_id, entry)
    return entry


def reply_ticket(ap_home, eng_id, text):
    """Answers a needs-input blocker OR leaves plan-review feedback --
    ap-decide.py's tiers already discriminate purely by the ticket's
    current state, so one write serves both. Always clears
    pending_approval, matching the old 'newest comment wins' semantics."""
    entry = read_ticket(ap_home, eng_id)
    if entry is None:
        return None
    entry["feedback"] = text
    entry["pending_approval"] = False
    entry["feedback_seq"] = entry.get("feedback_seq", 0) + 1
    append_history(entry, "replied", "human")
    write_ticket(ap_home, eng_id, entry)
    return entry


# --- CLI, for the bash callers (ap-cycle.sh, ap-resume.sh, ap) ---------------

def _print(entry):
    print(json.dumps(entry, indent=2) if entry is not None else "null")


def main():
    ap = argparse.ArgumentParser(prog="ap_queue.py")
    ap.add_argument("--ap-home", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("new")
    p.add_argument("eng_id")
    p.add_argument("note", nargs="?", default="")
    p.add_argument("--auto", action="store_true")

    p = sub.add_parser("get")
    p.add_argument("eng_id")

    p = sub.add_parser("list")
    p.add_argument("--state", default=None)

    p = sub.add_parser("set")
    p.add_argument("eng_id")
    p.add_argument("--state", default=None)
    p.add_argument("--field", action="append", default=[],
                    help="key=value, JSON-decoded if possible, 'null' clears it")
    p.add_argument("--event", default=None)
    p.add_argument("--actor", default="autopilot")
    p.add_argument("--mode", choices=["dry-run", "claim"], default="claim")

    p = sub.add_parser("approve")
    p.add_argument("eng_id")
    p.add_argument("--auto", action="store_true")

    p = sub.add_parser("reply")
    p.add_argument("eng_id")
    p.add_argument("text")

    args = ap.parse_args()

    if args.cmd == "new":
        if not valid_eng_id(args.eng_id):
            print("not a valid ENG-<n> id: %r" % args.eng_id, file=sys.stderr)
            return 1
        if read_ticket(args.ap_home, args.eng_id) is not None:
            print("%s is already queued" % args.eng_id, file=sys.stderr)
            return 1
        _print(new_ticket(args.ap_home, args.eng_id, args.note, args.auto))
    elif args.cmd == "get":
        entry = read_ticket(args.ap_home, args.eng_id)
        _print(entry)
        return 0 if entry is not None else 1
    elif args.cmd == "list":
        print(json.dumps(list_queue(args.ap_home, args.state), indent=2))
    elif args.cmd == "set":
        fields = {}
        if args.state is not None:
            fields["state"] = args.state
        for kv in args.field:
            k, _, v = kv.partition("=")
            try:
                v = json.loads(v)
            except (json.JSONDecodeError, ValueError):
                pass
            fields[k] = v
        entry = transition(args.ap_home, args.eng_id, args.mode,
                            event=args.event, actor=args.actor, **fields)
        _print(entry)
        return 0 if entry is not None else 1
    elif args.cmd == "approve":
        entry = approve_ticket(args.ap_home, args.eng_id, args.auto)
        _print(entry)
        return 0 if entry is not None else 1
    elif args.cmd == "reply":
        entry = reply_ticket(args.ap_home, args.eng_id, args.text)
        _print(entry)
        return 0 if entry is not None else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
