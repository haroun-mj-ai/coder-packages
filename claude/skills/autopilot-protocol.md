# Autopilot headless protocol

Shared contract for the `--headless` mode of `/implement-issue` (`--phase
plan` and `--phase implement`) and `/ship-work`, and for the bash
orchestrator (`ap-cycle.sh`) that invokes them. Read this before reading any
skill's own headless section: it defines the vocabulary and mechanics once
so each skill only states what maps to what.
(`/plan-issue` and `/implement-plan` are retired, folded into
`/implement-issue`'s two phases — this document still uses "the plan phase"
and "the implement phase" as the natural names for what each used to be.)

Launch mechanism is a wrapper-side, not skill-side, concern (see "## Parking"
below): `ap-cycle.sh` launches a headless act as either a one-shot `claude
-p` (`AP_ACT_LAUNCH_MODE=oneshot`) or a persistent interactive session in its
own tmux window (`AP_ACT_LAUNCH_MODE=persistent`, the default). Nothing in
this document or in a skill's own headless section depends on which — a
skill never needs to know or care.

## Trigger

The literal argument `--headless`. Absent, every skill behaves exactly as its
interactive instructions say and this protocol is inert. Present, every "ask
the human" point in that skill's instructions is replaced by the ask→fallback
rule below, and the run ends by writing `status.json`.

No autopilot run has a human synchronously present at the moment an ask-point
is hit — headless mode never blocks waiting for one inline: it takes a
documented default, or it asks and stops (`status: NEEDS_HUMAN`). What
happens to the *process* after that stop is a wrapper-side launch-mode
decision — see "## Parking" — not something this rule or a skill's own
instructions need to distinguish.

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
  has been posted to the inbox issue. What happens to the *process* next is
  the wrapper's call — see "## Parking" — not something a skill's own
  instructions decide or need to know.
- `FAILED` — an error stopped the run. No in-run retry; the wrapper decides
  whether and when to retry.

## Parking

`AP_ACT_LAUNCH_MODE=persistent` (the default) launches every headless act —
plan, replan, implement, ship, standalone or chained — as a real interactive
`claude` session in its own tmux window inside the `autopilot` session,
instead of a one-shot `claude -p`. This changes what happens to the
*process* after a `NEEDS_HUMAN` write; it changes nothing about how a skill
decides to reach `NEEDS_HUMAN` in the first place, still governed entirely
by the ask→fallback rule above.

- **`DONE`/`FAILED`**: the wrapper tears the window down (a short debounce,
  then `tmux kill-window`) — same as `AP_ACT_LAUNCH_MODE=oneshot`'s process
  exit, just wrapper-driven instead of automatic.
- **`NEEDS_HUMAN`**: the window is deliberately left alive — "parks" —
  instead of ending the run. The wrapper records a parked-registry entry
  (`$AP_HOME/parked/<inbox-issue>.json`: window name, lane, run dir, plan
  path, ports, the question) and releases the act's lane slot and per-issue
  lock immediately, so the pipeline's limited build/ship slots (2 and 3 by
  default) aren't tied up for however long the owner takes to reply — the
  exact property `oneshot` mode's "NEEDS_HUMAN frees the slot" already had,
  preserved here by a different mechanism.
- **Resuming**: a reply lands one of two ways, both converging on the same
  `ap-resume.sh <inbox-issue> [<reply-text>]` — re-acquires a slot from the
  normal pool, re-acquires the per-issue lock, then either injects the reply
  via `tmux send-keys` or (no reply text) just observes whatever the act has
  already moved to:
  1. **A GitHub inbox comment**, exactly as today — `ap-cycle.sh`'s scan
     detects it (same marker-line discipline, same "is this agent-authored"
     check) and backgrounds `ap-resume.sh` with the comment text.
  2. **`tmux attach -t autopilot`**, finding the window (named
     `act_<lane>[_<slot>]_<issue>_<phase>`; `ap status`/`ap runs` list
     these), and typing the answer directly. A background sweep in
     `ap-cycle.sh` notices the resulting state change and reconciles the
     lane/issue locks and the registry the same way `ap-resume.sh` would —
     this is what makes attaching and typing alone actually work, not just
     mechanically possible.
- **Required of every skill's own headless section**: stop any dev
  servers/background processes the run started *before* writing
  `NEEDS_HUMAN`, not only before `DONE` — a slot freed at park time can be
  handed to a fresh act whose assigned port pair would otherwise collide
  with the parked act's still-bound servers.
- **The GitHub inbox comment on `NEEDS_HUMAN` is still mandatory** — a
  durable audit trail and a channel that works even if the workspace or
  tmux session is down — it is simply no longer the *only* way back in.
- **`AP_ACT_LAUNCH_MODE=oneshot`** restores today's exact original
  behavior: `NEEDS_HUMAN` just ends the run, a later reply starts a brand
  new invocation that re-derives context from the plan file (and kata).
  Nothing above applies in this mode.

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
  "detail": "<short free text: assumptions, the QA artifact path, denial strings>"
}
```

- `issue`: the Linear id the run acted on, `ENG-<n>` form.
- `phase`: which of the three skills wrote this file.
- `plan_path`: absolute path to the committed plan file, or `null` if none
  exists yet (e.g. a `FAILED` run that never reached the write).
- `pr_urls`: `[]` unless `phase: ship` succeeded; then the opened PR URL(s).
- `question`: the exact question posted to the inbox on `NEEDS_HUMAN`, or
  `null` otherwise.
- `detail`: short free text — documented-default assumptions taken, the
  permission-denial string on `FAILED`, or any other one-liner the wrapper or
  the morning brief should surface. On an `implement` phase `DONE`, this is
  where the **QA artifact's absolute path** goes
  (`docs/plans/qa/<eng-id>-qa.md` in the root worktree — see
  `implement-issue/SKILL.md`'s Phase B step 9): that file, not `detail`, carries the
  relaunch commands, the gates' commit SHA, and the QA checklist, so `detail`
  only needs to point at it rather than duplicate it. Not a substitute for
  `question` or the inbox post; both still happen.

## Inbox contract

The private review channel is one GitHub repo, `$AP_INBOX_REPO` (default
`haroun-mj-ai/autopilot-inbox`), operated entirely through `gh issue`
commands. Never post plan content or questions to Linear — Linear is
team-visible.

- **Delegation is owner-initiated.** The owner creates the inbox issue — from
  the GitHub mobile app, typically — to hand off a Linear issue to the
  pipeline. Title must contain the Linear id (`ENG-<id>`, case-insensitive
  match, e.g. `ENG-1234` or `ENG-1234: whatever note`); anything in the title
  after the id, plus the issue body, is a note passed to `/implement-issue
  --phase plan` as context, not machine-parsed.
- **`Queued` label = new delegation.** An open inbox issue carrying the
  `Queued` label (case-insensitive match on the label name) and none of the
  eight state labels below is unclaimed work waiting for `autopilot-poll` to
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
  `needs-input`, `failed`, `ship-pending`. State machine:
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
  `ship-pending` means implement finished and committed, ship still owed —
  reachable from `shipping` (the orchestrator sets it when a ship phase
  fails for an external cause, see "External failures are re-queued, not
  dead-ended" below) or by a human relabelling by hand. `autopilot-poll`'s
  tier 4 claims it (`ship-pending` → `shipping`) and emits `action:ship`,
  which the orchestrator dispatches as `/ship-work --headless --no-merge`
  with no `/implement-issue` step first — the plan is
  already committed. This `action:ship` claims the orchestrator's SHIP lane
  (its own slot pool, `AP_SHIP_SLOTS`), not the BUILD lane `implement` uses —
  see "Orchestrator guarantees" below for the port-pair mechanics, and
  `autopilot/README.md`'s concurrency section for why the cap differs.
- **External failures are re-queued, not dead-ended.** When an act's own
  stderr/stdout matches a signature that names a cause outside the plan or
  the code — a rate/usage/session limit trip, or the provider itself
  erroring (`overloaded`, `529`, `API Error`) — the orchestrator does not
  label the inbox issue `failed`. Instead it restores the state the failed
  phase started from, so the same work is picked up again once things clear:
  `plan`/`replan` → `Queued`, `implement` → `plan-review`,
  `ship` → `ship-pending`. It comments on the inbox issue naming the
  external cause and the matched signature line, and pings with a title
  like `requeued after external failure: <issue>` rather than the usual
  `FAILED` wording. This is entirely orchestrator-side reconciliation, not a
  skill behavior — no skill needs to detect or act on it. The consecutive-
  failure counter (and the usage-limit auto-pause it can trigger) still
  increments for an external failure exactly as it does for any other one —
  that backoff is what stops a re-queue from thrashing.
- **Every comment the pipeline writes is marked.** The inbox is operated with
  the owner's own `gh` credentials, so a pipeline comment and a human comment
  have the same author — the first line is the only distinguishing signal, and
  `autopilot-poll` relies on it to decide whether new owner input exists. Every
  comment written by any headless skill or by the orchestrator MUST begin with
  one of: `Plan file: <abs path>` (a plan post), `Phase: plan|implement|ship`
  (a `NEEDS_HUMAN` question or a phase-scoped informational note), or
  `Autopilot:` (orchestrator-written failure/re-queue notices). An unmarked
  comment is read as the owner speaking and starts an unbounded re-plan loop:
  each re-plan posts another comment that triggers the next. Do not post an
  unmarked "FYI" — there is no such thing as a free comment here.
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
headlessly; the free-text-creation path (`/implement-issue`'s
`--no-issue`-adjacent step 1) is interactive-only, since it depends on an ask that has no
headless-safe default.

## Orchestrator guarantees

The wrapper (`ap-cycle.sh`), not the skill, guarantees:

- `$AP_RUN_DIR` exists before the skill runs, and its absolute path is
  appended to the invocation as literal prompt text, `--run-dir <path>` — the
  `dontAsk` profile is path-scoped, so the session usually cannot read
  `$AP_RUN_DIR` from its environment.
- For an `implement` act, and for the trailing `ship` call of the SAME
  implement→ship chain (still the build lane, same slot, both halves), the
  assigned build slot's port pair is appended the same way: `--ports
  fe=<port>,be=<port>`. For a STANDALONE `ship` act (a ship-only retry, tier
  4 above), the ports instead come from the SHIP lane's own base — a
  different, non-overlapping range, since ship-work runs no UI server and
  these ports only isolate its local gates from a concurrently running build.
  Either way, bind exactly the two ports given (never the human's baseline
  5173/8000) — see `implement-issue`'s headless section for the CORS
  implication, which only applies to the build-lane case.
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
