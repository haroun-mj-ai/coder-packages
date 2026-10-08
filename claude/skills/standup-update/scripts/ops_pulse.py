"""ops_pulse: read-only production numbers for Ryan's operations questions.

Runs INSIDE the prod backend container (stdin-piped, nothing written there):

  cat ops_pulse.py | railway ssh --environment production --service journeyai-backend \
      -- poetry run python - --days 1

Answers, for the window (default: last 1 day) and a 7-day activity view:
  1. what's spending money: by funding source, org, rep, agent, model
  2. who's using it: active reps last 7d vs the 7d before, and who dropped off
  3. who's running out of money: platform seats near their monthly cap
  4. what they're using: agent runs by agent and outcome
  5. meeting follow-ups: external transcripts vs debriefs captured, with misses
  6. nightly cleanup: what it closed and kept, and live queue size per rep
  7. failures: failed runs and provider errors (e.g. search provider out of credit)

Strictly read-only: only find/aggregate/count. Output is aggregates plus a few
examples (names, call subjects); no transcript bodies, no secrets.
"""

import argparse
import datetime as dt
import os
import statistics
import sys
from collections import defaultdict

sys.path.insert(0, "/app")

from pymongo import MongoClient  # noqa: E402

from app.core.config import settings  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("--days", type=float, default=1.0, help="window length in days, ending now")
p.add_argument("--top", type=int, default=8)
p.add_argument("--allow-staging", action="store_true")
args = p.parse_args()

env = os.environ.get("RAILWAY_ENVIRONMENT_NAME", "?")
if env != "production" and not args.allow_staging:
    sys.exit(f"refusing: RAILWAY_ENVIRONMENT_NAME={env!r}, expected 'production'")

db = MongoClient(settings.MONGODB_URL, serverSelectionTimeoutMS=15000)[settings.MONGODB_DB_NAME]
T = 60000  # maxTimeMS per query

now = dt.datetime.now(dt.timezone.utc)
since = now - dt.timedelta(days=args.days)
wk = now - dt.timedelta(days=7)
wk2 = now - dt.timedelta(days=14)


def agg(coll, pipeline):
    return list(db[coll].aggregate(pipeline, maxTimeMS=T, allowDiskUse=True))


orgs = {o["_id"]: o.get("name") or "?" for o in db.Organization.find({}, {"name": 1})}
SEED = {k for k, v in orgs.items() if v.startswith("[SEED]") or "test" in v.lower()}
users = {}
STAFF = set()  # Journey staff + service accounts: not reps, kept out of activity
for u in db.User.find({}, {"email": 1, "profile.first_name": 1, "profile.last_name": 1}):
    if (u.get("email") or "").lower().endswith("@meetjourney.ai"):
        STAFF.add(u["_id"])
    pr = u.get("profile") or {}
    nm = " ".join(x for x in (pr.get("first_name"), pr.get("last_name")) if x)
    users[u["_id"]] = nm or u.get("email") or str(u["_id"])
    if nm.lower() == "service account":
        STAFF.add(u["_id"])


def on(i):
    return orgs.get(i, f"org:{i}")


def un(i):
    return users.get(i, f"user:{i}")


def h(t):
    print(f"\n## {t}")


def money(x):
    return f"${x:,.2f}"


print(f"# ops pulse ({env}) window {since:%a %d %b %H:%M} -> {now:%a %d %b %H:%M} UTC ({args.days:g}d)")
print(f"(orgs named [SEED]/test excluded: {len(SEED)})")

# ---------------------------------------------------------------- 1. spend
h("1. Spend in window (APIUsage, billed rows only)")
spend_match = {
    "created_at": {"$gte": since},
    "cost_usd": {"$ne": None},
    "test_run": {"$ne": True},
    "record_kind": {"$ne": "request_telemetry"},
    "organization_id": {"$nin": list(SEED)},
}
for r in agg("APIUsage", [{"$match": spend_match},
                          {"$group": {"_id": {"$ifNull": ["$funding_source", "platform"]},
                                      "c": {"$sum": "$cost_usd"}, "n": {"$sum": 1}}}]):
    print(f"- {r['_id']}: {money(r['c'])} ({r['n']} calls)")


def top(key, label, fmt):
    rows = agg("APIUsage", [{"$match": spend_match},
                            {"$group": {"_id": key, "c": {"$sum": "$cost_usd"},
                                        "byok": {"$sum": {"$cond": [{"$eq": ["$funding_source", "byok"]}, "$cost_usd", 0]}}}},
                            {"$sort": {"c": -1}}, {"$limit": args.top}])
    print(f"top {label}:")
    for r in rows:
        if r["c"] >= 0.01:
            print(f"  - {fmt(r['_id'])}: {money(r['c'])} (byok {money(r['byok'])})")


top("$organization_id", "orgs", on)
top({"u": "$user_id", "o": "$organization_id"}, "reps", lambda k: f"{un(k.get('u'))} @ {on(k.get('o'))}")
top({"$ifNull": ["$agent_base_name", "$endpoint"]}, "agents (agent_base_name, else endpoint)", str)
top({"p": "$api_provider", "m": "$model_name"}, "models", lambda k: f"{k.get('p')}/{k.get('m')}")

# ---------------------------------------------------------------- 2. activity
h("2. Who's using it (user sessions + request telemetry; a lower bound; Journey staff excluded)")


def active(lo, hi):
    s = defaultdict(set)
    for r in agg("Session", [{"$match": {"origin": "user", "created_at": {"$gte": lo, "$lt": hi}}},
                             {"$group": {"_id": {"u": "$user_id", "o": "$organization_id"}}}]):
        s[r["_id"].get("o")].add(r["_id"].get("u"))
    for r in agg("APIUsage", [{"$match": {"record_kind": "request_telemetry", "created_at": {"$gte": lo, "$lt": hi},
                                          "user_id": {"$ne": None}}},
                              {"$group": {"_id": {"u": "$user_id", "o": "$organization_id"}}}]):
        s[r["_id"].get("o")].add(r["_id"].get("u"))
    return s


a_now, a_prev = active(wk, now), active(wk2, wk)
for o in sorted(set(a_now) | set(a_prev), key=lambda o: -len(a_now.get(o, ()))):
    # unknown ids are URL fragments some telemetry rows store as an org id
    if o in SEED or o not in orgs:
        continue
    cur, prev = a_now.get(o, set()) - STAFF, a_prev.get(o, set()) - STAFF
    if not cur and not prev:
        continue
    gone = sorted(un(u) for u in prev - cur)
    new = sorted(un(u) for u in cur - prev)
    line = f"- {on(o)}: {len(cur)} active last 7d (was {len(prev)})"
    if gone:
        line += f"; dropped off: {', '.join(gone[:6])}{' …' if len(gone) > 6 else ''}"
    if new:
        line += f"; new/back: {', '.join(new[:6])}"
    print(line)

# ---------------------------------------------------------------- 3. caps
h("3. Who's running out of money (platform seats >= 70% of monthly cap; approximate)")
print("(approximation of the cap resolver: per-seat override, else plan cap, else $100; BYOK-billed orgs and "
      "unset BYOK axes are uncapped. The Engagement dashboard is the authoritative view.)")
default_cap = float(getattr(settings, "USAGE_MONTHLY_CAP_USD", 100.0) or 100.0)
flagged = 0
for sub in db.OrganizationSubscription.find({}):
    o = sub.get("organization_id")
    if o in SEED or sub.get("status") not in (None, "active", "trialing"):
        continue
    start = sub.get("current_period_start")
    if not start or (now - start.replace(tzinfo=dt.timezone.utc)).days > 31:
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if sub.get("billing_mode") == "byok":
        # BYOK seat caps, per provider, only where the customer set one
        lim = sub.get("byok_seat_limits") or {}
        for prov, cfg in lim.items():
            cap = (cfg or {}).get("monthly_cap_usd") or 0
            if not cap:
                continue
            for r in agg("APIUsage", [{"$match": {"organization_id": o, "funding_source": "byok", "api_provider": prov,
                                                  "created_at": {"$gte": start}, "cost_usd": {"$ne": None},
                                                  "test_run": {"$ne": True}}},
                                      {"$group": {"_id": "$user_id", "c": {"$sum": "$cost_usd"}}}]):
                if r["c"] >= 0.7 * cap:
                    flagged += 1
                    print(f"- {un(r['_id'])} @ {on(o)}: BYOK {prov} {money(r['c'])} of {money(cap)} ({r['c'] / cap:.0%})")
        continue
    cap = sub.get("monthly_cap_usd_override") or sub.get("plan_monthly_cap_usd") or default_cap
    for r in agg("APIUsage", [{"$match": {"organization_id": o, "funding_source": {"$in": ["platform", None]},
                                          "created_at": {"$gte": start}, "cost_usd": {"$ne": None},
                                          "test_run": {"$ne": True}, "record_kind": {"$ne": "request_telemetry"}}},
                              {"$group": {"_id": "$user_id", "c": {"$sum": "$cost_usd"}}}]):
        if r["c"] >= 0.7 * cap:
            flagged += 1
            print(f"- {un(r['_id'])} @ {on(o)}: {money(r['c'])} of {money(cap)} ({r['c'] / cap:.0%}) since {start:%d %b}")
if not flagged:
    print("- nobody at or above 70%")

# ---------------------------------------------------------------- 4. features
h("4. What they're using (agent runs in window, by agent and outcome)")
runs = agg("OrchestrationRun", [{"$match": {"created_at": {"$gte": since}, "organization_id": {"$nin": list(SEED)}}},
                                {"$group": {"_id": {"a": "$orchestration_id", "s": "$status"}, "n": {"$sum": 1},
                                            "c": {"$sum": {"$ifNull": ["$total_cost_estimate_usd", 0]}}}}])
by_agent = defaultdict(lambda: {"n": 0, "c": 0.0, "s": defaultdict(int)})
for r in runs:
    a = by_agent[r["_id"].get("a")]
    a["n"] += r["n"]
    a["c"] += r["c"]
    a["s"][r["_id"].get("s")] += r["n"]
for a, v in sorted(by_agent.items(), key=lambda kv: -kv[1]["n"])[: args.top * 2]:
    st = ", ".join(f"{k} {n}" for k, n in sorted(v["s"].items(), key=lambda kv: -kv[1]))
    print(f"- {a}: {v['n']} runs, est {money(v['c'])} ({st})")

# ---------------------------------------------------------------- 5. D2
h("5. Meeting follow-ups: external transcripts in window vs debriefs captured")
tm = {"call_date": {"$gte": since}, "direction": {"$ne": "internal"}, "organization_id": {"$nin": list(SEED)}}
per = defaultdict(lambda: [0, 0])
misses = []
for t in db.CRMCallTranscript.find(tm, {"organization_id": 1, "debrief_items_captured_at": 1, "subject": 1,
                                        "call_date": 1, "owner_journey_user_id": 1}).max_time_ms(T):
    c = per[t.get("organization_id")]
    c[0] += 1
    if t.get("debrief_items_captured_at"):
        c[1] += 1
    else:
        misses.append(t)
for o, (n, d) in sorted(per.items(), key=lambda kv: -kv[1][0]):
    print(f"- {on(o)}: {d} of {n} transcripts have follow-ups captured ({d / n:.0%})")
if not per:
    print("- no external transcripts in window")
b5 = agg("OrchestrationRun", [{"$match": {"orchestration_id": "b5_call_debrief", "created_at": {"$gte": since},
                                          "organization_id": {"$nin": list(SEED)}}},
                              {"$group": {"_id": "$status", "n": {"$sum": 1}}}])
print("call-debrief runs: " + (", ".join(f"{r['_id']} {r['n']}" for r in b5) or "none"))
if misses:
    print("examples without a captured follow-up (check these by hand):")
    for t in misses[: args.top]:
        cd = t.get("call_date")
        print(f"  - {on(t.get('organization_id'))} | {cd:%d %b %H:%M} | owner {un(t.get('owner_journey_user_id'))} "
              f"| {(t.get('subject') or '')[:70]} | id {t['_id']}")
print("(caveat: the capture stamp is cleared by a manual re-run; a call can also be legitimately follow-up-free)")

# ---------------------------------------------------------------- 6. P4
h("6. Nightly cleanup in window, and live queue per rep")
dec = agg("ActionItemCleanupDecision", [{"$match": {"created_at": {"$gte": since},
                                                    "organization_id": {"$nin": list(SEED)}}},
                                        {"$group": {"_id": {"o": "$organization_id", "a": "$action"}, "n": {"$sum": 1}}}])
dper = defaultdict(dict)
for r in dec:
    dper[r["_id"].get("o")][r["_id"].get("a")] = r["n"]
for o, d in sorted(dper.items(), key=lambda kv: -sum(kv[1].values())):
    print(f"- {on(o)}: " + ", ".join(f"{k} {n}" for k, n in sorted(d.items())))
if not dper:
    print("- no cleanup decisions in window")
why = agg("ActionItemCleanupDecision", [{"$match": {"created_at": {"$gte": since}, "action": "close",
                                                    "organization_id": {"$nin": list(SEED)}}},
                                        {"$group": {"_id": {"$ifNull": ["$rule", "$verdict"]}, "n": {"$sum": 1}}},
                                        {"$sort": {"n": -1}}, {"$limit": args.top}])
if why:
    print("top close reasons: " + ", ".join(f"{r['_id']} {r['n']}" for r in why))
q = agg("ActionItem", [{"$match": {"status": {"$in": ["open", "in_progress"]}, "organization_id": {"$nin": list(SEED)},
                                   "parent_action_item_id": {"$in": [None, ""]}}},
                       {"$group": {"_id": {"o": "$organization_id", "u": "$user_id"}, "n": {"$sum": 1}}}])
qo = defaultdict(list)
for r in q:
    qo[r["_id"].get("o")].append((r["n"], r["_id"].get("u")))
for o, lst in sorted(qo.items(), key=lambda kv: -len(kv[1])):
    ns = sorted(n for n, _ in lst)
    mx = max(lst)
    print(f"- {on(o)}: {len(lst)} reps with live cards, median {statistics.median(ns):g}, "
          f"max {mx[0]} ({un(mx[1])})")
print("(live = open + in_progress top-level cards; a compound's children aren't counted separately)")

# ---------------------------------------------------------------- 7. failures
h("7. Failures in window")
fr = agg("OrchestrationRun", [{"$match": {"created_at": {"$gte": since}, "status": "failed",
                                          "organization_id": {"$nin": list(SEED)}}},
                              {"$group": {"_id": "$orchestration_id", "n": {"$sum": 1},
                                          "e": {"$first": "$error_summary"}}},
                              {"$sort": {"n": -1}}, {"$limit": args.top}])
for r in fr:
    print(f"- {r['_id']}: {r['n']} failed; e.g. {(r.get('e') or '')[:120]}")
if not fr:
    print("- no failed agent runs")
pe = agg("APIUsage", [{"$match": {"created_at": {"$gte": since}, "status_code": {"$gte": 400},
                                  "record_kind": {"$ne": "request_telemetry"}}},
                      {"$group": {"_id": {"p": "$api_provider", "s": "$status_code"}, "n": {"$sum": 1},
                                  "e": {"$first": "$error_message"}}},
                      {"$sort": {"n": -1}}, {"$limit": args.top}])
for r in pe:
    print(f"- provider {r['_id'].get('p')} HTTP {r['_id'].get('s')}: {r['n']}; e.g. {(r.get('e') or '')[:120]}")
credit = agg("OrchestrationRun", [{"$match": {"created_at": {"$gte": since}}},
                                  {"$unwind": "$step_runs"},
                                  {"$match": {"step_runs.error_message": {
                                      "$regex": "search1|credit|quota|insufficient|rate.?limit|402|429",
                                      "$options": "i"}}},
                                  {"$group": {"_id": "$orchestration_id", "n": {"$sum": 1},
                                              "e": {"$first": "$step_runs.error_message"}}}])
for r in credit:
    print(f"- quota/credit-looking step errors in {r['_id']}: {r['n']}; e.g. {(r.get('e') or '')[:120]}")
if not credit:
    print("- no quota/credit-looking step errors (search provider looks healthy, as far as runs record it)")
