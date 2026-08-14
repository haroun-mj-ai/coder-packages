#!/usr/bin/env python3
"""Inspect individual autopilot acts. Backend for `ap runs|run|tail`.

An act is a headless `claude -p` session, so there is no pane to attach to.
What there is:

  * the ledger row      ~/.autopilot/runs/<date>.jsonl   (phase, status, cost)
  * the run dir         ~/.autopilot/runs/<ts>-<pid>/    (status.json, *.stderr)
  * the transcript      ~/.claude/projects/**/<session-id>.jsonl
  * the live process    `claude -p ... --run-dir <run-dir>` in the process table

This joins them. A live act is found by the --run-dir in its argv, mapped to a
session id through ~/.claude/sessions/<pid>.json; a finished act comes from the
ledger, and its run dir is recovered from the --run-dir in its own prompt.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

AP_HOME = Path(os.environ.get("AP_HOME", Path.home() / ".autopilot"))
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


def cmd_interrupt(args):
    """`ap pause-act <target>` -- send Claude Code's own interrupt (Escape)
    into a live persistent act's tmux window. Stops it mid-turn without
    losing the session/context (unlike a NEEDS_HUMAN park, nothing is
    written to status.json and no reply is expected) -- `ap resume-act`
    later picks the same session back up exactly where it left off.
    Only meaningful for AP_ACT_LAUNCH_MODE=persistent acts: a oneshot
    `claude -p` act has no interactive pane to interrupt."""
    kind, rec = resolve(args.target)
    if kind != "live" or not rec or not rec.get("window"):
        print(f"no live, interactive (persistent-mode) act matches '{args.target}' -- "
              "a oneshot act has no session to interrupt", file=sys.stderr)
        return 1
    window = rec["window"]
    subprocess.run(["tmux", "send-keys", "-t", f"{AP_TMUX_SESSION}:{window}", "Escape"],
                   check=False)
    print(f"interrupted {window} (issue {rec.get('target') or '?'}, phase {rec.get('phase')})")
    print(f"resume: ap resume-act {args.target} [\"<message>\"]  "
          f"(or attach: tmux attach -t {AP_TMUX_SESSION})")
    print("note: this does NOT release the act's build/ship/plan lane lock -- unlike "
          "a NEEDS_HUMAN park, the ap-cycle.sh process that dispatched it is still "
          "polling for status.json, so its slot stays occupied the whole time it's paused")
    return 0


def cmd_continue(args):
    """`ap resume-act <target> [message]` -- inject a message into a live,
    interrupted (or otherwise idle) act's tmux window. Two SEPARATE
    send-keys calls, not text+Enter in one -- Claude Code's TUI does not
    reliably submit otherwise (same fix ap-resume.sh's reply injection
    needed, caught only by live testing; see autopilot README)."""
    kind, rec = resolve(args.target)
    if kind != "live" or not rec or not rec.get("window"):
        print(f"no live, interactive (persistent-mode) act matches '{args.target}'",
              file=sys.stderr)
        return 1
    window = rec["window"]
    text = args.message or "continue"
    target = f"{AP_TMUX_SESSION}:{window}"
    subprocess.run(["tmux", "send-keys", "-t", target, "--", text], check=False)
    time.sleep(1)
    subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=False)
    print(f"resumed {window} with: {text}")
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

    p = sub.add_parser("interrupt", help="pause a live persistent act mid-turn (resumable)")
    p.add_argument("target", nargs="?", default="latest")
    p.set_defaults(fn=cmd_interrupt)

    p = sub.add_parser("continue", help="resume an interrupted/idle live act")
    p.add_argument("target", nargs="?", default="latest")
    p.add_argument("message", nargs="?", default="continue")
    p.set_defaults(fn=cmd_continue)

    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
