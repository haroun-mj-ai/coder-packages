#!/usr/bin/env python3
"""ap_env.py -- read/write $AP_HOME/env's KEY=value lines (the autopilot
budget/concurrency knobs: AP_MAX_ISSUES_PER_DAY, AP_MAX_DAY_COST_USD,
AP_MAX_WEEK_COST_USD, AP_BUILD_SLOTS, AP_SHIP_SLOTS, AP_LIMIT_COOLDOWN_MIN).

The ONE shared implementation of that read-modify-write -- `ap limits`
(bash) shells out to this, `ap sessions`'s [L]imits action imports it
directly -- so there is exactly one place that knows how to safely edit
that file, matching the ap_queue.py precedent for the local ticket queue.
"""
import argparse
import json
import re
import sys

LIMIT_FIELDS = [
    ("AP_MAX_ISSUES_PER_DAY", "issues/day"),
    ("AP_MAX_DAY_COST_USD", "cost/day ($)"),
    ("AP_MAX_WEEK_COST_USD", "cost/week ($, informational)"),
    ("AP_BUILD_SLOTS", "build slots (clamped 1-4)"),
    ("AP_SHIP_SLOTS", "ship slots (clamped 1-6)"),
    ("AP_LIMIT_COOLDOWN_MIN", "usage-limit cooldown (min)"),
]


def read_value(path, key):
    """The live value of `key` in the env file -- whether it's currently
    set or commented out (so callers can tell "explicitly configured" from
    "still at whatever default ap-env.sh falls back to"). None if the file
    or the key doesn't exist at all."""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return None
    pattern = re.compile(r"^#?\s*" + re.escape(key) + r"=(.*)$")
    for line in lines:
        m = pattern.match(line.rstrip("\n"))
        if m:
            return m.group(1).strip()
    return None


def write_value(path, key, value):
    """Read-modify-write: replace the key's line if present (commented or
    not -- always converges on one live, uncommented definition), else
    append a new line. Every other line in the file is left untouched."""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        lines = []
    pattern = re.compile(r"^#?\s*" + re.escape(key) + r"=")
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = f"{key}={value}\n"
            break
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key}={value}\n")
    with open(path, "w") as f:
        f.writelines(lines)


def main():
    ap = argparse.ArgumentParser(prog="ap_env.py")
    ap.add_argument("--file", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("get")
    p.add_argument("key")

    p = sub.add_parser("get-all", help="prints {key: value_or_null, ...} as JSON")
    p.add_argument("keys", nargs="+")

    p = sub.add_parser("set")
    p.add_argument("key")
    p.add_argument("value")

    args = ap.parse_args()
    if args.cmd == "get":
        v = read_value(args.file, args.key)
        if v is not None:
            print(v)
    elif args.cmd == "get-all":
        print(json.dumps({k: read_value(args.file, k) for k in args.keys}))
    elif args.cmd == "set":
        write_value(args.file, args.key, args.value)
        print(f"{args.key}={args.value}")


if __name__ == "__main__":
    main()
