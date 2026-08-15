---
name: daily-brief
description: Composes the daily autopilot digest — what's awaiting approval, ready to test, blocked, failed, and today's spend/health — from a pre-gathered JSON snapshot. Invoked headless by the orchestrator (ap-brief.sh) at 07:00 AP_TZ. Prints markdown to stdout; makes no state changes of any kind.
---

# daily-brief

Pure transform. `ap-brief.sh` runs under a `dontAsk` profile that is
path-scoped to the project, so this skill has **no access to `~/.autopilot`**
(no ledger, no env, no queue files) and makes **no `gh` calls, no `ap_queue.py`
calls** — the wrapper already gathered everything and handed it over as a
single JSON file. Read that file, print a markdown digest to stdout, and
stop. That is the entire job: no reads outside the input file, no writes
anywhere (the wrapper owns the brief file and the `.last-brief-ts` marker),
no questions.

Shared vocabulary — queue ticket states, the ledger shape, the protocol's
`status.json` fields — is defined in `.claude/skills/autopilot-protocol.md`.
Read it first.

## Input

The file named by the `--input <path>` argument, inside the project (read it
with the Read tool). Shape:

```json
{
  "since": "<ISO ts>",
  "now": "<ISO ts>",
  "ledger": [ {"ts": "...", "issue": "ENG-123 or null", "phase": "poll|plan|replan|implement|ship", "status": "...", "cost": 0.0, "session_id": "..."}, ... ],
  "queue": [ {"eng_id": "ENG-123", "state": "...", "note": "...", "auto_approve": false, "question": null, "pr_urls": [], "seq": 1}, ... ],
  "budget": {"max_issues": 3, "max_cost": 50, "today_cost": 0.0, "today_issues": 0, "max_week_cost": 310, "week_cost": 0.0},
  "health": {"newest_entry_age_min": 5, "paused": false, "scheduler_alive": true}
}
```

- `ledger` is every row from `$AP_HOME/runs/*.jsonl` with `ts` >= `since`
  (all rows, if this is the first-ever brief).
- `queue` is every ticket currently in the local queue (`ap_queue.py
  --ap-home "$AP_HOME" list`, one entry per `$AP_HOME/queue/<ENG-ID>.json`),
  regardless of window — each entry is the ticket's full schema (see
  `.claude/skills/autopilot-protocol.md`'s "Local queue contract"), not just
  the subset shown above.
- `health.newest_entry_age_min` is `null` if there has never been a ledger
  entry at all.

If the input file is missing, empty, or fails to parse as JSON, print
exactly one line and stop:

```
Daily brief unavailable: could not read the input file.
```

Do not apologize, do not ask a question, do not attempt to reconstruct the
digest from anything else — there is nothing else available to this skill.

## Digest sections

Compose, in this order, one line per item, each line naming the `eng_id`
plus its `note` when non-empty. **Omit a section entirely if it has no
items** — except Spend and Health, which are always printed, so a fully
quiet day still reports something.

- **Queued** — `queue` entries at `state: queued`: one line each, `eng_id` +
  `note`. These are tickets the owner ran `ap queue` on since the last cycle
  picked them up; the section clears once the decider claims them into
  `planning`. (There is no "draft" concept anymore — a ticket only exists
  once `ap queue` has created it, so there is nothing unlabeled to report.)
- **Awaiting your approval** — `queue` entries at `state: plan-review`: one
  line each, `eng_id` + `note`. If the entry's `auto_approve` is `true`,
  append a note that it will auto-approve on the next cycle rather than
  actually waiting on the owner (e.g. "(auto-approves next cycle)"). The
  global `AP_AUTO_APPROVE` switch is NOT in this snapshot, so an entry can
  still auto-approve without its own `auto_approve` set; say so plainly
  rather than inventing it: end the section with one line noting that some
  entries may auto-approve via the global flag even without `auto_approve`
  shown here.
- **Shipping** — `queue` entries at `state: shipping`: one line each,
  `eng_id` + `note`. The PR(s) are already open by this point
  (`/implement-issue`'s Phase B opens them as its own last step) — this state
  means mid-`ship-work`, waiting on CI. The input has no started-at time
  (that lives only in the ledger's `ship` rows, which this section does not
  cross-reference), so just list them.
- **Ship pending** — `queue` entries at `state: ship-pending`: one line each,
  `eng_id` + `note`. These implemented, committed, and (normally) already have
  an open PR, but a ship phase either failed for an external cause and got
  re-queued here, or a human retried it by hand (`ap retry`) — the next
  cycle retries just the ship (CI-wait/merge), not the whole build.
- **Ready to test** — `queue` entries at `state: ready-to-test`: one line
  each, `eng_id` + `note`, plus the `pr_urls` already present in the entry
  (join with ", "; say "see `ap sessions` for PR links" only if `pr_urls` is
  empty). Relaunch commands still live only in the QA artifact
  (`docs/plans/qa/<eng-id>-qa.md`), which this skill cannot read — say so
  plainly rather than inventing one.
- **Needs input** — `queue` entries at `state: needs-input`: one line each,
  `eng_id` + `note`, plus the entry's own `question` field verbatim (it is
  in this snapshot, unlike the old inbox-comment version) and
  `phase_at_question` (which flags a `ship`-phase stop as needing an
  interactive `/ship-work` rather than a `go`/feedback reply).
- **Failed** — `queue` entries at `state: failed`: one line each, `eng_id` +
  `note`. The ledger rows carry no error text (that lives only in the
  ticket's `history`, which is not in this snapshot) — say so plainly ("see
  `ap run <eng-id>` for the error") rather than inventing one.
- **Spend** — always present: `budget.today_cost` vs `budget.max_cost`, and
  `budget.today_issues` vs `budget.max_issues`. Also report `budget.week_cost`
  vs `budget.max_week_cost` (this pipeline's carved-out share of the account's
  weekly Claude usage pool — the rest is reserved for interactive use, so
  `week_cost` alone approaching `max_week_cost` is a real signal even though
  it's well under the account's full weekly allotment). Flag it if
  `week_cost` exceeds `max_week_cost`.
- **Health** — always present: warn if `health.newest_entry_age_min` is
  `null` (no ledger activity ever) or greater than 60 (scheduler gap); warn
  if `health.paused` is true (autopilot is paused); warn if
  `health.scheduler_alive` is false (the tmux session isn't running at all).
  Otherwise report "ok".

A day with zero ledger activity and an empty queue still prints Spend
(`$0.00 / $<max_cost>`, `0 / $<max_issues>` issues, week `$<week_cost> /
$<max_week_cost>`) and Health (whichever warnings apply, or "ok").

## Output

Print the digest markdown to stdout. Nothing else — no preamble, no
questions, no trailing commentary. This is markdown for a human to read
(the wrapper forwards it verbatim to the phone notifier), not a
machine-parsed JSON contract. The skill makes no writes of any kind;
`ap-brief.sh` owns the brief file, the marker, and cleanup of the input
file.
