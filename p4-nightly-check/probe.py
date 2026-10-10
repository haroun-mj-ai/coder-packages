"""Read-only prod probe: what did last night's action-item cleanup do?

Runs INSIDE the prod backend container (piped to `poetry run python -` over
`railway ssh` by run.sh). It never writes. It prints one `OUT_JSON {...}`
line holding counts and opaque id prefixes only: no titles, descriptions,
payload text, model-written reasons, names or emails.

Window: the 24h ending at 08:30 America/New_York on CHECK_DATE, which covers
the 03:04 ET B1 pass, the 05:47 ET catch-up and the 09:19/09:29 UTC sweeps.

Degrades rather than fails: a collection or helper missing on the deployed
build (ActionItemCleanupDecision before ENG-2529 ships) is reported as absent.
"""

import asyncio
import datetime as dt
import json
import os
import sys
from collections import Counter, defaultdict
from zoneinfo import ZoneInfo

sys.path.insert(0, "/app")

CHECK_DATE = "__CHECK_DATE__"  # substituted by run.sh
ET = ZoneInfo("America/New_York")
LIVE = ["open", "in_progress", "snoozed", "held"]
CLOSING_VERDICTS = {"dismiss", "auto_close", "supersede", "complete"}


def pid(x) -> str:
    return str(x or "")[:8]


def at_et(day: dt.date, hour: int, minute: int) -> dt.datetime:
    """Naive UTC, matching how Mongo hands datetimes back."""
    local = dt.datetime(day.year, day.month, day.day, hour, minute, tzinfo=ET)
    return local.astimezone(dt.timezone.utc).replace(tzinfo=None)


def as_naive_utc(value):
    """`hygiene_decision.at` is sometimes an ISO string, sometimes a datetime."""
    if isinstance(value, str):
        try:
            value = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    if isinstance(value, dt.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(dt.timezone.utc).replace(tzinfo=None)
        return value
    return None


def key(d: dict) -> str:
    return "|".join(f"{k}={d[k]}" for k in sorted(d))


async def main():
    assert os.environ.get("RAILWAY_ENVIRONMENT_NAME") == "production", "not production"
    from pymongo import ReadPreference

    from app.core.config import settings
    from app.core.probe_boot import probe_boot

    day = dt.date.fromisoformat(CHECK_DATE)
    end = at_et(day, 8, 30)
    start = at_et(day - dt.timedelta(days=1), 8, 30)
    out: dict = {
        "check_date": CHECK_DATE,
        "window_utc": [start.isoformat(), end.isoformat()],
        "notes": [],
    }

    async with probe_boot("p4_nightly_check") as client:
        db = client.get_database(
            settings.MONGODB_DB_NAME, read_preference=ReadPreference.SECONDARY_PREFERRED
        )
        names = set(await db.list_collection_names())
        win = {"$gte": start, "$lt": end}

        # 1. B1 runs per rep.
        runs = await db["OrchestrationRun"].aggregate([
            {"$match": {"orchestration_id": "b1_action_item_manager", "created_at": win}},
            {"$group": {"_id": {"org": "$organization_id", "rep": "$user_id", "status": "$status"},
                        "n": {"$sum": 1}}},
        ]).to_list(None)
        out["b1_runs"] = [
            {"org": pid(r["_id"].get("org")), "rep": pid(r["_id"].get("rep")),
             "status": r["_id"].get("status"), "n": r["n"]}
            for r in runs
        ]

        # 2. Rule batches: per rep, per source/mode/action/rule/outcome.
        batch_rows = Counter()
        batch_meta = {}
        async for b in db["ActionItemCleanupRuleBatch"].find(
            {"created_at": win},
            {"user_id": 1, "source": 1, "mode": 1, "applied": 1, "apply_rules": 1,
             "entries.organization_id": 1, "entries.action": 1, "entries.rule": 1,
             "entries.outcome": 1, "entries.is_cascade": 1},
        ):
            entries = b.get("entries") or []
            org = pid(entries[0].get("organization_id")) if entries else "?"
            meta_key = (org, pid(b.get("user_id")), b.get("source"))
            batch_meta[meta_key] = {
                "mode": b.get("mode"), "applied": b.get("applied"),
                "apply_rules": sorted(b.get("apply_rules") or []),
            }
            for e in entries:
                batch_rows[key({
                    "org": pid(e.get("organization_id")), "rep": pid(b.get("user_id")),
                    "source": b.get("source"), "action": e.get("action"),
                    "rule": e.get("rule"), "outcome": e.get("outcome"),
                    "cascade": bool(e.get("is_cascade")),
                })] += 1
        out["rule_batch_entries"] = dict(batch_rows)
        out["rule_batch_meta"] = [
            {"org": k[0], "rep": k[1], "source": k[2], **v} for k, v in batch_meta.items()
        ]

        # 3. Decision history (ENG-2529), once deployed.
        if "ActionItemCleanupDecision" in names:
            dec = await db["ActionItemCleanupDecision"].aggregate([
                {"$match": {"created_at": win}},
                {"$group": {"_id": {
                    "org": "$organization_id", "rep": "$user_id", "by": "$decided_by",
                    "action": "$action", "verdict": "$verdict", "rule": "$rule",
                    "reason_code": "$reason_code", "generated": "$reason_generated",
                    "source": "$source"}, "n": {"$sum": 1}}},
            ]).to_list(None)
            out["decision_history"] = [
                {**{k: (pid(v) if k in ("org", "rep") else v) for k, v in r["_id"].items()},
                 "n": r["n"]}
                for r in dec
            ]
        else:
            out["decision_history"] = None
            out["notes"].append("ActionItemCleanupDecision absent: ENG-2529 not deployed to prod yet")

        # 4. Every card that went terminal in the window, attributed.
        from app.services.action_items.prospecting_cleanup_rules import (
            is_cleanup_rule_reason,
        )

        closes = Counter()
        cleanup_closed = []  # top-level rule/model closes, for the protection check
        async for doc in db["ActionItem"].find(
            {"status_changed_at": win, "status": {"$nin": LIVE}},
            {"organization_id": 1, "user_id": 1, "status": 1, "kind": 1,
             "parent_action_item_id": 1, "status_changed_at": 1,
             "status_changed_by.authority": 1, "status_changed_by.user_id": 1,
             "auto_close_reason": 1,
             "hygiene_decision.rule_close.at": 1, "hygiene_decision.rule_close.rule": 1,
             "hygiene_decision.verdict": 1, "hygiene_decision.at": 1,
             "hygiene_decision.reason_code": 1, "related_account_id": 1,
             "related_opportunity_id": 1, "payload.related_crm_opportunity_id": 1,
             "payload.crm_object_type": 1, "payload.crm_record_id": 1, "created_at": 1},
        ):
            hd = doc.get("hygiene_decision") or {}
            rc = hd.get("rule_close") or {}
            rc_at, hd_at = as_naive_utc(rc.get("at")), as_naive_utc(hd.get("at"))
            if rc_at and start <= rc_at < end:
                actor, detail = "rule", rc.get("rule")
            elif hd.get("verdict") in CLOSING_VERDICTS and hd_at and start <= hd_at < end:
                actor, detail = "model", hd.get("verdict")
            elif (doc.get("status_changed_by") or {}).get("authority"):
                by = doc["status_changed_by"]
                # Staff accounts act across orgs; name WHO (id prefix) as well as the role.
                actor, detail = "human", f'{by["authority"]}:{pid(by.get("user_id"))}'
                if by.get("user_id") == doc.get("user_id"):
                    detail = f'{by["authority"]}:self'

            elif is_cleanup_rule_reason(doc.get("auto_close_reason")):
                actor, detail = "rule_unstamped", None
            else:
                actor, detail = "system", None  # sweeps, cascades, agent tools
            is_child = bool(doc.get("parent_action_item_id"))
            changed = as_naive_utc(doc.get("status_changed_at"))
            closes[key({
                # 02:00-09:00 ET: the nightly passes, not daytime rep/agent activity.
                "overnight": bool(changed and at_et(day, 2, 0) <= changed < at_et(day, 9, 0)),
                "org": pid(doc.get("organization_id")), "rep": pid(doc.get("user_id")),
                "status": doc.get("status"), "kind": doc.get("kind"), "actor": actor,
                "detail": detail, "child": is_child,
            })] += 1
            if actor in ("rule", "model") and not is_child:
                cleanup_closed.append(doc)
        out["closes"] = dict(closes)

        # 5. Did a cleanup close hit an open deal or an upcoming external meeting?
        flags, unknown = [], 0
        try:
            from app.services.action_items.opportunity_liveness import (
                OPPORTUNITY_OPEN,
                opportunity_states,
            )
            from app.services.action_items.prospecting_cleanup_rules import (
                _opportunity_links,
                upcoming_meeting_account_ids,
            )

            by_org = defaultdict(list)
            for doc in cleanup_closed:
                by_org[doc["organization_id"]].append(doc)
            for org_id, docs in by_org.items():
                links = sorted({l for d in docs for l in _opportunity_links(d)})
                live = await opportunity_states(org_id, None, links) if links else None
                if live is not None and live.lookup_failed:
                    unknown += len(docs)
                    continue
                accounts = {str(d["related_account_id"]) for d in docs if d.get("related_account_id")}
                try:
                    met = await upcoming_meeting_account_ids(
                        organization_id=org_id, account_ids=accounts, now=end
                    )
                except Exception:  # noqa: BLE001
                    met, unknown = set(), unknown + len(docs)
                for d in docs:
                    open_deal = live is not None and any(
                        live.states.get(l) == OPPORTUNITY_OPEN for l in _opportunity_links(d)
                    )
                    meeting = str(d.get("related_account_id") or "") in met
                    if open_deal or meeting:
                        hd = d.get("hygiene_decision") or {}
                        flags.append({
                            "item": pid(d["_id"]), "org": pid(org_id), "rep": pid(d.get("user_id")),
                            "kind": d.get("kind"), "open_deal": open_deal, "meeting_14d": meeting,
                            "by": "rule" if (hd.get("rule_close") or {}).get("at") else "model",
                            "rule_or_verdict": (hd.get("rule_close") or {}).get("rule") or hd.get("verdict"),
                            "reason_code": hd.get("reason_code"),
                        })
        except ImportError as exc:
            out["notes"].append(f"protection helpers unavailable on this build: {exc.name}")
            unknown = len(cleanup_closed)
        out["protected_closes"] = flags
        out["protection_unknown"] = unknown
        out["notes"].append("meeting check is as of 08:30 ET, not the moment of each close")

        # 6. Deterministic sweeps and cascades.
        sweeps = []
        async for b in db["ActionItemExpiryBatch"].find(
            {"created_at": win},
            {"mode": 1, "run_marker": 1, "scanned": 1, "condemned": 1, "protected": 1, "closed": 1},
        ):
            sweeps.append({k: b.get(k) for k in ("mode", "run_marker", "scanned", "condemned", "protected", "closed")})
        out["expiry_sweeps"] = sweeps
        casc = await db["ActionItemCascadeBatch"].aggregate([
            {"$match": {"created_at": win}},
            {"$unwind": "$entries"},
            {"$group": {"_id": {"trigger": "$trigger", "why": "$entries.cascade_reason"}, "n": {"$sum": 1}}},
        ]).to_list(None)
        out["cascades"] = [{**r["_id"], "n": r["n"]} for r in casc]

        # 7. What each served rep still has live (context for "did it move anything").
        # Every (org, rep) the night touched: a run is filed under the rep's
        # serving org, but a staff rep's own cards can live in another org.
        reps = {(r["_id"].get("org"), r["_id"].get("rep")) for r in runs}
        async for b in db["ActionItemCleanupRuleBatch"].find(
            {"created_at": win}, {"user_id": 1, "entries.organization_id": 1}
        ):
            for e in b.get("entries") or []:
                reps.add((e.get("organization_id"), b.get("user_id")))
        reps = sorted(reps)
        backlog = []
        for org_id, rep_id in reps:
            n = await db["ActionItem"].count_documents({
                "organization_id": org_id, "user_id": rep_id, "status": {"$in": LIVE},
                "parent_action_item_id": {"$in": [None, ""]},
            })
            backlog.append({"org": pid(org_id), "rep": pid(rep_id), "live_top_level": n})
        out["live_backlog"] = backlog

    print("OUT_JSON " + json.dumps(out, default=str))


asyncio.run(main())
