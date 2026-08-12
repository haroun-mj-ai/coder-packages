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
- **`Queued` label = new delegation.** An open inbox issue carrying the
  `Queued` label (case-insensitive match on the label name) and none of the
  seven state labels below is unclaimed work waiting for `autopilot-poll` to
  pick it up. An open issue WITHOUT `Queued` is a **draft** — the pipeline
  ignores it entirely, whether or not it carries a state label. On claiming
  it, the poll removes `Queued` and adds the target state label
  (`planning`, or `needs-input` if the title carries no `ENG-\d+` id) in a
  single `gh issue edit` call. The pipeline never creates inbox issues
  itself; it only labels ones the owner already created.
- **Three independent auto-approve switches.** Any one of the following
  treats a `plan-review` issue with no new pending owner feedback exactly
  like a `go` comment (approve → `implement`), skipping the manual `go`:
  1. **Global flag** — `AP_AUTO_APPROVE=1` in the orchestrator's env; the
     wrapper passes `--auto-approve` to the poll prompt.
  2. **Label** — the issue itself carries the `auto` label
     (case-insensitive).
  3. **Comment** — an owner comment on the issue whose first line is
     exactly `auto` (case-insensitive, exact word — `go` and `auto` are the
     only two recognized directive keywords).
  A **new** owner comment that is neither `go` nor `auto` is feedback and
  beats every auto-approve switch (route to a re-plan, never build a plan
  the owner just objected to) — check for new comments before falling back
  to auto-approval. `needs-input` issues are **never** auto-approved: a
  blocking question or a ship-phase stop always waits for the human,
  regardless of any switch.
- **State labels** — exactly one held at a time, swapped rather than
  accumulated:
  `planning`, `plan-review`, `building`, `shipping`, `ready-to-test`,
  `needs-input`, `failed`. State machine:
  `planning → plan-review → building → shipping → ready-to-test`, with
  `needs-input`/`failed` reachable from any state. `shipping` is the odd one
  out: it is set by the **orchestrator** (`ap-cycle.sh`), not by a skill,
  right before it invokes the ship phase (`building` → `shipping`) — this
  makes it reliable even if the ship session dies before writing anything.
  `/ship-work --headless` owns the swap out of it (`shipping` →
  `ready-to-test` on success, `shipping` → `needs-input` on a hard stop).
  Every other swap is skill-side. Swap with:
  ```bash
  gh issue edit <n> --repo "$AP_INBOX_REPO" --add-label <new> --remove-label <old>
  ```
- **Plan content:** the full plan markdown is the issue **body** on create
  (`gh issue create --body-file`), or a new **comment** on update
  (`gh issue comment --body-file`). Never truncate it. The post MUST begin
  with the line `Plan file: <absolute path>` before the plan markdown — this
  is the machine-readable source `autopilot-poll` extracts `planPath` from.
- **Owner comments are the approval mechanism:**
  - The word `go` or `auto`, case-insensitive, exact (no other content) =
    approval (see the auto-approve switches above — these are the only two
    recognized directive keywords).
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

Headless runs never post a Linear comment — not ever, for any reason.
Questions, plan content, PR links, QA notes, and relaunch commands all go to
the inbox issue only (see the inbox contract above); Linear is team-visible
and the notify channel plus the private inbox repo are the only places a
headless run talks to a human. The entire headless footprint on Linear is
exactly two writes:

- **Claim** (on first touching an issue): `assignee: me`, `state: In
  Progress`.
- **Ship success**: label `agent:ready-to-test` — no comment. The PR link(s)
  go to the inbox issue only.

Never set `Staging` or `Done` headlessly — `Staging` means merged
(`AGENTS.md`), and merging is never autonomous. Never create a Linear issue
headlessly; the free-text-creation path (`/plan-issue`'s `--no-issue`-adjacent
step 1b) is interactive-only, since it depends on an ask that has no
headless-safe default.

## Orchestrator guarantees

The wrapper (`ap-cycle.sh`), not the skill, guarantees:

- `$AP_RUN_DIR` exists before the skill runs, and its absolute path is
  appended to the invocation as literal prompt text, `--run-dir <path>` — the
  `dontAsk` profile is path-scoped, so the session usually cannot read
  `$AP_RUN_DIR` from its environment.
- For `implement`/`ship` acts, the assigned build slot's port pair is
  appended the same way: `--ports fe=<port>,be=<port>`. Under this flag,
  bind exactly those two ports for the changed pair (never the human's
  baseline 5173/8000) — see `implement-plan`'s headless section for the CORS
  implication.
- The `building` → `shipping` inbox-label swap happens before the ship phase
  is invoked (see "State labels" above) and the "shipping: `<issue>`" phone
  ping fires at the same time — both wrapper-side, not skill-side, so they
  happen even if the ship session dies before writing anything.
- Reconciliation of `FAILED` or crashed runs (missing `status.json`) — a
  skill never needs to self-handle a crash; it only needs to write
  `status.json` on every path it controls.
- The phone ping on `NEEDS_HUMAN` and `FAILED`.

A skill's headless section is responsible for reaching one of the three
terminal states and writing `status.json` honestly; everything after that is
the wrapper's job.
