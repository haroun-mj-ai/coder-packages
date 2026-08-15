#!/usr/bin/env python3
"""Anchored 7-day cost window for the autopilot ledger.

Before this existed, `ap status` summed "the last 7 ledger FILES on disk" and
`ap-brief.sh` summed "entries in the last 7 DAYS" -- two different bases that
silently disagreed once a day was skipped or a ledger was pruned. Both now call
this, so there is exactly one definition of "week cost".

The window is anchored rather than rolling: a reset stamps an anchor timestamp,
and the window rolls forward from it in fixed `period_days` steps, so usage
resets on the same weekday/time every period instead of continuously sliding.

`baseline_usd` exists because a reset usually means "my real account usage is
at X% right now" -- the pipeline's own ledger cannot know that, since the
account pool is shared with interactive Claude Code sessions. The baseline is
that starting offset. It applies ONLY to the first period after the reset;
once the window rolls, the count genuinely starts from zero.

State file (default $AP_HOME/week-reset.json):

    {"anchor": "2026-08-14T17:00:00Z", "period_days": 7, "baseline_usd": 43.40}

With no state file, falls back to a plain trailing 7-day sum, which is what
ap-brief.sh always did -- so this is safe to drop onto a machine that has
never been reset.

Usage:
    ap-week-cost.py [--home DIR] [--format shell|json|usd]
"""

import argparse
import datetime
import glob
import json
import os
import sys

ISO_FORMATS = ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S")


def parse_ts(value):
    """Parse a ledger/state timestamp into an aware UTC datetime, or None."""
    if not value:
        return None
    text = str(value).strip()
    # Python's %z does not accept a bare "Z" before 3.7-era builds and is
    # inconsistent across them; normalise it away first.
    if text.endswith("Z"):
        text = text[:-1] + "+0000"
    for fmt in ISO_FORMATS:
        try:
            dt = datetime.datetime.strptime(text, fmt)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.astimezone(datetime.timezone.utc)
    try:
        dt = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def load_state(home):
    path = os.path.join(home, "week-reset.json")
    try:
        with open(path) as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return None
    anchor = parse_ts(state.get("anchor"))
    if anchor is None:
        return None
    try:
        period_days = int(state.get("period_days") or 7)
    except (TypeError, ValueError):
        period_days = 7
    if period_days < 1:
        period_days = 7
    try:
        baseline = float(state.get("baseline_usd") or 0.0)
    except (TypeError, ValueError):
        baseline = 0.0
    return {"anchor": anchor, "period_days": period_days, "baseline_usd": baseline}


def window(state, now):
    """Return (window_start, window_end, baseline_applies)."""
    if state is None:
        return now - datetime.timedelta(days=7), now, False
    period = datetime.timedelta(days=state["period_days"])
    start = state["anchor"]
    rolled = False
    # Roll forward in whole periods until the window contains `now`. A loop
    # (rather than arithmetic) keeps this correct across DST and clock jumps,
    # and the iteration count is bounded by elapsed_time/period.
    while start + period <= now:
        start += period
        rolled = True
    return start, start + period, not rolled


def ledger_total(home, start, end):
    total = 0.0
    counted = 0
    for path in sorted(glob.glob(os.path.join(home, "runs", "*.jsonl"))):
        try:
            handle = open(path)
        except OSError:
            continue
        with handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                stamp = parse_ts(row.get("ts"))
                # An entry with an unparseable/missing ts cannot be placed in
                # the window; skipping is the conservative choice (it can only
                # under-report, never invent spend).
                if stamp is None or stamp < start or stamp >= end:
                    continue
                try:
                    total += float(row.get("cost") or 0)
                except (TypeError, ValueError):
                    continue
                counted += 1
    return total, counted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=os.environ.get("AP_HOME", os.path.expanduser("~/.autopilot")))
    parser.add_argument("--format", default="shell", choices=("shell", "json", "usd"))
    args = parser.parse_args()

    now = datetime.datetime.now(datetime.timezone.utc)
    state = load_state(args.home)
    start, end, baseline_applies = window(state, now)
    spent, counted = ledger_total(args.home, start, end)
    baseline = state["baseline_usd"] if (state and baseline_applies) else 0.0
    total = baseline + spent

    payload = {
        "cost": round(total, 6),
        "spent_since_anchor": round(spent, 6),
        "baseline_usd": round(baseline, 6),
        "baseline_applied": bool(baseline_applies and state),
        "entries": counted,
        "window_start": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window_end": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "period_days": state["period_days"] if state else 7,
        "anchored": state is not None,
        "days_left": round((end - now).total_seconds() / 86400.0, 2),
    }

    if args.format == "json":
        print(json.dumps(payload))
    elif args.format == "usd":
        print("%.2f" % payload["cost"])
    else:
        for key, value in payload.items():
            print("AP_WEEK_%s=%s" % (key.upper(), value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
