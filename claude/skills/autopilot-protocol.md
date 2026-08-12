# Autopilot headless protocol

Shared contract for the `--headless` mode of `/plan-issue`, `/implement-plan`,
and `/ship-work`, and for the bash orchestrator (`ap-cycle.sh`) that invokes
them via `claude -p`. Read this before reading any skill's own headless
section: it defines the vocabulary and mechanics once so each skill only
states what maps to what.

## Trigger

The literal argument `--headless`. Absent, every skill behaves exactly as its
interactive instructions say and this protocol is inert. Present, every "ask
the human" point in that skill's instructions is replaced by the ask→fallback
rule below, and the run ends by writing `status.json`.

No autopilot run is ever a human at a terminal. A synchronous question would
block forever, so headless mode never blocks: it takes a documented default,
or it ends the run.

## Command discipline under `dontAsk`

Headless runs execute under a `dontAsk` permission profile: any tool call not
explicitly allowed is denied instantly, and **a piped or compound Bash command
is denied unless every segment is allowed**. So:

- One command per Bash call. Never pipe to `jq`/`python3`/`head` — `jq` is not
  even installed. For JSON from `gh`, use its built-in `--jq` flag
  (`gh issue list --json number,title,labels --jq '...'`), which needs no pipe.
- Prefer the allowed GitHub MCP issue tools (`list_issues`, `issue_read`,
  `issue_write`, `add_issue_comment`) over `gh` when one fits.
- A permission denial is not a prompt: nobody will answer. Retry once with an
  allowed form; if still denied, treat it per this protocol (FAILED with the
  denial string in `detail`) rather than asking in chat.

## Status vocabulary

- `DONE` — the phase finished; whatever it was supposed to produce (a
  committed plan, a QA'd branch, an open PR) exists.
- `NEEDS_HUMAN` — the run cannot proceed without the issue owner; a question
  has been posted to the inbox issue and the run has ended.
- `FAILED` — an error stopped the run. No in-run retry; the wrapper decides
  whether and when to retry.

## `status.json`

Written at the **end of every headless run**, success or not. Location, in
order of authority: the directory named by the `--run-dir <path>` argument
the orchestrator appends to every invocation (use this — the dontAsk profile
is path-scoped, so the session usually cannot read `$AP_RUN_DIR` from its
environment); else `$AP_RUN_DIR` if readable; else the fallback
`~/.autopilot/runs/adhoc/status.json` (create the directory if needed — the
orchestrator also checks there).
Exact shape, every key present on every write:

```json
{
  "status": "DONE|NEEDS_HUMAN|FAILED",
  "issue": "ENG-123",
  "phase": "plan|implement|ship",
  "plan_path": "<abs path or null>",
  "pr_urls": [],
  "question": "<string or null>",
  "detail": "<short free text: assumptions, relaunch commands, denial strings>"
}
```

- `issue`: the Linear id the run acted on, `ENG-<n>` form.
- `phase`: which of the three skills wrote this file.
- `plan_path`: absolute path to the committed plan file, or `null` if none
  exists yet (e.g. a `FAILED` run that never reached the write).
- `pr_urls`: `[]` unless `phase: ship` succeeded; then the opened PR URL(s).
- `question`: the exact question posted to the inbox on `NEEDS_HUMAN`, or
  `null` otherwise.
- `detail`: short free text — documented-default assumptions taken, relaunch
  commands for stopped servers, the permission-denial string on `FAILED`,
  or any other one-liner the wrapper or the morning brief should surface.
  Not a substitute for `question` or the inbox post; both still happen.

## Inbox contract

The private review channel is one GitHub repo, `$AP_INBOX_REPO` (default
`haroun-mj-ai/autopilot-inbox`), operated entirely through `gh issue`
commands. Never post plan content or questions to Linear — Linear is
team-visible.

- **Delegation is owner-initiated.** The owner creates the inbox issue — from
  the GitHub mobile app, typically — to hand off a Linear issue to the
  pipeline. Title must contain the Linear id (`ENG-<id>`, case-insensitive
  match, e.g. `ENG-1234` or `ENG-1234: whatever note`); anything in the title
  after the id, plus the issue body, is a note passed to `/plan-issue` as
  context, not machine-parsed.
- **No state label = new delegation.** An open inbox issue with none of the
  six state labels below is unclaimed work waiting for `autopilot-poll` to
  pick it up. The pipeline never creates inbox issues itself; it only labels
  and comments on ones the owner already created.
- **State labels** — exactly one held at a time, swapped rather than
  accumulated:
  `planning`, `plan-review`, `building`, `ready-to-test`, `needs-input`,
  `failed`. Swap with:
  ```bash
  gh issue edit <n> --repo "$AP_INBOX_REPO" --add-label <new> --remove-label <old>
  ```
- **Plan content:** the full plan markdown is the issue **body** on create
  (`gh issue create --body-file`), or a new **comment** on update
  (`gh issue comment --body-file`). Never truncate it. The post MUST begin
  with the line `Plan file: <absolute path>` before the plan markdown — this
  is the machine-readable source `autopilot-poll` extracts `planPath` from.
- **Owner comments are the approval mechanism:**
  - The word `go`, case-insensitive, exact (no other content) = approval.
  - Any other comment on a `plan-review` or `needs-input` issue = feedback or
    an answer, to be folded into a re-plan (quoted, not silently applied).

## Ask→fallback rule

Wherever an interactive skill's instructions say ask, confirm, or stop and
ask, headless mode resolves it one of two ways:

1. **If that instruction text also documents a default** (an explicit
   ordering, a stated fallback, a "otherwise do X"), take it. Record the
   assumption in `status.json`'s `detail` **and** as an inbox comment, so a
   human reviewing later can override it. This is not silent: it is a
   recorded, reversible choice.
2. **Otherwise**, post the question as a comment on the inbox issue, set its
   label to `needs-input`, write `status.json` with `status: NEEDS_HUMAN`
   and `question` set to the exact text posted, and end the run. Every
   `NEEDS_HUMAN` inbox comment MUST begin with the line `Phase: plan`,
   `Phase: implement`, or `Phase: ship` (matching `status.json`'s `phase`)
   before the question text — this is what `autopilot-poll` reads to route a
   later owner reply.

Never wait for a reply. Never ask in the chat/terminal (there is none to ask
in). Never post a question or plan content to Linear.

## Linear footprint

Headless runs only ever make the same two public writes the interactive
skills already make — nothing new:

- **Claim** (on first touching an issue): `assignee: me`, `state: In
  Progress`.
- **Ship success**: one comment with the PR link(s), plus label
  `agent:ready-to-test`.

Never set `Staging` or `Done` headlessly — `Staging` means merged
(`AGENTS.md`), and merging is never autonomous. Never create a Linear issue
headlessly; the free-text-creation path (`/plan-issue`'s `--no-issue`-adjacent
step 1b) is interactive-only, since it depends on an ask that has no
headless-safe default.

## Orchestrator guarantees

The wrapper (`ap-cycle.sh`), not the skill, guarantees:

- `$AP_RUN_DIR` exists before the skill runs.
- Reconciliation of `FAILED` or crashed runs (missing `status.json`) — a
  skill never needs to self-handle a crash; it only needs to write
  `status.json` on every path it controls.
- The phone ping on `NEEDS_HUMAN` and `FAILED`.

A skill's headless section is responsible for reaching one of the three
terminal states and writing `status.json` honestly; everything after that is
the wrapper's job.
