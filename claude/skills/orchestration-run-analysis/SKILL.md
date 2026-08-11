---
name: orchestration-run-analysis
description: >
  Deep-dive / audit one or more JourneyAI orchestration runs end to end —
  trigger & payload, agent sessions & tool usage, memories created/updated
  (fetched correctly? overwritten in place vs duplicated vs cross-account
  clobber?), action items & draft artifacts, and run lifecycle — then judge
  quality against the spec's prompt_template AND the product roadmap, surface
  issues with severity + fixes, and write a per-run evaluation doc. Use when the
  user asks to "analyze / audit / deep-dive / evaluate" orchestration run(s)
  (e.g. "run the same analysis on these A2 runs", a cockpit screenshot of runs,
  or "check this spec's latest runs"). Works against staging (Railway) or local.
---

# Orchestration run analysis

Produces the same deep-dive the A1/A2/wave5–7 evaluations used. Two helper
scripts live in `scripts/` next to this file; the rest is methodology.

## 0) Scope the request

Pin down before pulling data:
- **Which runs?** Explicit run ids (from a cockpit screenshot / the user), OR a
  spec id + "newest N" (e.g. the 3 most recent `a2_account_refresh`). A re-fire
  after a fix → compare against the prior wave.
- **Which spec(s)** and therefore the expected shape (steps, memories, action
  items). Read the backend spec to know what *should* happen.
- **Which environment.** Staging (Railway, DB `journeyai`) is the usual target;
  local is also possible. Org is normally Skaled MVP
  `52b5b8ea2a4a4fe5a1f9ae0d09b06ae6` (see the `reference_skaled_mvp_staging_ids`
  memory for verified ids).

## 1) Ground truth: read the spec + the roadmap (always fetch the roadmap yourself)

- **Backend spec:** `backend/app/orchestrations/<category>/<spec_id>.py` — the
  `prompt_template` strings, `steps` (system vs agent), `context_class`,
  `produces` (e.g. `memory:company_profile`), `required_integrations`,
  `cron_cadence`/`trigger_event_type`. This is the contract the run must meet.
- **Roadmap:** `docs/feedback/Journey MVP Roadmap v3 - Orchestration layer.pdf`.
  Read it with the Read tool (`pages`). Spec id → section: A1–A3 Account
  Lifecycle, B1–B6 Daily Sales Loop, C1–C5 Manager, D1–D5 Prospecting. Each spec
  is a left→right TRIGGER → SYSTEM/AGENT(reads/writes) → OUTPUT/REP row. Note the
  product intent: which agents, what each READS/WRITES, what artifacts it
  produces, and whether it emits Action Items (e.g. A2 is **memory-only**). Also
  the five principles (specialization, shared context, trigger intelligence,
  compound grouping, deterministic visibility) and the Artifacts table (pinned
  vs unpinned memory, action item, draft artifact, deal/rep summary, signal
  brief, prospecting plan — owner + where each lives).

## 2) Pull the data (`scripts/dump_runs.py`)

Edit the `SELECTION` block at the top of `dump_runs.py` (set `RUN_IDS` *or*
`SPEC_ID`+`LIMIT`, and `ORG_ID`). It dumps runs (+ embedded `step_runs`),
sessions (linked via `Session.metadata.orchestration_run_id`), messages →
ordered tool calls + results + text (via `Message.session_id`), the full memory
landscape per workspace (`Artifact`), action items + artifacts
(`source_orchestration_run_id`), and workspace/CRM context. Prints JSON after a
`###JSON###` marker.

**Run it in the staging container** (the internal Mongo only resolves there;
`railway run` runs locally and can't reach it). Avoid quoting hell by base64-ing
the script and single-quoting the redirects/`&&` so the *local* shell forwards
them as tokens (the container runs the command via `sh -c`):

```bash
cd backend                       # must be a Railway-linked dir (env: staging)
BLOB=$(base64 -w0 .claude/skills/orchestration-run-analysis/scripts/dump_runs.py)
railway ssh echo "$BLOB" '>' /tmp/dr.b64 '&&' base64 -d /tmp/dr.b64 '>' /tmp/dr.py \
  '&&' PYTHONPATH=/app python /tmp/dr.py > /tmp/run_dump.out 2>/tmp/run_dump.err
# extract the JSON after the marker into all.json, then analyze locally:
python3 -c "s=open('/tmp/run_dump.out').read(); i=s.find('###JSON###'); open('all.json','w').write(s[i+10:].strip())"
```

The script connects with `MongoClient(str(settings.MONGODB_URL))[settings.MONGODB_DB_NAME]`,
so it targets whatever DB the container is configured for. (For local, run it
with the local stack's env instead.) Cache the dump under
`~/journey-audit/<spec>/` — `/tmp` is wiped on WSL.

## 3) Render the run set (`scripts/inspect_runs.py`)

`python3 scripts/inspect_runs.py all.json` prints, per run: lifecycle
(status/cost/recovery/duration/dedupe_key), the trigger payload, the embedded
step list, and the **ordered tool-call flow per agent session (calls + results)** —
then the per-workspace **memory landscape** (one line per artifact:
type/pin/src_run/created/updated/title, flagged when written by these runs) and
any **action items**.

## 4) Analyze across every dimension

- **Lifecycle:** all steps `succeeded`? duration/cost reasonable? `recovery_attempts`
  0? `interrupted_at`/watchdog? dedupe_key correct (one per intended scope)?
- **Trigger & payload:** does the payload match what a *natural* trigger builds
  (event_id, scope ids, window_iso for crons)? For crons, did the right pager
  tuple fire?
- **Agent sessions & tool usage:** for each step's session, the ordered tool
  calls + results. Did agents read the right inputs (CRM with the **local
  Journey id**, not a `001…` SFDC remote id), reach `success` (not
  `not_found`/empty), and write what the spec's `produces` declares?
- **Memories — the core check (validate from records AND sessions):**
  1. *Right memory fetched* — `read_memories`/`read_memory_full` scoped to the
     run's **own** workspace + correct `memory_type`; no wrong-account fetch.
  2. *Updated in place, not duplicated* — the `save_artifact` result `_id`
     equals the pre-existing artifact's id; `created_at` stays, `updated_at`
     bumps; exactly one of each singleton (`company_profile`, `account_plan`)
     per account workspace. Count per type per workspace to catch dupes.
  3. *No cross-account override* — each run writes only to its own workspace;
     account-wide singletons (`company_profile`, `account_plan`) overwrite in
     place by design (keep-latest), per-opp memories (`stakeholder_map`,
     `deal_summary`) are **not** clobbered.
  4. *Provenance* — `source_orchestration_run_id` stamped; intent_key/dedupe_tag
     as expected.
- **Action items & draft artifacts:** kinds/status match the spec? compound
  parent + children with `compound_flavor` where the roadmap says so? draft
  artifact present (EmailDraftBody / LinkedinDraftBody / crm_update)? recipients
  resolved? provenance (`source_orchestration_run_id`, `orchestration_intent_key`)?
  **Does the spec emit items the roadmap says it shouldn't** (e.g. A2 = memory-only)?
- **Quality vs spec + roadmap:** content grounded (no fabricated stats/dates)?
  honest when data is missing? "preserve stable parts when nothing changed"
  respected? conforms to the roadmap row's reads/writes/outputs?

## 5) Write it up

Create `docs/feedback/orchestration-<spec>-per-run-evaluations-<YYYY-MM-DD>.md`
(append `-refire`/`-waveN` to distinguish runs). Match the established format
(see `orchestration-a2-per-run-evaluations-2026-06-16*.md` and
`orchestration-wave5/6/7-per-run-evaluations-2026-06-15.md`):

1. **Header** — rep, when/how fired, run count, env, what it's compared against.
2. **Summary table** — run / workspace / status / steps / cost / memories / items.
3. **One-line verdict** — does it run? high quality? major/minor/trivial issues?
4. **Memory-integrity validation** — the three checks above, with the
   id/created/updated evidence table.
5. **Roadmap conformance table** — requirement → ✅/⚠️/❌.
6. **Findings** — each issue with **severity** (P0 / Major / Minor / Trivial),
   root cause, and concrete fix option(s) ordered cheapest→most durable. Note
   what's already fixed/confirmed when validating a fix (before/after table).
7. **Per-run detail** — trigger payload, steps, the tool flow, memories, items.
8. **Overall judgment** — explicit grade + what must change before production.

Then give the user: the verdict, the findings with severity, and an offer to
fix (don't auto-commit — propose, then wait for go). Record notable findings in
memory (`project_*_run_audit_*`).

## Reference

- **Data model / linkage:** `OrchestrationRun` (embedded `step_runs` +
  `step_checkpoints`, `trigger_event_payload`, `dedupe_key`, `workspace_id`,
  `status`, `recovery_attempts`, `interrupted_at`, `total_cost_estimate_usd`) ·
  `Session.metadata.orchestration_run_id` · `Message.session_id` (tool calls in
  `output[].name`/`.arguments`, results in `.output`/`.text`) · `Artifact`
  (memories: `memory_type`, `is_pinned`, `source_orchestration_run_id`, `tags`,
  `dedupe_tag`, `orchestration_intent_key`) · `ActionItem`/`ActionItemArtifact`
  (`source_orchestration_run_id`, `action_item_id`) · `Workspace.linked_crm_entity_id`
  (the **local** account id) · `CRMAccount` (`_id` local, `remote_id` = SFDC `001…`).
- **CRM id gotcha:** the `read_crm_*` tools key on the local `CRMAccount.id`. An
  agent feeding a `001…` SFDC remote id gets `not_found`/empty. (Fixed for A2 +
  the read tools in `856260d`, but watch for it in other specs.)
- **Staging access / IDs:** `reference_skaled_mvp_staging_ids` memory.
- **Trigger a run to analyze:** the `cron-simulate` / `event-simulate` admin
  endpoints (`project_orchestration_simulate_endpoints` memory) — `bypass_dedupe:true`
  to re-fire the same window.
