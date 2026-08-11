"""Dump orchestration runs (+ steps, sessions, tool calls, memories, action
items, workspace/CRM context) for deep-dive analysis. Prints JSON after a
marker so it can be run in-container via `railway ssh` and captured locally.

Configure the SELECTION block, then run inside the backend container:

    PYTHONPATH=/app python dump_runs.py            # uses settings.MONGODB_URL/_DB_NAME

Two selection modes:
  * RUN_IDS non-empty  -> dump exactly those runs.
  * else SPEC_ID + LIMIT -> the newest LIMIT runs of that spec in ORG_ID.
"""

import json

from pymongo import MongoClient

from app.core.config import settings

# ---------------- SELECTION (edit per analysis) ----------------
ORG_ID = "52b5b8ea2a4a4fe5a1f9ae0d09b06ae6"  # Skaled MVP
SPEC_ID = "a2_account_refresh"
LIMIT = 3  # newest N runs of SPEC_ID (when RUN_IDS empty)
RUN_IDS: list[str] = []  # explicit run ids; takes precedence over SPEC_ID/LIMIT
# Memory artifact types worth pulling for the workspace memory landscape.
MEM_TYPES = [
    "company_profile", "company_deep_research", "account_plan", "stakeholder_map",
    "deal_summary", "deal_analysis", "call_summary", "rep_summary", "signal_brief",
]
# ---------------------------------------------------------------

c = MongoClient(str(settings.MONGODB_URL), serverSelectionTimeoutMS=20000)
d = c[settings.MONGODB_DB_NAME]


def trunc(v, n=700):
    if isinstance(v, str) and len(v) > n:
        return v[:n] + f"...[+{len(v) - n}]"
    return v


# 1) Resolve the run set.
if RUN_IDS:
    runs = list(d.OrchestrationRun.find({"_id": {"$in": RUN_IDS}}))
else:
    runs = list(
        d.OrchestrationRun.find({"organization_id": ORG_ID, "orchestration_id": SPEC_ID})
        .sort("created_at", -1)
        .limit(LIMIT)
    )
runs.sort(key=lambda r: str(r.get("created_at")))  # oldest-first for stable display
run_ids = [r["_id"] for r in runs]
ws_ids = sorted({r.get("workspace_id") for r in runs if r.get("workspace_id")})

# Embedded step_runs are kept as-is on the run doc; also try the separate
# collection (older specs) and attach under a distinct key so we never clobber.
sep_steps = list(
    d.OrchestrationStepRun.find(
        {"$or": [{"orchestration_run_id": {"$in": run_ids}}, {"run_id": {"$in": run_ids}}]}
    )
) if run_ids else []
by_run_sep = {}
for s in sep_steps:
    by_run_sep.setdefault(s.get("orchestration_run_id") or s.get("run_id"), []).append(s)
for r in runs:
    r["_step_runs_collection"] = by_run_sep.get(r["_id"], [])

out = {"_meta": {"db": settings.MONGODB_DB_NAME, "org": ORG_ID, "spec": SPEC_ID,
                 "run_ids": run_ids}, "runs": runs}

# 2) Sessions for these runs.
sessions = list(d.Session.find({"metadata.orchestration_run_id": {"$in": run_ids}})) if run_ids else []
sess_ids = [s["_id"] for s in sessions]
out["sessions"] = [
    {"_id": s["_id"], "title": s.get("title"),
     "run": (s.get("metadata") or {}).get("orchestration_run_id"),
     "metadata": s.get("metadata")}
    for s in sessions
]

# 3) Messages -> ordered output items (tool calls + results + text), truncated.
msgs = list(d.Message.find({"session_id": {"$in": sess_ids}})) if sess_ids else []
sess_msgs = {}
for m in msgs:
    items = []
    o = m.get("output")
    for it in (o if isinstance(o, list) else [o]):
        if not isinstance(it, dict):
            continue
        rec = {}
        for key in ("type", "name", "role"):
            if it.get(key):
                rec[key] = it[key]
        for key in ("arguments", "args", "input"):
            if it.get(key) is not None:
                rec["args"] = trunc(str(it[key]), 500)
                break
        if it.get("text"):
            rec["text"] = trunc(it["text"], 500)
        if it.get("output") is not None:
            rec["result"] = trunc(str(it["output"]), 900)
        if rec:
            items.append(rec)
    if m.get("role") in ("tool", "function") and m.get("content"):
        items.append({"role": m.get("role"), "result": trunc(str(m.get("content")), 900)})
    sess_msgs.setdefault(m.get("session_id"), []).append(
        {"created_at": str(m.get("created_at")), "role": m.get("role"), "items": items}
    )
for sid in sess_msgs:
    sess_msgs[sid].sort(key=lambda x: x["created_at"])
out["session_messages"] = sess_msgs

# 4) Memory/artifact landscape in the runs' workspaces (full history).
arts = list(d.Artifact.find({"workspace_id": {"$in": ws_ids}})) if ws_ids else []
out["artifacts_by_ws"] = {}
for a in arts:
    mt = a.get("memory_type") or a.get("type") or a.get("artifact_type")
    if mt not in MEM_TYPES and not a.get("is_pinned"):
        continue
    out["artifacts_by_ws"].setdefault(a.get("workspace_id"), []).append({
        "_id": a["_id"], "memory_type": mt, "is_pinned": a.get("is_pinned"),
        "src_run": a.get("source_orchestration_run_id"),
        "src_agent": a.get("source_agent_name"),
        "intent_key": a.get("orchestration_intent_key"),
        "dedupe_tag": a.get("dedupe_tag"), "tags": a.get("tags"),
        "title": a.get("title"), "created_at": str(a.get("created_at")),
        "updated_at": str(a.get("updated_at")), "body": trunc(a.get("body") or a.get("content"), 700),
    })
for w in out["artifacts_by_ws"]:
    out["artifacts_by_ws"][w].sort(key=lambda x: (x["memory_type"] or "", x["created_at"]))

# 5) Action items stamped with these runs.
ais = list(d.ActionItem.find({"source_orchestration_run_id": {"$in": run_ids}})) if run_ids else []
ai_ids = [a["_id"] for a in ais]
out["action_items"] = [
    {"_id": a["_id"], "kind": a.get("kind"), "status": a.get("status"), "title": a.get("title"),
     "ws": a.get("workspace_id"), "src_run": a.get("source_orchestration_run_id"),
     "parent": a.get("parent_action_item_id"), "agent_brief": trunc(a.get("agent_brief"), 300),
     "related_opportunity_id": a.get("related_opportunity_id")}
    for a in ais
]
out["action_item_artifacts"] = [
    {"_id": x["_id"], "action_item_id": x.get("action_item_id"), "kind": x.get("kind"),
     "src_run": x.get("source_orchestration_run_id")}
    for x in (d.ActionItemArtifact.find({"action_item_id": {"$in": ai_ids}}) if ai_ids else [])
]

# 6) Workspace + CRM context.
out["workspaces"] = [
    {k: w.get(k) for k in ["_id", "name", "workspace_type", "linked_crm_entity_id",
                           "linked_crm_entity_type", "is_deleted", "is_archived"] if k in w}
    for w in d.Workspace.find({"_id": {"$in": ws_ids}})
]
out["acct_names"] = {a["_id"]: a.get("name") for a in d.CRMAccount.find({"organization_id": ORG_ID}, {"name": 1})}

out["_counts"] = {"runs": len(runs), "sessions": len(sessions), "messages": len(msgs),
                  "artifacts_kept": sum(len(v) for v in out["artifacts_by_ws"].values()),
                  "action_items": len(ais)}

print("###JSON###")
print(json.dumps(out, default=str))
