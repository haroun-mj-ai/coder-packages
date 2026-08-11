"""Render a dumped run set (from dump_runs.py) for analysis: lifecycle, the
ordered tool-call flow per agent session (calls + results), the per-workspace
memory landscape (overwrite-in-place vs duplicate vs cross-account), and any
action items.

    python inspect_runs.py [path-to-all.json]   # default: ./all.json
"""

import json
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "all.json"
d = json.load(open(PATH))
runs = d["runs"]
ws_name = {w["_id"]: w.get("name") for w in d.get("workspaces", [])}
ws_link = {w["_id"]: w.get("linked_crm_entity_id") for w in d.get("workspaces", [])}
run_ids = {r["_id"] for r in runs}
acct = d.get("acct_names", {})

sess_by_run = {}
for s in d["sessions"]:
    sess_by_run.setdefault(s["run"], []).append(s)

print("COUNTS:", json.dumps(d.get("_counts", {})))
for r in runs:
    rid, ws = r["_id"], r.get("workspace_id")
    print(f"\n{'#' * 72}\nRUN {rid[:12]} · {ws_name.get(ws)} ({str(ws)[:8]}) · linked_acct={str(ws_link.get(ws))[:12]}")
    print(f"  status={r.get('status')} cost=${r.get('total_cost_estimate_usd')} "
          f"recovery={r.get('recovery_attempts')} started={str(r.get('started_at'))[:19]} "
          f"completed={str(r.get('completed_at'))[:19]}")
    print(f"  dedupe_key={r.get('dedupe_key')}")
    p = r.get("trigger_event_payload") or {}
    print(f"  trigger={r.get('trigger_event_type')} payload={json.dumps(p, default=str)[:260]}")
    for sr in (r.get("step_runs") or []):
        if isinstance(sr, dict):
            print(f"  step: {sr.get('name')} [{sr.get('status')}] "
                  f"writes={sr.get('writes') if 'writes' in sr else ''}")
    err = r.get("error") or r.get("error_summary")
    if err:
        print(f"  ERROR: {str(err)[:300]}")
    for s in sess_by_run.get(rid, []):
        print(f"  -- session {s['_id'][:8]} : {s.get('title')}")
        for msg in d["session_messages"].get(s["_id"], []):
            for it in msg["items"]:
                if it.get("name"):
                    print(f"       TOOL {it['name']}({it.get('args', '')[:190]})")
                    if it.get("result"):
                        print(f"            -> {it['result'][:230]}")
                elif it.get("text"):
                    print(f"       TEXT {it['text'][:180]}")
                elif it.get("result"):
                    print(f"       RESULT {it['result'][:230]}")

print(f"\n{'=' * 72}\nMEMORY LANDSCAPE (per workspace)")
for ws, arts in d["artifacts_by_ws"].items():
    print(f"\n{ws_name.get(ws)} ({ws[:8]}) — {len(arts)} memory artifacts")
    by_type = {}
    for a in arts:
        by_type.setdefault(a["memory_type"], []).append(a)
    for mt, lst in sorted(by_type.items()):
        for a in lst:
            tag = " <<THIS-WAVE" if a.get("src_run") in run_ids else ""
            print(f"  [{mt}] id={a['_id'][:8]} pin={a['is_pinned']} src={str(a.get('src_run'))[:8]}{tag} "
                  f"created={a['created_at'][:19]} updated={a['updated_at'][:19]}")
            print(f"      title: {str(a.get('title'))[:80]}")

if d.get("action_items"):
    print(f"\n{'=' * 72}\nACTION ITEMS stamped with these runs ({len(d['action_items'])})")
    for a in d["action_items"]:
        print(f"  {a.get('kind')} [{a.get('status')}] run={str(a.get('src_run'))[:8]} ws={str(a.get('ws'))[:8]} "
              f"parent={str(a.get('parent'))[:8]}")
        print(f"      title: {a.get('title')}")
        if a.get("agent_brief"):
            print(f"      brief: {a.get('agent_brief')[:160]}")
