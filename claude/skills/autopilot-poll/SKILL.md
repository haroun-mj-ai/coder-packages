---
name: autopilot-poll
description: Decides and claims the single next autopilot action for this cycle — triage of the private inbox, the pipeline's only intake channel. Invoked headlessly by the orchestrator (ap-cycle.sh) every cycle, haiku-sized, and emits ONLY a JSON object, no prose. Do NOT use interactively for planning or implementing.
---

# autopilot-poll

Reads the private inbox (`$AP_INBOX_REPO`) — the only channel the owner uses
to delegate work — decides the single next action for this autopilot cycle,
claims it (label swap and, where relevant, a Linear claim), and emits that
decision as JSON. Nothing else. The three real skills (`/plan-issue`,
`/implement-plan`, `/ship-work`) do the actual work in a later stage of the
same cycle; this skill only triages and claims.

Shared vocabulary — inbox labels, the owner-comment approval rule, the Linear
footprint — is defined once in `.claude/skills/autopilot-protocol.md`. Read it
first.

## Output contract

Emit **only** one JSON object. No prose before or after it, no markdown code
fence, nothing else on stdout.

```json
{
  "action": "plan|implement|replan|none",
  "issue": "ENG-123",
  "planPath": "<abs path>",
  "inboxIssue": 42,
  "feedback": "<text>"
}
```

- `action` is always present.
- `issue`, `planPath`, `inboxIssue`, `feedback` are present only when relevant
  to the emitted `action` (see the priority order below for which fields each
  action carries). Omit keys that don't apply rather than emitting `null` —
  the orchestrator enforces this contract with a JSON schema, so an
  unexpected key or a missing required one for a given `action` is a hard
  failure.

## Environment

`$AP_INBOX_REPO` (default `haroun-mj-ai/autopilot-inbox`) is the private
inbox repo. Operate on it entirely through `gh issue list`, `gh issue view`,
`gh issue edit`, `gh issue comment` — never through the GitHub MCP, never
through Linear. The repo owner is the only commenter whose comments count;
ignore comments from anyone else (the inbox is private, but be exact about
this per the protocol's approval rule).

## Invocation flags

The orchestrator appends these to `/autopilot-poll` for this cycle. Read them
before the scan — they gate which tiers you're even allowed to act on.

- `--busy-lanes <names>` — a comma-separated subset of `build` and `plan`
  (e.g. `--busy-lanes build`, `--busy-lanes build,plan`), omitted entirely
  when no lane is busy. A lane listed here is owned by a still-running act in
  a different cycle. **Skip that lane's tiers entirely for this invocation:
  do not emit an action for it, and do not touch its labels.** Tier 1
  (`go`/auto-approve → `implement`) is the BUILD lane. Tiers 2, 3, and 4
  (feedback replan, needs-input answers, Queued intake → `replan`/`plan`)
  are the PLAN lane. If every candidate item you find belongs to a busy
  lane, emit `{"action":"none"}`. The wrapper deliberately does not mark a
  busy-lane signal as "seen" so it re-fires once the lane frees — you must
  not consume it either: no label swap, no comment, no claim for an item
  whose lane you're skipping.
- `--auto-approve` — present when the global env flag `AP_AUTO_APPROVE=1` is
  set. One of three independent auto-approve switches; see tier 1 below.

## Priority order

Stop at the first hit. Process **oldest-first** within a tier (`gh issue
list --repo "$AP_INBOX_REPO" ... --json number,title,labels,createdAt`,
sort ascending). Touch **at most one** actionable item per invocation — one
poll, one claim, one JSON object.

1. **`plan-review` inbox issues that are approved** → approval. Skip this
   tier entirely if `build` is in `--busy-lanes`.
   - An issue is approved when either (a) its newest owner comment (posted
     after the most recent plan post) is the exact word `go` or `auto`
     (case-insensitive, exact word, no other content — `go` and `auto` are
     the only two recognized directive keywords), **or** (b) no such new
     owner comment exists (i.e. the newest new comment, if any, is feedback,
     not a directive) **and** any of the three auto-approve switches applies:
     the invocation carries `--auto-approve`, the issue itself carries the
     `auto` label (case-insensitive, read from the labels already fetched),
     or an existing owner comment on the issue has `auto` as its exact first
     line (case-insensitive).
   - **Order matters:** check for a new owner comment first. A new owner
     comment that is neither `go` nor `auto` is feedback and wins over every
     auto-approve switch — route it to tier 2 (`replan`), never build a plan
     the owner just objected to. Only fall back to the auto-approve switches
     when there is no new directive-or-feedback comment to process.
   - Extract the ENG id from the issue title (`ENG-<id>: ...`).
   - Extract `planPath` from the newest `Plan file: <absolute path>` line on
     the issue (body or comments, per the protocol's inbox contract). If no
     such line exists, fall back to listing `docs/plans/*<eng-id-lowercase>*.md`
     in the root worktrees (`/home/coder/root-for-local/wt-*/docs/plans/`)
     and the main checkout, newest first, and take the first hit. If neither
     the `Plan file:` line nor the fallback listing yields a path that
     actually exists on disk, do not emit `implement`: swap the label to
     `needs-input`, comment that the plan path could not be resolved, and
     continue the scan (fall through to the next tier/item, not this action).
   - Swap the inbox label `plan-review` → `building` **before** emitting.
   - Emit `{"action":"implement","issue":"ENG-<id>","planPath":"<path>","inboxIssue":<n>}`.

2. **`plan-review` inbox issues with any other new owner comment** (anything
   other than the exact word `go` or `auto`) → feedback. Skip this tier
   entirely if `plan` is in `--busy-lanes`.
   - Swap the inbox label `plan-review` → `planning` before emitting.
   - Emit `{"action":"replan","issue":"ENG-<id>","inboxIssue":<n>,"feedback":"<comment text>"}`.

3. **`needs-input` inbox issues with a new owner comment** → answer to a
   blocking question. Skip this tier entirely if `plan` is in
   `--busy-lanes`. `needs-input` issues are **never** auto-approved — a
   blocking question or a ship-phase stop always waits for the human, none
   of the three auto-approve switches applies here regardless of state.
   - Read the `Phase:` line of the newest agent-authored `NEEDS_HUMAN`
     comment on the issue (per the protocol's ask→fallback rule).
     - `Phase: plan` or `Phase: implement` → an implement-phase answer folds
       into a plan revision, which re-enters review and rebuilds — this is
       deliberate, not a shortcut. Swap the inbox label `needs-input` →
       `planning` before emitting. Emit
       `{"action":"replan","issue":"ENG-<id>","inboxIssue":<n>,"feedback":"<comment text>"}`.
     - `Phase: ship` → the stop lives in the PR/branch and needs the owner's
       interactive `/ship-work` session; no automated action can resolve it.
       Do not emit any action for this item: leave the label as
       `needs-input`, and continue the scan.
     - Missing `Phase:` line (legacy or malformed comment) → treat as
       `Phase: plan`.

4. **Open inbox issues carrying the `Queued` label** (case-insensitive) **and
   none of the six state labels** → a new owner delegation, oldest first.
   Skip this tier entirely if `plan` is in `--busy-lanes`. An open issue
   WITHOUT `Queued` is a draft — the pipeline ignores it entirely, whether or
   not it has a state label.
   - Extract the Linear id from the issue title with `ENG-\d+`
     (case-insensitive). The id may be followed by a note (`ENG-1234: fix the
     thing`); the id is what matters, the rest is context.
   - **No `ENG-\d+` match anywhere in the title** → the owner didn't include
     an id. Comment asking for one (e.g. "Add the Linear issue id, `ENG-<n>`,
     to the title and I'll pick this up."). Claim it with a single call:
     `gh issue edit <n> --repo "$AP_INBOX_REPO" --remove-label Queued --add-label needs-input`.
     Continue the scan — do not emit an action for this item.
   - **Match found** → claim it with a single call:
     `gh issue edit <n> --repo "$AP_INBOX_REPO" --remove-label Queued --add-label planning`,
     claim on Linear per the protocol's Linear footprint (`assignee: me`,
     `state: In Progress`), and emit
     `{"action":"plan","issue":"ENG-<id>","inboxIssue":<n>}`. If the title
     carries a note after the id, or the issue body is non-empty, include it
     as `"feedback":"<note text>"` in the same emit so `/plan-issue` sees it
     as context.

5. **Otherwise** → emit `{"action":"none"}`.

## Stale-claim sweep

Run this **before** the priority scan above — it's cheap and must not block
on it.

Inbox issues labeled `planning` or `building` with no comment or label
activity in the last 3 hours, **and** no autopilot run currently active
(check: the newest file under `~/.autopilot/runs/` is itself older than 3
hours, or the directory is absent/empty) → the claim is stale:

- Swap the label to `failed`.
- Comment `stale claim swept: no active run`.
- Continue the scan — a swept issue is not itself emitted as an action this
  cycle; move on to the priority order above as if it had never been
  claimed.

## Determinism rules

- Oldest-first within each tier (stable across cycles — the same item wins
  ties every time).
- At most one actionable item touched per invocation, ever — this skill
  never emits more than one action, and never claims two issues.
- **Label swaps (and the Linear claim in tier 4) happen before emitting the
  JSON.** This makes a crash after the swap indistinguishable from a normal
  in-progress claim: the 3h stale-claim sweep on a later cycle is what
  recovers it. Never emit first and swap after — that would risk a double
  claim if the emit succeeds but the swap is lost.
