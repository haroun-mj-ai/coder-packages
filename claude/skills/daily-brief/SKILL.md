---
name: daily-brief
description: Composes the daily autopilot digest — what's awaiting approval, ready to test, blocked, failed, and today's spend/health — from a pre-gathered JSON snapshot. Invoked headless by the orchestrator (ap-brief.sh) at 07:00 AP_TZ. Prints markdown to stdout; makes no state changes of any kind.
---

# daily-brief

Pure transform. `ap-brief.sh` runs under a `dontAsk` profile that is
path-scoped to the project, so this skill has **no access to `~/.autopilot`**
(no ledger, no env, no marker file) and makes **no `gh` calls** — the wrapper
already gathered everything and handed it over as a single JSON file. Read
that file, print a markdown digest to stdout, and stop. That is the entire
job: no reads outside the input file, no writes anywhere (the wrapper owns
the brief file and the `.last-brief-ts` marker), no questions.

Shared vocabulary — inbox labels, the ledger shape, the protocol's
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
  "inbox": [ {"number": 1, "title": "...", "labels": [{"name": "..."}], "url": "..."}, ... ],
  "budget": {"max_issues": 3, "max_cost": 50, "today_cost": 0.0, "today_issues": 0},
  "health": {"newest_entry_age_min": 5, "paused": false, "scheduler_alive": true}
}
```

- `ledger` is every row from `$AP_HOME/runs/*.jsonl` with `ts` >= `since`
  (all rows, if this is the first-ever brief).
- `inbox` is every currently-open inbox issue (`gh issue list --state open
  --json number,title,labels,url`), regardless of window.
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

Compose, in this order, one line per item, each line linking out (inbox
issue URL) where a link exists. **Omit a section entirely if it has no
items** — except Spend and Health, which are always printed, so a fully
quiet day still reports something.

- **Queued** — `inbox` entries with none of the six state labels
  (`planning`/`plan-review`/`building`/`ready-to-test`/`needs-input`/
  `failed`): one line each, issue title + URL. These are delegations the
  owner created since the last cycle picked them up; the section clears once
  `autopilot-poll` claims them into `planning`.
- **Awaiting your approval** — `inbox` entries labeled `plan-review`: one
  line each, issue title + URL.
- **Ready to test** — `inbox` entries labeled `ready-to-test`: one line each,
  issue title + URL. The input has no PR links or relaunch commands (those
  live in the inbox issue's own comments, which this skill cannot read) — say
  so plainly ("see inbox issue for PR link + relaunch commands") rather than
  inventing a link.
- **Needs input** — `inbox` entries labeled `needs-input`: one line each,
  issue title + URL. The input has no comment body, so the exact question
  and the `Phase:` marker (which would flag a `ship`-phase stop as needing an
  interactive `/ship-work` rather than a `go`/feedback reply) are not
  derivable from this data — say so plainly ("see inbox issue for the
  question") rather than inventing either.
- **Failed** — `inbox` entries labeled `failed`: one line each, issue title +
  URL. The ledger rows carry no error text (that lives only in the inbox
  `failed` comment, which this skill cannot read) — say so plainly ("see
  inbox issue for the error") rather than inventing one.
- **Spend** — always present: `budget.today_cost` vs `budget.max_cost`, and
  `budget.today_issues` vs `budget.max_issues`.
- **Health** — always present: warn if `health.newest_entry_age_min` is
  `null` (no ledger activity ever) or greater than 60 (scheduler gap); warn
  if `health.paused` is true (autopilot is paused); warn if
  `health.scheduler_alive` is false (the tmux session isn't running at all).
  Otherwise report "ok".

A day with zero ledger activity and an empty inbox still prints Spend
(`$0.00 / $<max_cost>`, `0 / $<max_issues>` issues) and Health (whichever
warnings apply, or "ok").

## Output

Print the digest markdown to stdout. Nothing else — no preamble, no
questions, no trailing commentary. This is markdown for a human to read
(the wrapper forwards it verbatim to the phone notifier), not a
machine-parsed contract like `autopilot-poll`'s JSON. The skill makes no
writes of any kind; `ap-brief.sh` owns the brief file, the marker, and
cleanup of the input file.
