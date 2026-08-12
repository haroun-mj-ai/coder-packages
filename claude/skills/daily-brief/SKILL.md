---
name: daily-brief
description: Composes the daily autopilot digest — what's awaiting approval, ready to test, blocked, failed, and today's spend/health — from the run ledger and inbox state. Invoked by the orchestrator at 07:00 (ap-brief.sh) or manually. Prints markdown to stdout; makes no state changes beyond writing the brief file and its own timestamp marker.
---

# daily-brief

Reads what happened since the last brief and prints a short markdown digest.
Read-only against the pipeline itself — this skill never touches inbox
labels, Linear, or any run state. Its only writes are the brief file and the
timestamp marker that tracks "since when" for the next run.

Shared vocabulary — inbox labels, the ledger shape, the protocol's
`status.json` fields — is defined in `.claude/skills/autopilot-protocol.md`.
Read it first.

## Inputs

- **Ledger since the last brief:** `~/.autopilot/runs/*.jsonl`, filtered to
  entries with `ts` after the timestamp recorded in
  `~/.autopilot/briefs/.last-brief-ts` (ISO-8601). If that marker file is
  absent (first-ever brief), use all available ledger entries.
- **Current inbox state:**
  ```bash
  gh issue list --repo "$AP_INBOX_REPO" --state open \
    --json number,title,labels
  ```
- Budgets: `$AP_MAX_DAY_COST_USD`, `$AP_MAX_ISSUES_PER_DAY` (same env as
  `ap-cycle.sh`; source `~/.autopilot/env` if the wrapper hasn't already).

## Digest sections

Compose, in this order, one line per item, each line linking out (inbox
issue URL, PR URL) where a link exists. **Omit a section entirely if it has
no items** — except Spend and Health, which are always printed, so a fully
quiet day still reports something.

- **Queued** — open inbox issues with none of the six state labels: one line
  each, issue title + inbox URL. These are delegations the owner created
  since the last cycle picked them up; the section clears once
  `autopilot-poll` claims them into `planning`.
- **Awaiting your approval** — inbox issues currently labeled
  `plan-review`: one line each, issue title + inbox URL.
- **Ready to test** — inbox issues currently labeled `ready-to-test`: one
  line each with the PR link(s) and the relaunch command(s) recorded on that
  issue (per `/implement-plan`'s headless server-teardown section — pull
  them from the inbox comment, not the ledger).
- **Needs input** — inbox issues currently labeled `needs-input`: one line
  each with the exact question (from the issue's own comment, or from a
  ledger entry's `status.json` `question` field if more current). If the
  newest `NEEDS_HUMAN` comment's `Phase:` line reads `Phase: ship`, append
  "resolve interactively (`/ship-work`)" — that stop needs the owner's own
  session, not a `go`/feedback reply autopilot can act on.
- **Failed** — inbox issues currently labeled `failed`: one line each with
  the last error line (from the failing ledger entry's `detail`, or the
  inbox `failed` comment if the ledger entry is missing/stale).
- **Spend** — always present: total `total_cost_usd` summed across the
  ledger entries in this window vs. `$AP_MAX_DAY_COST_USD`, and count of
  distinct issues acted on vs. `$AP_MAX_ISSUES_PER_DAY`.
- **Health** — always present: warn if the newest ledger entry overall
  (not just in-window) is older than 1 hour (scheduler gap), and warn if
  `~/.autopilot/pause` exists (autopilot is paused).

A day with zero ledger activity and an empty inbox still prints Spend
(`$0.00 / $AP_MAX_DAY_COST_USD`, `0 / $AP_MAX_ISSUES_PER_DAY` issues) and
Health (gap warning if applicable, or "ok").

## Output

1. Write the full digest to `~/.autopilot/briefs/YYYY-MM-DD.md` (today's
   date, local).
2. Update `~/.autopilot/briefs/.last-brief-ts` to the current time, so the
   next brief's window starts here. Do this only after the file write above
   succeeds.
3. Print the **same, full** digest to stdout as the skill's final output —
   this is what `ap-brief.sh` pipes to the phone notifier. Nothing else goes
   to stdout; this is markdown for a human to read, not a machine-parsed
   contract like `autopilot-poll`'s JSON.
