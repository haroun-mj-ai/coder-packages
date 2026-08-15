#!/usr/bin/env python3
"""Inspect individual autopilot acts. Backend for `ap runs|run|tail`, and
(via ap_queue.py) the local queue's mutation commands: `ap queue`/`ap
approve`/`ap reply`/`ap retry` -- the CLI-only replacement for what used to
be a GitHub inbox comment/label.

A persistent-mode act (the default) runs in a real tmux window, so
`ap sessions`'s `[a]ttach` action (see _attach_act) can jump a terminal into
it directly. What there is for inspecting any act, live or finished:

  * the ledger row      ~/.autopilot/runs/<date>.jsonl   (phase, status, cost)
  * the run dir         ~/.autopilot/runs/<ts>-<pid>/    (status.json, *.stderr)
  * the transcript      ~/.claude/projects/**/<session-id>.jsonl
  * the live process    `claude -p ... --run-dir <run-dir>` in the process table

This joins them. A live act is found by the --run-dir in its argv, mapped to a
session id through ~/.claude/sessions/<pid>.json; a finished act comes from the
ledger, and its run dir is recovered from the --run-dir in its own prompt.
"""
import argparse
import curses
import curses.textpad
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import ap_queue

AP_HOME = Path(os.environ.get("AP_HOME", Path.home() / ".autopilot"))
# cc-top lives in the sibling coder-packages/bin/, not autopilot/bin/ --
# shelled out to (not imported) so the two tools stay decoupled; `ap
# sessions` is the one place that needs cc-top's full per-session stats
# (cost/model/TTL/idle) merged onto its own act/queue-oriented rows.
CC_TOP = Path(__file__).resolve().parents[2] / "bin" / "cc-top"
if not CC_TOP.exists():
    _found = shutil.which("cc-top")
    CC_TOP = Path(_found) if _found else None
RUNS = AP_HOME / "runs"
# Overridable so the test harness can point at fixture transcripts instead of
# the real ~/.claude; nothing in normal use sets these.
PROJECTS = Path(os.environ.get("AP_PROJECTS_DIR",
                               Path.home() / ".claude" / "projects"))
SESSIONS = Path(os.environ.get("AP_SESSIONS_DIR",
                               Path.home() / ".claude" / "sessions"))
# Same override the test harness (and a non-default AP_TMUX_SESSION) needs so
# this never touches the real "autopilot" session by accident.
AP_TMUX_SESSION = os.environ.get("AP_TMUX_SESSION", "autopilot")

C = {"dim": "\033[2m", "b": "\033[1m", "r": "\033[31m", "g": "\033[32m",
     "y": "\033[33m", "c": "\033[36m", "0": "\033[0m"}
if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
    C = dict.fromkeys(C, "")


def col(k, s):
    return f"{C[k]}{s}{C['0']}"


def issue_of(s):
    """ENG-1181 out of an issue id or a plan path/filename."""
    m = re.search(r"(ENG-\d+)", str(s), re.I)
    return m.group(1).upper() if m else Path(str(s)).name[:10]


# --- discovery ---------------------------------------------------------------

# act_plan_<issue>_<phase> / act_build_<slot>_<issue>_<phase> /
# act_ship_<slot>_<issue>_<phase> -- the naming scheme ap-cycle.sh's
# window_name_for() uses (AP_ACT_LAUNCH_MODE=persistent). Underscore-
# separated, not dot-separated: tmux's own target syntax is
# session:window.pane, so a dotted window name gets misparsed by tmux
# itself the moment anything targets it by name.
_ACT_WINDOW_RE = re.compile(
    r"^act_(?:plan|build_\d+|ship_\d+)_(?P<issue>[^_]+)_(?P<phase>[^_]+)$"
)


def _tmux_windows(session=None):
    """[(window_name, pane_pid)] in the given tmux session, or [] if tmux
    or the session isn't up -- never an error worth surfacing here."""
    session = session or AP_TMUX_SESSION
    try:
        out = subprocess.run(
            ["tmux", "list-windows", "-t", session, "-F", "#{window_name} #{pane_pid}"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        name, _, pid_s = line.rpartition(" ")
        if name and pid_s.isdigit():
            rows.append((name, int(pid_s)))
    return rows


def _parked_registry_by_window():
    """{window_name: registry_dict} for every current $AP_HOME/parked/*.json
    entry -- see ap-cycle.sh's park_registry_write. Empty (not an error) in
    AP_ACT_LAUNCH_MODE=oneshot, where nothing ever parks."""
    parked_dir = AP_HOME / "parked"
    out = {}
    if not parked_dir.is_dir():
        return out
    for f in parked_dir.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        w = d.get("window")
        if w:
            out[w] = d
    return out


def live_acts():
    """[{pid, run_dir, phase, target, session_id, parked, window}] for running
    acts, from BOTH launch modes -- a one-shot `claude -p` in the process
    table (AP_ACT_LAUNCH_MODE=oneshot, `window` is None: no pane exists) and
    a persistent tmux window (AP_ACT_LAUNCH_MODE=persistent, the default,
    `window` is its tmux window name). A given pipeline only ever runs one
    mode at a time, but both code paths are kept so this still works
    immediately after flipping the env var either way."""
    out = []
    try:
        ps = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True,
                            text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        ps = ""
    reg = {}
    for f in SESSIONS.glob("*.json"):
        try:
            d = json.loads(f.read_text())
            reg[d.get("pid")] = d.get("sessionId")
        except (OSError, json.JSONDecodeError):
            pass

    for line in ps.splitlines():
        line = line.strip()
        if " -p " not in line or "--run-dir" not in line:
            continue
        pid_s, _, args = line.partition(" ")
        if not pid_s.isdigit():
            continue
        rd = re.search(r"--run-dir (\S+)", args)
        skill = re.search(r"-p (/\S+)", args)
        # implement-issue names both plan and implement acts identically (one
        # skill, two phases) -- its own --phase argument is what disambiguates,
        # not the skill name, which ship-work has none of.
        phase_flag = re.search(r"--phase (\S+)", args)
        if skill and skill.group(1).lstrip("/") == "implement-issue" and phase_flag:
            phase_label = phase_flag.group(1)
            tgt = re.search(r"--phase \S+ (\S+)", args)
        else:
            phase_label = (skill.group(1).lstrip("/").replace("ship-work", "ship")
                           if skill else "?")
            # the prompt's first token after the skill is the target (issue or plan)
            tgt = re.search(r"-p /\S+ (\S+)", args)
        pid = int(pid_s)
        out.append({
            "pid": pid,
            "run_dir": rd.group(1) if rd else "",
            "phase": phase_label,
            # implement/ship are handed a plan path, not an issue id; pull the
            # issue out of the filename so the column reads the same as plan's.
            "target": issue_of(tgt.group(1)) if tgt else "",
            "session_id": reg.get(pid, ""),
            "parked": False,
            "window": None,
        })

    parked_by_window = _parked_registry_by_window()
    for window_name, pid in _tmux_windows():
        m = _ACT_WINDOW_RE.match(window_name)
        if not m:
            continue
        registry = parked_by_window.get(window_name) or {}
        out.append({
            "pid": pid,
            "run_dir": registry.get("run_dir", ""),
            "phase": m.group("phase"),
            "target": issue_of(m.group("issue")),
            "session_id": reg.get(pid, ""),
            "parked": window_name in parked_by_window,
            "window": window_name,
        })
    return out


def ledger_rows(days=3):
    rows = []
    for p in sorted(RUNS.glob("*.jsonl"))[-days:]:
        for line in p.read_text().splitlines():
            if line.strip():
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def transcript(session_id):
    if not session_id:
        return None
    hits = list(PROJECTS.rglob(f"{session_id}*.jsonl"))
    return hits[0] if hits else None


def subagent_files(t):
    return sorted((t.parent / t.stem / "subagents").glob("*.jsonl")) if t else []


def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def read(t):
    if not t or not t.exists():
        return []
    out = []
    with t.open(errors="replace") as fh:
        for line in fh:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def summarize(t):
    """Roll a transcript up into the numbers worth printing."""
    # `models` counts every request including subagents; `main_models` counts
    # only the act's own loop, which is what --model pins. Subagents outnumber
    # the main loop, so reporting the modal model over everything hides it.
    s = {"reqs": 0, "models": {}, "main_models": {}, "in": 0, "out": 0,
         "cache_r": 0, "cache_w": 0, "tools": {}, "tool_errors": 0,
         "api_errors": 0, "first": None, "last": None, "run_dir": "",
         "final": "", "subagents": 0, "by_model": {}}
    seen = set()
    for f in [t] + subagent_files(t):
        s["subagents"] += 1 if f != t else 0
        for d in read(f):
            if d.get("isApiErrorMessage"):
                s["api_errors"] += 1
            if not s["run_dir"]:
                # The prompt is wrapped in XML-ish tags, so stop at the first
                # quote/brace/angle rather than taking all non-whitespace.
                mm = re.search(r"--run-dir ([^\s<'\"}]+)",
                               str(d.get("message", ""))[:4000])
                if mm:
                    s["run_dir"] = mm.group(1)
            when = ts(d.get("timestamp"))
            if when:
                s["first"] = min(s["first"] or when, when)
                s["last"] = max(s["last"] or when, when)
            tr = d.get("toolUseResult")
            if isinstance(tr, dict) and (tr.get("is_error") or tr.get("isError")):
                s["tool_errors"] += 1
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            for b in msg.get("content") or []:
                if isinstance(b, dict):
                    if b.get("type") == "tool_use":
                        s["tools"][b.get("name", "?")] = s["tools"].get(b.get("name", "?"), 0) + 1
                    elif b.get("type") == "text" and b.get("text", "").strip() and f == t:
                        s["final"] = b["text"]
            u = msg.get("usage")
            if not u:
                continue
            key = msg.get("id") or d.get("requestId")
            if key:
                if key in seen:
                    continue
                seen.add(key)
            s["reqs"] += 1
            m = msg.get("model", "?")
            s["models"][m] = s["models"].get(m, 0) + 1
            if f == t:
                s["main_models"][m] = s["main_models"].get(m, 0) + 1
            s["in"] += u.get("input_tokens", 0)
            s["out"] += u.get("output_tokens", 0)
            s["cache_r"] += u.get("cache_read_input_tokens", 0)
            s["cache_w"] += u.get("cache_creation_input_tokens", 0)
            # Per-model buckets (split cache-write by TTL) so estimate_cost()
            # can price each request at its own model's rate -- a session mixing
            # a main model with cheaper subagent models must not all get priced
            # as one, and 1h vs 5m cache writes are billed at different rates.
            cc = u.get("cache_creation")
            bm = s["by_model"].setdefault(
                m, {"in": 0, "out": 0, "cache_r": 0, "cache_w_1h": 0, "cache_w_5m": 0})
            bm["in"] += u.get("input_tokens", 0)
            bm["out"] += u.get("output_tokens", 0)
            bm["cache_r"] += u.get("cache_read_input_tokens", 0)
            if cc:
                bm["cache_w_1h"] += cc.get("ephemeral_1h_input_tokens", 0)
                bm["cache_w_5m"] += cc.get("ephemeral_5m_input_tokens", 0)
            else:
                # Older/simpler usage shape has no 1h/5m breakdown, just the
                # flat total -- assume the 5m (non-opted-in) rate rather than
                # silently dropping the cache-write cost entirely, since a
                # write premium is usually the single biggest cost driver.
                bm["cache_w_5m"] += u.get("cache_creation_input_tokens", 0)
    return s


# USD per million tokens, standard service tier, base input/output rates.
# Cache write = 2x base input (1h TTL) or 1.25x base input (5m TTL); cache
# read = 0.1x base input -- Anthropic's published multipliers. Matched by
# substring against the model string (e.g. "claude-opus-5" contains "opus").
MODEL_PRICING = {
    "opus": {"in": 15.0, "out": 75.0},
    "sonnet": {"in": 3.0, "out": 15.0},
    "haiku": {"in": 0.80, "out": 4.0},
}


def _price_for(model):
    m = (model or "").lower()
    for key, p in MODEL_PRICING.items():
        if key in m:
            return p
    return None


def estimate_cost(s):
    """USD estimate from a summarize() result's per-model token buckets.
    Returns (total, skipped_models) -- a model this table doesn't recognize
    is left out of the total rather than guessed at, and reported back so
    the caller can say the estimate is partial instead of silently wrong."""
    total = 0.0
    skipped = []
    for model, b in (s.get("by_model") or {}).items():
        p = _price_for(model)
        if not p:
            skipped.append(model)
            continue
        total += b["in"] * p["in"] / 1e6
        total += b["out"] * p["out"] / 1e6
        total += b["cache_r"] * (p["in"] * 0.1) / 1e6
        total += b["cache_w_1h"] * (p["in"] * 2.0) / 1e6
        total += b["cache_w_5m"] * (p["in"] * 1.25) / 1e6
    return total, skipped


def resolve(target):
    """target -> (kind, record). Accepts 'latest', a session-id prefix, an
    issue id, or a run-dir name."""
    live = live_acts()
    if target in ("latest", "last", ""):
        if live:
            return "live", live[-1]
        rows = [r for r in ledger_rows() if r.get("phase") != "poll" and r.get("session_id")]
        if not rows:
            rows = [r for r in ledger_rows() if r.get("session_id")]
        return ("done", rows[-1]) if rows else (None, None)
    t = target.lower()
    for a in live:
        # Exact on the issue, not substring: `ENG-1` must not match `ENG-1181`.
        # An act with no session id yet has no transcript to show, so skip it.
        if not a["session_id"]:
            continue
        if a["session_id"].startswith(target) or t == a["target"].lower() \
                or t == Path(a["run_dir"]).name.lower():
            return "live", a
    for r in reversed(ledger_rows(days=30)):
        if (r.get("session_id") or "").startswith(target) \
                or t == str(r.get("issue") or "").lower():
            return "done", r
    return None, None


# --- rendering ---------------------------------------------------------------

def main_model(s):
    """The act's own loop model — the one --model pins."""
    d = (s or {}).get("main_models") or {}
    return max(d, key=d.get).replace("claude-", "")[:9] if d else "-"


def human(n):
    for u, d in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= d:
            return f"{n/d:.1f}{u}"
    return str(int(n))


def brief(block):
    """One-line gist of a tool_use block."""
    name = block.get("name", "?")
    i = block.get("input") or {}
    for k in ("command", "file_path", "pattern", "path", "prompt", "description",
              "url", "query", "subagent_type"):
        if k in i:
            v = str(i[k]).replace("\n", " ")
            return f"{name}({k}={v[:90]})"
    return name


def age_str(ts_str):
    when = ts(ts_str)
    if not when:
        return "-"
    secs = int((datetime.now(timezone.utc) - when).total_seconds())
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


QUEUE_DASHBOARD_STATES = ("queued", "plan-review", "needs-input", "ship-pending")


def _cc_top_stats():
    """session_id -> cc-top's row for it (cost/model/effort/out-per-min/
    $/hr/$tot/tokens/reqs/idle/ttl) -- every session on this machine, not
    just autopilot's, via `cc-top --json`. Empty dict (never raises) if
    cc-top can't be found or the call fails for any reason -- this is a
    display enrichment, never load-bearing for `ap sessions`'s own act/
    queue logic. -a is generous (7 days) since a parked act can idle far
    longer than cc-top's own 60-minute default before a human gets to it."""
    if not CC_TOP:
        return {}
    try:
        out = subprocess.run(
            [sys.executable, str(CC_TOP), "--json", "-a", "10080"],
            capture_output=True, text=True, timeout=15).stdout
        rows = json.loads(out)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return {}
    return {r["session_id"]: r for r in rows if r.get("session_id")}


def _dashboard_rows():
    """Every live act, plus every queue ticket waiting on a human decision
    (queued/plan-review/needs-input/ship-pending), plus each OTHER issue's
    most recent finished outcome (so a FAILED/DONE/NEEDS_HUMAN act doesn't
    just disappear from the dashboard once its window is gone) -- one row
    per issue, live wins, then a pending queue state, then the ledger. Live
    rows additionally carry `stats` (cc-top's per-session cost/model/TTL/
    idle, keyed by session_id) when a match is found -- None otherwise.

    A queue ticket's state ALWAYS wins over the ledger's historical status
    once one exists for that issue, no matter which state it's in -- not
    just the 4 "awaiting decision" ones. Marking a stale row done/resolved
    via the [s]tatus action would otherwise keep silently losing to the old
    ledger row here, which is exactly the bug that made it look like nothing
    happened."""
    live = live_acts()
    live_issues = {a["target"] for a in live if a.get("target")}
    all_queue = {e["eng_id"]: e for e in ap_queue.list_queue(str(AP_HOME))}
    queue_entries = [e for eng_id, e in all_queue.items()
                      if e.get("state") in QUEUE_DASHBOARD_STATES
                      and eng_id not in live_issues]
    queue_pending_issues = {e["eng_id"] for e in queue_entries}
    by_issue = {}
    latest_session_for_issue = {}
    for r in ledger_rows(days=7):
        if r.get("phase") == "poll" or not r.get("issue"):
            continue
        # Unfiltered: even a queue-pending issue (e.g. needs-input, its
        # window long dead) had a real session at some point -- keep that
        # around so its row can still show cc-top's historical stats for it,
        # not just issues that fall through to a "done" ledger row.
        if r.get("session_id"):
            latest_session_for_issue[r["issue"]] = r["session_id"]  # chronological -- last wins
        if r["issue"] in live_issues or r["issue"] in queue_pending_issues:
            continue
        by_issue[r["issue"]] = r
    cc_stats = _cc_top_stats()
    rows = [{"kind": "live", "issue": a["target"], "phase": a["phase"], "status": "LIVE",
              "note": "parked (needs input)" if a["parked"] else
                      ("interactive" if a["window"] else "headless"),
              "rec": a, "stats": cc_stats.get(a.get("session_id"))}
            for a in sorted(live, key=lambda a: a["target"] or "")]
    rows += [{"kind": "queue", "issue": e["eng_id"], "phase": None,
               "status": e["state"].upper(), "note": _queue_note(e), "rec": e,
               "stats": cc_stats.get(latest_session_for_issue.get(e["eng_id"]))}
             for e in sorted(queue_entries, key=lambda e: e.get("seq", 0))]
    for iss, r in sorted(by_issue.items(), key=lambda kv: kv[1].get("ts", "")):
        # The ledger row always carries the real session_id for this
        # issue's last act, even once it's finished -- cc-top's own scan
        # still has stats for it as long as the transcript is within its
        # lookback window, so a DONE/FAILED/etc. row isn't stuck showing all
        # dashes just because it's not live anymore.
        row_stats = cc_stats.get(r.get("session_id"))
        q = all_queue.get(iss)
        if q is not None and iss not in live_issues and iss not in queue_pending_issues:
            # A non-pending queue state (done/failed/building/planning/
            # shipping/ready-to-test) with no live act for it -- show the
            # queue's own state/note, not the possibly long-stale ledger row.
            rows.append({"kind": "queue", "issue": iss, "phase": r.get("phase"),
                         "status": q["state"].upper(), "note": _queue_note(q),
                         "rec": q, "stats": row_stats})
        else:
            rows.append({"kind": "done", "issue": iss, "phase": r.get("phase"),
                         "status": r.get("status"), "note": f"{age_str(r.get('ts'))} ago",
                         "rec": r, "stats": row_stats})
    return rows


def _queue_note(entry):
    """A custom note (set via the [e]dit-note action) always wins over the
    state-derived default text -- except needs-input, where the blocking
    question is too operationally important to bury, so a custom note is
    appended to it instead of replacing it."""
    state = entry.get("state")
    custom = entry.get("note")
    if state == "needs-input":
        q = (entry.get("question") or "blocking question")[:50]
        return f"{q} | {custom}" if custom else q
    if custom:
        return custom
    if state == "queued":
        return "awaiting plan"
    if state == "plan-review":
        if entry.get("auto_approve"):
            return "auto-approve on"
        if entry.get("pending_approval"):
            return "approved -- building next cycle"
        return "awaiting `ap approve`"
    if state == "ship-pending":
        return "will ship automatically next cycle"
    if state == "done":
        return "marked done"
    if state == "failed":
        return "failed"
    if state == "ready-to-test":
        pr_urls = entry.get("pr_urls") or []
        return "PRs open" + (f": {', '.join(pr_urls)}" if pr_urls else "")
    if state in ("building", "planning", "shipping"):
        return "no live session for this state -- possibly stale, check `ap decide`"
    return state or "-"


DASHBOARD_HDR = (f"{'#':>2} {'ISSUE':<10} {'PHASE':<10} {'STATUS':<8} "
                  f"{'MODEL':<14} {'EFF':<4} {'OUT/min':>7} {'$/hr':>6} "
                  f"{'$TOT':>7} {'OUT':>6} {'CACHE-R':>7} {'REQ':>4} "
                  f"{'IDLE':>6} {'TTL':>7}  NOTE")


def _ttl_cell(stats):
    """(text, color_class) for the TTL column -- color_class is 'g'/'y'/'r'
    (only meaningful in the curses renderer; the plain fallback ignores it).
    Same thresholds/formula as cc-top's own ttl_str()."""
    if not stats:
        return "-", None
    remaining = stats.get("ttl_remaining_sec")
    if remaining is None:
        return "-", None
    if remaining > 0:
        mins = remaining / 60
        return ("<1m" if mins < 1 else f"{mins:.0f}m"), ("g" if remaining > 600 else "y")
    overdue = ((time.time() - (stats.get("last") or time.time()))
               - (stats.get("ttl_bucket_sec") or 300)) / 60
    return f"EXP+{overdue:.0f}m", "r"


def _stat_cells(stats):
    """Plain-text values for cc-top's numeric columns, given a row's `stats`
    (or None if this row has no live session cc-top could match)."""
    if not stats:
        return dict(model="-", eff="-", out_min="-", usd_hr="-", tot="-",
                     out="-", cache_r="-", req="-", idle="-", ttl="-")
    tokens = stats.get("tokens") or {}
    ttl, _ = _ttl_cell(stats)
    return dict(
        model=(stats.get("model") or "?").replace("claude-", "")[:14],
        eff=(stats.get("effort") or "")[:4],
        out_min=human(stats.get("out_per_min") or 0),
        usd_hr=f"{stats.get('usd_per_hr') or 0:.2f}",
        tot=f"{stats.get('cost') or 0:.2f}",
        out=human(tokens.get("output_tokens", 0)),
        cache_r=human(tokens.get("cache_read_input_tokens", 0)),
        req=str(stats.get("reqs") or 0),
        idle=(f"{stats['idle_min']:.0f}m" if stats.get("idle_min") is not None else "-"),
        ttl=ttl,
    )


def _row_parts(i, row):
    """(prefix, ttl_cell, suffix) for one dashboard line, split around the
    TTL cell specifically -- built from exact field widths, not string
    search, so the curses renderer can recolor just that cell without any
    risk of a coincidental text match elsewhere in the line (e.g. inside a
    long NOTE)."""
    c = _stat_cells(row.get("stats"))
    prefix = (f"{i:>2} {row['issue'] or '-':<10} {(row['phase'] or '-'):<10} "
              f"{row['status']:<8} {c['model']:<14} {c['eff']:<4} "
              f"{c['out_min']:>7} {c['usd_hr']:>6} {c['tot']:>7} {c['out']:>6} "
              f"{c['cache_r']:>7} {c['req']:>4} {c['idle']:>6} ")
    ttl_cell = f"{c['ttl']:>7}"
    suffix = f"  {row['note']}"
    return prefix, ttl_cell, suffix


def _row_line(i, row):
    """One plain-text dashboard line -- shared by the non-tty fallback and
    (cell-by-cell, for TTL coloring) the curses renderer."""
    prefix, ttl_cell, suffix = _row_parts(i, row)
    return prefix + ttl_cell + suffix


def _print_dashboard(rows):
    if not rows:
        print("no live or recent acts")
        return
    print(DASHBOARD_HDR)
    for i, row in enumerate(rows, 1):
        print(_row_line(i, row))


def _attach_act(window):
    """Jump this terminal into a live act's real tmux window, so you can
    watch/type into it directly instead of the read-only `ap tail`. Same
    nested-attach / no-tty fallback cmd_watch uses -- print the command
    instead of exec'ing into it when we can't actually attach."""
    target = f"{AP_TMUX_SESSION}:{window}"
    if os.environ.get("TMUX") or not sys.stdout.isatty():
        print(f"attach with:  tmux attach -t {target}")
        return
    os.execvp("tmux", ["tmux", "attach-session", "-t", target])


def _wait_key(msg="[Enter to return] "):
    try:
        input(msg)
    except EOFError:
        pass


def _kill_window_and_registry(window, issue):
    """Force-end a tmux window and drop any parked-registry entry for it --
    the shared mechanics behind both the standalone [K]ill action and
    _action_status_curses's auto-kill when a terminal status is set on a
    still-live row."""
    subprocess.run(["tmux", "kill-window", "-t", f"{AP_TMUX_SESSION}:{window}"], check=False)
    if issue:
        (AP_HOME / "parked" / f"{issue}.json").unlink(missing_ok=True)


LEDGER_STATUS_TO_STATE = {"DONE": "done", "FAILED": "failed", "NEEDS_HUMAN": "needs-input"}


def _row_initial_state(row):
    """Best-guess queue state to seed a brand-new ticket with, for a
    ledger-only row that has no queue file yet -- preserves its real
    historical outcome instead of silently defaulting to `queued` (which is
    exactly what setting a note on it used to do as a side effect)."""
    if row["kind"] == "done":
        return LEDGER_STATUS_TO_STATE.get(row["status"])
    return None


def _action_attach(row):
    """Jump straight into the row's live tmux window -- no reply/back prompt
    first. You can always reply by just typing into the attached session,
    so a reply-or-attach-or-back menu ahead of it was pure friction. The one
    action that still drops to the plain terminal (see _dispatch_attach) --
    a real tmux attach needs the actual terminal handed over, which a
    curses popup fundamentally can't do."""
    rec = row["rec"]
    if row["kind"] != "live" or not rec.get("window"):
        print("not applicable: no live tmux window for this row (headless act, or not live)")
        _wait_key()
        return
    _attach_act(rec["window"])  # execvp's into tmux directly on success; falls
    # back to printing the attach command (and returning normally) only when
    # already nested in tmux or stdout isn't a real tty


def _repaint_base(stdscr):
    """Force a clean repaint of the plain dashboard before drawing a new
    popup -- a newwin() overlay never touches stdscr's own buffer, so any
    two popups shown back-to-back (e.g. confirm-then-message, or two text
    inputs in a row) would otherwise overlap the previous popup's leftover
    pixels instead of starting from a clean base. Called at the top of
    every popup function so callers never have to remember it themselves."""
    stdscr.touchwin()
    stdscr.refresh()


def _popup_menu(stdscr, title, options, initial=0):
    """Modal, arrow-navigable popup listing `options` on top of the current
    curses screen (no drop to plain terminal) -- returns the chosen string,
    or None if cancelled (Esc/q). Up/Down or j/k move, Enter chooses."""
    if not options:
        return None
    _repaint_base(stdscr)
    h, w = stdscr.getmaxyx()
    box_h = min(len(options) + 4, max(5, h - 2))
    box_w = min(max(len(title), max(len(o) for o in options)) + 6, max(20, w - 2))
    y0 = max(0, (h - box_h) // 2)
    x0 = max(0, (w - box_w) // 2)
    win = curses.newwin(box_h, box_w, y0, x0)
    win.keypad(True)
    sel = max(0, min(initial, len(options) - 1))
    while True:
        win.erase()
        win.border()
        win.addnstr(0, 2, f" {title} ", max(1, box_w - 4), curses.A_BOLD)
        for i, opt in enumerate(options):
            row_y = i + 2
            if row_y >= box_h - 1:
                break
            attr = curses.A_REVERSE if i == sel else curses.A_NORMAL
            win.addnstr(row_y, 2, opt, max(1, box_w - 4), attr)
        win.addnstr(box_h - 1, 2, "↑/↓ select, Enter choose, Esc cancel", max(1, box_w - 4), curses.A_DIM)
        win.refresh()
        try:
            key = win.getch()
        except curses.error:
            key = -1
        if key in (curses.KEY_UP, ord("k")):
            sel = max(0, sel - 1)
        elif key in (curses.KEY_DOWN, ord("j")):
            sel = min(len(options) - 1, sel + 1)
        elif key in (10, 13, curses.KEY_ENTER):
            return options[sel]
        elif key in (27, ord("q")):
            return None
        elif key == curses.KEY_RESIZE:
            stdscr.erase()
            stdscr.refresh()
            h, w = stdscr.getmaxyx()


def _popup_confirm(stdscr, message):
    """Yes/No confirm popup, same arrow-navigable mechanics as _popup_menu."""
    return _popup_menu(stdscr, message, ["No", "Yes"], initial=0) == "Yes"


def _popup_text_input(stdscr, title, initial=""):
    """Modal text-entry popup on top of the current curses screen -- type,
    Enter submits, Esc cancels. Returns the entered text (str, possibly
    empty) or None if cancelled. Backspace/arrow-key line editing comes free
    from curses.textpad.Textbox; the validator below just remaps Enter/Esc
    onto Textbox's own Ctrl-G "done editing" trigger."""
    _repaint_base(stdscr)
    h, w = stdscr.getmaxyx()
    box_w = min(max(len(title) + 4, 54), max(20, w - 4))
    box_h = 4
    y0 = max(0, (h - box_h) // 2)
    x0 = max(0, (w - box_w) // 2)
    win = curses.newwin(box_h, box_w, y0, x0)
    win.keypad(True)
    win.border()
    win.addnstr(0, 2, f" {title} ", max(1, box_w - 4), curses.A_BOLD)
    win.addnstr(box_h - 1, 2, "Enter submit, Esc cancel", max(1, box_w - 4), curses.A_DIM)
    win.refresh()
    edit_w = max(1, box_w - 4)
    edit_win = win.derwin(1, edit_w, 2, 2)
    edit_win.erase()
    if initial:
        try:
            edit_win.addnstr(0, 0, initial, edit_w - 1)
        except curses.error:
            pass
    edit_win.refresh()
    box = curses.textpad.Textbox(edit_win, insert_mode=True)
    cancelled = False

    def _validator(ch):
        nonlocal cancelled
        if ch == 27:  # Esc
            cancelled = True
            return 7  # Ctrl-G: Textbox's own "stop editing" trigger
        if ch in (10, curses.KEY_ENTER):  # Enter submits, same trigger
            return 7
        return ch

    curses.curs_set(1)
    try:
        box.edit(_validator)
    finally:
        curses.curs_set(0)
    return None if cancelled else box.gather().strip()


def _popup_message(stdscr, title, lines):
    """Modal info/result popup -- shows text, dismissed by any key. Replaces
    the old plain-terminal print()+wait-for-Enter pattern everywhere except
    attach (which must hand over the real terminal)."""
    if isinstance(lines, str):
        lines = lines.splitlines() or [""]
    lines = lines or ["(nothing to show)"]
    _repaint_base(stdscr)
    h, w = stdscr.getmaxyx()
    content_w = max((len(l) for l in lines), default=10)
    box_w = min(max(len(title) + 4, content_w + 4), max(20, w - 4))
    box_h = min(len(lines) + 3, max(4, h - 2))
    y0 = max(0, (h - box_h) // 2)
    x0 = max(0, (w - box_w) // 2)
    win = curses.newwin(box_h, box_w, y0, x0)
    win.keypad(True)
    win.border()
    win.addnstr(0, 2, f" {title} ", max(1, box_w - 4), curses.A_BOLD)
    for i, line in enumerate(lines):
        row_y = i + 1
        if row_y >= box_h - 1:
            break
        win.addnstr(row_y, 2, line, max(1, box_w - 4))
    win.addnstr(box_h - 1, 2, "any key to dismiss", max(1, box_w - 4), curses.A_DIM)
    win.refresh()
    try:
        win.getch()
    except curses.error:
        pass


TERMINAL_STATES = {"done", "failed", "ready-to-test"}


def _action_status_curses(stdscr, row):
    """The general status-change action -- also how a stale ledger-only row
    (no queue file at all, e.g. an old NEEDS_HUMAN/FAILED the human already
    resolved by hand) gets marked done: force_state creates the ticket on
    the fly if it doesn't exist yet. Arrow-navigable popup to pick the new
    state, then a second popup to confirm -- distinct from the other
    actions (which are direct keys with no menu): a status is inherently a
    pick-one-of-N-known-values choice, so browsing beats typing the exact
    state name.

    Setting a terminal state (done/failed/ready-to-test) on a row that's
    STILL live also ends its tmux window in the same motion -- a ticket
    can't be both "done" and "live" at once, and leaving the window running
    is exactly why marking something done previously kept showing LIVE no
    matter what the queue file said (a tmux window existing is the only
    live-ness signal this dashboard has; it never consulted queue state)."""
    issue = row["issue"]
    if not issue:
        return
    current = (row.get("rec") or {}).get("state")
    is_live = row["kind"] == "live"
    window = (row.get("rec") or {}).get("window") if is_live else None
    states = sorted(ap_queue.STATES)
    choice = _popup_menu(stdscr, f"Set {issue}'s status",
                          states, initial=states.index(current) if current in states else 0)
    if choice is None or choice == current:
        return
    will_kill = bool(is_live and window and choice in TERMINAL_STATES)
    confirm_msg = (f"Set {issue} -> {choice} AND end its live tmux window?"
                   if will_kill else f"Set {issue} -> {choice}?")
    if not _popup_confirm(stdscr, confirm_msg):
        return
    ap_queue.force_state(str(AP_HOME), issue, choice)
    if will_kill:
        _kill_window_and_registry(window, issue)


def _action_retry_curses(stdscr, row):
    if row["status"] != "FAILED":
        _popup_message(stdscr, "Retry", "not applicable: only a FAILED row can be retried")
        return
    ok, lines = retry_act(row["issue"])
    _popup_message(stdscr, "Retry", lines)


def _action_pause_curses(stdscr, row):
    rec = row["rec"]
    if row["kind"] != "live" or rec.get("parked") or not rec.get("window"):
        _popup_message(stdscr, "Pause", "not applicable: only a live, non-parked, interactive act can be paused")
        return
    ok, lines = interrupt_act(row["issue"])
    _popup_message(stdscr, "Pause", lines)


def _action_approve_curses(stdscr, row):
    if row["kind"] != "queue" or row["rec"].get("state") != "plan-review":
        _popup_message(stdscr, "Approve", "not applicable: only a plan-review ticket can be approved")
        return
    entry = ap_queue.approve_ticket(str(AP_HOME), row["issue"])
    _popup_message(stdscr, "Approved", f"approved {entry['eng_id']}" if entry else "no such ticket")


def _action_feedback_curses(stdscr, row):
    if row["kind"] != "queue" or row["rec"].get("state") not in ("plan-review", "needs-input"):
        _popup_message(stdscr, "Feedback",
                        "not applicable: only a plan-review or needs-input ticket takes feedback here")
        return
    if row["rec"].get("state") == "needs-input":
        _popup_message(stdscr, "Blocking question", row["rec"].get("question") or "(none recorded)")
    text = _popup_text_input(stdscr, f"Feedback/answer for {row['issue']}")
    if not text:
        return
    entry = ap_queue.reply_ticket(str(AP_HOME), row["issue"], text)
    _popup_message(stdscr, "Recorded", f"recorded for {entry['eng_id']}" if entry else "no such ticket")


def _action_note_curses(stdscr, row):
    """Set/clear a free-text note on any row's ticket -- creates the ticket
    if the row was ledger-only (no queue file yet), preserving its known
    historical state (see _row_initial_state) instead of resetting it."""
    issue = row["issue"]
    if not issue:
        _popup_message(stdscr, "Edit note", "not applicable: this row has no ticket id")
        return
    current_note = (row.get("rec") or {}).get("note") or ""
    text = _popup_text_input(stdscr, f"Note for {issue}", initial=current_note)
    if text is None:
        return
    entry = ap_queue.set_note(str(AP_HOME), issue, text, initial_state=_row_initial_state(row))
    _popup_message(stdscr, "Note updated", f"{entry['eng_id']} note -> {text or '(cleared)'}")


def _action_kill_curses(stdscr, row):
    """Force-end a live act's tmux window -- for a session that's actually
    stale (already handled/shipped outside the pipeline, or just stuck)
    rather than genuinely still working, which `ap sessions` otherwise has
    no way to tell apart from a real live act. Removes any parked-registry
    entry too, so the ticket becomes claimable/settable again; press [s]
    right after to record its real final state (or set a terminal state
    there directly -- it now kills the window itself too)."""
    rec = row["rec"]
    if row["kind"] != "live" or not rec.get("window"):
        _popup_message(stdscr, "Kill", "not applicable: no live tmux window for this row")
        return
    window = rec["window"]
    if not _popup_confirm(stdscr, f"Really kill '{window}' for {row['issue'] or '?'}?"):
        return
    _kill_window_and_registry(window, row["issue"])
    _popup_message(stdscr, "Killed",
                   [f"killed {window}.",
                    f"Press [s] now to record {row['issue'] or 'this ticket'}'s real final status."])


def _action_info_curses(stdscr, row):
    """Read-only peek at a row's transcript summary (model/requests/
    subagents/latest message) or queue detail (note/question) without
    committing to a full attach -- the old Enter-opens-detail view's
    content, as a dismissable popup instead of a blocking prompt."""
    lines = [f"{row['issue'] or '?'}   phase={row['phase'] or '-'}   status={row['status']}"]
    rec = row.get("rec") or {}
    if row["kind"] == "live" and rec.get("session_id"):
        t = transcript(rec["session_id"])
        if t:
            s = summarize(t)
            lines.append(f"model: {main_model(s)}   requests: {s['reqs']}   subagents: {s['subagents']}")
            if s.get("final"):
                lines.append("")
                lines.append("latest message:")
                lines.extend(s["final"][:600].splitlines())
        else:
            lines.append("(no transcript found)")
    elif row["kind"] == "queue":
        lines.append(f"note: {rec.get('note') or '-'}")
        if rec.get("question"):
            lines.append(f"question: {rec['question']}")
    _popup_message(stdscr, "Info", lines)


def _action_queue_new_curses(stdscr):
    """Queue a brand-new ticket without leaving the dashboard -- the CLI-only
    replacement for opening a GitHub inbox issue, reachable right from `ap
    sessions` instead of a separate `ap queue` invocation."""
    eng_id = _popup_text_input(stdscr, "ENG-id to queue")
    if not eng_id:
        return
    if not ap_queue.valid_eng_id(eng_id):
        _popup_message(stdscr, "Queue", f"not a valid ENG-<n> id: {eng_id!r}")
        return
    if ap_queue.read_ticket(str(AP_HOME), eng_id) is not None:
        _popup_message(stdscr, "Queue", f"{eng_id} is already queued")
        return
    note = _popup_text_input(stdscr, "Note (optional)") or ""
    auto = _popup_confirm(stdscr, "Auto-approve this ticket?")
    entry = ap_queue.new_ticket(str(AP_HOME), eng_id, note, auto)
    _popup_message(stdscr, "Queued", f"queued {entry['eng_id']}" + (" [auto-approve]" if auto else ""))


# Direct single-key actions on the selected row -- no arrow-driven menu:
# press the letter, it happens. Listed in the header so the binding never
# has to be memorized. 'n' (queue new) and 'q' (quit) act independently of
# the current selection; every other key here acts on the selected row.
# 's' (status) is handled separately in _curses_main -- it's the one
# genuine pick-one-of-N-known-values action, so it gets an arrow-navigable
# popup instead of a direct key, per its own nature (see
# _action_status_curses). Every action here stays fully inside curses
# (popups only) EXCEPT attach, which is handled separately too -- a real
# tmux attach needs the terminal itself handed over, which no popup can do.
ROW_ACTIONS = {
    ord("p"): ("pause", _action_pause_curses),
    ord("g"): ("go/approve", _action_approve_curses),
    ord("f"): ("feedback", _action_feedback_curses),
    ord("t"): ("retry", _action_retry_curses),
    ord("e"): ("edit note", _action_note_curses),
    ord("K"): ("kill", _action_kill_curses),
    ord("i"): ("info", _action_info_curses),
}
ACTION_HDR = "[a]ttach [i]nfo [p]ause [g]o [f]eedback [s]tatus [e]dit-note [K]ill [t]retry [n]ew [q]uit"


TTL_CURSES_COLOR = {"g": 1, "y": 2, "r": 3}


def _curses_main(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)
    curses.init_pair(2, curses.COLOR_YELLOW, -1)
    curses.init_pair(3, curses.COLOR_RED, -1)
    stdscr.keypad(True)
    stdscr.timeout(5000)  # live-refresh every 5s, same default cc-top --watch uses

    selected = 0
    rows = []
    last_scan = 0.0
    while True:
        now = time.time()
        if now - last_scan >= 5 or not rows:
            rows = _dashboard_rows()
            last_scan = now
            if rows:
                selected = max(0, min(selected, len(rows) - 1))
            else:
                selected = 0

        stdscr.erase()
        h, w = stdscr.getmaxyx()
        stdscr.addnstr(0, 0, "ap sessions -- central control point  (↑/↓ or j/k select)", w - 1, curses.A_BOLD)
        stdscr.addnstr(1, 0, ACTION_HDR, w - 1, curses.A_BOLD | curses.color_pair(1))
        stdscr.addnstr(2, 0, DASHBOARD_HDR, w - 1, curses.A_DIM)
        if not rows:
            stdscr.addnstr(4, 0, "no live or recent acts", w - 1)
        for i, row in enumerate(rows):
            if i + 3 >= h - 1:
                break  # more rows than fit -- truncate rather than error
            attr = curses.A_REVERSE if i == selected else curses.A_NORMAL
            prefix, ttl_cell, suffix = _row_parts(i + 1, row)
            stdscr.addnstr(i + 3, 0, prefix + ttl_cell + suffix, w - 1, attr)
            # Recolor just the TTL cell on top (exact offset, not a text
            # search), so it's still visible under A_REVERSE (selected row).
            _, ttl_color = _ttl_cell(row.get("stats"))
            if ttl_color:
                col = len(prefix)
                pair = curses.color_pair(TTL_CURSES_COLOR[ttl_color])
                stdscr.addnstr(i + 3, col, ttl_cell, w - 1 - col, attr | pair | curses.A_BOLD)
        stdscr.refresh()

        try:
            key = stdscr.getch()
        except curses.error:
            key = -1

        def _dispatch_attach(row):
            # attach is the ONLY action that still drops to the plain
            # terminal -- a real tmux attach hands over the terminal itself
            # (execvp), which no curses popup can do. Every other action
            # stays fully inside curses (see ROW_ACTIONS/_action_status_curses).
            curses.def_prog_mode()
            curses.endwin()
            try:
                _action_attach(row)
            except EOFError:
                pass
            # attach's own "not applicable" print()/input() can print more
            # lines than fit below curses' last-drawn frame, physically
            # scrolling the terminal -- which desyncs curses' internal row
            # bookkeeping from reality. Force a real terminal clear+home
            # first so the resumed curses frame always repaints onto a
            # known-blank screen, however much was printed.
            sys.stdout.write("\033[2J\033[H")
            sys.stdout.flush()
            curses.reset_prog_mode()
            stdscr.touchwin()

        if key in (curses.KEY_UP, ord("k")):
            selected = max(0, selected - 1) if rows else 0
        elif key in (curses.KEY_DOWN, ord("j")):
            selected = min(len(rows) - 1, selected + 1) if rows else 0
        elif key in (ord("q"), 27):
            return
        elif key == curses.KEY_RESIZE:
            continue
        elif key == ord("n"):
            _action_queue_new_curses(stdscr)
            rows = []  # force an immediate re-scan+redraw next loop iteration
        elif key in (10, 13, curses.KEY_ENTER):
            # Enter = the fast path: attach straight into the selected live
            # act. No reply/back menu first -- you can always reply once
            # you're actually in the session.
            if rows:
                _dispatch_attach(rows[selected])
                rows = []
        elif key == ord("a"):
            if rows:
                _dispatch_attach(rows[selected])
                rows = []
        elif key == ord("s"):
            if rows:
                _action_status_curses(stdscr, rows[selected])
                rows = []
        elif rows and key in ROW_ACTIONS:
            ROW_ACTIONS[key][1](stdscr, rows[selected])
            rows = []
        # any other key (including -1 on timeout): just loop and re-render


def cmd_sessions(args):
    """`ap sessions` -- the central control point for the pipeline: every
    live act, every queue ticket awaiting a decision, and each other issue's
    most recent finished outcome, merged with cc-top's live per-session
    cost/model/TTL/idle stats. Arrow keys (or j/k) ONLY move the row
    selection; every action is a direct, always-visible single key (see
    ACTION_HDR) -- never an arrow-picked menu of ACTIONS -- but every
    action's own input/confirmation is a popup on top of the live
    dashboard, never a drop to the plain terminal, with one unavoidable
    exception: [a]ttach (or Enter), which hands over the real terminal via
    tmux attach -- no popup can do that. [i]nfo peeks at a row's transcript
    summary or queue detail without committing to a full attach. [p]ause,
    [g]o/approve and [f]eedback (popup text entry) for a queue ticket.
    [s]tatus is the one pick-one-of-N-known-values action: an arrow-navigable
    popup to choose the new state, then a second popup to confirm -- this is
    also how you mark a stale ledger-only row done/resolved, and setting a
    terminal state (done/failed/ready-to-test) on a row that's still LIVE
    also ends its tmux window in the same motion, so it actually stops
    showing live afterward. [e]dit-note (popup text entry) sets/clears a
    free-text note that wins over the state-derived default text, for any
    row -- preserves the row's real historical state if it didn't have a
    queue file yet. [K]ill force-ends a live act's tmux window on its own,
    for when the underlying work is already done/stale (a window existing
    is the only "live" signal this dashboard has -- it can't tell a
    genuinely-running act from an already-shipped one left open) but you
    want to record its final status separately via [s]. [t]retry a FAILED
    row. [n]ew queues a brand-new ticket (popup text entry) without leaving
    the dashboard. q quits. Live-refreshes every 5s, same cadence as
    `cc-top --watch`'s default."""
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        _print_dashboard(_dashboard_rows())
        return 0
    try:
        curses.wrapper(_curses_main)
    except KeyboardInterrupt:
        pass
    return 0


def cmd_list(args):
    live = {a["session_id"]: a for a in live_acts() if a["session_id"]}
    rows = [r for r in ledger_rows(days=args.days) if r.get("phase") != "poll"] \
        if not args.all else ledger_rows(days=args.days)
    rows = rows[-args.n:]
    print(col("b", f"{'WHEN':6} {'PHASE':10} {'ISSUE':10} {'STATUS':8} "
                   f"{'MODEL':9} {'$':>7} {'MIN':>4} {'REQ':>4} {'SESSION':9}"))
    for r in rows:
        t = transcript(r.get("session_id"))
        s = summarize(t) if t else None
        # Prefer the ledger's own model field; fall back to the transcript for
        # rows written before ap-cycle.sh started recording it.
        model = r.get("model") or main_model(s)
        dur = (s["last"] - s["first"]).total_seconds() / 60 if s and s["first"] and s["last"] else 0
        st = str(r.get("status"))
        cl = "g" if st in ("DONE",) else "r" if st == "FAILED" else "dim"
        when = (r.get("ts") or "")[11:16]
        print(f"{when:6} {r.get('phase','?'):10} {str(r.get('issue') or '-'):10} "
              f"{col(cl, f'{st:8}')} {model:9} {r.get('cost') or 0:7.2f} {dur:4.0f} "
              f"{(s['reqs'] if s else 0):4} {str(r.get('session_id') or '-')[:8]:9}")
    for sid, a in live.items():
        s = summarize(transcript(sid))
        model = main_model(s)
        dur = (datetime.now(timezone.utc) - s["first"]).total_seconds() / 60 if s["first"] else 0
        label = "PARKED" if a.get("parked") else "LIVE"
        clr = "dim" if a.get("parked") else "y"
        print(f"{'now':6} {a['phase']:10} {a['target'][:10]:10} "
              f"{col(clr, label.ljust(8))} {model:9} {'':7} {dur:4.0f} "
              f"{s['reqs']:4} {sid[:8]:9} {col('dim', 'pid ' + str(a['pid']))}")
    if not rows and not live:
        print(col("dim", "  (no acts recorded)"))


def cmd_model(args):
    """The act's own model (main_model(), not counting subagents) for one
    session's transcript, printed bare. Same motivation as cmd_cost: a
    resumed act's ledger row needs this field populated same as every other
    row -- it's how a pipeline silently running the wrong model gets noticed
    (see append_ledger's comment in ap-cycle.sh)."""
    t = transcript(args.session_id)
    print(main_model(summarize(t)) if t else "")
    return 0


def cmd_tail_text(args):
    """The act's own final assistant message, plain text, printed bare. For
    ap-cycle.sh's persistent-mode FAILED reconcile: a persistent act has no
    captured stdout/stderr to build its external-failure-signature classifier
    from (that's -p mode's `--output-format json` blob, which doesn't exist
    here), but the transcript itself often says exactly what happened -- e.g.
    the model's own "cut off by a session usage limit" line. Without this, a
    real usage-limit interruption in persistent mode falls through to a
    plain, misleading `failed` label instead of being re-queued like the
    same failure would be in oneshot mode (this is the bug that mislabeled
    ENG-1308 as `failed` instead of re-queuing it on 2026-08-14)."""
    t = transcript(args.session_id)
    print((summarize(t).get("final") if t else "") or "")
    return 0


def interrupt_act(target):
    """Send Claude Code's own interrupt (Escape) into a live persistent act's
    tmux window. Stops it mid-turn without losing the session/context
    (unlike a NEEDS_HUMAN park, nothing is written to status.json and no
    reply is expected) -- continue_act() later picks the same session back
    up exactly where it left off. Only meaningful for
    AP_ACT_LAUNCH_MODE=persistent acts: a oneshot `claude -p` act has no
    interactive pane to interrupt. Returns (ok, message_lines)."""
    kind, rec = resolve(target)
    if kind != "live" or not rec or not rec.get("window"):
        return False, [f"no live, interactive (persistent-mode) act matches '{target}' -- "
                        "a oneshot act has no session to interrupt"]
    window = rec["window"]
    subprocess.run(["tmux", "send-keys", "-t", f"{AP_TMUX_SESSION}:{window}", "Escape"],
                   check=False)
    return True, [
        f"interrupted {window} (issue {rec.get('target') or '?'}, phase {rec.get('phase')})",
        f"resume: ap resume-act {target} [\"<message>\"]  (or attach: tmux attach -t {AP_TMUX_SESSION})",
        "note: this does NOT release the act's build/ship/plan lane lock -- unlike "
        "a NEEDS_HUMAN park, the ap-cycle.sh process that dispatched it is still "
        "polling for status.json, so its slot stays occupied the whole time it's paused",
    ]


def continue_act(target, message):
    """Inject a message into a live, interrupted (or otherwise idle) act's
    tmux window. Two SEPARATE send-keys calls, not text+Enter in one --
    Claude Code's TUI does not reliably submit otherwise (same fix
    ap-resume.sh's reply injection needed, caught only by live testing; see
    autopilot README). Returns (ok, message_lines)."""
    kind, rec = resolve(target)
    if kind != "live" or not rec or not rec.get("window"):
        return False, [f"no live, interactive (persistent-mode) act matches '{target}'"]
    window = rec["window"]
    text = message or "continue"
    tmux_target = f"{AP_TMUX_SESSION}:{window}"
    subprocess.run(["tmux", "send-keys", "-t", tmux_target, "--", text], check=False)
    time.sleep(1)
    subprocess.run(["tmux", "send-keys", "-t", tmux_target, "Enter"], check=False)
    return True, [f"resumed {window} with: {text}"]


def cmd_interrupt(args):
    ok, lines = interrupt_act(args.target)
    for line in lines:
        print(line, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def cmd_continue(args):
    ok, lines = continue_act(args.target, args.message)
    for line in lines:
        print(line, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


REQUEUE_STATE = {
    "plan": "queued",
    "replan": "queued",
    "implement": "plan-review",
    "ship": "ship-pending",
}


def retry_act(target):
    """Manually re-queue a FAILED act to the state it started from -- the
    same requeue ap-cycle.sh's own external-failure classifier already does
    automatically for a recognized signature (see the ENG-1308 usage-limit
    mislabel this was built alongside). Works for ANY FAILED act, not just
    external-signature ones: a human deciding to retry despite a real error
    is a legitimate call this tool shouldn't second-guess. Returns
    (ok, message_lines)."""
    kind, rec = resolve(target)
    if kind == "live":
        return False, [f"'{target}' is still LIVE, not failed -- nothing to retry "
                        "(see ap pause-act/ap resume-act for a live act)"]
    if kind != "done" or not rec:
        return False, [f"no act matches '{target}'"]
    if rec.get("status") != "FAILED":
        return False, [f"'{target}' is {rec.get('status')}, not FAILED -- nothing to retry"]
    phase = rec.get("phase")
    new_state = REQUEUE_STATE.get(phase)
    if not new_state:
        return False, [f"don't know how to re-queue phase '{phase}'"]
    eng_id = rec.get("issue")
    if not eng_id:
        return False, ["this act's ledger row has no issue id -- cannot re-queue"]
    entry = ap_queue.transition(
        str(AP_HOME), eng_id, "claim", state=new_state,
        event=f"manually re-queued via `ap retry` (was FAILED, phase {phase})")
    if entry is None:
        return False, [f"no queue entry for {eng_id} -- was it ever `ap queue`d?"]
    return True, [f"re-queued {eng_id}: failed -> {new_state}"]


def cmd_retry(args):
    ok, lines = retry_act(args.target)
    for line in lines:
        print(line, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def cmd_queue(args):
    """`ap queue ENG-1400 ["note"] [--auto]` -- new-work intake, the CLI-only
    replacement for opening a GitHub inbox issue titled ENG-<id> and
    labelling it Queued. ap-decide.py's tier5 picks this up next cycle."""
    if not ap_queue.valid_eng_id(args.eng_id):
        print(f"not a valid ENG-<n> id: {args.eng_id!r}", file=sys.stderr)
        return 1
    if ap_queue.read_ticket(str(AP_HOME), args.eng_id) is not None:
        print(f"{args.eng_id} is already queued (see `ap sessions`)", file=sys.stderr)
        return 1
    entry = ap_queue.new_ticket(str(AP_HOME), args.eng_id, args.note or "", args.auto)
    print(f"queued {entry['eng_id']} (seq {entry['seq']}){' [auto-approve]' if args.auto else ''}")
    return 0


def cmd_approve(args):
    """`ap approve ENG-1400 [--auto]` -- approve a plan-review ticket ("go"),
    the CLI-only replacement for commenting go/auto on a GitHub inbox issue.
    --auto also flips the ticket's persistent auto-approve switch, so future
    plans on this same ticket build without a further `ap approve`."""
    entry = ap_queue.approve_ticket(str(AP_HOME), args.eng_id, args.auto)
    if entry is None:
        print(f"no queue entry for {args.eng_id}", file=sys.stderr)
        return 1
    print(f"approved {entry['eng_id']}" + (" (auto)" if args.auto else ""))
    return 0


def cmd_reply(args):
    """`ap reply ENG-1400 "text"` -- plan-revision feedback OR a needs-input
    answer, the CLI-only replacement for commenting on a GitHub inbox issue.
    ap-decide.py's tiers already discriminate purely by the ticket's current
    state (plan-review vs needs-input), so one write serves both."""
    entry = ap_queue.reply_ticket(str(AP_HOME), args.eng_id, args.text)
    if entry is None:
        print(f"no queue entry for {args.eng_id}", file=sys.stderr)
        return 1
    print(f"reply recorded for {entry['eng_id']} (state={entry['state']})")
    return 0


def cmd_cost(args):
    """Estimated USD cost for one session's transcript, printed to stdout as
    a bare number (for a bash caller to capture directly). This exists for
    AP_ACT_LAUNCH_MODE=persistent acts, which have no -p JSON blob to read
    total_cost_usd from -- ap-cycle.sh calls this right after an act ends so
    the ledger's cost column isn't just a silent 0 (see autopilot/README.md).
    """
    t = transcript(args.session_id)
    if not t:
        print("0")
        print(f"cost: no transcript found for session {args.session_id}", file=sys.stderr)
        return 0
    total, skipped = estimate_cost(summarize(t))
    print(f"{total:.6f}")
    if skipped:
        print(f"cost: unpriced model(s) excluded from estimate: {', '.join(skipped)}",
              file=sys.stderr)
    return 0


def cmd_show(args):
    kind, rec = resolve(args.target)
    if not rec:
        print(f"no act matches '{args.target}'", file=sys.stderr)
        return 1
    sid = rec.get("session_id") or ""
    t = transcript(sid)
    s = summarize(t) if t else None
    run_dir = rec.get("run_dir") or (s or {}).get("run_dir", "")

    print(col("b", "── act ──────────────────────────────────────────────────"))
    if kind == "live":
        state_label = ("PARKED (waiting on a reply, pid %s)" if rec.get("parked")
                        else "LIVE (pid %s)") % rec["pid"]
        state_color = "dim" if rec.get("parked") else "y"
        print(f"  state      {col(state_color, state_label)}")
    else:
        print(f"  state      {rec.get('status')}")
    print(f"  phase      {rec.get('phase')}")
    print(f"  issue      {rec.get('issue') or rec.get('target') or '-'}")
    print(f"  session    {sid or '-'}")
    print(f"  run dir    {run_dir or '-'}")
    if rec.get("cost") is not None and kind != "live":
        print(f"  cost       ${rec['cost']:.4f}   {col('dim','(ledger, from claude -p)')}")
    if s:
        model = main_model(s) + col("dim", "  (+subagents: " + ", ".join(
            f"{k.replace('claude-','')}x{v}" for k, v in
            sorted(s["models"].items(), key=lambda x: -x[1])
            if k not in s["main_models"]) + ")" if s["subagents"] else "")
        dur = ((s["last"] or s["first"]) - s["first"]).total_seconds() / 60 if s["first"] else 0
        print(f"  models     {model or '-'}")
        print(f"  duration   {dur:.0f} min   requests {s['reqs']}   subagents {s['subagents']}")
        print(f"  tokens     out {human(s['out'])}  cache-read {human(s['cache_r'])}  "
              f"cache-write {human(s['cache_w'])}")
        if s["api_errors"] or s["tool_errors"]:
            print(col("r", f"  errors     api {s['api_errors']}  tool {s['tool_errors']}"))
        if s["tools"]:
            top = ", ".join(f"{k} {v}" for k, v in
                            sorted(s["tools"].items(), key=lambda x: -x[1])[:8])
            print(f"  tools      {top}")

    if run_dir:
        sj = Path(run_dir) / "status.json"
        print(col("b", "\n── status.json ──────────────────────────────────────────"))
        if sj.exists():
            print("  " + sj.read_text().strip().replace("\n", "\n  "))
        else:
            print(col("r", "  MISSING — this is what makes the wrapper record FAILED"))
        for e in sorted(Path(run_dir).glob("*.stderr")):
            body = e.read_text(errors="replace").strip()
            if body:
                print(col("b", f"\n── {e.name} (tail) ───────────────────────────────"))
                print("  " + "\n  ".join(body.splitlines()[-12:]))

    if args.timeline and t:
        print(col("b", "\n── timeline ─────────────────────────────────────────────"))
        for d in read(t):
            if d.get("type") != "assistant":
                continue
            when = ts(d.get("timestamp"))
            hh = when.strftime("%H:%M") if when else "     "
            for b in (d.get("message") or {}).get("content") or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    print(f"  {col('dim', hh)} {col('c', brief(b))}")
                elif b.get("type") == "text" and b.get("text", "").strip():
                    first = b["text"].strip().splitlines()[0]
                    print(f"  {col('dim', hh)} {first[:110]}")

    if s and s["final"]:
        print(col("b", "\n── final message ────────────────────────────────────────"))
        print("  " + "\n  ".join(s["final"].strip().splitlines()[:20]))
    return 0


def cmd_tail(args):
    kind, rec = resolve(args.target)
    if not rec:
        print(f"no act matches '{args.target}'", file=sys.stderr)
        return 1
    sid = rec.get("session_id") or ""
    t = transcript(sid)
    if not t:
        print(f"no transcript yet for {sid or args.target}", file=sys.stderr)
        return 1
    print(col("b", f"tail {rec.get('phase')} {rec.get('issue') or rec.get('target') or ''} "
                   f"[{sid[:8]}]  {col('dim','ctrl-c to stop')}"), flush=True)
    pos = 0
    if not args.from_start:                       # start near the end
        with t.open(errors="replace") as fh:
            lines = fh.readlines()
            pos = fh.tell()
        for line in lines[-args.lines:]:
            emit(line)
    while True:
        try:
            with t.open(errors="replace") as fh:
                fh.seek(pos)
                for line in fh:
                    emit(line)
                pos = fh.tell()
        except OSError:
            pass
        if kind == "live" and not Path(f"/proc/{rec['pid']}").exists():
            print(col("dim", "— process exited —"))
            return 0
        if kind != "live":
            return 0
        time.sleep(args.interval)


def emit(line):
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        return
    when = ts(d.get("timestamp"))
    hh = when.strftime("%H:%M:%S") if when else "        "
    if d.get("isApiErrorMessage"):
        print(f"  {col('dim', hh)} {col('r', 'API ERROR: ' + str(d.get('message', {}).get('content'))[:160])}")
        return
    if d.get("type") != "assistant":
        return
    for b in (d.get("message") or {}).get("content") or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_use":
            print(f"  {col('dim', hh)} {col('c', brief(b))}")
        elif b.get("type") == "text" and b.get("text", "").strip():
            for ln in b["text"].strip().splitlines()[:6]:
                print(f"  {col('dim', hh)} {ln[:120]}")
    sys.stdout.flush()


def cmd_watch(args):
    """tmux window with one pane per live act, each tailing it."""
    if not shutil.which("tmux"):
        print("tmux not installed", file=sys.stderr)
        return 1
    acts = [a for a in live_acts() if a["session_id"]]
    if not acts:
        print("no live acts to watch (try `ap runs`)", file=sys.stderr)
        return 1
    me = Path(__file__).resolve()
    sess = "ap-watch"
    subprocess.run(["tmux", "kill-session", "-t", sess],
                   capture_output=True, check=False)
    first = acts[0]
    subprocess.run(["tmux", "new-session", "-d", "-s", sess,
                    f"{sys.executable} {me} tail {first['session_id']}; read -r"],
                   check=True)
    for a in acts[1:]:
        subprocess.run(["tmux", "split-window", "-t", sess,
                        f"{sys.executable} {me} tail {a['session_id']}; read -r"],
                       check=True)
    subprocess.run(["tmux", "select-layout", "-t", sess, "even-vertical"], check=False)
    subprocess.run(["tmux", "set-option", "-t", sess, "mouse", "on"],
                   capture_output=True, check=False)
    # Nested attach is an error, and so is attaching with no tty (cron, a pipe,
    # an agent shell) -- in both cases just say where the panes are.
    if os.environ.get("TMUX") or not sys.stdout.isatty():
        print(f"{len(acts)} pane(s) in tmux session '{sess}': "
              + ", ".join(f"{a['phase']} {a['target']}" for a in acts))
        print(f"attach with:  tmux attach -t {sess}")
        return 0
    os.execvp("tmux", ["tmux", "attach", "-t", sess])


def main():
    ap = argparse.ArgumentParser(prog="ap-runs.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="recent acts, live ones last")
    p.add_argument("-n", type=int, default=20)
    p.add_argument("--days", type=int, default=3)
    p.add_argument("--all", action="store_true", help="include poll rows")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show", help="detail for one act")
    p.add_argument("target", nargs="?", default="latest")
    p.add_argument("--timeline", action="store_true", help="every tool call")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("tail", help="follow one act")
    p.add_argument("target", nargs="?", default="latest")
    p.add_argument("--lines", type=int, default=40)
    p.add_argument("--from-start", action="store_true")
    p.add_argument("--interval", type=float, default=1.0)
    p.set_defaults(fn=cmd_tail)

    p = sub.add_parser("watch", help="tmux pane per live act")
    p.set_defaults(fn=cmd_watch)

    p = sub.add_parser("cost", help="estimated USD cost for one session's transcript")
    p.add_argument("session_id")
    p.set_defaults(fn=cmd_cost)

    p = sub.add_parser("model", help="the act's own model for one session's transcript")
    p.add_argument("session_id")
    p.set_defaults(fn=cmd_model)

    p = sub.add_parser("tail-text", help="the act's own final assistant message, plain text")
    p.add_argument("session_id")
    p.set_defaults(fn=cmd_tail_text)

    p = sub.add_parser("interrupt", help="pause a live persistent act mid-turn (resumable)")
    p.add_argument("target", nargs="?", default="latest")
    p.set_defaults(fn=cmd_interrupt)

    p = sub.add_parser("continue", help="resume an interrupted/idle live act")
    p.add_argument("target", nargs="?", default="latest")
    p.add_argument("message", nargs="?", default="continue")
    p.set_defaults(fn=cmd_continue)

    p = sub.add_parser("retry", help="re-queue a FAILED act to its pre-phase state")
    p.add_argument("target", nargs="?", default="latest")
    p.set_defaults(fn=cmd_retry)

    p = sub.add_parser("queue", help="new-work intake: queue an ENG-<id> for the pipeline")
    p.add_argument("eng_id")
    p.add_argument("note", nargs="?", default="")
    p.add_argument("--auto", action="store_true", help="also set this ticket's auto-approve switch")
    p.set_defaults(fn=cmd_queue)

    p = sub.add_parser("approve", help="approve a plan-review ticket (\"go\")")
    p.add_argument("eng_id")
    p.add_argument("--auto", action="store_true", help="also set this ticket's auto-approve switch")
    p.set_defaults(fn=cmd_approve)

    p = sub.add_parser("reply", help="plan feedback or a needs-input answer")
    p.add_argument("eng_id")
    p.add_argument("text")
    p.set_defaults(fn=cmd_reply)

    p = sub.add_parser("sessions", help="interactive dashboard: list, inspect, act")
    p.set_defaults(fn=cmd_sessions)

    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
